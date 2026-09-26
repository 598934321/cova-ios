import CovaCore
import Foundation
import XCTest
@testable import CovaPlayer

/// 地址与曲目身份：安全面（脱敏 / 不可持久化）+ 校验面。
final class PlaybackItemTests: XCTestCase {
    private let signedURL = URL(string: "https://cdn.covalink.example/audio/a.m4a?sig=deadbeefSECRET&q-time=1700")!

    // MARK: - AudioURL 脱敏（AGENTS 硬边界 3 / D7）

    func testDescriptionNeverEchoesQuery() throws {
        let url = try AudioURL(https: signedURL)
        let described = String(describing: url)
        XCTAssertFalse(described.contains("deadbeefSECRET"), described)
        XCTAssertFalse(described.contains("q-time"), described)
        XCTAssertFalse(described.contains("sig="), described)
        XCTAssertTrue(described.hasPrefix("https://"))
    }

    func testDebugDescriptionAndDumpAlsoRedact() throws {
        let url = try AudioURL(https: signedURL)
        XCTAssertFalse(url.debugDescription.contains("deadbeefSECRET"))
        var dumped = ""
        dump(url, to: &dumped)
        XCTAssertFalse(dumped.contains("deadbeefSECRET"), dumped)
        let mirrored = Mirror(reflecting: url)
        let children = mirrored.children.map { "\($0.label ?? "")=\($0.value)" }.joined(separator: "|")
        XCTAssertFalse(children.contains("deadbeefSECRET"), children)
    }

    func testWrappedInCollectionStillRedacts() throws {
        let url = try AudioURL(https: signedURL)
        let wrapped: [String: [AudioURL?]] = ["item": [url]]
        let described = String(describing: wrapped)
        XCTAssertFalse(described.contains("deadbeefSECRET"), described)
    }

    func testLocalizedFileURLDoesNotEchoPathQuery() throws {
        let url = try AudioURL(file: URL(fileURLWithPath: "/private/var/containers/Cova/a.covaud"))
        XCTAssertFalse(String(describing: url).contains("a.covaud"))
        XCTAssertTrue(url.isLocalized)
    }

    /// 结构性达成签名地址不可持久化：整条链路上都不存在 Encodable 通路。
    func testSignedURLIsNotEncodable() throws {
        let url = try AudioURL(https: signedURL)
        XCTAssertNil(url as? any Encodable)
        let item = TestItems.make("t1", source: .bearerRequired(url))
        XCTAssertNil(item as? any Encodable)
        let queue = PlayQueue(items: [item])
        XCTAssertNil(queue as? any Encodable)
        XCTAssertNil(queue.current as? any Encodable)
    }

    func testLoopModeIsPersistableButCarriesNoAddress() throws {
        let data = try JSONEncoder().encode(LoopMode.one)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"one\"")
        XCTAssertEqual(try JSONDecoder().decode(LoopMode.self, from: data), .one)
    }

    // MARK: - AudioURL 校验（fail-closed）

    func testHTTPSRejectsInsecureAndMalformedForms() {
        XCTAssertThrowsError(try AudioURL(https: URL(string: "http://cdn.example.com/a.m4a")!))
        XCTAssertThrowsError(try AudioURL(https: URL(string: "file:///tmp/a.m4a")!))
        XCTAssertThrowsError(try AudioURL(https: URL(string: "https://cdn.example.com")!))
        XCTAssertThrowsError(try AudioURL(https: URL(string: "https://user:pw@cdn.example.com/a.m4a")!))
        XCTAssertThrowsError(try AudioURL(https: URL(string: "ftp://cdn.example.com/a.m4a")!))
    }

    func testFileRejectsSchemeConfusionAndQuery() {
        XCTAssertThrowsError(try AudioURL(file: URL(string: "https://cdn.example.com/a.m4a")!))
        XCTAssertThrowsError(try AudioURL(file: URL(string: "file:///tmp/a.mp3?sig=1")!))
        XCTAssertThrowsError(try AudioURL(file: URL(string: "file:///tmp/a.mp3#frag")!))
        XCTAssertNoThrow(try AudioURL(file: URL(fileURLWithPath: "/tmp/a.mp3")))
    }

    func testValueStillReadableForEngineHandoff() throws {
        let url = try AudioURL(https: signedURL)
        XCTAssertEqual(url.value, signedURL)
        XCTAssertEqual(url.scheme, .https)
    }

    // MARK: - PlaybackItem 校验

    func testItemRejectsUnsafeIdentifiers() {
        for bad in ["", ".", "..", "a/b", "a\\b", "a%2Fb", "id with space", "id\n", String(repeating: "x", count: 121)] {
            XCTAssertThrowsError(
                try PlaybackItem(id: bad, title: "t", artist: "a", audioSource: .publicDirect(TestItems.audioURL())),
                "应拒绝 id：'\(bad)'"
            ) { error in
                XCTAssertTrue(error is PlaybackItem.IdentifierRejection, "\(error)")
            }
        }
    }

    func testItemAcceptsCanonicalIdentifiers() throws {
        for good in ["library-334cbf73cab881cd48fba970", "media_reference-1_2", "ABC-123"] {
            XCTAssertNoThrow(try PlaybackItem(id: good, title: "t", artist: "a", audioSource: .publicDirect(TestItems.audioURL())))
        }
    }

    func testNonFiniteAndNonPositiveDurationsNormalizeToUnknown() throws {
        for bad in [0, -1, Double.nan, Double.infinity] {
            let item = try PlaybackItem(
                id: "t1", title: "t", artist: "a", duration: bad,
                audioSource: .publicDirect(TestItems.audioURL())
            )
            XCTAssertNil(item.duration, "\(bad) 应归一为未知时长")
        }
        let item = try PlaybackItem(
            id: "t1", title: "t", artist: "a", duration: 100.5,
            audioSource: .publicDirect(TestItems.audioURL())
        )
        XCTAssertEqual(item.duration, 100.5)
    }

    func testBearerSourceHasNoPlayableURLOutput() {
        let item = TestItems.make("t1", source: .bearerRequired(TestItems.audioURL()))
        XCTAssertNil(item.playableURL)
        XCTAssertTrue(item.requiresLocalization)
        XCTAssertFalse(item.isReadyToStream)
    }

    func testPublicAndLocalizedSourcesArePlayable() {
        let direct = TestItems.make("t1", source: .publicDirect(TestItems.audioURL()))
        XCTAssertTrue(direct.isReadyToStream)
        XCTAssertFalse(direct.requiresLocalization)
        let localized = TestItems.make("t2", source: .localized(TestItems.fileURL("/tmp/a.covaud")))
        XCTAssertTrue(localized.isReadyToStream)
        XCTAssertNotNil(localized.playableURL)
    }

    func testLocalizationProducesNewValueAndKeepsIdentity() {
        let bearer = TestItems.make("t1", album: "专辑", duration: 42, source: .bearerRequired(TestItems.audioURL()))
        let localized = bearer.localized(to: TestItems.fileURL("/tmp/a.covaud"))
        XCTAssertEqual(localized.id, bearer.id)
        XCTAssertEqual(localized.duration, 42)
        XCTAssertEqual(localized.album, "专辑")
        XCTAssertEqual(localized.kind, bearer.kind)
        XCTAssertTrue(localized.isReadyToStream)
        // 原值不变（不可变性）：避免「就地改写」把 Bearer 地址留在别处。
        XCTAssertTrue(bearer.requiresLocalization)
    }

    func testDescriptionOfItemDoesNotLeakAddress() {
        let item = TestItems.make("t1", source: .bearerRequired(try! AudioURL(https: signedURL)))
        let described = String(reflecting: item)
        XCTAssertFalse(described.contains("deadbeefSECRET"), described)
        var dumped = ""
        dump(item, to: &dumped)
        XCTAssertFalse(dumped.contains("deadbeefSECRET"), dumped)
    }

    /// 新增档位必须在这里表态 —— `allCases.count` 是刻意钉死的数量判据（本批加 `.work` 时
    /// 它就直接红，逼着改的人看清「上报 / 不上报」这张表多了一行）。
    /// 三种 kind 的**实际行为**钉在 `WorkPlaybackReportTests`（各条都真跑到协调器与桩提交器）。
    func testKindDrivesReportingDecision() {
        XCTAssertEqual(PlaybackItem.Kind.allCases.count, 3)
        XCTAssertEqual(
            PlaybackItem.Kind.allCases, [.libraryTrack, .privateCandidate, .work]
        )
        XCTAssertEqual(PlaybackItem.Kind.libraryTrack.rawValue, "libraryTrack")
        XCTAssertEqual(PlaybackItem.Kind.work.rawValue, "work")
        XCTAssertNotEqual(PlaybackItem.Kind.privateCandidate, PlaybackItem.Kind.libraryTrack)
        // 这张表只有一格是「不上报」：生成候选私有音频（design 02 §8）。
        // 作品行**要**上报，否则 `work_listens` 永远空、最近播放里永远不会有作品行。
        let suppressed: Set<PlaybackItem.Kind> = [.privateCandidate]
        XCTAssertEqual(
            Set(PlaybackItem.Kind.allCases).subtracting(suppressed),
            [.libraryTrack, .work]
        )
    }
}

/// 循环三态转移表。
final class LoopModeTests: XCTestCase {
    func testAdvancedFollowsOffAllOneCycle() {
        XCTAssertEqual(LoopMode.off.advanced(), .all)
        XCTAssertEqual(LoopMode.all.advanced(), .one)
        XCTAssertEqual(LoopMode.one.advanced(), .off)
    }

    func testFullCycleReturnsToStart() {
        var mode = LoopMode.off
        for _ in 0..<3 { mode = mode.advanced() }
        XCTAssertEqual(mode, .off)
        XCTAssertEqual(LoopMode.allCases.count, 3)
    }

    func testPredicateFlagsMatchSemantics() {
        XCTAssertTrue(LoopMode.all.wrapsToFirst)
        XCTAssertFalse(LoopMode.off.wrapsToFirst)
        XCTAssertFalse(LoopMode.one.wrapsToFirst)
        XCTAssertTrue(LoopMode.one.repeatsCurrentItem)
        XCTAssertFalse(LoopMode.all.repeatsCurrentItem)
        XCTAssertFalse(LoopMode.off.repeatsCurrentItem)
    }
}
