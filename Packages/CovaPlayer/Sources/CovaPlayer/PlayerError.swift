import Foundation

/// 播放器层对外错误。
///
/// **安全（AGENTS 硬边界 3 / D7）**：所有 case 的关联值都只允许是
/// 结构性原因、主机名、字节数或曲目 id —— **类型层面不存在 URL / header / token 字段**，
/// 因此错误进入日志、`print`、`XCTAssert` 描述支路时都不可能带出签名地址或凭证。
public enum PlayerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 队列为空 / 无当前项。
    case noCurrentItem
    /// 队列索引越界。
    case indexOutOfRange(Int)
    /// 队列中不存在该曲目。
    case unknownItem(String)
    /// 播放引擎未就绪。
    case engineNotReady
    /// 私有音频未完成本地化就被要求播放（D7 硬规则）。
    case notLocalized(String)
    /// 出站主机被拒绝（只允许 `CovaEnvironment.isProductionOrigin`）。
    case hostRejected
    /// 下载到的字节数为 0（空文件）。
    case emptyDownload
    /// 下载字节数与响应声明的期望长度不符（截断）。
    case truncated(expected: Int, actual: Int)
    /// 响应状态码非 2xx。
    case badStatus(Int)
    /// 缓存文件名/路径逃逸：解析出的目标不在该 owner 的缓存根内。
    case pathEscape
    /// 凭证读取失败（不含任何凭证内容）。
    case credentialUnavailable
    /// 本地化写入失败（仅携带系统错误码）。
    case writeFailed(Int32)
    /// 会话代次已过期（登出/换号后到达的在途结果）。
    case staleSession
    /// 操作被取消。
    case cancelled
    /// 生命周期已 teardown，拒绝新操作。
    case tornDown

    public var description: String {
        switch self {
        case .noCurrentItem: return "无当前播放项"
        case .indexOutOfRange(let index): return "队列索引越界：\(index)"
        case .unknownItem(let id): return "队列中不存在曲目：\(id)"
        case .engineNotReady: return "播放引擎未就绪"
        case .notLocalized(let id): return "私有音频尚未本地化：\(id)"
        case .hostRejected: return "出站地址被拒绝（非生产出口）"
        case .emptyDownload: return "下载结果为空文件（0 字节）"
        case .truncated(let expected, let actual): return "下载被截断（期望 \(expected) 字节，实得 \(actual)）"
        case .badStatus(let code): return "音频下载响应状态码 \(code)"
        case .pathEscape: return "缓存路径逃逸，已拒绝"
        case .credentialUnavailable: return "凭证不可用，无法取回私有音频"
        case .writeFailed(let code): return "本地写入失败（状态码 \(code)）"
        case .staleSession: return "会话已变更，结果作废"
        case .cancelled: return "操作已取消"
        case .tornDown: return "播放器已释放"
        }
    }
}
