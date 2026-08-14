//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//|  模块职责：订单执行模块 —— CTrade 封装：市价开/平仓、下单错误       |
//|            退避重试、滑点设置、SL/TP 规范化校验、改单统一入口       |
//|            ModifySL（保本推损/跟踪止损的具体策略在主 EA 的         |
//|            ManagePosition 中实现，G1/G2/G3）                        |
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
   //    黄金上常见 Invalid stops 拒单，开仓下单前必须校验
   //    修复C4：按 MT5 服务器规则校验 —— 买单 SL 相对 Bid、TP 相对 Ask；
   //    卖单 SL 相对 Ask、TP 相对 Bid（原实现买单 SL 错用 Ask 基准，
   //    点差拉宽时会误拒合法止损）
   bool              ValidateStops(const bool isBuy, const double sl, const double tp)
     {
      double point      = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      long   stopsLevel = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist    = stopsLevel * point;
      double bid        = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask        = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      if(isBuy)
        {
         // 买单：SL 相对 Bid、TP 相对 Ask 校验
         if(sl > 0 && bid - sl < minDist) return false;
         if(tp > 0 && tp - ask < minDist) return false;
        }
      else
        {
         // 卖单：SL 相对 Ask、TP 相对 Bid 校验
         if(sl > 0 && sl - ask < minDist) return false;
         if(tp > 0 && bid - tp < minDist) return false;
        }
      return true;
     }

   //--- 修复E3：改单场景放宽版校验 —— 仅做基础 sanity check（有限值、
   //    非负、方向正确），不校验最小停损距，由服务器端做最终裁决；
   //    避免极端点差下保本推损/跟踪止损改单被本地校验误拒（开仓路径
   //    仍用严格版 ValidateStops）
   bool              ValidateStopsRelaxed(const bool isBuy, const double sl, const double tp)
     {
      if(!MathIsValidNumber(sl) || !MathIsValidNumber(tp))
         return false;
      if(sl < 0 || tp < 0)
         return false;
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(isBuy)
        {
         if(sl > 0 && sl >= bid) return false;   // 多单 SL 须低于 Bid
         if(tp > 0 && tp <= ask) return false;   // 多单 TP 须高于 Ask
        }
      else
        {
         if(sl > 0 && sl <= ask) return false;   // 空单 SL 须高于 Ask
         if(tp > 0 && tp >= bid) return false;   // 空单 TP 须低于 Bid
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
   //      false = 不可重试/累计 GTEA_OPEN_MAX_ATTEMPTS 次重试耗尽，已放弃
   //              （调用方回退 IDLE）
   bool              Open(const ENUM_SIGNAL_DIR dir, const double lots,
                          double sl, double tp, const string comment)
     {
      if(dir == SIGNAL_NONE || lots <= 0)
        {
         ResetRetry();
         return false;
        }
      // A1：一单一结防御性二次校验 —— 主流程由 CanOpenNew 把关，此处为
      //     发送前最后一道防线（防状态机漏洞/未来新开仓路径绕过检查）
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!m_pos.SelectByIndex(i))
            continue;
         if(m_pos.Magic() == m_magic && m_pos.Symbol() == m_symbol)
           {
            m_logger.Warn(StringFormat("开仓拒绝: 本 magic 已持有仓位 ticket=%I64u(一单一结防御性二次校验)",
                                       m_pos.Ticket()));
            ResetRetry();
            return false;
           }
        }
      // 重试间隔保护：距上次尝试不足 GTEA_RETRY_MIN_INTERVAL_SEC 秒则等待
      // 后续 Tick（防 Tick 密集时轰炸服务器）
      if(m_retryPending && TimeCurrent() - m_lastRetryTime < GTEA_RETRY_MIN_INTERVAL_SEC)
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
         if(m_retryAttempt >= GTEA_OPEN_MAX_ATTEMPTS)
           {
            // 累计尝试耗尽：放弃，由调用方回退状态机 IDLE（保持原回退语义）
            m_logger.Error(StringFormat("开仓失败: 累计 %d 次重试耗尽 retcode=%u",
                                        m_retryAttempt, rc));
            ResetRetry();
            return false;
           }
         m_retryPending = true;
         // 重试日志节流，避免密集 Tick 下刷屏
         m_logger.WarnThrottled("open_retry",
                                StringFormat("开仓可重试失败(第 %d/%d 次): retcode=%u, 等待下一 Tick 重试",
                                             m_retryAttempt, GTEA_OPEN_MAX_ATTEMPTS, rc), 60);
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
   //    修复C2：失败后本次调用内立即重试（最多 GTEA_CLOSE_MAX_ATTEMPTS 次，
   //    复用开仓的可重试错误判定）；仍失败时返回 false，由主 EA 在
   //    CLOSING 态下的后续 Tick 继续尝试直到成功
   bool              CloseMyPosition(const string reason)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!m_pos.SelectByIndex(i))
            continue;
         if(m_pos.Magic() != m_magic || m_pos.Symbol() != m_symbol)
            continue;
         ulong ticket = m_pos.Ticket();
         // Netting/Hedging 统一走 PositionClose（方案 6.6 账户模式适配）
         for(int attempt = 1; attempt <= GTEA_CLOSE_MAX_ATTEMPTS; attempt++)
           {
            if(m_trade.PositionClose(ticket))
              {
               m_logger.Notify("平仓成功: " + reason + ", ticket=" + (string)ticket);
               return true;
              }
            uint rc = m_trade.ResultRetcode();
            if(!IsRetryableError(rc))
              {
               // 不可重试错误（市场关闭/交易禁止等）：立即退出，交由后续 Tick
               m_logger.Error(StringFormat("平仓失败(不可重试): %s retcode=%u, 等待后续 Tick 再试",
                                           reason, rc));
               return false;
              }
            m_logger.Warn(StringFormat("平仓可重试失败(第 %d/%d 次): %s retcode=%u",
                                       attempt, GTEA_CLOSE_MAX_ATTEMPTS, reason, rc));
            // 评审五：重试间短暂退避，避免同一价格快照下连发被同样拒单。
            //   Sleep 在策略测试器中被忽略（不影响回测）；实盘 OnTick 内
            //   阻塞上限 (GTEA_CLOSE_MAX_ATTEMPTS-1)×GTEA_CLOSE_RETRY_SLEEP_MS
            //   毫秒，平仓属高优先级动作可接受；本轮仍失败时由 CLOSING
            //   态跨 Tick 重试兜底
            if(attempt < GTEA_CLOSE_MAX_ATTEMPTS)
               Sleep(GTEA_CLOSE_RETRY_SLEEP_MS);
           }
         m_logger.Error(StringFormat("平仓失败: 本次 %d 次重试耗尽, 将由后续 Tick 继续尝试: %s",
                                     GTEA_CLOSE_MAX_ATTEMPTS, reason));
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
      // 修复五：先选中持仓确定方向，本地校验新 SL/TP，
      //         避免向服务器反复发送无效改单
      if(!m_pos.SelectByTicket(ticket))
        {
         m_logger.Warn(StringFormat("改单放弃: 选中持仓失败 ticket=%I64u", ticket));
         return false;
        }
      bool isBuy = (m_pos.PositionType() == POSITION_TYPE_BUY);
      // 修复E3：改单路径改用放宽版校验（仅 sanity check），避免极端点差下
      //         严格版 ValidateStops 误拒保本/跟踪改单，最小停损距由服务器裁决
      if(!ValidateStopsRelaxed(isBuy, sl, ntp))
        {
         m_logger.Warn(StringFormat("改单放弃: SL/TP 基础校验未通过(方向/数值非法) sl=%.2f tp=%.2f", sl, ntp));
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
  };

#endif // __GTEA_TRADEEXECUTOR_MQH__
