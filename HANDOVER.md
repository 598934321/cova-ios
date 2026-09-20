# 开发交接手册 — Cova iOS 原生客户端

> 面向接手本仓的开发者/代理。先读本手册，再读 `AGENTS.md`、`docs/EXECUTION-PROMPT.md`
> （编排协议）、`docs/PLAN.md`（总计划）、`docs/decisions.md`（锁定决策）。
> 本手册记录**截至 2026-09-20 的真实状态**，不粉饰未完成项。

---

## 0. 一分钟现状速览

| 项 | 值 |
|---|---|
| 当前锚点 | HEAD = 本 commit（G3-d 落证，父提交 `f39cfa9` = 代码锚点），工作树干净（另有 1 个 stash，见 §9） |
| 版本 | `CFBundleShortVersionString 0.2.24` / `CFBundleVersion 35`（`project.yml`） |
| 阶段 | G0 已完成并落证；G3（核心层）进行中：**G3-a/G3-b/G3-c/G3-d 已验收**（G3-d 于第十轮隔离评审 100% 通过），剩 **G3-e（CovaPlayer）未开始**；**G1 Figma 方向稿已产出待用户验收**（§9） |
| 门禁 | `Scripts/check.sh` EXIT=0；CovaCore 372 个测试、行覆盖率 95.28%；协调器套件 5000 迭代 ×26 用例 = 130000 执行 **0 flake** |
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
│   └── test-count-baseline.env   # 测试数量下限（APP_MIN=2 / CORE_MIN=372）
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

八步及其含义：

| 步骤 | 内容 |
|---|---|
| 0/8 | 预热模拟器 |
| 1/8 | `xcodegen generate` 重新生成工程 |
| 2/8 | 工程结构 / 语言模式 / 无远程包·框架·二进制制品 / 零第三方依赖 |
| 3/8 | `swift package dump-package` 依赖图 + **CovaCore 平台中立性**（整目录禁止字面 `#if`、禁止 iOS-only import） |
| 4/8 | 有效构建设置（Debug/Release × simulator/device）+ clean build + **从实际编译日志断言 `-swift-version 6`** + 产物保真（bundle id / minOS / `UIBackgroundModes`） |
| 5/8 | App 工程测试（CovaTests，iOS 模拟器） |
| 6/8 | 核心层包测试（CovaCoreTests，iOS 模拟器），只认 xcresult 的 `passed`，且 `failed==0` |
| 7/8 | 核心层行覆盖率（SwiftPM 插桩 + `llvm-cov`，阈值 80%）+ 编译集合与源集合双向一致 |

**门禁设计要点（改动前必读）**：

- 只允许追加断言，不允许为了让门禁变绿而放宽；测试数量下限在 `Scripts/test-count-baseline.env`，
  新增测试要同步抬高基线（随 commit 进入版本递增与人工审查）。
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
- TD-1：CovaPlayer 无覆盖率门槛（宿主测量无法代表 iOS-only 逻辑）→ G3-e 处理。
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
