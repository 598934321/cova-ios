import CovaCore
import Foundation

/// 作品直存（BUG-15 的双路径分野，DEVELOPMENT.md §4.6 / A6）。
///
/// **这一层存在的理由就是「不走 checkout」**：作品是用户自己生成的成品，
/// 下载它不扣费、不需要授权凭证换取下载地址，所以它**绝不**经过
/// `POST /api/downloads/checkout`（那条是库曲的扣费写路径，D12 合规门禁未放行 ⇒ 全仓无调用点）。
/// 接错腿 = 误扣费，所以这里连一个能构造 checkout 请求的入口都没有。
///
/// 证据（2026-09-26 只读核对 `web` 仓）：`works/route.ts`、`lib/studio/create/works.ts`、
/// `lib/media-storage/playback-url.ts`、`api/media/objects/[id]/route.ts`、
/// `api/proxy/audio/route.ts` 五个文件里 `consumeCredits|grantCredits|ledger` **零命中**；
/// 而 `checkoutDownloads` 只接受已发布库曲的 `trackIds`
/// （`SELECT … FROM tracks WHERE status='published' AND id IN (…)`）⇒ 伪 trackId
/// `{jobId}:{candidateId}` 根本进不去那张表。
///
/// 与 `PrivateAudioFetcher` 的分工（两者都往沙盒写音频，但**不是一件事**，不许合并）：
/// · fetcher 写的是 **Caches** 里按 `#形态@g代次` 命名的可重取缓存 —— 系统能在空间紧张时清，
///   登出与 `purgeStale` 会清，代次一换名字就变；
/// · 本层写的是 **Documents** 里用户主动按「保存」留下的成品，有本地清单、文件名带作品身份。
///   拿缓存那一格去承载「已在本机」，用户会在某次系统清理或重新登录后发现标记凭空消失，
///   而那句标记是他亲手点出来的 —— 这是两个生命周期，不是一条腿的两段。
public actor WorkDownloadStore {
    private let transport: any PrivateAudioTransport
    private let credentials: any APICredentialProviding
    private let baseDirectory: URL
    private let fileManager: FileManager

    /// 在途合并（M7 同源教训）：同一作品双击下载只许打一次出口。
    /// `token` 用来「只摘掉自己那一条」—— 清理会整张表作废，
    /// 此后新起的保存不能被上一位的收尾误删。
    private struct InflightSave {
        let token: UInt64
        let task: Task<Result<WorkDownloadEntry, PlayerError>, Never>
    }

    private var inFlight: [String: InflightSave] = [:]
    private var nextSaveToken: UInt64 = 0

    public init(
        transport: any PrivateAudioTransport,
        credentials: any APICredentialProviding,
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.transport = transport
        self.credentials = credentials
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory()
        self.fileManager = fileManager
    }

    /// 默认落在 **Documents**（不是 Caches）：用户主动保存的资产不该被系统在空间紧张时清掉。
    public static func defaultBaseDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return documents.appendingPathComponent("Cova", isDirectory: true)
    }

    // MARK: - 保存

    /// 把一首作品的音频直存到沙盒，并记进本机清单。
    ///
    /// 硬顺序（任何一步失败都不产生清单条目）：
    /// 1. 身份与出口裁决（D23：生产出口才带凭证，名单桶一律**不带**凭证）；
    /// 2. 已有一份校验通过的文件 ⇒ 直接交回，**不再打一次出口**；
    /// 3. 落盘式传输写临时文件 → 校验非空/未截断 → 原子 move → 0600；
    /// 4. 写清单（owner 分桶，0600）。
    public func save(_ request: WorkDownloadRequest) async -> Result<WorkDownloadEntry, PlayerError> {
        if Task.isCancelled { return .failure(.cancelled) }
        guard let owner = request.session.owner else {
            // 清单必须按身份分桶（D8）：没有 owner 就没有可清除的归属，宁可不存。
            return .failure(.credentialUnavailable)
        }
        let target: URL
        let directory: URL
        do {
            directory = try WorkDownloadPath.ownerDirectory(base: baseDirectory, owner: owner)
            target = try WorkDownloadPath.fileURL(
                base: baseDirectory, owner: owner, workId: request.workId
            )
        } catch let error as PlayerError {
            return .failure(error)
        } catch {
            return .failure(.pathEscape)
        }

        // 已存且校验通过 ⇒ 复用（12d §8「同一曲目重复下载不重复创建」的作品版）。
        if let existing = validEntry(workId: request.workId, owner: owner, at: target) {
            return .success(existing)
        }

        // 在途合并：同一作品已有一路在跑 ⇒ 等它，不另起一次出站。
        if let running = inFlight[request.workId] {
            return await running.task.value
        }
        nextSaveToken += 1
        let token = nextSaveToken
        let task: Task<Result<WorkDownloadEntry, PlayerError>, Never> = Task { [weak self] in
            guard let self else { return .failure(.tornDown) }
            return await self.performSave(request, owner: owner, directory: directory, target: target)
        }
        inFlight[request.workId] = InflightSave(token: token, task: task)
        let outcome = await task.value
        if inFlight[request.workId]?.token == token { inFlight[request.workId] = nil }
        return outcome
    }

    private func performSave(
        _ request: WorkDownloadRequest,
        owner: PrincipalID,
        directory: URL,
        target: URL
    ) async -> Result<WorkDownloadEntry, PlayerError> {
        let source = request.source.value
        // D23 的初始裁决（本层自己判，传输层只管逐跳）：生产出口 ∪ 名单存储主机，其余一律拒。
        guard CovaEnvironment.isSanctionedMediaURL(source) else {
            return .failure(.hostRejected(host: CovaEnvironment.egressHostLabel(of: source)))
        }
        // **凭证只送到生产出口**：名单桶（`playbackUrl` 的预签名 COS 直链）本来就是免凭证的，
        // 把 Bearer 送过去等于拿名单当放行凭证的理由 —— D23 明令不许。
        let authorization: SecretString?
        if CovaEnvironment.isProductionOrigin(source) {
            guard let snapshot = try? await credentials.currentSession() else {
                return .failure(.credentialUnavailable)
            }
            authorization = snapshot.accessToken
        } else {
            authorization = nil
        }

        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: WorkDownloadPath.directoryAttributes
            )
            try fileManager.createDirectory(
                at: WorkDownloadPath.temporaryDirectory(base: baseDirectory),
                withIntermediateDirectories: true,
                attributes: WorkDownloadPath.directoryAttributes
            )
        } catch {
            return .failure(.writeFailed(PrivateAudioFetcher.status(of: error)))
        }

        let temporary = WorkDownloadPath.temporaryDirectory(base: baseDirectory)
            .appendingPathComponent(UUID().uuidString + ".part")
        let receipt: PrivateAudioReceipt
        do {
            receipt = try await transport.writeAudio(
                from: source, authorization: authorization, to: temporary,
                expectedBytes: request.expectedBytes
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            if Task.isCancelled || PrivateAudioFetcher.isCancellationShaped(error) {
                return .failure(.cancelled)
            }
            if let classified = error as? PlayerError { return .failure(classified) }
            return .failure(.writeFailed(PrivateAudioFetcher.status(of: error)))
        }
        guard !Task.isCancelled else {
            try? fileManager.removeItem(at: temporary)
            return .failure(.cancelled)
        }
        guard (200...299).contains(receipt.statusCode) else {
            try? fileManager.removeItem(at: temporary)
            return .failure(.badStatus(receipt.statusCode))
        }
        // D7 的「校验非空 + 拒绝截断」在这一条腿上同样成立（A6：非 0 字节）。
        guard receipt.bytesWritten > 0 else {
            try? fileManager.removeItem(at: temporary)
            return .failure(.emptyDownload)
        }
        if let expected = receipt.expectedBytes, expected != receipt.bytesWritten {
            try? fileManager.removeItem(at: temporary)
            return .failure(.truncated(expected: expected, actual: receipt.bytesWritten))
        }

        do {
            _ = try? fileManager.removeItem(at: target)
            try fileManager.moveItem(at: temporary, to: target)
            try fileManager.setAttributes(
                WorkDownloadPath.fileAttributes, ofItemAtPath: target.path
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .failure(.writeFailed(PrivateAudioFetcher.status(of: error)))
        }

        let entry = WorkDownloadEntry(
            workId: request.workId,
            jobId: WorkDownloadPath.jobId(ofWorkId: request.workId) ?? request.workId,
            candidateId: WorkDownloadPath.candidateId(ofWorkId: request.workId),
            title: request.title,
            artist: request.artist,
            duration: request.duration,
            fileName: WorkDownloadPath.fileName(forWorkId: request.workId),
            byteCount: receipt.bytesWritten,
            savedAt: Date()
        )
        appendEntry(entry, owner: owner)
        return .success(entry)
    }

    // MARK: - 查询与删除

    /// 本机清单 ∩ 盘上事实：**只回那些文件还在且非 0 字节的条目**
    /// （12d §7「列表事实源 = 本机沙盒存在且校验通过的文件」搬到作品直存这一腿）。
    ///
    /// 清单单独不足以作证 —— 系统清理、用户用「文件」App 删掉、上一次写坏，
    /// 都会让清单说「有」而盘上没有。行内的「已在本机」标记必须建立在盘上事实上。
    public func entries(owner: PrincipalID) -> [WorkDownloadEntry] {
        guard let stored = readManifest(owner: owner) else { return [] }
        return stored
            .filter { entry in
                guard let url = try? WorkDownloadPath.fileURL(
                    base: baseDirectory, owner: owner, workId: entry.workId
                ) else { return false }
                return Self.isValidFile(url, fileManager: fileManager)
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func entry(workId: String, owner: PrincipalID) -> WorkDownloadEntry? {
        entries(owner: owner).first { $0.workId == workId }
    }

    public func isSaved(workId: String, owner: PrincipalID) -> Bool {
        entry(workId: workId, owner: owner) != nil
    }

    /// 已存作品的本机地址（`file://`，无查询串）；不存在或已空 ⇒ nil。
    public func localFileURL(workId: String, owner: PrincipalID) -> AudioURL? {
        guard isSaved(workId: workId, owner: owner),
              let url = try? WorkDownloadPath.fileURL(
                  base: baseDirectory, owner: owner, workId: workId
              ) else { return nil }
        return try? AudioURL(file: url)
    }

    /// 删除本机文件与清单条目。
    ///
    /// 两条口径（都是为了不说假话）：
    /// · **本来就没有** ⇒ `false`。「删掉了一个真存在的东西」与「盘上确实没有」是两句话，
    ///   后者报成功会让 UI 的「已删除」提示变成谎言；
    /// · 删了之后盘上仍在 ⇒ `false`（宁可少报，不虚报；与 `purge(owner:)` 同一口径）。
    @discardableResult
    public func remove(workId: String, owner: PrincipalID) -> Bool {
        guard var stored = readManifest(owner: owner) else { return false }
        let hadEntry = stored.contains { $0.workId == workId }
        let target = try? WorkDownloadPath.fileURL(
            base: baseDirectory, owner: owner, workId: workId
        )
        let fileWasThere = target.map { Self.isValidFile($0, fileManager: fileManager) } ?? false
        guard hadEntry || fileWasThere else { return false }
        if let target {
            try? fileManager.removeItem(at: target)
            if Self.isValidFile(target, fileManager: fileManager) { return false }
        }
        stored.removeAll { $0.workId == workId }
        writeManifest(stored, owner: owner)
        return true
    }

    /// 登出 / 换号：该身份名下保存的作品文件与清单一并清掉（D8 防串号；与
    /// `PrivateAudioFetching.purge(owner:)` 同一条失效面）。返回**已确认删除**的条目数。
    @discardableResult
    public func purge(owner: PrincipalID) -> Int {
        let existing = entries(owner: owner)
        guard let directory = try? WorkDownloadPath.ownerDirectory(base: baseDirectory, owner: owner)
        else { return 0 }
        try? fileManager.removeItem(at: directory)
        var stillThere = 0
        if let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            stillThere = files.count
        }
        guard stillThere == 0 else { return 0 }
        return existing.count
    }

    // MARK: - 清单（Codable JSON，owner 分桶；**不含任何 URL**）

    private func manifestURL(owner: PrincipalID) -> URL? {
        try? WorkDownloadPath.ownerDirectory(base: baseDirectory, owner: owner)
            .appendingPathComponent(WorkDownloadPath.manifestName)
    }

    private func readManifest(owner: PrincipalID) -> [WorkDownloadEntry]? {
        guard let url = manifestURL(owner: owner),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([WorkDownloadEntry].self, from: data)
    }

    private func writeManifest(_ entries: [WorkDownloadEntry], owner: PrincipalID) {
        guard let url = manifestURL(owner: owner),
              let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(WorkDownloadPath.fileAttributes, ofItemAtPath: url.path)
    }

    private func appendEntry(_ entry: WorkDownloadEntry, owner: PrincipalID) {
        var stored = readManifest(owner: owner) ?? []
        stored.removeAll { $0.workId == entry.workId }
        stored.append(entry)
        writeManifest(stored, owner: owner)
    }

    private func validEntry(
        workId: String, owner: PrincipalID, at target: URL
    ) -> WorkDownloadEntry? {
        guard Self.isValidFile(target, fileManager: fileManager),
              let stored = readManifest(owner: owner)?.first(where: { $0.workId == workId })
        else { return nil }
        return stored
    }

    static func isValidFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }
}

/// 直存请求。**不含任何可持久化的敏感地址以外的东西**：`source` 是 `AudioURL`
/// （描述面恒脱敏），清单只落 `fileName` 与展示字段。
public struct WorkDownloadRequest: Equatable, Sendable {
    /// 作品身份 = 伪 trackId `{jobId}:{candidateId}`（与上报用的同一个 id）。
    public let workId: String
    public let title: String
    public let artist: String?
    public let duration: Double?
    /// 已解析成绝对 https 的音频地址（`audioUrl` 优先；缺则 `playbackUrl`）。
    public let source: AudioURL
    public let session: PlaybackSessionContext
    /// 已知的期望字节数（服务端给了 `Content-Length` 才有；用于拒绝截断）。
    public let expectedBytes: Int?

    public init(
        workId: String,
        title: String,
        artist: String? = nil,
        duration: Double? = nil,
        source: AudioURL,
        session: PlaybackSessionContext,
        expectedBytes: Int? = nil
    ) {
        self.workId = workId
        self.title = title
        self.artist = artist
        self.duration = duration
        self.source = source
        self.session = session
        self.expectedBytes = expectedBytes.map { max(0, $0) }
    }
}

/// 本机清单的一行。**只有本地文件名与展示字段** —— 没有 URL、没有签名串，
/// 因此它可以被编码落盘（硬边界 3 只禁签名地址进持久化索引，不禁本地文件名）。
public struct WorkDownloadEntry: Codable, Equatable, Sendable {
    public let workId: String
    public let jobId: String
    public let candidateId: String?
    public let title: String
    public let artist: String?
    public let duration: Double?
    public let fileName: String
    public let byteCount: Int
    public let savedAt: Date

    public init(
        workId: String, jobId: String, candidateId: String?, title: String, artist: String?,
        duration: Double?, fileName: String, byteCount: Int, savedAt: Date
    ) {
        self.workId = workId
        self.jobId = jobId
        self.candidateId = candidateId
        self.title = title
        self.artist = artist
        self.duration = duration
        self.fileName = fileName
        self.byteCount = byteCount
        self.savedAt = savedAt
    }
}

/// 目录与文件命名（纯函数：路径逃逸与非法 id 在这里 fail-closed）。
public enum WorkDownloadPath {
    /// 沙盒根下的作品直存目录名（与 `PrivateAudioPath.directoryName` 刻意不同名：
    /// 一个是可清的缓存，一个是用户保存的资产）。
    public static let directoryName = "cova-work-downloads"
    public static let temporaryDirectoryName = ".inflight"
    public static let manifestName = "manifest.json"
    /// 本地扩展名。服务端作品音频是 mp3（`worker.ts:256-260` 的 `/audio/<stem>_<hash>.mp3`），
    /// 而落盘传输的回执读不到 MIME ⇒ 用固定扩展名，**不假装**它是从响应头取来的。
    public static let fileExtension = "mp3"
    public static let fileMode = 0o600
    public static let directoryMode = 0o700

    public static var fileAttributes: [FileAttributeKey: Any] {
        [FileAttributeKey.posixPermissions: fileMode]
    }

    public static var directoryAttributes: [FileAttributeKey: Any] {
        [FileAttributeKey.posixPermissions: directoryMode]
    }

    /// owner 命名空间（hex，与 `PrivateAudioPath` 同一手法：原始字符不进文件系统）。
    public static func namespace(for owner: PrincipalID) -> String {
        PrivateAudioPath.namespace(for: owner)
    }

    public static func rootDirectory(base: URL) -> URL {
        base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func ownerDirectory(base: URL, owner: PrincipalID) throws -> URL {
        try OwnerIdentifier.requireValid(owner)
        let root = rootDirectory(base: base).standardizedFileURL
        let directory = root
            .appendingPathComponent(namespace(for: owner), isDirectory: true)
            .standardizedFileURL
        guard PrivateAudioPath.isInside(directory: root, url: directory) else {
            throw PlayerError.pathEscape
        }
        return directory
    }

    public static func temporaryDirectory(base: URL) -> URL {
        rootDirectory(base: base).appendingPathComponent(temporaryDirectoryName, isDirectory: true)
    }

    /// 文件名：`{jobId}-{candidateId}.mp3`（伪 id 里的 `:` 换掉 ——
    /// 它在 POSIX 上合法，但在「文件」App 与分享面板里会被显示成 `/`，是个纯坑）。
    public static func fileName(forWorkId workId: String) -> String {
        workId.replacingOccurrences(of: ":", with: "-") + "." + fileExtension
    }

    public static func jobId(ofWorkId workId: String) -> String? {
        guard let first = workId.split(separator: ":").first, !first.isEmpty else { return nil }
        return String(first)
    }

    public static func candidateId(ofWorkId workId: String) -> String? {
        let parts = workId.split(separator: ":")
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    public static func fileURL(base: URL, owner: PrincipalID, workId: String) throws -> URL {
        try PlaybackItem.validateIdentifier(workId)
        let root = rootDirectory(base: base).standardizedFileURL
        let directory = try ownerDirectory(base: base, owner: owner)
        let file = directory
            .appendingPathComponent(fileName(forWorkId: workId))
            .standardizedFileURL
        guard PrivateAudioPath.isInside(directory: root, url: file) else {
            throw PlayerError.pathEscape
        }
        return file
    }
}
