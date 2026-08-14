# GoldTrendEA — 黄金外汇「顺势一单一结」EA 框架

> 对应方案文档：[黄金外汇EA顺势一单一结开发方案.md](../黄金外汇EA顺势一单一结开发方案.md)
> 当前版本：v0.10（M1 框架搭建阶段产出：接口定义 + 骨架实现，**非完整可交易版本**）

## 目录结构

```
GoldTrendEA/
├── Experts/
│   └── GoldTrendEA.mq5            # 主 EA：OnInit/OnTick/OnDeinit/OnTradeTransaction
├── Include/
│   └── GoldTrendEA/
│       ├── Config.mqh             # 29 项 input 参数 + 公共枚举（方案 4.5 节参数表 + InpLogKeepDays 日志保留天数）
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
| SignalEngine | `CSignalEngine` | MarketData, Indicators | `Evaluate() → BUY/SELL/NONE`、`IsTrendReversed` |
| PositionManager | `CPositionManager` | Logger | `CanOpenNew/CountMyPositions/SyncWithReality/OnPositionClosed/RestoreState` |
| RiskManager | `CRiskManager` | Logger | `CalcLots/IsHalted/SpreadOk/IsFridayCloseTime/OnTradeResult` |
| TradeExecutor | `CTradeExecutor` | Logger | `Open(重试)/CloseMyPosition/ModifySL/ApplyBreakEven/ApplyAtrTrailing` |

依赖注入均在主 EA 的 `OnInit` 中完成（指针注入），各模块之间不直接互相构造。

## 如何导入 MT5

1. 打开 MT5 → 「文件」→「打开数据文件夹」→ 进入 `MQL5/` 目录；
2. 将本项目 `Experts/GoldTrendEA.mq5` 拷贝到 `MQL5/Experts/`（可放子目录如 `MQL5/Experts/GoldTrendEA/`）；
3. 将本项目 `Include/GoldTrendEA/` 整个目录拷贝到 `MQL5/Include/` 下（即最终为 `MQL5/Include/GoldTrendEA/*.mqh`，**目录名不可改**，与 `#include <GoldTrendEA/...>` 路径对应）；
4. 在 MetaEditor 中打开 `GoldTrendEA.mq5` 按 F7 编译；
5. 编译通过后在 MT5 中将 EA 拖到 XAUUSD H1 图表（任意周期均可运行，H1 与内部 `InpSignalTF` 一致最直观），启用「算法交易」。

> 注意：当前为框架版本，可编译、可挂载、可完成"信号评估→开仓→止损止盈→平仓→冷却"的基本闭环，但保本推损/ATR 跟踪/结构点止损等仍为 TODO 骨架，**请勿用于实盘**。

> 运维提示（日志参数）：VPS 长期运行时请按磁盘容量设置 `InpLogKeepDays`（建议 30/60/90 天，超期旧日志自动清理）；若回测或实盘出现「单日日志超 50MB」WARN，应精简日志级别或提高 `WarnThrottled` 节流窗口。

## 后续开发待办（TODO 清单）

按方案文档里程碑推进，代码内均有 `TODO(阶段, 方案章节)` 标注：

### M2 策略信号实现
- [ ] `SignalEngine::IsTrendReversed`：条件二「完整反向三重信号」——复用 `Evaluate()` 并缓存本根 K 线评估结果，避免重复计算（方案 4.4）
- [ ] `GoldTrendEA.mq5::TryOpenPosition`：结构点止损候选 —— `SwingLow/SwingHigh` 外加缓冲，与 ATR 距离取 max（方案 4.4）

### M3 风控与出场完善
- [ ] `TradeExecutor::ApplyBreakEven`：保本推损完整实现；需要在开仓时把**初始止损距离**持久化到全局变量（保本后 `pos.StopLoss()` 已变化）（方案 4.4）
- [ ] `TradeExecutor::ApplyAtrTrailing`：ATR 跟踪止损完整实现，含 `InpTrailReplacesTP` 风格开关（方案 4.4）
- [ ] `PositionManager::StartCooldown`：亏损/盈利平仓差异化冷却长度（方案 4.3）
- [ ] `PositionManager::RestoreState`：重连后首个 Tick 全量对账（SL/TP 与预期一致性校验）（方案 8.2）
- [ ] `RiskManager::IsNewsBlackout`：新闻时段过滤（手工时间表或经济日历接入，P2 可选）（方案 5.2）

### M4 回测与优化（方案第 7 章）
- [ ] 自定义 `OnTester` 复合优化指标（PF × 回撤组合）
- [ ] MACD「零轴位置约束」优化开关对比（`SignalEngine::MomentumOk` 内 TODO）

### P2 增强项
- [ ] `Logger::Notify`：SendMail 邮件通道、每日日报（方案 8.3）
- [ ] 图表状态面板：状态机状态/趋势方向/当日盈亏/熔断状态（方案 F11）
- [ ] **账户级统一熔断**：当前日/周亏损熔断为「实例级（magic+symbol）」隔离；多品种同时运行时若需汇总全部实例的账户级总亏损熔断，属后续单独设计（需跨实例共享统计与互斥写入方案）

## 关键设计约定（开发时必须遵守）

- **一单一结不变量**：任何开仓路径必须先经 `CPositionManager::CanOpenNew()`（内部含真实持仓核对）；
- **真实持仓为唯一事实来源**：新增状态流转逻辑时，勿只依赖内存状态，参考 `SyncWithReality()`（注：OPENING 态无持仓属正常，由主 EA 的 Tick 驱动重试分支处理）；
- **信号只用已收盘 K 线**（index ≥ 1），杜绝未来函数；
- **风控红线参数**（`InpDailyLossPct/InpWeeklyLossPct/InpRiskPercent`）不参与优化；
- 全局变量持久化统一使用各模块 Init 时生成的**实例级前缀** `"GTEA_"+magic+"_"+symbol+"_"`（magic+symbol 组合命名空间，避免多图表同 magic 时冷却/风控状态跨品种污染）；
- **多品种/多图表挂载必须为每个实例配置不同的 `InpMagic`**（OnInit 对默认 magic 有防呆 Warn）；如需账户级统一熔断，属后续单独设计（见 TODO 清单 P2）；
- **升级兼容说明**：从旧版本（仅按 magic 命名空间）升级到当前版本时，熔断与冷却的持久化命名空间已变为 magic+symbol，**历史状态不会被继承**——升级后当日/本周风控统计与冷却将从 0 重新累积，建议在非交易时段升级，必要时手动清理旧全局变量（前缀 `GTEA_<magic>_`）；
- **`STATE_OPENING` 语义**：表示已触发开仓流程、等待 Tick 驱动重试结果的状态，该状态下**可能暂时无真实持仓**，由 `OnTick` 的 `RetryOpenPosition()` 分支负责最终转为 `POSITION_OPEN` 或回退 `IDLE`；后续开发不要将「OPENING + 无持仓」当作异常处理。
