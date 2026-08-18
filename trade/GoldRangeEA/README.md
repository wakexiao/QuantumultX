# GoldRangeEA — 黄金箱体震荡高抛低吸（一单一结）

MT5 EA。自动识别 XAUUSD M15 横盘震荡区间（箱体），在上沿压力位做空、下沿支撑位做多；
每单独立开仓、独立止盈止损，禁止加仓/扛单/马丁；行情突破箱体走出趋势时自动暂停开仓。
需求唯一事实来源：`../GoldTrendEA/v1.md`（下文条款号均指向该文档）。

## 目录结构

```
GoldRangeEA/
├── Experts/GoldRangeEA.mq5      # 主 EA（初始化/OnTick 调度/持仓管理/成交回报）
└── Include/GoldRangeEA/
    ├── Config.mqh               # 全部 input 参数 + 枚举 + 点值换算 + 执行常量
    ├── Logger.mqh               # 分级日志（MQL5/Files/GoldRangeEA/）+ WARN 节流 + 推送
    ├── MarketData.mqh           # 新K线判定 / 交易环境校验 / 报价新鲜度
    ├── Indicators.mqh           # ADX + KDJ(iStochastic 近似) 句柄与读取
    ├── BoxEngine.mqh            # 策略核心：箱体识别 / 三级漏斗 / 止盈止损 / 盈亏比
    ├── PositionManager.mqh      # 6 态状态机 / 时间制冷却 / 箱体快照持久化 / 对账
    ├── RiskManager.mqh          # 固定手数 / 日亏净额熔断 / 连亏暂停 / 点差 / 保证金
    └── TradeExecutor.mqh        # CTrade 封装：市价开平仓 / 重试 / SL-TP 停损距校验
```

## v1.md 条款 → 代码映射

| v1 条款 | 实现（文件::函数） |
|---|---|
| §2.1 箱体定义（N 根最高/最低） | `BoxEngine.mqh::CBoxEngine::OnNewBar`（批量 CopyHigh/CopyLow + 线性扫描） |
| §2.2-1/2 高度 ∈ [15,80] 点过滤 | `BoxEngine::OnNewBar` 高度过滤分支 |
| §2.2-3 触碰次数 ≥2 | `BoxEngine::OnNewBar` 第二趟触碰计数（容差 `InpTouchTolerance`） |
| §2.2-4 ADX ≤25 | `BoxEngine::OnNewBar` ADX 过滤（`Indicators::AdxValue`） |
| §2.3 每根新 K 线刷新箱体 | `GoldRangeEA.mq5::OnTick` ③ → `BoxEngine::OnNewBar` |
| §3.1 做多（下沿+容差 & J≤20） | `BoxEngine::EvaluateEntry` L1/L2/L3 三级漏斗 |
| §3.2 做空（上沿−容差 & J≥80） | `BoxEngine::EvaluateEntry` L1/L2/L3 |
| §3.3 箱体中部绝对不开仓 | `BoxEngine::EvaluateEntry` L2 位置过滤（两次 double 比较） |
| §3.1/3.2 最小交易间隔 5 分钟 | `PositionManager::MinIntervalElapsed/CanOpenNew`（时间制，`OnPositionClosed` 记时间戳） |
| §4.1 ADX>25 禁开新仓（存量单正常止盈止损） | `BoxEngine::OnNewBar` 置无效箱体 → `EvaluateEntry` L1 拒绝；持仓管理不受影响 |
| §4.2 突破止损联动 | `GoldRangeEA.mq5::ManagePosition` ① + `PositionManager::SaveBoxSnapshot/BoxSnapshot` |
| §5.1 止盈（模式 A 比例 / 模式 B 对侧） | `BoxEngine::CalcStops`（`InpTPMode` 枚举切换） |
| §5.2 止损（高度×0.4，置于箱体外侧） | `BoxEngine::CalcStops`（min/max 取箱体外侧价） |
| §5.3 盈亏比 ≥1.2 否则放弃 | `BoxEngine::CheckMinRR` + `OnTick` ⑧（INFO 日志放弃） |
| §5.4 时间止损 4 小时 | `GoldRangeEA.mq5::ManagePosition` ② |
| §6.1 日亏损 10 美元（净额口径） | `RiskManager::OnTradeResult/IsHalted/CheckPeriodReset`（盈利抵扣、次日复位） |
| §6.2 连亏 3 笔暂停 30 分钟 | `RiskManager::OnTradeResult/CheckPeriodReset`（PAUSE_UNTIL 持久化） |
| §6.3 同一时间最多 1 单 | `PositionManager::CountMyPositions/CanOpenNew` + `TradeExecutor::Open` 二次防御 |
| §6.4 固定手数 0.01 | `RiskManager::FixedLots`（MIN/MAX/STEP 归一化） |
| §七 23 项参数 | `Config.mqh`（默认值逐项照抄） |
| §八-1/2/3 无加仓/无多单/无对冲 | 状态机仅 IDLE→…→POSITION_OPEN 单笔路径，无第二开仓路径 |
| §八-4 每单必带 SL/TP | `GoldRangeEA::TryOpenPosition`（市价单带 SL/TP 下单，无裸单路径） |
| §八-5 禁按浮亏调手数 | 无浮亏相关手数逻辑，仅 `FixedLots` |
| §八-6 禁中部开仓 | 同 §3.3 |
| §八-7 ADX>25 禁开仓 | 同 §4.1 |
| §八-8 禁移动止损 | `TradeExecutor` 已删除 ModifySL 接口，SL 入场后固定 |
| §十-1 点=0.01 美元 | `Config.mqh::PtsToPrice`（固定换算） |
| §十-2 回测建议 | `GoldRangeEA.mq5::OnTester`（PF×√N÷回撤 复合适应度） |

## 实现决策记录（用户确认 / 开发决策）

- **D1 入场用 Tick 级检测（用户确认）**：入场条件是「价格到达箱体沿位 + KDJ 极值」的
  盘中价格事件，等 M15 收盘会错过回抽；故箱体按 M15 新 K 线刷新，入场条件逐 Tick 检查，
  突破止损联动亦 Tick 级实时（§4.2）。
- **D2 突破止损基准 = 开仓时刻的箱体快照**：持仓期间箱体逐 K 线动态漂移，若用「当前
  箱体」判定突破会导致基准移动、突破判定失真；开仓成功即将上下沿写入全局变量
  `BOX_UPPER/BOX_LOWER`（GV 持久化，EA 重启后 `RestoreState` 读回）。
- **D3 KDJ 口径 = iStochastic(9,3,3, MODE_SMA, STO_LOWHIGH) + J = 3K − 2D**：MT5 无
  原生 KDJ，此为业界标准近似；J 值对超买超卖的灵敏度高于 K/D，符合 v1 §3.1/3.2 语义。
- **D4 点值固定 1 点 = 0.01 美元，不依赖 SYMBOL_POINT**（v1 §十-1）：3 位小数报价的
  经纪商上全部「N 点」参数语义不变；`SYMBOL_POINT ≠ 0.01` 时 OnInit 仅 WARN 提示不拒启。

## 构建与部署

1. **编译目标必须选 `X64 Regular`**（MetaEditor → 工具 → 选项 → 编译器）。
   禁止 `X64 AVX2 + FMA3`：仅支持 AVX 的 CPU 上 EA 加载会报错 568。
2. 目录导入 MQL5：将 `Include/GoldRangeEA/` 拷入 `MQL5/Include/`，将
   `Experts/GoldRangeEA.mq5` 拷入 `MQL5/Experts/`，MetaEditor 中按 F7 编译；
   日志输出到 `MQL5/Files/GoldRangeEA/yyyymmdd.log`。
3. 回测建议（v1 §十-2）：近 1 年 XAUUSD M15，「仅开盘价」之外的每 Tick 模式（入场为
   Tick 级）；重点观察：震荡段胜率与盈利、ADX>25 时段零开仓、最大回撤是否可控。

## 安全网与边界提示

- **InpMaxSpreadPoints=50（v1 规格外保护）**：v1 未要求点差过滤，属实盘保护性安全网；
  设 0 可完全关闭（直通）。参数按 1 点=0.01 美元口径解释，内部以 Ask-Bid 价格差比较，
  2 位/3 位小数报价的经纪商上语义一致（评审修复 F1）。
- **最小箱体 15 点时 SL 仅 6 点**（15×0.4，模式 A 下 TP 7.5 点）：若券商
  `SYMBOL_TRADE_STOPS_LEVEL` > 6 点，开仓将被停损距校验拒绝（日志 ERROR「SL/TP 不满足
  最小停损距」后放弃）；此时可调大 `InpBoxMinPoints` 或 `InpSLRatio`，或换止损位更宽
  的券商账户。
- 持久化全局变量前缀 `GREA_{magic}_{symbol}_`：多图表挂载请为每个图表配置不同 magic。
- **Netting（净持仓）账户警示**：同品种手动交易会与 EA 持仓合并导致 magic 漂移，EA
  会漏管持仓并可能重复开仓——Netting 账户请勿手动交易同品种，建议用 Hedging 账户
  或独立账户运行本 EA。
- **勿与 GoldTrendEA 共用相同 magic**：GoldTrendEA 默认 magic=20260813，两者若配置
  相同 magic 且挂同一品种，会互相误管对方持仓（平仓/统计串扰）。
- **美分账户换算**：账户货币为美分时，`InpMaxDailyLossUSD` 需按账户货币换算——如目标
  10 美元日亏上限应设 1000（1 美元=100 美分）。
- **连亏暂停口径**：按「连续净亏损笔数」计数（含时间止损/突破联动的小亏平仓），比
  规格 v1 §6.2 字面「连续止损单」更保守，属有意实现。
- **盈亏入账口径**：按平仓成交的 `PROFIT+SWAP+COMMISSION` 计；佣金拆两腿（开仓腿+
  平仓腿）收取的经纪商会略微低估日亏（黄金 CFD 多为免佣或单腿低佣，影响有限）。

## 风险声明

本策略定位为阶段性震荡行情套利工具（v1 §十-3），非长期全天候策略；行情走出大趋势时
ADX 过滤会自动停止开仓，但仍建议人工监控，必要时手动关停。
