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
#property version   "0.10"
#property description "顺势一单一结 EA 框架：H4趋势+H1三重过滤，同一时刻最多1单"
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
ENUM_SIGNAL_DIR   g_pendingDir  = SIGNAL_NONE;
double            g_pendingLots = 0.0;
double            g_pendingSL   = 0.0;
double            g_pendingTP   = 0.0;

//+------------------------------------------------------------------+
//| OnInit：环境校验 → 模块初始化与依赖注入 → 状态恢复                 |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- 1. 日志模块最先初始化（其余模块依赖它）
   if(!g_logger.Init(InpMagic))
      return INIT_FAILED;
   g_logger.Info("========== GoldTrendEA v0.10 初始化 ==========");
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
   if(!g_executor.Init(_Symbol, InpMagic, InpSlippagePoints, &g_logger))
     { g_logger.Error("CTradeExecutor 初始化失败");  return INIT_FAILED; }

   //--- 5. 状态恢复：存量持仓 > 全局变量冷却 > IDLE（方案 4.3 / 8.2）
   g_posMgr.RestoreState();

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
         g_executor.CloseMyPosition("周五收盘离场");
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
   ENUM_SIGNAL_DIR sig = g_signal.Evaluate();
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
   // TODO(M2, 方案 4.4)：结构点止损候选 —— 取 SwingLow/SwingHigh 外加缓冲，
   //      与 ATR 距离取 max：
   //      double swing;  if(isBuy && g_indicators.SwingLow(swing, InpSwingBars))
   //          slDist = MathMax(slDistAtr, entry - swing + 缓冲);
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
      g_posMgr.SetState(STATE_POSITION_OPEN);
      // TODO(M3)：将初始止损距离持久化(全局变量)，供保本推损计算使用
     }
   else if(g_executor.IsRetryPending())
     {
      // 可重试失败：登记待重试参数，保持 OPENING 由后续 Tick 继续（修复三）
      g_pendingDir  = sig;
      g_pendingLots = lots;
      g_pendingSL   = sl;
      g_pendingTP   = tp;
     }
   else
     {
      // 不可重试/重试耗尽失败：记 ERROR 后回到待机（方案 4.3 状态图 OPENING→IDLE）
      g_posMgr.SetState(STATE_IDLE);
     }
  }

//+------------------------------------------------------------------+
//| OPENING 态：Tick 驱动的开仓重试（修复三，替代阻塞式 Sleep 重试）  |
//+------------------------------------------------------------------+
void RetryOpenPosition()
  {
   if(g_pendingDir == SIGNAL_NONE)
     {
      // 无待重试参数（异常兜底，如重启后恢复到 OPENING）：回退待机
      g_executor.ResetRetry();
      g_posMgr.SetState(STATE_IDLE);
      return;
     }
   if(g_executor.Open(g_pendingDir, g_pendingLots, g_pendingSL, g_pendingTP, "GTEA"))
     {
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
   g_pendingDir  = SIGNAL_NONE;
   g_pendingLots = 0.0;
   g_pendingSL   = 0.0;
   g_pendingTP   = 0.0;
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
//| 持仓管理：保本推损 / ATR 跟踪 / 趋势反转离场（方案 4.4）           |
//|   Tick 级：保本推损（对触发价敏感）                                |
//|   新K线级：ATR 跟踪止损、趋势反转检测（方案 N05 性能要求）         |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   CPositionInfo pos;
   if(!g_posMgr.SelectMyPosition(pos))
      return;

   //--- Tick 级：保本推损（骨架接口，M3 实现）
   g_executor.ApplyBreakEven(pos);

   //--- 新 K 线级：ATR 跟踪 + 反转离场
   if(g_market.IsNewBar(InpSignalTF))
     {
      double atr = 0.0;
      if(g_indicators.AtrSig(atr) && atr > 0)
         g_executor.ApplyAtrTrailing(pos, atr);

      //--- 趋势反转强制离场（方案 4.4）
      int posDir = (pos.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
      if(g_signal.IsTrendReversed(posDir))
        {
         g_posMgr.SetState(STATE_CLOSING);
         g_executor.CloseMyPosition("趋势反转强制离场");
        }
     }
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
   //--- 选中成交单获取详情
   if(!HistoryDealSelect(trans.deal))
      return;
   //--- 过滤：本 EA（magic）+ 本品种
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   //--- 只处理平仓方向的成交（DEAL_ENTRY_OUT，方案 6.6）
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   //--- 单笔盈亏 = 利润 + 隔夜费 + 佣金（方案 6.6）
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_logger.Info(StringFormat("平仓成交回报: deal=%I64u 盈亏=%.2f", trans.deal, profit));

   //--- 风控统计（连亏计数/日周亏损累计/熔断判定）
   g_risk.OnTradeResult(profit);
   //--- 状态机：平仓结算 → 冷却期（方案 4.3）
   g_posMgr.OnPositionClosed(profit);
  }
//+------------------------------------------------------------------+
