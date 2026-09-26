import CovaCore
@testable import CovaPlayer
import Foundation
import XCTest

/// 作品直存（BUG-15 / DEVELOPMENT.md A6）。
///
/// 本文件钉的四件事，每件都对应一个「接错就是事故」的分野：
/// ① 出口：只有生产出口能拿到 Bearer，名单桶**一律不带凭证**（D23「名单不是放凭证的理由」）；
/// ② 名单外主机一次出站都不许发生（不是"发出去再拒"）；
/// ③ 清单以**盘上事实**为准，不以清单自己为准（系统清理/用户手删之后不许继续说「已在本机」）；
/// ④ 0 字节 / 截断 / 非 2xx 一律不产生条目。
///
/// 写法纪律：actor 的取值一律先 `let … = await …` 再断言 —— `XCTAssert*` 是 autoclosure，
/// 里面放 `await` 直接编译不过（本文件第一版就全红在这上面）。
final class WorkDownloadStoreTests: XCTestCase {
    private var base: URL!
    private let owner = PrincipalID(rawValue: "principal-1")
    private var session: PlaybackSessionContext { PlaybackSessionContext(owner: owner) }

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        base = nil
        super.tearDown()
    }

    // MARK: - 夹具

    private func store(
        transport: StubPrivateAudioTransport = StubPrivateAudioTransport(),
        principal: String? = "principal-1"
    ) -> WorkDownloadStore {
        WorkDownloadStore(
            transport: transport,
            credentials: StubCredentialProvider(principal: principal),
            baseDirectory: base
        )
    }

    private func audioURL(_ raw: String) throws -> AudioURL {
        try AudioURL(https: URL(string: raw)!)
    }

    private func request(
        workId: String = "job-test-0001:cand-1",
        source: AudioURL,
        expectedBytes: Int? = nil
    ) throws -> WorkDownloadRequest {
        try WorkDownloadRequest(
            workId: workId, title: "夏日信号", artist: nil, duration: 118.4,
            source: source, session: session, expectedBytes: expectedBytes
        )
    }

    private func manifestData() throws -> Data {
        let directory = try WorkDownloadPath.ownerDirectory(base: base, owner: owner)
        return try Data(contentsOf: directory.appendingPathComponent(WorkDownloadPath.manifestName))
    }

    private func entryCount(_ sut: WorkDownloadStore) async -> Int {
        await sut.entries(owner: owner).count
    }

    // MARK: - ① 落盘与清单

    func testSaveWritesNonEmptyFileAndRecordsAnEntry() async throws {
        let transport = StubPrivateAudioTransport()
        await transport.configure(.init(bytesToWrite: 4096))
        let sut = store(transport: transport)
        let source = try audioURL("https://covalink.cn/audio/summer_9f3a.mp3")

        let result = await sut.save(try request(source: source))
        let entry = try result.get()
        XCTAssertEqual(entry.workId, "job-test-0001:cand-1")
        XCTAssertEqual(entry.jobId, "job-test-0001")
        XCTAssertEqual(entry.candidateId, "cand-1")
        XCTAssertEqual(entry.fileName, "job-test-0001-cand-1.mp3")
        XCTAssertEqual(entry.byteCount, 4096)
        XCTAssertEqual(entry.duration, 118.4)

        let fileURL = try WorkDownloadPath.fileURL(base: base, owner: owner, workId: entry.workId)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.size] as? Int, 4096, "A6：沙盒里必须是非 0 字节的完整文件")
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600, "作品字节只有 owner 可读")
        let saved = await sut.isSaved(workId: entry.workId, owner: owner)
        XCTAssertTrue(saved)
        let count = await entryCount(sut)
        XCTAssertEqual(count, 1)
        let local = await sut.localFileURL(workId: entry.workId, owner: owner)
        XCTAssertNotNil(local)
        XCTAssertEqual(local?.value.lastPathComponent, "job-test-0001-cand-1.mp3")
    }

    /// 清单里**不许有地址**：签名串住在 query，一旦进持久化索引就违反硬边界 3。
    func testManifestCarriesNoURLAndNoSignature() async throws {
        let transport = StubPrivateAudioTransport()
        let sut = store(transport: transport)
        let signed = try audioURL(
            "https://covalink.cn/api/proxy/audio?url=https%3A%2F%2Fup.invalid%2Fx.mp3&exp=1&sig=SECRET"
        )
        _ = await sut.save(try request(source: signed))
        let text = String(decoding: try manifestData(), as: UTF8.self)
        XCTAssertFalse(text.contains("http"), "清单里出现了地址")
        XCTAssertFalse(text.contains("sig"), "清单里出现了签名参数")
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertTrue(text.contains("job-test-0001-cand-1.mp3"), "本地文件名是允许的那一份")
    }

    /// 已有一份校验通过的文件 ⇒ 不再打第二次出口（12d §8「重复下载不重复创建」的作品版）。
    func testSecondSaveReusesTheExistingFileWithoutAnotherEgress() async throws {
        let transport = StubPrivateAudioTransport()
        let sut = store(transport: transport)
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        let first = try await sut.save(try request(source: source)).get()
        let second = try await sut.save(try request(source: source)).get()
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1, "第二次不该出站")
        XCTAssertEqual(first, second)
        let count = await entryCount(sut)
        XCTAssertEqual(count, 1)
    }

    /// 双击只许打一次出口（M7 同源教训：并发同键必须合流）。
    func testConcurrentSavesOfTheSameWorkCoalesceIntoOneEgress() async throws {
        let transport = SlowPrivateAudioTransport(delay: .milliseconds(60))
        let sut = WorkDownloadStore(
            transport: transport, credentials: StubCredentialProvider(), baseDirectory: base
        )
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        let saveRequest = try request(source: source)
        async let first = sut.save(saveRequest)
        async let second = sut.save(saveRequest)
        let a = try await first.get()
        let b = try await second.get()
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1, "两次点击 = 两次出站（写放大）")
        XCTAssertEqual(a.workId, b.workId)
        let count = await entryCount(sut)
        XCTAssertEqual(count, 1)
    }

    // MARK: - ② 出口裁决

    func testCredentialsAreSentOnlyToTheProductionOrigin() async throws {
        let transport = StubPrivateAudioTransport()
        let sut = store(transport: transport)

        let production = try audioURL("https://covalink.cn/api/media/objects/obj-1?ref=r&intent=play")
        _ = await sut.save(try request(workId: "job-a:cand-1", source: production))
        let firstCall = await transport.lastCall
        let first = try XCTUnwrap(firstCall)
        XCTAssertTrue(first.hasAuthorization, "生产出口这一腿要带 Bearer")

        // `playbackUrl` 的形态：预签名 COS 绝对直链（免凭证，TTL 900s）。
        let bucket = try audioURL(
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/work/c2.mp3?sign=x"
        )
        _ = await sut.save(try request(workId: "job-b:cand-1", source: bucket))
        let secondCall = await transport.lastCall
        let second = try XCTUnwrap(secondCall)
        XCTAssertFalse(
            second.hasAuthorization,
            "名单桶绝不是凭证出口（D23：把 Bearer 送到名单主机就是失守）"
        )
    }

    /// 生产实测（2026-09-26 只读探针，`GET /api/studio/create/works?limit=6`，6/6 行同形）：
    /// 作品的 `playbackUrl` 落在 **`covalink-uploads-…`（用户私产桶）**，而 D23 的名单里只有
    /// covers 与 audio 两个桶 ⇒ 这一腿今天就是走不通，必须**点名主机拒掉**，
    /// 而不是"试一下然后当网络问题"。（所以 `workPlaybackItem` 只吃 `audioUrl`；
    /// 直存也只在 `audioUrl` 缺的时候才退到 `playbackUrl`，届时名单一放宽就自动可用。）
    func testRealProductionPlaybackUrlHostIsRefusedByName() async throws {
        let transport = StubPrivateAudioTransport()
        let sut = store(transport: transport)
        let uploads = try audioURL(
            "https://covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com/jobs/job-1/c-1.mp3?sign=x"
        )
        let result = await sut.save(try request(workId: "job-u:cand-1", source: uploads))
        guard case .failure(.hostRejected(let host)) = result else {
            return XCTFail("uploads 桶不在名单内，必须被拒；实际 \(result)")
        }
        XCTAssertEqual(host, "covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com")
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0, "拒绝必须发生在出站之前")
    }

    func testHostsOutsideTheAllowlistNeverReachTheNetwork() async throws {
        let transport = StubPrivateAudioTransport()
        let sut = store(transport: transport)
        for host in ["https://evil.test/a.mp3", "https://covalink.cn.evil.test/a.mp3",
                     "https://covalink-audio-1301797874.cos.ap-beijing.myqcloud.com/a.mp3"] {
            let result = await sut.save(try request(source: try audioURL(host)))
            guard case .failure(let error) = result else {
                return XCTFail("\(host) 竟然被放行")
            }
            guard case .hostRejected(let label) = error else {
                return XCTFail("\(host) 的失败不是点名主机的拒绝：\(error)")
            }
            XCTAssertFalse(label.isEmpty)
            XCTAssertFalse(label.contains("/"), "拒绝信息里不许带路径/查询（签名就住在那里）")
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0, "被拒的主机一次出站都不该发生")
        let count = await entryCount(sut)
        XCTAssertEqual(count, 0)
    }

    /// 没有身份就没有可分桶的归属 ⇒ 宁可不存（D8：清单必须按 owner 隔离）。
    func testSaveWithoutAnOwnerIsRefused() async throws {
        let transport = StubPrivateAudioTransport()
        let sut = WorkDownloadStore(
            transport: transport,
            credentials: StubCredentialProvider(principal: nil),
            baseDirectory: base
        )
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        let anonymous = try WorkDownloadRequest(
            workId: "job-a:cand-1", title: "夏日信号", source: source,
            session: .unauthenticated
        )
        let result = await sut.save(anonymous)
        guard case .failure(.credentialUnavailable) = result else {
            return XCTFail("未认证必须拒绝，而不是存到一个无主的目录里：\(result)")
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0)
    }

    // MARK: - ③ 清单以盘上事实为准

    func testEntriesFollowTheDiskNotTheManifest() async throws {
        let transport = StubPrivateAudioTransport()
        let sut = store(transport: transport)
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        let entry = try await sut.save(try request(source: source)).get()
        let before = await entryCount(sut)
        XCTAssertEqual(before, 1)

        // 用户用「文件」App 删掉、或系统清理 ⇒ 清单还在，但事实已经不在。
        let fileURL = try WorkDownloadPath.fileURL(base: base, owner: owner, workId: entry.workId)
        try FileManager.default.removeItem(at: fileURL)
        let after = await entryCount(sut)
        XCTAssertEqual(after, 0, "盘上没有就不许说「已在本机」")
        let saved = await sut.isSaved(workId: entry.workId, owner: owner)
        XCTAssertFalse(saved)
        let local = await sut.localFileURL(workId: entry.workId, owner: owner)
        XCTAssertNil(local)
    }

    func testRemoveDeletesFileAndEntry() async throws {
        let transport = StubPrivateAudioTransport()
        let sut = store(transport: transport)
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        let entry = try await sut.save(try request(source: source)).get()
        let fileURL = try WorkDownloadPath.fileURL(base: base, owner: owner, workId: entry.workId)

        let removed = await sut.remove(workId: entry.workId, owner: owner)
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let count = await entryCount(sut)
        XCTAssertEqual(count, 0)
        // 本来就没什么可删的 ⇒ false（「删掉了东西」与「盘上确实没有」是两句话）。
        let again = await sut.remove(workId: entry.workId, owner: owner)
        XCTAssertFalse(again)
        let never = await sut.remove(workId: "job-never:cand-9", owner: owner)
        XCTAssertFalse(never)
    }

    func testPurgeClearsOnlyThatOwner() async throws {
        let transport = StubPrivateAudioTransport()
        let other = PrincipalID(rawValue: "principal-2")
        let sut = WorkDownloadStore(
            transport: transport, credentials: StubCredentialProvider(), baseDirectory: base
        )
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        _ = await sut.save(try request(workId: "job-a:cand-1", source: source))
        _ = await sut.save(try request(workId: "job-a:cand-2", source: source))
        let otherRequest = try WorkDownloadRequest(
            workId: "job-b:cand-1", title: "别的账号的作品", source: source,
            session: PlaybackSessionContext(owner: other)
        )
        _ = await sut.save(otherRequest)
        let mine = await entryCount(sut)
        XCTAssertEqual(mine, 2)
        let theirs = await sut.entries(owner: other).count
        XCTAssertEqual(theirs, 1)

        let purged = await sut.purge(owner: owner)
        XCTAssertEqual(purged, 2, "只报**已确认删除**的条数")
        let afterMine = await entryCount(sut)
        XCTAssertEqual(afterMine, 0)
        let afterTheirs = await sut.entries(owner: other).count
        XCTAssertEqual(afterTheirs, 1, "别的身份名下的文件不许被扫掉")
        let secondPurge = await sut.purge(owner: owner)
        XCTAssertEqual(secondPurge, 0)
    }

    // MARK: - ④ 失败面不产生条目

    func testEmptyDownloadIsRejected() async throws {
        let transport = StubPrivateAudioTransport()
        await transport.configure(.init(bytesToWrite: 0))
        let sut = store(transport: transport)
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        let result = await sut.save(try request(source: source))
        guard case .failure(.emptyDownload) = result else {
            return XCTFail("0 字节必须被拒（D7「校验非空」在这一条腿上同样成立）：\(result)")
        }
        let count = await entryCount(sut)
        XCTAssertEqual(count, 0)
    }

    func testTruncatedDownloadIsRejectedWithBothNumbers() async throws {
        let transport = StubPrivateAudioTransport()
        // 桩在 declaresExpectedBytes=false 时把**调用方给的**期望长度原样回执 ⇒ 造得出截断。
        await transport.configure(.init(bytesToWrite: 16, declaresExpectedBytes: false))
        let sut = store(transport: transport)
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        let result = await sut.save(try request(source: source, expectedBytes: 4096))
        guard case .failure(.truncated(let expected, let actual)) = result else {
            return XCTFail("声明长度与实得不符必须被判截断：\(result)")
        }
        XCTAssertEqual(expected, 4096)
        XCTAssertEqual(actual, 16)
        let count = await entryCount(sut)
        XCTAssertEqual(count, 0)
    }

    func testTransportFailureLeavesNoEntryAndNoTempShard() async throws {
        let transport = StubPrivateAudioTransport()
        await transport.configure(.init(throwsError: .badStatus(503)))
        let sut = store(transport: transport)
        let source = try audioURL("https://covalink.cn/audio/summer.mp3")
        let result = await sut.save(try request(source: source))
        guard case .failure(.badStatus(503)) = result else {
            return XCTFail("传输层的分类错误要原样交出：\(result)")
        }
        let count = await entryCount(sut)
        XCTAssertEqual(count, 0)
        let inflight = WorkDownloadPath.temporaryDirectory(base: base)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: inflight, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "失败的那一路不许留下分片")
    }

    // MARK: - 命名与身份（纯函数）

    func testFileNameReplacesThePseudoTrackIdSeparator() {
        XCTAssertEqual(WorkDownloadPath.fileName(forWorkId: "job-1:cand-2"), "job-1-cand-2.mp3")
        XCTAssertEqual(WorkDownloadPath.jobId(ofWorkId: "job-1:cand-2"), "job-1")
        XCTAssertEqual(WorkDownloadPath.candidateId(ofWorkId: "job-1:cand-2"), "cand-2")
        XCTAssertNil(WorkDownloadPath.candidateId(ofWorkId: "job-1"), "裸 jobId 没有候选段")
        XCTAssertEqual(WorkDownloadPath.jobId(ofWorkId: "job-1"), "job-1")
        // `:` 在 POSIX 上合法，但在「文件」App 与分享面板里显示成 `/` ⇒ 换成 `-`。
        XCTAssertFalse(WorkDownloadPath.fileName(forWorkId: "job-1:cand-2").contains(":"))
    }

    func testFileURLRejectsUnsafeWorkIds() throws {
        for bad in ["", ".", "..", "job/../../etc", "job-1#cand", "job-1@g1", "a b"] {
            XCTAssertThrowsError(
                try WorkDownloadPath.fileURL(base: base, owner: owner, workId: bad),
                "应拒绝 workId：'\(bad)'"
            )
        }
    }

    /// `#` 与 `@` 必须继续被拒：它们是 `PrivateAudioPath.fileName` 的分隔符，
    /// 放开就等于让一个 id 能伪造出「别的形态/别的代次」的缓存身份。
    func testCacheSeparatorsStayOutOfEveryIdentifier() {
        for bad in ["job-1#cand", "job-1@g3", "x#full@g9"] {
            XCTAssertThrowsError(try PlaybackItem.validateIdentifier(bad), "\(bad) 不该被接受")
        }
        XCTAssertNoThrow(try PlaybackItem.validateIdentifier("job-1:cand-2"))
    }
}

/// 带一段可观察延迟的落盘传输桩：用于让「并发同键」真的重叠（确定性来自 actor 信箱顺序，
/// 延迟只是把窗口撑宽，不参与判据）。
private actor SlowPrivateAudioTransport: PrivateAudioTransport {
    private let delay: Duration
    private(set) var callCount = 0

    init(delay: Duration) { self.delay = delay }

    func writeAudio(
        from url: URL, authorization: SecretString?, to fileURL: URL, expectedBytes: Int?
    ) async throws -> PrivateAudioReceipt {
        callCount += 1
        try await Task.sleep(for: delay)
        let payload = Data(repeating: 0x2a, count: 32)
        FileManager.default.createFile(atPath: fileURL.path, contents: payload)
        return PrivateAudioReceipt(
            bytesWritten: payload.count, expectedBytes: payload.count, statusCode: 200
        )
    }

    func cancelInFlightTransfers() async {}
}
