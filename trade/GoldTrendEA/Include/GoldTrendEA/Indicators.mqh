//+------------------------------------------------------------------+
//|                                                   Indicators.mqh |
//|  模块职责：指标计算层 —— 统一管理 EMA/ADX/MACD/ATR 指标句柄，       |
//|            封装 CopyBuffer 读取（全部基于已收盘 K 线 index 1），    |
//|            唐奇安通道用 iHighest/iLowest 直接计算（不依赖自定义指标）|
//|  对应方案文档：第 3.2 节（CIndicators）、6.2 节（句柄与 CopyBuffer）|
//+------------------------------------------------------------------+
#ifndef __GTEA_INDICATORS_MQH__
#define __GTEA_INDICATORS_MQH__

#include <GoldTrendEA/Config.mqh>
#include <GoldTrendEA/Logger.mqh>

//+------------------------------------------------------------------+
//| CIndicators：指标计算层                                            |
//+------------------------------------------------------------------+
class CIndicators
  {
private:
   string            m_symbol;
   CLogger          *m_logger;

   //--- 趋势周期（H4）指标句柄（方案 4.1）
   int               m_hEmaFastTrend;      // EMA20 @H4
   int               m_hEmaMidTrend;       // EMA60 @H4
   int               m_hEmaSlowTrend;      // EMA200 @H4
   int               m_hAdxTrend;          // ADX(14) @H4

   //--- 信号周期（H1）指标句柄（方案 4.2 / 4.4）
   int               m_hEmaFastSig;        // EMA20 @H1
   int               m_hEmaMidSig;         // EMA60 @H1
   int               m_hMacdSig;           // MACD(12,26,9) @H1
   int               m_hAtrSig;            // ATR(14) @H1（止损/跟踪用）

   //--- 校验单个句柄有效性，无效则记 ERROR
   bool              CheckHandle(const int handle, const string name)
     {
      if(handle == INVALID_HANDLE)
        {
         m_logger.Error("指标句柄创建失败: " + name + ", err=" + (string)GetLastError());
         return false;
        }
      return true;
     }

public:
                     CIndicators() : m_symbol(""), m_logger(NULL),
                                     m_hEmaFastTrend(INVALID_HANDLE), m_hEmaMidTrend(INVALID_HANDLE),
                                     m_hEmaSlowTrend(INVALID_HANDLE), m_hAdxTrend(INVALID_HANDLE),
                                     m_hEmaFastSig(INVALID_HANDLE), m_hEmaMidSig(INVALID_HANDLE),
                                     m_hMacdSig(INVALID_HANDLE), m_hAtrSig(INVALID_HANDLE) {}
                    ~CIndicators() {}

   //--- 初始化：OnInit 中一次性创建全部句柄（方案 6.2）
   //    任一句柄失败返回 false → 主程序应 INIT_FAILED 拒绝启动
   bool              Init(const string symbol, CLogger *logger)
     {
      m_symbol = symbol;
      m_logger = logger;

      m_hEmaFastTrend = iMA(m_symbol, InpTrendTF, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      m_hEmaMidTrend  = iMA(m_symbol, InpTrendTF, InpEMA_Mid,  0, MODE_EMA, PRICE_CLOSE);
      m_hEmaSlowTrend = iMA(m_symbol, InpTrendTF, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      m_hAdxTrend     = iADX(m_symbol, InpTrendTF, InpADX_Period);

      m_hEmaFastSig   = iMA(m_symbol, InpSignalTF, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      m_hEmaMidSig    = iMA(m_symbol, InpSignalTF, InpEMA_Mid,  0, MODE_EMA, PRICE_CLOSE);
      m_hMacdSig      = iMACD(m_symbol, InpSignalTF, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
      m_hAtrSig       = iATR(m_symbol, InpSignalTF, InpATR_Period);

      bool ok = true;
      if(!CheckHandle(m_hEmaFastTrend, "EMA_Fast@TrendTF"))  ok = false;
      if(!CheckHandle(m_hEmaMidTrend,  "EMA_Mid@TrendTF"))   ok = false;
      if(!CheckHandle(m_hEmaSlowTrend, "EMA_Slow@TrendTF"))  ok = false;
      if(!CheckHandle(m_hAdxTrend,     "ADX@TrendTF"))       ok = false;
      if(!CheckHandle(m_hEmaFastSig,   "EMA_Fast@SignalTF")) ok = false;
      if(!CheckHandle(m_hEmaMidSig,    "EMA_Mid@SignalTF"))  ok = false;
      if(!CheckHandle(m_hMacdSig,      "MACD@SignalTF"))     ok = false;
      if(!CheckHandle(m_hAtrSig,       "ATR@SignalTF"))      ok = false;
      return ok;
     }

   //--- 释放全部句柄（OnDeinit 中调用，方案 6.2）
   //    C1：释放后将句柄成员重置为 INVALID_HANDLE，防止重复释放与释放后误用
   void              Release()
     {
      if(m_hEmaFastTrend != INVALID_HANDLE) { IndicatorRelease(m_hEmaFastTrend); m_hEmaFastTrend = INVALID_HANDLE; }
      if(m_hEmaMidTrend  != INVALID_HANDLE) { IndicatorRelease(m_hEmaMidTrend);  m_hEmaMidTrend  = INVALID_HANDLE; }
      if(m_hEmaSlowTrend != INVALID_HANDLE) { IndicatorRelease(m_hEmaSlowTrend); m_hEmaSlowTrend = INVALID_HANDLE; }
      if(m_hAdxTrend     != INVALID_HANDLE) { IndicatorRelease(m_hAdxTrend);     m_hAdxTrend     = INVALID_HANDLE; }
      if(m_hEmaFastSig   != INVALID_HANDLE) { IndicatorRelease(m_hEmaFastSig);   m_hEmaFastSig   = INVALID_HANDLE; }
      if(m_hEmaMidSig    != INVALID_HANDLE) { IndicatorRelease(m_hEmaMidSig);    m_hEmaMidSig    = INVALID_HANDLE; }
      if(m_hMacdSig      != INVALID_HANDLE) { IndicatorRelease(m_hMacdSig);      m_hMacdSig      = INVALID_HANDLE; }
      if(m_hAtrSig       != INVALID_HANDLE) { IndicatorRelease(m_hAtrSig);       m_hAtrSig       = INVALID_HANDLE; }
     }

   //--- CopyBuffer 通用封装：读单个值（shift≥1，已收盘K线）
   //    返回 false = 数据不足/未同步 → 调用方应静默放弃本轮（方案 6.2）
   bool              GetValue(const int handle, const int buffer, const int shift, double &value)
     {
      double buf[1];
      if(CopyBuffer(handle, buffer, shift, 1, buf) < 1)
         return false;
      value = buf[0];
      return true;
     }

   //--- CopyBuffer 通用封装：读一段序列（start 起 count 根，时间序列方向）
   bool              GetSeries(const int handle, const int buffer, const int start,
                               const int count, double &arr[])
     {
      ArraySetAsSeries(arr, true);
      if(CopyBuffer(handle, buffer, start, count, arr) < count)
         return false;
      return true;
     }

   //=== 便捷读取接口（shift=1 默认取已收盘K线）========================

   //--- 趋势周期 EMA 三线
   bool              EmaFastTrend(double &v, const int shift = 1) { return GetValue(m_hEmaFastTrend, 0, shift, v); }
   bool              EmaMidTrend(double &v, const int shift = 1)  { return GetValue(m_hEmaMidTrend, 0, shift, v);  }
   bool              EmaSlowTrend(double &v, const int shift = 1) { return GetValue(m_hEmaSlowTrend, 0, shift, v); }

   //--- 趋势周期 ADX 主线（buffer 0 = MAIN_LINE）
   bool              AdxTrend(double &v, const int shift = 1)     { return GetValue(m_hAdxTrend, 0, shift, v); }

   //--- 信号周期 EMA 快/中线
   bool              EmaFastSig(double &v, const int shift = 1)   { return GetValue(m_hEmaFastSig, 0, shift, v); }
   bool              EmaMidSig(double &v, const int shift = 1)    { return GetValue(m_hEmaMidSig, 0, shift, v);  }

   //--- 信号周期 MACD：主线序列 + 信号线序列（供交叉窗口回溯，方案 4.2）
   //    arr[0] 对应 shift=1（最近一根已收盘K线），count 建议 InpMACD_Window+1
   bool              MacdMain(double &arr[], const int count)     { return GetSeries(m_hMacdSig, 0, 1, count, arr); }
   bool              MacdSignal(double &arr[], const int count)   { return GetSeries(m_hMacdSig, 1, 1, count, arr); }

   //--- 信号周期 ATR（止损距离/跟踪止损基准，方案 4.4）
   bool              AtrSig(double &v, const int shift = 1)       { return GetValue(m_hAtrSig, 0, shift, v); }

   //--- 唐奇安通道上/下轨（方案 4.2）：
   //    定义 = 「前 period 根 K 线」的最高/最低价，不含当前已收盘判定K线(index 1)，
   //    故检索起点为 index 2，即 index 2 ~ (period+1)
   bool              DonchianUpper(double &v, const int period)
     {
      int idx = iHighest(m_symbol, InpSignalTF, MODE_HIGH, period, 2);
      if(idx < 0)
         return false;
      v = iHigh(m_symbol, InpSignalTF, idx);
      return (v > 0);
     }

   bool              DonchianLower(double &v, const int period)
     {
      int idx = iLowest(m_symbol, InpSignalTF, MODE_LOW, period, 2);
      if(idx < 0)
         return false;
      v = iLow(m_symbol, InpSignalTF, idx);
      return (v > 0);
     }

   //--- 结构点：近 swingBars 根已收盘K线的最低/最高（初始止损候选，方案 4.4）
   bool              SwingLow(double &v, const int swingBars)
     {
      int idx = iLowest(m_symbol, InpSignalTF, MODE_LOW, swingBars, 1);
      if(idx < 0) return false;
      v = iLow(m_symbol, InpSignalTF, idx);
      return (v > 0);
     }

   bool              SwingHigh(double &v, const int swingBars)
     {
      int idx = iHighest(m_symbol, InpSignalTF, MODE_HIGH, swingBars, 1);
      if(idx < 0) return false;
      v = iHigh(m_symbol, InpSignalTF, idx);
      return (v > 0);
     }
  };

#endif // __GTEA_INDICATORS_MQH__
