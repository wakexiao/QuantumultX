//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//|  模块职责：订单执行模块 —— CTrade 封装：市价开/平仓、下单错误       |
//|            退避重试、滑点设置、SL/TP 停损距校验                      |
//|  注意：v1 §八-8 禁止移动止损（SL 入场后固定不修改），本 EA 不提供    |
//|        改单接口；TP/SL 全部服务器端执行                              |
//|  对应需求文档 v1.md：§八（禁止事项）、模板 6.3（CTrade 下单与重试）   |
//+------------------------------------------------------------------+
#ifndef __GREA_TRADEEXECUTOR_MQH__
#define __GREA_TRADEEXECUTOR_MQH__

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <GoldRangeEA/Config.mqh>
#include <GoldRangeEA/Logger.mqh>

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

   //--- 错误码是否可重试（requote/价格变化类，模板 6.3）
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
      // 滑点换算（评审修复 F2）：入参 slippagePoints 为 1 点=0.01 美元口径
      // （GREA_POINT_VALUE），而 SetDeviationInPoints 需要经纪商原生点
      // （SYMBOL_POINT）；3 位小数报价上 30 口径点仅 $0.03 容忍度会频繁
      // 拒单，故换算为原生点数传入（至少 1），两种报价精度容忍度等价
      double nativePoint = SymbolInfoDouble(symbol, SYMBOL_POINT);
      int    devPoints   = (nativePoint > 0)
                           ? (int)MathRound(slippagePoints * GREA_POINT_VALUE / nativePoint)
                           : slippagePoints;
      if(devPoints < 1)
         devPoints = 1;
      m_trade.SetDeviationInPoints(devPoints);
      m_trade.SetTypeFillingBySymbol(m_symbol);   // 自动适配券商成交模式
      return (m_symbol != "" && m_magic != 0 && m_logger != NULL);
     }

   //--- 市价开仓（修复三：Tick 驱动非阻塞重试，单次调用仅一次下单尝试）
   //    dir: SIGNAL_BUY/SIGNAL_SELL；sl/tp 传 0 表示不设置
   //    返回 true = 开仓成功；返回 false 时由 IsRetryPending() 区分：
   //      true  = 可重试失败，等待下一 Tick 再试（调用方保持 OPENING 态）
   //      false = 不可重试/累计 GREA_OPEN_MAX_ATTEMPTS 次重试耗尽，已放弃
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
      // 重试间隔保护：距上次尝试不足 GREA_RETRY_MIN_INTERVAL_SEC 秒则等待
      // 后续 Tick（防 Tick 密集时轰炸服务器）
      if(m_retryPending && TimeCurrent() - m_lastRetryTime < GREA_RETRY_MIN_INTERVAL_SEC)
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
         if(m_retryAttempt >= GREA_OPEN_MAX_ATTEMPTS)
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
                                             m_retryAttempt, GREA_OPEN_MAX_ATTEMPTS, rc), 60);
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
   //    修复C2：失败后本次调用内立即重试（最多 GREA_CLOSE_MAX_ATTEMPTS 次，
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
         for(int attempt = 1; attempt <= GREA_CLOSE_MAX_ATTEMPTS; attempt++)
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
                                       attempt, GREA_CLOSE_MAX_ATTEMPTS, reason, rc));
            // 评审五：重试间短暂退避，避免同一价格快照下连发被同样拒单。
            //   Sleep 在策略测试器中被忽略（不影响回测）；实盘 OnTick 内
            //   阻塞上限 (GREA_CLOSE_MAX_ATTEMPTS-1)×GREA_CLOSE_RETRY_SLEEP_MS
            //   毫秒，平仓属高优先级动作可接受；本轮仍失败时由 CLOSING
            //   态跨 Tick 重试兜底
            if(attempt < GREA_CLOSE_MAX_ATTEMPTS)
               Sleep(GREA_CLOSE_RETRY_SLEEP_MS);
           }
         m_logger.Error(StringFormat("平仓失败: 本次 %d 次重试耗尽, 将由后续 Tick 继续尝试: %s",
                                     GREA_CLOSE_MAX_ATTEMPTS, reason));
         return false;
        }
      return false;                        // 无持仓
     }
  };

#endif // __GREA_TRADEEXECUTOR_MQH__
