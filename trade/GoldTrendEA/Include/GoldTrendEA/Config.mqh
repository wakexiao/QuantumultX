//+------------------------------------------------------------------+
//|                                                       Config.mqh |
//|  模块职责：EA 全部 input 参数集中定义 + 公共枚举/常量               |
//|  对应方案文档：第 4.5 节「可调参数总表」（28 项参数一一对应）+     |
//|               日志保留天数 InpLogKeepDays（修复四新增）              |
//+------------------------------------------------------------------+
#ifndef __GTEA_CONFIG_MQH__
#define __GTEA_CONFIG_MQH__

//--- 信号方向枚举（信号引擎输出）
enum ENUM_SIGNAL_DIR
  {
   SIGNAL_NONE = 0,     // 无信号
   SIGNAL_BUY  = 1,     // 做多信号
   SIGNAL_SELL = -1     // 做空信号
  };

//=== 基础标识 =======================================================
input long              InpMagic            = 20260813;   // EA 魔术号（持仓过滤唯一标识）

//=== 周期设置（方案 4.1：H4 定方向 + H1 信号）=======================
input ENUM_TIMEFRAMES   InpTrendTF          = PERIOD_H4;  // 趋势周期（固定 H4，不优化）
input ENUM_TIMEFRAMES   InpSignalTF         = PERIOD_H1;  // 信号周期（固定 H1，不优化）

//=== 趋势方向层：EMA 排列 + ADX 强度（方案 4.1）=====================
input int               InpEMA_Fast         = 20;         // 快线 EMA 周期（优化 10~30 步长5）
input int               InpEMA_Mid          = 60;         // 中线 EMA 周期（优化 40~80 步长10）
input int               InpEMA_Slow         = 200;        // 慢线 EMA 周期（优化 150~250 步长25）
input int               InpADX_Period       = 14;         // ADX 周期（不优化）
input double            InpADX_Threshold    = 22.0;       // ADX 趋势阈值（优化 18~30 步长2）
input bool              InpADX_Rising       = false;      // 要求 ADX 递增（可选增强开关）

//=== 动能确认层：MACD（方案 4.2）====================================
input int               InpMACD_Fast        = 12;         // MACD 快线（标准值，不优化）
input int               InpMACD_Slow        = 26;         // MACD 慢线（标准值，不优化）
input int               InpMACD_Signal      = 9;          // MACD 信号线（标准值，不优化）
input int               InpMACD_Window      = 3;          // 交叉回溯窗口/根（优化 1~5）

//=== 突破触发层：唐奇安通道（方案 4.2）==============================
input int               InpDonchian_Period  = 20;         // 唐奇安周期（优化 10~40 步长5）

//=== 出场规则（方案 4.4）============================================
input int               InpATR_Period       = 14;         // ATR 周期（不优化）
input double            InpSL_ATR_Mult      = 2.0;        // 止损 ATR 倍数（优化 1.5~3.0 步长0.25）
input int               InpSwingBars        = 10;         // 结构点回溯根数（优化 5~20 步长5）
input double            InpRR               = 1.8;        // 固定盈亏比（优化 1.2~2.5 步长0.2）
input double            InpBE_Trigger       = 1.0;        // 保本触发/倍止损距离（优化 0.6~1.5）
input double            InpBE_Offset        = 0.3;        // 保本偏移/美元（优化 0~1.0）
input double            InpTrail_ATR_Mult   = 2.5;        // 跟踪止损 ATR 倍数（优化 1.5~3.5 步长0.5）
input bool              InpTrailReplacesTP  = false;      // 跟踪启动后取消固定TP（风格对比开关）

//=== 一单一结机制（方案 4.3）========================================
input int               InpCooldownBars     = 3;          // 平仓后冷却 K 线数/H1（优化 0~10）

//=== 资金管理与风控（方案 5 章，红线项不参与优化）====================
input double            InpRiskPercent      = 1.0;        // 单笔风险 %（实盘固定 ≤1）
input double            InpMaxLots          = 1.0;        // 最大手数上限（按账户规模定）
input double            InpDailyLossPct     = 3.0;        // 日亏损熔断 %（风控红线，不优化）
input double            InpWeeklyLossPct    = 6.0;        // 周亏损熔断 %（风控红线，不优化）
input int               InpMaxConsecLoss    = 4;          // 最大连亏次数（优化 3~6）
input int               InpMaxSpreadPoints  = 45;         // 最大允许点差/点（按券商实测定）
input bool              InpFridayClose      = true;       // 周五收盘前离场开关
input int               InpFridayCloseHour  = 21;         // 周五离场时刻/服务器小时（优化 20~23）
input bool              InpNewsFilter       = false;      // 重大新闻时段过滤开关（可选，P2）

//=== 执行参数 =======================================================
input int               InpSlippagePoints   = 30;         // 最大滑点/点（不优化）

//=== 日志与运维（修复四：日志容量与保留策略）=======================
input int               InpLogKeepDays      = 30;         // 日志保留天数（超期旧日志自动清理）

//--- 全局变量（状态持久化）命名（方案 6.6）：
//    修复一：前缀不再使用仅含 magic 的宏，改由各模块 Init(magic, symbol)
//    时生成实例级 m_gvPrefix = "GTEA_"+magic+"_"+symbol+"_"，
//    避免多图表同 magic 挂载时冷却/风控状态跨品种污染

#endif // __GTEA_CONFIG_MQH__
