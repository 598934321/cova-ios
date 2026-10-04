import CovaCore
import XCTest

/// 「服务端会把 `bpm` / `energy` 发成 `null`」这条事实的钉死面。
///
/// 起因（2026-09-25 只读探针打 `https://covalink.cn/api/tracks`，400 行 ×
/// `sort=featured|newest|popular|downloads|favorites|duration_asc|bpm_asc` + `page=3&pageSize=50`）：
/// · `bpm: null`、`energy: null` 在真实列表里**成片存在**（featured 档首屏 20 行里 15 行 `energy` 为
///   null，两种 null 在 400 行的扫掠里都出现过）；
/// · 其余 17 个非可选字段实测**无一** null ⇒ 只有这两格是服务端可空，DTO 里也**只**放宽这两格。
///
/// 为什么必须有这一族用例：`TrackDto.bpm/energy` 曾被声明成非可选 ⇒ `JSONDecoder` 直接抛错 ⇒
/// `CatalogService.classify` 把 `.decoding` 报成「后端契约缺口 NEEDS-1」⇒ 03 曲库整屏错误态。
/// 缺陷在客户端，账却记在后端头上（AGENTS/NEEDS 的既有口径禁止），而 638 条测试全绿 ——
/// 因为**没有任何一条 fixture 在这两格里放 null**。本文件补的就是那只探针。
///
/// 探针可失败的证据（先在**未修**的代码上跑本类）：`Executed 8 tests, with 7 failures`
/// —— 7 条红全部是 `Expected value of type Int but found null instead. Path: …bpm`
/// 与 `Key 'bpm' not found`；第 8 条（类型不符必须抛错）修前修后都绿，它防的是「放宽变成宽容」。
/// 修复后本类全绿（11 条）。
final class TrackNullBpmEnergyDTOTests: XCTestCase {

    // MARK: - 探针本体：解得开吗（修复前这些用例必然红）

    /// 真实分页封套 `{page,pageSize,total,totalPages,tracks[]}`：一条给 `null`、一条**根本没有这两个键**。
    func testTrackPageEnvelopeWithNullAndAbsentBpmEnergyDecodes() throws {
        XCTAssertNoThrow(try Fixture.decode(TrackPageDto.self, "synthetic/track-page-null-bpm-energy"))
    }

    /// 收藏 feed 的库曲条目（`FavoriteItemDto.library`）走的是同一个 `TrackDto`。
    func testFavoritesLibraryItemWithNullBpmEnergyDecodes() throws {
        let data = try mutatedRows(
            from: "favorites-list", in: "tracks", nulling: ["bpm", "energy"]
        )
        XCTAssertNoThrow(try JSONDecoder().decode(FavoritesListDto.self, from: data))
    }

    /// 歌单详情的 `tracks[]` 也是 `TrackDto` 投影。
    func testPlaylistDetailTracksWithNullBpmEnergyDecodes() throws {
        let data = try mutatedRows(
            from: "playlist-detail", in: "tracks", nulling: ["bpm", "energy"]
        )
        XCTAssertNoThrow(try JSONDecoder().decode(PlaylistDetailDto.self, from: data))
    }

    /// 详情 `track` + `similar[]` **两套投影同时**带 null：`SimilarTrackDto` 也 declared 过非可选。
    func testTrackDetailBothProjectionsWithNullBpmEnergyDecode() throws {
        let data = try mutatedRows(
            from: "track-detail-real-1", in: "similar", nulling: ["bpm", "energy"]
        )
        XCTAssertNoThrow(try JSONDecoder().decode(TrackDetailDto.self, from: data))
    }

    /// `GET /api/tracks?similarTo=` 的独立封套。
    func testSimilarToPageWithNullBpmEnergyDecodes() throws {
        let data = try mutatedRows(
            from: "tracks-similar-to", in: "tracks", nulling: ["bpm", "energy"]
        )
        XCTAssertNoThrow(try JSONDecoder().decode(SimilarTrackPageDto.self, from: data))
    }

    /// 详情 `track` 单行（两格**整键缺席**，不是 null）——详情端点与列表端点是两次序列化。
    func testTrackDetailTrackWithoutBpmEnergyKeysDecodes() throws {
        let data = try mutatedRows(
            from: "track-detail-real-1", in: nil, nulling: ["bpm", "energy"], droppingKeys: true
        )
        XCTAssertNoThrow(try JSONDecoder().decode(TrackDetailDto.self, from: data))
    }

    // MARK: - 修复后的口径（nil 而不是 0 / ""；可空不等于宽容；行文案整段消失）

    /// 「不编造边界」：缺席就是缺席 —— `nil`，不是 `0`、不是 `""`。
    func testNullAndAbsentBpmEnergyDecodeToNilNotZeroOrEmpty() throws {
        let page = try Fixture.decode(TrackPageDto.self, "synthetic/track-page-null-bpm-energy")
        XCTAssertEqual(page.tracks.count, 2)
        for track in page.tracks {
            XCTAssertNil(track.bpm, "bpm 给了 null 或没给 ⇒ nil（不许是 0）")
            XCTAssertNil(track.energy, "energy 给了 null 或没给 ⇒ nil（不许是空串）")
        }
        // 封套其余四键仍是真数：放宽这两格不能顺手把 total/page 读没。
        XCTAssertEqual(page.total, 20425)
        XCTAssertEqual(page.page, 3)
        XCTAssertEqual(page.pageSize, 50)
        XCTAssertEqual(page.totalPages, 409)

        let similar = try Fixture.decode(SimilarTrackPageDto.self, "tracks-similar-to")
        let data = try mutatedRows(from: "tracks-similar-to", in: "tracks", nulling: ["bpm", "energy"])
        let nulled = try JSONDecoder().decode(SimilarTrackPageDto.self, from: data)
        XCTAssertEqual(nulled.tracks.count, similar.tracks.count)
        for item in nulled.tracks {
            XCTAssertNil(item.bpm, "similar 投影同理：nil 而不是 0")
            XCTAssertNil(item.energy)
            // 相邻必填格不许被顺手放宽（否则下一格 null 又会安静地变成 0）
            XCTAssertFalse(item.audioUrl.isEmpty)
            XCTAssertFalse(item.waveformPeaks.isEmpty)
        }
    }

    /// 可空 **≠** 宽容：类型不对必须照样抛错，否则真正的契约漂移会被 `nil` 吞掉。
    func testWrongTypedBpmEnergyStillFailsDecoding() throws {
        let badBpm = try mutatedRows(
            from: "track-page", in: "tracks", replacing: ["bpm": "快", "energy": 12]
        )
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPageDto.self, from: badBpm)) { error in
            XCTAssertTrue(error is DecodingError, "类型不符应抛 DecodingError，实际：\(error)")
        }
    }

    /// 行副文案的 BPM 段：按 07「可空/缺失规则」——`bpm` 为 0 或空 ⇒ **该段整块不进**，
    /// 不写 `BPM 0`、不写 `--`（03 §4 的行本身只规定 封面/标题+艺人/时长，BPM 是附加段）。
    func testBpmSegmentOmitsWhenAbsentOrZero() {
        XCTAssertEqual(TrackRowCopy.bpmSegment(96), "BPM 96")
        XCTAssertNil(TrackRowCopy.bpmSegment(nil), "没给 BPM ⇒ 整段不出现")
        XCTAssertNil(TrackRowCopy.bpmSegment(0), "0 按 07 的口径是「未分析」，不画 BPM 0")
        XCTAssertNil(TrackRowCopy.bpmSegment(-4), "负数不是节拍，不编一个")
    }

    /// 拼接只连**存在**的片段：少一段就少一个分隔符，不留悬挂的 ` · `。
    /// 时长走 `m:ss`（`durationSegment`），不再输出 `183s` 这种读不出来的形状。
    func testRowSubtitleJoinsOnlyPresentSegments() {
        XCTAssertEqual(
            TrackRowCopy.subtitle(artist: "艾丽丝·莫罗", durationSeconds: 183, bpm: 96),
            "艾丽丝·莫罗 · 3:03 · BPM 96"
        )
        XCTAssertEqual(
            TrackRowCopy.subtitle(artist: "艾丽丝·莫罗", durationSeconds: 183, bpm: nil),
            "艾丽丝·莫罗 · 3:03"
        )
        XCTAssertEqual(
            TrackRowCopy.subtitle(artist: "艾丽丝·莫罗", durationSeconds: nil, bpm: nil),
            "艾丽丝·莫罗"
        )
    }

    /// 时长段的边界形：0 秒是合法的 `0:00`；整分钟不丢秒位；负值整段不拼。
    func testDurationSegmentFormatsMinutesAndSeconds() {
        XCTAssertEqual(TrackRowCopy.durationSegment(0), "0:00")
        XCTAssertEqual(TrackRowCopy.durationSegment(9), "0:09")
        XCTAssertEqual(TrackRowCopy.durationSegment(60), "1:00")
        XCTAssertEqual(TrackRowCopy.durationSegment(138), "2:18")
        XCTAssertEqual(TrackRowCopy.durationSegment(3600), "60:00")
        XCTAssertNil(TrackRowCopy.durationSegment(nil))
        XCTAssertNil(TrackRowCopy.durationSegment(-1), "负值不是时长，不编一个")
    }

    /// 三屏（03 / 06 / 16）行副文案的**实际调用形状**：把解出来的 `nil` 交进去，
    /// 屏上既不会出现 `Optional(...)` / `BPM 0`，也不会出现悬空的 `·`。
    func testSubtitleFromNulledRowDropsTheWholeBpmSegment() throws {
        let page = try Fixture.decode(TrackPageDto.self, "synthetic/track-page-null-bpm-energy")
        for track in page.tracks {
            let artist = track.artistNameCn ?? track.artist.name
            let text = TrackRowCopy.subtitle(
                artist: artist, durationSeconds: Int(track.duration), bpm: track.bpm
            )
            let duration = Int(track.duration)
            XCTAssertEqual(
                text, "\(artist) · \(duration / 60):\(String(format: "%02d", duration % 60))",
                track.id
            )
            XCTAssertFalse(text.contains("BPM"), track.id)
            XCTAssertFalse(text.contains("nil"), track.id)
            XCTAssertFalse(text.hasSuffix("·"), track.id)
        }
    }

    // MARK: - fixture 变形工具

    /// 把 fixture 里的行取出来，按需要把某些键写成 `null`（NSNull）/ 删掉 / 换成错误类型，
    /// 再拼回同一份封套 —— 真实投影特征（camel vs snake、`featured` Bool vs 数字）全部保留。
    ///
    /// - Parameter key: 行数组在封套里的键；`nil` 表示封套里只有一个 `track` 对象（详情形态）。
    private func mutatedRows(
        from name: String,
        in key: String?,
        nulling fields: [String] = [],
        droppingKeys drop: Bool = false,
        replacing: [String: Any] = [:]
    ) throws -> Data {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.data(name)) as? [String: Any])
        var out = root
        func mutate(_ row: [String: Any]) -> [String: Any] {
            var row = row
            for field in fields {
                if drop { row[field] = nil } else { row[field] = NSNull() }
            }
            for (field, value) in replacing { row[field] = value }
            return row
        }
        if let key, let rows = root[key] as? [[String: Any]] {
            out[key] = rows.map(mutate)
        } else if let track = root["track"] as? [String: Any] {
            out["track"] = mutate(track)
        } else {
            XCTFail("fixture \(name) 里没有可变形的行（key=\(String(describing: key))）")
        }
        return try JSONSerialization.data(withJSONObject: out)
    }
}
