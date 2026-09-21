import CovaCore
import CovaPlayer
import SwiftUI

/// 根状态（@MainActor + @Observable）：会话 / 播放器 / 导航 / Toast。
/// UI 只读快照与意图方法，**不直接碰 actor**（并发边界集中在这一层）。
@MainActor
@Observable
public final class AppSession {
    public enum AuthPhase: Equatable { case restoring, guest, signedIn(AuthUser), failed(String) }
    public enum Tab: String, CaseIterable, Identifiable { case home, library, mine
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .home: return "首页"
            case .library: return "曲库"
            case .mine: return "我的"
            }
        }
        public var symbol: String {
            switch self {
            case .home: return "house.fill"
            case .library: return "music.note.list"
            case .mine: return "person.fill"
            }
        }
    }

    public private(set) var authPhase: AuthPhase = .restoring
    public var tab: Tab = .home
    public var drawerOpen = false
    public var playerSheetOpen = false
    public var loginPresented = false
    public var toast: (message: String, isError: Bool)?
    public private(set) var snapshot: PlaybackSnapshot?

    public let auth: CovaAuthSession
    public let client: CovaAPIClient
    public let player: CovaPlayer
    private var snapshotTask: Task<Void, Never>?

    public init(previewTab: Tab = .home) {
        tab = previewTab
        let auth = CovaDependencies.makeAuthSession()
        self.auth = auth
        self.client = CovaAPIClient(transport: CovaDependencies.makeTransport(), credentials: auth)
        self.player = CovaDependencies.makePlayer(auth: auth)
    }

    public func bootstrap() async {
        try? await player.activateForPlayback()
        do {
            let state = try await auth.restoreSession()
            if let user = state.user {
                authPhase = .signedIn(user)
                await bindPlayerSession()
            } else {
                authPhase = .guest
            }
        } catch {
            authPhase = .guest   // 无已存会话 = 游客态，不是错误
        }
        startSnapshotPolling()
    }

    /// 登录：NEEDS-1 的 `user` 缺字段会让解码失败 —— 那种失败**点名 NEEDS-1**，
    /// 不伪装成「密码错误」。
    public func signIn(email: String, password: String) async {
        do {
            let user = try await auth.signIn(email: email, password: SecretString(password))
            authPhase = .signedIn(user)
            await bindPlayerSession()
            showToast("欢迎回来，\(user.name)")
        } catch let error as CovaAPIError {
            switch error {
            case .decoding:
                authPhase = .failed("后端返回的用户字段不完整（NEEDS-1 已登记），登录暂不可用")
            default:
                authPhase = .failed("登录失败：\(error.redactedDescription)")
            }
        } catch {
            authPhase = .failed("登录失败：\(error.localizedDescription)")
        }
    }

    public func signOut() async {
        try? await auth.signOut()
        await player.bindSession(PlaybackSessionContext(owner: nil, generation: .initial))
        authPhase = .guest
        showToast("已登出：队列与私有音频缓存已清理")
    }

    /// 播放器会话绑定：owner/generation 取自**凭证快照**（D8 防串号的同一份事实）。
    private func bindPlayerSession() async {
        guard let snap = try? await auth.currentSession() else { return }
        await player.bindSession(PlaybackSessionContext(owner: snap.principal, generation: snap.generation))
    }

    public func continueAsGuest() async {
        await auth.continueAsGuest()
        authPhase = .guest
    }

    // MARK: 播放意图（UI 唯一入口）

    public func play(tracks: [TrackDto], at index: Int) async {
        let items = tracks.compactMap { Self.playbackItem(from: $0) }
        guard !items.isEmpty else { return }
        _ = await player.start(items: items, at: min(index, items.count - 1))
        await refreshSnapshot()
    }

    public func toggle() async { _ = await player.toggle(); await refreshSnapshot() }
    public func next() async { _ = await player.next(); await refreshSnapshot() }
    public func previous() async { _ = await player.previous(); await refreshSnapshot() }
    public func seek(_ seconds: Double) async { _ = await player.seekTo(seconds); await refreshSnapshot() }
    public func cycleLoop() async { _ = await player.cycleLoopMode(); await refreshSnapshot() }

    public func refreshSnapshot() async { snapshot = await player.currentSnapshot() }

    private func startSnapshotPolling() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    public func showToast(_ message: String, isError: Bool = false) {
        toast = (message, isError)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { if self?.toast?.message == message { self?.toast = nil } }
        }
    }

    /// `TrackDto` → `PlaybackItem`：私有音频一律 `bearerRequired`（D7：必须先本地化）。
    public static func playbackItem(from track: TrackDto) -> PlaybackItem? {
        guard let audio = URL(string: track.audioUrl), let audioURL = try? AudioURL(https: audio) else { return nil }
        let cover = URL(string: track.cover).flatMap { try? AudioURL(https: $0) }
        return try? PlaybackItem(
            id: track.id,
            title: track.titleCn ?? track.title,
            artist: track.artistNameCn ?? track.artist.name,
            album: track.styleCn ?? track.style,
            duration: track.audioDuration ?? track.duration,
            coverURL: cover,
            audioSource: .bearerRequired(audioURL),
            kind: .libraryTrack
        )
    }
}
