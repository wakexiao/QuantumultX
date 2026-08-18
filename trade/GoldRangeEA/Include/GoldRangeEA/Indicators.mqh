//+------------------------------------------------------------------+
//|                                                   Indicators.mqh |
//|  模块职责：指标计算层 —— 仅管理 2 个指标句柄：                      |
//|            ADX（趋势过滤，v1 §4.1）与 KDJ（iStochastic 近似，       |
//|            v1 §3.1/3.2 超买超卖确认）；批量 OHLC 序列读取            |
//|            （供 BoxEngine 箱体计算）；全部基于已收盘 K 线             |
//|  对应需求文档 v1.md：§2.1（箱体统计）、§3.1/3.2（KDJ）、§4.1（ADX）|
//+------------------------------------------------------------------+
#ifndef __GREA_INDICATORS_MQH__
#define __GREA_INDICATORS_MQH__

#include <GoldRangeEA/Config.mqh>
#include <GoldRangeEA/Logger.mqh>

//+------------------------------------------------------------------+
//| CIndicators：指标计算层                                            |
//+------------------------------------------------------------------+
class CIndicators
  {
private:
   string            m_symbol;
   CLogger          *m_logger;

   //--- 信号周期指标句柄
   int               m_hAdx;               // ADX(InpADX_Period) @信号周期（趋势过滤）
   int               m_hKdj;               // iStochastic(K,D,Slowing) @信号周期（KDJ 近似）

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
                                     m_hAdx(INVALID_HANDLE), m_hKdj(INVALID_HANDLE) {}
                    ~CIndicators() {}

   //--- 初始化：OnInit 中一次性创建全部句柄
   //    任一句柄失败返回 false → 主程序应 INIT_FAILED 拒绝启动
   bool              Init(const string symbol, CLogger *logger)
     {
      m_symbol = symbol;
      m_logger = logger;

      //--- ADX：趋势过滤（v1 §4.1，ADX ≤ 阈值 = 震荡可开仓）
      m_hAdx = iADX(m_symbol, InpSignalTF, InpADX_Period);

      //--- KDJ：MT5 无原生 KDJ，用 iStochastic 标准近似口径（v1 §3.1/3.2）
      //    参数顺序：Kperiod, Dperiod, slowing, ma_method, price_field
      //    STO_LOWHIGH = 经典 KD 的高低价口径（而非收盘价口径）
      m_hKdj = iStochastic(m_symbol, InpSignalTF, InpKDJ_K, InpKDJ_D,
                           InpKDJ_Slowing, MODE_SMA, STO_LOWHIGH);

      bool ok = true;
      if(!CheckHandle(m_hAdx, "ADX@SignalTF"))  ok = false;
      if(!CheckHandle(m_hKdj, "KDJ@SignalTF"))  ok = false;
      return ok;
     }

   //--- 释放全部句柄（OnDeinit 中调用）
   //    释放后将句柄成员重置为 INVALID_HANDLE，防止重复释放与释放后误用
   void              Release()
     {
      if(m_hAdx != INVALID_HANDLE) { IndicatorRelease(m_hAdx); m_hAdx = INVALID_HANDLE; }
      if(m_hKdj != INVALID_HANDLE) { IndicatorRelease(m_hKdj); m_hKdj = INVALID_HANDLE; }
     }

   //--- CopyBuffer 通用封装：读单个值（shift≥1，已收盘K线）
   //    返回 false = 数据不足/未同步 → 调用方应静默放弃本轮
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

   //--- ADX 主线（v1 §4.1 趋势过滤；buffer 0 = MAIN_LINE）
   bool              AdxValue(double &v, const int shift = 1)
     {
      return GetValue(m_hAdx, 0, shift, v);
     }

   //--- KDJ J 值（v1 §3.1/3.2 超买超卖确认）
   //    MT5 无原生 KDJ，此为业界标准近似口径：
   //    iStochastic(K,D,Slowing, MODE_SMA, STO_LOWHIGH) 的
   //    %K（buffer 0 = MAIN_LINE）与 %D（buffer 1 = SIGNAL_LINE），
   //    J = 3K − 2D（J 对超买超卖比 K/D 更灵敏，符合 v1 语义）
   bool              KdjJ(double &j, const int shift = 1)
     {
      double k = 0.0, d = 0.0;
      if(!GetValue(m_hKdj, 0, shift, k))    // %K
         return false;
      if(!GetValue(m_hKdj, 1, shift, d))    // %D
         return false;
      j = 3.0 * k - 2.0 * d;
      return true;
     }

   //=== 批量 OHLC 序列（供 BoxEngine 箱体计算，v1 §2.1）===============
   //    一次 CopyHigh/CopyLow 取 count 根已收盘 K 线（start=1 起），
   //    arr[0] = 最近一根已收盘K线，时间序列方向
   bool              CopyClosedHighs(const int count, double &arr[])
     {
      ArraySetAsSeries(arr, true);
      if(CopyHigh(m_symbol, InpSignalTF, 1, count, arr) < count)
         return false;
      return true;
     }

   bool              CopyClosedLows(const int count, double &arr[])
     {
      ArraySetAsSeries(arr, true);
      if(CopyLow(m_symbol, InpSignalTF, 1, count, arr) < count)
         return false;
      return true;
     }
  };

#endif // __GREA_INDICATORS_MQH__
