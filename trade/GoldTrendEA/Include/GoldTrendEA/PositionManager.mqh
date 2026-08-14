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
   CPositionInfo     m_pos;               // 标准库持仓查询封装

   ENUM_EA_STATE     m_state;             // 当前状态（内存镜像，真实持仓为准）
   int               m_cooldownLeft;      // 冷却剩余K线数
   datetime          m_lastCloseTime;     // 最近平仓时间（诊断用）
   string            m_gvPrefix;          // 修复一：实例级持久化前缀 magic+symbol

   //--- 全局变量名（修复一：改用 magic+symbol 实例级前缀，
   //    避免多图表同 magic 挂载时冷却状态跨品种污染）
   string            GVName(const string suffix) { return m_gvPrefix + suffix; }

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

public:
                     CPositionManager() : m_magic(0), m_symbol(""), m_logger(NULL),
                                          m_state(STATE_IDLE), m_cooldownLeft(0),
                                          m_lastCloseTime(0), m_gvPrefix("") {}
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
   int               CountMyPositions()
     {
      int cnt = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!m_pos.SelectByIndex(i))
            continue;
         if(m_pos.Magic() == m_magic && m_pos.Symbol() == m_symbol)
            cnt++;
        }
      return cnt;
     }

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
         //     不在此处修正，由主 EA 的 OPENING 分支处理
         m_logger.Warn("状态对账: 持仓已消失但状态=" + StateName(m_state) + ", 进入冷却期");
         StartCooldown();
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
   void              OnPositionClosed(const double profit)
     {
      m_lastCloseTime = TimeCurrent();
      m_logger.Notify(StringFormat("平仓结算: 盈亏=%.2f", profit));
      StartCooldown();
     }

   //--- 启动冷却期并持久化
   void              StartCooldown()
     {
      m_cooldownLeft = InpCooldownBars;
      // TODO(M3, 方案 4.3)：亏损/盈利平仓可配置不同冷却长度，当前统一取 InpCooldownBars
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
   void              SaveState()
     {
      GlobalVariableSet(GVName("COOLDOWN_LEFT"), (double)m_cooldownLeft);
      GlobalVariableSet(GVName("STATE"), (double)m_state);
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
         // TODO(M3, 方案 8.2)：重连后首个Tick做全量对账（SL/TP是否与预期一致），
         //      不一致时修正并告警
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
