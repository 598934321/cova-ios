import CovaCore
import Foundation
@testable import CovaPlayer

// MARK: - 确定性时钟（禁止真实等待，D16⑤）

/// 虚拟时钟：`advance` 即跳转，`sleep` 只挪刻度不真正挂起。
actor FakeClock: CovaClock {
    private var value: TimeInterval

    init(start: TimeInterval = 0) {
        value = start
    }

    func now() -> TimeInterval { value }

    func advance(_ by: TimeInterval) {
        value += by
    }

    func sleep(seconds: TimeInterval) async throws {
        value += seconds
    }
}

// MARK: - 引擎桩

/// 脚本化引擎：记录调用、按需投递事件（零 AVFoundation、零音频硬件）。
final class ScriptedEngine: PlayerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let pairing = AsyncStream.makeStream(of: PlayerEvent.self)
    private var _calls: [String] = []
    private var _loads: [PlaybackItem] = []
    private var _seeks: [Double] = []
    private var _rates: [Double] = []
    private var _time: Double = 0
    private var _duration: Double?
    private var _releaseCount = 0

    var events: AsyncStream<PlayerEvent> { pairing.stream }

    func load(_ item: PlaybackItem) async {
        record("load")
        mutate { _loads.append(item) }
    }

    func play() async { record("play") }
    func pause() async { record("pause") }

    func seek(to seconds: Double) async {
        record("seek")
        mutate {
            _seeks.append(seconds)
            _time = seconds
        }
    }

    func setRate(_ rate: Double) async {
        record("setRate")
        mutate { _rates.append(rate) }
    }

    func currentRate() async -> Double { snapshot { _rates.last ?? 1 } }
    func currentTime() async -> Double { snapshot { _time } }

    func currentDuration() async -> Double? { snapshot { _duration } }

    func stopAndRelease() {
        record("release")
        mutate { _releaseCount += 1 }
    }

    // MARK: 测试驱动面

    func emit(_ event: PlayerEvent) {
        pairing.continuation.yield(event)
    }

    func finishStream() {
        pairing.continuation.finish()
    }

    func setDuration(_ value: Double?) {
        mutate { _duration = value }
    }

    var calls: [String] { snapshot { _calls } }
    var loads: [PlaybackItem] { snapshot { _loads } }
    var seeks: [Double] { snapshot { _seeks } }
    var rates: [Double] { snapshot { _rates } }
    var releaseCount: Int { snapshot { _releaseCount } }
    var callCount: Int { snapshot { _calls.count } }

    func count(of call: String) -> Int {
        snapshot { _calls.filter { $0 == call }.count }
    }

    private func record(_ call: String) {
        mutate { _calls.append(call) }
    }

    private func mutate(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    private func snapshot<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Now Playing 桩

/// 信号计数器：「等信号再断言」的最小原语（D16⑤ 禁止用让步/时间猜测做断言）。
///
/// `wait` 挂起直到计数达标；`timeout` 只把「信号永不到来」的回归从挂死转成变红，
/// 不参与任何断言判定（达标即由 `bump` 直接放行）。
final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    private typealias Waiter = (target: Int, continuation: CheckedContinuation<Bool, Never>)
    private var waiters: [Waiter] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var value: Int { locked { _value } }

    func bump() {
        let ready = locked { () -> [Waiter] in
            _value += 1
            let current = _value
            let hits = waiters.filter { $0.target <= current }
            waiters.removeAll { $0.target <= current }
            return hits
        }
        for hit in ready { hit.continuation.resume(returning: true) }
    }

    /// 挂起直到计数达标（同步临界区里的注册，不违反「async 上下文禁用 NSLock」）。
    func wait(target: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let satisfied = locked { () -> Bool in
                if _value >= target { return true }
                waiters.append((target, continuation))
                return false
            }
            if satisfied { continuation.resume(returning: true) }
        }
    }

    /// 放弃等待（超时兜底路径）：摘出并唤醒，避免 continuation 泄漏。
    func abandonWaiting(target: Int) {
        let pending = locked { () -> [Waiter] in
            let hits = waiters.filter { $0.target == target }
            waiters.removeAll { $0.target == target }
            return hits
        }
        for hit in pending { hit.continuation.resume(returning: false) }
    }
}

/// 带真实时间上界的等待：上界只把「信号永不到来」的回归从挂死转成变红，不参与行为判定。
enum Signals {
    static func wait(
        target: Int,
        counter: SignalCounter,
        timeout: TimeInterval = 10
    ) async -> Bool {
        if counter.value >= target { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await counter.wait(target: target) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let winner = await group.next() ?? false
            group.cancelAll()
            counter.abandonWaiting(target: target)
            return winner || counter.value >= target
        }
    }
}

/// 记录型元数据发布器（决策路径全部在此可断言，不需要 MediaPlayer）。
actor RecordingNowPlaying: NowPlayingControlling {
    let publishSignal = SignalCounter()
    private(set) var published: [NowPlayingMetadata] = []
    private(set) var clearCount = 0
    private(set) var teardownCount = 0

    func publish(_ metadata: NowPlayingMetadata) {
        published.append(metadata)
        publishSignal.bump()
    }

    var publishCount: Int { published.count }

    func clear() {
        clearCount += 1
    }

    func teardown() {
        teardownCount += 1
        published = []
        clearCount += 1
    }

    var lastPublished: NowPlayingMetadata? { published.last }
}

// MARK: - 上报提交桩

/// 可编程的播放上报桩（**绝不触碰网络**）。
actor StubPlayReportSubmitter: PlayReportSubmitting {
    struct Script: Sendable {
        /// 第 n 次调用抛错（0 基）。
        var failures: [Int: PlayReportFailureKind] = [:]
        /// 第 n 次调用返回 `idempotentReplay`。
        var replays: Set<Int> = []
    }

    enum PlayReportFailureKind: Error { case transport, unauthorized, rejected, decoding }

    private(set) var requests: [PlayReportRequestDto] = []
    private var script = Script()

    func script(_ update: Script) {
        script = update
    }

    var callCount: Int { requests.count }

    var keys: [IdempotencyKey] { requests.map(\.idempotencyKey) }
    var trackIDs: [String] { requests.map(\.trackId) }
    var sources: [String] { requests.map(\.source) }

    func submit(_ request: PlayReportRequestDto) async throws -> PlayReportResponseDto {
        let index = requests.count
        requests.append(request)
        switch script.failures[index] {
        case .transport: throw CovaAPIError.offline
        case .unauthorized: throw CovaAPIError.unauthorized(apiCode: nil)
        case .rejected: throw CovaAPIError.httpStatus(code: 500, apiCode: nil)
        case .decoding: throw CovaAPIError.decoding(field: "recorded")
        case .none: break
        }
        // TD-14：响应 DTO 刻意无 public init（只由解码产出）→ 桩也走解码路径。
        let replay = script.replays.contains(index)
        let json: String = replay
            ? "{\"recorded\":true,\"idempotentReplay\":true,\"authenticated\":true}"
            : "{\"recorded\":true,\"idempotentReplay\":false,\"authenticated\":true}"
        return try JSONDecoder().decode(PlayReportResponseDto.self, from: Data(json.utf8))
    }
}

// MARK: - 凭证 / 私有音频传输桩

/// 桩凭证提供器：返回固定快照（可切换 owner / generation）。
struct StubCredentialProvider: APICredentialProviding {
    let snapshot: AuthSessionSnapshot?
    let throwsOnRead: Bool

    init(principal: String? = "principal-1", generation: SessionGeneration = .initial, throwsOnRead: Bool = false) {
        if let principal {
            snapshot = AuthSessionSnapshot(
                principal: PrincipalID(rawValue: principal),
                generation: generation,
                accessToken: SecretString("stub-access-token-value")
            )
        } else {
            snapshot = nil
        }
        self.throwsOnRead = throwsOnRead
    }

    func currentSession() async throws -> AuthSessionSnapshot? {
        if throwsOnRead { throw CovaAPIError.credentialReadFailed }
        return snapshot
    }

    func refreshAccessToken(for snapshot: AuthSessionSnapshot) async throws -> SecretString {
        snapshot.accessToken
    }
}

/// 落盘式传输桩：按脚本写字节 / 抛错，并记录调用形态。
actor StubPrivateAudioTransport: PrivateAudioTransport {
    struct Behavior: Sendable {
        var bytesToWrite: Int = 16
        var declaresExpectedBytes: Bool = true
        var throwsError: PlayerError?
        var writesToDisk = true
    }

    private(set) var calls: [PrivateAudioCall] = []
    var behavior = Behavior()

    struct PrivateAudioCall: Sendable {
        let url: URL
        let hasAuthorization: Bool
        let destination: URL
        let expectedBytes: Int?
    }

    func configure(_ update: Behavior) {
        behavior = update
    }

    var callCount: Int { calls.count }
    var lastCall: PrivateAudioCall? { calls.last }

    func writeAudio(
        from url: URL,
        authorization: SecretString?,
        to fileURL: URL,
        expectedBytes: Int?
    ) async throws -> PrivateAudioReceipt {
        calls.append(PrivateAudioCall(
            url: url,
            hasAuthorization: authorization != nil,
            destination: fileURL,
            expectedBytes: expectedBytes
        ))
        if let error = behavior.throwsError { throw error }
        if Task.isCancelled { throw PlayerError.cancelled }
        let payload = Data(repeating: 0x5a, count: max(0, behavior.bytesToWrite))
        if behavior.writesToDisk {
            FileManager.default.createFile(atPath: fileURL.path, contents: payload)
        }
        return PrivateAudioReceipt(
            bytesWritten: payload.count,
            expectedBytes: behavior.declaresExpectedBytes ? payload.count : expectedBytes,
            statusCode: 200
        )
    }
}

/// 记录型源准备器。
actor StubSourcePreparer: PlaybackSourcePreparing {
    enum Mode: Sendable {
        /// 需要本地化的条目落到一个合法沙盒 file URL（模拟 D7 的下载成功路径）。
        case localizes
        case failWith(PlayerError)
    }

    var mode: Mode = .localizes
    private(set) var requests: [String] = []

    func configure(_ update: Mode) {
        mode = update
    }

    var callCount: Int { requests.count }

    func prepareSource(
        for item: PlaybackItem,
        session: PlaybackSessionContext
    ) async -> Result<PlaybackItem, PlayerError> {
        requests.append(item.id)
        switch mode {
        case .localizes:
            guard item.requiresLocalization else { return .success(item) }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cova-stub-localized", isDirectory: true)
            return .success(item.localized(to: TestItems.fileURL(root.appendingPathComponent(item.id).path)))
        case .failWith(let error):
            return .failure(error)
        }
    }
}

/// 封面挂载桩：可控制耗时与否（用信号式等待，不做时间猜测）。
actor StubArtworkAttacher: NowPlayingArtworkAttaching {
    private(set) var requests: [String] = []
    var result = true

    func configure(result: Bool) {
        self.result = result
    }

    var callCount: Int { requests.count }

    func attachArtwork(for metadata: NowPlayingMetadata) async -> Bool {
        requests.append(metadata.itemID)
        return result
    }
}

// MARK: - 条目工厂

enum TestItems {
    static let publicHost = "https://cdn.covalink.example"

    static func audioURL(_ path: String = "/audio/one.m4a") -> AudioURL {
        try! AudioURL(https: URL(string: "\(publicHost)\(path)")!)
    }

    static func fileURL(_ path: String) -> AudioURL {
        try! AudioURL(file: URL(fileURLWithPath: path))
    }

    static func make(
        _ id: String,
        title: String? = nil,
        artist: String = "艺人",
        album: String? = nil,
        duration: Double? = 100,
        kind: PlaybackItem.Kind = .libraryTrack,
        source: PlaybackItem.AudioSource? = nil,
        cover: AudioURL? = nil
    ) -> PlaybackItem {
        try! PlaybackItem(
            id: id,
            title: title ?? "曲目-\(id)",
            artist: artist,
            album: album,
            duration: duration,
            coverURL: cover ?? audioURL("/cover/\(id).jpg"),
            audioSource: source ?? .publicDirect(audioURL("/audio/\(id).m4a")),
            kind: kind
        )
    }

    static func makeMany(_ ids: [String], duration: Double? = 100) -> [PlaybackItem] {
        ids.map { make($0, duration: duration) }
    }
}

/// 临时沙盒目录（每个用例独占，测试结束即删）。
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL
    private let fileManager = FileManager.default

    init(subdirectory: String = UUID().uuidString) {
        url = fileManager.temporaryDirectory
            .appendingPathComponent("cova-player-tests", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? fileManager.removeItem(at: url)
    }
}
