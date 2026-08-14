//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//|  模块职责：订单执行模块 —— CTrade 封装：市价开/平仓、下单错误       |
//|            退避重试、滑点设置、SL/TP 规范化校验、保本推损与 ATR     |
//|            跟踪止损接口                                             |
//|  对应方案文档：第 3.2 节（CExecutor）、4.4 节（出场规则）、         |
//|               6.3 节（CTrade 下单与错误重试）                       |
//+------------------------------------------------------------------+
#ifndef __GTEA_TRADEEXECUTOR_MQH__
#define __GTEA_TRADEEXECUTOR_MQH__

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <GoldTrendEA/Config.mqh>
#include <GoldTrendEA/Logger.mqh>

//+------------------------------------------------------------------+
//| CTradeExecutor：订单执行封装                                        |
//+------------------------------------------------------------------+
class CTradeExecutor
  {
private:
   CTrade            m_trade;             // 标准库交易封装
   CPositionInfo     m_pos;
   string            m_symbol;
   long              m_magic;
   CLogger          *m_logger;
   // 修复三：Tick 驱动非阻塞重试状态（替代阻塞式 Sleep 重试）
   int               m_retryAttempt;      // 已尝试次数（含首次）
   datetime          m_lastRetryTime;     // 上次尝试时间（重试间隔保护）
   bool              m_retryPending;      // true=等待下一 Tick 重试

   //--- 价格规范化到品种小数位（自动适配黄金 2/3 位与外汇 3/5 位，方案 N06）
   double            NormalizePrice(const double price)
     {
      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      return NormalizeDouble(price, digits);
     }

   //--- SL/TP 停损距校验：距离基准价须 >= SYMBOL_TRADE_STOPS_LEVEL（方案 6.3）
   //    黄金上常见 Invalid stops 拒单，下单/改单前必须校验
   //    修复二：买单 SL/TP 以 Ask 为基准、卖单以 Bid 为基准（与服务器规则一致，
   //    原买单用 Bid 校验比服务器更严，会误拒刚好满足 stopsLevel 的合法止损）
   bool              ValidateStops(const bool isBuy, const double sl, const double tp)
     {
      double point      = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      long   stopsLevel = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist    = stopsLevel * point;
      double bid        = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask        = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      if(isBuy)
        {
         // 买单：SL/TP 相对 Ask 校验
         if(sl > 0 && ask - sl < minDist) return false;
         if(tp > 0 && tp - ask < minDist) return false;
        }
      else
        {
         // 卖单：SL/TP 相对 Bid 校验
         if(sl > 0 && sl - bid < minDist) return false;
         if(tp > 0 && bid - tp < minDist) return false;
        }
      return true;
     }

   //--- 错误码是否可重试（requote/价格变化类，方案 6.3）
   bool              IsRetryableError(const uint retcode)
     {
      return (retcode == TRADE_RETCODE_REQUOTE ||
              retcode == TRADE_RETCODE_PRICE_CHANGED ||
              retcode == TRADE_RETCODE_PRICE_OFF ||
              retcode == TRADE_RETCODE_TIMEOUT);
     }

public:
                     CTradeExecutor() : m_symbol(""), m_magic(0), m_logger(NULL),
                                        m_retryAttempt(0), m_lastRetryTime(0),
                                        m_retryPending(false) {}
                    ~CTradeExecutor() {}

   //--- 初始化：设置 magic 与最大滑点（方案 6.3）
   bool              Init(const string symbol, const long magic,
                          const int slippagePoints, CLogger *logger)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_logger = logger;
      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(slippagePoints);
      m_trade.SetTypeFillingBySymbol(m_symbol);   // 自动适配券商成交模式
      return (m_symbol != "" && m_magic != 0 && m_logger != NULL);
     }

   //--- 市价开仓（修复三：Tick 驱动非阻塞重试，单次调用仅一次下单尝试）
   //    dir: SIGNAL_BUY/SIGNAL_SELL；sl/tp 传 0 表示不设置
   //    返回 true = 开仓成功；返回 false 时由 IsRetryPending() 区分：
   //      true  = 可重试失败，等待下一 Tick 再试（调用方保持 OPENING 态）
   //      false = 不可重试/累计 3 次重试耗尽，已放弃（调用方回退 IDLE）
   bool              Open(const ENUM_SIGNAL_DIR dir, const double lots,
                          double sl, double tp, const string comment)
     {
      if(dir == SIGNAL_NONE || lots <= 0)
        {
         ResetRetry();
         return false;
        }
      // 重试间隔保护：距上次尝试不足 1 秒则等待后续 Tick（防 Tick 密集时轰炸服务器）
      if(m_retryPending && TimeCurrent() - m_lastRetryTime < 1)
         return false;

      bool isBuy = (dir == SIGNAL_BUY);
      ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      sl = NormalizePrice(sl);
      tp = NormalizePrice(tp);
      if(!ValidateStops(isBuy, sl, tp))
        {
         m_logger.Error(StringFormat("开仓拒绝: SL/TP 不满足最小停损距 sl=%.2f tp=%.2f", sl, tp));
         ResetRetry();
         return false;
        }

      // 本 Tick 仅做一次下单尝试（修复三：移除 Sleep，OnTick 内无阻塞）
      double price = isBuy ? SymbolInfoDouble(m_symbol, SYMBOL_ASK)
                           : SymbolInfoDouble(m_symbol, SYMBOL_BID);
      m_lastRetryTime = TimeCurrent();
      if(m_trade.PositionOpen(m_symbol, type, lots, price, sl, tp, comment) &&
         m_trade.ResultRetcode() == TRADE_RETCODE_DONE)
        {
         ResetRetry();                     // 重试成功清零计数
         m_logger.Notify(StringFormat("开仓成功: %s %.2f手 @%.2f SL=%.2f TP=%.2f",
                                      isBuy ? "BUY" : "SELL",
                                      lots, m_trade.ResultPrice(), sl, tp));
         return true;
        }

      uint rc = m_trade.ResultRetcode();
      if(IsRetryableError(rc))
        {
         m_retryAttempt++;
         if(m_retryAttempt >= 3)
           {
            // 累计 3 次失败：放弃，由调用方回退状态机 IDLE（保持原回退语义）
            m_logger.Error(StringFormat("开仓失败: 累计 %d 次重试耗尽 retcode=%u",
                                        m_retryAttempt, rc));
            ResetRetry();
            return false;
           }
         m_retryPending = true;
         // 重试日志节流，避免密集 Tick 下刷屏
         m_logger.WarnThrottled("open_retry",
                                StringFormat("开仓可重试失败(第 %d/3 次): retcode=%u, 等待下一 Tick 重试",
                                             m_retryAttempt, rc), 60);
         return false;
        }
      // 不可重试错误（资金不足/交易禁止等）：立即放弃
      m_logger.Error(StringFormat("开仓失败(不可重试): retcode=%u", rc));
      ResetRetry();
      return false;
     }

   //--- 修复三：是否存在待重试的开仓（供主 EA 判断是否保持 OPENING 态）
   bool              IsRetryPending() const { return m_retryPending; }

   //--- 修复三：清零重试计数（成功/放弃/外部取消时调用）
   void              ResetRetry() { m_retryAttempt = 0; m_retryPending = false; }

   //--- 市价平掉本 EA 持仓（趋势反转/周五离场/熔断强平用）
   bool              CloseMyPosition(const string reason)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!m_pos.SelectByIndex(i))
            continue;
         if(m_pos.Magic() != m_magic || m_pos.Symbol() != m_symbol)
            continue;
         // Netting/Hedging 统一走 PositionClose（方案 6.6 账户模式适配）
         if(m_trade.PositionClose(m_pos.Ticket()))
           {
            m_logger.Notify("平仓成功: " + reason + ", ticket=" + (string)m_pos.Ticket());
            return true;
           }
         m_logger.Error(StringFormat("平仓失败: %s retcode=%u", reason, m_trade.ResultRetcode()));
         return false;
        }
      return false;                        // 无持仓
     }

   //--- 修改止损（只朝有利方向移动的约束由调用方保证）
   //    改单失败不重试超过1次，下一 Tick 自然重试（方案 6.3，避免阻塞）
   bool              ModifySL(const ulong ticket, const double newSL, const double tp)
     {
      double sl  = NormalizePrice(newSL);
      double ntp = NormalizePrice(tp);
      // 修复五：先选中持仓确定方向，复用 ValidateStops 本地校验新 SL/TP，
      //         避免向服务器反复发送无效改单
      if(!m_pos.SelectByTicket(ticket))
        {
         m_logger.Warn(StringFormat("改单放弃: 选中持仓失败 ticket=%I64u", ticket));
         return false;
        }
      bool isBuy = (m_pos.PositionType() == POSITION_TYPE_BUY);
      if(!ValidateStops(isBuy, sl, ntp))
        {
         m_logger.Warn(StringFormat("改单放弃: SL/TP 不满足最小停损距 sl=%.2f tp=%.2f", sl, ntp));
         return false;
        }
      if(!m_trade.PositionModify(ticket, sl, ntp))
        {
         m_logger.Warn(StringFormat("改单失败: ticket=%I64u retcode=%u, 下一Tick重试",
                                    ticket, m_trade.ResultRetcode()));
         return false;
        }
      return true;
     }

   //--- 保本推损（方案 4.4）：浮盈达到 止损距离×InpBE_Trigger 时
   //    将 SL 移至 入场价 ± InpBE_Offset
   //    返回 true = 本次执行了推损动作
   bool              ApplyBreakEven(CPositionInfo &pos)
     {
      // TODO(M3, 方案 4.4)：完整实现，骨架逻辑如下 ——
      // double entry   = pos.PriceOpen();
      // double slDist  = MathAbs(entry - pos.StopLoss());   // 初始止损距离(需在开仓时另行持久化,
      //                                                     //  因保本后 pos.StopLoss 已变化)
      // bool   isBuy   = (pos.PositionType() == POSITION_TYPE_BUY);
      // double profit  = isBuy ? (当前Bid - entry) : (entry - 当前Ask);
      // if(profit >= slDist * InpBE_Trigger 且 当前SL仍劣于保本位)
      //     newSL = entry ± InpBE_Offset;  ModifySL(...);
      return false;
     }

   //--- ATR 跟踪止损（方案 4.4）：保本后启动，每根信号周期新 K 线调用
   //    newSL = 收盘价 ∓ atr × InpTrail_ATR_Mult，只朝有利方向移动
   bool              ApplyAtrTrailing(CPositionInfo &pos, const double atr)
     {
      // TODO(M3, 方案 4.4)：完整实现，骨架逻辑如下 ——
      // bool   isBuy = (pos.PositionType() == POSITION_TYPE_BUY);
      // double close = iClose(m_symbol, InpSignalTF, 1);
      // double newSL = isBuy ? close - atr * InpTrail_ATR_Mult
      //                      : close + atr * InpTrail_ATR_Mult;
      // 仅当 newSL 优于当前 SL（多单更高/空单更低）时才 ModifySL；
      // 若 InpTrailReplacesTP=true，跟踪启动后将 TP 置 0（方案 4.4 风格开关）
      return false;
     }
  };

#endif // __GTEA_TRADEEXECUTOR_MQH__
