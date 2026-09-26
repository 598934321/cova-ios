@testable import CovaCore
import Foundation
import XCTest

/// `GET /api/studio/create/works`（分页那一支）的契约面（DEVELOPMENT.md §4.7 / §5 P1-1）。
///
/// 本文件钉的都是**会被静默吃掉**的事，不是"能解出来"：
/// ① `favorited`/`disliked` 为 false 时服务端整个键不发 ⇒ 缺键读成 false 是**服务端行为**，
///    而"读不出布尔"必须与"缺键"分得开（`signalShapeDrift`）；
/// ② 行 id 的四种形状原样保留、同一 job 可多行、id 可整串重复 ⇒ 不许去重、不许改写；
/// ③ 一行坏形状不许把整页判死（那在屏上就是"你还没有作品"），但少掉的行必须数得出来；
/// ④ 请求编码（参数只有 `q/filter/sort/cursor/limit` 五个，别的键一个都不发）。
final class WorksListDTOTests: XCTestCase {

    // MARK: - ① favorited / disliked 的缺键语义

    /// fixture 的前提必须自己成立：**那两个键是真的没发**，不是发了 false。
    /// （否则下面"缺键读成 false"那条断言就是在测我自己写的 JSON。）
    func testFixtureOmitsTheSignalKeysEntirelyJustLikeTheServerDoes() throws {
        let root = try Fixture.value("works-list-page") as? [String: Any]
        let works = try XCTUnwrap(root?["works"] as? [[String: Any]], "fixture 形状不对")
        XCTAssertEqual(works.count, 6)
        // 前两行：favorite 与 dislike 都不是 true ⇒ 两个键整个缺席。
        for index in 0...1 {
            XCTAssertNil(works[index]["favorited"], "第 \(index) 行不该带 favorited 键")
            XCTAssertNil(works[index]["disliked"], "第 \(index) 行不该带 disliked 键")
        }
        // 只有第五行发了 disliked:true（第六行发了 favorited:true）。
        XCTAssertEqual(works[4]["disliked"] as? Bool, true)
        XCTAssertNil(works[4]["favorited"], "disliked 那行不该同时把 favorited 也发出来")
        XCTAssertEqual(works[5]["favorited"] as? Bool, true)
    }

    func testAbsentSignalKeysReadAsFalseAndPresentOnesReadAsTrue() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        XCTAssertEqual(page.works.count, 6, "六行一行都不许丢")
        XCTAssertEqual(page.unreadableItemCount, 0)

        let first = try XCTUnwrap(page.works.first)
        XCTAssertFalse(first.favorited)
        XCTAssertFalse(first.disliked)
        XCTAssertFalse(first.signalShapeDrift, "缺键是服务端的正常写法，不是形状漂移")

        let disliked = try XCTUnwrap(page.works.first(where: { $0.disliked }))
        XCTAssertEqual(disliked.id, "job-11aa:cand-1")
        XCTAssertFalse(disliked.favorited)

        let favorited = try XCTUnwrap(page.works.first(where: { $0.favorited }))
        XCTAssertEqual(favorited.id, "job-22bb:cand-2")
        XCTAssertFalse(favorited.disliked)
    }

    /// 显式 `null` 与缺键在语义上同义（服务端"false 就不发"，发了 null 也当 false），
    /// 而**非布尔的值**必须留下可见痕迹 —— 把 `"true"` 读成 false 是静默说谎。
    func testNullOrAbsentBothReadAsFalseWhileWrongTypedValueFlagsDrift() throws {
        let explicitNull = Data(#"{"works":[{"id":"j:c1","favorited":null,"disliked":null}]}"#.utf8)
        let nullPage = try JSONDecoder().decode(WorksPageDto.self, from: explicitNull)
        let nullRow = try XCTUnwrap(nullPage.works.first)
        XCTAssertFalse(nullRow.favorited)
        XCTAssertFalse(nullRow.signalShapeDrift, "显式 null 不是漂移：服务端那一档就是 false")

        let stringTrue = Data(#"{"works":[{"id":"j:c1","favorited":"true"}]}"#.utf8)
        let drifted = try JSONDecoder().decode(WorksPageDto.self, from: stringTrue)
        let driftRow = try XCTUnwrap(drifted.works.first)
        XCTAssertFalse(driftRow.favorited, "读不出布尔就只能落 false（不猜字符串 true 是真）")
        XCTAssertTrue(driftRow.signalShapeDrift, "但这件事必须看得见")
    }

    /// favorite 与 dislike 服务端互斥：两个同时为真只能是漂移，本层不替 UI 挑一个。
    func testBothSignalsTrueIsReportedAsConflictNotSilentlyResolved() throws {
        let data = Data(#"{"works":[{"id":"j:c1","favorited":true,"disliked":true}]}"#.utf8)
        let page = try JSONDecoder().decode(WorksPageDto.self, from: data)
        let row = try XCTUnwrap(page.works.first)
        XCTAssertTrue(row.signalConflict)
        XCTAssertEqual(page.conflictingSignalRows.count, 1)
    }

    // MARK: - ② id 的四种形状（原样保留）

    func testAllFourIDShapesAreClassifiedAndKeptVerbatim() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        let identities = page.works.map(\.identity)
        XCTAssertEqual(identities[0], .candidate(jobID: "job-7f3a", candidateID: "cand-1"))
        XCTAssertEqual(identities[2], .pendingPlaceholder(jobID: "job-9c2b", ordinal: "1"))
        XCTAssertEqual(identities[3], .bareJobID(jobID: "job-9c2b"))
        XCTAssertEqual(page.works.map(\.id), [
            "job-7f3a:cand-1", "job-7f3a:cand-2", "job-9c2b:pending-1", "job-9c2b",
            "job-11aa:cand-1", "job-22bb:cand-2",
        ], "id 必须逐字节原样，一个字符都不改写")
    }

    /// 三段 / 空段这类形状**不丢行**：原 id 还在，只是本层拒绝给它编语义。
    func testMalformedIdentifierIsKeptButClassifiedIrregular() {
        XCTAssertEqual(WorksRowIdentity(rawID: "a:b:c"), .irregular(rawID: "a:b:c"))
        XCTAssertEqual(WorksRowIdentity(rawID: ":cand").jobID, nil)
        XCTAssertEqual(WorksRowIdentity(rawID: "job:pending-").candidateID, "pending-")
        // `pending-` 没有序号不是契约里的占位形态 ⇒ 不自编 ordinal。
        XCTAssertNil(WorksRowIdentity.pendingOrdinal("pending-"))
        XCTAssertEqual(WorksRowIdentity.pendingOrdinal("pending-2"), "2")
    }

    /// 同一 job 两行、甚至整串 id 重复：本层不去重（去重 = 把服务端给的作品藏起来一行）。
    func testDuplicateAndJobSharedIDsAreNeverDeduplicated() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        XCTAssertEqual(page.rows(jobID: "job-7f3a").count, 2, "一次生成两行是常态")
        XCTAssertEqual(Set(page.rows(jobID: "job-7f3a").map(\.id)).count, 2)

        let duplicated = Data(
            #"{"works":[{"id":"j:c1","jobId":"j"},{"id":"j:c1","jobId":"j"},{"id":"j","jobId":"j"}],"total":3}"#
                .utf8
        )
        let twice = try JSONDecoder().decode(WorksPageDto.self, from: duplicated)
        XCTAssertEqual(twice.works.count, 3, "整串 id 重复也必须原样留着")
        XCTAssertEqual(twice.works.filter { $0.id == "j:c1" }.count, 2)
    }

    // MARK: - ③ 逐行容错（一行坏不连累整页，且少掉的行可解释）

    func testGarbageElementsAreCountedNotSilentlyDropped() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-garbage-rows")
        XCTAssertEqual(page.works.count, 1, "六个元素里唯一读得出身份的那行必须活着")
        XCTAssertEqual(page.unreadableItemCount, 5)
        XCTAssertEqual(page.total, 6)
        let survivor = try XCTUnwrap(page.works.first)
        XCTAssertEqual(survivor.id, "job-drift:cand-1")
        XCTAssertEqual(survivor.jobId, "job-drift")
    }

    /// 每个字段各自容错：坏类型 ⇒ 该字段 nil，**不**填默认值，也**不**毁掉整行。
    func testWrongTypedFieldsBecomeNilInsteadOfInventedDefaults() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-garbage-rows")
        let row = try XCTUnwrap(page.works.first)
        // duration 是字符串、status 是词表外的值、tags 是字符串、instrumental 是字符串、
        // modelVersion 是数字、createdAt 是数字、melody 是对象 —— 全部读成 nil。
        XCTAssertNil(row.duration)
        XCTAssertNil(row.status, "认不出的状态不许读成 failed")
        XCTAssertNil(row.tags, "tags 不是数组就是没给，不许包成 [\"流行,夏日\"]")
        XCTAssertNil(row.instrumental)
        XCTAssertNil(row.modelVersion)
        XCTAssertNil(row.melody)
        XCTAssertNil(row.createdAt)
        XCTAssertNil(row.providerClipId)
        // 而好的那几个键照常读出来（证明不是"整行降级成空"）。
        XCTAssertEqual(row.title, "形状漂了的一行")
        XCTAssertEqual(row.audioUrl?.rawValue, "/api/media/objects/mo_f12d83ad?ref=mr_67ff4cbf&intent=play")
        XCTAssertTrue(row.signalShapeDrift)
    }

    /// `tags` 的 `null` 与 `[]` 是两件事（服务端两个键都给过）⇒ 不合并。
    func testTagsNullAndEmptyAreDistinguishable() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        let pending = try XCTUnwrap(page.works.first(where: \.isPendingPlaceholder))
        XCTAssertEqual(pending.tags, [], "服务端发的是空数组，本层就留着空数组")
        let lyricless = try XCTUnwrap(page.works.first(where: { $0.lyrics == nil && !$0.isPendingPlaceholder }))
        XCTAssertNotNil(lyricless.tags, "这一行 tags 有内容；nil 只能来自服务端没发这个键")

        let nullTags = try JSONDecoder().decode(
            WorksPageDto.self, from: Data(#"{"works":[{"id":"j:c1","tags":null}]}"#.utf8)
        )
        XCTAssertNil(try XCTUnwrap(nullTags.works.first).tags)
    }

    /// 整个 `works` 键读不出来（不是数组）⇒ **抛**，不静默当空列表。
    /// 空列表在 19/20 屏是"你还没有作品"，那是完全不同的一句话。
    func testMissingOrWrongTypedWorksKeyThrowsInsteadOfReadingAsEmpty() {
        let bad: [Data] = [Data("{}".utf8), Data(#"{"works":null}"#.utf8),
                           Data(#"{"works":"none"}"#.utf8), Data("[]".utf8)]
        for item in bad {
            XCTAssertThrowsError(try JSONDecoder().decode(WorksPageDto.self, from: item))
        }
        XCTAssertNoThrow(try JSONDecoder().decode(WorksPageDto.self, from: Data(#"{"works":[]}"#.utf8)))
    }

    // MARK: - ④ 两条地址腿：audioUrl 能用、playbackUrl 不能用（D23）

    /// 生产实测形态：`audioUrl` 是**站内相对**路径 ⇒ 补上生产 origin 后可出站。
    func testRelativeAudioURLResolvesOntoTheProductionOrigin() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        let row = try XCTUnwrap(page.works.first)
        let url = try XCTUnwrap(row.resolvedAudioURL)
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(url), "\(url) 不是生产出口")
        XCTAssertEqual(url.path, "/api/media/objects/mo_f12d83ad")
        XCTAssertTrue(url.absoluteString.contains("intent=play"))
    }

    /// `playbackUrl` 是 uploads 桶的预签名直链：本端**不给 URL 出口**，
    /// 且那个桶**不在** D23 名单里（§7 #37）—— 这一条断言测的是"名单没被偷偷放宽"。
    func testPlaybackURLHasNoURLOutletAndItsRealBucketIsNotSanctioned() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        let row = try XCTUnwrap(page.works.first)
        let raw = try XCTUnwrap(row.playbackUrl?.rawValue)
        XCTAssertTrue(raw.hasPrefix("https://covalink-uploads-"), "fixture 钉的是实测那个桶的形态")
        XCTAssertFalse(
            CovaEnvironment.isSanctionedStorageHost(
                "covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com"
            ),
            "uploads 桶一旦进了名单，本文件与 §7 #37 就得同时改 —— 这条不许悄悄绿"
        )
        // 出口守卫亲口否认那条直链（这才是"不能用"的可断言形态，比"类型上没给方法"硬）。
        let direct = try XCTUnwrap(URL(string: raw))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(direct), "uploads 桶不是生产出口")
        XCTAssertFalse(CovaEnvironment.isSanctionedMediaURL(direct), "uploads 桶不在 D23 名单内")
        XCTAssertEqual(
            CovaEnvironment.mediaHopEgress(
                from: try XCTUnwrap(row.resolvedAudioURL), to: direct, carriesCredentials: true
            ),
            .refused,
            "音频腿追到那个桶必须被点名拒掉，而不是先试一次再当网络问题"
        )
    }

    /// 签名串不许从描述/反射里漏出来（TD-23 口径）。
    func testSignedURLsNeverSurfaceInDescriptions() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        let row = try XCTUnwrap(page.works.first)
        let playback = try XCTUnwrap(row.playbackUrl?.rawValue)
        let audio = try XCTUnwrap(row.audioUrl?.rawValue)
        for rendered in [String(describing: row), String(reflecting: row),
                        String(describing: page), String(reflecting: page)] {
            XCTAssertFalse(rendered.contains(playback), "泄漏了直链：\(rendered)")
            XCTAssertFalse(rendered.contains(audio), "泄漏了媒体地址：\(rendered)")
        }
        XCTAssertTrue(String(describing: row).contains("<redacted>"))
    }

    // MARK: - 可播性 / 展示口径

    func testPlayabilityExcludesPlaceholdersFailuresAndAudiolessRows() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        XCTAssertEqual(page.works.count, 6)
        XCTAssertEqual(page.playableWorks.count, 4, "占位行 + failed 行不算可播")
        XCTAssertEqual(page.placeholderWorks.count, 1)
        let pending = try XCTUnwrap(page.placeholderWorks.first)
        XCTAssertFalse(pending.isPlayable)
        XCTAssertFalse(pending.isRealCandidateRow)

        // 只有 playbackUrl、没有 audioUrl 的成功行：**本端不可播**（D23 那条腿走不通）。
        let fallbackOnly = try JSONDecoder().decode(
            WorksPageDto.self,
            from: Data(
                #"{"works":[{"id":"j:c1","status":"succeeded","playbackUrl":"https://uploads.invalid/a.mp3"}]}"#
                    .utf8
            )
        )
        let row = try XCTUnwrap(fallbackOnly.works.first)
        XCTAssertNil(row.audioUrl)
        XCTAssertFalse(row.isPlayable, "不许把名单桶直链算成本端能播")
    }

    func testEmptyTitleAndZeroDurationReadAsAbsentNotAsValues() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        let blank = try XCTUnwrap(page.works.first(where: { $0.id == "job-7f3a:cand-2" }))
        XCTAssertNil(blank.displayTitle, "空串标题不许显示成「空」，也不许由 DTO 编一个「未命名」")
        XCTAssertEqual(blank.title, "", "而原值仍留在行上：空串是服务端给的事实，不是本层造的")
        XCTAssertEqual(blank.displayDuration, 118.4, "这一行有真时长，不该被标题那格连累")

        let zero = try JSONDecoder().decode(
            WorksPageDto.self,
            from: Data(#"{"works":[{"id":"j:c1","duration":0,"title":"  "}]}"#.utf8)
        )
        let row = try XCTUnwrap(zero.works.first)
        XCTAssertNil(row.displayDuration, "0 是服务端的未分析形态，不是零秒")
        XCTAssertNil(row.displayTitle)
        XCTAssertEqual(row.duration, 0, "但原值仍在，UI 想知道就说想知道")
    }

    // MARK: - 请求编码（参数只有五个）

    func testFilterAndSortValueSetsMatchTheServerExactly() {
        XCTAssertEqual(
            WorksListFilter.allCases.map(\.rawValue),
            ["all", "generating", "vocal", "instrumental", "liked", "disliked", "cover",
             "extend", "remaster"]
        )
        XCTAssertEqual(WorksListSort.allCases.map(\.rawValue), ["newest", "oldest"])
        // 未知值服务端当 all ⇒ 客户端的恢复入口只认闭合词表，认不出来给 nil（不假装选中了）。
        XCTAssertNil(WorksListFilter.recognized("status"))
        XCTAssertEqual(WorksListFilter.recognized("liked"), .liked)
        XCTAssertNil(WorksListSort.recognized("popular"), "库曲那套 sort 值在作品端点不存在")
    }

    func testQueryItemsEncodeExactlyFivePossibleKeysInContractOrder() {
        let query = WorksListQuery(
            filter: .liked, search: "  夏夜  ", sort: .oldest,
            cursor: WorksListCursor("6"), limit: 40
        )
        XCTAssertEqual(
            query.queryItems.map { "\($0.name)=\($0.value ?? "")" },
            ["q=夏夜", "filter=liked", "sort=oldest", "cursor=6", "limit=40"]
        )
    }

    /// 缺位的键**不发**：空 `q` 与没有 cursor 都不该出现一个空值键。
    func testAbsentOptionalKeysAreNotEmitted() {
        let bare = WorksListQuery()
        XCTAssertEqual(
            bare.queryItems.map(\.name), ["filter", "sort", "limit"],
            "默认态：只有 filter/sort/limit 恒发"
        )
        XCTAssertEqual(bare.filter, .all)
        XCTAssertEqual(bare.sort, .newest, "newest 是服务端默认")
        XCTAssertEqual(bare.limit, 30, "服务端默认 30")
        for whitespace in ["", "   ", "\n\t"] {
            XCTAssertNil(WorksListQuery(search: whitespace).normalizedSearch)
            XCTAssertFalse(
                WorksListQuery(search: whitespace).queryItems.contains { $0.name == "q" },
                "不许发 q="
            )
        }
    }

    /// 契约里没有的参数，编码里也永远不许出现（那正是 E3a「筛选静默失效」的形状）。
    func testNoKeysTheServerDoesNotReadAreEverEmitted() {
        let forbidden = ["status", "offset", "page", "pageSize", "source", "id", "instrumental",
                         "limit2", "cursor2"]
        let selections: [WorksListQuery] = [
            WorksListQuery(), WorksListQuery(filter: .generating, search: "夏", sort: .oldest,
                                             cursor: WorksListCursor("60"), limit: 500),
            WorksListQuery(filter: .cover, limit: -7),
        ]
        for query in selections {
            for name in query.queryItems.map(\.name) {
                XCTAssertFalse(forbidden.contains(name), "发出了服务端不读的键：\(name)")
            }
            XCTAssertEqual(Set(query.queryItems.map(\.name)).subtracting(
                ["q", "filter", "sort", "cursor", "limit"]
            ).count, 0, "出现了第五个参数名之外的键")
        }
    }

    func testLimitIsClampedIntoTheServerWindowAtConstruction() {
        XCTAssertEqual(WorksListQuery.defaultLimit, 30)
        XCTAssertEqual(WorksListQuery.minimumLimit, 1)
        XCTAssertEqual(WorksListQuery.maximumLimit, 100)
        XCTAssertEqual(WorksListQuery(limit: 0).limit, 1)
        XCTAssertEqual(WorksListQuery(limit: -99).limit, 1)
        XCTAssertEqual(WorksListQuery(limit: 101).limit, 100)
        XCTAssertEqual(WorksListQuery(limit: 100_000).limit, 100)
        XCTAssertEqual(WorksListQuery(limit: 100).limit, 100)
        XCTAssertEqual(WorksListQuery(limit: 1).limit, 1)
    }

    /// cursor 是**字符串化的行偏移**（服务端 v1 简化）：原文回发、不当分页游标语义用。
    func testCursorKeepsRawTextAndOnlyReportsOffsetAsDiagnosis() throws {
        let cursor = try XCTUnwrap(WorksListCursor("6"))
        XCTAssertEqual(cursor.rawValue, "6")
        XCTAssertEqual(cursor.rowOffset, 6)
        let opaque = try XCTUnwrap(WorksListCursor("eyJvZmZzZXQiOjZ9"))
        XCTAssertEqual(opaque.rowOffset, nil, "读不出十进制就当读不出，不猜")
        XCTAssertNil(WorksListCursor(""), "空串不是游标")
        XCTAssertNil(WorksListCursor("   "))
        XCTAssertNil(WorksListCursor.next(nil), "nextCursor:null ⇒ 没有下一页")
    }

    func testPageAndQueryChainViaTheServerCursorOnly() throws {
        let page = try Fixture.decode(WorksPageDto.self, "works-list-page")
        XCTAssertEqual(page.nextCursor, "6", "实测 nextCursor 是字符串")
        XCTAssertEqual(page.total, 8, "total 是整表条数，不是本页行数")
        XCTAssertEqual(page.works.count, 6)
        XCTAssertTrue(page.hasMorePages)

        let first = WorksListQuery(filter: .all, limit: 6)
        let second = try XCTUnwrap(first.advanced(toNextCursor: page.nextCursor))
        XCTAssertEqual(second.cursor?.rawValue, "6")
        XCTAssertEqual(second.filter, first.filter)
        XCTAssertEqual(second.limit, first.limit)
        XCTAssertNil(first.advanced(toNextCursor: nil), "到底了就不该再发一次同样的请求")
    }

    func testEndpointPathIsTheSameOriginWorksPath() {
        XCTAssertEqual(WorksListQuery.path, "/api/studio/create/works")
        XCTAssertNotNil(CovaEnvironment.makeAPIURL(path: WorksListQuery.path,
                                                   queryItems: WorksListQuery().queryItems))
    }
}
