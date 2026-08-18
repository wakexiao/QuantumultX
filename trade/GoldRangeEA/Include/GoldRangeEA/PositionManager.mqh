//+------------------------------------------------------------------+
//|                                              PositionManager.mqh |
//|  模块职责：持仓管理器 —— 一单一结状态机核心：                       |
//|            以 magic number + symbol 查询真实持仓为唯一事实来源，    |
//|            状态流转、时间制冷却、全局变量状态持久化                  |
//|  与模板差异：冷却由「K 线根数」改为「时间制」（v1 §3.1/3.2 最小交易  |
//|            间隔=分钟）；新增单笔级箱体上下沿快照持久化（v1 §4.2     |
//|            突破止损联动基准）；删除保本专用变量（v1 §八-8 不改 SL）  |
//|  对应需求文档 v1.md：§3.1/3.2（最小间隔）、§4.2（箱体快照）、       |
//|               §6.3（一单一结）、§八（禁止事项）                      |
//+------------------------------------------------------------------+
#ifndef __GREA_POSITIONMANAGER_MQH__
#define __GREA_POSITIONMANAGER_MQH__

#include <Trade/PositionInfo.mqh>
#include <GoldRangeEA/Config.mqh>
#include <GoldRangeEA/Logger.mqh>
#include <GoldRangeEA/RiskManager.mqh>   // 兜底路径回查盈亏后补风控统计

//--- 一单一结状态机状态（沿用模板 6 态）
enum ENUM_EA_STATE
  {
   STATE_IDLE             = 0,  // 空仓待机：Tick 级评估箱体入场信号
   STATE_SIGNAL_CONFIRMED = 1,  // 信号确认：三级漏斗通过，等待风控/手数
   STATE_OPENING          = 2,  // 开仓中：下单+重试进行中
   STATE_POSITION_OPEN    = 3,  // 持仓管理：突破联动/时间止损监控
   STATE_CLOSING          = 4,  // 平仓结算中
   STATE_COOLING_DOWN     = 5   // 冷却期：距上次平仓不足最小交易间隔（时间制）
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
   CRiskManager     *m_risk;              // 风控模块（可选注入，兜底补账用）
   CPositionInfo     m_pos;               // 标准库持仓查询封装

   ENUM_EA_STATE     m_state;             // 当前状态（内存镜像，真实持仓为准）
   datetime          m_lastCloseTime;     // 最近平仓时间（时间制冷却基准，持久化）
   double            m_snapUpper;         // 本笔持仓的箱体上沿快照（开仓时写入）
   double            m_snapLower;         // 本笔持仓的箱体下沿快照（开仓时写入）
   string            m_gvPrefix;          // 实例级持久化前缀 magic+symbol
   bool              m_gvNameWarned;      // 全局变量名超长只告警一次（防刷屏）
   datetime          m_lastHeartbeat;     // 上次心跳写入时刻（频率控制）
   // 持仓计数 Tick 级缓存 —— 同一 Tick 内 CountMyPositions/HasPosition
   // 多次调用复用结果；每 Tick 开始及开平仓动作后由外部失效
   int               m_cachedCount;       // 缓存的本 magic 持仓数
   bool              m_cacheValid;        // 缓存有效标记

   //--- 全局变量名（magic+symbol 实例级前缀，避免多图表同 magic 挂载时
   //    冷却/风控状态跨品种污染；超 63 字符会被终端截断，记 ERROR 提醒）
   string            GVName(const string suffix)
     {
      string name = m_gvPrefix + suffix;
      if(StringLen(name) > GREA_GV_NAME_MAX && !m_gvNameWarned)
        {
         m_gvNameWarned = true;
         m_logger.Error(StringFormat("全局变量名超长(%d>%d): %s, 将被终端截断, 请缩短 magic/品种组合",
                                     StringLen(name), GREA_GV_NAME_MAX, name));
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

   //--- 兜底路径盈亏回查 —— 持仓消失但未经 OnTradeTransaction 入账时，
   //    回查近期历史平仓成交（过滤/防重复逻辑与主 EA 的 ReconcileOfflineDeals
   //    一致：magic+品种+DEAL_ENTRY_OUT，且 ticket 大于最后已入账成交），
   //    逐笔补调 RiskManager::OnTradeResult（同时登记 ticket 防重复）。
   //    返回 true = 至少找到一笔，profitSum 输出合计盈亏
   bool              ReconcileMissingClose(double &profitSum)
     {
      profitSum = 0.0;
      if(m_risk == NULL)
         return false;                     // 未注入风控模块，回退保守路径
      if(!HistorySelect(TimeCurrent() - GREA_SYNC_LOOKBACK_SEC, TimeCurrent() + 60))
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
         //--- 单笔盈亏口径与 OnTradeTransaction 一致
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
                                          m_state(STATE_IDLE),
                                          m_lastCloseTime(0),
                                          m_snapUpper(0.0), m_snapLower(0.0),
                                          m_gvPrefix(""),
                                          m_gvNameWarned(false), m_lastHeartbeat(0),
                                          m_cachedCount(0), m_cacheValid(false) {}
                    ~CPositionManager() {}

   //--- 初始化：绑定 magic/symbol/日志
   bool              Init(const long magic, const string symbol, CLogger *logger)
     {
      m_magic  = magic;
      m_symbol = symbol;
      m_logger = logger;
      // 生成 magic+symbol 组合的实例级持久化命名空间
      m_gvPrefix = "GREA_" + (string)m_magic + "_" + m_symbol + "_";
      return (m_magic != 0 && m_symbol != "" && m_logger != NULL);
     }

   //--- 注入风控模块（OnInit 中 g_risk.Init 之后调用，兜底补账用；
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

   //--- 统计本 EA 持仓数量：magic + symbol 双重过滤
   //    一单一结不变量：任何开仓动作前必须返回 0
   //    同一 Tick 内重复调用复用缓存（OnTick 顶部 InvalidateCache 失效）
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

   //--- 失效持仓计数缓存 —— 每次 OnTick 开始、任何开/平仓动作后、
   //    本 EA 成交回报到达时必须调用，避免脏读
   void              InvalidateCache() { m_cacheValid = false; }

   //--- 是否持有本 EA 仓位
   bool              HasPosition() { return (CountMyPositions() > 0); }

   //--- 选中本 EA 持仓（供持仓管理读取 ticket/方向/SL 等）
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

   //--- 每 Tick 对账：以真实持仓为唯一事实来源修正内存状态
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
         //     OPENING 态无持仓属正常（Tick 驱动重试等待中），
         //     不在此处修正，由主 EA 的 OPENING 分支处理；
         //     先回查历史成交获取实际盈亏（补风控统计），回查不到时
         //     保守进入冷却（时间制，与正常平仓同基准）
         m_logger.Warn("状态对账: 持仓已消失但状态=" + StateName(m_state) + ", 进入冷却期");
         double profitSum = 0.0;
         if(ReconcileMissingClose(profitSum))
           {
            // 回查成功：按平仓事件正常路径结算（Notify + 时间制冷却）；
            // 后续同笔成交的 OnTradeTransaction 回报由 LastDealTicket 去重跳过
            OnPositionClosed(profitSum);
           }
         else
            StartCooldown();
        }
     }

   //--- 时间制冷却判定（v1 §3.1/3.2：距上一笔平仓 ≥ 最小交易间隔）
   //    m_lastCloseTime=0（无平仓记录）或间隔参数=0 时视为已冷却完毕
   bool              MinIntervalElapsed() const
     {
      if(InpMinTradeIntervalMin <= 0 || m_lastCloseTime <= 0)
         return true;
      return ((long)(TimeCurrent() - m_lastCloseTime) >= (long)InpMinTradeIntervalMin * 60);
     }

   //--- 冷却期到期翻转（COOLING_DOWN → IDLE）：主 EA OnTick 无持仓分支调用
   void              UpdateCooldown()
     {
      if(m_state != STATE_COOLING_DOWN)
         return;
      if(MinIntervalElapsed())
        {
         SetState(STATE_IDLE);
         SaveState();
        }
     }

   //--- 是否允许开新仓：状态、真实持仓、时间制冷却三重检查
   bool              CanOpenNew()
     {
      if(HasPosition())
         return false;                     // 一单一结硬约束（v1 §6.3）
      if(m_state == STATE_COOLING_DOWN)
         return false;                     // 主 EA 每 Tick 先 UpdateCooldown 翻转
      return (m_state == STATE_IDLE && MinIntervalElapsed());
     }

   //--- 平仓事件回调（由 OnTradeTransaction 的 DEAL_ENTRY_OUT 驱动）
   //    时间制冷却：记录平仓时刻并持久化，冷却时长由
   //    InpMinTradeIntervalMin（分钟）统一决定（v1 §3.1/3.2）
   void              OnPositionClosed(const double profit)
     {
      m_lastCloseTime = TimeCurrent();
      m_logger.Notify(StringFormat("平仓结算: 盈亏=%.2f, 冷却 %d 分钟",
                                   profit, InpMinTradeIntervalMin));
      StartCooldown();
     }

   //--- 启动冷却期并持久化（时间制；间隔为 0 时直接回 IDLE）
   void              StartCooldown()
     {
      ClearTradeVars();                    // 单笔持仓级变量随平仓清理
      if(MinIntervalElapsed())
         SetState(STATE_IDLE);
      else
         SetState(STATE_COOLING_DOWN);
      SaveState();
     }

   //--- 状态持久化：写全局变量（EA 重启/断线不丢失）
   //    LAST_CLOSE_TIME 供重启后恢复时间制冷却进度
   void              SaveState()
     {
      GlobalVariableSet(GVName("LAST_CLOSE_TIME"), (double)m_lastCloseTime);
      GlobalVariableSet(GVName("STATE"), (double)m_state);
      GlobalVariableSet(GVName("STATE_TIME"), (double)TimeCurrent());
     }

   //--- 读取上次持久化的状态（离线补账判断用），无记录返回 IDLE
   ENUM_EA_STATE     SavedState()
     {
      if(GlobalVariableCheck(GVName("STATE")))
         return (ENUM_EA_STATE)(int)GlobalVariableGet(GVName("STATE"));
      return STATE_IDLE;
     }

   //--- 上次状态持久化时刻，无记录返回 0
   datetime          StateSavedTime()
     {
      if(GlobalVariableCheck(GVName("STATE_TIME")))
         return (datetime)GlobalVariableGet(GVName("STATE_TIME"));
      return 0;
     }

   //=== 单笔持仓级持久化：开仓时的箱体上下沿快照（v1 §4.2）===========
   //    突破止损联动的判定基准 = 开仓时刻的箱体（而非逐K线漂移的动态
   //    箱体），GV 持久化后 EA 重启仍可恢复（README 决策记录 D2）

   //--- 开仓成功后由主 EA 写入快照
   void              SaveBoxSnapshot(const double upper, const double lower)
     {
      m_snapUpper = upper;
      m_snapLower = lower;
      GlobalVariableSet(GVName("BOX_UPPER"), upper);
      GlobalVariableSet(GVName("BOX_LOWER"), lower);
     }

   //--- 读取快照（运行期，内存直读）；返回 false = 无快照
   bool              BoxSnapshot(double &upper, double &lower) const
     {
      if(m_snapUpper <= 0 || m_snapLower <= 0)
         return false;
      upper = m_snapUpper;
      lower = m_snapLower;
      return true;
     }

   //--- 从 GV 读回快照到内存（RestoreState 检测到存量持仓时调用）
   void              RestoreBoxSnapshot()
     {
      if(GlobalVariableCheck(GVName("BOX_UPPER")))
         m_snapUpper = GlobalVariableGet(GVName("BOX_UPPER"));
      if(GlobalVariableCheck(GVName("BOX_LOWER")))
         m_snapLower = GlobalVariableGet(GVName("BOX_LOWER"));
      if(m_snapUpper > 0 && m_snapLower > 0)
         m_logger.Info(StringFormat("箱体快照恢复: 上沿=%.2f 下沿=%.2f", m_snapUpper, m_snapLower));
      else
         m_logger.Warn("箱体快照恢复: 无持久化记录, 突破联动将退化为当前箱体缓存兜底");
     }

   //--- 平仓后清除单笔持仓级变量（StartCooldown 统一调用，覆盖所有平仓路径）
   void              ClearTradeVars()
     {
      GlobalVariableDel(GVName("BOX_UPPER"));
      GlobalVariableDel(GVName("BOX_LOWER"));
      m_snapUpper = 0.0;
      m_snapLower = 0.0;
     }

   //--- 心跳机制 —— 每 GREA_HEARTBEAT_INTERVAL_SEC 秒写一次心跳全局
   //    变量（当前服务器时间），供外部看门狗监控 EA 存活
   void              UpdateHeartbeat()
     {
      datetime now = TimeCurrent();
      if(now - m_lastHeartbeat < GREA_HEARTBEAT_INTERVAL_SEC)
         return;
      m_lastHeartbeat = now;
      GlobalVariableSet(GVName("HEARTBEAT"), (double)now);
     }

   //--- 状态恢复：OnInit 中调用
   //    优先级：真实持仓 > 全局变量 > 默认 IDLE
   void              RestoreState()
     {
      if(HasPosition())
        {
         // 检测到本 magic 已有持仓 → 直接进入持仓管理，
         // 并读回开仓时的箱体上下沿快照（突破联动基准）
         m_state = STATE_POSITION_OPEN;
         m_logger.Info("状态恢复: 检测到存量持仓, 进入 POSITION_OPEN");
         RestoreBoxSnapshot();
         return;
        }
      // 持久化状态为 OPENING（下单中断重启）且当前无持仓 → 待重试
      // 参数已丢失，直接归为 IDLE 重走信号评估
      if(SavedState() == STATE_OPENING)
        {
         m_state = STATE_IDLE;
         m_logger.Info("状态恢复: 上次停机时为 OPENING(开仓中断)且当前无持仓, 直接归为 IDLE");
         SaveState();
         return;
        }
      // 时间制冷却恢复：读回平仓时刻，未到期则保持 COOLING_DOWN
      if(GlobalVariableCheck(GVName("LAST_CLOSE_TIME")))
         m_lastCloseTime = (datetime)GlobalVariableGet(GVName("LAST_CLOSE_TIME"));
      if(SavedState() == STATE_COOLING_DOWN && !MinIntervalElapsed())
        {
         m_state = STATE_COOLING_DOWN;
         m_logger.Info(StringFormat("状态恢复: 冷却期剩余 %d 秒(最小间隔 %d 分钟)",
                                    (int)(InpMinTradeIntervalMin * 60 - (TimeCurrent() - m_lastCloseTime)),
                                    InpMinTradeIntervalMin));
         return;
        }
      m_state = STATE_IDLE;
      m_logger.Info("状态恢复: 无持仓无冷却, 进入 IDLE");
     }
  };

#endif // __GREA_POSITIONMANAGER_MQH__
