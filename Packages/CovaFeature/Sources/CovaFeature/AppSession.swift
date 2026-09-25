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
    /// 04 抽屉的开关。**只有两处置真**：顶栏字标钮（`openDrawer(from:)`）与走查键
    /// `COVA_PREVIEW_DRAWER`（`CovaRootView`）—— 后者没有触发者，所以它打开的抽屉不归还焦点。
    public var drawerOpen = false
    /// 04 §1 入口① 的位置：抽屉是**从哪一枚顶栏字标钮**打开的。
    /// 04 §6 后半句「关闭时归还给触发它的 logo 按钮」只有真的存在触发者才谈得上，
    /// 所以这一本账必须记在会话层（触发钮在 01/03 的 toolbar 里，抽屉在根视图的 overlay 里，
    /// 两者不在同一棵视图树上，关闭那一刻谁该接焦点没法由抽屉自己推断）。
    public enum DrawerOpener: String, Equatable, Sendable { case home, library }
    /// 最近一次由字标钮打开抽屉的那一枚；走查键打开的恒为 nil（于是关闭时不假装归还）。
    public private(set) var drawerOpener: DrawerOpener?
    public var playerSheetOpen = false
    public var loginPresented = false
    public var toast: (message: String, isError: Bool)?
    public private(set) var snapshot: PlaybackSnapshot?

    // MARK: `GET /api/auth/me` 共享账（04 §7 G 区卡片 + 11「我的」同读这一份）

    /// `/me` 的**同步状态**。它与「上一次成功取到的值」是两本账，不能压成一个 optional：
    /// 04 §4 / 11 §4 都要求失败时**保留上次缓存值**并另标「未同步」——
    /// 只留一个 `me?` 就要么丢掉缓存、要么把「没取到」伪装成「这账号没有权益」。
    public enum MeSyncState: Equatable {
        case idle        // 还没发过（游客态：04 §7「游客态：不发 me」）
        case syncing     // 在途
        case synced      // 最近一次成功
        case outOfSync   // 最近一次失败（可能手里还留着旧值）
    }

    /// 最近一次**成功**取到的 `/me`；失败不清空（04 §4「保留上次缓存值」），但换身份/登出会清。
    public private(set) var me: CovaMeResponse?
    public private(set) var meState: MeSyncState = .idle
    /// 已为哪个身份取过（D8 防串号：换号即作废，不给新账号看旧账号的余额）。
    private var meOwner: String?
    /// 在途去重：抽屉与 11 同一帧都要数据时只发一次请求。
    private var meTask: Task<Void, Never>?
    /// 请求代号：每发起一次 +1。**迟到包只认自己那一代的账** —— 否则换号后旧请求返回，
    /// 既会把新账号的在途标记销掉（下一次 `loadMe` 就永远不再发），也会把旧余额落进新账。
    private var meRequestID = 0

    /// 取 `/me`：**一次认证变化只取一次**，`force` 才重发。
    ///
    /// 04 §7 写的是「距上次 > 5min 才刷新」，而 5min 这个时限**没有 token 也没有配置档**
    /// （TG-09 未裁决）⇒ 不发明时限，退化成「同身份内不重复取，除显式重试」。
    /// 游客**不发**；失败**不吞**（状态留 `.outOfSync` 给 UI 说话用）。
    public func loadMe(force: Bool = false) async {
        guard case .signedIn(let user) = authPhase else {
            resetMe()
            return
        }
        let owner = user.id
        if !force, meOwner == owner, meState == .synced || meState == .syncing { return }
        // 只合并**同一身份**的在途请求；换号后的迟到包不参与这个判断。
        if let running = meTask, meOwner == owner { await running.value; return }
        meRequestID += 1
        let id = meRequestID
        meOwner = owner
        meState = me == nil ? .syncing : .outOfSync
        let service = CatalogService(client: client)
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await service.me()
                guard self.meRequestID == id else { return }   // 迟到的旧一代：不落账
                self.me = response
                self.meState = .synced
            } catch {
                guard self.meRequestID == id else { return }
                self.meState = .outOfSync     // 旧值留着（04 §4），但状态说实话
            }
            if self.meRequestID == id { self.meTask = nil }
        }
        meTask = operation
        await operation.value
    }

    /// 清 `/me` 这本账（登出/游客/换号前的同一动作）。`meRequestID` 一并推进，
    /// 让任何在途的迟到包自己认不出这一代。
    private func resetMe() {
        meTask?.cancel()
        meTask = nil
        me = nil
        meState = .idle
        meOwner = nil
        meRequestID += 1
    }

    /// `/me` 的身份（抽屉 G 区首选用它：`covaId` 只在 `/me` 上给，登录响应的 `user` 没有）。
    public var meUser: AuthUser? {
        if case .signedIn(let user) = authPhase { return me?.user ?? user }
        return nil
    }

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
                await loadMe()
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
            // 04 §7：登录成功**强制刷新** `/me`（余额/身份在登录后才有意义）。
            await loadMe(force: true)
            showToast("欢迎回来，\(user.name)")
        } catch let error as CovaAPIError {
            switch error {
            case .decoding:
                authPhase = .failed("后端返回的用户字段不完整（NEEDS-1 已登记），登录暂不可用")
            default:
                authPhase = .failed(LoginFailureCopy.message(for: error))
            }
        } catch {
            authPhase = .failed(LoginFailureCopy.message(for: error))
        }
    }

    /// 点通知进来：只信 `sessionId`；缺失/不合法 ⇒ 回落首页，**不**猜一条会话路由。
    public func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        path = []
        guard let sessionID = StudioNotificationPlanner.route(from: userInfo) else {
            tab = .home
            return
        }
        tab = .home
        path.append(.aiSession(sessionID))
    }

    public func signOut() async {
        // 登出先把 18 的待发/已发通知与角标一并撤掉，再清本机账（spec 明令）。
        await StudioNotifier.revokeAll()
        try? await auth.signOut()
        await player.bindSession(PlaybackSessionContext(owner: nil, generation: .initial))
        authPhase = .guest
        // 04 §4「登出后 G 区立即回落未登录态」：`/me` 这本账（含缓存值）不留残留（D8 owner 隔离）。
        resetMe()
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
        resetMe()   // 游客态不发 `me`（04 §7），也不许留着上一个身份的余额
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
        case membership
        case enterprise
        case artist(String)
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
    public private(set) var studioCoordinator: OneStepStreamCoordinator?

    /// 流式阶段与降级原因（09 的降级条要说真话，所以它得能读到状态机的事实）。
    public func studioStreamState() async
        -> (phase: OneStepStreamPhase?, trigger: OneStepDegradationTrigger?) {
        guard let studioCoordinator else { return (nil, nil) }
        return (await studioCoordinator.currentPhase(), await studioCoordinator.degradationTrigger())
    }

    /// 发一句话给 agent，拿回流帧。旧流一定先被有界取消（D16），不留并发尾巴。
    public func beginStudioStream(
        sessionID: String, request: HTTPRequest
    ) async throws -> AsyncStream<CovaSSEFrame> {
        await cancelStudioStream()
        let coordinator = CovaDependencies.makeStudioStream()
        studioCoordinator = coordinator
        do {
            return try await coordinator.start(sessionId: sessionID, agentRequest: request)
        } catch {
            studioCoordinator = nil
            throw error
        }
    }

    public func cancelStudioStream() async {
        let current = studioCoordinator
        studioCoordinator = nil
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

    /// 04 §1 入口①：顶栏字标钮开抽屉。记下是谁开的，关闭时才知道该把 VoiceOver 焦点还给谁。
    /// 关闭不在此处（04 §1「关闭 = 回到打开前的屏」，且关闭点分散在遮罩/✕/选中项/先逛逛四处），
    /// 归还由 `DrawerTrigger` 自己观察 `drawerOpen` 的那次回落完成。
    public func openDrawer(from opener: DrawerOpener) {
        drawerOpener = opener
        drawerOpen = true
    }

    // MARK: 播放意图（UI 唯一入口）

    public func play(tracks: [TrackDto], at index: Int) async {
        let items = tracks.compactMap { Self.playbackItem(from: $0) }
        // 旧形态在这里是**静默**的：整批 `compactMap` 出空队列 ⇒ `play(items:)` 直接 return，
        // 用户点了播放但什么都没发生（R16-1 的表现面）。补地址失败现在只可能是后端给了
        // 客户端不能猜的形态（协议相对 / 非 https / 穿越段），那就必须说一句，而不是憋着。
        if items.isEmpty {
            showToast("音频地址不可用，这首暂时播不了", isError: true)
            return
        }
        if items.count < tracks.count {
            showToast("\(tracks.count - items.count) 首的地址不可用，已跳过")
        }
        // 歌词（02 §6 / D15：静态文本，无时间轴）跟着**这一次起播的那条曲目**进来 ——
        // `PlaybackItem` 刻意不带 lyrics 字段（播放层不该知道目录内容），所以这一份
        // 只在 UI 层存活，并绑定 itemID：换到别的曲目就自动失效，不会把上一首的词留给下一首。
        let safeIndex = min(max(index, 0), tracks.count - 1)
        lyricsOwnerID = tracks[safeIndex].id
        currentLyrics = tracks[safeIndex].lyrics
        await play(items: items, at: index)
    }

    /// 当前歌词 + 它属于哪一条曲目（视图必须比对 itemID 才能显示）。
    public private(set) var currentLyrics: String?
    public private(set) var lyricsOwnerID: String?

    /// 快照里的曲目换了 ⇒ 歌词账跟着作废（不留上一首的词）。
    public var lyricsForCurrentItem: String? {
        guard let lyricsOwnerID, let snapshot, snapshot.item?.id == lyricsOwnerID else { return nil }
        return currentLyrics
    }

    public func play(items: [PlaybackItem], at index: Int = 0) async {
        guard !items.isEmpty else {
            // 「点了没反应」必须是可解释的一件事，而不是一个静默 return（R16-1 的可见面：
            // 上游 `compactMap` 把不能播的行全丢掉时，队列就是这里的那个空数组）。
            showToast("音频地址不可用，暂时播不了", isError: true)
            return
        }
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
    ///
    /// 地址先过 `CovaEnvironment.resolveMediaURL`：线上 `audioUrl` 实测是**相对路径**
    /// （`/api/tracks/<id>/preview-stream`，20/20 行），补不成绝对同源地址就当不能播（R16-1）。
    public static func playbackItem(from track: TrackDto) -> PlaybackItem? {
        guard let audio = CovaEnvironment.resolveMediaURL(track.audioUrl),
              let audioURL = try? AudioURL(https: audio) else { return nil }
        let cover = CovaEnvironment.resolveMediaURL(track.cover).flatMap { try? AudioURL(https: $0) }
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
        guard let audio = CovaEnvironment.resolveMediaURL(similar.audioUrl),
              let audioURL = try? AudioURL(https: audio) else { return nil }
        let cover = CovaEnvironment.resolveMediaURL(similar.cover).flatMap { try? AudioURL(https: $0) }
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
