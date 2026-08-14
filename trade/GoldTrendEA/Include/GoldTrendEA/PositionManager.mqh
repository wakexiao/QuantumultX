//+------------------------------------------------------------------+
//|                                              PositionManager.mqh |
//|  模块职责：持仓管理器 —— 一单一结状态机核心：                       |
//|            以 magic number + symbol 查询真实持仓为唯一事实来源，    |
//|            状态流转、冷却期计数、全局变量状态持久化                 |
//|  对应方案文档：第 4.3 节（一单一结状态机）、6.4 节（持仓过滤）、    |
//|               6.6 节（状态持久化）                                  |
//+------------------------------------------------------------------+
#ifndef __GTEA_POSITIONMANAGER_MQH__
#define __GTEA_POSITIONMANAGER_MQH__

#include <Trade/PositionInfo.mqh>
#include <GoldTrendEA/Config.mqh>
#include <GoldTrendEA/Logger.mqh>
#include <GoldTrendEA/RiskManager.mqh>   // A3：兜底路径回查盈亏后补调风控统计

//--- 一单一结状态机状态（方案 4.3 状态图）
enum ENUM_EA_STATE
  {
   STATE_IDLE             = 0,  // 空仓待机：每根信号周期新K线评估信号
   STATE_SIGNAL_CONFIRMED = 1,  // 信号确认：三重过滤通过，等待风控/手数
   STATE_OPENING          = 2,  // 开仓中：下单+重试进行中
   STATE_POSITION_OPEN    = 3,  // 持仓管理：移动止损/反转监测
   STATE_CLOSING          = 4,  // 平仓结算中
   STATE_COOLING_DOWN     = 5   // 冷却期：N 根信号周期K线内不评估信号
  };

//+------------------------------------------------------------------+
//| CPositionManager：一单一结状态机                                    |
//+------------------------------------------------------------------+
class CPositionManager
  {
private:
   long              m_magic;
   string            m_symbol;
   CLogger          *m_logger;
   CRiskManager     *m_risk;              // A3：风控模块（可选注入，兜底补账用）
   CPositionInfo     m_pos;               // 标准库持仓查询封装

   ENUM_EA_STATE     m_state;             // 当前状态（内存镜像，真实持仓为准）
   int               m_cooldownLeft;      // 冷却剩余K线数
   datetime          m_lastCloseTime;     // 最近平仓时间（诊断用）
   string            m_gvPrefix;          // 修复一：实例级持久化前缀 magic+symbol
   bool              m_gvNameWarned;      // E5：全局变量名超长只告警一次（防刷屏）
   datetime          m_lastHeartbeat;     // F5：上次心跳写入时刻（频率控制）
   // D1：持仓计数 Tick 级缓存 —— 同一 Tick 内 CountMyPositions/HasPosition
   //     多次调用复用结果；每 Tick 开始及开平仓动作后由外部失效
   int               m_cachedCount;       // 缓存的本 magic 持仓数
   bool              m_cacheValid;        // 缓存有效标记

   //--- 全局变量名（修复一：改用 magic+symbol 实例级前缀，
   //    避免多图表同 magic 挂载时冷却状态跨品种污染）
   //    E5：MT5 全局变量名上限 63 字符，超长会被终端截断导致命名冲突，
   //    记 ERROR 暴露问题（仍返回原名交由终端截断，日志用于提醒缩短组合）
   string            GVName(const string suffix)
     {
      string name = m_gvPrefix + suffix;
      if(StringLen(name) > GTEA_GV_NAME_MAX && !m_gvNameWarned)
        {
         m_gvNameWarned = true;
         m_logger.Error(StringFormat("全局变量名超长(%d>%d): %s, 将被终端截断, 请缩短 magic/品种组合",
                                     StringLen(name), GTEA_GV_NAME_MAX, name));
        }
      return name;
     }

   //--- 状态名称（日志用）
   string            StateName(const ENUM_EA_STATE s)
     {
      switch(s)
        {
         case STATE_IDLE:             return "IDLE";
         case STATE_SIGNAL_CONFIRMED: return "SIGNAL_CONFIRMED";
         case STATE_OPENING:          return "OPENING";
         case STATE_POSITION_OPEN:    return "POSITION_OPEN";
         case STATE_CLOSING:          return "CLOSING";
         case STATE_COOLING_DOWN:     return "COOLING_DOWN";
        }
      return "UNKNOWN";
     }

   //--- A3：兜底路径盈亏回查 —— 持仓消失但未经 OnTradeTransaction 入账时，
   //    回查近期历史平仓成交（过滤/防重复逻辑与主 EA 的 ReconcileOfflineDeals
   //    一致：magic+品种+DEAL_ENTRY_OUT，且 ticket 大于最后已入账成交），
   //    逐笔补调 RiskManager::OnTradeResult（同时登记 ticket 防重复）。
   //    返回 true = 至少找到一笔，profitSum 输出合计盈亏
   bool              ReconcileMissingClose(double &profitSum)
     {
      profitSum = 0.0;
      if(m_risk == NULL)
         return false;                     // 未注入风控模块，回退保守路径
      if(!HistorySelect(TimeCurrent() - GTEA_SYNC_LOOKBACK_SEC, TimeCurrent() + 60))
        {
         m_logger.Warn("状态对账: HistorySelect 失败, 无法回查平仓盈亏");
         return false;
        }
      ulong lastTicket = m_risk.LastDealTicket();
      int   found      = 0;
      int   total      = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0 || deal <= lastTicket)
            continue;                      // 已入账过的成交跳过（防重复）
         if(HistoryDealGetInteger(deal, DEAL_MAGIC) != m_magic)
            continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != m_symbol)
            continue;
         long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
            continue;
         //--- 单笔盈亏口径与 OnTradeTransaction 一致（方案 6.6）
         double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                       + HistoryDealGetDouble(deal, DEAL_SWAP)
                       + HistoryDealGetDouble(deal, DEAL_COMMISSION);
         m_logger.Warn(StringFormat("状态对账: 补记平仓成交 deal=%I64u 盈亏=%.2f", deal, profit));
         m_risk.OnTradeResult(profit, deal);   // 补风控统计并登记 ticket 防重复
         profitSum += profit;
         found++;
        }
      return (found > 0);
     }

public:
                     CPositionManager() : m_magic(0), m_symbol(""), m_logger(NULL),
                                          m_risk(NULL),
                                          m_state(STATE_IDLE), m_cooldownLeft(0),
                                          m_lastCloseTime(0), m_gvPrefix(""),
                                          m_gvNameWarned(false), m_lastHeartbeat(0),
                                          m_cachedCount(0), m_cacheValid(false) {}
                    ~CPositionManager() {}

   //--- 初始化：绑定 magic/symbol/日志
   bool              Init(const long magic, const string symbol, CLogger *logger)
     {
      m_magic  = magic;
      m_symbol = symbol;
      m_logger = logger;
      // 修复一：生成 magic+symbol 组合的实例级持久化命名空间
      m_gvPrefix = "GTEA_" + (string)m_magic + "_" + m_symbol + "_";
      return (m_magic != 0 && m_symbol != "" && m_logger != NULL);
     }

   //--- A3：注入风控模块（OnInit 中 g_risk.Init 之后调用，兜底补账用；
   //    未注入时 SyncWithReality 兜底路径保持原保守行为）
   void              SetRiskManager(CRiskManager *risk) { m_risk = risk; }

   //--- 当前状态（只读）
   ENUM_EA_STATE     State() const { return m_state; }

   //--- 状态流转（统一入口，带日志）
   void              SetState(const ENUM_EA_STATE s)
     {
      if(s == m_state)
         return;
      m_logger.Info("状态流转: " + StateName(m_state) + " -> " + StateName(s));
      m_state = s;
     }

   //--- 统计本 EA 持仓数量：magic + symbol 双重过滤（方案 6.4 真实代码）
   //    一单一结不变量：任何开仓动作前必须返回 0
   //    D1：同一 Tick 内重复调用复用缓存（OnTick 顶部 InvalidateCache 失效）
   int               CountMyPositions()
     {
      if(m_cacheValid)
         return m_cachedCount;
      int cnt = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!m_pos.SelectByIndex(i))
            continue;
         if(m_pos.Magic() == m_magic && m_pos.Symbol() == m_symbol)
            cnt++;
        }
      m_cachedCount = cnt;
      m_cacheValid  = true;
      return cnt;
     }

   //--- D1：失效持仓计数缓存 —— 每次 OnTick 开始、任何开/平仓动作后、
   //    本 EA 成交回报到达时必须调用，避免脏读
   void              InvalidateCache() { m_cacheValid = false; }

   //--- 是否持有本 EA 仓位
   bool              HasPosition() { return (CountMyPositions() > 0); }

   //--- 选中本 EA 持仓（供持仓管理读取 ticket/方向/SL 等）
   //    返回 true 后可通过 m_pos 的引用接口读取详情
   bool              SelectMyPosition(CPositionInfo &pos)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!pos.SelectByIndex(i))
            continue;
         if(pos.Magic() == m_magic && pos.Symbol() == m_symbol)
            return true;
        }
      return false;
     }

   //--- 每 Tick 对账：以真实持仓为唯一事实来源修正内存状态（方案 4.3）
   //    防止手动平仓、SL触发、断线期间成交导致的状态漂移
   void              SyncWithReality()
     {
      bool has = HasPosition();
      if(has && m_state != STATE_POSITION_OPEN && m_state != STATE_CLOSING)
        {
         m_logger.Warn("状态对账: 检测到真实持仓但状态=" + StateName(m_state) + ", 强制修正");
         SetState(STATE_POSITION_OPEN);
        }
      if(!has && (m_state == STATE_POSITION_OPEN || m_state == STATE_CLOSING))
        {
         // 持仓已消失（SL/TP成交或手动平仓）→ 进入冷却
         // 注：正常路径由 OnTradeTransaction 驱动，此处为兜底；
         //     修复三：OPENING 态无持仓属正常（Tick 驱动重试等待中），
         //     不在此处修正，由主 EA 的 OPENING 分支处理；
         //     A3：先回查历史成交获取实际盈亏（补风控统计 + 按盈亏选
         //     冷却档），回查不到时才保守取更长的亏损冷却（原 G5 兜底）
         m_logger.Warn("状态对账: 持仓已消失但状态=" + StateName(m_state) + ", 进入冷却期");
         double profitSum = 0.0;
         if(ReconcileMissingClose(profitSum))
           {
            // 回查成功：按平仓事件正常路径结算（Notify + 按实际盈亏选冷却档）；
            // 后续同笔成交的 OnTradeTransaction 回报由 LastDealTicket 去重跳过
            OnPositionClosed(profitSum);
           }
         else
            StartCooldown(InpCooldownBarsLoss);
        }
     }

   //--- 是否允许开新仓：状态、真实持仓、冷却期三重检查
   bool              CanOpenNew()
     {
      if(HasPosition())
         return false;                     // 一单一结硬约束
      if(m_state == STATE_COOLING_DOWN)
         return false;
      return (m_state == STATE_IDLE);
     }

   //--- 平仓事件回调（由 OnTradeTransaction 的 DEAL_ENTRY_OUT 驱动，方案 4.3）
   //    G5：按盈亏差异化冷却 —— 亏损用 InpCooldownBarsLoss（更长，避免
   //    止损后立刻被同一信号再次触发连续挨打），盈利/保本用
   //    InpCooldownBarsProfit（更短，可为 0）
   void              OnPositionClosed(const double profit)
     {
      m_lastCloseTime = TimeCurrent();
      m_logger.Notify(StringFormat("平仓结算: 盈亏=%.2f", profit));
      StartCooldown(profit < 0 ? InpCooldownBarsLoss : InpCooldownBarsProfit);
     }

   //--- 启动冷却期并持久化（G5：冷却长度由调用方按盈亏选择）
   void              StartCooldown(const int bars)
     {
      ClearTradeVars();                    // G1：单笔持仓级变量随平仓清理
      m_cooldownLeft = bars;
      if(m_cooldownLeft > 0)
         SetState(STATE_COOLING_DOWN);
      else
         SetState(STATE_IDLE);
      SaveState();
     }

   //--- 信号周期新 K 线回调：冷却倒数（方案 4.3 COOLDOWN → IDLE）
   void              OnNewSignalBar()
     {
      if(m_state != STATE_COOLING_DOWN)
         return;
      m_cooldownLeft--;
      if(m_cooldownLeft <= 0)
        {
         m_cooldownLeft = 0;
         SetState(STATE_IDLE);
        }
      SaveState();
     }

   //--- 状态持久化：写全局变量（EA 重启/断线不丢失，方案 6.6）
   //    修复E2：额外记录保存时刻，供离线补账确定历史成交回查窗口
   void              SaveState()
     {
      GlobalVariableSet(GVName("COOLDOWN_LEFT"), (double)m_cooldownLeft);
      GlobalVariableSet(GVName("STATE"), (double)m_state);
      GlobalVariableSet(GVName("STATE_TIME"), (double)TimeCurrent());
     }

   //--- 修复E2：读取上次持久化的状态（离线补账判断用），无记录返回 IDLE
   ENUM_EA_STATE     SavedState()
     {
      if(GlobalVariableCheck(GVName("STATE")))
         return (ENUM_EA_STATE)(int)GlobalVariableGet(GVName("STATE"));
      return STATE_IDLE;
     }

   //--- 修复E2：上次状态持久化时刻，无记录返回 0
   datetime          StateSavedTime()
     {
      if(GlobalVariableCheck(GVName("STATE_TIME")))
         return (datetime)GlobalVariableGet(GVName("STATE_TIME"));
      return 0;
     }

   //=== G1：单笔持仓级持久化（初始止损距离/保本完成标记，重启可恢复）===

   //--- 开仓成功后持久化初始止损距离（保本触发基准，保本后 pos.StopLoss
   //    已变化无法反推），并清除上一笔的保本完成标记
   void              SaveInitialSLDist(const double dist)
     {
      GlobalVariableSet(GVName("INIT_SLDIST"), dist);
      GlobalVariableDel(GVName("BE_DONE"));
     }

   //--- 读取持久化的初始止损距离，无记录返回 0
   double            InitialSLDist()
     {
      if(GlobalVariableCheck(GVName("INIT_SLDIST")))
         return GlobalVariableGet(GVName("INIT_SLDIST"));
      return 0.0;
     }

   //--- 保本已完成标记（持久化，保本只推一次、EA 重启后不重复推）
   void              MarkBreakEvenDone() { GlobalVariableSet(GVName("BE_DONE"), 1.0); }
   bool              IsBreakEvenDone()
     {
      return (GlobalVariableCheck(GVName("BE_DONE")) &&
              GlobalVariableGet(GVName("BE_DONE")) > 0);
     }

   //--- 平仓后清除单笔持仓级变量（StartCooldown 统一调用，覆盖所有平仓路径）
   void              ClearTradeVars()
     {
      GlobalVariableDel(GVName("INIT_SLDIST"));
      GlobalVariableDel(GVName("BE_DONE"));
     }

   //--- F5：心跳机制 —— 每 GTEA_HEARTBEAT_INTERVAL_SEC 秒写一次心跳全局
   //    变量（当前服务器时间），供外部看门狗监控 EA 存活；OnTick 顶部调用
   void              UpdateHeartbeat()
     {
      datetime now = TimeCurrent();
      if(now - m_lastHeartbeat < GTEA_HEARTBEAT_INTERVAL_SEC)
         return;
      m_lastHeartbeat = now;
      GlobalVariableSet(GVName("HEARTBEAT"), (double)now);
     }

   //--- 状态恢复：OnInit 中调用（方案 4.3 / 8.2 状态恢复流程）
   //    优先级：真实持仓 > 全局变量 > 默认 IDLE
   void              RestoreState()
     {
      if(HasPosition())
        {
         // 检测到本 magic 已有持仓 → 直接进入持仓管理
         m_state = STATE_POSITION_OPEN;
         m_logger.Info("状态恢复: 检测到存量持仓, 进入 POSITION_OPEN");
         // G10（方案 8.2）：SL/TP 存在性与方向对账由主 EA 的
         //      ReconcileRestoredStops 在 RestoreState 之后执行
         return;
        }
      // E1：持久化状态为 OPENING（下单中断重启）且当前无持仓 → 待重试
      //     参数已丢失，直接归为 IDLE 重走信号评估（不再依赖运行时
      //     RetryOpenPosition 的异常兜底）
      if(SavedState() == STATE_OPENING)
        {
         m_state = STATE_IDLE;
         m_logger.Info("状态恢复: 上次停机时为 OPENING(开仓中断)且当前无持仓, 直接归为 IDLE");
         SaveState();
         return;
        }
      if(GlobalVariableCheck(GVName("COOLDOWN_LEFT")))
        {
         m_cooldownLeft = (int)GlobalVariableGet(GVName("COOLDOWN_LEFT"));
         if(m_cooldownLeft > 0)
           {
            m_state = STATE_COOLING_DOWN;
            m_logger.Info(StringFormat("状态恢复: 冷却期剩余 %d 根K线", m_cooldownLeft));
            return;
           }
        }
      m_state = STATE_IDLE;
      m_logger.Info("状态恢复: 无持仓无冷却, 进入 IDLE");
     }
  };

#endif // __GTEA_POSITIONMANAGER_MQH__
