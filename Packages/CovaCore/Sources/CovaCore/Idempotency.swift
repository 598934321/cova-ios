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

/// 幂等键值类型。
///
/// 格式：`cova-<operation>-<32 位小写 hex>`（由 16 个密码学随机字节编码）。
/// 键本身**不是**凭证，可安全出现在日志/持久化索引中（不含 token/签名 URL）。
public struct IdempotencyKey: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
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
        return IdempotencyKey(rawValue: operation.keyPrefix + hexString(bytes))
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
public struct IdempotentRequestToken: Hashable, Sendable {
    public let operation: IdempotentOperation
    public let key: IdempotencyKey

    public init(operation: IdempotentOperation) {
        self.operation = operation
        self.key = IdempotencyKeyGenerator.generate(for: operation)
    }

    /// 显式指定键（测试/从已持久化的操作恢复时使用）。
    public init(operation: IdempotentOperation, key: IdempotencyKey) {
        self.operation = operation
        self.key = key
    }
}
