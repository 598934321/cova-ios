import Foundation

/// 幂等写操作的作用域（api-contracts §2/§3/§4；D8）。
///
/// 每次枚举值对应一个**需要幂等键的写端点**：
/// - `downloadCheckout` → `POST /api/downloads/checkout`（扣费）
/// - `planStart` → `POST /api/studio/one-step/plans/start`（启动制作）
/// - `playReport` → `POST /api/tracks/play`（播放上报）
public enum IdempotentOperation: String, CaseIterable, Codable, Sendable {
    case downloadCheckout = "download-checkout"
    case planStart = "plan-start"
    case playReport = "play-report"

    /// 幂等键前缀（`cova-<operation>-`）。
    public var keyPrefix: String { "cova-\(rawValue)-" }
}

/// 幂等键校验错误（不携带键内容，避免把控制字符/注入串回显到日志）。
public enum IdempotencyKeyError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case tooShort(minimum: Int)
    case tooLong(maximum: Int)
    case controlCharacters
    case invalidCharacters
    /// operation 与 key 前缀不匹配（如 operation=playReport 却用 checkout 的键）。
    case operationMismatch

    public var description: String {
        switch self {
        case .empty: return "幂等键为空"
        case .tooShort(let minimum): return "幂等键过短（下限 \(minimum)）"
        case .tooLong(let maximum): return "幂等键过长（上限 \(maximum)）"
        case .controlCharacters: return "幂等键含控制字符"
        case .invalidCharacters: return "幂等键含非法字符"
        case .operationMismatch: return "幂等键与操作类型不匹配"
        }
    }
}

/// 幂等键值类型。
///
/// 格式：`cova-<operation>-<32 位小写 hex>`（由 16 个密码学随机字节编码）。
/// 键本身**不是**凭证，可安全出现在日志/持久化索引中（不含 token/签名 URL）。
///
/// 运行时校验（构造/解码均 fail-closed）：
/// - 非空；UTF-8 字节数 `minimumLength...maximumLength`；
/// - 仅允许 `[A-Za-z0-9_-]`；拒绝控制字符（含 CR/LF，防头部注入）与其它符号。
public struct IdempotencyKey: Hashable, Sendable, CustomStringConvertible, Codable {
    public static let minimumLength = 8
    public static let maximumLength = 128

    public let rawValue: String

    /// 校验式构造（唯一公开入口）：不合法即抛 `IdempotencyKeyError`。
    public init(validating rawValue: String) throws {
        try IdempotencyKey.validate(rawValue)
        self.rawValue = rawValue
    }

    /// 生成器专用：输入由本类型生成，恒为规范形态。
    init(generated rawValue: String) {
        self.rawValue = rawValue
    }

    public static func validate(_ raw: String) throws {
        if raw.isEmpty { throw IdempotencyKeyError.empty }
        let byteCount = raw.utf8.count
        if byteCount < minimumLength { throw IdempotencyKeyError.tooShort(minimum: minimumLength) }
        if byteCount > maximumLength { throw IdempotencyKeyError.tooLong(maximum: maximumLength) }
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F { throw IdempotencyKeyError.controlCharacters }
            let allowed = (value >= 0x61 && value <= 0x7A)
                || (value >= 0x41 && value <= 0x5A)
                || (value >= 0x30 && value <= 0x39)
                || value == 0x2D || value == 0x5F
            if !allowed { throw IdempotencyKeyError.invalidCharacters }
        }
    }

    public var description: String { rawValue }

    /// 该键是否符合指定 operation 的规范形态（前缀 + 32 位小写 hex）。
    public func isCanonical(for operation: IdempotentOperation) -> Bool {
        let prefix = operation.keyPrefix
        guard rawValue.hasPrefix(prefix) else { return false }
        let suffix = rawValue.dropFirst(prefix.count)
        guard suffix.count == IdempotencyKeyGenerator.hexLength else { return false }
        return suffix.allSatisfy(IdempotencyKeyGenerator.isLowercaseHexDigit)
    }

    // MARK: - Codable（编解码为 JSON string）

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            try self.init(validating: raw)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效幂等键")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 幂等键生成器。
///
/// 生成策略：从 `SystemRandomNumberGenerator` 取 16 个随机字节 → 32 位小写 hex。
/// 生成器可注入（`using:`）以便测试确定性与并发行为；
/// **重试/重放不得调用生成器** —— 一次逻辑操作生成一次键，之后复用同一个 `IdempotencyKey`。
public enum IdempotencyKeyGenerator {
    /// 随机字节数（16 → 128 bit，碰撞概率可忽略）。
    public static let randomByteCount = 16
    /// hex 字符串长度（= `randomByteCount * 2`）。
    public static let hexLength = randomByteCount * 2

    /// 生成一次逻辑操作的幂等键。
    public static func generate(for operation: IdempotentOperation) -> IdempotencyKey {
        var generator = SystemRandomNumberGenerator()
        return generate(for: operation, using: &generator)
    }

    /// 注入随机源生成（测试用；生产请用 `generate(for:)`）。
    public static func generate<G: RandomNumberGenerator>(
        for operation: IdempotentOperation,
        using generator: inout G
    ) -> IdempotencyKey {
        var bytes = [UInt8]()
        bytes.reserveCapacity(randomByteCount)
        for _ in 0..<randomByteCount {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return IdempotencyKey(generated: operation.keyPrefix + hexString(bytes))
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    /// 小写 hex 判定（`Character.isHexDigit` 也接受大写，规范形态只允许小写）。
    static func isLowercaseHexDigit(_ character: Character) -> Bool {
        switch character {
        case "0"..."9", "a"..."f": return true
        default: return false
        }
    }
}

/// 一次逻辑写操作的幂等凭据。
///
/// 语义（D8）：
/// - **构造 token 一次 = 生成一个键**；
/// - 该逻辑操作的所有重试/重放都必须复用 `key`（不要为每次重试新建 token）；
/// - 新的逻辑操作必须新建 token（得到新键）。
/// - 显式指定键的构造会校验 `operation` 与 `key` 前缀一致（防串操作类型）。
public struct IdempotentRequestToken: Hashable, Sendable {
    public let operation: IdempotentOperation
    public let key: IdempotencyKey

    public init(operation: IdempotentOperation) {
        self.operation = operation
        self.key = IdempotencyKeyGenerator.generate(for: operation)
    }

    /// 显式指定键（测试/从已持久化的操作恢复时使用）；前缀不匹配即抛 `operationMismatch`。
    public init(operation: IdempotentOperation, key: IdempotencyKey) throws {
        guard key.isCanonical(for: operation) else {
            throw IdempotencyKeyError.operationMismatch
        }
        self.operation = operation
        self.key = key
    }
}
