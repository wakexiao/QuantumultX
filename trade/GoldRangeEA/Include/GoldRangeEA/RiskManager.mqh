//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|  模块职责：风控模块 —— 固定手数归一化、日亏损净额熔断（美元）、      |
//|            最大连亏暂停、点差过滤、保证金校验                       |
//|  与模板差异：日亏损由「净值百分比」改为「绝对美元净额」（v1 §6.1，   |
//|            盈利单抵扣、负值累计）；连亏暂停改参数化分钟（§6.2）；   |
//|            删除周百分比熔断/周五离场/新闻过滤/风险百分比反推手数路径|
//|            （v1 §6.4 固定手数）                                    |
//|  对应需求文档 v1.md：§5.3（盈亏比）、§6.1（日亏损）、§6.2（连亏）、 |
//|               §6.4（手数控制）、§八-5（禁动态手数）                 |
//+------------------------------------------------------------------+
#ifndef __GREA_RISKMANAGER_MQH__
#define __GREA_RISKMANAGER_MQH__

#include <GoldRangeEA/Config.mqh>
#include <GoldRangeEA/Logger.mqh>

//+------------------------------------------------------------------+
//| CRiskManager：固定手数与熔断风控                                    |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   string            m_symbol;
   long              m_magic;              // 持久化命名空间需要 magic
   CLogger          *m_logger;

   //--- 熔断状态（全部持久化到全局变量）
   double            m_dailyNet;           // 当日已平仓单盈亏净额（正=净盈/负=净亏，v1 §6.1）
   int               m_consecLosses;       // 当前连亏笔数（盈利单清零，v1 §6.2）
   datetime          m_pauseUntil;         // 连亏暂停截止时间（0=未暂停，v1 §6.2）
   int               m_lastResetDay;       // 上次日复位的"天"标识
   ulong             m_lastDealTicket;     // 最后已入账平仓成交 ticket（离线补账防重复）
   string            m_gvPrefix;           // 实例级持久化前缀 magic+symbol
   bool              m_gvNameWarned;       // 全局变量名超长只告警一次（防刷屏）

   //--- magic+symbol 实例级前缀，避免多图表同 magic 挂载时风控统计
   //    （日亏净额、连亏计数）跨品种污染；超 63 字符会被终端截断
   string            GVName(const string suffix)
     {
      string name = m_gvPrefix + "RISK_" + suffix;
      if(StringLen(name) > GREA_GV_NAME_MAX && !m_gvNameWarned)
        {
         m_gvNameWarned = true;
         m_logger.Error(StringFormat("全局变量名超长(%d>%d): %s, 将被终端截断, 请缩短 magic/品种组合",
                                     StringLen(name), GREA_GV_NAME_MAX, name));
        }
      return name;
     }

   //--- 当前服务器时间结构
   void              NowStruct(MqlDateTime &dt) { TimeToStruct(TimeCurrent(), dt); }

   //--- LAST_DEAL 冷启动初始化 —— 首次运行/换命名空间后无持久化记录时，
   //    从历史成交（本 magic+品种）回查最大 deal ticket 作为入账基准，
   //    避免首日离线补账/兜底补账误把历史旧成交记入当日风控统计
   void              InitLastDealFromHistory()
     {
      if(!HistorySelect(0, TimeCurrent() + 60))
        {
         m_logger.Warn("冷启动: HistorySelect 失败, LAST_DEAL 基准未初始化, 补账路径可能误记历史成交");
         return;
        }
      ulong maxTicket = 0;
      int   total     = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0 || deal <= maxTicket)
            continue;
         if(HistoryDealGetInteger(deal, DEAL_MAGIC) != m_magic)
            continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != m_symbol)
            continue;
         maxTicket = deal;
        }
      if(maxTicket > 0)
        {
         m_lastDealTicket = maxTicket;
         SaveState();
         m_logger.Info(StringFormat("冷启动: LAST_DEAL 无持久化记录, 按历史成交初始化入账基准 ticket=%I64u", maxTicket));
        }
     }

public:
                     CRiskManager() : m_symbol(""), m_magic(0), m_logger(NULL),
                                      m_dailyNet(0), m_consecLosses(0), m_pauseUntil(0),
                                      m_lastResetDay(-1),
                                      m_lastDealTicket(0), m_gvPrefix(""),
                                      m_gvNameWarned(false) {}
                    ~CRiskManager() {}

   //--- 初始化：绑定 magic/品种/日志并恢复持久化的熔断状态
   bool              Init(const long magic, const string symbol, CLogger *logger)
     {
      m_magic  = magic;
      m_symbol = symbol;
      m_logger = logger;
      m_gvPrefix = "GREA_" + (string)m_magic + "_" + m_symbol + "_";
      LoadState();
      // LAST_DEAL 全局变量不存在（冷启动）时从历史成交初始化入账基准
      if(!GlobalVariableCheck(GVName("LAST_DEAL")))
         InitLastDealFromHistory();
      return (m_magic != 0 && m_symbol != "" && m_logger != NULL);
     }

   //=== 手数（v1 §6.4 固定手数控制）===================================

   //--- 固定手数归一化：返回 InpFixedLots 按 SYMBOL_VOLUME_MIN/MAX/STEP
   //    规范化后的手数；失败（参数非法/低于最小手数）记 ERROR 返回 0。
   //    注：模板 CalcLots 的「风险百分比反推手数」路径已按 v1 §6.4 +
   //    §八-5（禁止根据浮亏/盈利动态调整手数）整体删除，本函数仅保留
   //    其中的步长/小数位归一化处理；不做任何余额相关计算
   double            FixedLots()
     {
      double lots    = InpFixedLots;
      if(lots <= 0)
        {
         m_logger.Error(StringFormat("固定手数非法: %.2f ≤ 0, 放弃开仓", InpFixedLots));
         return 0.0;
        }
      double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double lotMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double lotMax  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);

      // 向下对齐到步长（保证不超参数手数），并夹到交易所允许范围
      if(lotStep > 0)
         lots = MathFloor(lots / lotStep) * lotStep;
      lots = MathMin(lots, lotMax);
      if(lots < lotMin)
        {
         m_logger.Error(StringFormat("固定手数 %.2f 归一化后 %.2f < 最小手数 %.2f, 放弃开仓",
                                     InpFixedLots, lots, lotMin));
         return 0.0;
        }
      if(MathAbs(lots - InpFixedLots) > 1e-8)
         m_logger.Warn(StringFormat("固定手数 %.2f 已按品种步长归一化为 %.2f", InpFixedLots, lots));

      // 按 VOLUME_STEP 动态计算手数小数位（lotStep=0.01→2位、0.1→1位、
      // 1→0位），lotStep 异常时回退默认 2 位
      int lotDigits = 2;
      if(lotStep > 0)
        {
         double digitsRaw = -MathLog10(lotStep);
         if(MathIsValidNumber(digitsRaw) && digitsRaw >= 0 && digitsRaw <= 8)
            lotDigits = (int)MathRound(digitsRaw);
        }
      return NormalizeDouble(lots, lotDigits);
     }

   //--- 保证金校验：开仓占用 <= 可用保证金的 GREA_MAX_MARGIN_USE_PCT%
   bool              MarginOk(const ENUM_ORDER_TYPE type, const double lots, const double price)
     {
      double marginNeed = 0.0;
      if(!OrderCalcMargin(type, m_symbol, lots, price, marginNeed))
        {
         m_logger.Warn("保证金校验: OrderCalcMargin 失败, err=" + (string)GetLastError());
         return false;
        }
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(marginNeed > freeMargin * GREA_MAX_MARGIN_USE_PCT / 100.0)
        {
         m_logger.Warn(StringFormat("保证金校验: 需 %.2f > 可用 %.2f 的%.0f%%, 放弃开仓",
                                    marginNeed, freeMargin, GREA_MAX_MARGIN_USE_PCT));
         return false;
        }
      return true;
     }

   //=== 熔断矩阵（v1 §6.1 / §6.2）====================================

   //--- 熔断总裁决：任一熔断激活返回 true（禁止开新仓），reason 输出原因
   //    日亏损口径为「净额」：当日已平仓单盈亏之和 ≤ −阈值 触发，
   //    盈利单抵扣亏损单（v1 §6.1「当日所有已平仓订单的盈亏之和」）
   bool              IsHalted(string &reason)
     {
      if(m_dailyNet <= -InpMaxDailyLossUSD)
        {
         reason = StringFormat("日亏损熔断(当日净亏 %.2f ≥ %.2f 美元, 次日恢复)",
                               -m_dailyNet, InpMaxDailyLossUSD);
         return true;
        }
      if(m_pauseUntil > 0 && TimeCurrent() < m_pauseUntil)
        {
         reason = StringFormat("连亏暂停中(至 %s)", TimeToString(m_pauseUntil));
         return true;
        }
      return false;
     }

   //--- 点差过滤（安全网，v1 规格外保护）：当前点差 > 阈值时放弃本次信号；
   //    InpMaxSpreadPoints=0 表示关闭过滤（直通）。
   //    口径统一（评审修复 F1）：参数按 1 点=0.01 美元（GREA_POINT_VALUE）解释，
   //    而 SYMBOL_SPREAD 的单位是经纪商原生点（SYMBOL_POINT），3 位小数报价上
   //    0.20 美元点差=200 原生点，直接数值比较会恒拒单致 EA 永不交易；
   //    故改用 Ask-Bid 价格差与 PtsToPrice(阈值) 比较，两种报价精度语义一致
   bool              SpreadOk()
     {
      if(InpMaxSpreadPoints <= 0)
         return true;
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(ask <= 0 || bid <= 0)
         return true;                     // 报价异常不拦截，后续流程自会失败
      double spread = ask - bid;
      if(spread > PtsToPrice(InpMaxSpreadPoints))
        {
         m_logger.WarnThrottled("spread",
                                StringFormat("点差过滤: 当前 %.1f 点 > 阈值 %d 点, 放弃信号",
                                             spread / GREA_POINT_VALUE, InpMaxSpreadPoints),
                                60);
         return false;
        }
      return true;
     }

   //=== 盈亏统计与周期复位 ============================================

   //--- 成交回报回调：由 OnTradeTransaction 的 DEAL_ENTRY_OUT 驱动，
   //    离线补账时也由主 EA 回查历史后补调
   //    profit 应为 DEAL_PROFIT + DEAL_SWAP + DEAL_COMMISSION 之和；
   //    dealTicket 非 0 时登记为最后已入账成交，供离线补账防重复
   void              OnTradeResult(const double profit, const ulong dealTicket = 0)
     {
      if(dealTicket > 0 && dealTicket > m_lastDealTicket)
         m_lastDealTicket = dealTicket;
      // 日净额累计（正负相抵，v1 §6.1 净额口径）
      m_dailyNet += profit;
      if(profit < 0)
        {
         // 连亏计数：仅亏损单计数，盈利单清零（v1 §6.2）
         m_consecLosses++;
         if(m_consecLosses >= InpMaxConsecSL)
           {
            m_pauseUntil = TimeCurrent() + (datetime)(InpPauseMinutes * 60);   // 暂停 N 分钟
            m_logger.Notify(StringFormat("连续止损 %d 笔, 暂停开仓 %d 分钟(至 %s)",
                                         m_consecLosses, InpPauseMinutes, TimeToString(m_pauseUntil)));
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

   //--- 最后已入账平仓成交 ticket（离线补账去重用，只读）
   ulong             LastDealTicket() const { return m_lastDealTicket; }

   //--- 周期复位检查：每 Tick 轻量调用
   //    连亏暂停到期 → 清零连亏计数并恢复开仓评估（同步持久化，
   //    否则恢复后首笔亏损会基于旧计数立即再次触发暂停）；
   //    跨日 → 日净额归零（次日恢复，v1 §6.1）
   void              CheckPeriodReset()
     {
      if(m_pauseUntil > 0 && TimeCurrent() >= m_pauseUntil)
        {
         m_logger.Info(StringFormat("连亏暂停到期: 清零连亏计数(原 %d 笔), 恢复开仓评估",
                                    m_consecLosses));
         m_consecLosses = 0;
         m_pauseUntil   = 0;
         SaveState();
        }
      MqlDateTime dt;
      NowStruct(dt);
      // 跨日复位（服务器时间 0 点后首个 Tick）
      if(dt.day != m_lastResetDay)
        {
         m_lastResetDay = dt.day;
         m_dailyNet     = 0.0;
         m_logger.Info("日风控复位: 当日盈亏净额清零");
         SaveState();
        }
     }

   //=== 状态持久化（写全局变量，重启不丢失）==========================

   void              SaveState()
     {
      GlobalVariableSet(GVName("DAILY_NET"),    m_dailyNet);
      GlobalVariableSet(GVName("CONSEC_LOSS"),  (double)m_consecLosses);
      GlobalVariableSet(GVName("PAUSE_UNTIL"),  (double)m_pauseUntil);
      GlobalVariableSet(GVName("RESET_DAY"),    (double)m_lastResetDay);
      GlobalVariableSet(GVName("LAST_DEAL"),    (double)m_lastDealTicket);
     }

   void              LoadState()
     {
      if(GlobalVariableCheck(GVName("DAILY_NET")))   m_dailyNet      = GlobalVariableGet(GVName("DAILY_NET"));
      if(GlobalVariableCheck(GVName("CONSEC_LOSS"))) m_consecLosses  = (int)GlobalVariableGet(GVName("CONSEC_LOSS"));
      if(GlobalVariableCheck(GVName("PAUSE_UNTIL"))) m_pauseUntil    = (datetime)GlobalVariableGet(GVName("PAUSE_UNTIL"));
      if(GlobalVariableCheck(GVName("RESET_DAY")))   m_lastResetDay  = (int)GlobalVariableGet(GVName("RESET_DAY"));
      if(GlobalVariableCheck(GVName("LAST_DEAL")))   m_lastDealTicket= (ulong)GlobalVariableGet(GVName("LAST_DEAL"));
     }
  };

#endif // __GREA_RISKMANAGER_MQH__
