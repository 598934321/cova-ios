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

    private let session: URLSession

    public init() {
        session = URLSessionTransport.makeDefaultSession()
    }

    init(session: URLSession) {
        self.session = session
    }

    public func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let urlRequest = URLSessionTransport.makeURLRequest(request)
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
