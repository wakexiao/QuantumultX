//+------------------------------------------------------------------+
//|                                                  GoldRangeEA.mq5 |
//|  黄金箱体震荡 EA「高抛低吸一单一结」—— 主 EA 文件                  |
//|  职责：模块初始化与依赖注入(OnInit)、主流程调度(OnTick，从最便宜    |
//|        到最贵逐级过滤)、持仓突破联动与时间止损(ManagePosition)、    |
//|        句柄释放与状态持久化(OnDeinit)、成交回报驱动状态机           |
//|        (OnTradeTransaction)                                        |
//|  对应需求文档 v1.md：§九（运行逻辑流程图）、§八（禁止事项）         |
//+------------------------------------------------------------------+
#property copyright "GoldRangeEA Project"
#property link      ""
// 版本号与 Config.mqh 的 GREA_VERSION 保持同步（#property 不支持
// 宏展开，升版时两处同步修改）
#property version   "1.10"
#property description "箱体震荡高抛低吸一单一结EA：M15箱体识别+KDJ超买超卖+ADX趋势过滤，同一时刻最多1单"
#property strict

#include <GoldRangeEA/Config.mqh>
#include <GoldRangeEA/Logger.mqh>
#include <GoldRangeEA/MarketData.mqh>
#include <GoldRangeEA/Indicators.mqh>
#include <GoldRangeEA/BoxEngine.mqh>
#include <GoldRangeEA/PositionManager.mqh>
#include <GoldRangeEA/RiskManager.mqh>
#include <GoldRangeEA/TradeExecutor.mqh>

//--- 模块实例（EA 生命周期内单例）
CLogger           g_logger;
CMarketData       g_market;
CIndicators       g_indicators;
CBoxEngine        g_box;
CPositionManager  g_posMgr;
CRiskManager      g_risk;
CTradeExecutor    g_executor;

//--- OPENING 态待重试的开仓参数（Tick 驱动非阻塞重试）
//    不缓存首次的 SL/TP 绝对价（重试时已过期）：重试时按当前价与
//    当前箱体缓存经 CalcStops 重算；并记录首次尝试时刻用于超时判定
ENUM_SIGNAL_DIR   g_pendingDir      = SIGNAL_NONE;
double            g_pendingLots     = 0.0;
datetime          g_pendingFirstTry = 0;     // 首次下单尝试时刻（超时用）

//--- 箱体快照缺失告警节流（异常场景，300 秒最多一条 ERROR 防刷屏）
datetime          g_lastSnapErrTime = 0;

//+------------------------------------------------------------------+
//| OnInit：参数校验 → 模块初始化与依赖注入 → 离线补账 → 状态恢复      |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- 1. 日志模块最先初始化（其余模块依赖它）
   if(!g_logger.Init(InpMagic))
      return INIT_FAILED;
   g_logger.Info("========== GoldRangeEA v" + GREA_VERSION + " 初始化 ==========");
   g_logger.Info(StringFormat("品种=%s 信号周期=%s magic=%I64d",
                              _Symbol, EnumToString(InpSignalTF), InpMagic));

   //--- 2. 参数合法性校验
   if(InpBoxBars < 2)
     {
      g_logger.Error("参数校验失败: 箱体K线数量须 ≥ 2");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpBoxMinPoints <= 0 || InpBoxMaxPoints <= 0 || InpBoxMinPoints >= InpBoxMaxPoints)
     {
      g_logger.Error(StringFormat("参数校验失败: 须满足 0 < 箱体最小高度(%d) < 最大高度(%d)",
                                  InpBoxMinPoints, InpBoxMaxPoints));
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTPRatio <= 0 || InpSLRatio <= 0)
     {
      g_logger.Error("参数校验失败: 止盈比例/止损比例须 > 0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinRR < 1.0)
     {
      g_logger.Error("参数校验失败: 最小盈亏比须 ≥ 1.0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpFixedLots <= 0)
     {
      g_logger.Error("参数校验失败: 固定手数须 > 0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTouchTolerancePct < 0 || InpEntryTolerancePct < 0 ||
      InpTouchTolMinPoints < 0 || InpEntryTolMinPoints < 0)
     {
      g_logger.Error("参数校验失败: 触碰容差/入场容差(百分比与下限点数)须 ≥ 0");
      return INIT_PARAMETERS_INCORRECT;
     }
   //--- 以下 4 项为重标定评审修复补充：容差/入场带量级耦合校验
   if(InpTouchTolerancePct >= 50 || InpEntryTolerancePct >= 50)
     {
      g_logger.Error(StringFormat("参数校验失败: 触碰/入场容差百分比(%.1f%%/%.1f%%)须 < 50, 否则容差达箱高一半、箱体中部不开仓语义被破坏; 若从旧版本升级, 请先删除/重建 .set 文件后重试(旧参数值会被按参数名静默覆盖)",
                                  InpTouchTolerancePct, InpEntryTolerancePct));
      return INIT_PARAMETERS_INCORRECT;
     }
   if((InpTouchTolerancePct <= 0 && InpTouchTolMinPoints <= 0) ||
      (InpEntryTolerancePct <= 0 && InpEntryTolMinPoints <= 0))
     {
      g_logger.Error("参数校验失败: 触碰/入场容差的百分比与下限点数不可同时为 0(容差恒为 0, 判定退化为精确相等且永不触发); 若从旧版本升级, 请先删除/重建 .set 文件后重试(旧参数值会被按参数名静默覆盖)");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(2 * InpEntryTolMinPoints >= InpBoxMinPoints)
     {
      g_logger.Error(StringFormat("参数校验失败: 入场容差下限 %d 点过大(须 < 箱体最小高度 %d 点的一半), 否则最小箱体上两侧入场带重叠; 若从旧版本升级, 请先删除/重建 .set 文件后重试(旧参数值会被按参数名静默覆盖)",
                                  InpEntryTolMinPoints, InpBoxMinPoints));
      return INIT_PARAMETERS_INCORRECT;
     }
   if(MathMax(InpEntryTolerancePct * InpBoxMaxPoints / 100.0, InpEntryTolMinPoints) >= InpBreakoutPoints)
     {
      g_logger.Error(StringFormat("参数校验失败: 突破联动点数 %d 须大于最大可能入场带半宽 %.1f 点, 否则存在开仓即触发突破平仓的窗口; 若从旧版本升级, 请先删除/重建 .set 文件后重试(旧参数值会被按参数名静默覆盖)",
                                  InpBreakoutPoints,
                                  MathMax(InpEntryTolerancePct * InpBoxMaxPoints / 100.0, InpEntryTolMinPoints)));
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxHoldHours < 0)
     {
      g_logger.Error("参数校验失败: 最大持仓时间须 ≥ 0（0=禁用时间止损）");
      return INIT_PARAMETERS_INCORRECT;
     }
   //--- 以下 5 项为评审修复 F6 补充：非法参数直接拒启，防参数扫描踩坑
   //    InpBreakoutPoints=0 虽通过本条 ≥0 校验，但实际会被上方的量级耦合
   //    校验拒绝（入场带半宽 > 0 时存在开仓即秒平窗口），有效下限为大于
   //    最大入场带半宽
   if(InpBreakoutPoints < 0)
     {
      g_logger.Error("参数校验失败: 突破幅度须 ≥ 0（负值会形成开仓秒平循环）");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinTouches < 1)
     {
      g_logger.Error("参数校验失败: 箱体最少触碰次数须 ≥ 1");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpKDJOversold >= InpKDJOverbought)
     {
      g_logger.Error(StringFormat("参数校验失败: 须满足 KDJ 超卖(%d) < 超买(%d)",
                                  InpKDJOversold, InpKDJOverbought));
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxConsecSL < 1)
     {
      g_logger.Error("参数校验失败: 连亏暂停笔数须 ≥ 1");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpPauseMinutes < 0)
     {
      g_logger.Error("参数校验失败: 连亏暂停时长须 ≥ 0 分钟");
      return INIT_PARAMETERS_INCORRECT;
     }
   // 点值语义提示（不拒启）：本 EA 按 v1 §十-1 固定 1 点=0.01 美元口径
   // 运行，不依赖 SYMBOL_POINT（README 决策记录 D4）。评审修复 F1/F2 后
   // 点差过滤与滑点均已自动换算适配两种报价精度，此处仅如实提示口径
   double symPoint = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(MathAbs(symPoint - GREA_POINT_VALUE) > 1e-9)
      g_logger.Warn(StringFormat("注意: 品种 SYMBOL_POINT=%.5f ≠ %.2f, 策略参数按 1点=0.01美元 口径解释, 点差过滤与滑点已自动换算适配",
                                 symPoint, GREA_POINT_VALUE));

   //--- 生效配置日志（重标定评审修复）：启动时打印关键参数供用户核对是否
   //    为重标定值——旧 .set 文件会按参数名静默覆盖新默认值（箱体/容差/
   //    突破类旧值会被上方参数校验拒启，KDJ 阈值类旧值静默通过但压低
   //    频次），升级后务必核对本行（README 升级提示）
   g_logger.Info(StringFormat(
      "生效配置: 箱体窗口=%d根 高度=[%d,%d]点 入场容差=%.1f%%+下限%d点 触碰容差=%.1f%%+下限%d点 KDJ超卖/超买=%d/%d 突破联动=%d点 日亏熔断=%.0f美元 连亏暂停=%d笔 点差上限=%d点",
      InpBoxBars, InpBoxMinPoints, InpBoxMaxPoints,
      InpEntryTolerancePct, InpEntryTolMinPoints,
      InpTouchTolerancePct, InpTouchTolMinPoints,
      InpKDJOversold, InpKDJOverbought,
      InpBreakoutPoints, InpMaxDailyLossUSD,
      InpMaxConsecSL, InpMaxSpreadPoints));

   //--- 3. 账户模式记录（Netting/Hedging 适配）
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_logger.Info("账户模式: " + (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING
                                 ? "Hedging" : "Netting"));

   //--- 4. 各模块初始化与依赖注入（顺序：数据层 → 指标层 → 上层模块）
   if(!g_market.Init(_Symbol, &g_logger))
     { g_logger.Error("CMarketData 初始化失败");  return INIT_FAILED; }
   if(!g_indicators.Init(_Symbol, &g_logger))
     { g_logger.Error("CIndicators 初始化失败(指标句柄创建失败)");  return INIT_FAILED; }
   if(!g_box.Init(&g_indicators, &g_logger))
     { g_logger.Error("CBoxEngine 初始化失败");  return INIT_FAILED; }
   if(!g_posMgr.Init(InpMagic, _Symbol, &g_logger))
     { g_logger.Error("CPositionManager 初始化失败");  return INIT_FAILED; }
   if(!g_risk.Init(InpMagic, _Symbol, &g_logger))
     { g_logger.Error("CRiskManager 初始化失败");  return INIT_FAILED; }
   // 注入风控模块，供 SyncWithReality 兜底路径回查盈亏后补风控统计
   g_posMgr.SetRiskManager(&g_risk);
   if(!g_executor.Init(_Symbol, InpMagic, GREA_SLIPPAGE_POINTS, &g_logger))
     { g_logger.Error("CTradeExecutor 初始化失败");  return INIT_FAILED; }

   //--- 5. 离线成交补账 —— 离线期间持仓被服务器平掉（周末跳空
   //    触发 SL 等）时 OnTradeTransaction 不会补发，需回查历史补记风控统计
   ReconcileOfflineDeals();

   //--- 6. 状态恢复：存量持仓 > 全局变量冷却 > IDLE
   //    检测到存量持仓时同时读回箱体上下沿快照（v1 §4.2 联动基准）
   g_posMgr.RestoreState();

   g_logger.Notify("EA 启动完成, 当前状态机就绪");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit：释放指标句柄 + 持久化状态                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_posMgr.SaveState();
   g_risk.SaveState();
   g_indicators.Release();
   g_logger.Info(StringFormat("EA 停止, reason=%d, 状态已持久化", reason));
  }

//+------------------------------------------------------------------+
//| OnTick：主流程调度（v1 §九流程图；检查顺序从最便宜到最贵）          |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- 每 Tick 开始失效持仓计数缓存（同一 Tick 内后续查询复用）
   g_posMgr.InvalidateCache();
   // 心跳全局变量（每 5 分钟写一次，供外部看门狗监控 EA 存活）
   g_posMgr.UpdateHeartbeat();

   //--- ① 交易环境校验（失败节流告警并返回）
   if(!g_market.IsTradingEnvironmentOK())
      return;

   //--- ② 风控周期复位（跨日/连亏暂停到期）与状态对账
   g_risk.CheckPeriodReset();
   g_posMgr.SyncWithReality();

   //--- ③ 信号周期新 K 线 → 刷新箱体（v1 §2.3；含高度/触碰/ADX 过滤）
   //    箱体按新 K 线刷新、入场条件逐 Tick 检查（决策记录 D1）
   if(g_market.IsNewBar(InpSignalTF))
      g_box.OnNewBar();

   //--- ④ 有持仓 → 仅执行持仓管理（熔断激活时同样只管理存量持仓）
   if(g_posMgr.HasPosition())
     {
      // CLOSING 态下持仓仍在（此前平仓失败）→ 本 Tick 继续尝试
      // 平仓直到成功，成交回报由 OnTradeTransaction 驱动进入冷却
      if(g_posMgr.State() == STATE_CLOSING)
        {
         g_executor.CloseMyPosition("CLOSING 态补偿重试");
         g_posMgr.InvalidateCache();       // 平仓动作后失效缓存防脏读
         return;
        }
      ManagePosition();
      return;
     }

   //--- ⑤ 熔断检查：日亏净额/连亏暂停激活时禁止开新仓（v1 §6.1/6.2）
   string haltReason;
   if(g_risk.IsHalted(haltReason))
     {
      g_logger.WarnThrottled("halt", "熔断激活, 禁止开仓: " + haltReason);
      if(g_posMgr.State() == STATE_OPENING)
         CancelPendingOpen("熔断激活");
      return;
     }

   //--- ⑤+ OPENING 态：Tick 驱动的下单重试，重试等待期间
   //       不重复评估信号
   if(g_posMgr.State() == STATE_OPENING)
     {
      RetryOpenPosition();
      return;
     }

   //--- ⑥ 时间制冷却：到期翻转 COOLING_DOWN → IDLE，未到期不开仓
   g_posMgr.UpdateCooldown();
   if(!g_posMgr.CanOpenNew())
      return;

   //--- ⑦ Tick 级入场评估：箱体三级漏斗（有效箱体 → 沿位 → KDJ）
   //    价格口径（与实际成交价一致，避免信号/成交偏差）：
   //    做多以 (Ask, Bid) 调用——入场侧 Ask（买单成交价）判内缘、对侧
   //    Bid 判外缘；做空以 (Bid, Ask) 调用——入场侧 Bid（卖单成交价）
   //    判内缘、对侧 Ask 判外缘。外缘对侧口径与突破联动止损一致（多单
   //    以 Bid 判破位），消除点差导致的开仓即秒平窗口（v1.10，评审
   //    问题1修复）；两个报价任一无效（≤0）则跳过本轮评估；箱体中部
   //    两次都在 L2 被廉价拒绝（§3.3）
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return;
   ENUM_SIGNAL_DIR sig = SIGNAL_NONE;
   if(g_box.EvaluateEntry(ask, bid) == SIGNAL_BUY)
      sig = SIGNAL_BUY;
   else if(g_box.EvaluateEntry(bid, ask) == SIGNAL_SELL)
      sig = SIGNAL_SELL;
   if(sig == SIGNAL_NONE)
      return;

   //--- ⑧ 盈亏比校验（v1 §5.3）：先于状态流转判定（评审修复 F4）——
   //    CheckMinRR 依赖箱体缓存，结果在一个箱体周期内恒定，先判不影响
   //    语义；不满足时节流记 WARN 并直接返回，不做状态流转（防 RR<1.2
   //    参数组合沿位徘徊期 SIGNAL_CONFIRMED→IDLE 每 Tick 两条日志风暴）
   if(!g_box.CheckMinRR())
     {
      double rr = (g_box.SlDist() > 0) ? g_box.TpDist() / g_box.SlDist() : 0.0;
      g_logger.WarnThrottled("rr",
                             StringFormat("开仓放弃: 盈亏比 %.2f < 最小 %.2f (v1 §5.3)",
                                          rr, InpMinRR),
                             300);
      return;
     }
   g_posMgr.SetState(STATE_SIGNAL_CONFIRMED);

   //--- ⑨ 点差过滤（安全网，0=关闭）
   if(!g_risk.SpreadOk())
     {
      g_posMgr.SetState(STATE_IDLE);
      return;
     }

   //--- ⑩ 计算手数/SL/TP 并执行开仓（保证金校验在 TryOpenPosition 内）
   TryOpenPosition(sig);
  }

//+------------------------------------------------------------------+
//| 开仓流程：固定手数 → 箱体止盈止损 → 保证金校验 → 下单              |
//|   （v1 §3.1/3.2 入场动作、§5.1/5.2 止盈止损、§八-4 每单必带 SL）  |
//+------------------------------------------------------------------+
void TryOpenPosition(const ENUM_SIGNAL_DIR sig)
  {
   //--- 固定手数（v1 §6.4：固定手数，禁动态调整；含品种步长归一化）
   double lots = g_risk.FixedLots();
   if(lots <= 0)
     {
      g_posMgr.SetState(STATE_IDLE);
      return;
     }

   bool   isBuy = (sig == SIGNAL_BUY);
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- 箱体止盈止损（v1 §5.1/5.2：TP 模式A比例/模式B对侧；SL 置箱体外侧）
   double sl = 0.0, tp = 0.0;
   if(!g_box.CalcStops(sig, entry, sl, tp))
     {
      g_logger.Warn("开仓放弃: 箱体止盈止损失败(无有效箱体)");
      g_posMgr.SetState(STATE_IDLE);
      return;
     }

   //--- 保证金校验（安全网）
   if(!g_risk.MarginOk(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lots, entry))
     {
      g_posMgr.SetState(STATE_IDLE);
      return;
     }

   //--- 下单（市价带 SL/TP；ValidateStops 停损距校验在执行器内完成，
   //    校验失败记 ERROR 并放弃，重试不缓存过期价格）
   g_posMgr.SetState(STATE_OPENING);
   if(g_executor.Open(sig, lots, sl, tp, "GREA"))
     {
      g_posMgr.InvalidateCache();          // 开仓成功后失效缓存防脏读
      g_posMgr.SetState(STATE_POSITION_OPEN);
      // 箱体上下沿快照写入持久化（v1 §4.2 突破联动基准，决策记录 D2：
      // 以开仓时箱体为基准，防逐K线漂移，重启可恢复）
      SBoxState box;
      if(g_box.GetBox(box))
         g_posMgr.SaveBoxSnapshot(box.upper, box.lower);
      else
         g_logger.Error("开仓成功但箱体快照获取失败, 突破联动将退化为当前缓存兜底");
      // 状态流转完成后立即持久化（评审修复 F7）：防 EA 异常终止后 GV
      // 停留旧值，导致离线止损成交不进入日亏统计（离线补账依赖
      // 已保存的 POSITION_OPEN 态判定回查窗口）
      g_posMgr.SaveState();
     }
   else if(g_executor.IsRetryPending())
     {
      // 可重试失败：登记待重试参数，保持 OPENING 由后续 Tick 继续
      g_pendingDir      = sig;
      g_pendingLots     = lots;
      g_pendingFirstTry = TimeCurrent();
     }
   else
     {
      // 不可重试/重试耗尽失败（含停损距校验失败）：记 ERROR 后回到待机
      g_posMgr.SetState(STATE_IDLE);
     }
  }

//+------------------------------------------------------------------+
//| OPENING 态：Tick 驱动的开仓重试（非阻塞，替代 Sleep 重试）         |
//|   重试时基于当前 Ask/Bid 与当前箱体缓存经 CalcStops 重算 SL/TP；   |
//|   重试等待期间箱体已失效（新K线刷新后过滤不再通过）→ 行情结构已变， |
//|   放弃重试；首次尝试后超时窗口内仍未成功则放弃回 IDLE 重走评估     |
//+------------------------------------------------------------------+
void RetryOpenPosition()
  {
   // 防御：仅 OPENING 态可执行重试/超时取消
   if(g_posMgr.State() != STATE_OPENING)
      return;
   if(g_pendingDir == SIGNAL_NONE || g_pendingLots <= 0)
     {
      // 无待重试参数（异常兜底，如重启后恢复到 OPENING）：回退待机
      g_executor.ResetRetry();
      g_posMgr.SetState(STATE_IDLE);
      return;
     }
   // 重试超时判定，超窗口后放弃本次信号（行情可能已走远）
   if(TimeCurrent() - g_pendingFirstTry > GREA_OPEN_RETRY_TIMEOUT_SEC)
     {
      CancelPendingOpen(StringFormat("重试超时(超过 %d 秒)", GREA_OPEN_RETRY_TIMEOUT_SEC));
      return;
     }
   // 箱体失效检查：等待重试期间箱体刷新后不再有效 → 放弃
   SBoxState box;
   if(!g_box.GetBox(box))
     {
      CancelPendingOpen("等待重试期间箱体已失效");
      return;
     }
   // 基于当前价重算 SL/TP（手数不变故风险不变）
   bool   isBuy = (g_pendingDir == SIGNAL_BUY);
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0, tp = 0.0;
   if(!g_box.CalcStops(g_pendingDir, entry, sl, tp))
     {
      CancelPendingOpen("重试重算止盈止损失败");
      return;
     }
   if(g_executor.Open(g_pendingDir, g_pendingLots, sl, tp, "GREA"))
     {
      g_posMgr.InvalidateCache();          // 开仓成功后失效缓存防脏读
      if(g_box.GetBox(box))
         g_posMgr.SaveBoxSnapshot(box.upper, box.lower);
      ClearPendingOpen();
      g_posMgr.SetState(STATE_POSITION_OPEN);
      // 状态流转完成后立即持久化（评审修复 F7，与 TryOpenPosition
      // 成功路径对齐）：防异常终止后 GV 停留旧值漏记离线止损盈亏
      g_posMgr.SaveState();
      return;
     }
   if(!g_executor.IsRetryPending())
     {
      // 重试耗尽或不可重试：放弃并回退 IDLE
      ClearPendingOpen();
      g_posMgr.SetState(STATE_IDLE);
     }
   // 仍在重试窗口内：保持 OPENING，等待下一 Tick
  }

//+------------------------------------------------------------------+
//| 清除待重试开仓参数                                                |
//+------------------------------------------------------------------+
void ClearPendingOpen()
  {
   g_pendingDir      = SIGNAL_NONE;
   g_pendingLots     = 0.0;
   g_pendingFirstTry = 0;
  }

//+------------------------------------------------------------------+
//| 取消待重试开仓并回退状态机（熔断激活时调用）                       |
//+------------------------------------------------------------------+
void CancelPendingOpen(const string reason)
  {
   g_logger.Warn("放弃待重试开仓: " + reason);
   g_executor.ResetRetry();
   ClearPendingOpen();
   g_posMgr.SetState(STATE_IDLE);
  }

//+------------------------------------------------------------------+
//| 持仓管理（Tick 级，v1 §九流程 5）：                                |
//|   ① 突破止损联动（§4.2，Tick 级实时）：多单 Bid 跌破快照下沿−     |
//|      突破点数 / 空单 Ask 涨破快照上沿+突破点数 → 立即平仓          |
//|   ② 时间止损（§5.4）：持仓超 InpMaxHoldHours 小时 → 市价平仓       |
//|   TP/SL 均为服务器端挂单执行，不轮询（§5.1/5.2）                    |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   CPositionInfo pos;
   if(!g_posMgr.SelectMyPosition(pos))
      return;

   bool   isBuy = (pos.PositionType() == POSITION_TYPE_BUY);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   //--- ① 突破止损联动：以开仓时持久化的箱体快照为基准（决策记录 D2）
   double upper = 0.0, lower = 0.0;
   bool   hasSnap = g_posMgr.BoxSnapshot(upper, lower);
   if(!hasSnap)
     {
      // 快照缺失（异常，如持久化变量被清）：记 ERROR 并按当前箱体缓存兜底
      LogBoxSnapMissing();
      SBoxState box;
      hasSnap = g_box.GetBox(box);
      if(hasSnap)
        {
         upper = box.upper;
         lower = box.lower;
        }
     }
   if(hasSnap)
     {
      double brkDist = PtsToPrice(InpBreakoutPoints);
      if(isBuy && bid < lower - brkDist)
        {
         ClosePosition(StringFormat("箱体下破突破止损联动: Bid=%.2f < 快照下沿%.2f−%d点(§4.2)",
                                    bid, lower, InpBreakoutPoints));
         return;
        }
      if(!isBuy && ask > upper + brkDist)
        {
         ClosePosition(StringFormat("箱体上破突破止损联动: Ask=%.2f > 快照上沿%.2f+%d点(§4.2)",
                                    ask, upper, InpBreakoutPoints));
         return;
        }
     }

   //--- ② 时间止损（v1 §5.4，可选）：超时仍未触发止盈止损 → 市价平仓离场
   //    InpMaxHoldHours=0 视为禁用该功能（防误配置导致持仓秒平）
   if(InpMaxHoldHours > 0)
     {
      long heldSec = (long)(TimeCurrent() - pos.Time());
      if(heldSec > (long)InpMaxHoldHours * 3600)
         ClosePosition(StringFormat("时间止损: 持仓 %.1f 小时 > %d 小时(§5.4)",
                                    heldSec / 3600.0, InpMaxHoldHours));
     }
  }

//+------------------------------------------------------------------+
//| 平仓辅助：进 CLOSING 态 → 市价平仓（失败时后续 Tick 在 CLOSING     |
//| 态补偿重试）→ 失效缓存；成交回报由 OnTradeTransaction 驱动冷却      |
//+------------------------------------------------------------------+
void ClosePosition(const string reason)
  {
   g_posMgr.SetState(STATE_CLOSING);
   g_executor.CloseMyPosition(reason);
   g_posMgr.InvalidateCache();
  }

//+------------------------------------------------------------------+
//| 箱体快照缺失告警（节流 ERROR：300 秒最多一条，防 Tick 级刷屏）     |
//+------------------------------------------------------------------+
void LogBoxSnapMissing()
  {
   if(TimeCurrent() - g_lastSnapErrTime >= 300)
     {
      g_lastSnapErrTime = TimeCurrent();
      g_logger.Error("箱体快照缺失(持久化变量被清?), 突破联动退化为当前箱体缓存兜底");
     }
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction：成交回报驱动状态机流转                         |
//|   捕获 DEAL_ADD 且 DEAL_ENTRY_OUT 的平仓成交：                     |
//|   记录单笔盈亏(利润+隔夜费+佣金) → 风控统计(日净额/连亏) → 冷却时间戳|
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   //--- 只关心新增成交
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   //--- 先按单笔过滤（评审修复 F8）：HistoryDealSelect 精选单笔代价低，
   //    magic+symbol 不匹配直接返回——双 EA 共存时对方每笔成交不再
   //    触发下方全量历史枚举
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   //--- 匹配本 EA 后再做全量历史加载：后续入账依赖完整历史上下文
   //    （+3600 冗余覆盖服务器时钟偏差）
   if(!HistorySelect(0, TimeCurrent() + 3600))
      return;
   //--- 本 EA 的成交必然改变持仓状态，失效持仓计数缓存
   g_posMgr.InvalidateCache();
   //--- 只处理平仓方向的成交（DEAL_ENTRY_OUT）
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   //--- 防重复入账 —— SyncWithReality 兜底补账可能已先行入账该成交
   //    （成交 ticket 服务器端递增，<= 最后已入账 ticket 即已处理过；
   //    同一 ticket 重复推送时 deal == last 恰被 <= 拦截，改成 < 会放行
   //    重复入账，勿改）
   if(trans.deal <= g_risk.LastDealTicket())
      return;

   //--- 单笔盈亏 = 利润 + 隔夜费 + 佣金
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_logger.Info(StringFormat("平仓成交回报: deal=%I64u 盈亏=%.2f", trans.deal, profit));

   //--- 风控统计（日净额累计/连亏计数/熔断判定），传入 deal ticket
   //    登记为最后已入账成交，供离线补账去重
   g_risk.OnTradeResult(profit, trans.deal);
   //--- 状态机：平仓结算 → 时间制冷却（记录平仓时间戳）
   g_posMgr.OnPositionClosed(profit);
  }

//+------------------------------------------------------------------+
//| 离线成交补账（OnInit 中、RestoreState 前调用）                    |
//|   EA 离线期间（如周末跳空触发 SL）持仓被服务器平掉时，重启后     |
//|   OnTradeTransaction 不会触发，日亏净额与连亏统计会遗漏。          |
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
      from = TimeCurrent() - GREA_RECONCILE_LOOKBACK_SEC;
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
      //--- 单笔盈亏口径与 OnTradeTransaction 一致
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
//| OnTester：自定义复合优化指标                                       |
//|   适应度 = ProfitFactor × sqrt(总交易数) ÷ max(最大相对回撤%, 1)   |
//|   奖励高利润因子与充足样本量、惩罚深回撤；无交易/异常返回 0         |
//|   回测观察要点见 v1 §十-2（震荡段胜率/趋势段零开仓/最大回撤）       |
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
   //--- 最大相对回撤%（按净值），下限 1 防除零与极小回撤刺高适应度
   double ddRel = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   return pf * MathSqrt(trades) / MathMax(ddRel, 1.0);
  }
//+------------------------------------------------------------------+
