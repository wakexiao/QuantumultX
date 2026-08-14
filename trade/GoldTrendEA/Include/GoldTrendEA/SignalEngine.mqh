//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh |
//|  模块职责：信号引擎 —— 四层递进过滤：                              |
//|            ① H4 EMA20/60/200 排列定方向 → ② H4 ADX>阈值确认强度    |
//|            → ③ H1 MACD 交叉窗口动能确认 → ④ H1 唐奇安收盘突破触发   |
//|            输出 SIGNAL_BUY / SIGNAL_SELL / SIGNAL_NONE             |
//|  对应方案文档：第 4.1 节（趋势方向）、4.2 节（入场触发）            |
//+------------------------------------------------------------------+
#ifndef __GTEA_SIGNALENGINE_MQH__
#define __GTEA_SIGNALENGINE_MQH__

#include <GoldTrendEA/Config.mqh>
#include <GoldTrendEA/Logger.mqh>
#include <GoldTrendEA/MarketData.mqh>
#include <GoldTrendEA/Indicators.mqh>

//+------------------------------------------------------------------+
//| CSignalEngine：三重过滤信号引擎                                     |
//+------------------------------------------------------------------+
class CSignalEngine
  {
private:
   CMarketData      *m_market;             // 行情数据层（依赖注入）
   CIndicators      *m_ind;                // 指标计算层（依赖注入）
   CLogger          *m_logger;

   //--- 第①②层：趋势方向判定（H4 EMA 排列 + ADX 强度，方案 4.1）
   //    返回 +1 多头 / -1 空头 / 0 震荡或数据不足
   int               TrendDirection()
     {
      double emaF, emaM, emaS, adx, closeTrend;
      // 全部取已收盘K线（index 1），数据不足直接放弃本轮
      if(!m_ind.EmaFastTrend(emaF) || !m_ind.EmaMidTrend(emaM) ||
         !m_ind.EmaSlowTrend(emaS) || !m_ind.AdxTrend(adx))
         return 0;
      closeTrend = m_market.Close(InpTrendTF, 1);
      if(closeTrend <= 0)
         return 0;

      // ADX 强度过滤：低于阈值视为震荡，不交易
      if(adx <= InpADX_Threshold)
         return 0;

      // 可选增强：要求 ADX 递增（趋势强度增强中）
      if(InpADX_Rising)
        {
         double adxPrev;
         if(!m_ind.AdxTrend(adxPrev, 2))
            return 0;
         if(adx <= adxPrev)
            return 0;
        }

      // H4 多头排列 + 收盘价在 EMA 快线上方 → 多头方向
      if(emaF > emaM && emaM > emaS && closeTrend > emaF)
        {
         // H1 方向一致性确认：EMA20 > EMA60（避免大周期趋势中的深度回调期入场）
         double sF, sM;
         if(!m_ind.EmaFastSig(sF) || !m_ind.EmaMidSig(sM))
            return 0;
         if(sF > sM)
            return 1;
         return 0;
        }
      // H4 空头排列镜像
      if(emaF < emaM && emaM < emaS && closeTrend < emaF)
        {
         double sF, sM;
         if(!m_ind.EmaFastSig(sF) || !m_ind.EmaMidSig(sM))
            return 0;
         if(sF < sM)
            return -1;
         return 0;
        }
      return 0;
     }

   //--- 第③层：MACD 动能确认（H1，方案 4.2）
   //    做多：近 InpMACD_Window 根内发生金叉 且 当前主线>信号线；做空镜像
   bool              MomentumOk(const int dir)
     {
      int count = InpMACD_Window + 1;      // 多取一根用于交叉比较
      double main[], sig[];
      if(!m_ind.MacdMain(main, count) || !m_ind.MacdSignal(sig, count))
         return false;                     // 数据不足放弃（方案 6.2）

      // 当前动能状态：主线须在信号线的顺势一侧（main[0] 即最近已收盘K线）
      if(dir > 0 && main[0] <= sig[0]) return false;
      if(dir < 0 && main[0] >= sig[0]) return false;

      // 交叉窗口回溯：窗口内任意相邻两根发生同向交叉即满足
      for(int i = 0; i < InpMACD_Window; i++)
        {
         if(dir > 0 && main[i+1] <= sig[i+1] && main[i] > sig[i])
            return true;                   // 金叉：前一根在下/等于，本根在上
         if(dir < 0 && main[i+1] >= sig[i+1] && main[i] < sig[i])
            return true;                   // 死叉镜像
        }
      // TODO(优化开关，方案 4.2)：可选约束"交叉发生在零轴附近/上方"，
      //      留作 M4 回测优化阶段的对比项，当前不实现
      return false;
     }

   //--- 第④层：唐奇安收盘突破触发（H1，方案 4.2）
   //    做多：已收盘K线收盘价 > 前 N 根最高价（不含判定K线本身）；做空镜像
   bool              BreakoutOk(const int dir)
     {
      double closeSig = m_market.Close(InpSignalTF, 1);
      if(closeSig <= 0)
         return false;
      if(dir > 0)
        {
         double upper;
         if(!m_ind.DonchianUpper(upper, InpDonchian_Period))
            return false;
         return (closeSig > upper);
        }
      if(dir < 0)
        {
         double lower;
         if(!m_ind.DonchianLower(lower, InpDonchian_Period))
            return false;
         return (closeSig < lower);
        }
      return false;
     }

public:
                     CSignalEngine() : m_market(NULL), m_ind(NULL), m_logger(NULL) {}
                    ~CSignalEngine() {}

   //--- 初始化：注入行情层、指标层与日志
   bool              Init(CMarketData *market, CIndicators *ind, CLogger *logger)
     {
      m_market = market;
      m_ind    = ind;
      m_logger = logger;
      return (m_market != NULL && m_ind != NULL && m_logger != NULL);
     }

   //--- 信号评估主入口：仅应在信号周期新 K 线时调用（方案 3.4 主流程）
   //    三重过滤全部通过才输出方向信号；记录每层过滤结果便于诊断
   ENUM_SIGNAL_DIR   Evaluate()
     {
      int dir = TrendDirection();
      if(dir == 0)
        {
         m_logger.Info("信号评估: 趋势方向层未通过(震荡/ADX不足/数据不足)");
         return SIGNAL_NONE;
        }
      if(!MomentumOk(dir))
        {
         m_logger.Info(StringFormat("信号评估: 方向=%d 通过, MACD动能层未通过", dir));
         return SIGNAL_NONE;
        }
      if(!BreakoutOk(dir))
        {
         m_logger.Info(StringFormat("信号评估: 方向=%d+动能通过, 唐奇安突破层未通过", dir));
         return SIGNAL_NONE;
        }
      m_logger.Info(StringFormat("信号评估: 三重过滤全部通过, 方向=%s",
                                 dir > 0 ? "BUY" : "SELL"));
      return (dir > 0) ? SIGNAL_BUY : SIGNAL_SELL;
     }

   //--- 趋势反转检测（持仓管理期调用，方案 4.4「趋势反转强制离场」）
   //    posDir: 当前持仓方向(+1多/-1空)；返回 true = 应强制离场
   bool              IsTrendReversed(const int posDir)
     {
      // 条件一：H4 EMA20 与 EMA60 反向交叉（排列破坏）
      double emaF, emaM;
      if(m_ind.EmaFastTrend(emaF) && m_ind.EmaMidTrend(emaM))
        {
         if(posDir > 0 && emaF < emaM) return true;
         if(posDir < 0 && emaF > emaM) return true;
        }
      // 条件二：出现完整的反向三重信号
      // TODO(M2, 方案 4.4)：调用 Evaluate() 判断是否输出与持仓相反的信号；
      //      注意避免与开仓评估重复计算，可缓存本根K线的评估结果
      return false;
     }
  };

#endif // __GTEA_SIGNALENGINE_MQH__
