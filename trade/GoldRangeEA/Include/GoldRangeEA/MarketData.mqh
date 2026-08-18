//+------------------------------------------------------------------+
//|                                                   MarketData.mqh |
//|  模块职责：行情数据层 —— 新 K 线判定（多周期各自独立）、多周期      |
//|            OHLC 读取、点差查询、报价新鲜度与交易环境校验            |
//|  对应方案文档：第 3.2 节（CMarketData）、6.1 节（新K线判定）、      |
//|               6.5 节（交易环境校验）                                |
//+------------------------------------------------------------------+
#ifndef __GREA_MARKETDATA_MQH__
#define __GREA_MARKETDATA_MQH__

#include <GoldRangeEA/Config.mqh>
#include <GoldRangeEA/Logger.mqh>

//+------------------------------------------------------------------+
//| CMarketData：行情数据层                                            |
//+------------------------------------------------------------------+
class CMarketData
  {
private:
   string            m_symbol;             // 交易品种
   CLogger          *m_logger;             // 日志模块（依赖注入）

   // 多周期新 K 线判定：每个周期独立维护 lastBarTime（方案 6.1）
   // 用成员数组而非 static，支持多品种/多实例复用
   ENUM_TIMEFRAMES   m_tfs[];
   datetime          m_lastBarTimes[];

   //--- 查找/登记周期槽位，返回索引
   int               TfSlot(const ENUM_TIMEFRAMES tf)
     {
      int n = ArraySize(m_tfs);
      for(int i = 0; i < n; i++)
         if(m_tfs[i] == tf)
            return i;
      ArrayResize(m_tfs, n + 1);
      ArrayResize(m_lastBarTimes, n + 1);
      m_tfs[n] = tf;
      m_lastBarTimes[n] = 0;
      return n;
     }

public:
                     CMarketData() : m_symbol(""), m_logger(NULL) {}
                    ~CMarketData() {}

   //--- 初始化：绑定品种与日志模块
   bool              Init(const string symbol, CLogger *logger)
     {
      m_symbol = symbol;
      m_logger = logger;
      return (m_symbol != "" && m_logger != NULL);
     }

   //--- 新 K 线判定：指定周期出现新 K 线时返回 true（每根仅一次）
   //    注意：首次调用（lastBarTime==0）视为非新K线，避免EA挂载即触发信号
   bool              IsNewBar(const ENUM_TIMEFRAMES tf)
     {
      int slot = TfSlot(tf);
      datetime t = iTime(m_symbol, tf, 0);
      if(t == 0)
         return false;                     // 历史数据未同步
      if(t != m_lastBarTimes[slot])
        {
         bool first = (m_lastBarTimes[slot] == 0);
         m_lastBarTimes[slot] = t;
         return !first;
        }
      return false;
     }

   //--- OHLC 读取（shift=1 为已收盘K线；信号判定一律不用 shift=0，方案 6.2）
   double            Close(const ENUM_TIMEFRAMES tf, const int shift) { return iClose(m_symbol, tf, shift); }
   double            Open(const ENUM_TIMEFRAMES tf, const int shift)  { return iOpen(m_symbol, tf, shift);  }
   double            High(const ENUM_TIMEFRAMES tf, const int shift)  { return iHigh(m_symbol, tf, shift);  }
   double            Low(const ENUM_TIMEFRAMES tf, const int shift)   { return iLow(m_symbol, tf, shift);   }

   //--- K 线开盘时间（shift=0 为当前未收盘K线；G4 信号评估缓存键用）
   datetime          BarTime(const ENUM_TIMEFRAMES tf, const int shift = 0) { return iTime(m_symbol, tf, shift); }

   //--- 当前点差（点）
   long              SpreadPoints()
     {
      return SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
     }

   //--- 报价新鲜度：最近 Tick 距今不超过 maxAgeSec 秒（方案 6.5）
   bool              IsQuoteFresh(const int maxAgeSec = 60)
     {
      datetime lastTick = (datetime)SymbolInfoInteger(m_symbol, SYMBOL_TIME);
      return (TimeCurrent() - lastTick <= maxAgeSec);
     }

   //--- 交易环境校验（每 Tick 轻量检查，方案 6.5）
   //    失败时通过节流 WARN 记录原因，返回 false
   bool              IsTradingEnvironmentOK()
     {
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        {
         m_logger.WarnThrottled("env_terminal", "终端自动交易未允许");
         return false;
        }
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
        {
         m_logger.WarnThrottled("env_mql", "EA 交易权限未允许");
         return false;
        }
      if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
        {
         m_logger.WarnThrottled("env_account", "账户禁止 EA 交易");
         return false;
        }
      if(SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
        {
         m_logger.WarnThrottled("env_symbol", "品种非完全可交易状态: " + m_symbol);
         return false;
        }
      if(!IsQuoteFresh(60))
        {
         m_logger.WarnThrottled("env_stale", "报价陈旧(>60s 无 Tick): " + m_symbol);
         return false;
        }
      return true;
     }
  };

#endif // __GREA_MARKETDATA_MQH__
