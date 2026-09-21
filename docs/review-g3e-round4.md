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
| MAJ-2 | **Major** | `discardPrivateAudio(owner:)` 的**默认空实现**可被「第二个会写文件的准备器」绕过清盘：登出后文件仍在沙盒。`fetcher.purgeAll()` 支路要求 `as? any PrivateAudioFetching` 成功转换。**修法：删掉默认实现，改为必须实现** | `PrivateAudioFetching.swift:66-68`、`CovaPlayer.swift:130-137`；探针 `testFileWritingPreparerWithoutOverrideIsDiscardedOnLogout`。违反 D8 / api-contracts §5 | **待修（第 6 批·组 2）** |
| MAJ-3 | **Major** | `cancelInFlightTransfers()` 的默认空实现使「清理前作废在途」不成义务：`purgeAll()` 后传输仍跑完并投递 `failure(写入失败 状态码 4)`；盘上干净**只是巧合**（`commitMove` 撞 ENOENT），不是设计保证 | `PrivateAudioTransport.swift:51-58`；探针 `testPurgeIsNotDefeatedByInFlightTransferOnDefaultNoOpTransport`。违反 D16② | **已修（第 6 批·组 1）**：删除 `cancelInFlightTransfers()` 的协议默认空实现 → 必须实现（漏实现编译不过）。永久测试 `testPurgeIsNotDefeatedByInFlightTransferOnRequiredCancellation`、`testInFlightCancellationIsARequiredWitnessNotADefaultNoOp`；变异 G1-M3a KILLED（复现出原话形态「本地写入失败（状态码 4）」） |
| MAJ-4 | **Major** | 被作废的传输抛的是裸 `NSURLError(-999)`，最终被归类成 `missingFile` 且 **计入失败连击**（`countsTowardFailureStreak == true`）→ 登出/断网造成的取消会被 design §9「连续 3 次失败停止」累计。机理：`for try await byte` / `handle.synchronize()` 不在任何 `catch` 内（只有 `bytes(for:)` 段做了归一） | `PrivateAudioTransport.swift:270-283` vs `:229-237`、`PlayerEngine.swift:52`、`PrivateAudioFetcher.swift:201-203`；探针 `testRealTransportCancellationTerminatesInFlightStream` | **已修（第 6 批·组 1）**：读循环 + `synchronize()` 整段纳入 `normalizedStreamError`，准备器侧 `isCancellationShaped` 为第二道；取消一律归一为 `.cancelled` → `countsTowardFailureStreak == false`。永久测试 `testRealTransportCancellationTerminatesInFlightStream`、`testMidStreamNetworkFailureIsNotSilentlyTreatedAsCancellation`、`testStreamErrorNormalizationTable`、`testInvalidatedTransferNeverCountsTowardFailureStreak`；变异 G1-M4a / G1-M4b KILLED |
| MAJ-5 | **Major** | 观测者注册排在 `configureForPlayback()` **之后**，且门面用 `try?` 吞错 → 真机 `setActive(true)` 失败（他人占用/通话中）时注册被跳过，**design §7 再次静默失效**。M3 修复本身有效，但把「注册」挂在了「激活成功」上 | `AudioSessionController.swift:279-286`、`CovaPlayer.swift:160-166`；探针 `testObserverRegistrationDoesNotDependOnSessionActivation`（`observedNotificationCount=0` 而 `isActivated=true`）。另注：既有 `testRealAdapterAsSystemGetsObserversRegisteredByGate` 带 `XCTSkip` 逃生门，正是该形态 | **待修（第 6 批·组 3）** |
| MAJ-6 | **Major** | 锁屏命令桥用 `DispatchSemaphore` **无超时** `wait()` 把系统线程钉在含下载挂起点的 actor 链上，实测 parked 0.424s（夹具放行前零推进），上界 = `resourceTimeout` **7 天**。（即此前被延后的 M9，复审证实仍 Major） | `MPNowPlayingController.swift:144-158` → `NowPlayingController.swift:189` → `PlaybackCoordinator.resume():517-533` → `loadCurrent` → `prepareSource:910`；`PrivateAudioTransport.swift:103` | **待修（第 6 批·组 3）** |
| MAJ-7 | **Major** | 门面 `deinit` 只 `engine.stopAndRelease()`：析构后 `playCommand.isEnabled=true`、Now Playing 仍显示死门面曲名、`playbackState=playing`；`AVAudioSessionAdapter` 无 `deinit`，观测者 token 只在 `stopObserving()` 摘 ⇒ **通知残留（本仓红线）**。`CovaPlayer.swift:17` 的「不留远端 target」自述不实 | `CovaPlayer.swift:261-264`、`AudioSessionController.swift:351-519`；探针 `testDeinitWithoutTeardownRetiresRemoteCommandsAndNowPlaying`。附带：门面本身无泄漏（`testFacadeDeallocationAtEachLifecycleStage` 四阶段全 true） | **待修（第 6 批·组 3）** |
| MAJ-8 | **Major** | `.publicDirect` 的 https 媒体地址在引擎侧**零出口判定**：`playableURL(for:)` 对 `https://cdn-other.invalid/a.m4a` 返回 `.success`；`assetOrigin` 是**从不被消费的死字段**（全仓仅出现在门面构造与两处断言里） | `AVPlayerEngine.swift:132-145`、`CovaPlayer.swift:21/43/48/68`；探针 `testPublicDirectHTTPSIsJudgedAgainstProductionExit`。违反 AGENTS 硬边界 2 字面口径与 `CovaPlayer.swift:14` 注释承诺 | **待修（第 6 批·组 2）** |
| min-1 | Minor | 缓存**目录**位仍 0755（文件位已 0600） | `PrivateAudioFetcher.swift:383-390` | **待修（第 6 批·组 3）** |
| min-2 | Minor | 同源判定与出口守卫口径不一致：`isProductionOrigin` 放行 `https://covalink.cn:443`，而 `AudioAuthorityMatch.origin(of:)` 把 `covalink.cn` 与 `…:443` 判成两台主机 → **合法重定向被误杀**（NEEDS-15 未解锁前又多一处堵点） | `PrivateAudioTransport.swift:67-73`；探针 `testCanonicalPortMatchesProductionAuthority` | **待修（第 6 批·组 2）** |
| min-3 | Minor | 同键合流在 `expectedBytes` 不一致时破裂：同一 key 两次带 Bearer 出站，A 已拿到的 24 字节交付被 B 的 48 字节提交换掉（盘上实得 48）。设计注释称有意，但与既有 `testConcurrentSameKeyRequestsTriggerExactlyOneTransfer` 自陈的「两个调用者必须拿到同一份内容」直接冲突 | `PrivateAudioFetcher.swift:112-118`；探针 `testMergedSameKeyRequestsCommitOneConsistentPayload` | **待修（第 6 批·组 2）** |
| min-4 | Minor | 跨主机重定向的**凭证外发面在离线夹具上不可观测**（`URLProtocol` 桩不重放跳转链，实测只发出 1 个主机、落地请求无 `Authorization`）⇒ 既未证实也未证伪；且实现里没有 `willPerformHTTPRedirection` 委托，也就**没有任何可剥离 `Authorization` 的位置** | 既有 C2 测试同样自陈此局限 | **本批处理（第 6 批·组 3）**：离线不可证者登记 TD 并写进存疑点，不许假断言 |
| min-5 | Minor | `purgeStale(before:)` 跨 owner 全目录扫描，会连带删掉其他账号的旧代次文件（当前单账号装配无实害） | `PrivateAudioFetcher.swift:261-282` | **待修（第 6 批·组 2）** |
| min-6 | Minor | 多实例门面互踩系统单例：`registerCommands()` 每次 `removeTarget(nil)`、`setCommandsEnabled`/`teardown` 作用于全部 11 条命令，与所有者无关；`registeredHandlerCount` 是自我申报而非系统事实 | `MPNowPlayingController.swift:114`；探针 `testSecondFacadeRegistration…`/`testTeardownDisablesEverySharedCommandRegardlessOfOwner` | **本批处理（第 6 批·组 3）**：不收敛则必须立 TD 并给边界说明 |

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
