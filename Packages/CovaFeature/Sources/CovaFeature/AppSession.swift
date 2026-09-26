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
        self.workDownloads = CovaDependencies.makeWorkDownloads(auth: auth)
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

    /// 登录：解码失败不伪装成「密码错误」，也**不点名 NEEDS-1**（那条已撤销，D21⑤）
    /// —— 统一由 `LoginFailureCopy` 说话。
    public func signIn(email: String, password: String) async {
        do {
            let user = try await auth.signIn(email: email, password: SecretString(password))
            authPhase = .signedIn(user)
            // 换号 = 上一条账号的在途账一律作废（D5/D8/D22：这一本账是"这台设备替谁在跑"，
            // 账号一换就没有替谁的问题了，留着只会串到下一个人的列表上）。
            resetLiveStudioJobs()
            await bindPlayerSession()
            bindRecents(owner: user.id)
            await refreshCollections()
            // 04 §7：登录成功**强制刷新** `/me`（余额/身份在登录后才有意义）。
            await loadMe(force: true)
            // A1：登录成功后「最近播放」改读服务端那一份（上一个身份的账不留）。
            await loadRecentHistory(force: true)
            showToast("欢迎回来，\(user.name)")
        } catch let error as CovaAPIError {
            // 不再为 `.decoding` 单开一句「后端返回的用户字段不完整（NEEDS-1 已登记）」：
            // NEEDS-1 已撤销（D21⑤），而这一支同时是 D21③ 身份一致性 fail-closed 的落点
            // （`AuthSession.identityMismatchDescription` 就是以 `.decoding` 抛的）⇒
            // 「两份响应说的是两个人」会被读成"后端少字段"。统一走 LoginFailureCopy：
            // `.decoding` 落「登录没成功，检查一下网络再试」，既不指凭证也不指后端。
            authPhase = .failed(LoginFailureCopy.message(for: error))
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
        // A6 的作品直存按 owner 分桶 ⇒ **必须在签出之前**取到是谁的那一份：
        // 签出之后凭证快照没了，届时连"该清谁的文件"都说不出来（D8 owner 隔离）。
        let leavingOwner = (try? await auth.currentSession())?.principal
        try? await auth.signOut()
        await player.bindSession(PlaybackSessionContext(owner: nil, generation: .initial))
        authPhase = .guest
        // 04 §4「登出后 G 区立即回落未登录态」：`/me` 这本账（含缓存值）不留残留（D8 owner 隔离）。
        resetMe()
        // D8 同一条理由：换号/登出后两本收藏账必须清空，否则新账号会看见旧账号的收藏态。
        favoriteIDs = []
        savedPlaylistIDs = []
        clearRecents()
        resetLiveStudioJobs()
        // A1/A3/A6 的三本新账同属「这台设备替谁在跑」：换号一律作废（D8 owner 隔离）。
        resetRecentHistory()
        resetStudioCreate()
        await resetWorkDownloads(owner: leavingOwner)
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
        resetLiveStudioJobs()   // 同一族隔离：游客的 08 列表上没有"这台设备在跑"的账
        resetRecentHistory()   // 服务端历史同理：游客没有可读的历史，也不许看到上一个人的
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
        case studioCreate
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

    /// 03 §7 / 01 §6 的跨屏预填：从 01 的 AI 音乐人栏点进曲库时，曲库要按 `artistId` 筛。
    ///
    /// 它是**一次性载荷**，不是路由参数，也不是曲库的常驻状态：
    /// · 不放进 `Route` —— 曲库是 Tab 根屏，`.library` 不在 `path` 里，而且路由值会进 URL/深链，
    ///   一个预填筛选跟着导航栈活第三次就不对了；
    /// · 由 03 在**取数之前**读一次并立刻置 nil（`consumeLibraryPreset()`）——
    ///   留着它，用户手动清掉筛选后一滚回来又被预填一遍，那是屏上凭空多出来的一条因果。
    public struct LibraryPreset: Equatable, Sendable {
        /// `LibraryFilterSelection.queryItems(artistID:)` 那一条腿的参数。
        public var artistID: String?
        /// 上面那个号在屏上怎么念（03 §1 的已选 chips 要能**看见**这个筛选、也要能**撤掉**它；
        /// 只有号没有名字，就会剩下一条"发出去了但屏上不说"的隐藏筛选 —— 那是同一类谎）。
        /// 由递出这一格的屏（01 §6）把它本来就显示着的那两个字带过来，03 不反查、不猜。
        public var artistLabel: String?
        /// 跨维度预置值（`LibraryFilterSelection.merge(_:)` 的入参形态：维度名 → 值）。
        public var dimensions: [String: [String]]

        public init(
            artistID: String? = nil, artistLabel: String? = nil, dimensions: [String: [String]] = [:]
        ) {
            self.artistID = artistID
            self.artistLabel = artistLabel
            self.dimensions = dimensions
        }
    }
    public var pendingLibraryPreset: LibraryPreset?

    /// 取走预填载荷：**读到就销**，第二次调用必然是 `nil`。
    public func consumeLibraryPreset() -> LibraryPreset? {
        let preset = pendingLibraryPreset
        pendingLibraryPreset = nil
        return preset
    }

    /// 本次运行的 agent 流协调器（**一次发送一个**，`OneStepStreamCoordinator` 是单次使用的）。
    public private(set) var studioCoordinator: OneStepStreamCoordinator?

    /// 流式阶段与降级原因（09 的降级条要说真话，所以它得能读到状态机的事实）。
    public func studioStreamState() async
        -> (phase: OneStepStreamPhase?, trigger: OneStepDegradationTrigger?) {
        guard let studioCoordinator else { return (nil, nil) }
        return (await studioCoordinator.currentPhase(), await studioCoordinator.degradationTrigger())
    }

    // MARK: 08 §3.C 的「本机在途 job」账（09 写、08 读）

    /// 会话号 → **未终态** job 的进度读数。三档事实必须都能表达，而字典的两种"没有"不一样：
    /// · 键**缺席** = 本机没有这一路的在途事实 ⇒ 08 无环（冷启动必然这一档，§9 判据第 3 条）；
    /// · 键在、值为 `nil` = 有 job 在跑但没有可读进度 ⇒ 只说「生成中」，不印也不念百分数；
    /// · 键在、值有数 = `0...1` 的实测进度。
    ///
    /// 来源只有这一个：08 §数据源行 140 钉的「本设备内存中未终态的 job（由 09 的发起者持有）」，
    /// 所以 08 **不**为列表逐行发请求（N+1 禁令），也不从别处推一个数出来。
    /// 读写一律走下面三个方法 + `StudioLiveJobLedger` 那几个扩展：`dict[id] = nil` 在 Swift 里
    /// 是**删键**，直接写下标会把第二档（有 job 无读数）擦成第一档（没 job）。
    public private(set) var liveStudioJobs: [String: Double?] = [:]

    /// 「这一路是我这台设备发起的、还没收口」⇒ 上环。`progress` 拿不到就传 `nil`（只说生成中）。
    public func markStudioJobLive(sessionID: String, progress: Double?) {
        liveStudioJobs.markStudioLive(sessionID: sessionID, progress: progress)
    }

    /// **只更新已有那条的读数**：屏上重新对到一份权威状态时调它。
    /// 键不在就什么都不做 —— 冷启动或本机没发起过的会话，凭空 `mark` 会给 08 长出一格
    /// "这设备在跑"的假事实（§数据源行 140 只要发起者持有）。
    public func updateStudioJobProgress(sessionID: String, progress: Double?) {
        guard liveStudioJobs.studioHasLiveJob(sessionID) else { return }
        liveStudioJobs.markStudioLive(sessionID: sessionID, progress: progress)
    }

    /// 收口：终态、用户点「停止生成」、以及任何"本机已知这一路结束了"的时刻。
    public func settleStudioJob(sessionID: String) {
        liveStudioJobs.settleStudioLive(sessionID: sessionID)
    }

    /// 整本作废（登出 / 换号 / 转游客）。D5/D8/D22 的按身份隔离：本机内存里的在途账
    /// 留在上一个身份身上，下一个账号就会看到一格不属于他的「生成中」——
    /// 这一族缺陷本仓已经吃过一次（`resetMe` / `clearRecents` / 两本收藏账同一个道理）。
    private func resetLiveStudioJobs() {
        liveStudioJobs = [:]
    }

    /// 发一句话给 agent，拿回流帧。旧流一定先被有界取消（D16），不留并发尾巴。
    ///
    /// 顺带落 08 §数据源行 140 那一本账：这一枪发出去，这一路会话从这一刻起就是
    /// 「本机持有的未终态 job」⇒ 08 的那一格环有了唯一合法的来源。**已经有一个读数就留着它**
    /// （计划卡那一轮可能已经推进过），没有就是"有 job、暂无读数"那一档。
    public func beginStudioStream(
        sessionID: String, request: HTTPRequest
    ) async throws -> AsyncStream<CovaSSEFrame> {
        await cancelStudioStream()
        let coordinator = CovaDependencies.makeStudioStream()
        studioCoordinator = coordinator
        do {
            let stream = try await coordinator.start(sessionId: sessionID, agentRequest: request)
            if !liveStudioJobs.studioHasLiveJob(sessionID) {
                markStudioJobLive(sessionID: sessionID, progress: nil)
            }
            return stream
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

    // MARK: 最近播放（A1：登录态以 `GET /api/play-history` 为准，游客/离线回落本地账）

    /// 一行「最近播放」的视图模型：**库曲行与作品行共用同一个形状**（A1 的混排）。
    ///
    /// 只有展示字段 + 身份 —— 音频地址不进这一层（签名串禁入持久化索引，硬边界 3），
    /// 点开时按 `kind` 回读权威端点：库曲 `GET /api/tracks/:id`、
    /// 作品 `GET /api/studio/create/works?id=<trackId>`。
    public struct RecentPlayRow: Identifiable, Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable { case library, work }
        /// 库曲 = trackId；作品 = 伪 trackId `{jobId}:{candidateId}`（也是上报用的那一个）。
        public let id: String
        public let kind: Kind
        public let title: String
        /// 作品行的艺人名恒为 null（服务端投影如此）⇒ nil 就是「没有」，UI 自己决定占位，
        /// **不许**由这一层编一个「未知艺人」。
        public let artist: String?
        public let coverURLString: String?
        public let duration: Double?
        /// 裸 jobId 的作品行不可播（服务端可能因取不到候选音频而丢行）。
        public let playable: Bool
        /// 服务端回显的来源（松散串，只用于诊断，不上屏）。
        public let source: String?
    }

    public enum RecentHistoryState: String, Equatable, Sendable {
        case idle        // 还没发过（游客态不发）
        case loading     // 在途
        case loaded      // 最近一次成功
        case outOfSync   // 最近一次失败（`recentHistory` 可能还留着上次的值）
    }

    public internal(set) var recentHistory: [RecentPlayRow] = []
    public internal(set) var recentHistoryState: RecentHistoryState = .idle
    /// 服务端 items 里读不出身份的行数（**不静默丢行**：少掉的行要能解释）。
    public internal(set) var recentHistoryUnreadable = 0
    /// 下面这几个是**实现细节但跨文件**（`PlayHistoryFlow` / `StudioCreateFlow` 两条腿
    /// 都在同一模块的另一个文件里）⇒ 只能是 module 内可见，不能是 `private`。
    var recentHistoryOwner: String?
    var recentHistoryRequestID = 0
    /// 在途去重（同 `meTask` 那条腿）：抽屉与 01 同一帧都要这一份时只发一次请求。
    var recentHistoryTask: Task<Void, Never>?

    /// 屏上渲染的那一份（用户裁决 2026-09-26：**服务端为准，游客/离线回落本地账**）。
    ///
    /// 回落只在「服务端这一份是空的」时发生 —— 服务端回了一份空历史（新账号）是**事实**，
    /// 不是失败，那种情况下拿本机旧账顶上就是把「你没有历史」说成「你有」。
    /// 所以判据是 `recentHistoryState == .loaded` 而不是 `recentHistory.isEmpty`。
    public var recentRows: [RecentPlayRow] {
        if recentHistoryState == .loaded { return recentHistory }
        return recents.map { recent in
            RecentPlayRow(
                id: recent.id, kind: .library, title: recent.title, artist: recent.artist,
                coverURLString: recent.coverURLString, duration: nil, playable: true, source: nil
            )
        }
    }

    // MARK: 创作台（design/screens/19-studio-create.md · A3/A4/A11）

    /// 19 屏的全部状态（一个值类型 ⇒ 视图只读它，不散着读七八个属性）。
    public struct StudioCreateState: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case idle
            /// 提交在途（CTA 菊花，不可二次点击）。
            case submitting
            /// 任务轮询中；携服务端任务态（文案走 `GenerationJobStatus.userLabel`）。
            case polling(GenerationJobStatus)
            case succeeded
            /// 任务终态失败（`errorMessage` 就地展示）。
            case failed
            /// **不许说失败**的两格：2xx 没读到任务号、或轮询到上限还没终态
            /// （任务可能仍在跑）。文案见 `message`。
            case unconfirmed
        }

        public var phase: Phase = .idle
        public var jobId: String?
        /// 服务端回显的扣费数字（`charge`）。**0 与 nil 都不渲染**那一行（0 也可能只是
        /// 开发环境开关关闭，客户端无从判别，所以不写「免费」）。
        public var charge: Int?
        public var works: [CreateWorkItemDto] = []
        public var message: String?
        /// 已等待秒数（D 区计时）。
        public var elapsed: TimeInterval = 0

        public var isBusy: Bool {
            switch phase {
            case .submitting, .polling: return true
            default: return false
            }
        }
    }

    public internal(set) var studioCreate = StudioCreateState()
    /// 同一次提交的幂等凭据：**重试复用、新提交重建**（A11）。
    var studioCreateToken: IdempotentRequestToken?
    var studioCreateTask: Task<Void, Never>?
    var studioCreateTicker: Task<Void, Never>?
    var studioCreateSubmitID = 0
    /// 屏上输入框的内容（19 §3.B）。放在会话层是为了「返回再进来还在」。
    public var studioCreatePrompt = ""

    // MARK: 作品直存（A6 / BUG-15：不 checkout、不扣费）

    public let workDownloads: WorkDownloadStore
    /// 本机已存的作品 id（行内「已在本机」标记的事实源；来自 `WorkDownloadStore`，
    /// 而它又以**盘上文件**为准，不是清单说了算）。
    public internal(set) var savedWorkIDs: Set<String> = []

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
