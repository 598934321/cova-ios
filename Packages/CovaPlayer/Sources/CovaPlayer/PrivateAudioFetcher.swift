import CovaCore
import Foundation

/// 私有音频本地化器（D7 硬规则的实现）。
///
/// 硬性顺序（任何一步失败都不产生可播地址）：
/// 1. owner 与 generation 必须与凭证快照一致（防跨账号 / 防在途旧代次）；
/// 2. **发起**那一条必须是 `CovaEnvironment.isProductionOrigin`（唯一网络出口，D10）；
///    3xx 的落地由传输层按 D23 逐跳裁决 —— 许可名单的存储桶只作为**被核准的那一条落地**
///    出现，并且那一跳不带任何凭证（R18-4：已授权整曲正是靠这一条才出得来）；
/// 3. 经**落盘式**传输流式写入临时文件（`HTTPTransport` 整包返回 Data，故不复用它）；
/// 4. 校验完成性：字节数 > 0，且响应声明长度时必须相等（拒绝空文件与截断）；
/// 5. 原子 `move` 到 owner 目录，返回 `file://`；
/// 6. 全程不把带 Bearer/签名查询的 https 地址交给播放器，也不写日志。
public actor PrivateAudioFetcher: PrivateAudioFetching, PlaybackSourcePreparing {
    private let transport: any PrivateAudioTransport
    private let credentials: any APICredentialProviding
    private let baseDirectory: URL
    private let fileManager: FileManager

    /// 在途传输的身份（M7 去重键）：目标路径由这**四元组**唯一决定，因此它也是「同一份内容」的判据。
    ///
    /// R16-1b：`contentKind` 必须在这一条腿上出现 —— 否则「同一 itemID 的预览段」与
    /// 「同一 itemID 的整曲」会合流到同一次传输，先发起者的那一份字节被当成另一份交付。
    private struct TransferKey: Hashable {
        let ownerNamespace: String
        let itemID: String
        let generation: UInt64
        let contentKind: PrivateAudioContentKind
    }

    /// 一条在途传输。`token` 用于「只摘掉自己那一条」的收尾 —— 清理会作废整张表，
    /// 此后新起的传输不能被上一位的收尾误删。
    private struct InflightTransfer {
        let token: UInt64
        let task: Task<Result<AudioURL, PlayerError>, Never>
    }

    /// 在途去重表（M7）：同一 `(owner, itemID, generation)` 只允许**一次**真实传输。
    private var inflightTransfers: [TransferKey: InflightTransfer] = [:]
    private var nextTransferToken: UInt64 = 0

    /// 当前在途传输数（可观测面：去重与清理真的生效）。
    public var inflightTransferCount: Int { inflightTransfers.count }

    /// 等待一条在途传输，并把「调用者被取消」真的传导进那一路传输（MAJ-1）。
    ///
    /// 为什么必须在**这里**做而不是在传输层：合流用的是无结构 `Task`（为了在 actor 重入前
    /// 先把登记表填上），无结构任务**不继承**调用者的取消状态，`await task.value` 本身也不做
    /// 取消检查 —— 于是旧行为是「`caller.cancel()` 生效、下载照跑、结果照投递」（TD-40 由此
    /// 从「未证明」变成「已证否」）。D16② 要求的是相反形态：已发起（已授权）的传输必须被立即
    /// 取消，且结果不得投递。取消对合流者是**共享**的：同一 key 只有一路真实传输，
    /// 一人取消即终止那一路，其余合流者同样收到 `.cancelled`（而不是拿到一份「自己没要」的字节）。
    private func awaitTransfer(_ task: Task<Result<AudioURL, PlayerError>, Never>) async -> Result<AudioURL, PlayerError> {
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard Task.isCancelled == false else {
            // 完成与取消撞在同一瞬间时也不投递可播地址（`cancel()` 对已结束的任务是空操作）。
            task.cancel()
            return .failure(.cancelled)
        }
        return outcome
    }

    public init(
        transport: any PrivateAudioTransport,
        credentials: any APICredentialProviding,
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.transport = transport
        self.credentials = credentials
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory()
        self.fileManager = fileManager
        // M6：启动期兜底清理上一次进程被杀 / 写异常留下的在途分片。
        Self.discardInflightShards(in: self.baseDirectory, fileManager: fileManager)
    }

    /// 默认落在 Caches（系统可在空间不足时清理 —— 私有音频是可重取的缓存，不是唯一副本）。
    public static func defaultBaseDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches.appendingPathComponent("Cova", isDirectory: true)
    }

    public var cachedRootDirectory: URL { PrivateAudioPath.rootDirectory(base: baseDirectory) }

    // MARK: - 本地化

    public func localizedURL(for request: PrivateAudioRequest) async -> Result<AudioURL, PlayerError> {
        // MAJ-1：调用者已取消时一个出站动作都不许发生（D16②「结果不得投递」的最早形态）。
        if Task.isCancelled { return .failure(.cancelled) }
        switch await sessionBinding(for: request) {
        case .success:
            break
        case .failure(let error):
            return .failure(error)
        }
        guard case .https = request.source.scheme else {
            return .failure(.hostRejected(host: CovaEnvironment.egressHostLabel(of: request.source.value)))
        }
        // 发起地**只能**是生产出口（D10 + D23①）。整曲桶从来不是"直接发过去"的目标：它是这一条
        // 请求拿到 302 之后由 `MediaEgressHop` 以**匿名请求**重发的那一条落地（R18-4）——
        // 少这一道，服务端原文里的任何一台 host 都能被当成私有音频的来源。
        guard CovaEnvironment.isProductionOrigin(request.source.value) else {
            return .failure(.hostRejected(host: CovaEnvironment.egressHostLabel(of: request.source.value)))
        }
        guard let owner = request.session.owner else {
            return .failure(.credentialUnavailable)
        }
        let target: URL
        do {
            target = try PrivateAudioPath.fileURL(
                base: baseDirectory,
                owner: owner,
                itemID: request.itemID,
                generation: request.session.generation,
                kind: request.contentKind
            )
        } catch let error as PlayerError {
            return .failure(error)
        } catch {
            return .failure(.pathEscape)
        }

        // R16-1b：形态不可判别 ⇒ 这一条腿整个关掉。不是「保守起见少一次网络」，而是
        // 「这里没有任何东西能证明盘上那一份就是本次要的那一份」：库曲的预览段与整曲
        // 住同一个端点、同一个 itemID、同一代次，而 DTO 既不给长度也不给形态标记。
        if request.contentKind.allowsCacheReuse,
           let cached = existingValidFile(at: target, expectedBytes: request.expectedBytes) {
            return .success(cached)
        }

        // M7：并发同键请求必须**合流到一次传输**。旧行为是两个调用者各起一路下载、
        // 各自往同一个目标路径做原子替换 —— 后提交方会把先交付方已经拿到的文件换掉
        // （交付面因此不稳定），且出口被多打了一次（Bearer 地址重复外发）。
        let key = TransferKey(
            ownerNamespace: PrivateAudioPath.namespace(for: owner),
            itemID: request.itemID,
            generation: request.session.generation.value,
            contentKind: request.contentKind
        )
        if let entry = inflightTransfers[key] {
            let shared = await awaitTransfer(entry.task)
            switch shared {
            case .failure:
                return shared
            case .success(let delivered):
                // min-3：合流者**绝不换件**。旧注释说的「自己的期望长度复核不过 → 自己重取」
                // 实际是「往同一个目标路径再覆盖提交一次」—— 于是先交付方拿到的 24 字节被
                // 后加入方的 48 字节换掉（盘上实得 48），与 `testConcurrentSameKeyRequestsTriggerExactlyOneTransfer`
                // 自陈的「两个调用者必须拿到同一份内容」直接冲突。
                // 现在：同一 key 的字节数只由那一次传输决定；期望与实得不一致就是**元数据打架**，
                // 如实报截断并把决定权交回上层，一次覆盖都不做。
                if let verdict = mergedOutcome(at: target, delivered: delivered, expectedBytes: request.expectedBytes) {
                    return verdict
                }
            }
        }
        return await startTransfer(for: request, owner: owner, target: target, key: key)
    }

    /// 合流交付复核（min-3）：返回 nil 才允许自己另起一路。
    ///
    /// 与缓存复用腿（`existingValidFile`）**相反**，这里一个字节都不删：目标文件是别人那一次
    /// 传输的交付物，删除或覆盖它就是把「换件」写进成功路径。只有「文件确实不见了」
    /// （被清理、被系统回收）才退回自己重取。
    private func mergedOutcome(
        at url: URL,
        delivered: AudioURL,
        expectedBytes: Int?
    ) -> Result<AudioURL, PlayerError>? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if let expectedBytes, expectedBytes != size {
            return .failure(.truncated(expected: expectedBytes, actual: size))
        }
        guard size > 0 else { return .failure(.emptyDownload) }
        // 权限位不合格也不换件：那是「别人的交付物」，不是本路可以重写的东西。
        guard Self.hasPrivateAudioFileMode(attributes) else { return .failure(.writeFailed(EACCES)) }
        guard let verified = try? AudioURL(file: url) else { return .failure(.pathEscape) }
        return .success(verified)
    }

    /// 登记并等待一次传输（同一时刻只有一个登记动作：本函数到 `inflightTransfers[key] = …`
    /// 之间没有任何挂起点，因此两个并发调用不可能各自登记）。
    private func startTransfer(
        for request: PrivateAudioRequest,
        owner: PrincipalID,
        target: URL,
        key: TransferKey
    ) async -> Result<AudioURL, PlayerError> {
        let temporary = temporaryURL()
        let token = nextTransferToken
        nextTransferToken &+= 1
        let task: Task<Result<AudioURL, PlayerError>, Never> = Task { [weak self] in
            guard let self else { return .failure(.cancelled) }
            return await self.performTransfer(
                for: request,
                owner: owner,
                target: target,
                temporary: temporary,
                key: key,
                token: token
            )
        }
        inflightTransfers[key] = InflightTransfer(token: token, task: task)
        return await awaitTransfer(task)
    }

    /// 传输本体（在合流后的唯一一路里执行）。
    private func performTransfer(
        for request: PrivateAudioRequest,
        owner: PrincipalID,
        target: URL,
        temporary: URL,
        key: TransferKey,
        token: UInt64
    ) async -> Result<AudioURL, PlayerError> {
        defer {
            if inflightTransfers[key]?.token == token { inflightTransfers[key] = nil }
        }
        // MAJ-1：任务在「登记之后、真正出站之前」被取消 → 直接收尾，一次传输都不发。
        if Task.isCancelled { return .failure(.cancelled) }
        do {
            try prepareDirectories(owner: owner)
            let receipt = try await transport.writeAudio(
                from: request.source.value,
                authorization: try await authorizationValue(),
                to: temporary,
                expectedBytes: request.expectedBytes
            )
            guard receipt.bytesWritten > 0 else {
                removeItem(at: temporary)
                return .failure(.emptyDownload)
            }
            if let expected = receipt.expectedBytes, expected != receipt.bytesWritten {
                removeItem(at: temporary)
                return .failure(.truncated(expected: expected, actual: receipt.bytesWritten))
            }
            guard receipt.isComplete else {
                removeItem(at: temporary)
                return .failure(.emptyDownload)
            }
            // MAJ-1 / D16②：提交前复核取消状态 —— 被取消的传输绝不产出可播地址。
            if Task.isCancelled {
                removeItem(at: temporary)
                return .failure(.cancelled)
            }
            // 提交前复核会话：下载途中登出/换号则丢弃（旧代次结果绝不落库）。
            switch await sessionBinding(for: request) {
            case .success:
                break
            case .failure(let error):
                removeItem(at: temporary)
                return .failure(error)
            }
            if Task.isCancelled {
                removeItem(at: temporary)
                return .failure(.cancelled)
            }
            try commitMove(from: temporary, to: target)
            removeItem(at: temporary)
            guard let localized = try? AudioURL(file: target) else {
                return .failure(.pathEscape)
            }
            return .success(localized)
        } catch let error as PlayerError {
            removeItem(at: temporary)
            return .failure(error)
        } catch is CancellationError {
            removeItem(at: temporary)
            return .failure(.cancelled)
        } catch {
            removeItem(at: temporary)
            // MAJ-4：被作废的传输抛上来的多是裸 `NSURLError(-999)`（`for try await byte` 与
            // `handle.synchronize()` 都不在任何 `catch` 里）。不归一就会被算成「写入失败」→
            // `missingFile` → **计入失败连击**，于是登出/断网造成的取消会喂 design §9 的
            // 「连续 3 次失败停止」。取消不是失败。
            if Self.isCancellationShaped(error) {
                return .failure(.cancelled)
            }
            return .failure(.writeFailed(Self.status(of: error)))
        }
    }

    /// 条目 → 缓存内容形态（R16-1b 的唯一裁决点，纯函数好断言）。
    ///
    /// · `.libraryTrack`：线上只有 `/api/tracks/<id>/preview-stream` 这一个出口，
    ///   未授权发预览段字节、已授权 302 走整曲桶，而曲目 DTO **既不给字节长度也不给形态标记**
    ///   （实测 `duration` 178.84s 与缓存里 19.56s 的预览段并存）⇒ 调用方无法判别，`.unspecified`；
    /// · `.privateCandidate`：生成候选与笔记音频的地址就是「这一条资产本身」，
    ///   不存在同一地址的第二种形态 ⇒ 声明 `.full`，缓存复用照旧。
    /// · `.work`：作品的 `audioUrl` 同理是「这一条成品本身」（三种形态都是整首：
    ///   `/audio/*.mp3` 公开静态、`/api/media/objects/…` 需 Bearer、`/api/proxy/audio?…`
    ///   签名代理）⇒ `.full`。它**不是**库曲那种「同一端点按授权发不同字节」的形状。
    static func contentKind(for item: PlaybackItem) -> PrivateAudioContentKind {
        switch item.kind {
        case .libraryTrack: return .unspecified
        case .privateCandidate, .work: return .full
        }
    }

    /// 播放源准备：已可播的原样放行，需 Bearer 的必须先本地化。
    public func prepareSource(
        for item: PlaybackItem,
        session: PlaybackSessionContext
    ) async -> Result<PlaybackItem, PlayerError> {
        guard item.requiresLocalization else { return .success(item) }
        guard case .bearerRequired(let url) = item.audioSource else {
            return .failure(.notLocalized(item.id))
        }
        switch await localizedURL(for: PrivateAudioRequest(
            itemID: item.id,
            source: url,
            session: session,
            contentKind: Self.contentKind(for: item)
        )) {
        case .success(let localized):
            return .success(item.localized(to: localized))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - 清理（D8：登出/换号清私有音频）

    /// 清除某 owner 的全部私有音频（登出 / 换号）。返回**已确认删除**的文件数。
    ///
    /// M5：owner 必须先过校验。空 principal 的 hex 命名空间是 `""`，
    /// `appendingPathComponent("")` 会算到**缓存根** —— 一次删掉所有账号的私有音频。
    /// 取回侧早就 fail-closed（`PrivateAudioPath.fileURL` 调 `OwnerIdentifier.requireValid`），
    /// 清理侧漏了同一道闸。
    @discardableResult
    public func purge(owner: PrincipalID) async -> Int {
        guard (try? OwnerIdentifier.requireValid(owner)) != nil else { return 0 }
        // M8 / D16②：作废在途传输，否则「已授权的下载」会在清理之后继续投递结果。
        await transport.cancelInFlightTransfers()
        discardInflightRegistry()
        return removeVerified(
            at: PrivateAudioPath.ownerDirectory(base: baseDirectory, owner: owner)
        )
    }

    /// 会话失效（D8 / F-13）：本实现会在磁盘上留私有音频，因此**必须**覆盖协议的空操作默认值。
    /// 「有没有真的覆盖」由 `PrivateAudioFetcherTests` 的协议面清理用例把守（而不是只测 `purge`）。
    public func discardPrivateAudio(owner: PrincipalID?) async {
        if let owner {
            _ = await purge(owner: owner)
        } else {
            _ = await purgeAll()
        }
    }

    @discardableResult
    public func purgeStale(before generation: SessionGeneration) async -> Int {
        await transport.cancelInFlightTransfers()
        discardInflightRegistry()
        // min-5：作用域收窄到**当前凭证快照的那个 owner**。旧实现扫遍缓存根下的每个 owner 目录，
        // 于是 A 账号的一次代次推进会把 B 账号的旧代次文件一并删掉 —— 当前单账号装配没有实害，
        // 但「跨 owner 误删」在类型上没人守住，而 M8 的 owner 校验（空 principal → 缓存根）
        // 就是同一族缺陷留下过的那道口子。
        // 凭证不可知（登出中 / 读取失败）时一个都不删：宁可留孤儿文件给下一次 `purge`，
        // 也不替不明的身份做删除决定。
        guard let owner = await currentCredentialOwner() else { return 0 }
        let directory = PrivateAudioPath.ownerDirectory(base: baseDirectory, owner: owner)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for file in files {
            let stored = PrivateAudioPath.generation(infileName: file.lastPathComponent)
            guard let stored, stored < generation else { continue }
            if removeVerified(at: directory.appendingPathComponent(file.lastPathComponent)) > 0 {
                removed += 1
            }
        }
        return removed
    }

    /// 当前凭证快照里的身份（不做任何网络调用；读取失败 / 未登录 → nil）。
    private func currentCredentialOwner() async -> PrincipalID? {
        // `try?` 会把「抛错」与「快照为 nil」压成同一个 nil：两种形态都不该被当作
        // 「有身份」处理，因此这里不区分它们 —— 拿不到 owner 就不删任何东西。
        guard let snapshot = try? await credentials.currentSession() else { return nil }
        return snapshot.principal
    }

    @discardableResult
    public func purgeAll() async -> Int {
        await transport.cancelInFlightTransfers()
        discardInflightRegistry()
        return removeVerified(at: PrivateAudioPath.rootDirectory(base: baseDirectory))
    }

    /// 作废在途登记表（M7 的另一半）：清理之后到达的请求**绝不复用**清理前开始的传输，
    /// 否则会拿到一条「落在刚刚被清空的目录里」的投递。已在途的那一路自己收尾时只会
    /// 按 token 摘掉自己的条目（`performTransfer` 的 `defer`），不会误删新条目。
    private func discardInflightRegistry() {
        inflightTransfers = [:]
    }

    /// 丢弃在途分片（M6）：`.inflight` 是隐藏目录、且不在 owner 目录下，
    /// 因此 `purge(owner:)`/`purgeStale` 都到不了它 —— 上一次进程被杀或 ObjC 写异常
    /// 留下的半文件会永久残留。清理与 `purgeAll` 都要覆盖它，并在启动期兜一次。
    @discardableResult
    public func discardInflightShards() -> Int {
        Self.discardInflightShards(in: baseDirectory, fileManager: fileManager)
    }

    /// 启动期清理（同步，供 `init` 使用）。
    @discardableResult
    static func discardInflightShards(in base: URL, fileManager: FileManager) -> Int {
        removeVerified(
            at: PrivateAudioPath.temporaryDirectory(base: base),
            fileManager: fileManager
        )
    }

    /// 在途/已缓存文件总数（teardown 断言用）。
    public func cachedFileCount() -> Int {
        fileCount(in: PrivateAudioPath.rootDirectory(base: baseDirectory))
    }

    // MARK: - 内部

    /// 从任意底层错误只取整数码（与 `PlayerError` 一致：不回显路径/地址/描述）。
    static func status(of error: Error) -> Int32 {
        Int32(truncatingIfNeeded: (error as NSError).code)
    }

    /// 「这其实是一次取消」的归一判据（MAJ-4，D16②）。
    ///
    /// 覆盖三种真实形态：Swift `CancellationError`、已经归一过的 `PlayerError.cancelled`、
    /// 以及 Foundation/URLSession 的裸 `NSURLErrorDomain / NSURLErrorCancelled(-999)`
    /// （会话 `invalidateAndCancel()` 之后在途字节流抛上来的就是这一条）。
    /// 判据只认 domain + code，不看描述文本（描述里可能带任务标识，不进错误值）。
    static func isCancellationShaped(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let playerError = error as? PlayerError, playerError == .cancelled { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let bridge = error as NSError
        return bridge.domain == NSURLErrorDomain && bridge.code == NSURLErrorCancelled
    }

    /// 校验 owner/generation 与凭证快照一致（不做任何网络调用）。
    private func sessionBinding(for request: PrivateAudioRequest) async -> Result<Void, PlayerError> {
        guard let owner = request.session.owner else { return .failure(.credentialUnavailable) }
        let snapshot: AuthSessionSnapshot?
        do {
            snapshot = try await credentials.currentSession()
        } catch {
            return .failure(.credentialUnavailable)
        }
        guard let snapshot else { return .failure(.credentialUnavailable) }
        guard snapshot.principal == owner else { return .failure(.staleSession) }
        guard snapshot.generation == request.session.generation else { return .failure(.staleSession) }
        return .success(())
    }

    private func authorizationValue() async throws -> SecretString? {
        let snapshot: AuthSessionSnapshot?
        do {
            snapshot = try await credentials.currentSession()
        } catch {
            throw PlayerError.credentialUnavailable
        }
        guard let snapshot else { throw PlayerError.credentialUnavailable }
        return snapshot.accessToken
    }

    private func existingValidFile(at url: URL, expectedBytes: Int?) -> AudioURL? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            removeItem(at: url)
            return nil
        }
        if let expectedBytes, expectedBytes != size {
            removeItem(at: url)
            return nil
        }
        // m12：缓存复用面同样复核权限 —— 收紧之前留下的「组/其它可读」旧文件不能继续被当作可用缓存。
        guard Self.hasPrivateAudioFileMode(attributes) else {
            removeItem(at: url)
            return nil
        }
        return try? AudioURL(file: url)
    }

    private func temporaryURL() -> URL {
        PrivateAudioPath.temporaryDirectory(base: baseDirectory)
            .appendingPathComponent(UUID().uuidString.lowercased() + ".part")
    }

    private func prepareDirectories(owner: PrincipalID) throws {
        // 顺序有讲究：先根、再 owner 目录、再在途目录 —— `createDirectory(withIntermediateDirectories:)`
        // 会顺手把上游目录按默认位（0755）建出来，所以每一个都必须自己收紧（min-1）。
        try createDirectory(PrivateAudioPath.rootDirectory(base: baseDirectory))
        try createDirectory(PrivateAudioPath.ownerDirectory(base: baseDirectory, owner: owner))
        try createDirectory(PrivateAudioPath.temporaryDirectory(base: baseDirectory))
    }

    /// 建目录**并**把位收敛到 `PrivateAudioPath.directoryMode`（min-1）。
    ///
    /// 收紧对「已存在的目录」同样执行：收紧之前建的 0755 目录必须被就地改到 0700，
    /// 否则这条判据只对全新安装生效。失败按 fail-closed 处理（宁可这次取回失败）。
    private func createDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) == false {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw PlayerError.writeFailed(Self.status(of: error))
            }
        }
        do {
            try fileManager.setAttributes(PrivateAudioPath.directoryAttributes, ofItemAtPath: url.path)
        } catch {
            throw PlayerError.writeFailed(Self.status(of: error))
        }
        guard Self.hasPrivateAudioDirectoryMode(attributesOf(url)) else {
            throw PlayerError.writeFailed(EACCES)
        }
    }

    /// 目录位是否已收敛到 `PrivateAudioPath.directoryMode`（min-1 的复核面）。
    static func hasPrivateAudioDirectoryMode(_ attributes: [FileAttributeKey: Any]) -> Bool {
        let raw = (attributes[.posixPermissions] as? NSNumber)?.int32Value ?? -1
        return Int(truncatingIfNeeded: raw) & 0o777 == PrivateAudioPath.directoryMode
    }

    private func commitMove(from source: URL, to target: URL) throws {
        removeItem(at: target)
        do {
            // 原子替换：避免半写文件被当作可用缓存。
            try fileManager.moveItem(at: source, to: target)
        } catch {
            throw PlayerError.writeFailed(Self.status(of: error))
        }
        guard fileExists(at: target) else { throw PlayerError.emptyDownload }
        // m12：权限在**提交处**再判一次，不单独信传输层的建档属性 ——
        // 缓存里是「仅本人可见」的音频字节，任何组/其它可读位都必须在这里被抹掉。
        // 收紧失败按 fail-closed 处理：宁可删掉这份缓存，也不交付一个世界可读的文件。
        do {
            try fileManager.setAttributes(
                PrivateAudioPath.fileAttributes,
                ofItemAtPath: target.path
            )
        } catch {
            removeItem(at: target)
            throw PlayerError.writeFailed(Self.status(of: error))
        }
        guard Self.hasPrivateAudioFileMode(attributesOf(target)) else {
            removeItem(at: target)
            throw PlayerError.writeFailed(EACCES)
        }
    }

    private func attributesOf(_ url: URL) -> [FileAttributeKey: Any] {
        (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
    }

    /// 权限位是否已收敛到 `PrivateAudioPath.fileMode`（m12 的复核面：提交处与缓存复用处共用）。
    static func hasPrivateAudioFileMode(_ attributes: [FileAttributeKey: Any]) -> Bool {
        let raw = (attributes[.posixPermissions] as? NSNumber)?.int32Value ?? -1
        return Int(truncatingIfNeeded: raw) & 0o777 == PrivateAudioPath.fileMode
    }

    private func removeItem(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        // 清理失败不影响判定：文件仍在 owner 目录内，purge/teardown 会兜底。
        try? fileManager.removeItem(at: url)
    }

    /// 删除并**复核删除结果**，返回已确认删除的文件数（m13）。
    ///
    /// 旧实现返回的是「删除前数到的数量」并用 `try?` 吞掉错误 —— 上层因此无法知道
    /// 清理是否真的发生（登出后磁盘上其实还有上一个账号的私有音频，也会被告知「已清 N 个」）。
    private func removeVerified(at url: URL) -> Int {
        Self.removeVerified(at: url, fileManager: fileManager)
    }

    /// 同上（静态形态，供 `init` 的启动期清理复用）。
    @discardableResult
    static func removeVerified(at url: URL, fileManager: FileManager) -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let count = fileCount(in: url, fileManager: fileManager)
        do {
            try fileManager.removeItem(at: url)
        } catch {
            return 0
        }
        // 删除后复核：路径仍在就一个都不算删掉（宁可少报，不可虚报）。
        return fileManager.fileExists(atPath: url.path) ? 0 : count
    }

    /// 目录（或单文件）下的文件总数。
    static func fileCount(in url: URL, fileManager: FileManager) -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue { return 1 }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return 0 }
        var count = 0
        for case let candidate as URL in enumerator where !candidate.hasDirectoryPath {
            count += 1
        }
        return count
    }

    private func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func fileCount(in directory: URL) -> Int {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            count += 1
        }
        return count
    }
}
