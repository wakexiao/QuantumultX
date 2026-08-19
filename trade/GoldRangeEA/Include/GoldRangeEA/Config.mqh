//+------------------------------------------------------------------+
//|                                                       Config.mqh |
//|  模块职责：EA 全部 input 参数集中定义 + 公共枚举/常量/点值换算       |
//|  对应需求文档 v1.md：第七节「可调整参数列表」（23 项参数一一对应，   |
//|               KDJ 9,3,3 拆为 3 个 input、MagicNumber=InpMagic）+    |
//|               周期 InpSignalTF + 调试 InpVerboseSignalLog +          |
//|               安全网 InpMaxSpreadPoints（v1 规格外保护）+            |
//|               版本宏/心跳/重试等执行常量                             |
//+------------------------------------------------------------------+
#ifndef __GREA_CONFIG_MQH__
#define __GREA_CONFIG_MQH__

//--- EA 版本号统一定义（日志头等处引用；#property version 不支持宏展开，
//    主 EA 中的 #property 需随本宏同步手工更新）
#define GREA_VERSION  "1.05"

//--- 信号方向枚举（BoxEngine 输出）
enum ENUM_SIGNAL_DIR
  {
   SIGNAL_NONE = 0,     // 无信号
   SIGNAL_BUY  = 1,     // 做多信号
   SIGNAL_SELL = -1     // 做空信号
  };

//--- 止盈模式枚举（v1 §5.1：A=箱体高度比例，B=箱体对侧）
enum ENUM_TP_MODE
  {
   TP_MODE_RATIO = 0,   // 模式A：止盈 = 箱体高度 × 止盈比例（默认）
   TP_MODE_EDGE  = 1    // 模式B：止盈 = 箱体对侧沿价
  };

//=== 基础标识（v1 §七）==============================================
input long              InpMagic            = 88888;      // EA 魔术号（持仓过滤唯一标识）

//=== 周期设置（v1 §一：M15 主周期，可参数调整）=======================
input ENUM_TIMEFRAMES   InpSignalTF         = PERIOD_M15; // 箱体/信号周期（新K线刷新箱体）

//=== 箱体识别（v1 §2.1 / §2.2）======================================
// 默认刻度按 2026-08-18 实盘实测重标定（README 决策记录 D5）：v1 §七 原默认
// （60 根/15~80 点/容差 3 点）在 1 点=$0.01 口径下与 XAUUSD 实际波动差 1~2 个
// 数量级（实测 60 根 M15 高低区间约 6000 点），箱体永不形成、EA 永不交易
input int               InpBoxBars          = 24;         // 箱体统计K线数量（§2.1 最近 N 根；24 根=6 小时窗口）
input int               InpBoxMinPoints     = 400;        // 箱体最小高度/点（§2.2-1，太小无利润空间）
input int               InpBoxMaxPoints     = 3000;       // 箱体最大高度/点（§2.2-2，太大已是趋势；D7 上调适配实测波动体制）
input int               InpTouchTolerance   = 30;         // 触碰容差/点（§2.2-3 到达上下沿±范围算触碰）
input int               InpMinTouches       = 2;          // 上下沿最小触碰次数（§2.2-3 各至少 N 次）

//=== 入场条件（v1 §3.1 / §3.2 / §3.3）===============================
input int               InpEntryTolerance   = 30;         // 入场容差/点（§3.1/3.2 到达上下沿±范围可入场）
input int               InpKDJ_K            = 9;          // KDJ K 周期（§七：9,3,3）
input int               InpKDJ_D            = 3;          // KDJ D 周期（§七：9,3,3）
input int               InpKDJ_Slowing      = 3;          // KDJ 慢化周期（§七：9,3,3）
input int               InpKDJOverbought    = 80;         // KDJ 超买阈值（§3.2：J≥此值可做空）
input int               InpKDJOversold      = 20;         // KDJ 超卖阈值（§3.1：J≤此值可做多）

//=== 趋势过滤（v1 §4.1）=============================================
input int               InpADX_Period       = 14;         // ADX 周期（震荡/趋势判定）
input int               InpADX_Threshold    = 25;         // ADX 趋势阈值（>此值禁止开新仓，§4.1）

//=== 手数与出场（v1 §5.1/5.2/5.3/5.4、§6.4）=========================
input double            InpFixedLots        = 0.1;        // 固定手数（§6.4，禁动态调整；0.1手=10盎司，1美元波动≈$10）
input ENUM_TP_MODE      InpTPMode           = TP_MODE_RATIO; // 止盈模式（§5.1：A=高度比例/B=箱体对侧）
input double            InpTPRatio          = 0.5;        // 止盈比例（§5.1 模式A：止盈=箱体高度×此值）
input double            InpSLRatio          = 0.4;        // 止损比例（§5.2：止损=箱体高度×此值）
input double            InpMinRR            = 1.2;        // 最小盈亏比（§5.3：低于此值放弃开仓）
input int               InpBreakoutPoints   = 50;         // 突破确认点数（§4.2：突破箱体 N 点确认并止损）
input int               InpMaxHoldHours     = 4;          // 最大持仓时间/小时（§5.4：超时强制平仓）

//=== 交易节奏与全局风控（v1 §3.1/3.2、§6.1、§6.2）====================
input int               InpMinTradeIntervalMin = 5;       // 两笔订单最小间隔/分钟（§3.1/3.2 防频繁交易）
input double            InpMaxDailyLossUSD  = 200.0;      // 最大日亏损/美元（§6.1：当日净亏达此值停止开仓；与0.1手风险刻度匹配，D6/D7）
input int               InpMaxConsecSL      = 3;          // 连续止损暂停次数（§6.2：连亏 N 笔后暂停）
input int               InpPauseMinutes     = 30;         // 暂停时长/分钟（§6.2：暂停期满自动恢复）

//=== 安全网（v1 规格外保护，README「安全网参数」节说明）==============
input int               InpMaxSpreadPoints  = 50;         // 最大允许点差/点（0=关闭过滤；规格外安全网）

//=== 日志与运维 =====================================================
input int               InpLogKeepDays      = 30;         // 日志保留天数（超期旧日志自动清理）
input bool              InpVerboseSignalLog = true;       // 信号评估详细日志：逐级未通过原因+指标数值（D7 起默认开启）

//=== 点值语义（v1 §十-1）============================================
//    1 点 = 0.01 美元（XAUUSD 报价小数点后第二位变动 1）。
//    固定 0.01 换算，不依赖 SYMBOL_POINT —— 在 3 位小数报价经纪商上
//    全部「N 点」参数语义保持不变（README 决策记录 D4）
#define GREA_POINT_VALUE  0.01

//--- 点数 → 价格距离换算（全 EA 唯一口径，勿散落硬编码）
double PtsToPrice(const int points)
  {
   return points * GREA_POINT_VALUE;
  }

//=== 执行常量（非优化项故用宏而非 input）============================
#define GREA_CLOSE_MAX_ATTEMPTS      3              // 平仓失败单次调用内最大立即重试次数
#define GREA_CLOSE_RETRY_SLEEP_MS    300            // 平仓重试间退避/毫秒（测试器中 Sleep 被忽略）
#define GREA_OPEN_MAX_ATTEMPTS       3              // 开仓可重试错误累计最大尝试次数
#define GREA_RETRY_MIN_INTERVAL_SEC  1              // 开仓重试最小间隔/秒（防轰炸服务器）
#define GREA_OPEN_RETRY_TIMEOUT_SEC  30             // 开仓重试超时窗口/秒，超时放弃回 IDLE
#define GREA_RECONCILE_LOOKBACK_SEC  (7 * 24 * 3600) // 离线补账缺省回查窗口/秒（覆盖周末跳空）
#define GREA_SYNC_LOOKBACK_SEC       (24 * 3600)    // 状态对账兜底盈亏回查窗口/秒
#define GREA_HEARTBEAT_INTERVAL_SEC  (5 * 60)       // 心跳全局变量刷新间隔/秒（供外部看门狗监控）
#define GREA_GV_NAME_MAX             63             // MT5 全局变量名长度上限（超长将被终端截断）
#define GREA_SLIPPAGE_POINTS         30             // 下单最大滑点/点（执行细节，非策略参数）
#define GREA_MAX_MARGIN_USE_PCT      50.0           // 开仓保证金占用上限/%可用保证金（安全网）

//--- 全局变量（状态持久化）命名：
//    各模块 Init(magic, symbol) 时生成实例级 m_gvPrefix =
//    "GREA_"+magic+"_"+symbol+"_"，避免多图表同 magic 挂载时
//    冷却/风控状态跨品种污染（沿用模板修复一的命名空间方案）

#endif // __GREA_CONFIG_MQH__
