import CovaCore
import Foundation

/// 私有音频本地化器（D7 硬规则的实现）。
///
/// 硬性顺序（任何一步失败都不产生可播地址）：
/// 1. owner 与 generation 必须与凭证快照一致（防跨账号 / 防在途旧代次）；
/// 2. 出站主机必须是 `CovaEnvironment.isProductionOrigin`（唯一网络出口，D10）；
/// 3. 经**落盘式**传输流式写入临时文件（`HTTPTransport` 整包返回 Data，故不复用它）；
/// 4. 校验完成性：字节数 > 0，且响应声明长度时必须相等（拒绝空文件与截断）；
/// 5. 原子 `move` 到 owner 目录，返回 `file://`；
/// 6. 全程不把带 Bearer/签名查询的 https 地址交给播放器，也不写日志。
public actor PrivateAudioFetcher: PrivateAudioFetching, PlaybackSourcePreparing {
    private let transport: any PrivateAudioTransport
    private let credentials: any APICredentialProviding
    private let baseDirectory: URL
    private let fileManager: FileManager

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
        switch await sessionBinding(for: request) {
        case .success:
            break
        case .failure(let error):
            return .failure(error)
        }
        guard case .https = request.source.scheme else {
            return .failure(.hostRejected)
        }
        guard CovaEnvironment.isProductionOrigin(request.source.value) else {
            return .failure(.hostRejected)
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
                generation: request.session.generation
            )
        } catch let error as PlayerError {
            return .failure(error)
        } catch {
            return .failure(.pathEscape)
        }

        if let cached = existingValidFile(at: target, expectedBytes: request.expectedBytes) {
            return .success(cached)
        }

        let temporary = temporaryURL()
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
            // 提交前复核会话：下载途中登出/换号则丢弃（旧代次结果绝不落库）。
            switch await sessionBinding(for: request) {
            case .success:
                break
            case .failure(let error):
                removeItem(at: temporary)
                return .failure(error)
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
            return .failure(.writeFailed(Self.status(of: error)))
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
            session: session
        )) {
        case .success(let localized):
            return .success(item.localized(to: localized))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - 清理（D8：登出/换号清私有音频）

    @discardableResult
    public func purge(owner: PrincipalID) -> Int {
        let directory = PrivateAudioPath.ownerDirectory(base: baseDirectory, owner: owner)
        let count = fileCount(in: directory)
        removeItem(at: directory)
        return count
    }

    @discardableResult
    public func purgeStale(before generation: SessionGeneration) -> Int {
        let root = PrivateAudioPath.rootDirectory(base: baseDirectory)
        guard let owners = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for ownerDirectory in owners where fileManager.fileExists(atPath: ownerDirectory.path) {
            guard let files = try? fileManager.contentsOfDirectory(
                at: ownerDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files {
                let stored = PrivateAudioPath.generation(infileName: file.lastPathComponent)
                guard let stored, stored < generation else { continue }
                removed += 1
                removeItem(at: ownerDirectory.appendingPathComponent(file.lastPathComponent))
            }
        }
        return removed
    }

    @discardableResult
    public func purgeAll() -> Int {
        let root = PrivateAudioPath.rootDirectory(base: baseDirectory)
        let count = fileCount(in: root)
        removeItem(at: root)
        return count
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
        return try? AudioURL(file: url)
    }

    private func temporaryURL() -> URL {
        PrivateAudioPath.temporaryDirectory(base: baseDirectory)
            .appendingPathComponent(UUID().uuidString.lowercased() + ".part")
    }

    private func prepareDirectories(owner: PrincipalID) throws {
        try createDirectory(PrivateAudioPath.ownerDirectory(base: baseDirectory, owner: owner))
        try createDirectory(PrivateAudioPath.temporaryDirectory(base: baseDirectory))
    }

    private func createDirectory(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) == false else { return }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw PlayerError.writeFailed(Self.status(of: error))
        }
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
    }

    private func removeItem(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        // 清理失败不影响判定：文件仍在 owner 目录内，purge/teardown 会兜底。
        try? fileManager.removeItem(at: url)
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
