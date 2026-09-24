import CovaCore
import XCTest

final class LibraryDTOTests: XCTestCase {
    func testDecodesTrackPageRealListProjection() throws {
        let page = try Fixture.decode(TrackPageDto.self, "track-page")
        XCTAssertEqual(page.tracks.count, 3)
        XCTAssertEqual(page.total, 19562)
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.pageSize, 20)
        XCTAssertEqual(page.totalPages, 979)

        let track = page.tracks[0]
        XCTAssertEqual(track.id, "library-9749cdc210a624de9d0da02e")
        XCTAssertEqual(track.featured, false)
        XCTAssertEqual(track.previewStart, 167.02)
        XCTAssertEqual(track.previewEnd, 186.67)
        XCTAssertEqual(track.bpm, 76)
        XCTAssertEqual(track.style, "民谣")
        XCTAssertEqual(track.styleCn, "民谣")
        XCTAssertEqual(track.artist.countryFlag, "🇫🇷")
        XCTAssertEqual(track.artist.coreInstruments, "[\"钢琴\", \"大提琴\", \"弦乐四重奏\"]")
        XCTAssertNil(track.lyrics)
        XCTAssertNil(track.description)
        XCTAssertNil(track.audioDuration)
        XCTAssertNil(track.lyricistName)
        XCTAssertEqual(track.variantCount, 0)
        XCTAssertEqual(track.variants?.count, 0)
        XCTAssertEqual(track.waveformPeaks.count, 8)
        XCTAssertEqual(track.scenes, ["悬疑惊悚"])
        XCTAssertEqual(track.energy, "中")
        XCTAssertFalse(track.tags.isEmpty)
    }

    func testListProjectionUsesCamelCasePreviewAndBoolFeatured() throws {
        // 与 similar 投影的差异在此固化：列表是 camelCase preview + Bool featured
        let raw = try Fixture.value("track-page") as? [String: Any]
        let tracks = try XCTUnwrap(raw?["tracks"] as? [[String: Any]])
        for track in tracks {
            XCTAssertNotNil(track["previewStart"], "列表投影应有 camelCase previewStart")
            XCTAssertNotNil(track["previewEnd"], "列表投影应有 camelCase previewEnd")
            XCTAssertTrue(track["featured"] is Bool, "列表投影 featured 应为 Bool")
        }
    }

    func testDecodesRealTrackDetailWithSimilarProjection() throws {
        let detail = try Fixture.decode(TrackDetailDto.self, "track-detail-real-1")
        XCTAssertEqual(detail.track.id, "library-203506629c0d69e0b198b42e")
        XCTAssertEqual(detail.track.featured, false)
        // 详情 track 无 variant 字段族（真实形态，NEEDS #8）
        XCTAssertNil(detail.track.variants)
        XCTAssertNil(detail.track.variantCount)

        let similar = try XCTUnwrap(detail.similar)
        XCTAssertEqual(similar.count, 4)
        let first = try XCTUnwrap(similar.first)
        XCTAssertEqual(first.id, "library-d0af74d83c9b7cc578043024")
        XCTAssertEqual(first.title.isEmpty, false)
        XCTAssertEqual(first.cover.hasPrefix("https://"), true)
        XCTAssertEqual(first.duration > 0, true)
        XCTAssertEqual(first.bpm > 0, true)
        // R16-1：这里原本钉的是 `first.audioUrl.hasPrefix("https://")` —— 那是 2026-09-17
        // 回灌时的形态，而 2026-09-24 实测 `GET /api/tracks` 的 20/20 行都是**相对路径**。
        // 「以 https 开头」这条断言正是缺陷逃过去的原因：它把当时的**拼写**当成了契约，
        // 于是客户端只写对了绝对地址那一半。改钉成真正要紧的不变量：**这串值必须能被
        // 补成可出站的绝对地址**（两种拼写都放行），相对形态另有专门 fixture 覆盖。
        XCTAssertNotNil(CovaEnvironment.resolveMediaURL(first.audioUrl))
        XCTAssertEqual(URL(string: try XCTUnwrap(first.audioUrl))?.scheme, "https")
        XCTAssertEqual(first.waveformPeaks.count, 8)
        XCTAssertEqual(first.previewStart, 207.77)
        XCTAssertEqual(first.previewEnd > first.previewStart, true)
        XCTAssertEqual(first.playCount, 0)
        XCTAssertEqual(first.createdAt?.isEmpty, false)
        XCTAssertEqual(first.artist.name, "Amara Okafor")
        XCTAssertEqual(first.artist.nameCn, "阿玛拉·奥卡福")
        XCTAssertEqual(first.artist.id, "A06")
        XCTAssertNil(first.artist.country)
        XCTAssertEqual(first.similarityScore, 111)
        // 真实响应里相似度分既有 int 也有 float（110.75），必须都能解码
        XCTAssertEqual(similar[1].similarityScore, 110.75)
        XCTAssertEqual(first.tags.first?.dimension, "instrument")
        XCTAssertEqual(first.tags.first?.value, "合成器")
        XCTAssertNil(first.tags.first?.trackId, "similar 的 tags 元素无 trackId")
        XCTAssertEqual(first.isFeatured, false)
    }

    func testBothRealTrackDetailsDecodeWithNonEmptySimilar() throws {
        for name in ["track-detail-real-1", "track-detail-real-2"] {
            let detail = try Fixture.decode(TrackDetailDto.self, name)
            XCTAssertFalse(detail.track.id.isEmpty, name)
            let similar = try XCTUnwrap(detail.similar, name)
            XCTAssertFalse(similar.isEmpty, "\(name) 的 similar 不应为空")
            for item in similar {
                XCTAssertFalse(item.id.isEmpty)
                XCTAssertFalse(item.title.isEmpty)
                XCTAssertFalse(item.audioUrl.isEmpty)
                XCTAssertFalse(item.waveformPeaks.isEmpty)
                XCTAssertFalse(item.displayLabels.isEmpty)
                XCTAssertFalse(item.artist.id.isEmpty)
            }
        }
    }

    /// 回归守卫（M-1）：真实投影的特征必须留在 fixture 里。
    /// 若有人再把 fixture 改写成「贴合自己模型的示例」，本条会失败。
    func testSimilarFixtureKeepsRealProjectionShape() throws {
        let raw = try Fixture.value("track-detail-real-1") as? [String: Any]
        let similar = try XCTUnwrap(raw?["similar"] as? [[String: Any]])
        XCTAssertFalse(similar.isEmpty)
        for item in similar {
            XCTAssertNotNil(item["preview_start"], "similar 必须保留 snake_case preview_start")
            XCTAssertNotNil(item["preview_end"], "similar 必须保留 snake_case preview_end")
            XCTAssertNil(item["previewStart"], "similar 不应有 camelCase previewStart（真实投影无）")
            XCTAssertNil(item["previewEnd"], "similar 不应有 camelCase previewEnd（真实投影无）")
            XCTAssertNil(item["playCount"], "similar 不应有 camelCase playCount")
            XCTAssertNotNil(item["play_count"])
            XCTAssertNil(item["createdAt"], "similar 不应有 camelCase createdAt")
            XCTAssertNotNil(item["created_at"])
            let featured = try XCTUnwrap(item["featured"])
            let encoded = try JSONSerialization.data(withJSONObject: ["v": featured])
            XCTAssertEqual(
                String(data: encoded, encoding: .utf8),
                #"{"v":0}"#,
                "similar.featured 必须是数字 0/1，而非布尔"
            )
        }
    }

    func testSimilarFeaturedAcceptsNonZeroNumber() throws {
        let json = try Fixture.data("track-detail-real-1")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        var similar = try XCTUnwrap(root["similar"] as? [[String: Any]])
        similar[0]["featured"] = 1
        root["similar"] = similar
        let mutated = try JSONSerialization.data(withJSONObject: root)
        let detail = try JSONDecoder().decode(TrackDetailDto.self, from: mutated)
        XCTAssertEqual(detail.similar?.first?.featured, 1)
        XCTAssertEqual(detail.similar?.first?.isFeatured, true)
    }

    func testSyntheticTrackWithVariantsDecodesAndIgnoresUnknownFields() throws {
        let page = try Fixture.decode(TrackPageDto.self, "synthetic/track-with-variants")
        XCTAssertEqual(page.tracks.count, 1)
        let track = page.tracks[0]
        XCTAssertEqual(track.id, "library-synthetic-0001")
        XCTAssertEqual(track.variantGroupId, "group-synthetic")
        XCTAssertEqual(track.variantCount, 2)
        XCTAssertEqual(track.variants?.count, 2)
        XCTAssertEqual(track.variants?[1].variantRole, "B")
    }

    func testMissingRequiredTrackFieldFailsDecoding() {
        let json = Data(#"{"tracks":[{"title":"no id"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPageDto.self, from: json)) { error in
            guard let decoding = error as? DecodingError else { return XCTFail("应为 DecodingError") }
            XCTAssertEqual(CovaAPIError.classify(decoding: decoding), .decoding(field: "id"))
        }
    }

    // MARK: - similarTo 列表（similar 投影，专属封套）

    func testDecodesSimilarToPageWithSimilarProjection() throws {
        let page = try Fixture.decode(SimilarTrackPageDto.self, "tracks-similar-to")
        XCTAssertEqual(page.tracks.count, 5)
        XCTAssertEqual(page.total, 5)
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.pageSize, 5)
        XCTAssertEqual(page.totalPages, 1)
        XCTAssertEqual(page.similarTo, "library-9749cdc210a624de9d0da02e")

        let first = page.tracks[0]
        XCTAssertEqual(first.id, "library-5d8e91cab645b44c8ab12169")
        XCTAssertEqual(first.featured, 0)
        XCTAssertEqual(first.isFeatured, false)
        XCTAssertEqual(first.previewStart, 161.25)
        XCTAssertEqual(first.previewEnd, 182.01)
        XCTAssertEqual(first.similarityScore, 111)
        XCTAssertEqual(first.playCount, 0)
        XCTAssertEqual(first.createdAt?.isEmpty, false)
        XCTAssertEqual(first.waveformPeaks.count, 8)
        XCTAssertEqual(first.tags.first?.dimension, "instrument")
        XCTAssertNil(first.tags.first?.trackId)
        XCTAssertEqual(first.artist.id, "A07")
        XCTAssertNil(first.artist.country)
        // 同一响应内 similarityScore 混用 int / float
        XCTAssertEqual(page.tracks[1].similarityScore, 110.25)
    }

    /// 真实投影守卫：similarTo 的 `tracks[]` 必须保持 similar 投影特征。
    func testSimilarToFixtureKeepsRealProjectionShape() throws {
        let raw = try Fixture.value("tracks-similar-to") as? [String: Any]
        XCTAssertEqual(raw?["similarTo"] as? String, "library-9749cdc210a624de9d0da02e")
        let tracks = try XCTUnwrap(raw?["tracks"] as? [[String: Any]])
        XCTAssertEqual(tracks.count, 5)
        for track in tracks {
            XCTAssertNotNil(track["preview_start"], "similarTo 投影应为 snake_case preview_start")
            XCTAssertNil(track["previewStart"], "similarTo 投影不应有 camelCase previewStart")
            XCTAssertNil(track["playCount"])
            XCTAssertNil(track["createdAt"])
            XCTAssertNotNil(track["similarityScore"])
            let featured = try XCTUnwrap(track["featured"])
            let encoded = try JSONSerialization.data(withJSONObject: ["v": featured])
            XCTAssertEqual(String(data: encoded, encoding: .utf8), #"{"v":0}"#, "similarTo.featured 必须是数字")
        }
    }

    /// 两套投影必须保持可区分：similarTo 载荷**不得**被宽松成普通列表 DTO。
    /// 若把 `TrackPageDto` 放宽（容忍数字 featured / 可选化 preview*），本条会失败 —— 这是刻意守卫。
    func testSimilarToPayloadIsNotDecodableAsNormalTrackPage() throws {
        let data = try Fixture.data("tracks-similar-to")
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPageDto.self, from: data)) { error in
            guard let decoding = error as? DecodingError else { return XCTFail("应为 DecodingError") }
            XCTAssertEqual(CovaAPIError.classify(decoding: decoding), .decoding(field: "featured"))
        }
        // 反向：普通列表载荷仍必须能解成 TrackPageDto（未弱化）
        XCTAssertNoThrow(try Fixture.decode(TrackPageDto.self, "track-page"))
    }

    /// TD-16 反向守卫：普通列表载荷**不得**被 similar 投影 DTO 解出（两套投影互斥）。
    func testNormalTrackPageIsNotDecodableAsSimilarProjection() throws {
        let data = try Fixture.data("track-page")
        XCTAssertThrowsError(try JSONDecoder().decode(SimilarTrackPageDto.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "应为 DecodingError，实际：\(error)")
        }
    }

    /// TD-15：投影判别必须按「similarTo 非空」，空串/空白等同未传（普通列表投影）。
    func testProjectionDiscriminationUsesNonEmptySimilarTo() {
        XCTAssertEqual(TrackListProjection.forSimilarTo(nil), .normal)
        XCTAssertEqual(TrackListProjection.forSimilarTo(""), .normal)
        XCTAssertEqual(TrackListProjection.forSimilarTo("   "), .normal)
        XCTAssertEqual(TrackListProjection.forSimilarTo("\n"), .normal)
        XCTAssertEqual(TrackListProjection.forSimilarTo("library-1"), .similar)
        XCTAssertEqual(TrackListProjection.forSimilarTo(" library-1 "), .similar)
    }

    func testDecodesTrackPreviewUrl() throws {
        let preview = try Fixture.decode(TrackPreviewUrlDto.self, "track-preview-url")
        XCTAssertEqual(preview.url.hasPrefix("https://"), true)
        XCTAssertEqual(preview.previewStart, 167.02)
        XCTAssertEqual(preview.previewEnd, 186.67)
        XCTAssertEqual(preview.duration, 209.592)
    }

    func testTrackPreviewUrlToleratesMissingDuration() throws {
        let json = Data(#"{"url":"https://cdn.invalid/a.mp3","previewStart":1.0,"previewEnd":2.0}"#.utf8)
        let preview = try JSONDecoder().decode(TrackPreviewUrlDto.self, from: json)
        XCTAssertNil(preview.duration)
        XCTAssertEqual(preview.previewStart, 1.0)
    }

    func testDecodesPlaylistListWithSaveState() throws {
        let list = try Fixture.decode(PlaylistListDto.self, "playlists")
        XCTAssertEqual(list.playlists.count, 2)
        let playlist = list.playlists[0]
        XCTAssertEqual(playlist.id, "PL-20260917-09")
        XCTAssertEqual(playlist.trackCount, 10)
        XCTAssertEqual(playlist.isSaved, false)
        XCTAssertEqual(playlist.writable, false)
        XCTAssertEqual(
            playlist.disabledReason,
            "官方歌单使用收藏，不会复制为个人歌单；加入歌曲请选择个人或项目歌单"
        )
        XCTAssertEqual(playlist.coverMode, "fallback")
        XCTAssertNil(playlist.coverDefault)
        XCTAssertNil(playlist.coverAlt)
        XCTAssertNil(playlist.scene)
        XCTAssertNil(playlist.savedAt, "列表响应不含 savedAt")
        XCTAssertEqual(playlist.coverMedia?.alt, playlist.titleCn)
        XCTAssertEqual(playlist.coverMedia?.fit, "cover")
        XCTAssertEqual(playlist.coverMedia?.focalX, 50)
        XCTAssertEqual(playlist.coverMedia?.focalY, 50)
        XCTAssertEqual(playlist.coverMedia?.mode, "fallback")
        XCTAssertNil(playlist.coverMedia?.updatedAt)
        XCTAssertEqual(playlist.saveAction?.kind, "bookmark")
        XCTAssertEqual(playlist.saveAction?.saved, false)
        XCTAssertEqual(playlist.saveAction?.endpoint, "/api/saved-playlists")
        XCTAssertEqual(playlist.saveAction?.addMethod, "POST")
        XCTAssertEqual(playlist.saveAction?.removeMethod, "DELETE")
        XCTAssertEqual(playlist.cover?.hasPrefix("https://cdn.invalid/"), true)
    }

    func testPlaylistDetailOmitsSaveStateAndStillDecodes() throws {
        let detail = try Fixture.decode(PlaylistDetailDto.self, "playlist-detail")
        XCTAssertEqual(detail.playlist.id, "PL-20260917-09")
        XCTAssertNil(detail.playlist.isSaved)
        XCTAssertNil(detail.playlist.writable)
        XCTAssertNil(detail.playlist.disabledReason)
        XCTAssertNil(detail.playlist.saveAction)
        XCTAssertEqual(detail.tracks?.count, 2)
        XCTAssertEqual(detail.tracks?[0].id, "library-8140d670bee74e9e061ab5be")
    }

    func testDecodesTaxonomyTwelveDimensions() throws {
        let taxonomy = try Fixture.decode(TaxonomyDto.self, "taxonomy")
        let dims = taxonomy.taxonomy
        XCTAssertEqual(dims.scene?.count, 2)
        XCTAssertEqual(dims.mood?.count, 2)
        XCTAssertEqual(dims.genre?.count, 2)
        XCTAssertEqual(dims.subgenre?.count, 2)
        XCTAssertEqual(dims.style?.count, 2)
        XCTAssertEqual(dims.instrument?.count, 2)
        XCTAssertEqual(dims.attribute?.count, 2)
        XCTAssertEqual(dims.energy?.count, 2)
        XCTAssertEqual(dims.tag?.count, 2)
        XCTAssertEqual(dims.vocalType?.count, 2)
        XCTAssertEqual(dims.type?.count, 2)
        XCTAssertEqual(dims.musicalKey?.count, 2)

        let term = try XCTUnwrap(dims.scene?.first)
        XCTAssertEqual(term.id, "短视频/Vlog")
        XCTAssertEqual(term.label, "短视频/Vlog")
        XCTAssertEqual(term.aliases, ["短视频", "Vlog", "片头"])
        XCTAssertEqual(term.active, true)
        XCTAssertEqual(term.source, "taxonomy-v3-20260806")
        XCTAssertEqual(term.sortOrder, 0)
        XCTAssertEqual(term.version, 1)
    }

    func testTaxonomyToleratesMissingDimensionsAndTerms() throws {
        let json = Data(#"{"taxonomy":{"scene":[{"id":"x"}]}}"#.utf8)
        let taxonomy = try JSONDecoder().decode(TaxonomyDto.self, from: json)
        XCTAssertEqual(taxonomy.taxonomy.scene?.count, 1)
        XCTAssertEqual(taxonomy.taxonomy.scene?[0].id, "x")
        XCTAssertNil(taxonomy.taxonomy.scene?[0].label)
        XCTAssertNil(taxonomy.taxonomy.genre)
        XCTAssertNil(taxonomy.taxonomy.musicalKey)
    }

    func testMissingTaxonomyEnvelopeFailsDecoding() {
        XCTAssertThrowsError(try JSONDecoder().decode(TaxonomyDto.self, from: Data("{}".utf8)))
    }

    // MARK: - `GET /api/tracks` 的查询编码（E3a）
    //
    // 服务端真实契约（2026-09-24 只读实测 `https://covalink.cn/api/tracks`，与 `web` 仓
    // `src/app/api/tracks/route.ts` 的 `searchParams.get('search')` / `getAll(<维度名>)` 互证；
    // 探针只看行数与 `total`，不回显任何响应值）：
    // · 基线 `pageSize=100` → total 20324；
    // · `search=zzzznotaterm` → 0（生效）；`q=` / `keyword=` → 20324（**被忽略**）；
    // · `dimension=mood&term=…` → 20324（**被忽略**）；`mood=zzzznotaterm` / `scene=` / `genre=`
    //   / `style=` / `type=` / `vocalType=` / `energy=` 各自 → 0（**维度名就是参数名**）；
    // · 多选 = **重复同名参数**（维度内 OR）：`energy=高` → 7178、`energy=中` → 3393、
    //   `energy=高&energy=中` → **10571 = 7178 + 3393**（精确相加 ⇒ 两个值都进了同一维度）；
    //   逗号串 `energy=高,中` → 7178（等于单值 ⇒ 逗号不是该编码）。

    /// 编码后的**真实查询串**（`percentEncodedQuery` 保留转义；`URL.query` 是解码后的，不能用）。
    private func encodedTrackListQuery(_ query: TrackListQuery) throws -> String {
        let url = try XCTUnwrap(
            CovaEnvironment.makeAPIURL(path: "/api/tracks", queryItems: query.queryItems),
            "编码后的地址必须过 D10 出口守卫"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(components.percentEncodedQuery)
    }

    /// 解码回 `name=value` 列表（断言可读；元组不成 `Equatable`，故合并成字符串）。
    private func decodedQueryPairs(_ query: TrackListQuery) throws -> [String] {
        let url = try XCTUnwrap(
            CovaEnvironment.makeAPIURL(path: "/api/tracks", queryItems: query.queryItems)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return (components.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
    }

    func testTrackListQueryEncodesTextSearchAsSearchKey() throws {
        XCTAssertEqual(
            try encodedTrackListQuery(TrackListQuery(search: "深夜电台")),
            "page=1&pageSize=20&search=%E6%B7%B1%E5%A4%9C%E7%94%B5%E5%8F%B0"
        )
        // 反向钉子：服务端不读的 `q` 不得再出现在查询里。
        XCTAssertFalse(try encodedTrackListQuery(TrackListQuery(search: "深夜电台")).contains("q="))
    }

    func testTrackListQueryUsesDimensionNameAsTheParameterKey() throws {
        let query = TrackListQuery(dimension: "mood", terms: ["宁静"])
        XCTAssertEqual(
            try decodedQueryPairs(query),
            ["page=1", "pageSize=20", "mood=宁静"]
        )
        let names = try decodedQueryPairs(query).map { String($0.prefix(while: { $0 != "=" })) }
        XCTAssertFalse(names.contains("dimension"), "`dimension=` 服务端从不读（实测 = 基线）")
        XCTAssertFalse(names.contains("term"), "`term=` 服务端从不读（实测 = 基线）")
    }

    func testTrackListQueryEncodesMultiSelectAsRepeatedKeys() throws {
        let query = TrackListQuery(dimension: "energy", terms: ["高", "中"], page: 2, pageSize: 8)
        XCTAssertEqual(
            try decodedQueryPairs(query),
            ["page=2", "pageSize=8", "energy=高", "energy=中"]
        )
        XCTAssertEqual(
            try encodedTrackListQuery(query),
            "page=2&pageSize=8&energy=%E9%AB%98&energy=%E4%B8%AD"
        )
    }

    /// 多选 + 文本检索 + 按艺人筛**同时**成立（三键互不吞没，顺序固定可断言）。
    func testTrackListQueryCombinesSearchDimensionsAndArtist() throws {
        let query = TrackListQuery(
            dimension: "scene", terms: ["短视频/Vlog", "广告"],
            search: "钢琴", artistID: "A06", page: 3, pageSize: 20
        )
        XCTAssertEqual(
            try decodedQueryPairs(query),
            [
                "page=3", "pageSize=20", "artistId=A06",
                "search=钢琴", "scene=短视频/Vlog", "scene=广告",
            ]
        )
    }

    /// 空白筛选**不发键**：`search=`（空值）在服务端等价于未传，但会把缓存键污染成两套形态。
    func testTrackListQueryDropsBlankAndEmptyFilters() throws {
        XCTAssertEqual(
            try encodedTrackListQuery(
                TrackListQuery(dimension: "  ", terms: ["", "  "], search: "   ", artistID: " ")
            ),
            "page=1&pageSize=20"
        )
        // 有维度名但没有词条 ⇒ 只发分页（发 `mood=` 空值等于没筛，还会伪装成"已筛"）。
        XCTAssertEqual(
            try encodedTrackListQuery(TrackListQuery(dimension: "mood")),
            "page=1&pageSize=20"
        )
    }

    /// 维度名直接当参数名 ⇒ **语法**门槛是注入面（`a=b&c` 这类名字会把查询改写）。
    /// 门槛只校验形态，不维护"合法维度白名单"：词表由服务端 `getAll(<名>)` 逐名读，
    /// 客户端再抄一份就会在新维度上线时静默吞掉筛选。
    func testTrackListQueryRejectsMalformedDimensionNames() throws {
        for name in ["mo od", "a=b", "x&y", "能量", "sc/ene", "", "-", String(repeating: "a", count: 40)] {
            XCTAssertEqual(
                try encodedTrackListQuery(TrackListQuery(dimension: name, terms: ["高"])),
                "page=1&pageSize=20",
                "非法维度名「\(name)」不得进查询"
            )
        }
        // 合法形态放行（含 camelCase 的 `vocalType`，服务端就是这么读的）。
        XCTAssertEqual(
            try encodedTrackListQuery(TrackListQuery(dimension: "vocalType", terms: ["vocal"])),
            "page=1&pageSize=20&vocalType=vocal"
        )
    }

    /// 分页两键恒在：服务端 `page`/`pageSize` 缺失时按 1/20 处理，但显式发出才能让
    /// 「同一筛选 = 同一地址」这条断言成立（也便于缓存与日志对齐）。
    func testTrackListQueryKeepsPaginationAlwaysPresent() throws {
        XCTAssertEqual(try encodedTrackListQuery(TrackListQuery()), "page=1&pageSize=20")
        XCTAssertEqual(
            try encodedTrackListQuery(TrackListQuery(page: 7, pageSize: 100)),
            "page=7&pageSize=100"
        )
    }

    /// R16-1：`GET /api/tracks` 的 `audioUrl` 线上实测是**相对路径**（2026-09-24 只读探针，
    /// 20/20 行；服务端把整曲桶转私有读后只发本站 `preview-stream` 端点），
    /// 而全部既有真实回灌 fixture 都是绝对地址 —— **解码与补全这两条腿从没覆盖过真实形态**。
    /// 本条钉三件事：① 相对值照样能解码（`TrackDto.audioUrl` 是必填 String）；
    /// ② 补全结果是同源绝对地址且过出口守卫（缺这一步就是「整库静默不可播」）；
    /// ③ 同一份数据里 `cover` 仍是绝对直链 —— 两种拼写并存正是缺陷看不见的原因（画面正常）。
    func testRelativeAudioUrlFixtureDecodesAndResolvesToProductionOrigin() throws {
        let page = try Fixture.decode(TrackPageDto.self, "synthetic/track-page-relative-audio")
        XCTAssertEqual(page.tracks.count, 3)
        for track in page.tracks {
            XCTAssertFalse(track.audioUrl.isEmpty, track.id)
            XCTAssertEqual(track.audioUrl.hasPrefix("/api/tracks/"), true, "真实形态是站内代理端点")
            XCTAssertEqual(track.audioUrl.hasPrefix("//"), false, "不许是协议相对")
            let audio = try XCTUnwrap(CovaEnvironment.resolveMediaURL(track.audioUrl), track.id)
            XCTAssertEqual(audio.absoluteString, "https://covalink.cn\(track.audioUrl)")
            XCTAssertTrue(CovaEnvironment.isProductionOrigin(audio))
            let cover = try XCTUnwrap(CovaEnvironment.resolveMediaURL(track.cover), track.id)
            XCTAssertEqual(cover.absoluteString, track.cover)
        }
    }
}
