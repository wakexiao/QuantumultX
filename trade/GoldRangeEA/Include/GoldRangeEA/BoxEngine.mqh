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
   double            entryLow;    // 做多入场区上界 = lower + 入场带（§3.1，双边带判定）
   double            entryHigh;   // 做空入场区下界 = upper − 入场带（§3.2，双边带判定）
   double            entryBand;   // 入场带半宽 = max(高度×入场容差%, 容差下限点数)（沿位双边判定，防接飞刀）
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
      m_box.entryBand= 0.0;
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

      //--- ③ 高度过滤（v1 §2.2-1/2：小于最小高度无利润空间/大于最大高度
      //    已是趋势；默认 [500,3000] 点按 XAUUSD 实际波动量级重标定，
      //    见 README「波动率重标定」节）
      if(height < PtsToPrice(InpBoxMinPoints))
         reason = StringFormat("高度 %.1f 点 < 最小 %d 点",
                               height / GREA_POINT_VALUE, InpBoxMinPoints);
      else if(height > PtsToPrice(InpBoxMaxPoints))
         reason = StringFormat("高度 %.1f 点 > 最大 %d 点",
                               height / GREA_POINT_VALUE, InpBoxMaxPoints);

      //--- ④ 第二趟线性扫描：触碰计数（基于最终上下沿，v1 §2.2-3）
      //    触碰容差百分比化：max(高度×触碰容差%, 下限点数)——固定点数
      //    容差不随箱体量级缩放（小箱体上过宽漏计、大箱体上过窄漏计），
      //    百分比制下触碰带宽与箱体高度同比例缩放，下限防极矮箱体退化
      int touchUp = 0, touchDown = 0;
      if(reason == "")
        {
         double tol = MathMax(height * InpTouchTolerancePct / 100.0,
                              PtsToPrice(InpTouchTolMinPoints));
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
      // 入场带百分比化：band = max(高度×入场容差%, 下限点数)，随箱体量级
      // 自适应缩放；沿位判定为双边带（见 EvaluateEntry），entryLow/entryHigh
      // 分别为做多/做空入场区靠箱体内侧的边界
      m_box.entryBand= MathMax(height * InpEntryTolerancePct / 100.0,
                               PtsToPrice(InpEntryTolMinPoints));
      m_box.entryLow = lower + m_box.entryBand;   // 做多需 price ≤ 此线（且 ≥ 下沿−band）
      m_box.entryHigh= upper - m_box.entryBand;   // 做空需 price ≥ 此线（且 ≤ 上沿+band）
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
   //|   L2 位置过滤（双边带，防接飞刀 + 防开仓即秒平，v1.10）：           |
   //|      做多需 price ≤ 下沿+band（内缘，入场侧报价/成交价口径）且      |
   //|      opposite ≥ 下沿−band（外缘，对侧报价）；做空需 price ≥ 上沿−   |
   //|      band 且 opposite ≤ 上沿+band。外缘以对侧报价判定的原因：突破   |
   //|      联动止损以对侧报价判定（多单看 Bid 跌破下沿−突破点数），若外缘 |
   //|      用入场侧报价，当 band+点差 > 突破点数时存在开仓瞬间即触发突破  |
   //|      止损平仓的窗口（每次小亏点差、连亏数笔即触发暂停）；对侧口径下  |
   //|      开仓瞬间对侧报价距突破联动线至少还有 InpBreakoutPoints−band 的 |
   //|      余量，从根上消除该窗口。价格暴跌/涨到沿位外侧任意远处亦不算     |
   //|      "到达沿位"（防接飞刀）；箱体中部天然拒绝（§3.3 绝不在中部开仓）|
   //|   L3 KDJ 确认（2 根已收盘 K 线窗口）：最近 2 根已收盘 K 线           |
   //|      （shift=1 或 shift=2）任一根 J 达标即确认——做多 J ≤ 超卖阈值、 |
   //|      做空 J ≥ 超买阈值（数据不足静默）。单根口径与 Tick 级沿位检查   |
   //|      存在时间口径错配（沿位本 Tick 到达、J 值却取自上一根收盘），    |
   //|      放宽为 2 根窗口可覆盖"上一根 J 达标、本根刚回落"的常见形态     |
   //|   注：price 为入场侧报价（做多传 Ask、做空传 Bid），opposite 为对侧  |
   //|      报价（做多传 Bid、做空传 Ask），均由主 EA 传入（见主 EA 注释） |
   //+------------------------------------------------------------------+
   ENUM_SIGNAL_DIR   EvaluateEntry(const double price, const double opposite)
     {
      //--- L1：无有效箱体
      if(!m_box.valid)
         return SIGNAL_NONE;

      //--- L2：位置过滤（§3.1-2 / §3.2-2 / §3.3，双边带 + 外缘对侧报价）
      //    内缘以入场侧报价（成交价口径）判定到达沿位；外缘以对侧报价
      //    判定未深破沿位——与突破联动止损同口径（多单以 Bid 判破位），
      //    开仓瞬间对侧报价距突破联动线至少还有 InpBreakoutPoints−band
      //    余量，消除点差导致的"开仓即秒平"窗口；价格远破沿位外侧亦
      //    不算到达（防接飞刀）
      bool nearLow  = (price <= m_box.entryLow &&
                       opposite >= m_box.lower - m_box.entryBand);
      bool nearHigh = (price >= m_box.entryHigh &&
                       opposite <= m_box.upper + m_box.entryBand);
      if(!nearLow && !nearHigh)
        {
         if(InpVerboseSignalLog && TimeCurrent() - m_lastDiagTime >= 60)
           {
            m_lastDiagTime = TimeCurrent();
            m_logger.Info(StringFormat("入场评估: 入场价 %.2f/对侧价 %.2f 不在双边入场区(下沿%.2f±%.2f / 上沿%.2f±%.2f), 拒绝",
                                       price, opposite, m_box.lower, m_box.entryBand,
                                       m_box.upper, m_box.entryBand));
           }
         return SIGNAL_NONE;
        }

      //--- L3：KDJ 超买超卖确认（§3.1-3 / §3.2-3，2 根已收盘 K 线窗口）
      double j1 = 0.0, j2 = 0.0;
      bool   ok1 = m_ind.KdjJ(j1, 1);          // 最近 1 根已收盘 K 线（shift=1）
      bool   ok2 = m_ind.KdjJ(j2, 2);          // 最近 2 根已收盘 K 线（shift=2）
      if(!ok1 && !ok2)
         return SIGNAL_NONE;                    // 数据不足静默放弃本轮
      bool oversoldOK   = (ok1 && j1 <= InpKDJOversold)   || (ok2 && j2 <= InpKDJOversold);
      bool overboughtOK = (ok1 && j1 >= InpKDJOverbought) || (ok2 && j2 >= InpKDJOverbought);
      if(nearLow && oversoldOK)
         return SIGNAL_BUY;
      if(nearHigh && overboughtOK)
         return SIGNAL_SELL;
      if(InpVerboseSignalLog && TimeCurrent() - m_lastDiagTime >= 60)
        {
         m_lastDiagTime = TimeCurrent();
         string jText;
         if(ok1 && ok2)
            jText = StringFormat("J1=%.1f/J2=%.1f", j1, j2);
         else if(ok1)
            jText = StringFormat("J1=%.1f", j1);
         else
            jText = StringFormat("J2=%.1f", j2);
         m_logger.Info(StringFormat("入场评估: 已到沿位但 %s 未达阈值(超卖≤%d/超买≥%d), 放弃",
                                    jText, InpKDJOversold, InpKDJOverbought));
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
