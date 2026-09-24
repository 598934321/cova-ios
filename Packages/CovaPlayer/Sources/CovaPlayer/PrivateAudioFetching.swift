import CovaCore
import Foundation

/// 缓存对象的**内容形态**（R16-1b：同一条目的「预览段」与「整曲」不是同一份字节）。
///
/// 为什么需要一个由调用方声明的形态，而不是从地址里读出来（2026-09-24 只读核对
/// `web` 仓 `src/lib/api-dto.ts:131-137`、`src/app/api/tracks/[id]/preview-stream/route.ts:47-98`
/// 与 `src/lib/catalog-audio-url.ts`）：
/// · 库曲 `audioUrl` 一律是**同一个**站内端点 `/api/tracks/<id>/preview-stream`；
/// · 未授权 → 200 只发预览时间窗裁剪出的那段字节；已授权 → 302 到整曲桶；
/// · 曲目 DTO 里**没有**任何长度 / 字节数 / 「预览还是整曲」字段（实测 `duration` 178.84s，
///   而缓存对象是 19.56s 的预览段）。
/// ⇒ 客户端手上没有可判别的信息，那就**不许**把「同一条目、同一代次」当成同一份内容：
/// 形态由调用方显式声明，未声明（`.unspecified`）时缓存复用整条腿关闭。
/// 旧形态下购买发生后旧预览段会被无限复用，且一次失败都不报 —— 用户听到的永远是试听片段。
public enum PrivateAudioContentKind: String, Hashable, Sendable, CaseIterable {
    /// 调用方声明「这就是该条目的完整音频」（生成候选、笔记音频）。可复用缓存。
    case full
    /// 服务端裁剪过的预览段（有明确的「这一份只是片段」的来源）。可复用缓存，但与 `.full` 不同件。
    case preview
    /// 调用方**无法判别**手里是哪一份（库曲：预览与整曲共用一个端点，且没有长度字段）。
    /// ⇒ 每次装载都重新取回：宁可多打一次出口，也不把旧预览段当作整曲交付。
    case unspecified

    /// 参与缓存文件名的形态段（不含地址、host、query、token —— 见 `PrivateAudioPath.fileName`）。
    var pathToken: String {
        switch self {
        case .full: return "full"
        case .preview: return "preview"
        case .unspecified: return "unknown"
        }
    }

    /// 该形态下缓存对象可否被复用（`.unspecified` = 不可，这是本类型唯一的裁决面）。
    var allowsCacheReuse: Bool { self != .unspecified }
}

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
    /// 内容形态：进入缓存身份（同一 itemID / 同一代次下，形态不同 = 不同的两份字节）。
    public let contentKind: PrivateAudioContentKind

    public init(
        itemID: String,
        source: AudioURL,
        session: PlaybackSessionContext,
        expectedBytes: Int? = nil,
        contentKind: PrivateAudioContentKind = .full
    ) {
        self.itemID = itemID
        self.source = source
        self.session = session
        self.expectedBytes = expectedBytes.map { max(0, $0) }
        self.contentKind = contentKind
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
    /// 代次分隔符：`<itemID>#<形态>@g<generation>`。
    static let generationSeparator = "@g"
    /// 形态分隔符（R16-1b）：`#` 不在 `PlaybackItem` 的 id 白名单里，因此不可能与 itemID 相撞。
    static let kindSeparator = "#"
    /// 落盘文件权限位（m12）：只有 owner 可读写 —— 缓存里装的是「仅本人可见」的音频字节，
    /// 组/其它可读位一个都不给。传输层建文件与准备器提交时共用这一个口径。
    public static let fileMode = 0o600
    /// `fileMode` 的 `FileAttributeKey` 形态。
    public static var fileAttributes: [FileAttributeKey: Any] {
        [FileAttributeKey.posixPermissions: fileMode]
    }
    /// 目录权限位（min-1）：与文件位同口径收紧到「仅 owner 可进入」。
    ///
    /// 旧实现只收了文件位（0600），目录仍是 0755 —— 于是别的进程虽然读不到音频字节，
    /// 却能 `ls` 出「哪个账号（hex 命名空间）缓存过哪些曲目、在第几代、是哪一种形态」
    /// （文件名本身就是 `<itemID>#<形态>@g<generation>`）。元数据泄漏也是泄漏，
    /// D7/AGENTS 硬边界 3 不区分这两件事。
    public static let directoryMode = 0o700
    /// `directoryMode` 的 `FileAttributeKey` 形态。
    public static var directoryAttributes: [FileAttributeKey: Any] {
        [FileAttributeKey.posixPermissions: directoryMode]
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

    /// 文件名：只由 `itemID`、**内容形态** 与 generation 构成 —— 不含 host、path、query、token。
    ///
    /// 形态段（R16-1b）是缓存身份的一部分：`<itemID>#full@g3` 与 `<itemID>#preview@g3`
    /// 是两条不同的字节，永远不可能互相顶替。
    public static func fileName(
        itemID: String,
        generation: SessionGeneration,
        kind: PrivateAudioContentKind = .full
    ) -> String {
        itemID + kindSeparator + kind.pathToken
            + generationSeparator + String(generation.value) + "." + fileExtension
    }

    /// 从文件名解析 generation（解析失败视为「不属于任何在册代次」）。
    ///
    /// 形态段住在 `#` 与 `@g` **之间**，所以这里取的尾段仍以代次数字开头 —— 旧命名
    /// （`<itemID>@g<N>`，R16-1b 之前）照样能解析出来，于是 `purgeStale` 会把换命名前
    /// 留下的孤儿对象一并扫掉（它们再也无法被任何请求命中，留着就是死字节）。
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
        generation: SessionGeneration,
        kind: PrivateAudioContentKind = .full
    ) throws -> URL {
        try OwnerIdentifier.requireValid(owner)
        try PlaybackItem.validateIdentifier(itemID)
        let root = rootDirectory(base: base).standardizedFileURL
        let directory = ownerDirectory(base: base, owner: owner).standardizedFileURL
        guard isInside(directory: root, url: directory) else { throw PlayerError.pathEscape }
        let file = directory
            .appendingPathComponent(fileName(itemID: itemID, generation: generation, kind: kind))
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
