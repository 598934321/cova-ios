import Foundation

/// 音频地址的**结构性脱敏**载体（AGENTS 硬边界 3 / D7 / api-contracts §5）。
///
/// 存在理由：Bearer 换取的私有音频地址与签名 CDN 地址都是「拿到就能播」的敏感串。
/// 若它们以裸 `URL` 形态散落在模型里，就会被 `Codable` 写进持久化索引、被 `print` /
/// `XCTAssertEqual` 的描述支路带进日志。本类型把「可读」与「可序列化/可回显」拆开：
///
/// - **刻意不实现 `Codable`**（也不 `Encodable`）：编译期不存在把签名地址序列化落盘的通路；
/// - **`description` / `debugDescription` / `customMirror` 恒不回显 query 与 fragment**
///   （签名串位于 query；照 CovaCore `SecretString` 的手法处理反射面）；
/// - **`path` 也不回显**：部分 CDN 把签名放在路径段里（`/<sig>/<key>`），只保留 `scheme + host`；
/// - 明文只能经 `value` 显式取用，取用方承担「不落日志、不落文件」的责任。
public struct AudioURL: Hashable, Sendable {
    public enum Scheme: String, Hashable, Sendable, CaseIterable {
        case https
        case file
    }

    /// 拒绝原因（不携带被拒地址的任何片段）。
    public enum Rejection: Error, Equatable, Sendable, CustomStringConvertible {
        case missingScheme
        case unsupportedScheme(String)
        case missingHost
        case credentialsInURL
        case httpsURLWithoutAbsolutePath
        case fileURLWithoutFilePath
        case fileURLCarriesQuery

        public var description: String {
            switch self {
            case .missingScheme: return "地址缺少 scheme"
            case .unsupportedScheme(let scheme): return "不支持的 scheme：\(scheme)"
            case .missingHost: return "https 地址缺少 host"
            case .credentialsInURL: return "地址内嵌 userinfo（禁止凭证进 URL）"
            case .httpsURLWithoutAbsolutePath: return "https 地址缺少绝对路径"
            case .fileURLWithoutFilePath: return "file 地址缺少路径"
            case .fileURLCarriesQuery: return "file 地址不得携带查询/片段（签名串禁止进本地地址）"
            }
        }
    }

    private let url: URL
    public let scheme: Scheme

    /// 公开 https 直链（曲库音频 / 封面）。要求 scheme=https、有 host、有绝对路径、无 userinfo。
    public init(https url: URL) throws {
        guard let rawScheme = url.scheme else { throw Rejection.missingScheme }
        guard rawScheme.lowercased() == Scheme.https.rawValue else {
            throw Rejection.unsupportedScheme(rawScheme)
        }
        guard url.host?.isEmpty == false else { throw Rejection.missingHost }
        guard url.user == nil, url.password == nil else { throw Rejection.credentialsInURL }
        guard url.path.isEmpty == false, url.path.hasPrefix("/") else {
            throw Rejection.httpsURLWithoutAbsolutePath
        }
        self.url = url
        scheme = .https
    }

    /// 沙盒本地地址（私有音频落盘后）。要求 scheme=file、有路径、**无 query/fragment**。
    public init(file url: URL) throws {
        guard let rawScheme = url.scheme else { throw Rejection.missingScheme }
        guard rawScheme.lowercased() == Scheme.file.rawValue else {
            throw Rejection.unsupportedScheme(rawScheme)
        }
        guard url.path.isEmpty == false else { throw Rejection.fileURLWithoutFilePath }
        // 空查询（nil 或 ""）算合法；任何非空 query/fragment 一律拒绝（签名串就住在那里）。
        guard url.query.flatMap({ $0.isEmpty ? nil : $0 }) == nil,
              url.fragment.flatMap({ $0.isEmpty ? nil : $0 }) == nil else {
            throw Rejection.fileURLCarriesQuery
        }
        self.url = url
        scheme = .file
    }

    /// 明文地址：仅供真正交给播放器 / 构造请求时使用。
    public var value: URL { url }

    /// 是否本地沙盒地址（私有音频必须先本地化，播放器只接受 `file` 或公开直链）。
    public var isLocalized: Bool { scheme == .file }
}

// MARK: - 回显面（脱敏）

extension AudioURL: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `scheme://host/<redacted>`：query / fragment / path 一律不回显。
    public var description: String {
        switch scheme {
        case .file:
            return "file://<local>"
        case .https:
            let host = url.host()?.lowercased() ?? "<no-host>"
            return "https://\(host)/<redacted>"
        }
    }

    public var debugDescription: String { description }

    /// 反射面同样脱敏：`dump()` / `Mirror(reflecting:)` 拿不到 query。
    public var customMirror: Mirror {
        Mirror(self, children: ["description": description], displayStyle: .struct)
    }
}

// MARK: - 曲目身份

/// 一次可播放条目的身份值类型（不含任何可持久化的敏感地址）。
///
/// 设计约束：
/// - **不实现 `Codable`**：`audioSource` 里的地址不可持久化，整个条目因此不可序列化；
///   队列/播放态要落盘必须由上层重新换取地址（D7「Bearer URL 不进持久化索引」）。
/// - `duration` 可选：契约里有值，但私有候选与引擎实测前可能未知（±15s 需要区分该形态）。
public struct PlaybackItem: Hashable, Sendable {
    /// 音频来源判别式：决定「能不能直接把地址交给播放器」。
    public enum AudioSource: Hashable, Sendable {
        /// 公开直链（曲库音频，无需凭证，可匿名流播）。
        case publicDirect(AudioURL)
        /// 需 Bearer 的私有地址：**禁止**直接交给播放器，必须先经 `PrivateAudioFetching` 本地化。
        case bearerRequired(AudioURL)
        /// 已落盘的沙盒地址（`file://`），可直接播。
        case localized(AudioURL)
    }

    /// 条目性质：决定播放上报与合规行为（design/screens/02-player.md §8）。
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// 曲库曲目：上报播放（`source: "app-ios"`）。
        case libraryTrack
        /// 生成候选私有音频：**不上报**、不收藏。
        case privateCandidate
    }

    /// 曲目 id 的字符白名单口径（同时是缓存文件名的安全口径，fail-closed）。
    public static let maximumIdentifierByteLength = 120

    public let id: String
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: Double?
    public let coverURL: AudioURL?
    public let audioSource: AudioSource
    public let kind: Kind

    public init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: Double? = nil,
        coverURL: AudioURL? = nil,
        audioSource: AudioSource,
        kind: Kind = .libraryTrack
    ) throws {
        try Self.validateIdentifier(id)
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = Self.validatedDuration(duration)
        self.coverURL = coverURL
        self.audioSource = audioSource
        self.kind = kind
    }

    /// 时长归一：非有限值 / 非正值一律视为「未知」（避免把 NaN 带进钳制计算）。
    static func validatedDuration(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        return raw
    }

    /// 曲目 id 校验：非空、仅 `[A-Za-z0-9_-]`、长度受限、拒绝 `.` / `..`。
    ///
    /// 该 id 会参与缓存文件名与幂等关联，故此处就收紧（路径逃逸与头部注入的源头治理）。
    public static func validateIdentifier(_ id: String) throws {
        if id.isEmpty { throw IdentifierRejection.emptyIdentifier }
        if id == "." || id == ".." { throw IdentifierRejection.reservedIdentifier }
        if id.utf8.count > PlaybackItem.maximumIdentifierByteLength {
            throw IdentifierRejection.identifierTooLong
        }
        for scalar in id.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x30 && v <= 0x39)
                || v == 0x2D || v == 0x5F
            if !ok { throw IdentifierRejection.identifierCharacter }
        }
    }

    /// id 相关的结构性拒绝原因（与地址的 `Rejection` 分开，互不污染描述）。
    public enum IdentifierRejection: Error, Equatable, Sendable, CustomStringConvertible {
        case emptyIdentifier
        case reservedIdentifier
        case identifierTooLong
        case identifierCharacter

        public var description: String {
            switch self {
            case .emptyIdentifier: return "曲目 id 为空"
            case .reservedIdentifier: return "曲目 id 为保留路径段"
            case .identifierTooLong: return "曲目 id 超过 \(maximumIdentifierByteLength) 字节"
            case .identifierCharacter: return "曲目 id 含白名单外字符"
            }
        }
    }
}

extension PlaybackItem {
    /// 该条目是否需要先本地化才能播放（D7 硬规则的唯一判据）。
    public var requiresLocalization: Bool {
        if case .bearerRequired = audioSource { return true }
        return false
    }

    /// 当前是否具备「可直接交给播放器」的地址（公开直链或已本地化）。
    public var isReadyToStream: Bool {
        switch audioSource {
        case .publicDirect, .localized: return true
        case .bearerRequired: return false
        }
    }

    /// 直接可播地址（需 Bearer 时返回 nil —— 不存在绕过本地化的路径）。
    public var playableURL: AudioURL? {
        switch audioSource {
        case .publicDirect(let url), .localized(let url): return url
        case .bearerRequired: return nil
        }
    }

    /// 以本地化地址替换来源（下载完成后由 facade 调用；返回新值，不破坏不可变性）。
    public func localized(to url: AudioURL) -> PlaybackItem {
        PlaybackItem(
            validatedID: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            coverURL: coverURL,
            audioSource: .localized(url),
            kind: kind
        )
    }
}

extension PlaybackItem {
    /// 派生构造：`id` 来自已通过校验的实例，不重复校验。
    ///
    /// **internal**：包外唯一入口是 throwing `init`（fail-closed 不被绕过）。
    init(
        validatedID id: String,
        title: String,
        artist: String,
        album: String?,
        duration: Double?,
        coverURL: AudioURL?,
        audioSource: AudioSource,
        kind: Kind
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = Self.validatedDuration(duration)
        self.coverURL = coverURL
        self.audioSource = audioSource
        self.kind = kind
    }
}
