// R18-2 夹具的期望值口径：
// · 站内相对 → 期望 `ArtworkFixture.production(原文)`（生产 origin + **原文逐字节**）；
// · 名单内绝对 → 期望 `ArtworkFixture.sanctioned(路径)`（host 取自 CovaEnvironment 名单）；
// · 名单外 / 形状非法 → 期望 `.refused(host:)`，且 host 之外一个字都不许多；
// · nil / 空串 → 期望 `.absent`。

import CovaCore
import CovaUI
@testable import CovaFeature
import XCTest

/// 十条美术腿（R18-2）：夹具里的**服务端原文** → 各屏各槽的裁决结论。
///
/// 覆盖的是「哪条腿读哪个字段、读完是什么结论」；**不覆盖** `body` 是否真的把腿接上了
/// （那需要 UI 快照框架，本批刻意不发明）。每条用例都点名它钉的是哪个屏的哪个槽。
final class ArtworkMediaLegsTests: XCTestCase {

    // MARK: 夹具取样

    private func artist(_ id: String) throws -> ArtistDto {
        let artists: [ArtistDto] = try ArtworkFixture.decoded([ArtistDto].self, key: "artists")
        guard let found = artists.first(where: { $0.id == id }) else {
            throw ArtworkFixtureError.keyMissing("artists/\(id)")
        }
        return found
    }

    private func track(_ id: String) throws -> TrackDto {
        let tracks: [TrackDto] = try ArtworkFixture.decoded([TrackDto].self, key: "tracks")
        guard let found = tracks.first(where: { $0.id == id }) else {
            throw ArtworkFixtureError.keyMissing("tracks/\(id)")
        }
        return found
    }

    private func similar(_ id: String) throws -> SimilarTrackDto {
        let items: [SimilarTrackDto] = try ArtworkFixture.decoded([SimilarTrackDto].self, key: "similarTracks")
        guard let found = items.first(where: { $0.id == id }) else {
            throw ArtworkFixtureError.keyMissing("similarTracks/\(id)")
        }
        return found
    }

    private func playlist(_ id: String) throws -> PlaylistDto {
        let items: [PlaylistDto] = try ArtworkFixture.decoded([PlaylistDto].self, key: "playlists")
        guard let found = items.first(where: { $0.id == id }) else {
            throw ArtworkFixtureError.keyMissing("playlists/\(id)")
        }
        return found
    }

    /// 01「继续聆听」这一槽自 2026-09-26 起读的是 `AppSession.RecentPlayRow`
    /// （服务端 play-history 与本机账两本账合到同一个形状，A1 的混排）⇒ 夹具里那份
    /// `RecentTrack` 先映射过去。映射只搬封面相关的那几格，其余填合法值 ——
    /// **本用例验的是封面腿，不是行的语义**（行语义的用例在 `StudioCreateLegTests`）。
    private func recent(_ id: String) throws -> AppSession.RecentPlayRow {
        let items: [RecentTrack] = try ArtworkFixture.decoded([RecentTrack].self, key: "recentTracks")
        guard let found = items.first(where: { $0.id == id }) else {
            throw ArtworkFixtureError.keyMissing("recentTracks/\(id)")
        }
        return AppSession.RecentPlayRow(
            id: found.id, kind: .library, title: found.title, artist: found.artist,
            coverURLString: found.coverURLString, duration: nil, playable: true, source: nil
        )
    }

    // MARK: 16 音乐人主页 —— artist.avatar

    /// 线上实测形态：`GET /api/artists` 的 `artist.avatar` **13 行里 12 行是站内相对路径**
    /// （2026-09-25 本仓只读复核：13 行 = 12 相对 + 1 绝对在封面桶）。
    /// 这一条就是 R18-2 的主案发现场：旧代码 `URL(string:)` 拿到的是**没有 scheme 的相对 URL**，
    /// 出口守卫判假 ⇒ 一次请求都不发 ⇒ 只剩占位图。
    func testArtistHomeAvatarLegResolvesSiteRelativeAvatar() throws {
        let raw = "/uploads/avatars/relative.png"
        XCTAssertEqual(try artist("ar-relative").avatar, raw, "夹具改动会让这条用例失去所指")
        let resolution = ArtistHomeArtwork.avatar(try artist("ar-relative"))
        XCTAssertResolved(resolution, equals: ArtworkFixture.production(raw))
        guard case .resolved(let url) = resolution else { return }
        XCTAssertEqual(url.host(), CovaEnvironment.apiBaseURL.host())
        XCTAssertEqual(url.path, "/uploads/avatars/relative.png")
    }

    /// 同一条腿上的**绝对且名单内**形态（`GET /api/artists` 的 `covalink-covers-*` 头像）：
    /// 裁决必须原样交出，不做二次编码。
    func testArtistHomeAvatarLegKeepsSanctionedAbsoluteAvatar() throws {
        let expected = try ArtworkFixture.sanctioned("/avatars/absolute.png")
        XCTAssertResolved(ArtistHomeArtwork.avatar(try artist("ar-absolute")), equals: expected)
    }

    /// 「服务端这一行没给图」与「给了但不可出站」必须是**两个不同结论**（R18-2 的判据 3）。
    func testArtistHomeAvatarLegSeparatesMissingFromRefused() throws {
        XCTAssertAbsent(ArtistHomeArtwork.avatar(try artist("ar-nil")), "缺 avatar 字段")
        XCTAssertAbsent(ArtistHomeArtwork.avatar(try artist("ar-empty")), "avatar 是空串")
        XCTAssertRefused(ArtistHomeArtwork.avatar(try artist("ar-unsanctioned")), host: "art-cdn.invalid")
    }

    /// 近似 host 一律拒，并且**点名真正收到请求的那一台**（D23③）。
    func testArtistHomeAvatarLegRefusesNearMissHostsAndNamesThem() throws {
        XCTAssertRefused(
            ArtistHomeArtwork.avatar(try artist("ar-nearmiss")),
            host: "covalink.cn.evil.test",
            "后缀挂甲：不是 covalink.cn"
        )
        XCTAssertRefused(
            ArtistHomeArtwork.avatar(try artist("ar-userinfo")),
            host: "evil.test",
            "userinfo 逃逸：请求落在 @ 之后那台"
        )
    }

    /// 没有 host 的裸相对路径（`uploads/a.png`）**不猜 host**：拒绝，且不得回显原串。
    func testArtistHomeAvatarLegRefusesHostlessRelativeWithoutEchoingPath() throws {
        let message = try XCTUnwrap(
            XCTAssertRefused(ArtistHomeArtwork.avatar(try artist("ar-bare-relative")),
                             host: CovaEnvironment.unnameableHostLabel)
        )
        XCTAssertFalse(message.contains("uploads"), "拒绝信息里不许出现路径：\(message)")
        XCTAssertFalse(message.contains("sig"), "拒绝信息里不许出现查询串：\(message)")
    }

    // MARK: 曲目行封面 —— track.cover（16 / 01 / 03 / 06 / 07 五屏同一字段）

    /// 五条 `track.cover` 腿（16/01/03/06/07）在**站内相对 + 带查询**这一形态上必须给同一个结论，
    /// 且查询串逐字节带走：差一个字符（`%2B` 被发成 `+`、`&` 少了、参数换了序）就是另一张图
    /// 或一张没有。
    ///
    /// 据实记一句：`GET /api/tracks` 的 `cover` 今天 20/20 是封面桶**绝对**地址（本仓只读复核），
    /// 「相对 + 带查询」是**同一层**在 `GET /api/user-playlists` 上实测到的形态
    /// （`docs/decisions.md` §S补充3）—— 这一条钉的是"五种字段形态 × 五条腿共用一条规则"，
    /// 不是声称曲目封面今天就是相对路径。
    func testTrackCoverLegPreservesQueryStringBytesOnAllFiveTrackCoverLegs() throws {
        let raw = "/api/covers/track-1.png?width=640&height=640&sig=9f%2Bab&format=webp"
        let legs: [(String, CovaArtworkResolution)] = [
            ("16 曲目行", ArtistHomeArtwork.cover(try track("tk-relative-query"))),
            ("01 场景精选", HomeArtwork.cover(try track("tk-relative-query"))),
            ("03 曲库列表", LibraryArtwork.cover(try track("tk-relative-query"))),
            ("06 曲目行", PlaylistDetailArtwork.cover(try track("tk-relative-query"))),
            ("07 大封面", TrackDetailArtwork.cover(try track("tk-relative-query"))),
        ]
        for (name, resolution) in legs {
            XCTAssertResolved(resolution, equals: ArtworkFixture.production(raw), name)
            guard case .resolved(let url) = resolution else { continue }
            XCTAssertEqual(url.query, "width=640&height=640&sig=9f%2Bab&format=webp", "\(name) 的查询串被改写")
            XCTAssertTrue(url.absoluteString.contains("%2B"), "\(name) 的 %2B 被降档成裸加号")
            XCTAssertFalse(url.absoluteString.contains("9f+ab"), "\(name) 出现了未编码的 +")
        }
    }

    /// 名单内绝对曲目封面（2026-09-25 实测 `GET /api/tracks` 的 `cover` 20/20 落在这台）：
    /// 原样交出，不重编码、不加前缀。
    func testTrackCoverLegPassesSanctionedAbsoluteCoverThrough() throws {
        let expected = try ArtworkFixture.sanctioned("/covers/track-2.png")
        XCTAssertResolved(HomeArtwork.cover(try track("tk-abs-sanctioned")), equals: expected)
        XCTAssertResolved(LibraryArtwork.cover(try track("tk-abs-sanctioned")), equals: expected)
    }

    /// 名单外的绝对封面：**这一条就是「不是红屏也不是静默」** —— 拒、且说得出是哪台。
    func testTrackCoverLegRefusesUnsanctionedCoverHost() throws {
        XCTAssertRefused(HomeArtwork.cover(try track("tk-unsanctioned")), host: "covers.evil.test")
        XCTAssertRefused(ArtistHomeArtwork.cover(try track("tk-unsanctioned")), host: "covers.evil.test")
    }

    // MARK: 06 歌单详情头图 —— cover / coverUrl / coverMedia.imageUrl

    /// 头图三候选里的 `coverUrl`：站内相对 + 带查询（第 18 轮以测试账号实测的形态）。
    func testPlaylistHeroLegResolvesCoverUrlWithQueryIntact() throws {
        let raw = "/api/covers/playlist-1.png?width=640&height=640&sig=9f%2Bab&format=webp"
        let resolution = PlaylistDetailArtwork.hero(try playlist("pl-cover-url"))
        XCTAssertResolved(resolution, equals: ArtworkFixture.production(raw), "06 头图 coverUrl")
        guard case .resolved(let url) = resolution else { return }
        XCTAssertEqual(url.query, "width=640&height=640&sig=9f%2Bab&format=webp")
    }

    /// 三候选的取用顺序：`cover` → `coverUrl` → `coverMedia.imageUrl`，**空串不算给到值**。
    func testPlaylistHeroLegTakesFirstNonEmptyCandidate() throws {
        let expected = try ArtworkFixture.sanctioned("/covers/playlist-3.png")
        XCTAssertResolved(PlaylistDetailArtwork.hero(try playlist("pl-cover-first")), equals: expected, "cover 先到先用")

        let imageUrl = "/api/covers/playlist-2.png?width=640&sig=11%2B22"
        XCTAssertResolved(
            PlaylistDetailArtwork.hero(try playlist("pl-image-url")),
            equals: ArtworkFixture.production(imageUrl),
            "cover/coverUrl 都是空串时必须落到 imageUrl（旧 ?? 链在这里会静默留白）"
        )
    }

    func testPlaylistHeroLegHandlesMissingAndUnsanctioned() throws {
        XCTAssertAbsent(PlaylistDetailArtwork.hero(try playlist("pl-none")), "三个字段都没给")
        XCTAssertAbsent(PlaylistDetailArtwork.hero(nil), "歌单还没取到")
        XCTAssertRefused(PlaylistDetailArtwork.hero(try playlist("pl-unsanctioned")), host: "covers.evil.test")
    }

    /// 01 推荐歌单卡：同一套候选（`cover` → `coverUrl`），另一条腿独立钉一次。
    func testHomePlaylistCardLegMatchesHeroRule() throws {
        let raw = "/api/covers/playlist-1.png?width=640&height=640&sig=9f%2Bab&format=webp"
        XCTAssertResolved(HomeArtwork.playlistCover(try playlist("pl-cover-url")),
                          equals: ArtworkFixture.production(raw))
        XCTAssertAbsent(HomeArtwork.playlistCover(try playlist("pl-none")))
    }

    // MARK: 07 相似曲目横滑 —— similar.cover

    func testSimilarCoverLegResolvesAndRefuses() throws {
        let raw = "/api/covers/similar-1.png?width=320&sig=7c%2Bd"
        XCTAssertResolved(TrackDetailArtwork.similarCover(try similar("sm-relative-query")),
                          equals: ArtworkFixture.production(raw))
        XCTAssertRefused(
            TrackDetailArtwork.similarCover(try similar("sm-protocol-relative")),
            host: "covers.evil.test",
            "协议相对 //host/x 是 authority 逃逸，不补全"
        )
    }

    // MARK: 01 继续聆听 —— 本机账里的 coverURLString

    func testRecentCoverLegHandlesAbsoluteNilAndNearMiss() throws {
        let expected = try ArtworkFixture.sanctioned("/covers/recent-1.png")
        XCTAssertResolved(HomeArtwork.recentCover(try recent("rc-absolute")), equals: expected)
        XCTAssertAbsent(HomeArtwork.recentCover(try recent("rc-none")), "本机账里没存封面")
        XCTAssertRefused(HomeArtwork.recentCover(try recent("rc-nearmiss")), host: "covalink.cn.evil.test")
        let raw = "/api/covers/recent-2.png?width=320&sig=aa%2Bbb"
        XCTAssertResolved(HomeArtwork.recentCover(try recent("rc-relative")),
                          equals: ArtworkFixture.production(raw), "账里若存了相对形态同样要补")
    }

    // MARK: 裁决本身不许把签名带进可读文本（硬边界 3）

    /// 拒绝文本**只有** host：签名住在查询串里，整串一旦进文本就可能进日志。
    func testRefusalTextCarriesHostOnlyAndNeverTheQuery() throws {
        let signed = "https://covers.evil.test/covers/x.png?sig=a%2Bb&token=never-log-me"
        let message = try XCTUnwrap(
            XCTAssertRefused(CovaArtworkResolution(serverValue: signed), host: "covers.evil.test")
        )
        for forbidden in ["sig", "a%2Bb", "token", "never-log-me", "/covers/x.png"] {
            XCTAssertFalse(message.contains(forbidden), "拒绝文本泄漏了 \(forbidden)：\(message)")
        }
    }
}
