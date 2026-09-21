# 环 3 · 第 4 轮隔离复审结论存档（G3-e）

> 两个全新隔离实例，各自在只读克隆 + 独立 derivedData 里取证，不采信开发方日志与
> commit message。本文件由协调者逐条转录，**作为环 4 后续批次的唯一待修清单来源**，
> 避免评审结论只存在于会话上下文。判据不变：一轮零 Critical 且零 Major 才算验收。

## A. 状态机与播放上报面 —— 0 Critical / 1 Major / 4 Minor

高倍重复 **165,200 次执行 0 失败**（400×143、1200×90、800 轮竞态搜捕、112 步不变量扫描、
120 步上报账目扫描）⇒ 本仓「零 flake」判据成立。约 70 处 `await` 续体点全部穷举分类，
未发现第四处裸写状态的宣称类续体点。

| 编号 | 级别 | 现象 | 证据位置 | 处置（第 6 批） |
|---|---|---|---|---|
| F-A | **Major** | `.repeated` 守卫的 (c) 腿把「用户暂无播放意图」当成「引擎里没装载」→ 单曲队列 + `.all` + 暂停中按 ⏭/⏮ 落进**伪失败终态**：`state=.stopped`、`isFailureTerminal=true`、而 `failureStreak=0`、`lastFailure=nil`、引擎其实装着该项；位置被抹成 0、引擎账本清空（下次 `resume()` 多余重载）。对照组：三曲队列同动作给 `.advanced`+`.playing` 不进终态 ⇒ 判据过宽。既有 90 条协调器用例无一覆盖「paused/stopped × 单曲 × `.all`」 | `PlaybackCoordinator.swift:759-764` → `:826-836` → `:1019`；探针 `testP1e`/`testP1c`/`testP1f`/`testP1d`，对照 `testP1g`/`testP1b`。违反 design §9（终态=连续 3 次失败）、§4/§6（越界应保持），并与 `testStoppedThenUserNextDoesNotRevivePlayback` 自相矛盾。**修法**：(b) 引擎归属与 (c) 播放意图的收敛结果必须分离 |
| F-B | Minor | `teardown()` 之后快照仍携带失败账（`isFailureTerminal=true`/`lastFailure`/`streak=3`），且 `PlaybackSnapshot` 不暴露 `tornDown` → UI 无法区分「空闲待播」与「播放器已永久释放」 | `PlaybackCoordinator.swift:718-731`、`:1147-1156`；探针 `testP17`。违反 D8 失效面一致收敛 |
| F-C | Minor | 提交在途 + 回前台补发重叠 → 同一次实际播放**提交两次**（同键）。键层面未破（`idempotentReplay` 有测试），破的是「一次播放一次写请求」的写放大口径 | `CovaPlayer.swift:232-234` → `PlayReportCoordinator.swift:266-283`（`retryPending` 只看 `!submitted`）+ `deliver:303-336` 无在途标记；探针 `testP31`/`testP3`。既有 `testForegroundBackgroundTransitionNeverReportsTwice` 只覆盖「上次已完成」形态 |
| F-D | Minor（**不判缺陷**） | 队列变更入口在跨 actor hop 之后缺 `tornDown` 复检（`replaceQueue:341`、`removeItem:390`、`bindSession:321-327`）。3 组并发搜捕共 800 轮 0 违例，按 D16⑤ 不判缺陷，仅登记加固 | 同上 |
| F-E | Minor（**不判缺陷**） | 宣称类尾链缺意图/账本复检（`resume():535-539`、`apply(.moved):751`、`handleFailure:872`）。三条门控路径都无法把续体插进无挂起区间，快照均如实 ⇒ 不判缺陷；`advanceOutcome:497` 在 `.paused` 时仍回 `.advanced` 属已登记 TD-39 粒度债 | 同上 |

## B. 私有音频管线与会话/锁屏生命周期 —— 0 Critical / 8 Major / 6 Minor

基线 331 / 0 失败；新增 25 个攻击用例（泄漏 6 / 取消 5 / 生命周期 8 / 出口 6），全量 356
执行、16 条断言失败，集中在 11 个探针。**泄漏面全绿**：20 个承载点 × 5 条反射面
（`String(describing:)`/`String(reflecting:)`/`dump`/递归 `Mirror`/逐子值）= 100 次断言
零命中，含 query 签名与**路径段签名**两种形态；`Sources` 全域 `print/os_log/NSLog/Logger`
0 命中；缓存文件名与 owner 目录名零地址材料；`PlaybackItem`/`PlaybackSnapshot`/
`PrivateAudioRequest` 均非 `Encodable`；`.value` 生产使用点仅 3 处。
**M3 已闭合**：真实 `AVAudioSessionAdapter` + 生产默认装配实测注册 2 个观测者，
`routeChange(oldDeviceUnavailable)` 经真适配器驱动到 `.paused`，teardown 后归零。

| 编号 | 级别 | 现象 | 证据位置 | 处置（第 6 批） |
|---|---|---|---|---|
| MAJ-1 | **Major** | 上层取消**无法**终止合流中的下载：`caller.cancel()` 生效（`isCancelled=true`）但 `committed=1`、`cachedFileCount=1`。无结构 `Task{}` 不继承调用者取消，`await task.value` 不做取消检查 ⇒ **TD-40 由「未证明」变「已证否」** | `PrivateAudioFetcher.swift:134-146`、合流自述 `:99-101`；探针 `testUpperLayerCancellationTerminatesInFlightTransfer` | **已修（第 6 批·组 1）**：取消经 `awaitTransfer` 的 `withTaskCancellationHandler` 传导进合流那一路 + 提交前两处复核。永久测试 `testUpperLayerCancellationTerminatesInFlightTransfer`、`testCancellationByBothMergedCallersDeliversNoPlayableURL`、`testUncooperativeTransportStillCannotDeliverAfterCancellation`；变异 G1-M1a / G1-M1b KILLED。TD-40 据此关闭 |
| MAJ-2 | **Major** | `discardPrivateAudio(owner:)` 的**默认空实现**可被「第二个会写文件的准备器」绕过清盘：登出后文件仍在沙盒。`fetcher.purgeAll()` 支路要求 `as? any PrivateAudioFetching` 成功转换。**修法：删掉默认实现，改为必须实现** | `PrivateAudioFetching.swift:66-68`、`CovaPlayer.swift:130-137`；探针 `testFileWritingPreparerWithoutOverrideIsDiscardedOnLogout`。违反 D8 / api-contracts §5 | **已修（第 6 批·组 2）**：默认空实现删除 → 必须实现（漏覆盖编译不过，实测诊断已记 `docs/log/20260921.md` §13.4）。永久测试 `testSecondFileWritingPreparerIsDiscardedThroughProtocolSurfaceOnLogout`（新原语 `FileWritingPrivateAudioPreparer`：真的落盘、不是 `PrivateAudioFetching`）；变异 G2-M2a KILLED（10 条） |
| MAJ-3 | **Major** | `cancelInFlightTransfers()` 的默认空实现使「清理前作废在途」不成义务：`purgeAll()` 后传输仍跑完并投递 `failure(写入失败 状态码 4)`；盘上干净**只是巧合**（`commitMove` 撞 ENOENT），不是设计保证 | `PrivateAudioTransport.swift:51-58`；探针 `testPurgeIsNotDefeatedByInFlightTransferOnDefaultNoOpTransport`。违反 D16② | **已修（第 6 批·组 1）**：删除 `cancelInFlightTransfers()` 的协议默认空实现 → 必须实现（漏实现编译不过）。永久测试 `testPurgeIsNotDefeatedByInFlightTransferOnRequiredCancellation`、`testInFlightCancellationIsARequiredWitnessNotADefaultNoOp`；变异 G1-M3a KILLED（复现出原话形态「本地写入失败（状态码 4）」） |
| MAJ-4 | **Major** | 被作废的传输抛的是裸 `NSURLError(-999)`，最终被归类成 `missingFile` 且 **计入失败连击**（`countsTowardFailureStreak == true`）→ 登出/断网造成的取消会被 design §9「连续 3 次失败停止」累计。机理：`for try await byte` / `handle.synchronize()` 不在任何 `catch` 内（只有 `bytes(for:)` 段做了归一） | `PrivateAudioTransport.swift:270-283` vs `:229-237`、`PlayerEngine.swift:52`、`PrivateAudioFetcher.swift:201-203`；探针 `testRealTransportCancellationTerminatesInFlightStream` | **已修（第 6 批·组 1）**：读循环 + `synchronize()` 整段纳入 `normalizedStreamError`，准备器侧 `isCancellationShaped` 为第二道；取消一律归一为 `.cancelled` → `countsTowardFailureStreak == false`。永久测试 `testRealTransportCancellationTerminatesInFlightStream`、`testMidStreamNetworkFailureIsNotSilentlyTreatedAsCancellation`、`testStreamErrorNormalizationTable`、`testInvalidatedTransferNeverCountsTowardFailureStreak`；变异 G1-M4a / G1-M4b KILLED |
| MAJ-5 | **Major** | 观测者注册排在 `configureForPlayback()` **之后**，且门面用 `try?` 吞错 → 真机 `setActive(true)` 失败（他人占用/通话中）时注册被跳过，**design §7 再次静默失效**。M3 修复本身有效，但把「注册」挂在了「激活成功」上 | `AudioSessionController.swift:279-286`、`CovaPlayer.swift:160-166`；探针 `testObserverRegistrationDoesNotDependOnSessionActivation`（`observedNotificationCount=0` 而 `isActivated=true`）。另注：既有 `testRealAdapterAsSystemGetsObserversRegisteredByGate` 带 `XCTSkip` 逃生门，正是该形态 | **已修（第 7 批·组 1）**：门层注册提前 + `observingAttached` 独立记账（`stop()` 认两 flag 之或，半途失败也摘净）；门面删 `try?`，新增事实面 `audioSessionActivationFailure` + `isRemoteCommandSurfaceRegistered`，`activated` 只在真激活成功时置位；**`XCTSkip` 逃生门已拆**（改为两条分支都必须成立的确定性断言）。永久测试 `testObserverRegistrationDoesNotDependOnSessionActivation`、`testStopAfterFailedActivationStillDetachesObservers`、`testFacadeDoesNotSwallowAudioSessionActivationFailure`、`testExplicitActivationThrowsButStillRegistersSystemSurface` + 改写 `testRealAdapterAsSystemGetsObserversRegisteredByGate`（只加强）；变异 G3-M5a / M5b / M5c KILLED（8/4/4 条） |
| MAJ-6 | **Major** | 锁屏命令桥用 `DispatchSemaphore` **无超时** `wait()` 把系统线程钉在含下载挂起点的 actor 链上，实测 parked 0.424s（夹具放行前零推进），上界 = `resourceTimeout` **7 天**。（即此前被延后的 M9，复审证实仍 Major） | `MPNowPlayingController.swift:144-158` → `NowPlayingController.swift:189` → `PlaybackCoordinator.resume():517-533` → `loadCurrent` → `prepareSource:910`；`PrivateAudioTransport.swift:103` | **已修（第 7 批·组 2）**：桥接拆成两件事 —— `acceptanceStatus(for:)`（**纯函数、零 hop**：只有同步可判的 seek 合法性参与返回码）+ `deliver(router:command:)`（`Task` 跑完整链，不等结果），且 `.success` 才投递（非法 seek 不再白跑一趟 actor）。命令结果回传系统改由 Now Playing 回显承担（协调器每次状态转移 `publish`），并被测试真的走了一遍。永久测试 `testRemoteCommandAcceptanceIsDecidedWithoutAskingThePlayer`（用**未绑协调器**的 router 打：旧桥接在这里必然回 `.noActionableNowPlayingItem` ⇒ 确定性变红，不必挂死也不必计时器）、`testRemoteCommandDeliveryDoesNotWaitForInFlightLoad`（闸门后的在途装载：返回后仍观测到「投递已发生且那一路没走完」）、`testDeliveredRemoteCommandStillEchoesIntoNowPlaying`（回传腿，靠 `deliver` 的 `onDelivered` 记账点做确定性会合）；变异 G3-M6a（恢复无超时 `semaphore.wait()`）KILLED 13 条 / M6b 6 条 / M6c 4 条。「底层失败不再进返回码」的取舍立 **TD-42**（G4 真机冒烟）。**第 8 批收口**：组 2 的残留实为**编译不过**（在途测试函数体被截断在 `addTeardownBlock {` 中间 + 文件末尾多一个 `}`），已重建；该测试自己写的**竞态断言**（放行闸门后直读 `MPNowPlayingInfoCenter`）经 500 迭代复现为 **10/500 失败**，按上表的 `onDelivered` 接缝改掉后 1000 迭代 73,000 执行 / 0 失败；三处变异（M6a/M6c/min6a）在最终字节上复跑全部 KILLED。明细见 `docs/log/20260921.md` §15。 |
| MAJ-7 | **Major** | 门面 `deinit` 只 `engine.stopAndRelease()`：析构后 `playCommand.isEnabled=true`、Now Playing 仍显示死门面曲名、`playbackState=playing`；`AVAudioSessionAdapter` 无 `deinit`，观测者 token 只在 `stopObserving()` 摘 ⇒ **通知残留（本仓红线）**。`CovaPlayer.swift:17` 的「不留远端 target」自述不实 | `CovaPlayer.swift:261-264`、`AudioSessionController.swift:351-519`；探针 `testDeinitWithoutTeardownRetiresRemoteCommandsAndNowPlaying`。附带：门面本身无泄漏（`testFacadeDeallocationAtEachLifecycleStage` 四阶段全 true） | **已修（第 7 批·组 1）**：三层各补一处 —— 门面 `deinit` 调新增的同步路径 `retireSystemSurfacesSynchronously()`（关命令位 + `removeTarget` 摘净 + 取消在途封面 + 清 `MPNowPlayingInfoCenter` 字典 + `.stopped`）、`MPNowPlayingController.deinit` 兜底、`AVAudioSessionAdapter.deinit` 兜底摘 token，且**自引用强环**（门把 `system` 同时当 `notifier` 与 `routeProbe`）改弱引用打破 —— 否则适配器永不释放，兜底形同虚设。可观测面 `netLiveObserverTokens`（进程内净额）。`CovaPlayer.swift:17` 的自述已兑现并改写成可核对事实。永久测试 `testDeinitWithoutTeardownRetiresRemoteCommandsAndNowPlaying`、`testDeinitRetiresSharedSurfacesEvenWhenControllerOutlivesFacade`（拆掉「门面/控制器互为替身」的空断言面）、`testTeardownThenDeinitIsIdempotentOnSharedSurfaces`、`testAdapterDeinitDetachesObserversWhenStopWasForgotten`、`testExplicitStopObservingThenDeinitKeepsLedgerAtZero`、`testFacadeDeallocationLeavesNoLiveSessionObservers`；变异 G3-M7a（5 条）/ G3-M7a2（10 条）/ G3-M7b（1 条）KILLED |
| MAJ-8 | **Major** | `.publicDirect` 的 https 媒体地址在引擎侧**零出口判定**：`playableURL(for:)` 对 `https://cdn-other.invalid/a.m4a` 返回 `.success`；`assetOrigin` 是**从不被消费的死字段**（全仓仅出现在门面构造与两处断言里） | `AVPlayerEngine.swift:132-145`、`CovaPlayer.swift:21/43/48/68`；探针 `testPublicDirectHTTPSIsJudgedAgainstProductionExit`。违反 AGENTS 硬边界 2 字面口径与 `CovaPlayer.swift:14` 注释承诺 | **已修（第 6 批·组 2）**：`AVPlayerEngine.playableURL(for:egressOrigin:)` 对 `.publicDirect` 过 `isAllowedEgress`（① `isProductionOrigin` ② 与门面出口同源）；`CovaPlayer.init` 的默认引擎改为 `engine ?? AVPlayerEngine(egressOrigin: assetOrigin)` → `assetOrigin` 真的被消费（`CovaTests` 两条断言未动）。永久测试 `testPlayableURL…`（+3 拒绝腿 1 对照腿）、`testEngineEgressJudgementTable`、`testAssetOriginIsConsumedByTheDefaultEngine`；变异 G2-M8a / G2-M8b KILLED |
| min-1 | Minor | 缓存**目录**位仍 0755（文件位已 0600） | `PrivateAudioFetcher.swift:383-390` | **已修（第 7 批·组 1）**：`PrivateAudioPath.directoryMode = 0o700`；`prepareDirectories` 改为根 → owner → 在途逐个「建 + 收紧 + 复核」（`withIntermediateDirectories` 会顺手把上游按默认位建出来），且**已存在的目录就地收紧**（旧 `guard exists == false else { return }` 让这条只对全新安装生效 = 复审实测到的 0755），复核不过即 `writeFailed(EACCES)` fail-closed。永久测试 `testCacheDirectoriesAreOwnerOnlySearchable`、`testPreexistingLooseCacheDirectoriesAreTightenedInPlace`、`testDirectoryModeJudgementHandlesFullStMode`；变异 G3-min1a KILLED（2 条） |
| min-2 | Minor | 同源判定与出口守卫口径不一致：`isProductionOrigin` 放行 `https://covalink.cn:443`，而 `AudioAuthorityMatch.origin(of:)` 把 `covalink.cn` 与 `…:443` 判成两台主机 → **合法重定向被误杀**（NEEDS-15 未解锁前又多一处堵点） | `PrivateAudioTransport.swift:67-73`；探针 `testCanonicalPortMatchesProductionAuthority` | **已修（第 6 批·组 2）**：`origin(of:)` 只折叠规范端口（`CovaEnvironment.apiPort`，不写字面 443）→ 与 `isProductionOrigin` 同口径。永久测试 `testCanonicalPortMatchesProductionAuthority` + `testLandingOnCanonicalPortStillDeliversBytes`；变异 G2-min2a KILLED（7 条）。既有 `testAuthorityMatchDecisionTable` 的 `:443` 断言按新口径改写（只增不断） |
| min-3 | Minor | 同键合流在 `expectedBytes` 不一致时破裂：同一 key 两次带 Bearer 出站，A 已拿到的 24 字节交付被 B 的 48 字节提交换掉（盘上实得 48）。设计注释称有意，但与既有 `testConcurrentSameKeyRequestsTriggerExactlyOneTransfer` 自陈的「两个调用者必须拿到同一份内容」直接冲突 | `PrivateAudioFetcher.swift:112-118`；探针 `testMergedSameKeyRequestsCommitOneConsistentPayload` | **已修（第 6 批·组 2）**：合流交付走 `mergedOutcome` —— 期望与实得不一致回 `.truncated`，不删不覆盖；只有文件真不见了才自己重取。永久测试 `testMergedSameKeyRequestsCommitOneConsistentPayload`；变异 G2-min3a KILLED |
| min-4 | Minor | 跨主机重定向的**凭证外发面在离线夹具上不可观测**（`URLProtocol` 桩不重放跳转链，实测只发出 1 个主机、落地请求无 `Authorization`）⇒ 既未证实也未证伪；且实现里没有 `willPerformHTTPRedirection` 委托，也就**没有任何可剥离 `Authorization` 的位置** | 既有 C2 测试同样自陈此局限 | **离线不可证（第 7 批·组 2）**：登记 **TD-44** 并写进存疑点（`docs/log/20260921.md` §14.4），**未写任何假断言**。核过的三件事：① 全仓 grep `willPerformHTTPRedirection` 零命中 ⇒ 确实没有可剥离 `Authorization` 的位置，现行防线只剩落地权威判定（写盘前）；② 既有 C2 用例是**自陈局限的真断言**（断言「落地权威换人 → 拒绝 + 一个字节都不写盘」这个传输层唯一可观测事实），不是冒充已证；③ 要可证需要 `URLSessionPrivateAudioTransport` 侧可注入的 delegate 槽，而 `PrivateAudioTransport.swift` 不在本批文件所有权内 ⇒ TD-44 里写清了所需改动与判据草案，交协调者派后续批次 |
| min-5 | Minor | `purgeStale(before:)` 跨 owner 全目录扫描，会连带删掉其他账号的旧代次文件（当前单账号装配无实害） | `PrivateAudioFetcher.swift:261-282` | **已修（第 6 批·组 2）**：作用域收窄到当前凭证快照的 owner，凭证不可知 → 一个都不删。永久测试 `testPurgeStaleNeverReachesAnotherOwnersFiles`；变异 G2-min5a KILLED（5 条） |
| min-6 | Minor | 多实例门面互踩系统单例：`registerCommands()` 每次 `removeTarget(nil)`、`setCommandsEnabled`/`teardown` 作用于全部 11 条命令，与所有者无关；`registeredHandlerCount` 是自我申报而非系统事实 | `MPNowPlayingController.swift:114`；探针 `testSecondFacadeRegistration…`/`testTeardownDisablesEverySharedCommandRegardlessOfOwner` | **已修（第 7 批·组 2，第 8 批收口复跑）**：**能收敛的收敛、不能收敛的立 TD-43**。已收敛的一半 —— 共享命令面的**认领关系变成可查询的进程内事实**：`SharedSurfaceLedger`（NSLock + 单调票据、永不回收），`registerCommands()` 与 `setCommandsEnabled(_:)` 都认领（谁最后塑形谁负责），新增 `ownsSharedCommandSurface`（实例侧）/ `MPNowPlayingController.sharedSurfaceClaimCount`（进程侧总次数）+ 门面转发，`teardown()`/deinit 兜底退位。复审点名的「自我申报 vs 系统事实」混淆一并被写进判据（被顶掉者仍自报满额 11 条这条对照就摆在测试里）。未收敛的一半（TD-43）—— 系统不给 owner 命名空间、也不公开 `targets`（TD-39）⇒「按所有者隔离写入 / 系统侧 target 真数」本层做不到；**刻意不做**「非持有者跳过 `removeTarget`」（会把已挂上的 target 留在系统里，悬垂比互踩更糟）。永久测试 `testSecondRegistrationTakesOverSharedCommandSurface`、`testSharedSurfaceWriteFromNonOwnerStompsEveryCommandAndTakesOver` + 门面腿 `testSecondFacadeRegistrationTakesOverSharedCommandSurface`；变异 G3-min6a（去掉所有权票据）KILLED（第 8 批实测 6 条失败 / 3 个测试，控制器层与门面层都红） |

## C. 协调者裁决与后续

- F-D / F-E 接受「按 D16⑤ 不判缺陷、仅登记加固」的结论（不为不可观测窗口写竞态断言）。
- MAJ-6 / MAJ-7 是我在前一批**主动延后**的 M9 / m16-m17，复审证实为 Major ⇒ 延后判断错误，
  本批必须闭合，不再外派到 M1。
- 派单批次：**第 5 批** = F-A / F-B / F-C（状态机与上报，文件域 `PlaybackCoordinator`、
  `PlayReportCoordinator`、`CovaPlayer.swift`）；**第 6 批** = MAJ-1…MAJ-8 + min-1…min-6
  （私有音频与生命周期，文件域 `PrivateAudio*`、`AudioSessionController`、
  `MPNowPlayingController`、`AVPlayerEngine`、`CovaPlayer.swift`）。
  两批共用 `CovaPlayer.swift` ⇒ **严格串行**，第 6 批待第 5 批 commit 后再派。
- 两批都跑完并整轮 `check.sh` EXIT=0 后，派**第 5 轮**隔离复审（新实例、只读克隆）。


---

## §D 第 5 轮隔离复审（收窄范围版）实测补充

**私有音频/生命周期 + 门禁面**（0 Critical / 1 Major / 2 Minor）：
- (A) 侧 13 条历史 finding 全部判**已闭合**，无一被重新打开；MAJ-2/MAJ-3 的「无默认实现」
  经**编译期实证**（写一个只实现 `prepareSource` 的类型 → `does not conform to protocol`）。
- 门禁面是硬的：合法面干净 clone 与**含空格路径** clone 两侧 EXIT=0 且数字逐项一致；
  23 条必红面全红（含 `import`↵`WebKit` 换行拆名）；TD-9 六类合法形态零误红
  （5 个无插桩文件在映射侧与运行侧**同时缺席**，真分母判定未被撑破）；
  UIKit weak 豁免两侧 `otool -L` 实证，且在 `/tmp` 克隆里**关掉全部四条 import 判据**后
  产物侧仍能独立拦下强依赖；`git diff 8b9d0c1..HEAD -- Scripts/check.sh` 无替换式放宽
  （判据 fail 消息 79 → 137 条）。
- **Major-1（新）**：非持有者门面 `deinit` 无条件对进程单例 `MPRemoteCommandCenter`
  执行 `isEnabled = false` + `removeTarget(nil)`，不看同批刚建的所有权票据 →
  A 注册 → B 接手 → **A 析构打死 B 的锁屏控制**。实测复现、零测试覆盖。修 MAJ-7 引入的 B。
- Minor-1：CovaCore 的字面令牌判据在**文档注释**上误红（在文档里解释「为什么不引入 WebKit」
  会变成门禁事故）⇒ 「误红与漏检同等严重」在核心层不成立。
- Minor-2：播放器层 `import CoreMedia` 即红（清单只收实测在用的四项）。属摩擦非漏检，
  但需在常量注释写明「非 UI 模块走同一道显式改清单 + 评审流程」，避免被当 UI 判据随手放宽。

**协调者独立复核出的真 flake（复审报告未列，来自其原始日志）**：
`PrivateAudioFetcherTests.testCancellationByBothMergedCallersDeliversNoPlayableURL`
500 迭代**失败 6 次**、`testUpperLayerCancellationTerminatesInFlightTransfer` 失败 1 次，
每次耗时 ≈10.0s ⇒ 有界等待超时到期形态。即第 6/7 批为 MAJ-1 写的取消测试本身不稳定，
按本仓零 flake 判据属 Major —— (A) 侧「MAJ-1 已闭合」的结论要打上这个补丁。

**处置**：第 9 批（`dev-g3e-fix9`）只派这两条，并明令禁止用「删测试/放宽断言/XCTSkip/
调小迭代/调大超时」蒙混；若根因在生产代码，则视为 MAJ-1 原本未真正闭合，修生产。
