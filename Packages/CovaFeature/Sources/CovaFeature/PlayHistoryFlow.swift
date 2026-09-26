import CovaCore
import CovaPlayer
import Foundation

/// 「最近播放」这一栏的会话层腿（A1）。
///
/// 结构上照 `loadMe` 那一条已有的腿长：同身份内不重复取、在途去重、
/// **迟到的旧一代不落账**（换号后旧请求返回，不能把上一个人的历史写进这个人的列表，D8）。
extension AppSession {

    /// 取服务端最近播放。游客**不发**（那个端点恒 401），失败**不吞**（状态留给 UI 说话）。
    public func loadRecentHistory(force: Bool = false) async {
        guard case .signedIn(let user) = authPhase else {
            resetRecentHistory()
            return
        }
        let owner = user.id
        if !force, recentHistoryOwner == owner,
           recentHistoryState == .loaded || recentHistoryState == .loading { return }
        if let running = recentHistoryTask, recentHistoryOwner == owner {
            await running.value
            return
        }
        recentHistoryRequestID += 1
        let id = recentHistoryRequestID
        recentHistoryOwner = owner
        recentHistoryState = .loading
        let service = catalog
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let page = try await service.playHistory()
                guard self.recentHistoryRequestID == id else { return }   // 迟到的旧一代
                self.recentHistory = Self.recentRows(from: page)
                self.recentHistoryUnreadable = page.unreadableItemCount
                self.recentHistoryState = .loaded
            } catch {
                guard self.recentHistoryRequestID == id else { return }
                // 401 与「读不懂响应」都落 outOfSync：这一栏会回落到本机账（01 §8 的
                // 「分区级错误」形态由视图自己决定说不说），但绝不伪装成「你没有历史」。
                self.recentHistoryState = .outOfSync
            }
            if self.recentHistoryRequestID == id { self.recentHistoryTask = nil }
        }
        recentHistoryTask = operation
        await operation.value
    }

    /// 换号 / 登出 / 游客：这一本账整份作废（不留在设备上给下一个身份看）。
    public func resetRecentHistory() {
        recentHistoryTask?.cancel()
        recentHistoryTask = nil
        recentHistoryRequestID += 1
        recentHistoryOwner = nil
        recentHistory = []
        recentHistoryUnreadable = 0
        recentHistoryState = .idle
    }

    /// 01 那一栏的行数（A1 的取证口径要和 `curl` 数出来的一致，所以映射是纯函数）。
    static func recentRows(from page: PlayHistoryPageDto) -> [RecentPlayRow] {
        page.items.compactMap { item in
            guard let row = RecentPlayRow(item: item) else { return nil }
            return row
        }
    }

    /// 点一行：库曲回读曲目详情、作品回读作品行 —— 两档都**不**用历史里那份地址
    /// （签名串不入持久化索引；且作品的代理地址 TTL 30min，存下来到点开必过期）。
    public func replay(_ row: RecentPlayRow) async {
        guard row.playable else {
            showToast("这首还没做完，暂时不能播", isError: true)
            return
        }
        switch row.kind {
        case .library:
            do {
                let detail = try await catalog.trackDetail(row.id)
                await play(tracks: [detail.track], at: 0)
            } catch {
                showToast("这首暂时不能播", isError: true)
            }
        case .work:
            do {
                let page = try await studioCreateService.works(id: row.id)
                guard let work = page.works.first else {
                    showToast("这首暂时不能播", isError: true)
                    return
                }
                await playWork(work)
            } catch {
                showToast("这首暂时不能播", isError: true)
            }
        }
    }
}

extension AppSession.RecentPlayRow {
    /// 一行历史 → 视图模型。**只有身份读不出来时才放弃这一行**（其余字段缺失一律容忍）；
    /// 不可播的行**照样渲染**（点不开要说得出为什么，而不是让它凭空消失）。
    init?(item: PlayHistoryItemDto) {
        guard !item.trackId.isEmpty else { return nil }
        let track = item.track
        let title = track?.displayTitle ?? (item.isWorkRow ? "未命名作品" : item.trackId)
        self.init(
            id: item.trackId,
            kind: item.isWorkRow ? .work : .library,
            title: title,
            artist: track?.displayArtist,
            coverURLString: track?.cover,
            duration: track?.duration,
            playable: item.isPlayable,
            source: item.source
        )
    }
}
