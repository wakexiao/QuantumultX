//+------------------------------------------------------------------+
//|                                                  BoxEngine.mqh |
//|  模块职责：箱体震荡策略核心引擎 ——                                  |
//|            ① 箱体识别与有效性过滤（v1 §2.1/§2.2/§2.3，M15 新K线刷新）|
//|            ② Tick 级入场三级漏斗（§3.1/§3.2/§3.3：有效箱体→沿位→KDJ）|
//|            ③ 止盈止损距离计算（§5.1/§5.2）与盈亏比校验（§5.3）       |
//|  依赖注入：CIndicators / CLogger（沿用模板 SignalEngine 构造模式）   |
//+------------------------------------------------------------------+
#ifndef __GREA_BOXENGINE_MQH__
#define __GREA_BOXENGINE_MQH__

#include <GoldRangeEA/Config.mqh>
#include <GoldRangeEA/Logger.mqh>
#include <GoldRangeEA/Indicators.mqh>

//--- 箱体状态快照（成员缓存，GetBox 暴露给主 EA 做快照与日志）
struct SBoxState
  {
   double            upper;       // 箱体上沿（压力位，v1 §2.1）
   double            lower;       // 箱体下沿（支撑位，v1 §2.1）
   double            height;      // 箱体高度（价格单位）
   double            entryLow;    // 做多入场判定线 = lower + 入场容差（§3.1）
   double            entryHigh;   // 做空入场判定线 = upper − 入场容差（§3.2）
   double            tpDist;      // 止盈距离（价格单位；模式A=height×比例，模式B=height 名义值）
   double            slDist;      // 止损距离（价格单位 = height×止损比例）
   bool              valid;       // 是否有效箱体（§2.2 全部条件满足）
   datetime          barTime;     // 本快照的计算基准K线开盘时刻（§2.3 刷新戳）
  };

//+------------------------------------------------------------------+
//| CBoxEngine：箱体识别与入场信号引擎                                   |
//+------------------------------------------------------------------+
class CBoxEngine
  {
private:
   CIndicators      *m_ind;               // 指标计算层（依赖注入）
   CLogger          *m_logger;            // 日志（依赖注入）
   SBoxState         m_box;               // 箱体状态缓存
   datetime          m_lastDiagTime;      // verbose 诊断日志节流（防 Tick 级刷屏）

   //--- 复位缓存为无效空箱体
   void              Reset()
     {
      m_box.upper    = 0.0;
      m_box.lower    = 0.0;
      m_box.height   = 0.0;
      m_box.entryLow = 0.0;
      m_box.entryHigh= 0.0;
      m_box.tpDist   = 0.0;
      m_box.slDist   = 0.0;
      m_box.valid    = false;
      m_box.barTime  = 0;
     }

   //--- 有效性翻转日志（v1 §2.2→§2.3 观测）：
   //    无效→有效 或 有效→无效 各记一条；数值漂移（有效→有效）不刷屏，
   //    仅 InpVerboseSignalLog 时记录（决策记录 D1：数值漂移属正常动态更新）
   void              LogValidityFlip(const bool wasValid, const string failReason)
     {
      if(m_box.valid && !wasValid)
         m_logger.Notify(StringFormat(
            "有效箱体形成: 上沿=%.2f 下沿=%.2f 高度=%.1f 点 (K线数=%d, ADX过滤通过)",
            m_box.upper, m_box.lower, m_box.height / GREA_POINT_VALUE, InpBoxBars));
      else if(!m_box.valid && wasValid)
         m_logger.Info("箱体失效: " + failReason);
      else if(!m_box.valid && InpVerboseSignalLog)
         m_logger.Info("箱体未形成: " + failReason);
      else if(m_box.valid && wasValid && InpVerboseSignalLog)
         m_logger.Info(StringFormat("箱体更新: 上沿=%.2f 下沿=%.2f 高度=%.1f 点",
                                    m_box.upper, m_box.lower, m_box.height / GREA_POINT_VALUE));
     }

public:
                     CBoxEngine() : m_ind(NULL), m_logger(NULL), m_lastDiagTime(0)
                    { Reset(); }
                    ~CBoxEngine() {}

   //--- 初始化：注入指标层与日志
   bool              Init(CIndicators *ind, CLogger *logger)
     {
      m_ind    = ind;
      m_logger = logger;
      Reset();
      return (m_ind != NULL && m_logger != NULL);
     }

   //+------------------------------------------------------------------+
   //| 箱体刷新（v1 §2.1/§2.2/§2.3）：仅信号周期新 K 线时由主 EA 调用     |
   //|   流程：批量取 N 根已收盘 High/Low → 上下沿/触碰计数 → 高度过滤   |
   //|   → 触碰次数过滤 → ADX≤阈值过滤 → 预计算入场线与止盈止损距离       |
   //|   说明：触碰判定必须基于「最终」上下沿，故对已拷贝数组做两趟线性   |
   //|   扫描（求沿 → 计数），O(N) 无嵌套循环                             |
   //+------------------------------------------------------------------+
   void              OnNewBar()
     {
      bool   wasValid = m_box.valid;
      string reason   = "";

      m_box.barTime = iTime(_Symbol, InpSignalTF, 0);   // 刷新戳=当前K线开盘时刻
      m_box.valid   = false;                            // 先置无效，逐级过滤后置回

      //--- ① 批量取 N 根已收盘 K 线 High/Low（各一次 Copy，v1 §2.1）
      double highs[], lows[];
      if(!m_ind.CopyClosedHighs(InpBoxBars, highs) ||
         !m_ind.CopyClosedLows(InpBoxBars, lows))
        {
         m_logger.WarnThrottled("box_data", StringFormat(
            "箱体计算: High/Low 数据不足(需 %d 根), 本轮保持无箱体", InpBoxBars));
         LogValidityFlip(wasValid, "高低价数据不足");
         return;
        }

      //--- ② 第一趟线性扫描：上沿=max(high)、下沿=min(low)
      double upper = highs[0];
      double lower = lows[0];
      for(int i = 1; i < InpBoxBars; i++)
        {
         if(highs[i] > upper) upper = highs[i];
         if(lows[i]  < lower) lower = lows[i];
        }
      double height = upper - lower;

      //--- ③ 高度过滤（v1 §2.2-1/2：[15,80] 点，太小无利润/太大是趋势）
      if(height < PtsToPrice(InpBoxMinPoints))
         reason = StringFormat("高度 %.1f 点 < 最小 %d 点",
                               height / GREA_POINT_VALUE, InpBoxMinPoints);
      else if(height > PtsToPrice(InpBoxMaxPoints))
         reason = StringFormat("高度 %.1f 点 > 最大 %d 点",
                               height / GREA_POINT_VALUE, InpBoxMaxPoints);

      //--- ④ 第二趟线性扫描：触碰计数（基于最终上下沿，v1 §2.2-3）
      int touchUp = 0, touchDown = 0;
      if(reason == "")
        {
         double tol = PtsToPrice(InpTouchTolerance);
         for(int i = 0; i < InpBoxBars; i++)
           {
            if(highs[i] >= upper - tol) touchUp++;      // 上沿触碰：high ≥ 上沿−容差
            if(lows[i]  <= lower + tol) touchDown++;    // 下沿触碰：low ≤ 下沿+容差
           }
         if(touchUp < InpMinTouches || touchDown < InpMinTouches)
            reason = StringFormat("触碰不足(上沿 %d 次/下沿 %d 次, 需各 ≥%d)",
                                  touchUp, touchDown, InpMinTouches);
        }

      //--- ⑤ ADX 趋势过滤（v1 §2.2-4 / §4.1：ADX(shift=1) ≤ 25 才算震荡箱体）
      if(reason == "")
        {
         double adx = 0.0;
         if(!m_ind.AdxValue(adx))
            reason = "ADX 数据不足";
         else if(adx > InpADX_Threshold)
            reason = StringFormat("ADX %.1f > %d, 已是趋势行情", adx, InpADX_Threshold);
        }

      //--- ⑥ 全部通过 → 填充箱体缓存并预计算入场线/止盈止损距离
      if(reason != "")
        {
         LogValidityFlip(wasValid, reason);
         return;
        }
      m_box.upper    = upper;
      m_box.lower    = lower;
      m_box.height   = height;
      m_box.entryLow = lower + PtsToPrice(InpEntryTolerance);   // 做多需 price ≤ 此线
      m_box.entryHigh= upper - PtsToPrice(InpEntryTolerance);   // 做空需 price ≥ 此线
      // 止盈距离（v1 §5.1）：模式A=高度×比例；模式B=高度（名义距离，
      // CalcStops 中模式B直接用对侧沿价，tpDist 仅供 CheckMinRR 口径）
      m_box.tpDist   = (InpTPMode == TP_MODE_RATIO) ? height * InpTPRatio : height;
      // 止损距离（v1 §5.2）：高度×止损比例
      m_box.slDist   = height * InpSLRatio;
      m_box.valid    = true;
      LogValidityFlip(wasValid, "");
     }

   //+------------------------------------------------------------------+
   //| Tick 级入场三级漏斗（v1 §3.1/§3.2/§3.3，从最便宜到最贵）：         |
   //|   L1 无有效箱体 → NONE（§3.1-1）                                  |
   //|   L2 位置过滤：做多需 price ≤ entryLow、做空需 price ≥ entryHigh， |
   //|      两次 double 比较，箱体中部天然拒绝（§3.3 绝不在中部开仓）     |
   //|   L3 KDJ 确认：做多 J ≤ 超卖阈值、做空 J ≥ 超买阈值（数据不足静默） |
   //|   注：price 口径由主 EA 决定（做多传 Ask、做空传 Bid，见主 EA 注释）|
   //+------------------------------------------------------------------+
   ENUM_SIGNAL_DIR   EvaluateEntry(const double price)
     {
      //--- L1：无有效箱体
      if(!m_box.valid)
         return SIGNAL_NONE;

      //--- L2：位置过滤（§3.1-2 / §3.2-2 / §3.3）
      bool nearLow  = (price <= m_box.entryLow);    // 价格到达下沿+容差内
      bool nearHigh = (price >= m_box.entryHigh);   // 价格到达上沿−容差内
      if(!nearLow && !nearHigh)
        {
         if(InpVerboseSignalLog && TimeCurrent() - m_lastDiagTime >= 60)
           {
            m_lastDiagTime = TimeCurrent();
            m_logger.Info(StringFormat("入场评估: 价 %.2f 在箱体中部(入场区 %.2f~%.2f), 拒绝",
                                       price, m_box.entryLow, m_box.entryHigh));
           }
         return SIGNAL_NONE;
        }

      //--- L3：KDJ 超买超卖确认（§3.1-3 / §3.2-3）
      double j = 0.0;
      if(!m_ind.KdjJ(j))
         return SIGNAL_NONE;                        // 数据不足静默放弃本轮
      if(nearLow && j <= InpKDJOversold)
         return SIGNAL_BUY;
      if(nearHigh && j >= InpKDJOverbought)
         return SIGNAL_SELL;
      if(InpVerboseSignalLog && TimeCurrent() - m_lastDiagTime >= 60)
        {
         m_lastDiagTime = TimeCurrent();
         m_logger.Info(StringFormat("入场评估: 已到沿位但 J=%.1f 未达阈值(超卖≤%d/超买≥%d), 放弃",
                                    j, InpKDJOversold, InpKDJOverbought));
        }
      return SIGNAL_NONE;
     }

   //+------------------------------------------------------------------+
   //| 止盈止损计算（v1 §5.1/§5.2）                                       |
   //|   SL = entry ∓ slDist，且必须置于箱体外侧（§5.2）                  |
   //|   多单：SL = min(entry−slDist, lower−1点)；空单：SL = max(entry+slDist, upper+1点)|
   //|   （若按比例计算的 SL 仍在箱体内，取更远的箱体外侧价，防假突破扫损）|
   //|   TP：模式A = entry ± tpDist；模式B = 箱体对侧沿价（§5.1）          |
   //|   返回 false = 无有效箱体/方向非法（调用方放弃开仓）                |
   //+------------------------------------------------------------------+
   bool              CalcStops(const ENUM_SIGNAL_DIR dir, const double entry,
                               double &sl, double &tp)
     {
      if(!m_box.valid || m_box.slDist <= 0 || m_box.tpDist <= 0)
         return false;
      if(dir == SIGNAL_BUY)
        {
         double slByRatio  = entry - m_box.slDist;                 // 按比例的止损
         double slOutside  = m_box.lower - PtsToPrice(1);          // 下沿外 1 点缓冲
         sl = MathMin(slByRatio, slOutside);                       // 取更远者，确保箱体外
         tp = (InpTPMode == TP_MODE_RATIO) ? entry + m_box.tpDist  // 模式A：比例距离
                                           : m_box.upper;          // 模式B：对侧（上沿）
        }
      else if(dir == SIGNAL_SELL)
        {
         double slByRatio  = entry + m_box.slDist;
         double slOutside  = m_box.upper + PtsToPrice(1);          // 上沿外 1 点缓冲
         sl = MathMax(slByRatio, slOutside);
         tp = (InpTPMode == TP_MODE_RATIO) ? entry - m_box.tpDist
                                           : m_box.lower;          // 模式B：对侧（下沿）
        }
      else
         return false;
      return true;
     }

   //+------------------------------------------------------------------+
   //| 盈亏比校验（v1 §5.3）：tpDist ÷ slDist ≥ InpMinRR                 |
   //|   默认 0.5/0.4 = 1.25 ≥ 1.2 通过；不满足则主 EA 记 INFO 放弃开仓   |
   //|   注：模式B口径 tpDist=height，比值恒 1/SLRatio=2.5，自然通过      |
   //+------------------------------------------------------------------+
   bool              CheckMinRR() const
     {
      if(m_box.slDist <= 0)
         return false;
      return (m_box.tpDist / m_box.slDist >= InpMinRR);
     }

   //--- 暴露箱体缓存快照（供主 EA 持仓突破联动基准、GV 持久化与日志）
   //    返回 false = 当前无有效箱体
   bool              GetBox(SBoxState &out) const
     {
      if(!m_box.valid)
         return false;
      out = m_box;
      return true;
     }

   //--- 止盈/止损距离只读访问（主 EA 日志输出盈亏比用；无效箱体返回 0）
   double            TpDist() const { return m_box.valid ? m_box.tpDist : 0.0; }
   double            SlDist() const { return m_box.valid ? m_box.slDist : 0.0; }
  };

#endif // __GREA_BOXENGINE_MQH__
