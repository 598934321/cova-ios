import CovaCore
import CovaPlayer
import Foundation

/// 应用级依赖装配（D5/D10/D11）：出口守卫、Keychain（ThisDeviceOnly）、owner 绑定持久化。
/// 凭证只经 `CovaAuthSession` 注入客户端与播放器，**不进日志、不进 UI 状态**。
public enum CovaDependencies {
    public static func makeTransport() -> URLSessionTransport { URLSessionTransport() }

    public static func makeSecureStore() -> KeychainStore { KeychainStore() }

    public static func makeOwnerStore() -> FileActiveOwnerStore {
        FileActiveOwnerStore(baseDirectory: FileActiveOwnerStore.defaultBaseDirectory()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    public static func makeLifecycle(secureStore: any SecureStore) -> SessionLifecycle {
        SessionLifecycle(
            secureStore: secureStore,
            ownerStore: OwnerScopedJSONStore(baseDirectory: OwnerScopedJSONStore.defaultBaseDirectory()
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        )
    }

    public static func makeAuthSession() -> CovaAuthSession {
        let secure = makeSecureStore()
        let owner = makeOwnerStore()
        return CovaAuthSession(
            transport: makeTransport(),
            secureStore: secure,
            lifecycle: makeLifecycle(secureStore: secure),
            activeOwnerStore: owner
        )
    }

    /// 播放器装配：私有音频走 D7 硬顺序（Bearer 下载 → 沙盒校验非空 → `file://`）。
    @MainActor
    public static func makePlayer(auth: CovaAuthSession) -> CovaPlayer {
        let fetcher = try? PrivateAudioFetcher(
            transport: URLSessionPrivateAudioTransport(),
            credentials: auth
        )
        let reporter = PlayReportCoordinator(submitter: PlayReportSubmitter(client: CovaAPIClient(
            transport: makeTransport(), credentials: auth
        )))
        return CovaPlayer(reporter: reporter, sourcePreparer: fetcher)
    }
}

/// 播放上报提交器（NEEDS-2 未解锁时服务端可能拒 `app-ios`）：**不静默丢包** ——
/// 失败进未决队列，可经 `retryPending()` 补发（P5 幂等键复用）。
public struct PlayReportSubmitter: PlayReportSubmitting {
    private let client: CovaAPIClient
    public init(client: CovaAPIClient) { self.client = client }

    public func submit(_ request: PlayReportRequestDto) async throws -> PlayReportResponseDto {
        try await client.post("/api/tracks/play", body: request)
    }
}
