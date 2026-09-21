import CovaCore
import Foundation

/// 落盘结果回执。
///
/// 只有字节数与状态码 —— **没有 URL / header 字段**，因此回执进入日志也不会带出签名地址。
public struct PrivateAudioReceipt: Equatable, Sendable {
    public let bytesWritten: Int
    /// 响应声明的期望长度（未知为 nil）。
    public let expectedBytes: Int?
    public let statusCode: Int

    public init(bytesWritten: Int, expectedBytes: Int?, statusCode: Int) {
        self.bytesWritten = bytesWritten
        self.expectedBytes = expectedBytes
        self.statusCode = statusCode
    }

    /// 完成性判定（D7「校验非空」+ 拒绝截断）：
    /// - 0 字节一律拒绝；
    /// - 响应声明了期望长度则必须逐字节相等。
    public var isComplete: Bool {
        guard bytesWritten > 0 else { return false }
        guard let expected = expectedBytes else { return true }
        return expected == bytesWritten
    }
}

/// 私有音频的**落盘式**传输面。
///
/// 刻意不复用 CovaCore `HTTPTransport`：后者整包返回 `Data`，音频文件会把内存打爆。
/// 实现方必须流式写入目标文件句柄，并在返回前保证数据已落盘。
public protocol PrivateAudioTransport: Sendable {
    /// - Parameters:
    ///   - url: 已通过出口守卫的 https 地址。
    ///   - authorization: Bearer 值（`SecretString`，由凭证提供器注入；**不得**写日志）。
    ///   - fileURL: 目标临时文件（父目录已存在）。
    ///   - expectedBytes: 调用方已知的期望长度（可选，用于交叉校验）。
    /// - Parameters:
    ///   - url: 已通过出口守卫的 https 地址。
    ///   - authorization: Bearer 值（`SecretString`，由凭证提供器注入；**不得**写日志）。
    ///   - fileURL: 目标临时文件（父目录已存在）。
    ///   - expectedBytes: 调用方已知的期望长度（可选，用于交叉校验）。
    func writeAudio(
        from url: URL,
        authorization: SecretString?,
        to fileURL: URL,
        expectedBytes: Int?
    ) async throws -> PrivateAudioReceipt

    /// 作废该出口上的**在途**传输（D16②：已授权的传输必须被立即取消，且结果不得投递）。
    ///
    /// 语义是「作废当前在途」而不是「关掉出口」：登出/换号之后 App 还要为新会话取音频，
    /// 因此实现不得让出口永久不可用（终态下线请用 `shutDown()`）。
    ///
    /// 默认实现为空操作 —— 只适用于「没有底层在途请求可作废」的桩件与内存实现。
    func cancelInFlightTransfers() async
}

public extension PrivateAudioTransport {
    func cancelInFlightTransfers() async {}
}

/// 权威一致性判定（缺陷 C2 的纯决策面，零 URLSession 可断言）。
enum AudioAuthorityMatch {
    /// `scheme://host:port` 归一化 origin；host 缺失或非 https 时为 nil。
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// 请求发起的权威与落地响应的权威是否同一台。
    ///
    /// 刻意用「同源」而不是「生产出口」：出口守卫（`CovaEnvironment.isProductionOrigin`）
    /// 属于调用方（`PrivateAudioFetcher`）在发起前判的一次；本层要拦的是
    /// 「自动跟随重定向后，字节其实来自另一台主机」这一件事 —— 它必须在
    /// **一个字节都没写盘之前**被发现。
    static func matches(requestURL: URL, responseURL: URL?) -> Bool {
        guard let requested = origin(of: requestURL) else { return false }
        guard let landed = origin(of: responseURL) else { return false }
        return requested == landed
    }
}

/// 生产实现：`URLSession.bytes` 流式读取 + `FileHandle` 分块写入。
///
/// 超时口径与 CovaCore 普通请求不同：音频是**大文件读**，
/// 请求超时 15s（建连/首字节），资源超时 7 天（整体下载不被掐断）。
public final class URLSessionPrivateAudioTransport: PrivateAudioTransport, @unchecked Sendable {
    /// 单次请求（建连与首字节）超时。
    public static let requestTimeout: TimeInterval = 15
    /// 整个资源传输超时。
    public static let resourceTimeout: TimeInterval = 7 * 24 * 60 * 60
    /// 写盘块大小（64KB：避免逐字节 syscall，也避免整包进内存）。
    public static let writeChunkBytes = 64 * 1024

    private let lock = NSLock()
    private let configurationProvider: @Sendable () -> URLSessionConfiguration
    /// 当前这一代的会话；`cancelInFlightTransfers()` 把它下线并置 nil（下一次调用换代）。
    private var liveSession: URLSession?
    private var lockedCancellationCount = 0
    private var lockedSessionGeneration: UInt64 = 0
    private var lockedShutDown = false

    public init(session: URLSession? = nil) {
        if let session {
            let injected = session
            self.configurationProvider = { injected.configuration }
            self.liveSession = injected
            self.lockedSessionGeneration = 1
        } else {
            self.configurationProvider = Self.makeDefaultConfiguration
        }
    }

    /// 生产默认配置（音频形状）。
    private static func makeDefaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = nil
        // 私有音频响应绝不允许被系统 URL 缓存落盘：缓存键就是那条带签名的地址，
        // 值就是「仅本人可见」的音频字节（AGENTS 硬边界 3 / D7「不进持久化」）。
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    /// 当前会话（惰性换代）。终态下线后为 nil。
    private func currentSession() -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        if lockedShutDown { return nil }
        if let liveSession { return liveSession }
        let created = URLSession(configuration: configurationProvider())
        liveSession = created
        lockedSessionGeneration += 1
        return created
    }

    /// 已作废在途的次数（可观测面：清理确实发生）。
    public var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lockedCancellationCount
    }

    /// 会话代次（每次新建会话推进；证明出口没被打死，只是换了代）。
    public var sessionGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lockedSessionGeneration
    }

    /// 作废**在途**传输（M8 / D16②）：掐掉这一代会话，下一次请求换新一代会话。
    ///
    /// 为什么不能只靠「下一次读字节时才发现被取消」这种软约定：`bytes(for:)` 不交出任务句柄，
    /// 唯一能真正立刻终止已授权传输的开关是会话级 `invalidateAndCancel()`。
    /// 又因为它会让该会话永久不再接受任务，所以会话必须**按代**管理 ——
    /// 否则第一次登出就把出口永久打死。
    public func cancelInFlightTransfers() async {
        takeLiveSessionForCancellation()?.invalidateAndCancel()
    }

    /// 同步临界区：摘下当前这一代会话（异步上下文不能直接持锁，故独立成同构函数）。
    private func takeLiveSessionForCancellation() -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        let dying = liveSession
        liveSession = nil
        lockedCancellationCount += 1
        return dying
    }

    /// 终态下线：不再发起任何请求（进程退出/对象析构路径用）。
    public func shutDown() {
        lock.lock()
        let dying = liveSession
        liveSession = nil
        lockedShutDown = true
        lock.unlock()
        dying?.invalidateAndCancel()
    }

    /// 兼容旧调用名：语义是**终态下线**（不是「作废在途后继续可用」）。
    public func invalidateAndCancel() {
        shutDown()
    }

    /// 落盘文件属性（m12）：owner 可读写，且要求设备解锁后才可读。
    static func fileAttributes() -> [FileAttributeKey: Any] { [
        FileAttributeKey.posixPermissions: 0o600,
    ] }

    public func writeAudio(
        from url: URL,
        authorization: SecretString?,
        to fileURL: URL,
        expectedBytes: Int?
    ) async throws -> PrivateAudioReceipt {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        if let authorization {
            // Authorization 只进请求对象；本函数与错误类型都不回显它。
            request.setValue("Bearer \(authorization.rawValue)", forHTTPHeaderField: "Authorization")
        }
        guard let session = currentSession() else { throw PlayerError.cancelled }
        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw PlayerError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw PlayerError.cancelled
        } catch is URLError {
            throw PlayerError.badStatus(0)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PlayerError.hostRejected
        }
        // C2：响应的**最终**权威必须仍是发起那一台主机。URLSession 默认会自动跟随
        // 跨主机重定向，而 `HTTPURLResponse.url` 就是落地那一条 —— 不在这里判，
        // 任意主机的字节就会被当作 `file://` 交付播放。判在 `createFile` 之前：
        // 被拒绝时连文件都不该存在。
        guard AudioAuthorityMatch.matches(requestURL: url, responseURL: http.url) else {
            throw PlayerError.hostRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlayerError.badStatus(http.statusCode)
        }
        let declared = http.expectedContentLength >= 0 ? Int(http.expectedContentLength) : nil
        let expected = declared ?? expectedBytes

        // m14：`createFile` 的 Bool 必须检查（旧实现吞掉失败后靠 `FileHandle` 的 nil 猜错误码）。
        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: Self.fileAttributes()
        ) else {
            throw PlayerError.writeFailed(EINVAL)
        }
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw PlayerError.writeFailed(EBADF)
        }
        defer { try? handle.close() }

        var written = 0
        var buffer = Data()
        buffer.reserveCapacity(Self.writeChunkBytes)
        for try await byte in stream {
            // 取消（Swift 任务或会话代际作废）都必须在这里立刻收尾：
            // 「已作废的传输不得继续投递结果」（D16②）。半文件由上层删除。
            if Task.isCancelled { throw PlayerError.cancelled }
            buffer.append(byte)
            if buffer.count >= Self.writeChunkBytes {
                written += try Self.writeChunk(buffer, to: handle)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if buffer.isEmpty == false {
            written += try Self.writeChunk(buffer, to: handle)
        }
        try handle.synchronize()
        return PrivateAudioReceipt(
            bytesWritten: written,
            expectedBytes: expected,
            statusCode: http.statusCode
        )
    }

    /// 写一块并返回**实际**写入字节数；短写与 I/O 错误都以 `PlayerError` 抛出（绝不静默截断）。
    ///
    /// m14：`FileHandle.write(_:)` 不抛错、检测不了短写（出错走 ObjC 异常 → 进程崩）；
    /// `write(contentsOf:)` 是 throwing 版本，再以 `offsetInFile` 交叉核对实际推进量。
    static func writeChunk(_ data: Data, to handle: FileHandle) throws -> Int {
        let before = handle.offsetInFile
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw PlayerError.writeFailed(EIO)
        }
        let after = handle.offsetInFile
        let advanced = Int(after - before)
        guard advanced == data.count else { throw PlayerError.writeFailed(ENOSPC) }
        return advanced
    }
}
