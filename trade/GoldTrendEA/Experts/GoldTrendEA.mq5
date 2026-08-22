//+------------------------------------------------------------------+
//|                                                  GoldTrendEA.mq5 |
//|  黄金外汇 EA「顺势一单一结」—— 主 EA 文件                          |
//|  职责：模块初始化与依赖注入(OnInit)、主流程调度(OnTick)、           |
//|        句柄释放与状态持久化(OnDeinit)、成交回报驱动状态机           |
//|        (OnTradeTransaction)                                        |
//|  对应方案文档：第 3.3/3.4 节（架构与主流程图）、第 6 章实现要点     |
//+------------------------------------------------------------------+
#property copyright "GoldTrendEA Project"
#property link      ""
// F1：版本号与 Config.mqh 的 GTEA_VERSION 保持同步（#property 不支持
//     宏展开，升版时两处同步修改）
#property version   "0.31"
#property description "顺势一单一结 EA 框架：H1趋势+M15短线过滤，同一时刻最多1单"
#property strict

#include <GoldTrendEA/Config.mqh>
#include <GoldTrendEA/Logger.mqh>
#include <GoldTrendEA/MarketData.mqh>
#include <GoldTrendEA/Indicators.mqh>
#include <GoldTrendEA/SignalEngine.mqh>
#include <GoldTrendEA/PositionManager.mqh>
#include <GoldTrendEA/RiskManager.mqh>
#include <GoldTrendEA/TradeExecutor.mqh>

//--- 模块实例（EA 生命周期内单例）
CLogger           g_logger;
CMarketData       g_market;
CIndicators       g_indicators;
CSignalEngine     g_signal;
CPositionManager  g_posMgr;
CRiskManager      g_risk;
CTradeExecutor    g_executor;

//--- 修复三：OPENING 态待重试的开仓参数（Tick 驱动非阻塞重试用）
//    修复A2：不再缓存首次计算的 SL/TP 绝对价（重试时已过期），
//    改存止损距离，重试时基于当前 Ask/Bid 重算；并记录首次尝试时刻
//    用于重试超时判定
ENUM_SIGNAL_DIR   g_pendingDir      = SIGNAL_NONE;
double            g_pendingLots     = 0.0;
double            g_pendingSLDist   = 0.0;   // 首次计算的 ATR 止损距离（修复A2）
datetime          g_pendingFirstTry = 0;     // 首次下单尝试时刻（修复A2 超时用）

//+------------------------------------------------------------------+
//| OnInit：环境校验 → 模块初始化与依赖注入 → 状态恢复                 |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- 1. 日志模块最先初始化（其余模块依赖它）
   if(!g_logger.Init(InpMagic))
      return INIT_FAILED;
   g_logger.Info("========== GoldTrendEA v" + GTEA_VERSION + " 初始化 ==========");   // F1：版本号统一引用
   g_logger.Info(StringFormat("品种=%s 趋势周期=%s 信号周期=%s magic=%I64d",
                              _Symbol, EnumToString(InpTrendTF),
                              EnumToString(InpSignalTF), InpMagic));

   //--- 修复一（防呆）：多图表挂载须为每个图表配置不同 magic
   if(InpMagic == 20260813)
      g_logger.Warn("InpMagic 仍为默认值 20260813: 多图表/多品种挂载时请为每个图表配置不同 magic, 避免持仓与状态互相干扰");

   //--- 2. 参数合法性校验（方案 6.5）
   if(InpEMA_Fast >= InpEMA_Mid || InpEMA_Mid >= InpEMA_Slow)
     {
      g_logger.Error("参数校验失败: 须满足 EMA_Fast < EMA_Mid < EMA_Slow");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPercent <= 0 || InpRiskPercent > 5.0)
     {
      g_logger.Error("参数校验失败: InpRiskPercent 须在 (0, 5] 区间");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMACD_Window < 1 || InpMACD_Window > 50)
     {
      g_logger.Error("参数校验失败: InpMACD_Window 须在 [1, 50] 区间");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpDonchian_Period < 2 || InpDonchian_Period > 100)
     {
      g_logger.Error("参数校验失败: InpDonchian_Period 须在 [2, 100] 区间");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- 3. 账户模式记录（Netting/Hedging 适配，方案 6.6）
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_logger.Info("账户模式: " + (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING
                                 ? "Hedging" : "Netting"));

   //--- 4. 各模块初始化与依赖注入（顺序：数据层 → 指标层 → 上层模块）
   if(!g_market.Init(_Symbol, &g_logger))
     { g_logger.Error("CMarketData 初始化失败");  return INIT_FAILED; }
   if(!g_indicators.Init(_Symbol, &g_logger))
     { g_logger.Error("CIndicators 初始化失败(指标句柄创建失败)");  return INIT_FAILED; }
   if(!g_signal.Init(&g_market, &g_indicators, &g_logger))
     { g_logger.Error("CSignalEngine 初始化失败");  return INIT_FAILED; }
   if(!g_posMgr.Init(InpMagic, _Symbol, &g_logger))
     { g_logger.Error("CPositionManager 初始化失败");  return INIT_FAILED; }
   if(!g_risk.Init(InpMagic, _Symbol, &g_logger))   // 修复一：传入 magic 生成实例级持久化前缀
     { g_logger.Error("CRiskManager 初始化失败");  return INIT_FAILED; }
   //--- A3：注入风控模块，供 SyncWithReality 兜底路径回查盈亏后补风控统计
   g_posMgr.SetRiskManager(&g_risk);
   if(!g_executor.Init(_Symbol, InpMagic, InpSlippagePoints, &g_logger))
     { g_logger.Error("CTradeExecutor 初始化失败");  return INIT_FAILED; }

   //--- 5. 修复E2：离线成交补账 —— 离线期间持仓被服务器平掉（周末跳空
   //    触发 SL 等）时 OnTradeTransaction 不会补发，需回查历史补记风控统计
   ReconcileOfflineDeals();

   //--- 6. 状态恢复：存量持仓 > 全局变量冷却 > IDLE（方案 4.3 / 8.2）
   g_posMgr.RestoreState();

   //--- 7. G10：重连对账 —— 恢复到 POSITION_OPEN 时校验持仓 SL/TP
   //    存在性与方向，SL 缺失时按持久化的初始止损距离重建（方案 8.2）
   ReconcileRestoredStops();

   g_logger.Notify("EA 启动完成, 当前状态机就绪");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit：释放指标句柄 + 持久化状态（方案 6.2 / 6.6）              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_posMgr.SaveState();
   g_risk.SaveState();
   g_indicators.Release();
   g_logger.Info(StringFormat("EA 停止, reason=%d, 状态已持久化", reason));
  }

//+------------------------------------------------------------------+
//| OnTick：主流程调度（严格对应方案 3.4 主流程图）                    |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- D1：每 Tick 开始失效持仓计数缓存（同一 Tick 内后续查询复用）
   g_posMgr.InvalidateCache();
   //--- F5：心跳全局变量（每 5 分钟写一次，供外部看门狗监控 EA 存活）
   g_posMgr.UpdateHeartbeat();

   //--- ① 交易环境校验（失败节流告警并返回）
   if(!g_market.IsTradingEnvironmentOK())
      return;

   //--- ② 风控周期复位（跨日/跨周基数快照）与状态对账
   g_risk.CheckPeriodReset();
   g_posMgr.SyncWithReality();

   //--- ③ 周五收盘离场：强制平仓且不再开仓（方案 5.2）
   if(g_risk.IsFridayCloseTime())
     {
      if(g_posMgr.HasPosition())
        {
         // 修复C2：先进 CLOSING 态再平仓，失败时后续 Tick 可继续重试
         g_posMgr.SetState(STATE_CLOSING);
         g_executor.CloseMyPosition("周五收盘离场");
         g_posMgr.InvalidateCache();       // D1：平仓动作后失效缓存防脏读
         // 平仓成交回报将由 OnTradeTransaction 驱动状态机进入冷却
        }
      // 修复三：离场时段放弃待重试的开仓，避免 OPENING 态滞留
      if(g_posMgr.State() == STATE_OPENING)
         CancelPendingOpen("周五收盘离场");
      return;
     }

   //--- ④ 有持仓 → 仅执行持仓管理（熔断激活时同样只管理存量持仓）
   if(g_posMgr.HasPosition())
     {
      // 修复C2：CLOSING 态下持仓仍在（此前平仓失败）→ 本 Tick 继续尝试
      //         平仓直到成功，成交回报由 OnTradeTransaction 驱动进入冷却
      if(g_posMgr.State() == STATE_CLOSING)
        {
         g_executor.CloseMyPosition("CLOSING 态补偿重试");
         g_posMgr.InvalidateCache();       // D1：平仓动作后失效缓存防脏读
         return;
        }
      ManagePosition();
      return;
     }

   //--- ⑤ 熔断检查：激活时禁止开新仓
   string haltReason;
   if(g_risk.IsHalted(haltReason))
     {
      g_logger.WarnThrottled("halt", "熔断激活, 禁止开仓: " + haltReason);
      // 修复三：熔断期间放弃待重试的开仓
      if(g_posMgr.State() == STATE_OPENING)
         CancelPendingOpen("熔断激活");
      return;
     }

   //--- ⑤+ OPENING 态：Tick 驱动的下单重试（修复三），重试等待期间
   //       不重复评估信号、不进入新 K 线信号流程
   if(g_posMgr.State() == STATE_OPENING)
     {
      RetryOpenPosition();
      return;
     }

   //--- ⑥ 仅在信号周期新 K 线时执行完整信号计算（方案 6.1 / N05）
   if(!g_market.IsNewBar(InpSignalTF))
      return;

   //--- ⑦ 冷却期倒数（COOLING_DOWN → IDLE）
   g_posMgr.OnNewSignalBar();
   if(!g_posMgr.CanOpenNew())
      return;

   //--- ⑧ 信号引擎评估：三重过滤（方向+动能+突破）
   //    G4：用带同K线缓存的入口，与持仓期反向信号检测共用评估结果
   ENUM_SIGNAL_DIR sig = g_signal.EvaluateCached();
   if(sig == SIGNAL_NONE)
      return;
   g_posMgr.SetState(STATE_SIGNAL_CONFIRMED);

   //--- ⑨ 开仓前置检查：点差过滤（时段/新闻过滤已含在熔断裁决中）
   if(!g_risk.SpreadOk())
     {
      g_posMgr.SetState(STATE_IDLE);
      return;
     }

   //--- ⑩ 计算初始 SL/TP 与风控手数，执行开仓
   TryOpenPosition(sig);
  }

//+------------------------------------------------------------------+
//| 开仓流程：计算 SL/TP → 手数 → 保证金校验 → 下单（方案 4.4 / 5.1） |
//+------------------------------------------------------------------+
void TryOpenPosition(const ENUM_SIGNAL_DIR sig)
  {
   bool   isBuy = (sig == SIGNAL_BUY);
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- 初始止损：max(ATR×倍数, 结构点距离)（方案 4.4）
   double atr = 0.0;
   if(!g_indicators.AtrSig(atr) || atr <= 0)
     {
      g_logger.Warn("开仓放弃: ATR 数据不足");
      g_posMgr.SetState(STATE_IDLE);
      return;
     }
   double slDistAtr = atr * InpSL_ATR_Mult;
   double slDist    = slDistAtr;
   //--- G3（方案 4.4）：结构点止损候选 —— 近 InpSwingBars 根已收盘K线的
   //    SwingLow/SwingHigh 外加缓冲（GTEA_SWING_SL_BUFFER_ATR × ATR），与
   //    ATR 距离取 max（更宽者）；结构点距离须为正才参与比较（结构点
   //    越过入场价的异常形态退化为纯 ATR 止损）
   double swing = 0.0;
   if(isBuy && g_indicators.SwingLow(swing, InpSwingBars) && entry - swing > 0)
      slDist = MathMax(slDistAtr, entry - swing + atr * GTEA_SWING_SL_BUFFER_ATR);
   if(!isBuy && g_indicators.SwingHigh(swing, InpSwingBars) && swing - entry > 0)
      slDist = MathMax(slDistAtr, swing - entry + atr * GTEA_SWING_SL_BUFFER_ATR);
   double sl = isBuy ? entry - slDist : entry + slDist;

   //--- 固定盈亏比止盈：TP = entry ± slDist × InpRR（方案 4.4）
   double tp = isBuy ? entry + slDist * InpRR : entry - slDist * InpRR;

   //--- 风控手数：单笔风险百分比反推（方案 5.1）
   double lots = g_risk.CalcLots(entry, sl);
   if(lots <= 0)
     {
      g_posMgr.SetState(STATE_IDLE);
      return;
     }
   //--- 保证金校验
   if(!g_risk.MarginOk(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lots, entry))
     {
      g_posMgr.SetState(STATE_IDLE);
      return;
     }

   //--- 下单（修复三：Tick 驱动非阻塞重试，本次仅一次尝试）
   g_posMgr.SetState(STATE_OPENING);
   if(g_executor.Open(sig, lots, sl, tp, "GTEA"))
     {
      g_posMgr.InvalidateCache();          // D1：开仓成功后失效缓存防脏读
      g_posMgr.SetState(STATE_POSITION_OPEN);
      // G1：持久化初始止损距离（保本触发基准，EA 重启后可恢复）
      g_posMgr.SaveInitialSLDist(slDist);
     }
   else if(g_executor.IsRetryPending())
     {
      // 可重试失败：登记待重试参数，保持 OPENING 由后续 Tick 继续（修复三）
      // 修复A2：只登记止损距离与首次尝试时刻，重试时按当前价重算 SL/TP
      g_pendingDir      = sig;
      g_pendingLots     = lots;
      g_pendingSLDist   = slDist;
      g_pendingFirstTry = TimeCurrent();
     }
   else
     {
      // 不可重试/重试耗尽失败：记 ERROR 后回到待机（方案 4.3 状态图 OPENING→IDLE）
      g_posMgr.SetState(STATE_IDLE);
     }
  }

//+------------------------------------------------------------------+
//| OPENING 态：Tick 驱动的开仓重试（修复三，替代阻塞式 Sleep 重试）  |
//|   修复A2：重试时基于当前 Ask/Bid 重算 SL/TP（沿用首次的 ATR 止损  |
//|   距离），避免沿用过期价格；并增加重试超时窗口，首次尝试后        |
//|   GTEA_OPEN_RETRY_TIMEOUT_SEC 秒仍未成功则放弃回 IDLE 重走信号评估    |
//+------------------------------------------------------------------+
void RetryOpenPosition()
  {
   //--- 评审六（防御）：仅 OPENING 态可执行重试/超时取消，防未来新增
   //    调用路径在其它状态下误清待重试参数/误改状态机
   if(g_posMgr.State() != STATE_OPENING)
      return;
   if(g_pendingDir == SIGNAL_NONE || g_pendingSLDist <= 0)
     {
      // 无待重试参数（异常兜底，如重启后恢复到 OPENING）：回退待机
      g_executor.ResetRetry();
      g_posMgr.SetState(STATE_IDLE);
      return;
     }
   //--- 修复A2：重试超时判定，超窗口后放弃本次信号（行情可能已走远）
   if(TimeCurrent() - g_pendingFirstTry > GTEA_OPEN_RETRY_TIMEOUT_SEC)
     {
      CancelPendingOpen(StringFormat("重试超时(超过 %d 秒)", GTEA_OPEN_RETRY_TIMEOUT_SEC));
      return;
     }
   //--- 修复A2：基于当前价重算 SL/TP（复用首次的 ATR 止损距离与盈亏比逻辑），
   //    止损距离未变故手数风险不变，g_pendingLots 无需重算
   bool   isBuy = (g_pendingDir == SIGNAL_BUY);
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = isBuy ? entry - g_pendingSLDist : entry + g_pendingSLDist;
   double tp = isBuy ? entry + g_pendingSLDist * InpRR : entry - g_pendingSLDist * InpRR;
   if(g_executor.Open(g_pendingDir, g_pendingLots, sl, tp, "GTEA"))
     {
      g_posMgr.InvalidateCache();          // D1：开仓成功后失效缓存防脏读
      // G1：重试成功同样持久化初始止损距离（先存再清待重试参数）
      g_posMgr.SaveInitialSLDist(g_pendingSLDist);
      ClearPendingOpen();
      g_posMgr.SetState(STATE_POSITION_OPEN);
      return;
     }
   if(!g_executor.IsRetryPending())
     {
      // 重试耗尽或不可重试：放弃并回退 IDLE（保持原回退语义）
      ClearPendingOpen();
      g_posMgr.SetState(STATE_IDLE);
     }
   // 仍在重试窗口内：保持 OPENING，等待下一 Tick
  }

//+------------------------------------------------------------------+
//| 清除待重试开仓参数（修复三）                                     |
//+------------------------------------------------------------------+
void ClearPendingOpen()
  {
   g_pendingDir      = SIGNAL_NONE;
   g_pendingLots     = 0.0;
   g_pendingSLDist   = 0.0;
   g_pendingFirstTry = 0;
  }

//+------------------------------------------------------------------+
//| 取消待重试开仓并回退状态机（修复三：周五离场/熔断时调用）       |
//+------------------------------------------------------------------+
void CancelPendingOpen(const string reason)
  {
   g_logger.Warn("放弃待重试开仓: " + reason);
   g_executor.ResetRetry();
   ClearPendingOpen();
   g_posMgr.SetState(STATE_IDLE);
  }

//+------------------------------------------------------------------+
//| 持仓管理：保本推损 / 跟踪止损 / 趋势反转离场（方案 4.4）           |
//|   Tick 级：保本推损（G1，对触发价敏感）                           |
//|   新K线级：ATR+结构点跟踪止损（G2/G3）、趋势反转检测（含 G4      |
//|   反向三重信号）（方案 N05 性能要求）                              |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   CPositionInfo pos;
   if(!g_posMgr.SelectMyPosition(pos))
      return;

   //--- Tick 级：保本推损（G1）
   bool beMoved = ApplyBreakEven(pos);

   //--- 新 K 线级：跟踪止损 + 反转离场
   if(g_market.IsNewBar(InpSignalTF))
     {
      //--- 保本刚改过单：重新选中刷新 SL/TP 快照，避免用过期值计算
      if(beMoved && !g_posMgr.SelectMyPosition(pos))
         return;

      //--- ATR+结构点跟踪止损（G2/G3）
      ApplyTrailingStop(pos);

      //--- 趋势反转强制离场（方案 4.4）：H4 排列反转 或 完整反向
      //    三重信号（G4，评估结果同K线内缓存）
      int posDir = (pos.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
      if(g_signal.IsTrendReversed(posDir))
        {
         g_posMgr.SetState(STATE_CLOSING);
         g_executor.CloseMyPosition("趋势反转强制离场");
         g_posMgr.InvalidateCache();       // D1：平仓动作后失效缓存防脏读
        }
     }
  }

//+------------------------------------------------------------------+
//| G1 保本推损（Tick 级，方案 4.4）：浮盈达到 初始止损距离 ×          |
//|   InpBE_Trigger 时将 SL 推至 入场价 ± InpBE_Offset；只推一次        |
//|   （持久化标记防重复，重启后不重推）                              |
//|   返回 true = 本 Tick 执行了推损改单（调用方需刷新持仓快照）       |
//+------------------------------------------------------------------+
bool ApplyBreakEven(CPositionInfo &pos)
  {
   if(!InpUseBreakEven)
      return false;
   if(g_posMgr.IsBreakEvenDone())
      return false;                        // 保本只推一次（G1）

   //--- 初始止损距离：优先取开仓时持久化值；缺失（如全局变量被清）
   //    时回退用当前 |入场价-SL|（保本未推过，当前 SL 仍是初始 SL）
   double slDist = g_posMgr.InitialSLDist();
   if(slDist <= 0 && pos.StopLoss() > 0)
      slDist = MathAbs(pos.PriceOpen() - pos.StopLoss());
   if(slDist <= 0)
      return false;                        // 无法确定触发基准，跳过

   bool   isBuy = (pos.PositionType() == POSITION_TYPE_BUY);
   double entry = pos.PriceOpen();
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return false;
   double profit = isBuy ? (bid - entry) : (entry - ask);   // 浮盈（价格单位）
   if(profit < slDist * InpBE_Trigger)
      return false;                        // 未达保本触发阈值

   //--- 保本推损语义（方案 4.4：SL 移至「入场价 ± InpBE_Offset」）：
   //    多单将 SL 上移到入场价上方 offset 处锁定小利（此时浮盈已达
   //    slDist×trigger，现价远在 newSL 上方），空单对称下移；若写成
   //    entry - offset（多单）则 SL 仍在入场价下方，留有亏损敞口，
   //    不是「保本」—— 勿改反方向
   double newSL = isBuy ? entry + InpBE_Offset : entry - InpBE_Offset;
   double curSL = pos.StopLoss();
   //--- 只朝有利方向：新 SL 须优于当前 SL；且不越过现价（本地预检，
   //    避免无效改单与告警刷屏）
   if(isBuy && ((curSL > 0 && newSL <= curSL) || newSL >= bid))
      return false;
   if(!isBuy && ((curSL > 0 && newSL >= curSL) || newSL <= ask))
      return false;

   if(g_executor.ModifySL(pos.Ticket(), newSL, pos.TakeProfit()))
     {
      g_posMgr.MarkBreakEvenDone();        // 持久化标记，重启后不重复推
      g_logger.Notify(StringFormat("保本推损: SL %.2f -> %.2f (浮盈 %.2f 达触发阈值 %.2f)",
                                   curSL, newSL, profit, slDist * InpBE_Trigger));
      return true;
     }
   return false;                           // 改单失败，下一 Tick 自然重试
  }

//+------------------------------------------------------------------+
//| G2/G3 跟踪止损（新 K 线级，方案 4.4 / N05）：                     |
//|   候选1 = 已收盘价 ∓ ATR × InpTrail_ATR_Mult（G2）                |
//|   候选2 = 近 InpSwingBars 根已收盘K线结构点（多单 SwingLow /       |
//|           空单 SwingHigh，G3）                                     |
//|   取更利于保护利润者（多单 max / 空单 min），只朝有利方向移动；   |
//|   保本启用时待保本完成后启动（方案 4.4「保本后启动」，且只利动      |
//|   保证跟踪结果不低于保本位）；InpTrailReplacesTP=true 时跟踪改单     |
//|   同时取消固定 TP（让利润奔跑）                                   |
//+------------------------------------------------------------------+
void ApplyTrailingStop(CPositionInfo &pos)
  {
   if(!InpUseTrailing)
      return;
   //--- 保本启用时：保本完成后才启动跟踪（保本优先）；保本关闭时独立启动
   if(InpUseBreakEven && !g_posMgr.IsBreakEvenDone())
      return;

   double atr = 0.0;
   if(!g_indicators.AtrSig(atr) || atr <= 0)
      return;                              // 数据不足静默跳过（方案 6.2）
   double close = g_market.Close(InpSignalTF, 1);
   if(close <= 0)
      return;

   bool   isBuy = (pos.PositionType() == POSITION_TYPE_BUY);
   double newSL = 0.0;
   double swing = 0.0;
   if(isBuy)
     {
      newSL = close - atr * InpTrail_ATR_Mult;          // G2：ATR 跟踪候选
      if(g_indicators.SwingLow(swing, InpSwingBars))    // G3：结构点候选
         newSL = MathMax(newSL, swing);                 // 多单取更高者（更利于保护利润）
     }
   else
     {
      newSL = close + atr * InpTrail_ATR_Mult;
      if(g_indicators.SwingHigh(swing, InpSwingBars))
         newSL = MathMin(newSL, swing);                 // 空单取更低者
     }

   double curSL = pos.StopLoss();
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   //--- 只朝有利方向移动（保本后 curSL 已在保本位，只利动即保证不低于
   //    保本位；newSL == curSL 时改单是无效操作，同样跳过，故用 <=/>=）
   //    + 不越过现价（本地预检降噪，如结构点高于现价的急跌场景）
   if(isBuy && ((curSL > 0 && newSL <= curSL) || newSL >= bid))
      return;
   if(!isBuy && ((curSL > 0 && newSL >= curSL) || newSL <= ask))
      return;

   //--- InpTrailReplacesTP：跟踪启动后取消固定 TP（方案 4.4 风格开关）
   double tp = InpTrailReplacesTP ? 0.0 : pos.TakeProfit();
   if(g_executor.ModifySL(pos.Ticket(), newSL, tp))
      g_logger.Info(StringFormat("跟踪止损: SL %.2f -> %.2f (ATR=%.2f, 结构点=%.2f)%s",
                                 curSL, newSL, atr, swing,
                                 (InpTrailReplacesTP && pos.TakeProfit() > 0) ? ", 已取消固定TP" : ""));
  }

//+------------------------------------------------------------------+
//| G10 重连对账（OnInit 中 RestoreState 之后调用，方案 8.2）：       |
//|   恢复到 POSITION_OPEN 时校验持仓 SL/TP 是否存在且方向合理；       |
//|   SL 缺失 → 按持久化初始止损距离重建（无记录时回退 ATR 距离）；   |
//|   方向异常 → 告警（不自动修正，留人工裁决）                        |
//+------------------------------------------------------------------+
void ReconcileRestoredStops()
  {
   if(g_posMgr.State() != STATE_POSITION_OPEN)
      return;
   CPositionInfo pos;
   if(!g_posMgr.SelectMyPosition(pos))
      return;

   bool   isBuy = (pos.PositionType() == POSITION_TYPE_BUY);
   double entry = pos.PriceOpen();
   double sl    = pos.StopLoss();
   double tp    = pos.TakeProfit();
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- SL 缺失：按持久化的初始止损距离重建（无记录时回退 ATR×倍数）
   if(sl <= 0)
     {
      double dist = g_posMgr.InitialSLDist();
      if(dist <= 0)
        {
         double atr = 0.0;
         if(g_indicators.AtrSig(atr) && atr > 0)
            dist = atr * InpSL_ATR_Mult;
        }
      if(dist <= 0)
        {
         g_logger.Error("重连对账: 持仓 SL 缺失且无法重建(无持久化距离且 ATR 不可用), 请人工处理");
         return;
        }
      double newSL = isBuy ? entry - dist : entry + dist;
      g_logger.Warn(StringFormat("重连对账: 持仓 SL 缺失, 按初始止损距离 %.2f 重建 SL=%.2f",
                                 dist, newSL));
      if(!g_executor.ModifySL(pos.Ticket(), newSL, tp))
         g_logger.Error("重连对账: SL 重建改单失败, 持仓暂无止损保护, 请人工核对");
      // 注：改单失败时持仓仍在，INIT_SLDIST 仍是该持仓的有效信息（保本
      //    触发基准），不可在此 ClearTradeVars；单笔变量的清理统一由平仓后
      //    StartCooldown 负责，新开仓时 SaveInitialSLDist 也会覆盖旧值
      return;
     }

   //--- SL 方向校验：多单 SL 应低于 Bid、空单 SL 应高于 Ask（保本后 SL
   //    可能高于入场价，故以现价为基准而非入场价）
   if(bid > 0 && ask > 0)
     {
      if((isBuy && sl >= bid) || (!isBuy && sl <= ask))
         g_logger.Warn(StringFormat("重连对账: SL 方向异常(%s SL=%.2f Bid=%.2f Ask=%.2f), 请人工核对",
                                    isBuy ? "多单" : "空单", sl, bid, ask));
      //--- TP 方向校验（TP=0 合法：InpTrailReplacesTP 取消 TP 的场景）
      if(tp > 0 && ((isBuy && tp <= ask) || (!isBuy && tp >= bid)))
         g_logger.Warn(StringFormat("重连对账: TP 方向异常(%s TP=%.2f), 请人工核对",
                                    isBuy ? "多单" : "空单", tp));
     }
   g_logger.Info(StringFormat("重连对账: 持仓 SL/TP 校验完成 SL=%.2f TP=%.2f", sl, tp));
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction：成交回报驱动状态机流转（方案 4.3 / 6.6）       |
//|   捕获 DEAL_ADD 且 DEAL_ENTRY_OUT 的平仓成交：                     |
//|   记录单笔盈亏(利润+隔夜费+佣金) → 风控统计 → 启动冷却             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   //--- 只关心新增成交
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   //--- C3：先确保交易历史已加载，否则 HistoryDealSelect 可能因历史
   //    缓存未同步而失败漏记（+3600 冗余覆盖服务器时钟偏差）
   if(!HistorySelect(0, TimeCurrent() + 3600))
      return;
   //--- 选中成交单获取详情
   if(!HistoryDealSelect(trans.deal))
      return;
   //--- 过滤：本 EA（magic）+ 本品种
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   //--- D1：本 EA 的成交必然改变持仓状态，失效持仓计数缓存
   g_posMgr.InvalidateCache();
   //--- 只处理平仓方向的成交（DEAL_ENTRY_OUT，方案 6.6）
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   //--- A3：防重复入账 —— SyncWithReality 兜底补账可能已先行入账该成交
   //    （成交 ticket 服务器端递增，<= 最后已入账 ticket 即已处理过；
   //    同一 ticket 重复推送时 deal == last 恰被 <= 拦截，改成 < 会放行
   //    重复入账，勿改）
   if(trans.deal <= g_risk.LastDealTicket())
      return;

   //--- 单笔盈亏 = 利润 + 隔夜费 + 佣金（方案 6.6）
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_logger.Info(StringFormat("平仓成交回报: deal=%I64u 盈亏=%.2f", trans.deal, profit));

   //--- 风控统计（连亏计数/日周亏损累计/熔断判定）
   //    修复E2：传入 deal ticket 登记为最后已入账成交，供离线补账去重
   g_risk.OnTradeResult(profit, trans.deal);
   //--- 状态机：平仓结算 → 冷却期（方案 4.3）
   g_posMgr.OnPositionClosed(profit);
  }

//+------------------------------------------------------------------+
//| 修复E2：离线成交补账（OnInit 中、RestoreState 前调用）           |
//|   EA 离线期间（如周末跳空触发 SL）持仓被服务器平掉时，重启后     |
//|   OnTradeTransaction 不会触发，日/周亏损与连亏熔断统计会遗漏。       |
//|   判定：上次保存状态为 POSITION_OPEN/CLOSING 但当前无本 magic 持仓    |
//|   → 回查历史成交（magic + 品种 + DEAL_ENTRY_OUT，且 ticket 大于最后   |
//|   已入账成交防重复）补调 OnTradeResult 并进入冷却                    |
//+------------------------------------------------------------------+
void ReconcileOfflineDeals()
  {
   ENUM_EA_STATE savedState = g_posMgr.SavedState();
   if(savedState != STATE_POSITION_OPEN && savedState != STATE_CLOSING)
      return;                              // 上次停机时非持仓态，无需补账
   if(g_posMgr.HasPosition())
      return;                              // 持仓仍在，由 RestoreState 正常接管

   //--- 回查窗口：上次状态保存时刻前移 1 小时冗余；无记录时取缺省窗口
   datetime from = g_posMgr.StateSavedTime();
   if(from <= 0)
      from = TimeCurrent() - GTEA_RECONCILE_LOOKBACK_SEC;
   else
      from -= 3600;
   if(!HistorySelect(from, TimeCurrent() + 60))
     {
      g_logger.Warn("离线补账: HistorySelect 失败, 无法回查历史成交, 请人工核对风控统计");
      return;
     }

   ulong  lastTicket = g_risk.LastDealTicket();
   int    found      = 0;
   double profitSum  = 0.0;
   int    total      = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || deal <= lastTicket)
         continue;                         // 已入账过的成交跳过（防重复）
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      //--- 单笔盈亏口径与 OnTradeTransaction 一致（方案 6.6）
      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal, DEAL_SWAP)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION);
      g_logger.Warn(StringFormat("离线补账: 补记平仓成交 deal=%I64u 盈亏=%.2f", deal, profit));
      g_risk.OnTradeResult(profit, deal);
      profitSum += profit;
      found++;
     }

   if(found > 0)
     {
      g_logger.Notify(StringFormat("离线补账完成: 共 %d 笔, 合计盈亏=%.2f, 进入冷却期", found, profitSum));
      // 进入冷却并持久化，随后 RestoreState 会从全局变量恢复 COOLING_DOWN
      g_posMgr.OnPositionClosed(profitSum);
     }
   else
      g_logger.Warn("离线补账: 上次状态为持仓但未找到对应平仓成交, 请人工核对历史订单");
  }

//+------------------------------------------------------------------+
//| OnTester：自定义复合优化指标（G7/F3，方案 7.2「复合指标」）      |
//|   适应度 = ProfitFactor × sqrt(总交易数) ÷ max(最大相对回撤%, 1)   |
//|   奖励高利润因子与充足样本量、惩罚深回撤；无交易/异常返回 0       |
//+------------------------------------------------------------------+
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   if(trades <= 0)
      return 0.0;                          // 无交易：无统计意义
   //--- PF 手工计算：总亏损为 0 时内置 STAT_PROFIT_FACTOR 无定义，
   //    封顶 100 防无穷大扭曲遗传优化排序
   double grossProfit = TesterStatistics(STAT_GROSS_PROFIT);
   double grossLoss   = MathAbs(TesterStatistics(STAT_GROSS_LOSS));
   double pf = (grossLoss > 0) ? grossProfit / grossLoss
                               : (grossProfit > 0 ? 100.0 : 0.0);
   if(pf <= 0)
      return 0.0;
   //--- 最大相对回撤%（按净值，方案 1.4 验收口径），下限 1 防除零与
   //    极小回撤刺高适应度
   double ddRel = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   return pf * MathSqrt(trades) / MathMax(ddRel, 1.0);
  }
//+------------------------------------------------------------------+
