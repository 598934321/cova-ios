import CovaCore
import CovaPlayer
import CovaUI
import SwiftUI

/// 「继续聆听」的一行。**只有展示字段与曲目 id**：音频地址可能带签名，
/// 硬边界 3 禁止它进持久化索引 ⇒ 播放时回读 `GET /api/tracks/:id`，不存旧地址。
public struct RecentTrack: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let coverURLString: String?

    public init(id: String, title: String, artist: String, coverURLString: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.coverURLString = coverURLString
    }
}

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
        themeMode = CovaThemeMode(
            rawValue: UserDefaults.standard.string(forKey: Self.themeDefaultsKey) ?? ""
        ) ?? .system
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
                bindRecents(owner: user.id)
                await refreshCollections()
            } else {
                authPhase = .guest
                bindRecents(owner: nil)
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
            bindRecents(owner: user.id)
            await refreshCollections()
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
        // D8 同一条理由：换号/登出后两本收藏账必须清空，否则新账号会看见旧账号的收藏态。
        favoriteIDs = []
        savedPlaylistIDs = []
        clearRecents()
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

    // MARK: 导航与收藏态（design 04/06/07/12a/12b）

    /// 抽屉与各列表页共用的路由值。**只带 ID**，页面自己按 ID 取数 ——
    /// 把整个 DTO 塞进路由会让「深链直入」与「下拉刷新后重取」两套事实源打架。
    public enum Route: Hashable {
        case playlist(String)
        case favorites
        case myPlaylists
        case plaza
        case settings
        case aiSessions
        case aiSession(String)
    }
    public var path: [Route] = []

    /// 主题（design 15 的「外观」段）。**只有用户真的选过才落盘** ——
    /// 没选过时 UserDefaults 里没有键，下次启动仍是「跟随系统」。
    public private(set) var themeMode: CovaThemeMode
    private static let themeDefaultsKey = "cova.themeMode"

    public func setTheme(_ mode: CovaThemeMode) {
        themeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.themeDefaultsKey)
    }
    /// 07 曲目详情（半屏 sheet）。nil = 未打开。
    public var detailTrackID: String?
    /// 收藏态缓存（design 06 §NEEDS-9：详情端点不给 `isSaved`，收藏态只能由列表端点供给）。
    public private(set) var favoriteIDs: Set<String> = []
    public private(set) var savedPlaylistIDs: Set<String> = []

    public var catalog: CatalogService { CatalogService(client: client) }
    public var studio: StudioService { StudioService(client: client) }

    /// 首页/列表带过来的待说内容（08 的三条示例 chip 用它预填新会话）。
    public var pendingPrompt: String?
    /// 随待说内容一起带过去的「深度思考」开关（01 输入卡 → 09 首发）。
    public var pendingDeepThinking = false

    /// 本次运行的 agent 流协调器（**一次发送一个**，`OneStepStreamCoordinator` 是单次使用的）。
    private var studioStream: OneStepStreamCoordinator?

    /// 发一句话给 agent，拿回流帧。旧流一定先被有界取消（D16），不留并发尾巴。
    public func beginStudioStream(
        sessionID: String, request: HTTPRequest
    ) async throws -> AsyncStream<CovaSSEFrame> {
        await cancelStudioStream()
        let coordinator = CovaDependencies.makeStudioStream()
        studioStream = coordinator
        return try await coordinator.start(sessionId: sessionID, agentRequest: request)
    }

    public func cancelStudioStream() async {
        let current = studioStream
        studioStream = nil
        await current?.cancel()
    }

    /// 刷新两本收藏账。**游客一律清空**：游客的收藏态恒「未知」，按未收藏显示而不是报错
    /// （design 06/07 登录态口径），所以这里不是失败而是正常形态。
    public func refreshCollections() async {
        guard case .signedIn = authPhase else {
            favoriteIDs = []
            savedPlaylistIDs = []
            return
        }
        if let favorites = try? await catalog.favorites() {
            favoriteIDs = Set(favorites.tracks.map(\.id))
        }
        if let saved = try? await catalog.savedPlaylists() {
            savedPlaylistIDs = Set(saved.playlists.map(\.id))
        }
    }

    /// 收藏开关。**未确认成功前不改本地态** —— 乐观更新会把失败的行显示成已收藏，
    /// 用户以为存上了，实际后端没有（design 12a 的失败回落口径）。
    public func toggleFavorite(_ trackID: String) async {
        let on = !favoriteIDs.contains(trackID)
        do {
            _ = try await catalog.setFavorite(trackID: trackID, on)
            if on { favoriteIDs.insert(trackID) } else { favoriteIDs.remove(trackID) }
        } catch {
            showToast("收藏没保存上，再试一次", isError: true)
        }
    }

    public func toggleSavedPlaylist(_ playlistID: String) async {
        let on = !savedPlaylistIDs.contains(playlistID)
        do {
            _ = try await catalog.setSavedPlaylist(playlistID: playlistID, on)
            if on { savedPlaylistIDs.insert(playlistID) } else { savedPlaylistIDs.remove(playlistID) }
        } catch {
            showToast("取消收藏没保存上，再试一次", isError: true)
        }
    }

    /// 批量取消收藏（design 12a：**逐条 DELETE + 幂等键**，≤4 并发，不得发明批量端点）。
    /// 返回**失败**的 trackId 集合，调用方据此把失败的行保持勾选。
    public func removeFavorites(_ trackIDs: [String]) async -> Set<String> {
        var failed: Set<String> = []
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = trackIDs.makeIterator()
            var inFlight = 0
            while inFlight < 4, let id = next.next() {
                group.addTask { await self.sendRemoveFavorite(id) }
                inFlight += 1
            }
            while let (id, ok) = await group.next() {
                inFlight -= 1
                if ok { favoriteIDs.remove(id) } else { failed.insert(id) }
                if let following = next.next() {
                    group.addTask { await self.sendRemoveFavorite(following) }
                    inFlight += 1
                }
            }
        }
        return failed
    }

    private func sendRemoveFavorite(_ trackID: String) async -> (String, Bool) {
        do {
            _ = try await catalog.setFavorite(trackID: trackID, false)
            return (trackID, true)
        } catch {
            return (trackID, false)
        }
    }

    public func removeSavedPlaylists(_ playlistIDs: [String]) async -> Set<String> {
        var failed: Set<String> = []
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = playlistIDs.makeIterator()
            var inFlight = 0
            while inFlight < 4, let id = next.next() {
                group.addTask { await self.sendRemoveSavedPlaylist(id) }
                inFlight += 1
            }
            while let (id, ok) = await group.next() {
                inFlight -= 1
                if ok { savedPlaylistIDs.remove(id) } else { failed.insert(id) }
                if let following = next.next() {
                    group.addTask { await self.sendRemoveSavedPlaylist(following) }
                    inFlight += 1
                }
            }
        }
        return failed
    }

    private func sendRemoveSavedPlaylist(_ playlistID: String) async -> (String, Bool) {
        do {
            _ = try await catalog.setSavedPlaylist(playlistID: playlistID, false)
            return (playlistID, true)
        } catch {
            return (playlistID, false)
        }
    }

    /// 路由/抽屉入口的统一出口：游客点需要登录的入口 → 弹登录，而不是静默禁用。
    public func requireLoginForCollections() -> Bool {
        if case .signedIn = authPhase { return true }
        loginPresented = true
        return false
    }

    // MARK: 播放意图（UI 唯一入口）

    public func play(tracks: [TrackDto], at index: Int) async {
        let items = tracks.compactMap { Self.playbackItem(from: $0) }
        await play(items: items, at: index)
    }

    public func play(items: [PlaybackItem], at index: Int = 0) async {
        guard !items.isEmpty else { return }
        _ = await player.start(items: items, at: min(index, items.count - 1))
        await refreshSnapshot()
    }

    /// 07 的「加入队列」：插到下一首，**不打断当前播放**。
    public func enqueue(_ item: PlaybackItem) async {
        _ = await player.insertNext(item)
        await refreshSnapshot()
        showToast("已加入队列")
    }

    public func toggle() async { _ = await player.toggle(); await refreshSnapshot() }
    public func next() async { _ = await player.next(); await refreshSnapshot() }
    public func previous() async { _ = await player.previous(); await refreshSnapshot() }
    public func seek(_ seconds: Double) async { _ = await player.seekTo(seconds); await refreshSnapshot() }
    public func cycleLoop() async { _ = await player.cycleLoopMode(); await refreshSnapshot() }

    public func refreshSnapshot() async {
        let next = await player.currentSnapshot()
        snapshot = next
        // 「继续聆听」记的是**真的响过**的曲目：只在进入 `.playing` 的那一刻落账，
        // 装载失败/被暂停/只是被选中的都不算（否则这一栏会变成「我点过的东西」）。
        if next.state == .playing, let item = next.item, item.id != lastHeardItemID {
            lastHeardItemID = item.id
            recordRecent(RecentTrack(
                id: item.id, title: item.title, artist: item.artist,
                coverURLString: item.coverURL?.value.absoluteString
            ))
        }
    }

    // MARK: 继续聆听（01 §「继续聆听」：本机本地账，不是后端字段）

    /// 只存**展示字段 + 曲目 id**。音频地址可能带签名 ⇒ 硬边界 3 禁止把它写进持久化索引，
    /// 所以这一栏要点开时回读 `GET /api/tracks/:id` 再播，而不是拿旧地址直接放。
    public private(set) var recents: [RecentTrack] = []
    private var lastHeardItemID: String?
    private var recentsOwner: String?

    private static let recentsKeyPrefix = "cova.recents."
    private static let recentsLimit = 12

    /// 换到某个身份名下：先落盘当前账，再读该身份自己的账（D8「离线记录按账号清除」的另一半）。
    public func bindRecents(owner: String?) {
        if let recentsOwner, recentsOwner != owner {
            UserDefaults.standard.removeObject(forKey: Self.recentsKeyPrefix + recentsOwner)
        }
        recentsOwner = owner
        guard let owner else {
            recents = []
            return
        }
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKeyPrefix + owner),
              let stored = try? JSONDecoder().decode([RecentTrack].self, from: data) else {
            recents = []
            return
        }
        recents = stored
    }

    private func recordRecent(_ track: RecentTrack) {
        var next = recents
        next.removeAll { $0.id == track.id }
        next.insert(track, at: 0)
        if next.count > Self.recentsLimit { next.removeLast(next.count - Self.recentsLimit) }
        recents = next
        guard let owner = recentsOwner else { return }   // 游客不落盘：没有可清除的身份
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.recentsKeyPrefix + owner)
        }
    }

    /// 登出/换号：本机这一份「继续聆听」整份作废（不留在设备上给下一个身份看）。
    public func clearRecents() {
        if let owner = recentsOwner {
            UserDefaults.standard.removeObject(forKey: Self.recentsKeyPrefix + owner)
        }
        recents = []
        lastHeardItemID = nil
    }

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

    /// `SimilarTrackDto` → `PlaybackItem`：similar 是**另一套投影**（NEEDS-10/12），
    /// 不能按 `TrackDto` 解码，所以这里单独一条映射腿（07 的「播放全部」用它）。
    public static func playbackItem(from similar: SimilarTrackDto) -> PlaybackItem? {
        guard let audio = URL(string: similar.audioUrl), let audioURL = try? AudioURL(https: audio) else { return nil }
        let cover = URL(string: similar.cover).flatMap { try? AudioURL(https: $0) }
        return try? PlaybackItem(
            id: similar.id,
            title: similar.titleCn ?? similar.title,
            artist: similar.artist.nameCn ?? similar.artist.name,
            album: similar.styleCn ?? similar.style,
            duration: similar.audioDuration ?? similar.duration,
            coverURL: cover,
            audioSource: .bearerRequired(audioURL),
            kind: .libraryTrack
        )
    }
}
