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
| §2.2-1/2 高度 ∈ [500,3000] 点过滤 | `BoxEngine::OnNewBar` 高度过滤分支（重标定后量级，见下「波动率重标定」） |
| §2.2-3 触碰次数 ≥2 | `BoxEngine::OnNewBar` 第二趟触碰计数（容差 `InpTouchTolerancePct`% 与 `InpTouchTolMinPoints` 下限取大） |
| §2.2-4 ADX ≤25 | `BoxEngine::OnNewBar` ADX 过滤（`Indicators::AdxValue`） |
| §2.3 每根新 K 线刷新箱体 | `GoldRangeEA.mq5::OnTick` ③ → `BoxEngine::OnNewBar` |
| §3.1 做多（下沿双边带 & J≤30） | `BoxEngine::EvaluateEntry` L1/L2/L3 三级漏斗（2 根已收盘 K 线 J 任一达标） |
| §3.2 做空（上沿双边带 & J≥70） | `BoxEngine::EvaluateEntry` L1/L2/L3（同上） |
| §3.3 箱体中部绝对不开仓 | `BoxEngine::EvaluateEntry` L2 双边带位置过滤（内缘入场侧报价、外缘对侧报价判定，v1.10） |
| §3.1/3.2 最小交易间隔 5 分钟 | `PositionManager::MinIntervalElapsed/CanOpenNew`（时间制，`OnPositionClosed` 记时间戳） |
| §4.1 ADX>25 禁开新仓（存量单正常止盈止损） | `BoxEngine::OnNewBar` 置无效箱体 → `EvaluateEntry` L1 拒绝；持仓管理不受影响 |
| §4.2 突破止损联动 | `GoldRangeEA.mq5::ManagePosition` ① + `PositionManager::SaveBoxSnapshot/BoxSnapshot` |
| §5.1 止盈（模式 A 比例 / 模式 B 对侧） | `BoxEngine::CalcStops`（`InpTPMode` 枚举切换） |
| §5.2 止损（高度×0.4，置于箱体外侧） | `BoxEngine::CalcStops`（min/max 取箱体外侧价） |
| §5.3 盈亏比 ≥1.2 否则放弃 | `BoxEngine::CheckMinRR` + `OnTick` ⑧（INFO 日志放弃） |
| §5.4 时间止损 4 小时 | `GoldRangeEA.mq5::ManagePosition` ② |
| §6.1 日亏损 30 美元（净额口径） | `RiskManager::OnTradeResult/IsHalted/CheckPeriodReset`（盈利抵扣、次日复位） |
| §6.2 连亏 4 笔暂停 30 分钟 | `RiskManager::OnTradeResult/CheckPeriodReset`（PAUSE_UNTIL 持久化） |
| §6.3 同一时间最多 1 单 | `PositionManager::CountMyPositions/CanOpenNew` + `TradeExecutor::Open` 二次防御 |
| §6.4 固定手数 0.01 | `RiskManager::FixedLots`（MIN/MAX/STEP 归一化） |
| §七 23 项参数 | `Config.mqh`（参数框架一一对应；默认值已按 XAUUSD 实际波动量级重标定，不再逐项照抄 v1 默认值，见下「波动率重标定」） |
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

## 波动率重标定（重要）

> **升级提示（从旧版本升级务必阅读）**：旧版本保存的 `.set` 文件加载时会按参数名
> **静默覆盖**新默认值，且已删除的 `InpTouchTolerance`/`InpEntryTolerance` 在旧
> `.set` 中成为死键（MT5 静默忽略、无任何提示）。旧值落入 v1.10 后的行为分两类：
> ①**箱体/容差/突破类**旧值（如 `InpBoxMinPoints=15`、`InpBoxMaxPoints=80`、
> `InpBreakoutPoints=5`）——会被 v1.10 参数校验**直接拒启**并提示约束（拒启是有意
> 的安全拦截）；②**KDJ 阈值类**旧值（如超买/超卖 `80`/`20`）——会**静默通过**校验
> 但显著压低信号频次。两种情况的处理方式相同：**删除或重建 `.set` 文件**，或逐项
> 核对下方参数对照表；启动后请核对日志中的**「生效配置」**行（v1.10 起 OnInit 打印
> 全部关键参数）确认参数已更新为新标定值。

**为什么改**：原设计假设黄金日波幅约 150-400 点（$1.5-4），而 XAUUSD 9-15 小时的实际
高低范围典型为 $20-45（约 10 倍于原假设）。原默认箱体高度窗口 [15,80] 点 =
[$0.15,$0.80] 几乎永远无法满足，导致有效箱体永不形成、信号在第一级过滤（L1）全灭，
EA 长期零开单。新默认值按真实 XAUUSD 波动量级校准，**目标为震荡日 2-3 单/日；趋势日
仍为 0 单（ADX 过滤生效），属策略定位而非故障**。

**重标定后参数默认值对照**：

| 参数 | 原默认 | 新默认 | 说明 |
|---|---|---|---|
| `InpBoxBars` | 60 | 36 | 36 根 M15 ≈ 9 小时窗口，加快箱体形成与更迭 |
| `InpBoxMinPoints` | 15 | 500 | $5；消除微箱体（停损距拒单、点差占比过高） |
| `InpBoxMaxPoints` | 80 | 3000 | $30；匹配黄金实际波动量级 |
| `InpTouchTolerance`（点） | 3 | —— | 删除，由下行两个百分比制参数替代 |
| `InpTouchTolerancePct`（%） | —— | 3.0 | 触碰容差 = max(高度×3%, 下限)，随箱体量级缩放 |
| `InpTouchTolMinPoints`（点） | —— | 30 | 触碰容差下限 |
| `InpEntryTolerance`（点） | 3 | —— | 删除，由下行两个百分比制参数替代 |
| `InpEntryTolerancePct`（%） | —— | 2.5 | 入场带半宽 = max(高度×2.5%, 下限)，随箱体量级缩放 |
| `InpEntryTolMinPoints`（点） | —— | 30 | 入场带下限 |
| `InpKDJOverbought` | 80 | 70 | 原 80 过严 |
| `InpKDJOversold` | 20 | 30 | 原 20 过严 |
| `InpBreakoutPoints` | 5 | 100 | $1；防放大箱体后突破止损被噪音秒触发 |
| `InpMaxDailyLossUSD` | 10 | 30 | 与新量级下单笔风险匹配（见下） |
| `InpMaxConsecSL` | 3 | 4 | 放宽一笔，避免过早锁死日内频次 |
| `InpVerboseSignalLog` | false | true | 调试期默认开启；各出口均有 60 秒节流或按新 K 线频率输出，不会每 Tick 刷屏，确认策略正常后可改回 false |

**三项结构变更**（非单纯改默认值）：

1. **容差百分比化（含下限）**：触碰容差与入场容差由固定 3 点改为
   `max(箱体高度 × 百分比, 下限点数)`——固定点数容差不随箱体量级缩放（大箱体上
   相对过窄），百分比制下容差带与箱体高度同比例缩放，下限 30 点防极矮箱体退化。
   注意：箱高 < 1000 点（$10）时触碰容差由下限 30 点主导（$0.30，相对容差最高约
   6%），而非名义的 3%。实现于 `BoxEngine::OnNewBar`。
2. **双边入场区（防接飞刀 + 消除开仓即秒平，v1.10 修订）**：原做多条件
   `Ask ≤ 下沿+容差` 无下界——价格暴跌到箱体下方任意远处仍算"到下沿"，会在单边
   下跌中接飞刀。现改为双边带，且**外缘以对侧报价判定**：做多需 `Ask ≤ 下沿+band`
   （内缘，成交价口径）且 `Bid ≥ 下沿−band`（外缘，对侧报价）；做空需
   `Bid ≥ 上沿−band` 且 `Ask ≤ 上沿+band`。外缘用对侧报价的动机：突破联动止损以
   对侧报价判定（多单看 Bid），若外缘用入场侧报价，当 band+点差 > 突破点数时存在
   开仓瞬间即触发突破止损平仓的窗口（默认最坏组合 75+50=125 > 100 点——每次小亏
   点差、连亏 4 笔即触发 30 分钟暂停，消耗日内频次配额）；对侧口径下开仓瞬间对侧
   报价距突破联动线至少还有 `InpBreakoutPoints − band` 的余量（当前默认
   100−75=25 点），从根上消除该窗口。实现于 `BoxEngine::EvaluateEntry` L2。
3. **KDJ 2 根收盘 K 线窗口**：KDJ 确认由"仅 shift=1 一根已收盘 K 线 J 达标"放宽为
   "shift=1 或 shift=2 任一根 J 达标"，缓解 Tick 级沿位检查与已收盘 K 线指标的
   时间口径错配。实现于 `BoxEngine::EvaluateEntry` L3（`Indicators::KdjJ` 的 shift 参数）。

**风险量级变化（务必知悉）**：0.01 手下新单笔 SL 风险约 **$2-12**（高度 500-3000 点 ×
止损比例 0.4，即 $5×0.4 至 $30×0.4；原 $0.32）。日亏熔断 **$30** 相对单笔风险并非
恒定倍数，须按以下口径理解：

- **熔断倍数随箱体量级变化**：中位箱体（高度约 $10-15、单笔 SL $4-6）时约为单笔的
  4-6 倍，"震荡日 2-3 单/日"的目标不会被一笔亏损过早锁死；但**最大箱体（$30）单笔
  SL $12 时熔断额仅为单笔的 2.5 倍，3 笔满额止损即触发日熔断**（次日自动恢复）。
- **最坏单日敞口大于熔断额**：熔断按当日已实现净额判定、且仅在开新仓前检查，触发
  前已在场的最后一单仍会平仓入账——最坏单日已实现亏损 ≈ 熔断额 $30 + 在途单笔
  风险 ≈ **$32-42**（$30 + 在途单笔 $2-12；其中 $36-42 一侧对应「3 笔满额止损」
  典型路径，跳空情形见下条，实际无硬上限）。
- **跳空风险无硬上限**：跳空/周末/新闻行情下服务器端 SL 不保证按设定价成交，按
  跳空价成交时单笔实际亏损可能超过名义 SL 距离（单笔名义风险放大至 $2-12 后，
  跳空超额绝对值同步放大），最坏单日敞口**无硬上限**；日亏统计按实际成交盈亏入账。
- **连亏暂停的角色分工**：对"大亏序列"实际由日熔断先拦截（最大箱体下 3 笔满额
  止损即触发日熔断）；连亏 4 笔暂停 30 分钟主要拦截**小亏序列**（如突破联动、
  时间止损的小亏平仓连续出现时）。

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
- **停损距校验余量充足（重标定后）**：最小箱体 500 点时 SL = 500×0.4 = 200 点（$2）、
  模式 A 下 TP = 250 点（$2.5），远大于经纪商常见的 `SYMBOL_TRADE_STOPS_LEVEL`
  （通常 0-30 原生点）；原「最小箱体 15 点时 SL 仅 6 点易被停损距校验拒单」的问题
  已随波动率重标定消除（见上「波动率重标定」节）。
- 持久化全局变量前缀 `GREA_{magic}_{symbol}_`：多图表挂载请为每个图表配置不同 magic。
- **Netting（净持仓）账户警示**：同品种手动交易会与 EA 持仓合并导致 magic 漂移，EA
  会漏管持仓并可能重复开仓——Netting 账户请勿手动交易同品种，建议用 Hedging 账户
  或独立账户运行本 EA。
- **勿与 GoldTrendEA 共用相同 magic**：GoldTrendEA 默认 magic=20260813，两者若配置
  相同 magic 且挂同一品种，会互相误管对方持仓（平仓/统计串扰）。
- **美分账户换算**：账户货币为美分时，`InpMaxDailyLossUSD` 需按账户货币换算——如目标
  30 美元日亏上限应设 3000（1 美元=100 美分）。
- **连亏暂停口径**：按「连续净亏损笔数」计数（含时间止损/突破联动的小亏平仓），比
  规格 v1 §6.2 字面「连续止损单」更保守，属有意实现。
- **盈亏入账口径**：按平仓成交的 `PROFIT+SWAP+COMMISSION` 计；佣金拆两腿（开仓腿+
  平仓腿）收取的经纪商会略微低估日亏（黄金 CFD 多为免佣或单腿低佣，影响有限）。
- **开仓重试残余风险**：开仓重试的 30 秒窗口内价格若已深破沿位，重试成交后可能
  较快触发突破联动平仓（既有重试设计，重试时按当前价与当前箱体重算 SL 兜底）。

## 风险声明

本策略定位为阶段性震荡行情套利工具（v1 §十-3），非长期全天候策略；行情走出大趋势时
ADX 过滤会自动停止开仓，但仍建议人工监控，必要时手动关停。
