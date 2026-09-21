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

    // MARK: - 环 4 · M5：清理侧必须有 owner 校验闸

    /// M5：空 principal 的 hex 命名空间是 `""`，`appendingPathComponent("")` 会算到**缓存根**
    /// —— 旧行为是一次删光所有账号的私有音频。取回侧早有 fail-closed，清理侧漏了同一道闸。
    func testPurgeWithInvalidOwnerClearsNothingAndKeepsEveryOwnerDirectory() async {
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
        _ = await second.localizedURL(
            for: request(itemID: "three", session: Self.authenticatedContext(principal: "principal-2"))
        )
        let cacheRoot = PrivateAudioPath.rootDirectory(base: directory.url)
        let directoriesBefore = ownerDirectories(in: cacheRoot)
        XCTAssertEqual(directoriesBefore.count, 2, "前置条件：两个 owner 目录都在（不含 .inflight）")
        let totalBefore = await first.cachedFileCount()
        XCTAssertEqual(totalBefore, 3)

        for invalid in ["", "/etc/passwd", "a\\b", "带控制字符\u{7}", String(repeating: "a", count: 200)] {
            let removed = await first.purge(owner: PrincipalID(rawValue: invalid))
            XCTAssertEqual(removed, 0, "非法 owner 的清理必须返回 0（\(invalid.debugDescription)）")
        }
        let directoriesAfter = ownerDirectories(in: cacheRoot)
        XCTAssertEqual(directoriesAfter, directoriesBefore, "非法 owner 不得动到任何目录（更不得波及缓存根）")
        for principal in ["principal-1", "principal-2"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: PrivateAudioPath.ownerDirectory(base: directory.url, owner: PrincipalID(rawValue: principal)).path
                ),
                "\(principal) 的目录必须完好"
            )
        }
        let totalAfter = await first.cachedFileCount()
        XCTAssertEqual(totalAfter, 3, "一个字节都不能少")

        // 合法 owner 仍然只清自己那份（正向对照，TD-9）。
        let removed = await first.purge(owner: PrincipalID(rawValue: "principal-1"))
        XCTAssertEqual(removed, 2)
        let remaining = await first.cachedFileCount()
        XCTAssertEqual(remaining, 1)
    }

    // MARK: - 环 4 · M6：在途分片必须被兜底清理

    /// M6：`.inflight` 是隐藏目录且不在 owner 目录下 —— 进程被杀留下的半文件此前永久残留。
    func testInflightShardsSurvivingAKilledProcessAreDiscardedAtLaunch() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let shards = try seedInflightShards(in: directory, names: ["leftover.part", "another.part"])
        XCTAssertEqual(shards.count, 2, "前置条件：预置两条在途分片")

        _ = makeFetcher(in: directory, transport: StubPrivateAudioTransport())

        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: PrivateAudioPath.temporaryDirectory(base: directory.url).path)) ?? [])
        XCTAssertTrue(leftovers.isEmpty, "启动期必须清掉上一次进程留下的分片：\(leftovers)")
        for shard in shards {
            XCTAssertFalse(FileManager.default.fileExists(atPath: shard.path), "分片仍在磁盘上：\(shard.lastPathComponent)")
        }
    }

    /// M6：`discardInflightShards()` 的返回值是**被确认删除**的数量（不是「数到的数量」）。
    func testDiscardInflightShardsReturnsConfirmedDeletionCount() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let fetcher = makeFetcher(in: directory, transport: StubPrivateAudioTransport())
        let zeroOnEmpty = await fetcher.discardInflightShards()
        XCTAssertEqual(zeroOnEmpty, 0, "没有分片时报 0")

        _ = try seedInflightShards(in: directory, names: ["one.part", "two.part", "three.part"])
        let removed = await fetcher.discardInflightShards()
        XCTAssertEqual(removed, 3)
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: PrivateAudioPath.temporaryDirectory(base: directory.url).path))?.isEmpty ?? true,
            "分片目录必须被清空"
        )
        let again = await fetcher.discardInflightShards()
        XCTAssertEqual(again, 0, "第二次无物可删必须报 0")
    }

    /// M6 的边界（不是缺陷、只是口径）：`purge(owner:)`/`purgeStale` 到不了 `.inflight`，
    /// 覆盖它的是启动期清理、`discardInflightShards()` 与 `purgeAll()`。
    func testOwnerScopedPurgeDoesNotReachInflightDirectoryButPurgeAllDoes() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let fetcher = makeFetcher(in: directory, transport: StubPrivateAudioTransport())
        _ = await fetcher.localizedURL(for: request())
        let shard = try XCTUnwrap(seedInflightShards(in: directory, names: ["half.done.part"]).first)

        _ = await fetcher.purge(owner: PrincipalID(rawValue: "principal-1"))
        _ = await fetcher.purgeStale(before: SessionGeneration(value: 99))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shard.path), "owner 维度的清理不该顺手删掉别的在途（分工见注释）")

        let removed = await fetcher.purgeAll()
        XCTAssertEqual(removed, 1, "purgeAll 覆盖在途分片")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shard.path))
    }

    // MARK: - 环 4 · M8：清理面必须作废在途，且不能打死出口

    func testEveryPurgeSurfaceCancelsInFlightTransfersAndTheExitKeepsServing() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = GatedPrivateAudioTransport()
        await transport.release() // 本用例不关心在途会合，只关心「作废之后还能服务」
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        _ = await fetcher.localizedURL(for: request())
        let cancellationsAtStart = await transport.cancellationCount
        XCTAssertEqual(cancellationsAtStart, 0, "取回本身不该顺手作废出口")

        _ = await fetcher.purge(owner: PrincipalID(rawValue: "principal-1"))
        let afterOwnerPurge = await transport.cancellationCount
        XCTAssertEqual(afterOwnerPurge, 1, "D16②：清理之前必须作废在途")

        _ = await fetcher.purgeStale(before: SessionGeneration(value: 5))
        _ = await fetcher.purgeAll()
        let afterAll = await transport.cancellationCount
        XCTAssertEqual(afterAll, 3, "三个清理面都要作废")

        // 出口没被打死：作废之后仍能服务下一次请求。
        let result = await fetcher.localizedURL(for: request(itemID: "after-purge"))
        guard case .success = result else { return XCTFail("作废在途之后必须仍可取回：\(result)") }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2)
        let cached = await fetcher.cachedFileCount()
        XCTAssertEqual(cached, 1)
    }

    // MARK: - 环 4 · m12：落盘权限收紧

    func testCommittedCacheFileIsOwnerOnlyReadable() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        // 桩传输刻意不带权限（0644 落盘）→ 收紧必须发生在准备器的提交面与复用判据上。
        let fetcher = makeFetcherOn(in: directory, transport: StubPrivateAudioTransport())
        let result = await fetcher.localizedURL(for: request())
        guard case .success(let localized) = result else { return XCTFail("应成功本地化：\(result)") }
        let mode = try posixMode(of: localized.value.path)
        XCTAssertEqual(mode & 0o777, PrivateAudioPath.fileMode, "私有音频缓存只能是 owner 可读写（实得 \(String(format: "%04o", mode))）")
        XCTAssertEqual(mode & 0o077, 0, "组/其它位一个都不许留")
    }

    /// m12：收紧之前留下的「组/其它可读」旧缓存不得继续被复用（必须丢弃重取并收敛到 0600）。
    func testCachedFileWithLoosePermissionsIsDiscardedAndRefetched() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        _ = await fetcher.localizedURL(for: request())
        let target = try PrivateAudioPath.fileURL(
            base: directory.url,
            owner: PrincipalID(rawValue: "principal-1"),
            itemID: "one",
            generation: .initial
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        XCTAssertEqual(try posixMode(of: target.path) & 0o777, 0o644, "前置条件：造出一个世界可读的历史缓存")

        let callsBefore = await transport.callCount
        let result = await fetcher.localizedURL(for: request())
        guard case .success = result else { return XCTFail("重取应成功：\(result)") }
        let callsAfter = await transport.callCount
        XCTAssertEqual(callsAfter - callsBefore, 1, "权限不合格的缓存不得被复用")
        XCTAssertEqual(try posixMode(of: target.path) & 0o777, PrivateAudioPath.fileMode)
        XCTAssertTrue(PrivateAudioFetcher.hasPrivateAudioFileMode([.posixPermissions: NSNumber(value: Int16(0o600))]))
        XCTAssertFalse(PrivateAudioFetcher.hasPrivateAudioFileMode([.posixPermissions: NSNumber(value: Int16(0o640))]))
        XCTAssertFalse(PrivateAudioFetcher.hasPrivateAudioFileMode([:]))
    }

    // MARK: - 环 4 · m13：删除后复核，删不掉就不许报「已删」

    func testPurgeReturnsZeroWhenRemovalThrows() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let attempts = SignalCounter()
        let fetcher = makeFetcher(
            in: directory,
            transport: StubPrivateAudioTransport(),
            fileManager: ThrowingRemoveFileManager(attempts: attempts)
        )
        _ = await fetcher.localizedURL(for: request())
        let owner = PrivateAudioPath.ownerDirectory(base: directory.url, owner: PrincipalID(rawValue: "principal-1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owner.path), "前置条件：缓存文件已落盘")

        let removed = await fetcher.purge(owner: PrincipalID(rawValue: "principal-1"))
        XCTAssertEqual(removed, 0, "删除抛错时报 0（旧实现报的是「删除前数到的数量」）")
        XCTAssertGreaterThan(attempts.value, 0, "前置条件：确实尝试过删除")
        XCTAssertTrue(FileManager.default.fileExists(atPath: owner.path))
        let allRemoved = await fetcher.purgeAll()
        XCTAssertEqual(allRemoved, 0)
        let staleRemoved = await fetcher.purgeStale(before: SessionGeneration(value: 99))
        XCTAssertEqual(staleRemoved, 0)
    }

    /// m13 的第二支：底层删除「静默不生效」（路径仍在）也必须报 0 —— 这才是虚报的真实形态。
    func testPurgeReturnsZeroWhenPathSurvivesRemoval() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let attempts = SignalCounter()
        let fetcher = makeFetcher(
            in: directory,
            transport: StubPrivateAudioTransport(),
            fileManager: SilentNoOpRemoveFileManager(attempts: attempts)
        )
        _ = await fetcher.localizedURL(for: request())
        let removed = await fetcher.purge(owner: PrincipalID(rawValue: "principal-1"))
        XCTAssertEqual(removed, 0)
        XCTAssertGreaterThan(attempts.value, 0, "前置条件：确实尝试过删除")
        let cached = await fetcher.cachedFileCount()
        XCTAssertGreaterThan(cached, 0, "文件其实还在盘上（上层据此知道清理没发生）")
        let shards = try seedInflightShards(in: directory, names: ["stuck.part"])
        let stuck = try XCTUnwrap(shards.first)
        let discarded = await fetcher.discardInflightShards()
        XCTAssertEqual(discarded, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path))
    }

    // MARK: - 环 4 · M7：并发在途去重

    /// M7：同一 `(owner, itemID, generation)` 的并发取回只允许**一次**真实传输，
    /// 两个调用者拿到同一份内容。旧行为：`transportCalls=2` 且后提交方把先交付方的文件换掉。
    ///
    /// 会合方式：`GatedPrivateAudioTransport` 让每一路传输挂起，直到测试点名放行 ——
    /// 「两路确实在途重叠」由 `enteredSignal` / `maxConcurrentInFlight` 直接观测（D16⑤）。
    func testConcurrentSameKeyRequestsTriggerExactlyOneTransfer() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = GatedPrivateAudioTransport()
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        // 请求先落成局部常量：`async let` 里不许捕获非 Sendable 的测试实例（Swift 6 严格并发）。
        let sharedKey = request()
        let otherKey = request(itemID: "other")

        async let first: Result<AudioURL, PlayerError> = fetcher.localizedURL(for: sharedKey)
        let entered = await Signals.wait(target: 1, counter: transport.enteredSignal)
        XCTAssertTrue(entered, "前置条件：第一路必须已进入在途传输")

        async let second: Result<AudioURL, PlayerError> = fetcher.localizedURL(for: sharedKey)
        async let third: Result<AudioURL, PlayerError> = fetcher.localizedURL(for: otherKey)
        let overlapping = await Signals.wait(target: 2, counter: transport.enteredSignal)
        XCTAssertTrue(overlapping, "前置条件：不同 key 的第二路也必须真的在途（否则去重什么都没测到）")
        // 经一次 actor 回合：加入者（second）的第一段工作已跑完它的复核与合流判定。
        let liveTransfers = await fetcher.inflightTransferCount
        XCTAssertEqual(liveTransfers, 2, "去重表里只该有两个不同 key 的条目")

        await transport.release()
        let a = await first
        let b = await second
        let c = await third
        guard case .success(let urlA) = a else { return XCTFail("第一路应成功：\(a)") }
        guard case .success(let urlB) = b else { return XCTFail("加入者应成功：\(b)") }
        guard case .success(let urlC) = c else { return XCTFail("不同 key 应成功：\(c)") }

        let calls = await transport.callCount
        XCTAssertEqual(calls, 2, "同键并发只允许一次真实传输（实得 \(calls) 次）")
        let peak = await transport.maxConcurrentInFlight
        XCTAssertEqual(peak, 2, "两条传输确实重叠在途")
        let authorizations = await transport.sentAuthorizations
        XCTAssertEqual(authorizations.count, 2)
        XCTAssertTrue(authorizations.allSatisfy { $0 })

        XCTAssertEqual(urlA, urlB, "两个调用者必须拿到同一份内容")
        XCTAssertEqual(urlA.value.path, urlB.value.path)
        XCTAssertNotEqual(urlC.value.path, urlA.value.path, "不同 itemID 不得被合并成一份")

        let payload = await transport.payload()
        XCTAssertEqual(try Data(contentsOf: urlA.value), payload, "交付的文件必须就是那一次传输的字节")
        XCTAssertEqual(try Data(contentsOf: urlC.value).count, payload.count)
        XCTAssertEqual(try posixMode(of: urlA.value.path) & 0o777, PrivateAudioPath.fileMode)
        let cached = await fetcher.cachedFileCount()
        XCTAssertEqual(cached, 2, "去重不得让缓存计数虚增（一份内容一个文件）")
        let inflight = try? FileManager.default.contentsOfDirectory(
            atPath: PrivateAudioPath.temporaryDirectory(base: directory.url).path
        )
        XCTAssertTrue((inflight ?? []).isEmpty, "在途分片必须被 move 走：\(inflight ?? [])")
    }

    /// M7b：清理之后到达的请求，绝不复用清理前开始的传输（否则会把字节投进刚被清空的目录）。
    func testRequestArrivingAfterPurgeStartsItsOwnTransfer() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = GatedPrivateAudioTransport()
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        let sharedKey = request()
        async let first: Result<AudioURL, PlayerError> = fetcher.localizedURL(for: sharedKey)
        let parked = await Signals.wait(target: 1, counter: transport.enteredSignal)
        XCTAssertTrue(parked, "前置条件：第一路已进入传输")

        let cleared = await fetcher.purgeAll()
        XCTAssertEqual(cleared, 0, "此时还没有可删的缓存")
        let liveAfterPurge = await fetcher.inflightTransferCount
        XCTAssertEqual(liveAfterPurge, 0, "清理必须作废在途登记表")

        async let second: Result<AudioURL, PlayerError> = fetcher.localizedURL(for: sharedKey)
        await transport.release()
        _ = await first
        let result = await second
        guard case .success = result else { return XCTFail("清理之后的请求必须自己完成取回：\(result)") }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2, "清理前开始的传输不得被复用")
    }

    /// M7 的正向对照：串行的第二次请求走缓存命中，既不重复传输也不进登记表。
    func testSequentialRequestsStillHitCacheAndLeaveNoInflightEntries() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = GatedPrivateAudioTransport()
        await transport.release()
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        _ = await fetcher.localizedURL(for: request())
        _ = await fetcher.localizedURL(for: request())
        _ = await fetcher.localizedURL(for: request())
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
        let live = await fetcher.inflightTransferCount
        XCTAssertEqual(live, 0, "完成的传输必须从登记表摘除")
    }

    // MARK: - 环 4 · F-13：清理面必须挂在协议上（不是「记得去够实现方的 purge」）

    /// 通过 `PlaybackSourcePreparing` 协议面调用 → `PrivateAudioFetcher` 必须真的清了盘。
    /// （删掉实现方的覆盖 → 落到协议的默认空实现 → 这条立刻变红。）
    func testDiscardPrivateAudioThroughProtocolSurfacePurgesOwnersFiles() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = StubPrivateAudioTransport()
        let fetcher = makeFetcher(in: directory, transport: transport)
        _ = await fetcher.localizedURL(for: request())
        _ = await fetcher.localizedURL(for: request(itemID: "two"))
        let before = await fetcher.cachedFileCount()
        XCTAssertEqual(before, 2, "前置条件：两份私有音频已落盘")

        let preparer: any PlaybackSourcePreparing = fetcher
        await preparer.discardPrivateAudio(owner: PrincipalID(rawValue: "principal-1"))

        let after = await fetcher.cachedFileCount()
        XCTAssertEqual(after, 0, "协议面的清理必须真的删到磁盘")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: PrivateAudioPath.ownerDirectory(base: directory.url, owner: PrincipalID(rawValue: "principal-1")).path
            )
        )
        // 未知归属（nil）= 全量清除
        _ = await fetcher.localizedURL(for: request(itemID: "three"))
        await preparer.discardPrivateAudio(owner: nil)
        let everything = await fetcher.cachedFileCount()
        XCTAssertEqual(everything, 0)
    }

    // MARK: - 环 4 · 第 6 批 MAJ-1：上层取消必须真的终止合流那一路下载

    /// MAJ-1（原 TD-40 的证否）：`caller.cancel()` 过去只是让调用者自己退出 ——
    /// 合流用的无结构 `Task` **不继承**调用者取消，`await task.value` 也不查取消，
    /// 于是下载照跑、文件照提交、结果照投递。本用例把三件事逐一钉住：
    /// 传输那一路确实终止、沙盒里没有任何交付物、调用者拿不到可播地址。
    func testUpperLayerCancellationTerminatesInFlightTransfer() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = CancellablePrivateAudioTransport()
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        let shared = request()

        let caller = Task { await fetcher.localizedURL(for: shared) }
        let entered = await Signals.wait(target: 1, counter: transport.enteredSignal)
        XCTAssertTrue(entered, "前置条件：传输必须真的在途（否则什么都没测到）")
        let inflightBefore = await fetcher.inflightTransferCount
        XCTAssertEqual(inflightBefore, 1)

        caller.cancel()
        // 等待有上界：取消没传导时这里变红，而不是把测试挂死（D16⑤）。
        let terminated = await Signals.wait(target: 1, counter: transport.terminatedSignal)
        XCTAssertTrue(terminated, "MAJ-1：上层取消必须终止合流中的下载（旧行为：caller.isCancelled 而下载照跑）")
        // 兜底放行：只有「已经变红」的实现才需要它来解锁（TD-35 的教训）。
        // 正确实现下这一路已由取消决出，`settle` 首次生效原则让这里的放行成为空操作。
        await transport.release()

        let outcome = await caller.value
        guard case .failure(let error) = outcome else {
            return XCTFail("被取消的调用绝不许拿到可播地址：\(outcome)")
        }
        XCTAssertEqual(error, .cancelled, "取消必须归一为 `.cancelled`：\(error)")
        let committed = await fetcher.cachedFileCount()
        XCTAssertEqual(committed, 0, "取消的一路不得提交任何文件")
        let inflightAfter = await fetcher.inflightTransferCount
        XCTAssertEqual(inflightAfter, 0, "终止后的传输必须从登记表摘除")
        let completed = await transport.completedCount
        XCTAssertEqual(completed, 0, "桩侧也必须观测到「没有一次完成」")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: PrivateAudioPath.temporaryDirectory(base: directory.url).path
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "在途分片必须被删净：\(leftovers)")
    }

    /// MAJ-1 的合流腿：同一 key 的多个调用者共享那一路真实传输（去重本身由
    /// `testConcurrentSameKeyRequestsTriggerExactlyOneTransfer` 钉住），因此**任何一方**退出时
    /// 都不许留下「别人替它决定的一份字节」。本用例刻意把两个调用者一起取消：
    /// 于是「加入者是否已经走到合流分支」不再影响结论（不依赖调度顺序，D16⑤），
    /// 判据仍然是硬的两条 —— 谁都没拿到地址、盘上一个文件都没有。
    func testCancellationByBothMergedCallersDeliversNoPlayableURL() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = CancellablePrivateAudioTransport()
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        let shared = request()

        let first = Task { await fetcher.localizedURL(for: shared) }
        let entered = await Signals.wait(target: 1, counter: transport.enteredSignal)
        XCTAssertTrue(entered, "前置条件：第一路已进入传输")
        let merged = await fetcher.inflightTransferCount
        XCTAssertEqual(merged, 1, "登记表里就该有一条在途传输")
        let second = Task { await fetcher.localizedURL(for: shared) }

        first.cancel()
        second.cancel()
        let terminated = await Signals.wait(target: 1, counter: transport.terminatedSignal)
        XCTAssertTrue(terminated, "MAJ-1：合流后调用者的取消必须终止那一路真实传输（无结构任务不继承取消）")
        await transport.release() // 兜底解锁（见上一条用例的注释）
        let a = await first.value
        let b = await second.value
        guard case .failure(let errorA) = a else { return XCTFail("取消方不得拿到地址：\(a)") }
        XCTAssertEqual(errorA, .cancelled)
        guard case .failure(let errorB) = b else { return XCTFail("合流方同样不得拿到地址：\(b)") }
        XCTAssertEqual(errorB, .cancelled)
        let committed = await fetcher.cachedFileCount()
        XCTAssertEqual(committed, 0, "被作废的传输不得留下交付物")
        let inflight = await fetcher.inflightTransferCount
        XCTAssertEqual(inflight, 0, "终止后的传输必须从登记表摘除")
        let completed = await transport.completedCount
        XCTAssertEqual(completed, 0)
    }

    /// MAJ-1 的第二腿（最难的那种形态）：出口**不理会**任务取消时，取消仍不得产出交付物。
    ///
    /// 只测「合作型出口」会漏掉真实风险：字节可能已在缓冲、取消要等到下一块才被看到，
    /// 于是传输真的跑完了、真的把文件写到了临时路径。此时唯一还站得住的防线是
    /// 准备器**提交前**的取消复核 —— 少了它，`.cancelled` 虽然回给了调用者，
    /// 盘上却多出一份没人认领的私有音频（缓存复用腿下次会把它当可用缓存交付出去）。
    func testUncooperativeTransportStillCannotDeliverAfterCancellation() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = CancellablePrivateAudioTransport()
        await transport.configureHonoringCancellation(false)
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        let shared = request()

        let caller = Task { await fetcher.localizedURL(for: shared) }
        let entered = await Signals.wait(target: 1, counter: transport.enteredSignal)
        XCTAssertTrue(entered, "前置条件：传输已进入不合作出口")
        caller.cancel()
        let inflight = await fetcher.inflightTransferCount
        XCTAssertEqual(inflight, 1)
        // 不合作的出口只能由测试放行：它会把整份字节写完并交出回执。
        await transport.release()

        let outcome = await caller.value
        guard case .failure(let error) = outcome else {
            return XCTFail("MAJ-1：出口跑完也不得投递可播地址：\(outcome)")
        }
        XCTAssertEqual(error, .cancelled)
        let completed = await transport.completedCount
        XCTAssertEqual(completed, 1, "前置条件：传输确实**跑完了**（否则这条判据什么都没测到）")
        let committed = await fetcher.cachedFileCount()
        XCTAssertEqual(committed, 0, "MAJ-1：跑完的被取消传输绝不提交（提交前必须复核取消）")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: PrivateAudioPath.temporaryDirectory(base: directory.url).path
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "临时分片必须被删净：\(leftovers)")
        // 缓存复用面也不得把它当可用缓存交出去（第二次请求仍是一次真实取回）。
        let second = await fetcher.localizedURL(for: shared)
        guard case .success = second else { return XCTFail("重取应成功：\(second)") }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2, "上一次没留下任何可复用的东西")
        let afterSecond = await fetcher.cachedFileCount()
        XCTAssertEqual(afterSecond, 1)
    }

    // MARK: - 环 4 · 第 6 批 MAJ-3：清理前作废在途是**义务**（默认空实现已删除）

    /// MAJ-3：`purgeAll()` / `purge(owner:)` 必须先让出口作废在途，否则那一路会在清理之后
    /// 跑完并投递结果。旧协议带着 `cancelInFlightTransfers()` 的**默认空实现**，因此
    /// 「只实现 `writeAudio` 的出口」照样编得过、照样把私有音频写回沙盒 ——
    /// 盘上干净只是 `commitMove` 撞 ENOENT 的巧合。本用例用一个**真的会终止在途**的出口，
    /// 把「作废 → 终止 → 不投递 → 之后仍可服务」这条链钉死。
    func testPurgeIsNotDefeatedByInFlightTransferOnRequiredCancellation() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = CancellablePrivateAudioTransport()
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        let shared = request()
        let caller = Task { await fetcher.localizedURL(for: shared) }
        let entered = await Signals.wait(target: 1, counter: transport.enteredSignal)
        XCTAssertTrue(entered, "前置条件：在途传输已开始（已授权）")

        let removed = await fetcher.purge(owner: PrincipalID(rawValue: "principal-1"))
        XCTAssertEqual(removed, 0, "此刻还没有已提交的缓存可删")
        let requests = await transport.cancellationRequests
        XCTAssertEqual(requests, 1, "D16②：清理之前必须作废在途")
        let terminated = await Signals.wait(target: 1, counter: transport.terminatedSignal)
        XCTAssertTrue(terminated, "MAJ-3：作废必须真的终止那一路（默认空实现下它会跑完并投递结果）")
        await transport.release() // 兜底解锁（见 MAJ-1 用例的注释）：只在已经变红时才用得上

        let outcome = await caller.value
        guard case .failure(let error) = outcome else {
            return XCTFail("清理之后到达的结果不得投递：\(outcome)")
        }
        XCTAssertEqual(error, .cancelled)
        // 出口没被打死：作废只掐当前在途，清理之后仍须能为新会话取音频（D16② 的另一半）。
        let afterPurge = await fetcher.localizedURL(for: request(itemID: "after-purge"))
        guard case .success = afterPurge else {
            return XCTFail("作废在途不是打死出口：清理之后必须仍能取回：\(afterPurge)")
        }
        let committed = await fetcher.cachedFileCount()
        XCTAssertEqual(committed, 1, "只有清理之后新起的那一路有交付物")
    }

    /// MAJ-4 的账目腿：被作废的传输必须归一为「取消」，**不得**计入失败连击。
    ///
    /// 机理：真实传输在会话被作废后抛的是裸 `NSURLError(-999)`；不归一时它会经
    /// `writeFailed(-999)` → `missingFile` → `countsTowardFailureStreak == true`，
    /// 于是登出/断网造成的取消会喂 design §9「连续 3 次失败停止」。
    func testInvalidatedTransferNeverCountsTowardFailureStreak() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport = CancellablePrivateAudioTransport()
        let fetcher = makeFetcherOn(in: directory, transport: transport)
        let shared = request()
        let caller = Task { await fetcher.localizedURL(for: shared) }
        let entered = await Signals.wait(target: 1, counter: transport.enteredSignal)
        XCTAssertTrue(entered, "前置条件：出口已交出裸 -999 的形态（未归一就是失败）")
        await transport.cancelInFlightTransfers()
        let outcome = await caller.value
        guard case .failure(let error) = outcome else { return XCTFail("作废后不得投递：\(outcome)") }
        XCTAssertEqual(error, .cancelled, "MAJ-4：裸 -999 必须在准备器侧归一为取消：\(error)")

        let kind = PlaybackCoordinator.kind(for: error)
        XCTAssertEqual(kind, .cancelled, "协调器口径同样是取消")
        let failure = PlayerFailure(kind: kind, message: error.description)
        XCTAssertFalse(failure.countsTowardFailureStreak, "取消不得进 design §9 的失败连击")

        // TD-9 反向对照（判据不许过宽）：非取消形态的底层错误仍然是「失败」。
        let stray = NSError(domain: NSCocoaErrorDomain, code: 516)
        XCTAssertFalse(PrivateAudioFetcher.isCancellationShaped(stray), "别域错误不得被当成取消")
        XCTAssertEqual(PrivateAudioFetcher.status(of: stray), 516)
        XCTAssertTrue(
            PlayerFailure(kind: PlaybackCoordinator.kind(for: .writeFailed(516)), message: "")
                .countsTowardFailureStreak,
            "真实写失败照旧计连击"
        )
        XCTAssertTrue(PrivateAudioFetcher.isCancellationShaped(CancellationError()))
        XCTAssertTrue(PrivateAudioFetcher.isCancellationShaped(URLError(.cancelled)))
        XCTAssertFalse(PrivateAudioFetcher.isCancellationShaped(URLError(.networkConnectionLost)))
    }

    // MARK: - 夹具（环 4 新增）

    /// 缓存根下的 owner 目录名（`.inflight` 是隐藏目录，不计入 owner 集合）。
    private func ownerDirectories(in cacheRoot: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent)) ?? [])
    }

    /// 接受任意传输桩的取回器（既有 `makeFetcher` 只收 `StubPrivateAudioTransport`，一字未动）。
    private func makeFetcherOn(
        in directory: TemporaryDirectory,
        transport: any PrivateAudioTransport
    ) -> PrivateAudioFetcher {
        try! PrivateAudioFetcher(
            transport: transport,
            credentials: StubCredentialProvider(),
            baseDirectory: directory.url
        )
    }

    /// 注入「删除会失败」的文件管理器（m13 夹具；既有的 `makeFetcher` 一字未动）。
    private func makeFetcher(
        in directory: TemporaryDirectory,
        transport: any PrivateAudioTransport,
        fileManager: sending FileManager
    ) -> PrivateAudioFetcher {
        try! PrivateAudioFetcher(
            transport: transport,
            credentials: StubCredentialProvider(),
            baseDirectory: directory.url,
            fileManager: fileManager
        )
    }

    /// 在 `.inflight` 里预置分片（模拟进程被杀 / ObjC 写异常留下的半文件）。
    @discardableResult
    private func seedInflightShards(in directory: TemporaryDirectory, names: [String]) throws -> [URL] {
        let inflight = PrivateAudioPath.temporaryDirectory(base: directory.url)
        try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
        var seeded: [URL] = []
        for name in names {
            let url = inflight.appendingPathComponent(name)
            try Data(repeating: 0x2f, count: 7).write(to: url)
            seeded.append(url)
        }
        return seeded
    }

    private func posixMode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let raw = attributes[.posixPermissions] as? NSNumber else { throw PlayerError.writeFailed(ENODATA) }
        return Int(truncatingIfNeeded: raw.int32Value)
    }
}
