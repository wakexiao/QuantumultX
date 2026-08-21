//+------------------------------------------------------------------+
//|                                               GoldTrend888EA.mq5 |
//|            888趋势一单一结：H1趋势 + H1 ATR低位蓄势 + M5突破挂单 |
//+------------------------------------------------------------------+
#property copyright "GoldTrend888EA"
#property version   "1.00"
#property description "888趋势一单一结 v1.00"
#property description "H1 EMA50/200定方向，H1 ATR处于低位分位时在M5突破位挂Stop单"
#property description "每单固定手数，入场即带SL(3xATR)/TP(6xATR)，独立结算不加仓"
#property strict

#include <Trade\Trade.mqh>

//--- 版本与常量
#define T888_VERSION   "1.00"
#define T888_LOG_DIR   "GoldTrend888EA"          // MQL5/Files/GoldTrend888EA/yyyymmdd.log
#define T888_COMMENT   "888Trend"

//+------------------------------------------------------------------+
//| input 参数（与实盘参数面板一一对应）                             |
//+------------------------------------------------------------------+
input double InpFixedLots        = 0.05;      // 固定手数
input int    InpH1FastEMA        = 50;        // H1快速均线周期
input int    InpH1SlowEMA        = 200;       // H1慢速均线周期
input int    InpH1AtrPeriod      = 14;        // H1 ATR周期
input int    InpH1AtrLookback    = 40;        // H1 ATR低位区间回看根数
input double InpH1AtrPctile      = 20.0;      // H1 ATR低位阈值(百分位)
input int    InpM5AtrPeriod      = 14;        // M5 ATR周期
input int    InpM5BreakLookback  = 20;        // M5突破高低点回看根数
input double InpEntryOffsetATR   = 1.2;       // 入场偏移ATR倍数
input double InpSL_ATR_Mult      = 3.0;       // 止损ATR倍数
input double InpTP_ATR_Mult      = 6.0;       // 止盈ATR倍数
input long   InpMagic            = 20260815;  // EA魔术号
input int    InpSlippagePoints   = 50;        // 滑点(点)
input bool   InpDeleteOppOnFlip  = true;      // H1趋势反转时删除反向挂单

//+------------------------------------------------------------------+
//| 全局对象与状态                                                   |
//+------------------------------------------------------------------+
CTrade   g_trade;
int      g_hEmaFast = INVALID_HANDLE;   // H1 快速EMA
int      g_hEmaSlow = INVALID_HANDLE;   // H1 慢速EMA
int      g_hAtrH1   = INVALID_HANDLE;   // H1 ATR（低位过滤）
int      g_hAtrM5   = INVALID_HANDLE;   // M5 ATR（入场偏移/SL/TP）
datetime g_lastM5BarTime = 0;           // M5 新K线判定
datetime g_lastEnvWarn   = 0;           // 环境异常WARN节流

enum ENUM_TREND_DIR { TREND_NONE = 0, TREND_UP = 1, TREND_DOWN = -1 };

//+------------------------------------------------------------------+
//| 日志：双路输出（专家标签 + MQL5/Files/GoldTrend888EA/日期.log）  |
//+------------------------------------------------------------------+
void Log(const string level, const string msg)
{
   string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
               + " [" + level + "][" + (string)InpMagic + "] " + msg;
   Print(line);

   string fname = T888_LOG_DIR + "\\" +
                  TimeToString(TimeCurrent(), TIME_DATE) + ".log";
   StringReplace(fname, ".", "");            // 2026.08.20 -> 20260820
   StringReplace(fname, "log", "");          // 去掉被误伤的后缀再补回
   fname = T888_LOG_DIR + "\\" + FormatDateForFile(TimeCurrent()) + ".log";

   int h = FileOpen(fname, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI, '\t', CP_UTF8);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line + "\r\n");
      FileClose(h);
   }
}

//--- 日期转文件名 yyyymmdd
string FormatDateForFile(const datetime t)
{
   MqlDateTime st;
   TimeToStruct(t, st);
   return StringFormat("%04d%02d%02d", st.year, st.mon, st.day);
}

//--- 推送通知（测试器中自动跳过；失败仅记日志，避免占用终端推送配额）
void Notify(const string msg)
{
   Log("NOTIFY", msg);
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
      return;
   ResetLastError();
   if(!SendNotification("[888趋势] " + msg))
      Log("WARN", "推送失败 err=" + (string)GetLastError());
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 参数合法性
   if(InpFixedLots <= 0 || InpH1FastEMA <= 0 || InpH1SlowEMA <= InpH1FastEMA ||
      InpH1AtrPeriod <= 0 || InpH1AtrLookback < 10 ||
      InpH1AtrPctile <= 0 || InpH1AtrPctile > 100 ||
      InpM5AtrPeriod <= 0 || InpM5BreakLookback <= 0 ||
      InpEntryOffsetATR < 0 || InpSL_ATR_Mult <= 0 || InpTP_ATR_Mult <= 0)
   {
      Log("ERROR", "参数非法：请检查均线/ATR/倍数等输入");
      return(INIT_PARAMETERS_INCORRECT);
   }

   //--- 指标句柄
   g_hEmaFast = iMA(_Symbol, PERIOD_H1, InpH1FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, PERIOD_H1, InpH1SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtrH1   = iATR(_Symbol, PERIOD_H1, InpH1AtrPeriod);
   g_hAtrM5   = iATR(_Symbol, PERIOD_M5, InpM5AtrPeriod);
   if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE ||
      g_hAtrH1 == INVALID_HANDLE || g_hAtrM5 == INVALID_HANDLE)
   {
      Log("ERROR", "指标句柄创建失败");
      return(INIT_FAILED);
   }

   //--- 交易对象
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   Log("INFO", StringFormat(
       "888趋势一单一结 v%s 启动 %s | 手数=%.2f | H1 EMA=%d/%d | H1 ATR=%d 回看%d根 低位%.1f%% | "
       "M5 ATR=%d 突破回看%d根 | 偏移=%.1fxATR SL=%.1fxATR TP=%.1fxATR | magic=%s 滑点=%d点 反转删单=%s",
       T888_VERSION, _Symbol, InpFixedLots, InpH1FastEMA, InpH1SlowEMA,
       InpH1AtrPeriod, InpH1AtrLookback, InpH1AtrPctile,
       InpM5AtrPeriod, InpM5BreakLookback,
       InpEntryOffsetATR, InpSL_ATR_Mult, InpTP_ATR_Mult,
       (string)InpMagic, InpSlippagePoints, InpDeleteOppOnFlip ? "true" : "false"));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hEmaFast != INVALID_HANDLE) { IndicatorRelease(g_hEmaFast); g_hEmaFast = INVALID_HANDLE; }
   if(g_hEmaSlow != INVALID_HANDLE) { IndicatorRelease(g_hEmaSlow); g_hEmaSlow = INVALID_HANDLE; }
   if(g_hAtrH1   != INVALID_HANDLE) { IndicatorRelease(g_hAtrH1);   g_hAtrH1   = INVALID_HANDLE; }
   if(g_hAtrM5   != INVALID_HANDLE) { IndicatorRelease(g_hAtrM5);   g_hAtrM5   = INVALID_HANDLE; }
   Log("INFO", "EA 停止 reason=" + (string)reason);
}

//+------------------------------------------------------------------+
//| OnTick：仅在 M5 新K线时评估（全部基于已收盘K线）                 |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewM5Bar())
      return;

   //--- 环境校验（WARN 5分钟节流）
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      if(TimeCurrent() - g_lastEnvWarn >= 300)
      {
         g_lastEnvWarn = TimeCurrent();
         Log("WARN", "自动交易未允许（终端Algo Trading或EA权限关闭），本轮跳过");
      }
      return;
   }

   //--- 1. H1 趋势方向（已收盘H1）
   ENUM_TREND_DIR dir = GetH1Trend();

   //--- 2. 反向挂单清理（幂等：每根M5核对一次）
   if(InpDeleteOppOnFlip && dir != TREND_NONE)
      DeleteCounterTrendPendings(dir);

   if(dir == TREND_NONE)
      return;

   //--- 3. 计算顺势突破挂单价位（M5 已收盘K线 + M5 ATR）
   double entry = 0, sl = 0, tp = 0;
   if(!ComputeSetup(dir, entry, sl, tp))
      return;

   //--- 4. 维护挂单：已有同向挂单则跟随突破位修改；无挂单且ATR低位成立则新建
   ENUM_ORDER_TYPE wantType = (dir == TREND_UP) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   ulong  ticket   = 0;
   double oldPrice = 0;
   if(FindMyPending(wantType, ticket, oldPrice))
   {
      ModifyPending(ticket, wantType, oldPrice, entry, sl, tp);
      return;
   }

   if(CountMyPendings() > 0)   // 仅剩反向挂单且删除开关为false：不新建，等待其自然处置
      return;

   //--- ATR 低位过滤只约束「新建」挂单；已挂出的订单继续跟随突破位
   double pctRank = 0;
   if(!H1AtrIsLow(pctRank))
      return;

   PlacePending(dir, wantType, entry, sl, tp, pctRank);
}

//+------------------------------------------------------------------+
//| M5 新K线判定                                                     |
//+------------------------------------------------------------------+
bool IsNewBarM5Time(datetime &curBar)
{
   curBar = iTime(_Symbol, PERIOD_M5, 0);
   return(curBar > 0 && curBar != g_lastM5BarTime);
}

bool IsNewM5Bar()
{
   datetime cur = 0;
   if(!IsNewBarM5Time(cur))
      return false;
   bool first = (g_lastM5BarTime == 0);
   g_lastM5BarTime = cur;
   return(!first);   // 首个Tick仅初始化，不触发评估
}

//+------------------------------------------------------------------+
//| H1 趋势：EMA快线 > 慢线 = 多头；< = 空头（shift=1 已收盘）       |
//+------------------------------------------------------------------+
ENUM_TREND_DIR GetH1Trend()
{
   double fast[1], slow[1];
   if(CopyBuffer(g_hEmaFast, 0, 1, 1, fast) < 1 ||
      CopyBuffer(g_hEmaSlow, 0, 1, 1, slow) < 1)
   {
      Log("WARN", "H1 EMA 数据不足，本轮跳过");
      return TREND_NONE;
   }
   if(fast[0] > slow[0]) return TREND_UP;
   if(fast[0] < slow[0]) return TREND_DOWN;
   return TREND_NONE;
}

//+------------------------------------------------------------------+
//| H1 ATR 低位过滤：当前已收盘H1 ATR 在回看窗口内的分位 ≤ 阈值      |
//+------------------------------------------------------------------+
bool H1AtrIsLow(double &pctRank)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_hAtrH1, 0, 1, InpH1AtrLookback, buf) < InpH1AtrLookback)
   {
      Log("WARN", "H1 ATR 数据不足，本轮跳过");
      return false;
   }
   double cur = buf[0];
   int less = 0;
   for(int i = 1; i < InpH1AtrLookback; i++)
      if(buf[i] < cur)
         less++;
   pctRank = 100.0 * less / (InpH1AtrLookback - 1);
   return(pctRank <= InpH1AtrPctile);
}

//+------------------------------------------------------------------+
//| 计算突破挂单三价位：入场/止损/止盈                               |
//| 多：近N根已收盘M5最高价 + 偏移xATR；SL=入场-3xATR TP=入场+6xATR  |
//+------------------------------------------------------------------+
bool ComputeSetup(const ENUM_TREND_DIR dir, double &entry, double &sl, double &tp)
{
   double atr[1];
   if(CopyBuffer(g_hAtrM5, 0, 1, 1, atr) < 1 || atr[0] <= 0)
   {
      Log("WARN", "M5 ATR 数据不足，本轮跳过");
      return false;
   }
   double a = atr[0];

   if(dir == TREND_UP)
   {
      int idx = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, InpM5BreakLookback, 1);
      if(idx < 0) return false;
      double hh = iHigh(_Symbol, PERIOD_M5, idx);
      entry = hh + InpEntryOffsetATR * a;
      sl    = entry - InpSL_ATR_Mult * a;
      tp    = entry + InpTP_ATR_Mult * a;
   }
   else
   {
      int idx = iLowest(_Symbol, PERIOD_M5, MODE_LOW, InpM5BreakLookback, 1);
      if(idx < 0) return false;
      double ll = iLow(_Symbol, PERIOD_M5, idx);
      entry = ll - InpEntryOffsetATR * a;
      sl    = entry + InpSL_ATR_Mult * a;
      tp    = entry - InpTP_ATR_Mult * a;
   }
   entry = NormalizeDouble(entry, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   tp    = NormalizeDouble(tp, _Digits);
   return true;
}

//+------------------------------------------------------------------+
//| 挂单价位合法性：Stop单必须离市价至少 stops level                 |
//+------------------------------------------------------------------+
bool EntryPriceValid(const ENUM_ORDER_TYPE type, const double entry)
{
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(type == ORDER_TYPE_BUY_STOP)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return(ask > 0 && entry >= ask + minDist);
   }
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return(bid > 0 && entry <= bid - minDist);
}

//+------------------------------------------------------------------+
//| 手数规范化（固定手数按品种 min/max/step 校正）                   |
//+------------------------------------------------------------------+
double NormalizedLots()
{
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots  = InpFixedLots;
   if(vstep > 0)
      lots = MathFloor(lots / vstep + 0.5) * vstep;
   lots = MathMax(vmin, MathMin(vmax, lots));
   return NormalizeDouble(lots, 8);
}

//+------------------------------------------------------------------+
//| 本EA挂单扫描                                                     |
//+------------------------------------------------------------------+
bool IsMyPendingIndex(const int i, ulong &ticket, ENUM_ORDER_TYPE &type, double &price)
{
   ticket = OrderGetTicket(i);
   if(ticket == 0) return false;
   if(OrderGetInteger(ORDER_MAGIC) != InpMagic) return false;
   if(OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP) return false;
   price = OrderGetDouble(ORDER_PRICE_OPEN);
   return true;
}

int CountMyPendings()
{
   int cnt = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk; ENUM_ORDER_TYPE ty; double p;
      if(IsMyPendingIndex(i, tk, ty, p))
         cnt++;
   }
   return cnt;
}

bool FindMyPending(const ENUM_ORDER_TYPE wantType, ulong &ticket, double &price)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk; ENUM_ORDER_TYPE ty; double p;
      if(IsMyPendingIndex(i, tk, ty, p) && ty == wantType)
      {
         ticket = tk;
         price  = p;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 删除与当前H1趋势相反的挂单                                       |
//+------------------------------------------------------------------+
void DeleteCounterTrendPendings(const ENUM_TREND_DIR dir)
{
   ENUM_ORDER_TYPE oppType = (dir == TREND_UP) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk; ENUM_ORDER_TYPE ty; double p;
      if(!IsMyPendingIndex(i, tk, ty, p) || ty != oppType)
         continue;
      if(g_trade.OrderDelete(tk))
         Log("INFO", StringFormat("H1趋势反转→删除反向挂单 #%I64u %s @%s",
             tk, OrderTypeText(ty), DoubleToString(p, _Digits)));
      else
         Log("ERROR", StringFormat("删除反向挂单失败 #%I64u retcode=%u",
             tk, g_trade.ResultRetcode()));
   }
}

//+------------------------------------------------------------------+
//| 新建顺势Stop挂单                                                 |
//+------------------------------------------------------------------+
void PlacePending(const ENUM_TREND_DIR dir, const ENUM_ORDER_TYPE type,
                  const double entry, const double sl, const double tp,
                  const double pctRank)
{
   if(!EntryPriceValid(type, entry))
      return;   // 突破位已被穿越或距市价过近，等下一根M5重算

   double lots = NormalizedLots();
   bool ok;
   if(type == ORDER_TYPE_BUY_STOP)
      ok = g_trade.BuyStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, T888_COMMENT);
   else
      ok = g_trade.SellStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, T888_COMMENT);

   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      Log("INFO", StringFormat(
          "新建挂单 %s %.2f手 @%s SL=%s TP=%s | H1 ATR分位=%.1f%%（阈值%.1f%%）",
          OrderTypeText(type), lots,
          DoubleToString(entry, _Digits), DoubleToString(sl, _Digits),
          DoubleToString(tp, _Digits), pctRank, InpH1AtrPctile));
   else
      Log("ERROR", StringFormat("挂单失败 %s @%s retcode=%u",
          OrderTypeText(type), DoubleToString(entry, _Digits), rc));
}

//+------------------------------------------------------------------+
//| 修改已有挂单：跟随最新突破位（价位变化不足1点则跳过）            |
//+------------------------------------------------------------------+
void ModifyPending(const ulong ticket, const ENUM_ORDER_TYPE type,
                   const double oldPrice, const double entry,
                   const double sl, const double tp)
{
   if(MathAbs(entry - oldPrice) < _Point)
      return;
   if(!EntryPriceValid(type, entry))
      return;   // 新价位不合法（如市价已越过突破位），保留原挂单
   if(g_trade.OrderModify(ticket, entry, sl, tp, ORDER_TIME_GTC, 0))
      Log("INFO", StringFormat("挂单跟随 #%I64u %s %s→%s SL=%s TP=%s",
          ticket, OrderTypeText(type),
          DoubleToString(oldPrice, _Digits), DoubleToString(entry, _Digits),
          DoubleToString(sl, _Digits), DoubleToString(tp, _Digits)));
   else
      Log("WARN", StringFormat("挂单修改失败 #%I64u retcode=%u（下一根M5重试）",
          ticket, g_trade.ResultRetcode()));
}

//+------------------------------------------------------------------+
//| 成交事件：挂单触发开仓 / SLTP平仓 → 日志+推送                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
   {
      HistorySelect(0, TimeCurrent() + 3600);   // 历史窗口未加载时兜底
      if(!HistoryDealSelect(trans.deal))
         return;
   }
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic ||
      HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   long   entryFlag = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   double price     = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double volume    = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   long   dealType  = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   string dirText   = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";

   if(entryFlag == DEAL_ENTRY_IN)
   {
      Notify(StringFormat("挂单触发开仓 %s %.2f手 @%s",
             dirText, volume, DoubleToString(price, _Digits)));
   }
   else if(entryFlag == DEAL_ENTRY_OUT)
   {
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                    + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      long   reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      string why    = (reason == DEAL_REASON_SL) ? "止损" :
                      (reason == DEAL_REASON_TP) ? "止盈" : "平仓";
      Notify(StringFormat("%s %s %.2f手 @%s 盈亏=%.2f",
             why, dirText, volume, DoubleToString(price, _Digits), profit));
   }
}

//+------------------------------------------------------------------+
//| 挂单类型文本                                                     |
//+------------------------------------------------------------------+
string OrderTypeText(const ENUM_ORDER_TYPE type)
{
   return(type == ORDER_TYPE_BUY_STOP) ? "BuyStop" : "SellStop";
}
//+------------------------------------------------------------------+
