//+------------------------------------------------------------------+
//|                                                       Config.mqh |
//|  模块职责：EA 全部 input 参数集中定义 + 公共枚举/常量               |
//|  对应方案文档：第 4.5 节「可调参数总表」（28 项参数一一对应）+     |
//|               日志保留天数 InpLogKeepDays（修复四新增）+            |
//|               出场增强开关与差异化冷却（第二批 G1/G2/G5 新增）+      |
//|               版本宏/心跳/保证金阈值等（第三批 F1/F2/F5 新增）       |
//+------------------------------------------------------------------+
#ifndef __GTEA_CONFIG_MQH__
#define __GTEA_CONFIG_MQH__

//--- F1：EA 版本号统一定义（日志头等处引用；#property version 不支持
//    宏展开，主 EA 中的 #property 需随本宏同步手工更新）
#define GTEA_VERSION  "0.30"

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
input double            InpADX_Threshold    = 20.0;       // ADX 趋势阈值（优化 18~30 步长2；v0.30 由22降至20提升信号频次）
input bool              InpADX_Rising       = false;      // 要求 ADX 递增（可选增强开关）

//=== 动能确认层：MACD（方案 4.2）====================================
input int               InpMACD_Fast        = 12;         // MACD 快线（标准值，不优化）
input int               InpMACD_Slow        = 26;         // MACD 慢线（标准值，不优化）
input int               InpMACD_Signal      = 9;          // MACD 信号线（标准值，不优化）
input int               InpMACD_Window      = 10;         // 交叉回溯窗口/根（优化 3~15；v0.30 由3放宽至10提升动能层通过率）

//=== 突破触发层：唐奇安通道（方案 4.2）==============================
input int               InpDonchian_Period  = 12;         // 唐奇安周期（优化 8~30 步长2；v0.30 由20缩短至12缩小突破回看窗口）

//=== 出场规则（方案 4.4）============================================
input int               InpATR_Period       = 14;         // ATR 周期（不优化）
input double            InpSL_ATR_Mult      = 2.0;        // 止损 ATR 倍数（优化 1.5~3.0 步长0.25）
input int               InpSwingBars        = 10;         // 结构点回溯根数（优化 5~20 步长5）
input double            InpRR               = 1.8;        // 固定盈亏比（优化 1.2~2.5 步长0.2）
input bool              InpUseBreakEven     = true;       // 启用保本推损（G1，方案 4.4 默认启用）
input double            InpBE_Trigger       = 1.0;        // 保本触发/倍止损距离（优化 0.6~1.5）
input double            InpBE_Offset        = 0.3;        // 保本偏移/美元（优化 0~1.0）
input bool              InpUseTrailing      = true;       // 启用ATR+结构点跟踪止损（G2/G3，方案 4.4 默认启用）
input double            InpTrail_ATR_Mult   = 2.5;        // 跟踪止损 ATR 倍数（优化 1.5~3.5 步长0.5）
input bool              InpTrailReplacesTP  = false;      // 跟踪启动后取消固定TP（风格对比开关）

//=== 一单一结机制（方案 4.3）========================================
//    G5：原单一 InpCooldownBars 拆分为亏损/盈利差异化冷却（方案 4.3
//    「亏损平仓与盈利平仓可配置不同冷却长度」，默认相同）
input int               InpCooldownBarsLoss   = 1;        // 亏损平仓冷却 K 线数/H1（G5；v0.30 由3降至1加快下次入场机会）
input int               InpCooldownBarsProfit = 1;        // 盈利/保本平仓冷却 K 线数/H1（G5；v0.30 由3降至1）

//=== 资金管理与风控（方案 5 章，红线项不参与优化）====================
input double            InpRiskPercent      = 1.0;        // 单笔风险 %（实盘固定 ≤1）
input double            InpMaxLots          = 1.0;        // 最大手数上限（按账户规模定）
input double            InpMaxMarginUsePct  = 50.0;       // 开仓保证金占用上限/%可用保证金（F2，原硬编码50%）
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
input bool              InpVerboseSignalLog = true;       // 信号评估详细日志：逐层未通过原因+指标数值（D2/F4；v0.30 调试期默认开启便于观察各过滤层拒绝原因，确认正常后可改 false）

//=== 执行常量（修复C2/A2/E2 新增，非优化项故用宏而非 input）=========
#define GTEA_CLOSE_MAX_ATTEMPTS      3              // 平仓失败单次调用内最大立即重试次数（修复C2）
#define GTEA_CLOSE_RETRY_SLEEP_MS    300            // 平仓重试间退避/毫秒（评审五：Sleep 在测试器中被忽略，实盘避免同 Tick 内连发轰炸）
#define GTEA_SWING_SL_BUFFER_ATR     0.25           // 初始止损结构点缓冲/ATR 倍数（G3，方案 4.4「结构点外加缓冲」）
#define GTEA_OPEN_MAX_ATTEMPTS       3              // 开仓可重试错误累计最大尝试次数（F2，原硬编码3）
#define GTEA_RETRY_MIN_INTERVAL_SEC  1              // 开仓重试最小间隔/秒（F2，原硬编码1秒，防轰炸服务器）
#define GTEA_OPEN_RETRY_TIMEOUT_SEC  30             // 开仓重试超时窗口/秒，超时放弃回 IDLE（修复A2）
#define GTEA_RECONCILE_LOOKBACK_SEC  (7 * 24 * 3600) // 离线补账缺省回查窗口/秒（修复E2，覆盖周末跳空）
#define GTEA_SYNC_LOOKBACK_SEC       (24 * 3600)    // 状态对账兜底盈亏回查窗口/秒（A3，持仓消失刚发生，24h 足够）
#define GTEA_HEARTBEAT_INTERVAL_SEC  (5 * 60)       // 心跳全局变量刷新间隔/秒（F5，供外部看门狗监控）
#define GTEA_GV_NAME_MAX             63             // MT5 全局变量名长度上限（E5，超长将被终端截断）

//--- 全局变量（状态持久化）命名（方案 6.6）：
//    修复一：前缀不再使用仅含 magic 的宏，改由各模块 Init(magic, symbol)
//    时生成实例级 m_gvPrefix = "GTEA_"+magic+"_"+symbol+"_"，
//    避免多图表同 magic 挂载时冷却/风控状态跨品种污染

//=== 点值语义（v0.30 新增：统一美元口径换算，参照 GoldRangeEA）==========
//    1 点 = 0.01 美元（XAUUSD 报价小数点后第二位变动 1）。
//    固定 0.01 换算，不依赖 SYMBOL_POINT —— 在 3 位小数报价经纪商上
//    全部「N 点」参数语义保持不变（解决 SYMBOL_SPREAD 原生点数在 3 位小数
//    经纪商上返回 300-500 而非期望的 30-50 的口径不一致问题）
#define GTEA_POINT_VALUE  0.01

//--- 点数 → 价格距离换算（全 EA 唯一口径，点差过滤等模块统一调用）
double PtsToPrice(const int points)
  {
   return points * GTEA_POINT_VALUE;
  }

#endif // __GTEA_CONFIG_MQH__
