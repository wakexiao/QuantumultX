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

   //--- G4：同一根信号周期K线内的评估结果缓存（开仓评估与持仓期
   //    反向信号检测共用，避免重复 CopyBuffer 与重复日志）
   datetime          m_lastEvalBarTime;    // 缓存所属的信号周期K线开盘时间
   ENUM_SIGNAL_DIR   m_lastEvalDir;        // 缓存的评估结果

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

      // v0.31 short-term relaxation: M15 entries can miss the exact cross.
      // If MACD is aligned and the latest histogram is strengthening, pass.
      double histNow  = main[0] - sig[0];
      double histPrev = main[1] - sig[1];
      if(dir > 0 && histNow > 0 && histNow > histPrev)
         return true;
      if(dir < 0 && histNow < 0 && histNow < histPrev)
         return true;

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

   //--- D2/F4：各层诊断串（仅 InpVerboseSignalLog=true 时调用，附关键
   //    指标数值便于复盘；额外 CopyBuffer 只在开启详细日志时发生）
   string            TrendDiag()
     {
      double emaF = 0, emaM = 0, emaS = 0, adx = 0;
      if(!m_ind.EmaFastTrend(emaF) || !m_ind.EmaMidTrend(emaM) ||
         !m_ind.EmaSlowTrend(emaS) || !m_ind.AdxTrend(adx))
         return "趋势层指标数据不足";
      return StringFormat("EMA%d=%.2f EMA%d=%.2f EMA%d=%.2f ADX=%.1f",
                          InpEMA_Fast, emaF, InpEMA_Mid, emaM,
                          InpEMA_Slow, emaS, adx);
     }

   string            MacdDiag()
     {
      double main[], sig[];
      if(!m_ind.MacdMain(main, 2) || !m_ind.MacdSignal(sig, 2))
         return "MACD数据不足";
      return StringFormat("MACD主线=%.3f 信号线=%.3f", main[0], sig[0]);
     }

   string            BreakoutDiag()
     {
      double closeSig = m_market.Close(InpSignalTF, 1);
      double upper = 0, lower = 0;
      m_ind.DonchianUpper(upper, InpDonchian_Period);
      m_ind.DonchianLower(lower, InpDonchian_Period);
      return StringFormat("收盘=%.2f 唐奇安上轨=%.2f 下轨=%.2f", closeSig, upper, lower);
     }

public:
                     CSignalEngine() : m_market(NULL), m_ind(NULL), m_logger(NULL),
                                       m_lastEvalBarTime(0), m_lastEvalDir(SIGNAL_NONE) {}
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
   //    三重过滤全部通过才输出方向信号；逐层未通过的 Info 日志默认关闭
   //    （D2 降噪），InpVerboseSignalLog=true 时输出并附关键指标数值（F4）；
   //    缓存机制下本函数只在实际评估那次执行，日志不会重复
   ENUM_SIGNAL_DIR   Evaluate()
     {
      int dir = TrendDirection();
      if(dir == 0)
        {
         if(InpVerboseSignalLog)
            m_logger.Info("信号评估: 趋势方向层未通过(震荡/ADX不足/数据不足) [" + TrendDiag() + "]");
         return SIGNAL_NONE;
        }
      if(!MomentumOk(dir))
        {
         if(InpVerboseSignalLog)
            m_logger.Info(StringFormat("信号评估: 方向=%d 通过, MACD动能层未通过 [%s]",
                                       dir, MacdDiag()));
         return SIGNAL_NONE;
        }
      if(!BreakoutOk(dir))
        {
         if(InpVerboseSignalLog)
            m_logger.Info(StringFormat("信号评估: 方向=%d+动能通过, 唐奇安突破层未通过 [%s]",
                                       dir, BreakoutDiag()));
         return SIGNAL_NONE;
        }
      // 三重过滤全部通过属关键事件，始终记录；详细日志时附全层指标值
      m_logger.Info(StringFormat("信号评估: 三重过滤全部通过, 方向=%s%s",
                                 dir > 0 ? "BUY" : "SELL",
                                 InpVerboseSignalLog
                                 ? " [" + TrendDiag() + " " + MacdDiag() + " " + BreakoutDiag() + "]"
                                 : ""));
      return (dir > 0) ? SIGNAL_BUY : SIGNAL_SELL;
     }

   //--- G4：带同K线缓存的评估入口 —— 同一根信号周期K线内重复调用
   //    直接返回缓存结果，避免开仓评估与反向离场检测重复计算指标
   ENUM_SIGNAL_DIR   EvaluateCached()
     {
      datetime barTime = m_market.BarTime(InpSignalTF, 0);
      if(barTime > 0 && barTime == m_lastEvalBarTime)
         return m_lastEvalDir;             // 本根K线已评估过，直接取缓存
      ENUM_SIGNAL_DIR dir = Evaluate();
      if(barTime > 0)                      // 历史未同步(barTime=0)时不缓存
        {
         m_lastEvalBarTime = barTime;
         m_lastEvalDir     = dir;
        }
      return dir;
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
      // 条件二（G4）：出现完整的反向三重信号（方向+动能+突破全部
      // 反向成立）—— 复用带缓存的 Evaluate，同一根K线内不重复计算
      ENUM_SIGNAL_DIR sig = EvaluateCached();
      if(posDir > 0 && sig == SIGNAL_SELL)
        {
         m_logger.Info("反转检测: 持多单期间出现完整反向三重卖出信号");
         return true;
        }
      if(posDir < 0 && sig == SIGNAL_BUY)
        {
         m_logger.Info("反转检测: 持空单期间出现完整反向三重买入信号");
         return true;
        }
      return false;
     }
  };

#endif // __GTEA_SIGNALENGINE_MQH__
