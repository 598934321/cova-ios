import XCTest
import CovaCore
import Foundation
@testable import CovaPlayer

/// 私有音频本地化（D7 硬规则）：出口守卫、落盘式写入、完成性校验、owner 隔离与清理。
///
/// 零网络：传输一律走 `StubPrivateAudioTransport`（桩只写沙盒文件），
/// 出站地址虽落在生产 origin 形状上，但不会发生任何真实请求。
final class PrivateAudioFetcherTests: XCTestCase {
    // MARK: - 夹具

    /// 生产 origin 上的私有音频地址（带签名查询：用来验证 query 不外泄）。
    static func privateSource(_ path: String = "/api/media/private/one.m4a?sig=deadbeef") throws -> AudioURL {
        try AudioURL(https: URL(string: "https://covalink.cn\(path)")!)
    }

    static func authenticatedContext(
        principal: String = "principal-1",
        generation: SessionGeneration = .initial
    ) -> PlaybackSessionContext {
        PlaybackSessionContext(owner: PrincipalID(rawValue: principal), generation: generation)
    }

    private func makeFetcher(
        in directory: TemporaryDirectory,
        transport: StubPrivateAudioTransport,
        credentials: StubCredentialProvider = StubCredentialProvider()
    ) -> PrivateAudioFetcher {
        try! PrivateAudioFetcher(
            transport: transport,
            credentials: credentials,
            baseDirectory: directory.url
        )
    }

    private func request(
        itemID: String = "one",
        source: AudioURL? = nil,
        session: PlaybackSessionContext? = nil,
        expectedBytes: Int? = nil
    ) -> PrivateAudioRequest {
        PrivateAudioRequest(
            itemID: itemID,
            source: source ?? (try! Self.privateSource()),
            session: session ?? Self.authenticatedContext(),
            expectedBytes: expectedBytes
        )
    }

    // MARK: - 路径与命名（纯函数）

    func testOwnerNamespaceIsHexEncodedAndCollisionFree() {
        let first = PrivateAudioPath.namespace(for: PrincipalID(rawValue: "principal-1"))
        let second = PrivateAudioPath.namespace(for: PrincipalID(rawValue: "principal-2"))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
        XCTAssertFalse(first.contains("-"))
    }

    func testDirectoryLayoutKeepsTemporaryInsideRoot() throws {
        let base = URL(fileURLWithPath: "/tmp/cova-base", isDirectory: true)
        let root = PrivateAudioPath.rootDirectory(base: base)
        let owner = PrivateAudioPath.ownerDirectory(base: base, owner: PrincipalID(rawValue: "principal-1"))
        let temporary = PrivateAudioPath.temporaryDirectory(base: base)
        XCTAssertTrue(PrivateAudioPath.isInside(directory: root, url: owner))
        XCTAssertTrue(PrivateAudioPath.isInside(directory: root, url: temporary))
        XCTAssertFalse(PrivateAudioPath.isInside(directory: owner, url: temporary))
    }

    func testIsInsideRejectsEqualPathAndSiblingPrefixCollision() {
        let root = URL(fileURLWithPath: "/tmp/cova/root", isDirectory: true)
        XCTAssertFalse(PrivateAudioPath.isInside(directory: root, url: root))
        // `/tmp/cova/root-evil` 有字符串前缀但不是子项
        XCTAssertFalse(PrivateAudioPath.isInside(directory: root, url: URL(fileURLWithPath: "/tmp/cova/root-evil/x")))
        XCTAssertTrue(PrivateAudioPath.isInside(directory: root, url: URL(fileURLWithPath: "/tmp/cova/root/x")))
    }

    func testFileNameCarriesOnlyItemIDAndGeneration() {
        let name = PrivateAudioPath.fileName(itemID: "track42", generation: SessionGeneration(value: 7))
        XCTAssertEqual(name, "track42@g7.covaud")
        XCTAssertFalse(name.contains("covalink"))
        XCTAssertFalse(name.contains("sig"))
        XCTAssertEqual(PrivateAudioPath.generation(infileName: name), SessionGeneration(value: 7))
    }

    func testGenerationParsingFailsClosedOnForeignNames() {
        XCTAssertNil(PrivateAudioPath.generation(infileName: "random.bin"))
        XCTAssertNil(PrivateAudioPath.generation(infileName: "one@g.covaud"))
        XCTAssertNil(PrivateAudioPath.generation(infileName: "one@gX.covaud"))
    }

    func testFileURLRejectsUnsafeIdentifiersAndOwners() {
        let base = URL(fileURLWithPath: "/tmp/cova-base", isDirectory: true)
        let owner = PrincipalID(rawValue: "principal-1")
        for unsafe in ["../escape", "a/b", "..", ".", "", "带中文", "a b"] {
            XCTAssertThrowsError(
                try PrivateAudioPath.fileURL(base: base, owner: owner, itemID: unsafe, generation: .initial),
                unsafe
            )
        }
        XCTAssertThrowsError(
            try PrivateAudioPath.fileURL(base: base, owner: PrincipalID(rawValue: ""), itemID: "one", generation: .initial)
        )
    }

    func testFileURLStaysInsideOwnerDirectory() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cova-path-" + UUID().uuidString, isDirectory: true)
        let url = try PrivateAudioPath.fileURL(
            base: base,
            owner: PrincipalID(rawValue: "principal-1"),
            itemID: "one",
            generation: SessionGeneration(value: 3)
        )
        let root = PrivateAudioPath.rootDirectory(base: base)
        XCTAssertTrue(PrivateAudioPath.isInside(directory: root, url: url))
        XCTAssertTrue(url.lastPathComponent.contains("@g3"))
    }

    func testRequestNormalizesNegativeExpectedBytesAndDefaultBaseDirectoryIsSandboxed() async {
        XCTAssertEqual(request(expectedBytes: -7).expectedBytes, 0)
        XCTAssertEqual(request(expectedBytes: 12).expectedBytes, 12)
        XCTAssertNil(request(expectedBytes: nil).expectedBytes)
        let root = PrivateAudioFetcher.defaultBaseDirectory()
        XCTAssertTrue(root.path.contains("Cova"))
        let fetcher = try! PrivateAudioFetcher(
            transport: StubPrivateAudioTransport(),
            credentials: StubCredentialProvider(),
            baseDirectory: root
        )
        let cachedRoot = await fetcher.cachedRootDirectory.path
        XCTAssertTrue(cachedRoot.hasPrefix(root.path))
    }

    func testReceiptCompletenessRules() {
        XCTAssertFalse(PrivateAudioReceipt(bytesWritten: 0, expectedBytes: nil, statusCode: 200).isComplete)
        XCTAssertTrue(PrivateAudioReceipt(bytesWritten: 10, expectedBytes: nil, statusCode: 200).isComplete)
        XCTAssertTrue(PrivateAudioReceipt(bytesWritten: 10, expectedBytes: 10, statusCode: 200).isComplete)
        XCTAssertFalse(PrivateAudioReceipt(bytesWritten: 9, expectedBytes: 10, statusCode: 200).isComplete)
    }

    // MARK: - 本地化主路径

    func testBearerAudioIsWrittenToDiskAndReturnedAsFileURL() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        let result = await fetcher.localizedURL(for: request())

        guard case .success(let localized) = result else {
            return XCTFail("应成功本地化，实得 \(result)")
        }
        XCTAssertEqual(localized.scheme, .file)
        XCTAssertTrue(localized.isLocalized)
        XCTAssertFalse(localized.description.contains("sig"))
        XCTAssertFalse(localized.description.contains("covalink"))
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
        let lastCall = await transport.lastCall
        XCTAssertTrue(lastCall?.hasAuthorization == true, "Bearer 必须由凭证提供器注入到落盘传输")
        XCTAssertEqual(lastCall?.url.host, "covalink.cn")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localized.value.path))
        let size = ((try? FileManager.default.attributesOfItem(atPath: localized.value.path))?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0)
        // 临时分片必须被 move 走，不留半写文件。
        let inflight = PrivateAudioPath.temporaryDirectory(base: directory.url)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: inflight.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "残留在途分片：\(leftovers)")
    }

    func testEmptyFileIsRejectedAndNothingIsCommitted() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        await transport.configure(.init(bytesToWrite: 0, declaresExpectedBytes: false, throwsError: nil, writesToDisk: true))
        let fetcher = makeFetcher(in: directory, transport: transport)
        let result = await fetcher.localizedURL(for: request())
        guard case .failure(let error) = result else { return XCTFail("0 字节必须被拒绝：\(result)") }
        XCTAssertEqual(error, .emptyDownload)
        let count = await fetcher.cachedFileCount()
        XCTAssertEqual(count, 0, "空文件不得成为可用缓存")
    }

    func testTruncatedDownloadIsRejectedAndTemporaryRemoved() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        await transport.configure(.init(bytesToWrite: 8, declaresExpectedBytes: false, throwsError: nil, writesToDisk: true))
        let fetcher = makeFetcher(in: directory, transport: transport)
        // 调用方声明 16 字节，实得 8 → 截断。
        let result = await fetcher.localizedURL(for: request(expectedBytes: 16))
        guard case .failure(let error) = result else { return XCTFail("截断必须被拒绝：\(result)") }
        XCTAssertEqual(error, .truncated(expected: 16, actual: 8))
        let inflight = PrivateAudioPath.temporaryDirectory(base: directory.url)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: inflight.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testReceiptWithoutDeclaredLengthStillAcceptedWhenBytesPresent() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        await transport.configure(.init(bytesToWrite: 32, declaresExpectedBytes: false, throwsError: nil, writesToDisk: true))
        let fetcher = makeFetcher(in: directory, transport: transport)
        let result = await fetcher.localizedURL(for: request())
        if case .failure(let error) = result { XCTFail("未声明长度且有字节 → 应接受：\(error)") }
    }

    // MARK: - 出口守卫与会话守卫（先于任何写入）

    func testNonProductionHostIsRejectedWithoutTransportCall() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        let foreign = try! AudioURL(https: URL(string: "https://cdn.covalink.example/audio/one.m4a")!)
        let result = await fetcher.localizedURL(for: request(source: foreign))
        guard case .failure(let error) = result else { return XCTFail("非生产出口必须被拒绝：\(result)") }
        XCTAssertEqual(error, .hostRejected)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0, "出口守卫必须在发起传输之前")
    }

    func testUnauthenticatedAndStaleSessionNeverReachTransport() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let anonymous = makeFetcher(in: directory, transport: transport)
        let anonymousResult = await anonymous.localizedURL(for: request(session: .unauthenticated))
        guard case .failure(.credentialUnavailable) = anonymousResult else {
            return XCTFail("未认证不得取回私有音频：\(anonymousResult)")
        }

        let stale = makeFetcher(
            in: directory,
            transport: transport,
            credentials: StubCredentialProvider(principal: "principal-1", generation: SessionGeneration(value: 9))
        )
        let staleResult = await stale.localizedURL(
            for: request(session: Self.authenticatedContext(generation: .initial))
        )
        guard case .failure(.staleSession) = staleResult else {
            return XCTFail("generation 不一致必须作废：\(staleResult)")
        }

        let broken = makeFetcher(in: directory, transport: transport, credentials: StubCredentialProvider(throwsOnRead: true))
        let brokenResult = await broken.localizedURL(for: request())
        guard case .failure(.credentialUnavailable) = brokenResult else {
            return XCTFail("凭证读失败必须 fail-closed：\(brokenResult)")
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0)
    }

    func testCrossAccountPrincipalIsRejectedAsStale() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(
            in: directory,
            transport: transport,
            credentials: StubCredentialProvider(principal: "someone-else")
        )
        let result = await fetcher.localizedURL(for: request())
        guard case .failure(.staleSession) = result else { return XCTFail("跨账号必须作废：\(result)") }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0)
    }

    // MARK: - 缓存复用与失效

    func testSecondRequestReusesValidCachedFileWithoutRefetch() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        let first = await fetcher.localizedURL(for: request())
        guard case .success = first else { return XCTFail("首次应成功：\(first)") }
        let second = await fetcher.localizedURL(for: request())
        guard case .success(let again) = second else { return XCTFail("二次应成功：\(second)") }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1, "有效缓存必须复用（不得重复取回）")
        let count = await fetcher.cachedFileCount()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(again.isLocalized)
    }

    func testCachedFileOfWrongSizeIsDiscardedAndRefetched() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        _ = await fetcher.localizedURL(for: request())
        // 声明与缓存实际字节数不符 → 丢弃缓存并重取（拒绝「半截文件」被当作可用）。
        let result = await fetcher.localizedURL(for: request(expectedBytes: 999))
        if case .failure(let error) = result { XCTFail("应重取成功：\(error)") }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2)
    }

    func testEmptyCachedFileIsPurgedAndRefetched() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        let target = try! PrivateAudioPath.fileURL(
            base: directory.url,
            owner: PrincipalID(rawValue: "principal-1"),
            itemID: "one",
            generation: .initial
        )
        try! FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let result = await fetcher.localizedURL(for: request())
        if case .failure(let error) = result { XCTFail("空缓存必须被清理后重取：\(error)") }
        XCTAssertGreaterThan(((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.intValue ?? 0, 0)
    }

    // MARK: - 失败映射

    func testTransportAndWriteFailuresAreMappedWithoutEchoingPaths() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        await transport.configure(.init(bytesToWrite: 16, declaresExpectedBytes: true, throwsError: .cancelled, writesToDisk: true))
        let cancelled = await fetcher.localizedURL(for: request())
        guard case .failure(.cancelled) = cancelled else { return XCTFail("取消需原样分类：\(cancelled)") }

        await transport.configure(.init(bytesToWrite: 16, declaresExpectedBytes: true, throwsError: .badStatus(503), writesToDisk: true))
        let badStatus = await fetcher.localizedURL(for: request())
        guard case .failure(.badStatus(let code)) = badStatus else { return XCTFail("状态码需透传：\(badStatus)") }
        XCTAssertEqual(code, 503)

        // 声明写盘但实际不落盘 → 原子 move 失败（只带系统状态码，不带路径）。
        await transport.configure(.init(bytesToWrite: 16, declaresExpectedBytes: true, throwsError: nil, writesToDisk: false))
        let missing = await fetcher.localizedURL(for: request(itemID: "never-written"))
        guard case .failure(let error) = missing else { return XCTFail("未落盘必须失败：\(missing)") }
        XCTAssertTrue(
            error == .emptyDownload || error.description.contains("状态码"),
            "错误描述只允许携带状态码：\(error)"
        )
        XCTAssertFalse(String(describing: error).contains(directory.url.path))
    }

    func testStatusExtractionYieldsIntegerCodesOnly() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 516)
        XCTAssertEqual(PrivateAudioFetcher.status(of: error), 516)
        XCTAssertEqual(PrivateAudioFetcher.status(of: CancellationError()), Int32((CancellationError() as NSError).code))
    }

    // MARK: - owner 隔离与清理（D8）

    func testPurgeRemovesOnlyThatOwnersFiles() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let first = makeFetcher(in: directory, transport: transport)
        let second = makeFetcher(
            in: directory,
            transport: transport,
            credentials: StubCredentialProvider(principal: "principal-2")
        )
        _ = await first.localizedURL(for: request())
        _ = await first.localizedURL(for: request(itemID: "two"))
        _ = await second.localizedURL(for: request(itemID: "three", session: Self.authenticatedContext(principal: "principal-2")))
        let before = await first.cachedFileCount()
        XCTAssertEqual(before, 3)

        let removed = await first.purge(owner: PrincipalID(rawValue: "principal-1"))
        XCTAssertEqual(removed, 2, "只清该 owner 的目录")
        let after = await first.cachedFileCount()
        XCTAssertEqual(after, 1)
        let otherStill = FileManager.default.fileExists(
            atPath: PrivateAudioPath.ownerDirectory(base: directory.url, owner: PrincipalID(rawValue: "principal-2")).path
        )
        XCTAssertTrue(otherStill, "换号清理不得波及别的账号")
    }

    func testPurgeStaleKeepsCurrentGenerationAndUnknownNames() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        // 新代次必须用「凭证快照也推进到该代」的取回器（generation 不一致会在守卫处被拒，写不出文件）。
        let advanced = makeFetcher(
            in: directory,
            transport: transport,
            credentials: StubCredentialProvider(generation: SessionGeneration(value: 1))
        )
        let owner = PrincipalID(rawValue: "principal-1")
        // 两份 g0 + 一份 g1，再加一个非本方案命名的文件。
        _ = await fetcher.localizedURL(for: request(itemID: "zero", session: Self.authenticatedContext(generation: SessionGeneration(value: 0))))
        _ = await fetcher.localizedURL(for: request(itemID: "one", session: Self.authenticatedContext(generation: SessionGeneration(value: 0))))
        _ = await advanced.localizedURL(for: request(itemID: "one", session: Self.authenticatedContext(generation: SessionGeneration(value: 1))))
        let foreign = PrivateAudioPath.ownerDirectory(base: directory.url, owner: owner).appendingPathComponent("stray.bin")
        try? "x".data(using: .utf8)!.write(to: foreign)

        let current = PrivateAudioPath.fileName(itemID: "one", generation: SessionGeneration(value: 1))
        let currentFile = PrivateAudioPath.ownerDirectory(base: directory.url, owner: owner).appendingPathComponent(current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentFile.path), "前置条件：g1 文件必须已写出")

        let removed = await fetcher.purgeStale(before: SessionGeneration(value: 1))
        XCTAssertEqual(removed, 2, "旧代次与在途分片都属于可清理集合")
        let kept = FileManager.default.fileExists(atPath: foreign.path)
        XCTAssertTrue(kept, "无法解析代次的文件不得被误删")
        let currentKept = FileManager.default.fileExists(atPath: currentFile.path)
        XCTAssertTrue(currentKept, "当前代次必须保留")
    }

    func testPurgeAllClearsRootIncludingTemporaryShards() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        _ = await fetcher.localizedURL(for: request())
        let inflight = PrivateAudioPath.temporaryDirectory(base: directory.url)
        try? FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
        try? "part".data(using: .utf8)!.write(to: inflight.appendingPathComponent("leftover.part"))
        let removed = await fetcher.purgeAll()
        XCTAssertEqual(removed, 2)
        let count = await fetcher.cachedFileCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - 源准备器（协调器装载前的 D7 关口）

    func testPrepareSourcePassesThroughPlayableItemsAndLocalizesBearerOnes() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)

        let publicItem = TestItems.make("pub")
        let passed = await fetcher.prepareSource(for: publicItem, session: Self.authenticatedContext())
        guard case .success(let same) = passed else { return XCTFail("公开直链应原样放行：\(passed)") }
        XCTAssertEqual(same, publicItem)
        let callsAfterPublic = await transport.callCount
        XCTAssertEqual(callsAfterPublic, 0, "可播条目不得触发下载")

        let privateItem = TestItems.make(
            "priv",
            source: .bearerRequired(try! Self.privateSource("/api/media/private/priv.m4a?sig=aa"))
        )
        let localized = await fetcher.prepareSource(for: privateItem, session: Self.authenticatedContext())
        guard case .success(let ready) = localized else { return XCTFail("私有条目应被本地化：\(localized)") }
        XCTAssertEqual(ready.id, "priv")
        XCTAssertEqual(ready.title, privateItem.title)
        XCTAssertFalse(ready.requiresLocalization)
        guard case .localized(let url) = ready.audioSource else { return XCTFail("来源必须转为 localized") }
        XCTAssertEqual(url.scheme, .file)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }

    func testPrepareSourceFailsClosedWhenItemIsNotBearerButUnusable() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        // 需 Bearer 但未认证 → notLocalized 之前的守卫先拒（credentialUnavailable），绝不返回可播地址。
        let privateItem = TestItems.make("priv", source: .bearerRequired(try! Self.privateSource()))
        let result = await fetcher.prepareSource(for: privateItem, session: .unauthenticated)
        guard case .failure(let error) = result else { return XCTFail("未认证不得本地化：\(result)") }
        XCTAssertEqual(error, .credentialUnavailable)
    }

    func testFileURLOfLocalizedItemCarriesNoQueryEvenWhenSourceHadSignature() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        let result = await fetcher.localizedURL(for: request())
        guard case .success(let url) = result else { return XCTFail("\(result)") }
        XCTAssertNil(url.value.query)
        XCTAssertNil(url.value.fragment)
        // 签名串（query）不得出现在缓存文件名里。
        XCTAssertFalse(url.value.lastPathComponent.contains("sig"))
    }
}
