//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|  模块职责：风控模块 —— 单笔风险百分比反推手数、日/周亏损熔断、      |
//|            最大连亏暂停、点差过滤、周五离场检查、保证金校验         |
//|  对应方案文档：第 5 章（资金管理与风控设计）、6.6 节（盈亏统计与    |
//|               状态持久化）                                          |
//+------------------------------------------------------------------+
#ifndef __GTEA_RISKMANAGER_MQH__
#define __GTEA_RISKMANAGER_MQH__

#include <GoldTrendEA/Config.mqh>
#include <GoldTrendEA/Logger.mqh>

//+------------------------------------------------------------------+
//| CRiskManager：资金管理与熔断风控                                    |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   string            m_symbol;
   long              m_magic;              // 修复一：持久化命名空间需要 magic
   CLogger          *m_logger;

   //--- 熔断状态（全部持久化到全局变量，方案 5.2）
   double            m_dailyBaseEquity;    // 当日风控基数（当日首次交易前净值快照）
   double            m_weeklyBaseEquity;   // 本周风控基数
   double            m_dailyLoss;          // 当日已实现亏损（正数表示亏损额）
   double            m_weeklyLoss;         // 本周已实现亏损
   int               m_consecLosses;       // 当前连亏笔数
   datetime          m_pauseUntil;         // 连亏暂停截止时间（0=未暂停）
   int               m_lastResetDay;       // 上次日复位的"天"标识
   int               m_lastResetWeek;      // 上次周复位的"周"标识
   string            m_gvPrefix;           // 修复一：实例级持久化前缀 magic+symbol

   //--- 修复一：改用 magic+symbol 实例级前缀，避免多图表同 magic 挂载时
   //    风控统计（日/周亏损、连亏计数）跨品种污染
   string            GVName(const string suffix) { return m_gvPrefix + "RISK_" + suffix; }

   //--- 当前服务器时间结构
   void              NowStruct(MqlDateTime &dt) { TimeToStruct(TimeCurrent(), dt); }

public:
                     CRiskManager() : m_symbol(""), m_magic(0), m_logger(NULL),
                                      m_dailyBaseEquity(0), m_weeklyBaseEquity(0),
                                      m_dailyLoss(0), m_weeklyLoss(0),
                                      m_consecLosses(0), m_pauseUntil(0),
                                      m_lastResetDay(-1), m_lastResetWeek(-1),
                                      m_gvPrefix("") {}
                    ~CRiskManager() {}

   //--- 初始化：绑定 magic/品种/日志并恢复持久化的熔断状态
   //    修复一：新增 magic 入参，生成实例级前缀后再 LoadState
   bool              Init(const long magic, const string symbol, CLogger *logger)
     {
      m_magic  = magic;
      m_symbol = symbol;
      m_logger = logger;
      m_gvPrefix = "GTEA_" + (string)m_magic + "_" + m_symbol + "_";
      LoadState();
      return (m_magic != 0 && m_symbol != "" && m_logger != NULL);
     }

   //=== 手数计算（方案 5.1 固定分数法，真实公式代码）===================

   //--- 按单笔风险百分比 + 止损距离反推手数
   //    返回值 <=0 表示放弃开仓（资金相对止损过小/参数异常），已记 WARN
   double            CalcLots(const double entryPrice, const double slPrice)
     {
      double slDistance = MathAbs(entryPrice - slPrice);
      if(slDistance <= 0)
        {
         m_logger.Warn("手数计算: 止损距离非法, 放弃开仓");
         return 0.0;
        }
      double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney  = equity * InpRiskPercent / 100.0;

      // 用 TickValue/TickSize 动态换算，兼容黄金与外汇对、不同账户货币（方案 5.1）
      double tickSize   = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0 || tickValue <= 0)
        {
         m_logger.Warn("手数计算: TickSize/TickValue 异常");
         return 0.0;
        }
      double lossPerLot = slDistance / tickSize * tickValue;   // 每手止损亏损（账户货币）
      if(lossPerLot <= 0)
         return 0.0;
      double lots = riskMoney / lossPerLot;

      // 向下取整到 LotStep，保证实际风险 <= 设定风险
      double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double lotMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double lotMax  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      if(lotStep > 0)
         lots = MathFloor(lots / lotStep) * lotStep;
      lots = MathMin(lots, MathMin(lotMax, InpMaxLots));

      // 计算手数 < 最小手数 → 放弃本次开仓而非超风险强开（方案 5.1）
      if(lots < lotMin)
        {
         m_logger.Warn(StringFormat("手数计算: 计算手数 %.2f < 最小手数 %.2f, 放弃开仓(资金相对止损过小)",
                                    lots, lotMin));
         return 0.0;
        }
      return NormalizeDouble(lots, 2);
     }

   //--- 保证金校验：开仓占用 <= 可用保证金的 50%（方案 5.1）
   bool              MarginOk(const ENUM_ORDER_TYPE type, const double lots, const double price)
     {
      double marginNeed = 0.0;
      if(!OrderCalcMargin(type, m_symbol, lots, price, marginNeed))
        {
         m_logger.Warn("保证金校验: OrderCalcMargin 失败, err=" + (string)GetLastError());
         return false;
        }
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(marginNeed > freeMargin * 0.5)
        {
         m_logger.Warn(StringFormat("保证金校验: 需 %.2f > 可用 %.2f 的50%%, 放弃开仓",
                                    marginNeed, freeMargin));
         return false;
        }
      return true;
     }

   //=== 熔断矩阵（方案 5.2）===========================================

   //--- 熔断总裁决：任一熔断激活返回 true（禁止开新仓），reason 输出原因
   bool              IsHalted(string &reason)
     {
      double equityBase = (m_dailyBaseEquity > 0) ? m_dailyBaseEquity
                                                  : AccountInfoDouble(ACCOUNT_EQUITY);
      // 日亏损熔断：当日已实现亏损 >= 净值基数 × InpDailyLossPct%
      if(m_dailyLoss >= equityBase * InpDailyLossPct / 100.0 && m_dailyLoss > 0)
        {
         reason = StringFormat("日亏损熔断(已亏 %.2f)", m_dailyLoss);
         return true;
        }
      // 周亏损熔断
      double weekBase = (m_weeklyBaseEquity > 0) ? m_weeklyBaseEquity : equityBase;
      if(m_weeklyLoss >= weekBase * InpWeeklyLossPct / 100.0 && m_weeklyLoss > 0)
        {
         reason = StringFormat("周亏损熔断(已亏 %.2f)", m_weeklyLoss);
         return true;
        }
      // 连亏暂停：连续亏损 >= InpMaxConsecLoss 笔 → 暂停 24 小时
      if(m_pauseUntil > 0 && TimeCurrent() < m_pauseUntil)
        {
         reason = StringFormat("连亏暂停中(至 %s)", TimeToString(m_pauseUntil));
         return true;
        }
      // 新闻时段过滤（可选，方案 5.2）
      if(InpNewsFilter && IsNewsBlackout())
        {
         reason = "重大新闻时段过滤";
         return true;
        }
      return false;
     }

   //--- 点差过滤：当前点差 > 阈值时放弃本次信号（方案 5.2）
   bool              SpreadOk()
     {
      long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
        {
         m_logger.Warn(StringFormat("点差过滤: 当前 %d 点 > 阈值 %d 点, 放弃信号",
                                    spread, InpMaxSpreadPoints));
         return false;
        }
      return true;
     }

   //--- 周五离场检查：周五 >= InpFridayCloseHour（服务器时）应平仓且停开（方案 5.2）
   bool              IsFridayCloseTime()
     {
      if(!InpFridayClose)
         return false;
      MqlDateTime dt;
      NowStruct(dt);
      return (dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour);
     }

   //--- 新闻时段判定（可选 P2 功能）
   bool              IsNewsBlackout()
     {
      // TODO(P2, 方案 5.2)：手工维护时间表（非农/CPI/FOMC 前后30分钟）
      //      或接入经济日历；框架阶段恒返回 false
      return false;
     }

   //=== 盈亏统计与周期复位（方案 5.2 / 6.6）===========================

   //--- 成交回报回调：由 OnTradeTransaction 的 DEAL_ENTRY_OUT 驱动
   //    profit 应为 DEAL_PROFIT + DEAL_SWAP + DEAL_COMMISSION 之和
   void              OnTradeResult(const double profit)
     {
      if(profit < 0)
        {
         m_dailyLoss  += -profit;
         m_weeklyLoss += -profit;
         m_consecLosses++;
         if(m_consecLosses >= InpMaxConsecLoss)
           {
            m_pauseUntil = TimeCurrent() + 24 * 3600;   // 暂停 24 小时
            m_logger.Notify(StringFormat("连亏 %d 笔, 暂停开仓至 %s",
                                         m_consecLosses, TimeToString(m_pauseUntil)));
           }
        }
      else
        {
         m_consecLosses = 0;               // 盈利单清零连亏计数
        }
      string reason;
      if(IsHalted(reason))
         m_logger.Notify("熔断触发: " + reason);
      SaveState();
     }

   //--- 周期复位检查：每 Tick 轻量调用；跨日/跨周时复位统计并快照基数
   //    （方案 5.2：基数在每日/每周首次交易前快照，熔断次日/下周一自动复位）
   void              CheckPeriodReset()
     {
      MqlDateTime dt;
      NowStruct(dt);
      // 跨日复位（服务器时间 0 点后首个 Tick）
      if(dt.day != m_lastResetDay)
        {
         m_lastResetDay    = dt.day;
         m_dailyLoss       = 0.0;
         m_dailyBaseEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_logger.Info(StringFormat("日风控复位: 基数净值=%.2f", m_dailyBaseEquity));
         SaveState();
        }
      // 跨周复位（ISO 周变化，简化用"周一"检测）
      int weekId = (int)(TimeCurrent() / (7 * 24 * 3600));
      if(dt.day_of_week == 1 && weekId != m_lastResetWeek)
        {
         m_lastResetWeek    = weekId;
         m_weeklyLoss       = 0.0;
         m_weeklyBaseEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_logger.Info(StringFormat("周风控复位: 基数净值=%.2f", m_weeklyBaseEquity));
         SaveState();
        }
     }

   //=== 状态持久化（方案 6.6：写全局变量，重启不丢失）==================

   void              SaveState()
     {
      GlobalVariableSet(GVName("DAILY_LOSS"),   m_dailyLoss);
      GlobalVariableSet(GVName("WEEKLY_LOSS"),  m_weeklyLoss);
      GlobalVariableSet(GVName("DAILY_BASE"),   m_dailyBaseEquity);
      GlobalVariableSet(GVName("WEEKLY_BASE"),  m_weeklyBaseEquity);
      GlobalVariableSet(GVName("CONSEC_LOSS"),  (double)m_consecLosses);
      GlobalVariableSet(GVName("PAUSE_UNTIL"),  (double)m_pauseUntil);
      GlobalVariableSet(GVName("RESET_DAY"),    (double)m_lastResetDay);
      GlobalVariableSet(GVName("RESET_WEEK"),   (double)m_lastResetWeek);
     }

   void              LoadState()
     {
      if(GlobalVariableCheck(GVName("DAILY_LOSS")))   m_dailyLoss       = GlobalVariableGet(GVName("DAILY_LOSS"));
      if(GlobalVariableCheck(GVName("WEEKLY_LOSS")))  m_weeklyLoss      = GlobalVariableGet(GVName("WEEKLY_LOSS"));
      if(GlobalVariableCheck(GVName("DAILY_BASE")))   m_dailyBaseEquity = GlobalVariableGet(GVName("DAILY_BASE"));
      if(GlobalVariableCheck(GVName("WEEKLY_BASE")))  m_weeklyBaseEquity= GlobalVariableGet(GVName("WEEKLY_BASE"));
      if(GlobalVariableCheck(GVName("CONSEC_LOSS")))  m_consecLosses    = (int)GlobalVariableGet(GVName("CONSEC_LOSS"));
      if(GlobalVariableCheck(GVName("PAUSE_UNTIL")))  m_pauseUntil      = (datetime)GlobalVariableGet(GVName("PAUSE_UNTIL"));
      if(GlobalVariableCheck(GVName("RESET_DAY")))    m_lastResetDay    = (int)GlobalVariableGet(GVName("RESET_DAY"));
      if(GlobalVariableCheck(GVName("RESET_WEEK")))   m_lastResetWeek   = (int)GlobalVariableGet(GVName("RESET_WEEK"));
     }
  };

#endif // __GTEA_RISKMANAGER_MQH__
