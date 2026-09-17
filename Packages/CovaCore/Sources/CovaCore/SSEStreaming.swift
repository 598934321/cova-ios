import Foundation

/// 流式（SSE）传输抽象。
///
/// 生产实现 = `URLSessionSSETransport`（`URLSession.bytes` 字节流，无第三方依赖）；
/// 单测 = 注入的假流（可控分块/终止，**零真实网络**）。
///
/// 失败一律以 `CovaAPIError` 抛出（生产实现在内部完成映射）。
public protocol SSEStreamingTransport: Sendable {
    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error>
}

/// 生产 SSE 传输：`URLSession` 字节流。
///
/// - 与 `URLSessionTransport` 共用无缓存会话与 15s 超时配置，复用其 URLRequest 构造；
/// - 非 2xx 直接以 `CovaAPIError` 失败（不把错误页当事件流解析）；
/// - 按到达节奏产出 `Data` 块；迭代被取消时同步取消底层任务。
public struct URLSessionSSETransport: SSEStreamingTransport {
    /// 单次 yield 的字节上限（避免长连接把整段缓存进内存）。
    public static let chunkByteLimit = 4096

    /// SSE 空闲超时（等待数据的间隔上限）。
    ///
    /// 必须**大于** D6 的 30s 静默窗口：否则 URLSession 会在 15s（普通请求超时）就把长连接
    /// 掐断，`consume` 会把它当 EOF → 恒报 `.eofBeforeDone`，使「30s 静默」几乎不可达。
    /// 60s = 2× 静默窗口，活性判定权收归降级状态机。
    public static let idleTimeout: TimeInterval = 60

    /// SSE 资源总时长（近似无限）。
    ///
    /// `timeoutIntervalForResource` 是**整条连接的总时限**，对无限事件流必须足够大，
    /// 否则流会在总时限到达时被强制终止。取 URLSession 默认量级（7 天），
    /// 真正的活性由心跳与 30s 静默逻辑负责。
    public static let resourceTimeout: TimeInterval = 7 * 24 * 60 * 60

    private let session: URLSession

    public init() {
        session = Self.makeDefaultSession()
    }

    init(session: URLSession) {
        self.session = session
    }

    /// SSE 专用会话：空闲 60s、资源 ≈无限（与普通请求的 15s/15s 明确区分）。
    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    public func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        // 纵深防御（D10）：即便调用方绕过请求工厂，也拒绝非生产 origin，绝不发起请求。
        guard CovaEnvironment.isProductionOrigin(request.url) else {
            throw CovaAPIError.invalidRequestURL
        }
        // 已被取消：不得创建 URLSession 任务（纵深防御，M-1）。
        try Task.checkCancellation()
        let urlRequest = URLSessionTransport.makeURLRequest(request, timeoutInterval: Self.idleTimeout)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        continuation.finish(throwing: CovaAPIError.invalidResponse)
                        return
                    }
                    var buffer = Data()
                    buffer.reserveCapacity(Self.chunkByteLimit)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= Self.chunkByteLimit {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CovaAPIError.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Cova AI 流式/轮询端点请求工厂（唯一出站 URL 入口，均经 `CovaEnvironment` 守卫，D10）。
public enum CovaSSERequests {
    /// `POST /api/studio/agent`（SSE，`Accept: text/event-stream`）。
    ///
    /// 请求体字段族由 M2 按 web 契约组装；本层只保证「出口守卫 + 流式 Accept」。
    public static func agent(jsonBody: Data) throws -> HTTPRequest {
        try APIRequestBuilder.make(
            method: .post,
            path: "/api/studio/agent",
            jsonBody: jsonBody,
            accept: "text/event-stream"
        )
    }

    /// `GET /api/studio/one-step/plans?sessionId=`（降级轮询）。
    public static func oneStepPlans(sessionId: String) throws -> HTTPRequest {
        try APIRequestBuilder.make(
            method: .get,
            path: "/api/studio/one-step/plans",
            queryItems: [URLQueryItem(name: "sessionId", value: sessionId)]
        )
    }
}

/// 降级轮询抽象（D6：`GET /api/studio/one-step/plans?sessionId=`，每 5s）。
public protocol OneStepPlanPolling: Sendable {
    func pollPlans(sessionId: String) async throws -> [OneStepPlanCardDto]
}

/// 基于 `HTTPTransport` 的轮询实现（可注入假传输层测试；鉴权由上层传输包装提供）。
public struct HTTPOneStepPlanPoller: OneStepPlanPolling {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func pollPlans(sessionId: String) async throws -> [OneStepPlanCardDto] {
        // 传输入口取消守卫（M-1）：任务已取消时不得发起请求。
        try Task.checkCancellation()
        let request = try CovaSSERequests.oneStepPlans(sessionId: sessionId)
        let response = try await transport.send(request)
        let data = try CovaAPIClient.payload(from: response)
        do {
            return try JSONDecoder().decode(OneStepPlanCardsResponseDto.self, from: data).planCards
        } catch let error as DecodingError {
            throw CovaAPIError.classify(decoding: error)
        } catch {
            throw CovaAPIError.decoding(field: "planCards")
        }
    }
}
