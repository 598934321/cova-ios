# 开发交接手册 — Cova iOS 原生客户端

> 面向接手本仓的开发者/代理。先读本手册，再读 `AGENTS.md`、`docs/EXECUTION-PROMPT.md`
> （编排协议）、`docs/PLAN.md`（总计划）、`docs/decisions.md`（锁定决策）。
> 本手册记录**截至 2026-09-20 的真实状态**，不粉饰未完成项。

---

## 0. 一分钟现状速览

| 项 | 值 |
|---|---|
| 当前锚点 | HEAD = 本 commit（G3-d 落证，父提交 `f39cfa9` = 代码锚点），工作树干净（另有 1 个 stash，见 §9） |
| 版本 | `CFBundleShortVersionString 0.2.25` / `CFBundleVersion 36`（`project.yml`） |
| 阶段 | G0 已完成并落证；G3（核心层）进行中：**G3-a/G3-b/G3-c/G3-d 已验收**（G3-d 于第十轮隔离评审 100% 通过），剩 **G3-e（CovaPlayer）未开始**；**G1 Figma 方向稿已产出待用户验收**（§9） |
| 门禁 | `Scripts/check.sh` **十步** EXIT=0（协调者在含环 4 全部修复的 HEAD 上亲跑）：CovaCore 372 / 95.28%、**CovaPlayer 331 / 93.75%**（15/15 源文件无条件归因）；第 3 轮复审又判门禁 2 Major（禁 UI 黑名单形态可被 WebKit 与「仅测试 target 的 UIKit」打穿）→ 正在改白名单 |
| 设计闸门 | G1 方向稿已产出（§9）**待用户验收** / G2 未开始 → **禁止写 UI 代码** |
| 唯一未阻塞工作 | G3 核心层（纯逻辑，不涉 UI）：G3-e CovaPlayer；G1 验收 + G2 全量设计是外部依赖 |
| 下一步 | 见 §10：G3-e（CovaPlayer，D4/D7）与 G1 用户验收并行 |

**最重要的一句**：本仓一切改动走「五环流程 + 隔离评审」（§4）。不要跳过门禁、不要自评自过、
不要在 G1/G2 未验收时写 UI。

---

## 1. 这是什么

Cova（CovaLink）AI 音乐商用授权平台的 iPhone 原生 App。独立 git 仓，零第三方依赖，
SwiftUI + Swift Concurrency，部署目标 iOS 26。分层为四个本地 SwiftPM 包：

- `CovaCore`：模型 / API client / 认证 / SSE / 幂等 / 持久化（纯逻辑，全 XCTest）
- `CovaPlayer`：AVPlayer 自研播放层（**尚未实现**，G3-e）
- `CovaUI`：tokens / 材质 / 组件 / 动效（**尚未实现**，等 G2 设计验收）
- `CovaFeature`：各屏（**尚未实现**，等 G2 设计验收）

---

## 2. 仓库结构与工具链

```
多端/ios app/
├── AGENTS.md                # 硬边界 9 条 + 工具链约定（必读）
├── README.md                # 项目简介
├── HANDOVER.md              # 本手册
├── project.yml              # XcodeGen 唯一工程事实源（*.xcodeproj 不入 git）
├── Config/Info.plist        # bundle id / UIBackgroundModes:audio / 版本引用
├── Cova/CovaApp.swift       # 最小 App 入口（仅占位根视图）
├── CovaTests/               # App 工程层间装配测试（2 条）
├── Packages/                # 四层本地 SwiftPM 包（CovaCore 已实现）
├── Scripts/
│   ├── check.sh             # 门禁（8 步，见 §3）
│   └── test-count-baseline.env   # 测试数量下限（APP_MIN=2 / CORE_MIN=372 / PLAYER_MIN=331）
├── design/                  # tokens.json + screens/*.md + components.md + 官方 AppIcon
└── docs/
    ├── PLAN.md PRD.md decisions.md api-contracts.md NEEDS.md
    ├── design-language.md release-runbook.md EXECUTION-PROMPT.md
    └── log/20260917.md      # 全部推导、修复记录、技术债清单、环5验收
```

工具链（本机实测）：**Xcode 27.0（27A266a）/ iOS 27.0 SDK / Swift 6.4 / XcodeGen 2.45.4**。
模拟器：`iPhone 17 Pro`（运行时 iOS 26.5 与 iOS 27.0 均可用；门禁默认用前者）。
Apple 许可已接受；若新机器报 `You have not agreed to the Xcode license agreements`，
执行 `sudo xcodebuild -license accept`。

---

## 3. 构建与验收：`Scripts/check.sh`（fail-closed 门禁）

一条命令全量验收：

```bash
./Scripts/check.sh        # 退出码 0 才算过；任何一步失败立即非零退出
```

十步及其含义（G3-e 起由八步扩来：播放器层需要自己的测试与覆盖率口径）：

| 步骤 | 内容 |
|---|---|
| 0/10 | 预热模拟器 |
| 1/10 | `xcodegen generate` 重新生成工程 |
| 2/10 | 工程结构 / 语言模式 / 无远程包·框架·二进制制品 / 零第三方依赖 |
| 3/10 | `swift package dump-package` 依赖图（含 target 级依赖与源路径）+ **CovaCore 平台中立性**（整目录禁止字面 `#if`、禁止 iOS-only import）+ **播放器层禁 UI** + 符号链接禁令 + 源集合非空反向守卫 |
| 4/10 | 有效构建设置（Debug/Release × simulator/device）+ clean build + **从实际编译日志断言 `-swift-version 6`** + 产物保真（bundle id / minOS / `UIBackgroundModes`） |
| 5/10 | App 工程测试（CovaTests，iOS 模拟器）+ xccov 采集有效性 |
| 6/10 | 核心层包测试（CovaCoreTests，iOS 模拟器），只认 xcresult 的 `passed`，且 `failed==0` |
| 7/10 | 核心层行覆盖率（SwiftPM 插桩 + `llvm-cov`，阈值 80%）+ 编译集合与源集合双向一致 |
| 8/10 | **播放器层包测试**（CovaPlayerTests，iOS 模拟器），同时产出第 9 步要用的插桩产物（先清 ProfileData + 打时间戳） |
| 9/10 | **播放器层行覆盖率**：消费第 8 步的 `Coverage.profdata` + `llvm-cov` lcov（阈值 80%），并做 `.o ↔ OutputFileMap ↔ __llvm_covmap` **三方无条件交叉**归因（读不到即 fail-closed） |

**门禁设计要点（改动前必读）**：

- 只允许追加断言，不允许为了让门禁变绿而放宽；测试数量下限在 `Scripts/test-count-baseline.env`，
  新增测试要同步抬高基线（随 commit 进入版本递增与人工审查）。
- **硬边界 8 的机械化仍在收敛中（第 3 次复现，已换判据形态）**：3/10 目前用「单一词源
  `PLAYER_UI_MODULES` 派生三层判据」（字面 import / 符号 / 依赖与产物）。
  ⚠️ **撤回本手册此前的不实表述**：「正反对照均已实测（5 种绕过形态全部命中）」只在
  当时那 5 个夹具上成立。隔离复审随后连续打穿：第 2 轮 `import AVKit` +
  `AVPlayerViewController` 全绿；第 3 轮 `import WebKit` + `WKWebView` 全绿，
  `import SafariServices` / `import MessageUI` 也各自全绿；把 `import UIKit` + `UIView`
  只放进播放器**测试** target 同样三层皆不可见（L1 只扫非测试 target、符号层只扫产品
  objdir、dylib 层对 UIKit 整名豁免）。
  **根因是判据形态：黑名单靠人列举必然漏** → 正在改为**白名单**（播放器层含测试 target
  只允许固定 import 集合，其余一律红），并把 UIKit 豁免收窄为「UIKit 且 weak」
  （实测：合法态测试二进制是 weak UIKit，任何直接引用后变强依赖 —— weak 承载信号）。
  反向守卫（清空 `Sources` 即失败）保留。
- 判据来自**权威机器可读产物**（`dump-package` / `.SwiftFileList` / `xcactivitylog` / `xcresult` /
  `plansrc lcov`），不依赖对源码文本的正则——这是 G0 期间 8 轮对抗审查换来的结论，别再退回文本正则。
- **误红与漏检同等严重**：任何新断言都要有「合法工程对照不得误红」用例（TD-9）。
- 已知工具链坑：
  - `gunzip -c | strings` 从 stdin 会按约 1022 字符截断超长可打印串 → 门禁必须「解压到文件后
    `strings <file>`」（`300d985` 前已修复，勿改回管道形式）。
  - Xcode 不为本地 SwiftPM 包目标产出 `xccov` 覆盖率 → 覆盖率用 SwiftPM 插桩 + `llvm-cov`，
    并以「CovaCore 平台中立性」静态不变量兜底（TD-2/TD-5/TD-7）。
  - CovaCore 内**符号链接整类禁止**、`Sources/` 下名为 `Tests` 的子目录等会误红（TD-8/TD-10）。

只跑测试（调试用，不替代门禁）：

```bash
swift test --package-path Packages/CovaCore                    # macOS 主机，快
swift test --package-path Packages/CovaCore --filter 某用例名  # 定向
# iOS 模拟器定向（门禁同款）
xcodebuild -scheme CovaCore -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CovaCoreTests/某套件 test
```

---

## 4. 开发流程：五环 + 隔离评审（本仓纪律，违反即返工）

**角色**：

- **协调者**：维护 PLAN/日志、派任务、生成评审交接包、裁决循环与停止条件。不做实现、不做评审细节。
- **开发实例**：环 1（第一性原理推导，写进 `docs/log/YYYYMMDD.md`）+ 环 2（最小实现 + 门禁 + commit）。
- **评审实例**：环 3（对抗性黑盒审查）。**每次都是全新上下文，与开发实例零共享**。

**环 3 隔离协议（最高优先级）**：

1. 评审实例是新会话/新子代理，不继承开发者上下文（推导笔记、自评、修复说明、聊天历史、日志）。
2. 协调者只许给它三样：**代码事实**（仓库路径 + 待审 commit 范围）、**规格坐标**（PLAN 条目 /
   decisions 编号 / 契约端点 / 设计文件名，只给坐标不给解读）、**机械指令**（如何跑 `check.sh`、如何截图）。
   禁止传递「改了什么/为什么/我认为通过了/上轮修了什么」。
3. 评审自己检出、自己跑门禁、自己构造攻击用例、自己截图；**不采信开发方任何日志/截图**。
4. 评审报告是唯一回传物；开发对 finding 有异议只能在下轮评审用新证据反驳。
5. 复审也是全新实例，协调者给它上轮 findings 作「待攻击弱点清单」（只列现象与位置，不附修复说明）。
6. **同上下文「角色切换自评」不算对抗性审查**。无子代理能力时必须另开会话。
7. 交付评审交接包时，`git diff` 一律排除 `docs/log/`（否则会泄漏开发者叙事，削弱隔离）。
8. 同一缺陷**修两轮未消除** → 停止盲修，先写复现用例定位根因，再由协调者裁决（本仓已发生过两次，
   见 D16 与 G0 门禁演进）。

**闭环判据**：一轮评审 **零 Critical、零 Major** 才算过；Minor 记入 `docs/log/20260917.md` 技术债清单。
环 5 由协调者落证（勾选 PLAN、更新日志、递增版本、commit）。

---

## 5. 已实现模块：CovaCore 文件职责

| 文件 | 职责 |
|---|---|
| `CovaEnvironment.swift` | 网络出口唯一守卫（仅 `https://covalink.cn`，443，拒 http/私网/3110/尾随点/协议相对/路径穿越）；`makeAPIURL` |
| `CovaAPIError.swift` | 错误模型（传输/超时/取消/非 2xx/解码/未授权/会话变更/凭证读失败等），描述脱敏 |
| `HTTPTransport.swift` | `HTTPTransport` 协议 + `URLSessionTransport`（普通请求 15s/15s） |
| `SSEStreaming.swift` | `SSEStreamingTransport` + `URLSessionSSETransport`（idle 60s / resource 7d，见 TD-33）；`HTTPOneStepPlanPoller` |
| `CovaAPIClient.swift` | 请求构建（守卫 + Bearer 注入）、401→single-flight→重放一次、会话快照绑定（防串号） |
| `AuthSession.swift` | 认证状态机 signed-out/guest/authenticated；single-flight refresh（按 principal+generation+epoch 分桶）；`restoreSession()`（`/api/auth/me`）；登出/换号 |
| `AuthDTOs.swift` | 登录/刷新/登出/me、`AuthUser`/`Entitlements`（token 字段为 `SecretString`，仅 Decodable） |
| `LibraryDTOs.swift` | `TrackDto`/`TrackDetailDto`/`SimilarTrackDto`/`SimilarTrackPageDto`/`PlaylistDto`/taxonomy 等 |
| `OneStepPlanDTOs.swift` | 计划卡（12 态枚举）、参数、歌词；写请求 `OneStepPlanStartRequestDto` |
| `GenerationDTOs.swift` | 生成任务/候选（6 态/3 态） |
| `DownloadDTOs.swift` | checkout 请求/响应、`DownloadItemDto`（签名 URL 脱敏） |
| `CollectionDTOs.swift` | favorites / saved-playlists 请求与响应 |
| `PlayReportDTOs.swift` | 播放上报请求/响应（`source:"app-ios"`，幂等键） |
| `SSEEventDTOs.swift` | SSE 事件类型（thinking/text/plan_card/error/done/run_*/unknown）与载荷 |
| `SSEEventParser.swift` | 增量 SSE 解析（逐字节/CRLF/多行 data/BOM/UTF-8 跨块/行-事件长度上限/坏事件计数） |
| `OneStepStream.swift` | 降级状态机（10s 无首事件 / 30s 静默 / 3 坏事件 / done 前 EOF → 5s 轮询，不并发）+ 有界取消（D16） |
| `Idempotency.swift` | `IdempotencyKey`（校验）+ `IdempotentRequestToken`（operation↔key 绑定） |
| `SecureStore.swift` | `SecretString`（脱敏、非 Encodable、非 Hashable）+ `SecureStore` 协议 + 内存实现 |
| `KeychainStore.swift` | Keychain 生产实现（`ThisDeviceOnly`、`<principalId>.<kind>` 绑定、可注入 SecItem 操作层） |
| `PrincipalID.swift` / `OwnerIdentifier.swift` | owner 标识与校验（空/超长/控制字符拒绝） |
| `OwnerScopedStorage.swift` | owner 绑定 Codable JSON 持久化（hex 命名空间、防路径逃逸） |
| `SessionGeneration.swift` / `SessionLifecycle.swift` | 会话 generation（actor）与登出/换号 best-effort 全量清理 |
| `ActiveOwnerStore.swift` | 冷启动 owner 指针（0600 权限，非敏感） |
| `CovaClock.swift` | 可注入时钟（虚拟时钟用于确定性测试） |

测试：`Packages/CovaCore/Tests/CovaCoreTests/`（372 个测试，基线 `CORE_MIN=372`），fixtures 分
「真实回灌 / 契约目标 / 合成」三类，见 `Fixtures/README.md`。**fixture 严禁含真实凭证/签名 URL**。

---

## 6. 锁定决策与契约坐标

- 锁定决策：`docs/decisions.md` **D1–D16**。D1（iOS 26 + SwiftUI/Swift Concurrency）与
  D12（v1.0 零购买入口）已获用户批准；**D16 = 取消有界语义**（见 §8）。
- 后端契约：`docs/api-contracts.md`（端点 + 字段 + §5 安全规格）。
- 后端缺口：`docs/NEEDS.md` **NEEDS 1–13**（AUTH-LOGIN-TOKENS / PLAY-SOURCE-MOBILE /
  ENTITLEMENTS / ACCOUNT-DELETE 为硬阻塞；SSE payload schema 与多处投影不一致为已登记非阻塞项）。
  **客户端不得自行改后端**，发现缺口一律登记。

---

## 7. 技术债清单（TD）

完整条目与上下文在 `docs/log/20260917.md`；下表为汇总，按截止分组。

**G3 内（近期）**
- TD-1：**已关闭**（G3-e 环 4）。CovaPlayer 有了自己的 iOS 模拟器测试步（8/10）与
  行覆盖率步（9/10，阈值 80%，实测 93.75%）。关键教训：`xccov` 会把本地 SwiftPM 包目标
  **折叠进测试 target**（实测 `CovaPlayer 0.00% (0/0)`、报告 0 行点名 `Sources`），
  且该现象**依赖预热态** —— 干净 clone 上直接 fail-closed 变红。口径因此改为
  「第 8 步的 `Coverage.profdata` + `llvm-cov` lcov」，并在 6 个独立起点（冷 clone /
  含空格路径 / 删派生数据 / 换设备 / 预热重跑）上逐字复现同一数字才算数。
- TD-11：**已关闭**（基线文件改为**键名白名单解析**，不再 `.` source；实测 8 种投毒形态
  —— 覆写 `CORE_COVERAGE_MIN`/`IOS_ONLY_MODULES`/`REQUIRED_DEPLOYMENT_TARGET`、重复键、
  内联注释、负数、`$(...)`、`export` —— 全部拒跑）。
- TD-38：播放器层**禁 UI 判据**已由黑名单形态改为**白名单形态**（`944ba98`）：非测试
  target 只允许 `Foundation / AVFoundation / CovaCore / MediaPlayer`（实测从 import 全集
  扫出，刻意不塞未使用模块，故删任一项必红），测试 target 再加 `XCTest`；三层判据
  均纳入测试 target 的扫描域与 objdir；dylib 层 UIKit 豁免**收窄为「UIKit 且 weak」**
  （实测合法二进制是 weak UIKit，一旦直接引用即变强依赖 → 红）。黑名单 15 项保留为
  附加防线。**代价（协调者已裁决接受）**：将来播放器要 import `os`/`Dispatch`/`CoreMedia`
  等必须显式改清单 —— 这正是白名单的意义，不得为省事预先塞宽。
- TD-41：禁 UI 白名单**不拦反射/`dlopen` 取 UI 类**（已写进脚本注释）。本仓门禁的威胁模型
  是「防无意回归与锁定决策失守」，不防蓄意绕过；M1 若引入任何动态加载需人工复核。
- TD-39：`AdvanceOutcome`/`PlayerError` 结果粒度不足：环 4 的 F-4（终态应回 `.stopped`）、
  F-5（装载在途时 seek 应专属拒绝码）只能复用既有 case，因为新增 case 会打破
  `NowPlayingController` 的穷尽 switch。M1 接 UI 时一并复核更细粒度的结果类型。
- TD-40：私有音频并发合流改用无结构 `Task`（为了在 actor 重入前先把登记表填上），
  **取消传播路径未经证明**；M1 需复核「上层取消是否真能终止合流中的下载」。
- TD-10：源集合适配域过宽——`Sources/CovaCore/` 下若出现名为 `Tests` 的子目录会被误红。
- TD-11：`test-count-baseline.env` 注释与实现口径需对齐（只比较 `passed`）。
- TD-13：`similar[]` 投影稳定性无保证（后端双发范围可变）。
- TD-14：响应/投影 DTO 刻意无 `public init`（只由解码产出）。
- TD-17：需登录/写端点 DTO 目前为「契约目标形态」，NEEDS 解锁后才能真实回灌。

**M1（登录联调前后）**
- TD-18：真实 `SecItem*` / `ThisDeviceOnly` 未在真机冒烟。
- TD-19：幂等键「重试复用同键」是类型契约，跨重试持有仍是调用方约定。
- TD-20：owner JSON 同 owner 并发写无互斥。
- TD-26：5xx/429 自动重试与退避未实现。
- TD-27：`restoreSession` 传输失败时状态停在 signedOut，重试/降级策略待定。
- TD-28：`activeOwner` 双源（AuthSession 持久化 vs SessionLifecycle 内存）。
- TD-30：用户显式选 guest 后 owner 指针未回滚，下次冷启动可能自动恢复旧账号。

**M2**
- TD-31：计划卡 12 态中文文案与 `run_*` UI 映射（设计闸门后）。
- TD-32：降级轮询失败当前无限 5s 重试，需上限/退避策略。
- TD-33：SSE `idleTimeout=60s` / `resourceTimeout=7d` 为客户端推断，需真机确认服务端心跳 < 60s。

**G4 前**
- TD-21：TSAN 报 `IdempotencyKeyGenerator` 一处 access race，证据指向标准库 RNG 误报，需复核。
- TD-29：`AuthSession.setBeforeSessionActivation` 测试专用注入点。
- TD-34：`OneStepStream` 测试专用注入点 4 个：`setBeforeSSETaskStart`/`setBeforePollTaskStart`/
  `setAfterSSETaskEnd`/`setAfterPollTaskEnd`（生产恒 nil）。G4 前评估移除或收敛为 `@testable`-only。
- TD-35：测试等待原语（`waitFor`/`waitUntilOpened`/`advanceToNextDeadline` 等）全部无超时上界，
  回归将以「挂起」而非「断言红」呈现。G4 前评估加上界耗尽即 `XCTFail`，或门禁启用
  `-test-timeouts-enabled`（需改 `check.sh`）。
- TD-36：冗余防御层——轮询任务内层取消守卫（`receivePoll`/`receivePollFailure` 前，由
  `guard !isFinished` 兜底）与 `performPoll` 的 `pollTask?.cancel()`（不可达）。G4 前决定删除
  或登记为防御层惯例。
- TD-37：`GatedNowClock` 连装 `armNowGate`（未放行再装第二次）会覆写 `nowGate` → continuation
  泄漏。测试基建脆弱点，G4 前加断言或改多槽位。

**持续 / 工具链**
- TD-2：CovaCore 若真需要条件编译，必须先登记 NEEDS/decisions（禁止静默放宽）。
- TD-3：测试基线可被「删测试 + 同步下调基线」绕过，依赖版本递增人工审查。
- TD-4：`frameworks:` 令牌整体禁止；G3 若需显式链接系统框架须登记放行。
- TD-5：覆盖率仅行覆盖，未含函数/分支。
- TD-6：字面令牌判定会因注释误报（刻意的 fail-closed）。
- TD-7：门禁依赖 `.SwiftFileList`/`dump-package`/`xcactivitylog` 的工具契约，格式变化时「读不到即非零」。
- TD-8：CovaCore 内符号链接整类禁止（含指向仓内合法文件）。
- TD-9：每条断言必须有「合法工程对照不得误红」用例。
- TD-12：封闭枚举遇契约外取值会整包解码失败（M2 若需前向兼容须登记）。
- TD-15/16/22/23/24/25：**已关闭**（similarTo 判别式与反向守卫、owner C1 校验、敏感字段脱敏、
  幂等键绑定、刷新失败分类）。

---

## 8. 已知坑与硬约束（血泪经验）

**硬边界（`AGENTS.md`，违反即返工）**
1. 只改本仓；不碰生产 env/DB/服务器；不碰相邻仓。
2. 网络出口唯一 `https://covalink.cn`；开发期只允许**公开只读 GET**，写操作/扣费端点**未经用户单次批准不得调用**。
3. token 只进 Keychain（`ThisDeviceOnly`）；token/密码/签名 URL **禁写日志、禁入持久化**；密钥不进 git。
4. 零第三方依赖（白名单当前为空）；新增依赖须用户批准并登记 decisions。
5. 扣费/写操作必带幂等键。
6. 双 Demo 终态硬规则（两候选双 settled；私有音频先 Bearer 下载校验非空再 `file://`）。
7. 后端缺口写 `NEEDS.md`，不得自己改后端。
8. **G1/G2 未验收不写 UI**。
9. App Store 合规：v1.0 无任何购买/充值入口，仅展示余额。

**CovaCore 平台中立**
- 禁止任何字面 `#if` / `#elseif` / `#else` / `#endif`（注释里也不行，整目录扫描）。
- 禁止 `UIKit`/`SwiftUI`/`AVFoundation`/`AVKit`/`AVFAudio`/`RealityKit` 等 iOS-only import。
- 覆盖率在 macOS 主机产物上测量，靠上述不变量保证「被测源码与 iOS 同一份」。

**协作式取消的真相（D16）**
- Swift 协作式取消无法把「`Task.isCancelled` 检查 + `await` 发起传输」原子化，绝对「cancel 返回后
  零传输调用」不可达。**D16 确立有界语义**：cancel 后不再调度新周期；已授权传输必须被立即取消且
  结果不投递；允许一次被取消的窗口调用；**该窗口不得用于写/扣费**；测试必须确定性（禁止竞态断言）。
- 写/扣费路径若将来需要严格零调用，必须在其之上另加同步门。

**门禁自身很脆**
- 改 `Scripts/check.sh` 时先想清楚是否引入误红/漏检；门禁的威胁模型防的是**无意回归**，
  不防「蓄意改门禁文件」。
- 测试里用 `Task{}` 后立即 `cancel()` 再断言「必然取消/零调用」是**竞态断言**，禁止（见 D16⑤）。
  确定性驱动用已注入的 `AsyncGate` / 测试钩子，而非 `Task.yield()`/时间推进启发式。

**版本与提交**
- 每次 commit 递增 `project.yml` 的 `CFBundleShortVersionString`/`CFBundleVersion`（小迭代 +0.0.1 / 大迭代 +0.1）。
- 生成物（`*.xcodeproj`/`.build`/`DerivedData`）不入 git。
- 凭证据实：截至 `300d985` 版本 `0.2.21/32`；历史 0.1.0/1 → …（演进见 `project.yml` 注释）。

---

## 9. 当前未完成工作与续跑指引

### ⚠️ 2026-09-21 环 4 现场（协调者停放，覆盖下方 09-21 早先条目）
- **已入库且已验证**：`5b86671` 环 4①（状态机与集次守卫：C1/P1–P5/M10/M11）+
  `8031fec` 门禁修复（G-9…G-13）。门禁实例在**干净 clone** 上实测 `check.sh` **EXIT=0**：
  CovaTests 2、CovaCore 372（95.28%）、CovaPlayer 284（0 失败）、
  **CovaPlayer 行覆盖 2304/2476 = 93.05%，逐文件点名 15/15**（第 9 步口径已从 xccov
  改为 `Coverage.profdata` + `llvm-cov` lcov，TD-1 至此**真正清偿**——不再依赖预热态）。
  13 项绕过负例全红；0–7 步判据零放宽。`PLAYER_MIN` 由协调者抬到实测终值 **284**。
- **工作树里有 16 个文件的「环 4②（私有音频管线）」半成品，未提交且实测是坏的**：
  协调者亲自跑 `cd Packages/CovaPlayer && xcodebuild -scheme CovaPlayer
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:CovaPlayerTests test`
  → **Executed 323 tests, with 25 failures**。红点集中在 `PrivateAudioTransportTests`
  （18 红），症状是桩侧「音频下载响应状态码 0」（`PrivateAudioTransport.swift:414`、
  `PrivateAudioTransportTests.swift:705`）。**禁止直接 commit 这份半成品**；
  接手者应从 `git diff` 中甄别可用部分，或 `git checkout -- Packages/CovaPlayer` 回到
  `8031fec` 重做第 ② 组。
- **失败模式已重复三次**：开发实例在 150 轮上限处被截断，且倾向一次吃下过多缺陷。
  续跑纪律：**每个实例只派 1 组（≤6 条 finding），且要求它先 commit 再做下一组**。
- 环 3 第 2 轮复审实例正在 `/tmp` 克隆里攻击 `5b86671` + `8031fec`（上轮 13 条 findings
  作待攻击清单）。**G3-e 仍未验收**：需一轮零 Critical / 零 Major 才能进环 5。

### G3-e CovaPlayer 在途（2026-09-21 协调者停放，**未验收**）
- **环 1+环 2 已入库**：`8b9d0c1`（15 源文件 / 253 条测试）。协调者独立复跑
  `./Scripts/check.sh` = **EXIT=0（已扩到十步）**：CovaTests 2、CovaCore 372（95.28%）、
  CovaPlayerTests 253 passed / 0 failed、**CovaPlayer 行覆盖 2207/2407 = 91.69%**
  （TD-1 清偿：走 xccov 逐文件行数据，读不到即 fail-closed，阈值只允许抬高）。
  推导与状态规则裁决表在 `docs/log/20260921.md`。
- **环 3 隔离评审已跑，结论是「不通过」**：评审实例自建的 8 条对抗探针全失败 → 6 个缺陷：
  P1/P1b/P1c 失败后状态谎报 `.playing`（引擎未装载任何条目）、P2 过期装载回写竞态、
  P3 `teardown` 后队列变更复活播放器、P4 迟到的重复 `ended` 多跳一首。
  证据：`.build/check/test-player-ios.log` + `Packages/CovaPlayer/Tests/CovaPlayerTests/ZZReviewProbeTests.swift`。
- **环 4 修复实例在跑**（本手册更新时未回传）。
- ⚠️ **接手第一件必做的事**：`Packages/CovaPlayer/Tests/CovaPlayerTests/ZZReviewProbeTests.swift`
  是评审的临时取证物，**未跟踪、不得入 git**；它会被 SwiftPM 编进测试，导致门禁
  「261 跑 8 失败」的**误红**。先确认环 4 已把等价断言转成永久测试，再删除该文件，然后跑门禁。
- ⚠️ 版本递增失守已前滚修正：`abbd3f2` 的提交信息声称递增到 `0.2.28/39`，但 pathspec
  形式的 `git commit -- <path>` **不纳入未跟踪文件**，那次提交实际没改 `project.yml`
  （与 `8b9d0c1` 共用 `0.2.27/38`）。本 commit 补到 `0.2.28/39`。
  同一原因也让 18 份 G2 规格一度裸在工作树，已由 `abbd3f2` 补提交（现 `design/screens/` 22 个跟踪文件）。
- 剩余路径：环 4 修完 → **环 3 复审**（又一个全新隔离实例，带上轮 findings 作待攻击弱点清单，
  判据仍是零 Critical / 零 Major）→ 环 5 落证（勾 `docs/PLAN.md` G3 项、更新本手册
  §0/§3（8→10 步 + 播放器无 UI 不变量）/§7（TD-1 清偿 + 新 TD）、登记设计实例上报的
  7 项 NEEDS 候选、版本递增）→ 模拟器刷终态产物再截图。
- 外部阻塞不变：G1 Figma 验收（UI 禁令解除条件）、G2 画板需 Figma MCP（CLI 会话 0 工具）、
  NEEDS-1 / NEEDS-2 / NEEDS-4。

### G3-d 已验收（2026-09-20 落证）
- 收尾 commit：`f39cfa9`（协调器测试套件确定性化：信号式等待 + 定时器注册推进原语
  `advanceToNextDeadline` + TD-34 结束注入点 `setAfterSSETaskEnd`/`setAfterPollTaskEnd`）。
- 第十轮隔离评审（全新实例，独立取证）：**100%，零 Critical/Major**。关键证据：
  `-test-iterations 5000` = 130000 执行 **0 失败**；`check.sh` EXIT=0；变异自证 6 处 5 杀
  1 存活（存活者为已证实冗余防御层，登记 TD-36）；基线 372 持平。
- 完整记录：`docs/log/20260918.md`（环 1 推导 §一–§七、环 2 验证 §九、评审 §十二、落证 §十三）。
- **`git stash@{0}` 是已被超越的旧尝试**（message：「G3-d 九审：协调器测试确定性化（任务被取消，
  未验证）」）。f39cfa9 的实现独立重写且已验收，stash 无保留价值，建议 `git stash drop`；
  处置权在用户。
- flake 复现命令（留档，验证回归时用）：

```bash
cd Packages/CovaCore && xcodebuild -scheme CovaCore -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CovaCoreTests/OneStepStreamCoordinatorTests \
  -test-iterations 5000 test
```

### G1 Figma 方向稿已产出（2026-09-20，待用户验收）

- 文件：`Cova iOS — G1 方向稿`，fileKey `da8OZDpP3vvLgY1sUa3kqu`，
  <https://www.figma.com/design/da8OZDpP3vvLgY1sUa3kqu>。文件属 Figma 账号
  `hy598934321@gmail.com` 名下，用其他账号打开会报无权限。
- 变量基建：`Cova Tokens` 变量集（`VariableCollectionId:1:4`，Light `1:2` / Dark `1:3`
  双模式）已建——24 色 + 4 圆角 + 7 间距，按 `design/tokens.json` 录入；全部画板颜色绑
  变量，切模式即换肤。
- 画板 4 张（iPhone 393pt，页面 `G1 方向稿`）：`01 · 首页 Home`、`02 · 播放页 Player`
  （封面取色压暗背景 + 波形进度 + 队列面板）、`03 · 曲库 Library`（级联筛选 + 已选胶囊 +
  TrackRow + MiniPlayer）、`04 · 曲库 Library · Dark`（03 克隆帧切 Dark 模式，验证双主题
  token 生效）。
- **替代与近似（验收时知情）**：字体以 **Inter 代替 SF Pro**（本 Figma 环境所有 SF 系字体
  变量字重零宽渲染失败；真机实现仍用系统 SF Pro）；Liquid Glass 以透明度近似
  （MiniPlayer 72–85% 白），真机走系统 material。
- **状态：待用户验收。** 验收通过 → G2 补全约 18 屏全量（含空/加载/错误/Reduce Motion
  变体）；未过前 UI 编码禁令不变。
- Figma MCP 工具坑（下一代理必读）：
  - `use_figma` 脚本报错会**整体回滚**本轮已建节点（事务性），先小步验证再扩量。
  - 自动布局子框的 `layoutSizingVertical` 默认 `FIXED` 且初值 100 → 每个子框必须显式设
    `HUG`/`FILL`，否则渲染被裁到 100pt 高。
  - `appendChild` 后再读 `.children` 可能拿到陈旧引用，先存变量再 append。
  - `fills` 数组元素只读：paint 的 opacity 要在赋值前设好。

---

## 10. 下一步路线

1. ~~G3-d 收尾~~（2026-09-20 已验收，见 §9）。
2. **G3-e：CovaPlayer**（D4/D7）—— 当前唯一未阻塞任务——队列、循环三态、±15s、MPRemoteCommandCenter 锁屏控制、
   播放上报去重、私有音频先下载到沙盒校验非空再 `file://`。注意 TD-1（覆盖率门槛需 iOS destination
   方案）与平台中立性（`AVAudioSession` 是 iOS-only，需与 CovaCore 的 macOS 覆盖率口径分开处理）。
3. **G3 完成判据**：`check.sh` 全绿 + 核心层 ≥80% 覆盖率。
4. **G1/G2：Figma 方向稿/完整设计**。G1 方向稿已产出待用户验收（§9）；验收后 G2 按
   `design/screens/inventory.md` 补全约 18 屏（含空/加载/错误/Reduce Motion 变体）。
   产出规格：`design/tokens.json`、`design/screens/01-home|02-player|03-library.md`、
   `design/components.md`。**验收前不得写 UI**。
5. **M1**：发现与播放闭环（先等 NEEDS-1/2/3 解锁登录与播放上报）。
6. **M2/M3/G4**：见 `docs/PLAN.md` 与 `docs/release-runbook.md`。

**可并行的未阻塞工作**：G3 核心层（不涉 UI）。**被阻塞的**：任何 UI（等 G1/G2）、
真实登录联调（等 NEEDS-1）、播放上报（等 NEEDS-2）、账号删除（等 NEEDS-4，G4 前必需）。

---

## 11. 命令速查

```bash
# 门禁（唯一验收口径）
./Scripts/check.sh

# 生成/重建工程
xcodegen generate

# 仅核心层测试（快，macOS）
swift test --package-path Packages/CovaCore --filter CovaAPIClientTests

# iOS 模拟器测试（门禁同款 destination）
xcodebuild -scheme CovaCore -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# 高倍重复（查 flake）
xcodebuild -scheme CovaCore -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CovaCoreTests/某套件 -test-iterations 100 test

# 覆盖率（门禁内部用；手动采样）
swift test --package-path Packages/CovaCore --enable-code-coverage

# 只读契约核对（允许：公开 GET，无凭证）
curl -sS 'https://covalink.cn/api/tracks?page=1'

# 查看未验证的 stash
git stash list && git stash show -p stash@{0}
```

---

## 12. 交接检查清单

- [ ] 读完 `AGENTS.md`、`docs/EXECUTION-PROMPT.md`、`docs/PLAN.md`、`docs/decisions.md`（含 D16）。
- [ ] 本机 `xcodebuild -version` 与 `xcodegen --version` 正常，Xcode 许可已接受。
- [ ] `./Scripts/check.sh` 能跑通（首次较慢）。
- [ ] 明白 G1/G2 未验收前不写 UI（G1 方向稿已产出待验收，fileKey 见 §9）。
- [ ] 明白「隔离评审」规则与五环流程，不自评自过。
- [ ] 知道当前在途任务（G3-e CovaPlayer），以及 `stash@{0}` 已被超越建议处置。
- [ ] 知道所有后端缺口在 `docs/NEEDS.md`，不得自行改后端。
- [ ] 知道技术债在 `docs/log/20260917.md`，接手时优先清偿与当前任务相关的条目。

---

*本手册由协调者编写（初版 2026-09-18；2026-09-20 随 G3-d 落证与 G1 Figma 方向稿产出更新）。
若手册与仓库实际不符，以 `git log`/`docs/log/`/`check.sh` 实际输出为准，并顺手更新本手册。*

---

## 13. 环 4 现场快照（2026-09-21 协调者，供 `/goal resume` 接手）

**已入库**：`5b86671` 状态机守卫①（C1/P1–P5/M10/M11）· `8031fec` 门禁 G-9…G-13 ·
`69f894c` 停放 + `PLAYER_MIN=284` · `eaf3d75` 私有音频 C2/M5/M6/M8/m12–m14 ·
`20acd38` 门禁 F-9/F-10（禁 UI 三层判据改由单一词源 `PLAYER_UI_MODULES` 派生 +
`__llvm_covmap` 真分母无条件生效；带空格路径干净 clone EXIT=0、13 条端到端负例全红、
旧/新 L1 命中集逐字相同）。

**协调者对 `20acd38` 五项请示的裁决**：① `.unsafeFlags(` 禁令保留（`-wmo` 会打掉
per-file 覆盖率归因）；② **UIKit 在 `otool -L` 层整名容忍 —— 接受并登记为已知边界**
（合法测试二进制本身带 weak UIKit，由 AVFoundation overlay 拖入，weak 不承载信号；
UIKit 由 L1 + 符号层承担）→ 新 TD；③ F-10 夹具只能以大小写异名复现（完全同名在
xcodebuild 下编译期硬错）—— 采纳；④ 播放器**测试**里 import SwiftUI 判红 —— 不豁免
（G1/G2 未验收期间 UI 禁令是绝对的）；⑤ 并行实例在途改动由协调者统一重跑门禁。

**仍在跑（未提交）**：状态机组 F-1…F-8 与私有音频收尾组（为 `eaf3d75` 补永久测试 +
M7 并发去重 + M4 登出清盘接线 + M3 生产音频会话注册）。

**接手顺序（不可跳）**：收两组 commit → 整轮 `./Scripts/check.sh` 重跑并把 `PLAYER_MIN`
抬到终值 → **第 3 轮隔离复审**（判据：零 Critical 且零 Major；上轮 13 类 + 本轮 F-1…F-13
作待攻击弱点清单；探针必须写在独立克隆，禁止落在 `Packages/CovaPlayer/Tests` —— 会污染门禁）
→ 环 5 落证（勾 `docs/PLAN.md`、更新本手册 §0/§3（十步）/§7（TD-1 已清偿 + 新 TD）、
登记 NEEDS 候选、版本递增、刷模拟器出图）。

**编排教训（已固化为本仓纪律）**：开发实例有 150 轮上限，**一个实例只派一组
（≤8 条 finding）且必须先 commit 再继续**；并行实例必须各用独立 `-derivedDataPath`；
门禁类工作在 `/tmp` 克隆里验证。本轮已因此回退过一次 16 文件的半程重构。

### 环 4 已收口（2026-09-21，协调者实测）
- 三组修复全部入库：`cc81e29` 状态机组 F-1…F-8（9 条永久测试 + 5/5 变异全杀 +
  18000 次迭代 0 失败；三条续体收敛为单一守卫 `continuationIsCurrent`）、
  `6c924ba` 私有音频收尾组（38 条永久测试 + 12 处变异自证 + M7 并发合流 / M4·F-13
  登出清盘 / M3 生产音频会话注册）、`20acd38`+`8031fec` 门禁两批。
- **协调者亲跑整轮 `./Scripts/check.sh`（含全部环 4 修复的 HEAD）= EXIT=0**：
  CovaTests 2、CovaCore 372（95.28%）、**CovaPlayerTests 331 passed / 0 failed**、
  **CovaPlayer 行覆盖 2744/2927 = 93.75%（15/15 源文件，.o ↔ OutputFileMap ↔
  `__llvm_covmap` 三方无条件交叉）** → `PLAYER_MIN` 已收到终值 **331**（`7d2f200`）。
- 协调者裁决：F-6「成功装载即归零失败连击」**判为非缺陷**（design §9 的「连续」数连续
  失败曲目，装载成功≠播放成功，改了会让三次失败上限永不可达）；F-4/F-5 复用既有
  `PlayerError`/`AdvanceOutcome` case 而非新增（新增会打破 `NowPlayingController`
  穷尽 switch）→ 接受，登记 TD 待 M1 复核更细粒度结果类型。
- 后端缺口 **NEEDS 14–22** 已入册（`536b0f8`）。
- **第 3 轮复审结论（已回，两路）**：门禁面 0 Critical / **2 Major**（禁 UI 是黑名单形态：
  `import WebKit`+`WKWebView` 三层全绿；`import UIKit` 只放播放器**测试** target 也三层全绿）
  → 已由 `944ba98` **换成白名单形态**（允许清单从实际 import 全集扫出、三层判据都纳入测试
  target、UIKit 豁免收窄为「UIKit 且 weak」，37 条必红面零漏检，TD-38 关闭、新 TD-41）；
  语义面实例撞自身轮次上限未交报告 → 拆成两路窄实例重派。
- **第 4 轮复审结论（已回，两路，存档于 `docs/review-g3e-round4.md`）**：状态机面
  0 Critical / **1 Major**（F-A：`.repeated` 守卫把「无播放意图」当「引擎没装载」→ 单曲
  队列暂停中越界落进**伪失败终态**）+ 4 Minor，并给出 **165,200 次执行 0 失败** 的零 flake
  证据、约 70 处 `await` 续体点穷举；私有音频与生命周期面 0 Critical / **8 Major** + 6 Minor
  （含我此前错误延后的 M9/m16-m17，复审证实仍是 Major）。
- **已入库的修复批次**：`13aa6af` 第 5 批（F-A/F-B/F-C：两条腿分离、失效面收敛、集次在途
  标记；全量 341 / 0 失败，115,000 次迭代 0 失败，变异 5/5 全杀）· `378c1f2` 第 6 批组 1
  （MAJ-1/3/4 取消与作废语义）· `e683dff` 第 6 批组 2（MAJ-2/8、min-2/3/5 清盘义务与出口判定）。
- **在途**：第 7 批 = 第 6 批组 3（MAJ-5 观测者注册不得依赖会话激活成功、MAJ-6 锁屏命令桥
  禁止无超时 `DispatchSemaphore.wait`、MAJ-7 门面/适配器 `deinit` 退系统面、min-1/4/6）。
  第 6 批实例在刚开始本组时被轮次上限截断，工作树留有**未验证草稿**（约 133 行）；第 7 批
  的任务是把它当草案验证（先写永久测试证明其闭合，再决定保留/纠正），**不得**直接提交，
  也**不得**无脑丢弃。
- **基线现状**：`PLAYER_MIN=331` 落后于实测（第 5 批后为 341，第 6/7 批还会涨）。协调者刻意
  不在批次进行中抬基线（避免量一棵移动中的树），**收尾时必须**：整轮 `check.sh` EXIT=0
  复核 → 把 `PLAYER_MIN` 抬到当时终值 → 再派第 5 轮隔离复审。
