# GoldTrendEA — 黄金外汇「顺势一单一结」EA 框架

## v0.31 Short-Term Defaults

This version changes the default profile from swing-style H4/H1 filtering to a faster H1/M15 setup aimed at roughly 2-3 XAUUSD trades per active trend day. The main changes are: H1 trend filter, M15 signal bars, EMA 10/30/100, ADX 16, MACD lookback 16, Donchian 6, ATR stop 1.2, RR 1.3, earlier break-even, and tighter trailing.

The MACD layer now also accepts strengthening same-direction histogram momentum, so the EA can still enter after missing the exact MACD cross bar. Risk controls, one-position-at-a-time behavior, spread filtering, daily/weekly loss halts, and margin checks are unchanged.

> 对应方案文档：[黄金外汇EA顺势一单一结开发方案.md](../黄金外汇EA顺势一单一结开发方案.md)
> 当前版本：v0.31（版本号统一由 `Config.mqh` 的 `GTEA_VERSION` 定义；短线默认参数+开单频率优化阶段产出，**非完整可交易版本**）

## 目录结构

```
GoldTrendEA/
├── Experts/
│   └── GoldTrendEA.mq5            # 主 EA：OnInit/OnTick/OnDeinit/OnTradeTransaction
├── Include/
│   └── GoldTrendEA/
│       ├── Config.mqh             # 全部 input 参数 + 公共枚举/常量（方案 4.5 节参数表 + 版本宏 GTEA_VERSION/心跳/保证金阈值等）
│       ├── Logger.mqh             # 日志与通知：分级日志/WARN节流/手机推送（方案 8.3）
│       ├── MarketData.mqh         # 行情数据层：新K线判定/OHLC/点差/环境校验（方案 6.1/6.5）
│       ├── Indicators.mqh         # 指标计算层：句柄管理/CopyBuffer/唐奇安（方案 6.2）
│       ├── SignalEngine.mqh       # 信号引擎：EMA排列+ADX+MACD+唐奇安突破（方案 4.1/4.2）
│       ├── PositionManager.mqh    # 持仓管理器：一单一结状态机/冷却期/持久化（方案 4.3）
│       ├── RiskManager.mqh        # 风控模块：手数计算/熔断矩阵/点差与周五过滤（方案 5 章）
│       └── TradeExecutor.mqh      # 订单执行：CTrade封装/重试/SL·TP/移动止损（方案 6.3）
└── README.md
```

## 各模块职责与依赖关系

| 模块 | 类 | 依赖 | 核心接口 |
| --- | --- | --- | --- |
| Logger | `CLogger` | 无 | `Info/Warn/Error/WarnThrottled/Notify` |
| MarketData | `CMarketData` | Logger | `IsNewBar/Close/SpreadPoints/IsTradingEnvironmentOK` |
| Indicators | `CIndicators` | Logger | `Init(句柄创建)/Release/GetValue/DonchianUpper·Lower/AtrSig` |
| SignalEngine | `CSignalEngine` | MarketData, Indicators | `Evaluate/EvaluateCached(同K线缓存) → BUY/SELL/NONE`、`IsTrendReversed(含反向三重信号)` |
| PositionManager | `CPositionManager` | Logger, RiskManager(可选注入) | `CanOpenNew/CountMyPositions(Tick级缓存)/InvalidateCache/SyncWithReality(兜底盈亏回查)/OnPositionClosed(差异化冷却)/RestoreState/UpdateHeartbeat/单笔持仓级持久化(初始止损距离/保本标记)` |
| RiskManager | `CRiskManager` | Logger | `CalcLots/IsHalted/SpreadOk/IsFridayCloseTime/OnTradeResult/LastDealTicket` |
| TradeExecutor | `CTradeExecutor` | Logger | `Open(重试+一单一结二次校验)/CloseMyPosition/ModifySL`（保本/跟踪策略在主 EA 的 `ManagePosition` 中实现） |

依赖注入均在主 EA 的 `OnInit` 中完成（指针注入），各模块之间不直接互相构造。

## 如何导入 MT5

1. 打开 MT5 → 「文件」→「打开数据文件夹」→ 进入 `MQL5/` 目录；
2. 将本项目 `Experts/GoldTrendEA.mq5` 拷贝到 `MQL5/Experts/`（可放子目录如 `MQL5/Experts/GoldTrendEA/`）；
3. 将本项目 `Include/GoldTrendEA/` 整个目录拷贝到 `MQL5/Include/` 下（即最终为 `MQL5/Include/GoldTrendEA/*.mqh`，**目录名不可改**，与 `#include <GoldTrendEA/...>` 路径对应）；
4. 在 MetaEditor 中打开 `GoldTrendEA.mq5` 按 F7 编译；
5. 编译通过后在 MT5 中将 EA 拖到 XAUUSD H1 图表（任意周期均可运行，H1 与内部 `InpSignalTF` 一致最直观），启用「算法交易」。

> 注意：保本推损/ATR+结构点跟踪止损/反向三重信号离场等核心出场功能已实现（第二批 G1~G5/G7/G10），但尚未经方案 7.1 配置的全量回测与模拟盘验证，**请勿用于实盘**。

> 运维提示（日志参数）：VPS 长期运行时请按磁盘容量设置 `InpLogKeepDays`（建议 30/60/90 天，超期旧日志自动清理）；若回测或实盘出现「单日日志超 50MB」WARN，应精简日志级别或提高 `WarnThrottled` 节流窗口。信号逐层未通过的 Info 日志默认关闭，调试/复盘时开启 `InpVerboseSignalLog` 可附 EMA/ADX/MACD/唐奇安关键数值。

> 运维提示（心跳监控）：EA 每 5 分钟写一次心跳全局变量 `GTEA_<magic>_<symbol>_HEARTBEAT`（值为最近写入时的服务器时间戳），外部看门狗脚本可据此监控 EA 存活（长时间未更新 = EA 已停/终端断线，注意周末无 Tick 时心跳也会暂停）。

## v0.20 → v0.30 开单频率优化（重要）

### 问题根因

v0.20 在 XAUUSD 上几乎无法开单，原因有二：

1. **点差过滤 Bug（致命）**：`SpreadOk()` 直接用 `SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)` 获取的原生点数与固定阈值 45 比较。在 3 位小数报价经纪商上 `SYMBOL_SPREAD` 返回 300-500 原生点数（对应 $3-$5 实际价差），永远超过阈值 45，导致所有开仓被点差过滤 100% 拦死。
2. **四层信号过滤串联导致结构性低频**：H4 三线排列 + ADX>22 + H1 MACD 3根窗口交叉 + 唐奇安 20期突破，全部同时满足概率极低（约 2-5 天一次）。

### 修复与调整

| 修改项 | 旧值 | 新值 | 依据 |
| --- | --- | --- | --- |
| 点差过滤口径 | `SYMBOL_SPREAD`(原生点数) vs 45 | `Ask-Bid`(美元) vs `PtsToPrice(45)=$0.45` | 统一美元口径，3位小数经纪商正常点差$0.30-$0.50可正确放行；参照 GoldRangeEA 已验证实现 |
| `InpADX_Threshold` | 22.0 | 20.0 | ADX 20 仍属有效趋势过滤（教科书典型阈值为20-25），小幅放宽增加约20%趋势方向层通过率 |
| `InpMACD_Window` | 3 | 10 | 原窗口仅3根H1(3小时)内须出现交叉，概率极低；10根(10小时)允许日内交叉信号延续生效，与H4趋势周期节奏匹配 |
| `InpDonchian_Period` | 20 | 12 | 原20期(近1天)突破过滤极严；12期(半天)缩短回看窗口使得中等幅度的趋势行情也能触发突破 |
| `InpCooldownBarsLoss` | 3 | 1 | 原3根H1冷却(3小时)过长；1根(1小时)足以避免同Tick重复信号又不浪费次日行情 |
| `InpCooldownBarsProfit` | 3 | 1 | 同上 |
| `InpVerboseSignalLog` | false | true | 调试期默认开启，各过滤层拒绝原因可见（60s节流不刷屏） |
| 新增 `GTEA_POINT_VALUE` | — | 0.01 | 1点=$0.01 美元口径常量，PtsToPrice()统一换算 |
| 新增 `PtsToPrice()` | — | `points * 0.01` | 点数→价格距离函数（与 GoldRangeEA 一致） |

### H4三线排列/H1一致性判定

这两层仅检查方向（EMA20>60>200 排列 + 收盘价在快线上方/下方 + H1 EMA20>60 一致），无额外间距阈值或幅度约束，属顺势策略的方向根基，保持不动。

### 风控骨架不变

- 一单一结硬约束、每单硬 SL/TP、保证金校验、日/周亏损熔断、连亏暂停、状态持久化 —— 全部逻辑不变
- 单笔/日内风险敞口未变化（`InpRiskPercent`=1%、`InpDailyLossPct`=3%、`InpWeeklyLossPct`=6% 维持原值）
- 冷却时长缩短不影响风控上限（冷却是信号节奏控制而非风控红线）

### 目标频次

修复点差Bug后信号即可正常触发；四层过滤适度放宽后在中等趋势行情日（ADX>20、日内有明确方向）预期可达 **2-3 单/日**。震荡日（ADX<20）仍会被正确过滤不开单，符合"顺势"策略定位。

## v0.10 → v0.20 升级注意事项

从 v0.10 升级到 v0.20 前请逐项确认：

1. **`InpCooldownBars` 已拆分为两个参数**（G5）：亏损平仓用 `InpCooldownBarsLoss`、盈利/保本平仓用 `InpCooldownBarsProfit`（默认均为 3，与旧默认行为一致）。旧版 `.set` 配置文件中的 `InpCooldownBars` 不会自动迁移，需手动改为新参数名并重新保存；
2. **`InpUseBreakEven` / `InpUseTrailing` 默认启用**（属方案 4.4 核心出场功能）：升级后持仓管理行为与 v0.10（TODO 骨架、实际不生效）不同，不需要的用户请手动关闭；实盘前建议先按方案 7.1 配置回测验证出场参数；
3. **全局变量命名空间加入了 symbol**（`GTEA_<magic>_<symbol>_*`）：旧命名空间（仅 magic）的风控/冷却状态不会被继承，升级后日/周亏损、连亏计数与冷却从零开始累积，必要时手动清理旧全局变量（前缀 `GTEA_<magic>_`）；
4. **升级首日熔断基数按当前净值快照**：日/周亏损熔断的基数在首次启动时取当前净值补快照（而非当日 0 点/周初净值），若当日已有盈亏，首日熔断阈值会有偏差，次日跨日复位后自动回归正常；同理最后已入账成交基准（LAST_DEAL）首次启动时按历史成交最大 ticket 初始化，历史旧成交不会被补记入风控统计；
5. **`InpVerboseSignalLog` 默认关闭**：信号逐层未通过原因的详细日志不再默认输出，需要诊断/复盘时手动开启；
6. **`OnTester` 新增复合优化指标**（PF × √交易数 ÷ 最大相对回撤%）：新旧版本的优化结果排序口径不同，**不可直接对比**，历史优化结论需用新指标重跑；
7. **建议在非交易时段（周末）升级**，并先在模拟盘验证至少一个完整交易周期后再考虑实盘（当前版本本身仍**不建议实盘**，见上方注意）。

## 后续开发待办（TODO 清单）

按方案文档里程碑推进，代码内均有 `TODO(阶段, 方案章节)` 标注：

### M2 策略信号实现
- [x] `SignalEngine::IsTrendReversed`：条件二「完整反向三重信号」——复用 `EvaluateCached()` 同K线缓存评估结果，避免重复计算（方案 4.4，G4 已实现）
- [x] `GoldTrendEA.mq5::TryOpenPosition`：结构点止损候选 —— `SwingLow/SwingHigh` 外加缓冲（`GTEA_SWING_SL_BUFFER_ATR` × ATR），与 ATR 距离取 max（方案 4.4，G3 初始止损路径已实现；跟踪路径早已含结构点）

### M3 风控与出场完善
- [x] 保本推损完整实现（主 EA `ApplyBreakEven`，初始止损距离开仓时持久化，保本只推一次）（方案 4.4，G1）
- [x] ATR+结构点跟踪止损（主 EA `ApplyTrailingStop`，含 `InpTrailReplacesTP` 风格开关）（方案 4.4，G2/G3）
- [x] `PositionManager::StartCooldown`：亏损/盈利平仓差异化冷却长度（方案 4.3，G5）
- [x] 重连后 SL/TP 对账（主 EA `ReconcileRestoredStops`，SL 缺失按持久化初始止损距离重建）（方案 8.2，G10）
- [ ] `RiskManager::IsNewsBlackout`：新闻时段过滤（手工时间表或经济日历接入，P2 可选）（方案 5.2）

### M4 回测与优化（方案第 7 章）
- [x] 自定义 `OnTester` 复合优化指标（PF × √交易数 ÷ 最大相对回撤%，G7）
- [ ] MACD「零轴位置约束」优化开关对比（`SignalEngine::MomentumOk` 内 TODO）

### P2 增强项
- [ ] `Logger::Notify`：SendMail 邮件通道、每日日报（方案 8.3）
- [ ] 图表状态面板：状态机状态/趋势方向/当日盈亏/熔断状态（方案 F11）
- [ ] **账户级统一熔断**：当前日/周亏损熔断为「实例级（magic+symbol）」隔离；多品种同时运行时若需汇总全部实例的账户级总亏损熔断，属后续单独设计（需跨实例共享统计与互斥写入方案）

## 关键设计约定（开发时必须遵守）

- **一单一结不变量**：任何开仓路径必须先经 `CPositionManager::CanOpenNew()`（内部含真实持仓核对）；`CTradeExecutor::Open()` 发送前另有防御性二次持仓校验（A1，最后一道防线）；
- **持仓查询 Tick 级缓存**（D1）：`CountMyPositions/HasPosition` 同一 Tick 内复用缓存，`OnTick` 顶部已统一失效；**新增任何开/平仓路径后必须调用 `InvalidateCache()`** 避免脏读；
- **真实持仓为唯一事实来源**：新增状态流转逻辑时，勿只依赖内存状态，参考 `SyncWithReality()`（注：OPENING 态无持仓属正常，由主 EA 的 Tick 驱动重试分支处理）；
- **信号只用已收盘 K 线**（index ≥ 1），杜绝未来函数；
- **风控红线参数**（`InpDailyLossPct/InpWeeklyLossPct/InpRiskPercent`）不参与优化；
- 全局变量持久化统一使用各模块 Init 时生成的**实例级前缀** `"GTEA_"+magic+"_"+symbol+"_"`（magic+symbol 组合命名空间，避免多图表同 magic 时冷却/风控状态跨品种污染）；
- **多品种/多图表挂载必须为每个实例配置不同的 `InpMagic`**（OnInit 对默认 magic 有防呆 Warn）；如需账户级统一熔断，属后续单独设计（见 TODO 清单 P2）；
- **升级兼容说明**：从旧版本（仅按 magic 命名空间）升级到当前版本时，熔断与冷却的持久化命名空间已变为 magic+symbol，**历史状态不会被继承**——升级后当日/本周风控统计与冷却将从 0 重新累积，建议在非交易时段升级，必要时手动清理旧全局变量（前缀 `GTEA_<magic>_`）；注意全局变量名上限 63 字符，magic+品种组合过长时会被终端截断（E5 已加超长 ERROR 告警）；
- **版本号维护**（F1）：升版时同步修改 `Config.mqh` 的 `GTEA_VERSION` 与主 EA 的 `#property version`（MQL5 的 `#property` 不支持宏展开，无法直接引用宏）；
- **`STATE_OPENING` 语义**：表示已触发开仓流程、等待 Tick 驱动重试结果的状态，该状态下**可能暂时无真实持仓**，由 `OnTick` 的 `RetryOpenPosition()` 分支负责最终转为 `POSITION_OPEN` 或回退 `IDLE`；后续开发不要将「OPENING + 无持仓」当作异常处理；重启后恢复到持久化的 OPENING（待重试参数已丢失）时由 `RestoreState` 直接归为 `IDLE`（E1）。
