import CovaCore
import Foundation

/// 私有音频取回请求（D7 硬规则的唯一入口形态）。
///
/// 安全：`source` 是 `AudioURL`（不回显 query），`session` 决定 owner 目录与在途作废；
/// 本类型 **不实现 `Codable`** —— 请求（含地址）不可持久化。
public struct PrivateAudioRequest: Equatable, Sendable {
    public let itemID: String
    /// 需 Bearer 的私有地址（必须落在 `CovaEnvironment.isProductionOrigin` 上）。
    public let source: AudioURL
    public let session: PlaybackSessionContext
    /// 响应若声明长度，则以此校验完成性（拒绝截断）。
    public let expectedBytes: Int?

    public init(
        itemID: String,
        source: AudioURL,
        session: PlaybackSessionContext,
        expectedBytes: Int? = nil
    ) {
        self.itemID = itemID
        self.source = source
        self.session = session
        self.expectedBytes = expectedBytes.map { max(0, $0) }
    }
}

/// 私有音频取回与 owner 维度清理（D7 / D8 / api-contracts §5）。
public protocol PrivateAudioFetching: Sendable {
    /// 先把 Bearer 音频**流式写入沙盒**并校验完成性，再返回 `file://` 地址。
    func localizedURL(for request: PrivateAudioRequest) async -> Result<AudioURL, PlayerError>
    /// 清除某 owner 的全部私有音频（登出 / 换号）。
    /// 返回**已确认删除**的文件数：owner 非法 → 0；删除后路径仍在 → 0（宁可少报，不可虚报）。
    @discardableResult func purge(owner: PrincipalID) async -> Int
    /// 清除不属于给定 generation 的私有音频（在途旧代次结果不得被复用）。
    /// 返回**已确认删除**的文件数（口径同 `purge(owner:)`）。
    ///
    /// 作用域是**当前凭证快照的那个 owner**（环 4 · 第 6 批 min-5）：代次是账号内部的事实，
    /// 跨 owner 扫描会把别的账号的旧代次文件一起删掉。凭证不可知时一律不删（fail-closed）。
    @discardableResult func purgeStale(before generation: SessionGeneration) async -> Int
    /// 全量清除（teardown）。返回**已确认删除**的文件数（口径同 `purge(owner:)`）。
    @discardableResult func purgeAll() async -> Int
}

/// 播放源准备器：`PlaybackCoordinator` 装载前的「可直接播」关口。
///
/// 存在的意义是把 D7 写进类型：协调器只能拿到 `PlaybackItem`，
/// 而「需 Bearer 的条目未经本地化就被播放」这条路径由此协议把守（无绕过入口）。
public protocol PlaybackSourcePreparing: Sendable {
    func prepareSource(
        for item: PlaybackItem,
        session: PlaybackSessionContext
    ) async -> Result<PlaybackItem, PlayerError>

    /// 会话失效（登出 / 换号 / generation 推进）时丢弃私有音频（D8 / 缺陷 F-13）。
    ///
    /// 写进协议而不是留给调用方「记得去够实现方的 purge」：门面与协调器只有本协议视图，
    /// 清理因此是**装配面必然触达**的一步，而不是可选动作。
    ///
    /// - Parameter owner: 要清除的那个身份；`nil` 表示「身份已不可知」→ 全量清除。
    ///
    /// **必须实现**（环 4 · 第 6 批 MAJ-2）：这里曾有
    /// `public extension PlaybackSourcePreparing { func discardPrivateAudio(owner:) async {} }`
    /// 的默认空实现，于是「第二个会往磁盘写私有音频的准备器」只要忘记覆盖，就能让登出
    /// 静默变成空操作 —— 门面调用了、协议满足了、盘上的字节一个都没动（D8 / api-contracts §5 违例）。
    /// 默认实现删除后，漏覆盖 = 编译不过；「没有磁盘副作用」的实现也必须显式写一行空操作，
    /// 那一行就是它的免责申明。
    func discardPrivateAudio(owner: PrincipalID?) async
}

/// owner 目录与文件命名（缓存键含 `PrincipalID`，跨账号互不可见）。
///
/// 纯函数：路径逃逸与非法 id 在这里 fail-closed，可 100% 单测。
public enum PrivateAudioPath {
    /// 沙盒根下的私有音频目录名。
    public static let directoryName = "cova-private-audio"
    /// 临时分片目录（原子 move 前的落点）。
    public static let temporaryDirectoryName = ".inflight"
    /// 本地文件扩展名（不含任何地址信息）。
    public static let fileExtension = "covaud"
    /// 代次分隔符：`<itemID>@g<generation>`。
    static let generationSeparator = "@g"
    /// 落盘文件权限位（m12）：只有 owner 可读写 —— 缓存里装的是「仅本人可见」的音频字节，
    /// 组/其它可读位一个都不给。传输层建文件与准备器提交时共用这一个口径。
    public static let fileMode = 0o600
    /// `fileMode` 的 `FileAttributeKey` 形态。
    public static var fileAttributes: [FileAttributeKey: Any] {
        [FileAttributeKey.posixPermissions: fileMode]
    }

    /// owner 命名空间（hex，避免任何原始字符进入文件系统）。
    public static func namespace(for owner: PrincipalID) -> String {
        owner.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
    }

    public static func rootDirectory(base: URL) -> URL {
        base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func ownerDirectory(base: URL, owner: PrincipalID) -> URL {
        rootDirectory(base: base).appendingPathComponent(namespace(for: owner), isDirectory: true)
    }

    public static func temporaryDirectory(base: URL) -> URL {
        rootDirectory(base: base).appendingPathComponent(temporaryDirectoryName, isDirectory: true)
    }

    /// 文件名：只由 `itemID` 与 generation 构成 —— **不含** host、path、query、token。
    public static func fileName(itemID: String, generation: SessionGeneration) -> String {
        itemID + generationSeparator + String(generation.value) + "." + fileExtension
    }

    /// 从文件名解析 generation（解析失败视为「不属于任何在册代次」）。
    public static func generation(infileName name: String) -> SessionGeneration? {
        guard let range = name.range(of: generationSeparator) else { return nil }
        let tail = name[range.upperBound...]
        guard let dot = tail.firstIndex(of: "."), let value = UInt64(tail[..<dot]) else { return nil }
        return SessionGeneration(value: value)
    }

    /// 目标文件 URL（含路径逃逸守卫）。
    public static func fileURL(
        base: URL,
        owner: PrincipalID,
        itemID: String,
        generation: SessionGeneration
    ) throws -> URL {
        try OwnerIdentifier.requireValid(owner)
        try PlaybackItem.validateIdentifier(itemID)
        let root = rootDirectory(base: base).standardizedFileURL
        let directory = ownerDirectory(base: base, owner: owner).standardizedFileURL
        guard isInside(directory: root, url: directory) else { throw PlayerError.pathEscape }
        let file = directory.appendingPathComponent(fileName(itemID: itemID, generation: generation))
            .standardizedFileURL
        guard isInside(directory: root, url: file) else { throw PlayerError.pathEscape }
        return file
    }

    /// `url` 是否严格位于 `directory` 之内（含 `..` / 百分号编码的逃逸都已由 standardized 收敛）。
    public static func isInside(directory: URL, url: URL) -> Bool {
        let parent = directory.path
        let child = url.path
        guard child.count > parent.count else { return false }
        return child.hasPrefix(parent + "/")
    }
}
