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
    func writeAudio(
        from url: URL,
        authorization: SecretString?,
        to fileURL: URL,
        expectedBytes: Int?
    ) async throws -> PrivateAudioReceipt
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

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.resourceTimeout
            configuration.waitsForConnectivity = false
            configuration.httpAdditionalHeaders = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 供上层在 teardown 时强制取消在途任务。
    public func invalidateAndCancel() {
        session.invalidateAndCancel()
    }

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
        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw PlayerError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw PlayerError.cancelled }
            throw PlayerError.badStatus(0)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PlayerError.badStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlayerError.badStatus(http.statusCode)
        }
        let declared = http.expectedContentLength >= 0 ? Int(http.expectedContentLength) : nil
        let expected = declared ?? expectedBytes

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw PlayerError.writeFailed(errno)
        }
        defer { try? handle.close() }

        var written = 0
        var buffer = Data()
        buffer.reserveCapacity(Self.writeChunkBytes)
        for try await byte in stream {
            if Task.isCancelled {
                try? handle.close()
                throw PlayerError.cancelled
            }
            buffer.append(byte)
            if buffer.count >= Self.writeChunkBytes {
                handle.write(buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if buffer.isEmpty == false {
            handle.write(buffer)
            written += buffer.count
        }
        try handle.synchronize()
        return PrivateAudioReceipt(bytesWritten: written, expectedBytes: expected, statusCode: http.statusCode)
    }
}
