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
///
/// 与生产适配器**同一套代际口径**（`EngineEventGate`）：`load` / `stopAndRelease` 推进代际，
/// 观测者形态的事件走 `emitObserved(_:from:)`，于是「上一项的迟到通知」可以被确定性回放。
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
    private var gate = EngineEventGate()

    var events: AsyncStream<PlayerEvent> { pairing.stream }

    func load(_ item: PlaybackItem) async {
        record("load")
        mutate {
            _loads.append(item)
            _ = gate.advance()
        }
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
        mutate {
            _rates.append(rate)
        }
    }

    func currentRate() async -> Double { snapshot { _rates.last ?? 1 } }
    func currentTime() async -> Double { snapshot { _time } }

    func currentDuration() async -> Double? { snapshot { _duration } }

    func stopAndRelease() {
        record("release")
        mutate {
            _releaseCount += 1
            _ = gate.advance()
        }
    }

    // MARK: 测试驱动面

    /// 直接投递（不经闸门）：用于「协调器收到这条事件后如何归约」的纯状态测试。
    func emit(_ event: PlayerEvent) {
        pairing.continuation.yield(event)
    }

    /// 当前装载代际（`load` 之后它就是观测者块捕获的那个值）。
    var currentEpisode: UInt64 { snapshot { gate.episode } }

    /// 观测者形态的事件：与 `AVPlayerEngine.deliverObserved` 同一判据
    /// —— 过期代际与同代重复 `.ended` 在进事件流之前就被丢弃。返回是否真的投递了。
    @discardableResult
    func emitObserved(_ event: PlayerEvent, from episode: UInt64) -> Bool {
        let allowed = mutate { gate.accepts(event, from: episode) }
        guard allowed else { return false }
        pairing.continuation.yield(event)
        return true
    }

    /// 直读闸门判定（不投递），用于把「丢弃」本身变成可断言的事实。
    func gateAccepts(_ event: PlayerEvent, from episode: UInt64) -> Bool {
        mutate { gate.accepts(event, from: episode) }
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

    @discardableResult
    private func mutate<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func snapshot<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - 「装载在途」可控的引擎桩（F-8 的触发面）

/// 可控引擎桩：`load` 进入后**真的挂起**，直到测试点名放行。
///
/// 用途：`PlayerEngine` 契约规定「`load(_:)` 不抛错：失败一律以 `.failed` 事件表达」
/// （见 `PlayerEngine.swift`）。协调器此刻正等在 `await engine.load` 上、引擎账本尚未
/// 记账，只有测试能把这条失败投进归约入口 —— 没有本桩就没有确定性现场（F-8）。
///
/// 等待带**真实时间上界**（`releaseTimeout`）：忘记放行时用例变红而不是挂死；
/// 上界不参与任何行为判定（D16⑤）。
final class GatedLoadEngine: PlayerEngine, @unchecked Sendable {
    /// 第 n 次 `load` 已进入引擎（装载正在途）。
    let enteredLoad = SignalCounter()
    /// 第 n 次 `load` 已返回给协调器。
    let returnedLoad = SignalCounter()
    /// 放行计数：每次 `releaseLoad()` 放行一次在途装载。
    let releases = SignalCounter()

    private let lock = NSLock()
    private let pairing = AsyncStream.makeStream(of: PlayerEvent.self)
    private var _calls: [String] = []
    private var _loads: [PlaybackItem] = []
    private var _seeks: [Double] = []
    private var _rates: [Double] = []
    private var _time: Double = 0
    private var _duration: Double?
    private var _releaseCount = 0
    private var loadSequence = 0
    private let releaseTimeout: TimeInterval

    init(releaseTimeout: TimeInterval = 10) {
        self.releaseTimeout = releaseTimeout
    }

    var events: AsyncStream<PlayerEvent> { pairing.stream }

    func load(_ item: PlaybackItem) async {
        record("load")
        let turn = mutate {
            _loads.append(item)
            loadSequence += 1
            return loadSequence
        }
        enteredLoad.bump()
        // 真挂起点：协调器停在 `await engine.load` 里，测试得以在这段窗口内归约事件。
        _ = await Signals.wait(target: turn, counter: releases, timeout: releaseTimeout)
        returnedLoad.bump()
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

    /// 放行一次在途装载（`load` 就此返回给协调器）。
    func releaseLoad() {
        releases.bump()
    }

    /// 直接投递（不经闸门）：与 `ScriptedEngine.emit` 同口径。
    func emit(_ event: PlayerEvent) {
        pairing.continuation.yield(event)
    }

    func finishStream() {
        pairing.continuation.finish()
    }

    var calls: [String] { snapshot { _calls } }
    var loads: [PlaybackItem] { snapshot { _loads } }
    var seeks: [Double] { snapshot { _seeks } }
    var releaseCount: Int { snapshot { _releaseCount } }
    var callCount: Int { snapshot { _calls.count } }

    func count(of call: String) -> Int {
        snapshot { _calls.filter { $0 == call }.count }
    }

    private func record(_ call: String) {
        mutate { _calls.append(call) }
    }

    @discardableResult
    private func mutate<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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

/// **在途可控**的上报提交桩（F-C 的触发面）。
///
/// 用途：`retryPending` 只看「这一集次还没 submitted」，于是「提交在途 + 回前台补发」重叠时
/// 同一次实际播放会被写两次（同键）。要把它变成可断言的事实，需要两件事同时成立：
/// - 第一次提交**真的挂在那里**（`submit` 进入后等放行）—— 这就是重叠窗口；
/// - 之后的调用**照常直通** —— 否则「实现走偏（真的发了第二次）」时用例挂死而不是变红。
///
/// 因此闸门只挡前 `blockingCalls` 次（默认 1 次）；`maxConcurrentInFlight` 把
/// 「同一刻有两路写在途」本身变成可读取的事实，全程不需要让步或睡眠（D16⑤）。
/// `release()` 是**粘性**的：已放行之后的新调用直接通过。
actor GatedPlayReportSubmitter: PlayReportSubmitting {
    /// 第 n 次 `submit` 已进入（请求已记录、尚未返回 = 提交在途）。
    let enteredSignal = SignalCounter()

    /// 挡挂在途的调用次数（超出的调用直通，保证错误实现是「变红」而不是「挂死」）。
    private var blockingCalls: Int
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight = 0

    private(set) var requests: [PlayReportRequestDto] = []
    private(set) var maxConcurrentInFlight = 0

    init(blockingFirstCallCount: Int = 1) {
        blockingCalls = blockingFirstCallCount
    }

    var callCount: Int { requests.count }
    var keys: [IdempotencyKey] { requests.map(\.idempotencyKey) }
    var trackIDs: [String] { requests.map(\.trackId) }

    func submit(_ request: PlayReportRequestDto) async throws -> PlayReportResponseDto {
        requests.append(request)
        inFlight += 1
        maxConcurrentInFlight = max(maxConcurrentInFlight, inFlight)
        enteredSignal.bump()
        if blockingCalls > 0 {
            blockingCalls -= 1
            await waitUntilReleased()
        }
        inFlight -= 1
        return try JSONDecoder().decode(
            PlayReportResponseDto.self,
            from: Data(#"{"recorded":true,"idempotentReplay":false,"authenticated":true}"#.utf8)
        )
    }

    private func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    /// 放行全部在途（粘性：之后的调用直接通过）。
    func release() {
        released = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}

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

    /// MAJ-3：`cancelInFlightTransfers()` 已删除协议默认空实现 —— 桩也必须显式实现
    /// （本桩没有底层在途请求，所以显式记账 + 空动作即是正确语义）。
    func cancelInFlightTransfers() async {
        cancellationCount += 1
    }

    private(set) var cancellationCount = 0
}

/// 会计数的凭证提供器（环 4 · 第 6 批 min-3 的会合点）。
///
/// 为什么需要它：合流判据要求「加入者在先交付方结束**之前**走到登记表」，而 `localizedURL`
/// 从凭证返回到读登记表之间没有任何网络动作可观测。凭证读取正是那一段里唯一的挂起点：
/// 它一返回，加入者的续体就被排进取回器的 actor 信箱（FIFO），测试随后的一次 actor 回合
/// 必然排在它之后 —— 于是不靠让步、不靠猜时间就能确定性地会合（D16⑤）。
struct SignallingCredentialProvider: APICredentialProviding {
    let calls = SignalCounter()
    private let snapshot: AuthSessionSnapshot?

    init(principal: String = "principal-1", generation: SessionGeneration = .initial) {
        snapshot = AuthSessionSnapshot(
            principal: PrincipalID(rawValue: principal),
            generation: generation,
            accessToken: SecretString("stub-access-token-value")
        )
    }

    /// 未登录形态：读取成功但快照为 nil。
    init(signedOut: Bool) {
        snapshot = signedOut ? nil : AuthSessionSnapshot(
            principal: PrincipalID(rawValue: "principal-1"),
            generation: .initial,
            accessToken: SecretString("stub-access-token-value")
        )
    }

    var callCount: Int { calls.value }

    func currentSession() async throws -> AuthSessionSnapshot? {
        calls.bump()
        return snapshot
    }

    func refreshAccessToken(for snapshot: AuthSessionSnapshot) async throws -> SecretString {
        snapshot.accessToken
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

    /// MAJ-2：协议的默认空实现已删除 → 本桩不在磁盘上留任何私有音频字节，
    /// 因此这一行就是它的**免责申明**（显式空操作），而不是「忘记实现」。
    func discardPrivateAudio(owner: PrincipalID?) async {
        discardedOwners.append(owner)
    }

    private(set) var discardedOwners: [PrincipalID?] = []
    var discardCount: Int { discardedOwners.count }
}

/// **在途可控**的源准备器：指定 id 的条目在 `prepareSource` 里挂起，直到测试点名放行。
///
/// 用途：把「装载在途时用户换曲 / 释放播放器」这类 actor 重入窗口变成**可开关的门**，
/// 从而确定性复现过期回写（缺陷 P2），不需要任何时间猜测（D16⑤）。
///
/// 两个信号：
/// - `requestSignal`：进入 `prepareSource`（在途已开始）；
/// - `returnedSignal`：闸门放行后**即将返回**给协调器 —— 用作「续体已入队」的前置条件。
actor GatedSourcePreparer: PlaybackSourcePreparing {
    let requestSignal = SignalCounter()
    let returnedSignal = SignalCounter()
    private let gated: Set<String>
    private let failures: [String: PlayerError]
    private(set) var requests: [String] = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []

    init(gating ids: [String], failing: [String: PlayerError] = [:]) {
        gated = Set(ids)
        failures = failing
    }

    func prepareSource(
        for item: PlaybackItem,
        session: PlaybackSessionContext
    ) async -> Result<PlaybackItem, PlayerError> {
        requests.append(item.id)
        requestSignal.bump()
        if gated.contains(item.id) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if released.contains(item.id) {
                    continuation.resume()
                } else {
                    waiters[item.id] = continuation
                }
            }
        }
        returnedSignal.bump()
        if let error = failures[item.id] { return .failure(error) }
        return .success(item)
    }

    /// 放行指定条目的在途装载（被挂起的 `prepareSource` 就此返回给协调器）。
    func release(_ id: String) {
        released.insert(id)
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume()
        }
    }

    /// MAJ-2：本桩不落盘（只回 `.success(item)`），显式空操作 = 免责申明。
    func discardPrivateAudio(owner: PrincipalID?) async {}

    var callCount: Int { requests.count }
    var requestedIDs: [String] { requests }
    func returnedCount() -> Int { returnedSignal.value }
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
    /// 唯一生产出口上的主机（环 4 · 第 6 批 MAJ-8：引擎现在**判出口**，
    /// 所以「可播的公开直链」这一类夹具必须真的落在 `CovaEnvironment.isProductionOrigin` 上。
    /// 仍是零网络：`https://covalink.cn` 只出现在从未被解析的 `URL` 值里，
    /// 引擎侧的 `AVPlayerItem(url:)` 在模拟器上不会、也不该发出任何真实请求（本仓所有相关用例
    /// 只断言纯映射与事件形状，不装载这条地址）。
    static let productionHost = "https://covalink.cn"

    static func audioURL(_ path: String = "/audio/one.m4a") -> AudioURL {
        try! AudioURL(https: URL(string: "\(publicHost)\(path)")!)
    }

    static func productionAudioURL(_ path: String = "/audio/one.m4a") -> AudioURL {
        try! AudioURL(https: URL(string: "\(productionHost)\(path)")!)
    }

    /// 生产出口上的公开直链条目（引擎侧「可播」的正向夹具）。
    static func makeProduction(_ id: String = "pub", path: String = "/audio/one.m4a") -> PlaybackItem {
        make(id, source: .publicDirect(productionAudioURL(path)))
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

// MARK: - 环 4 私有音频收尾：在途可控传输桩 / 删除失败夹具 / 可观测的会话系统

/// **在途可控**的落盘传输桩（M7 / M8）。
///
/// 每次 `writeAudio` 都在写完字节之前挂起，直到测试点名放行 —— 于是「两路是否真的重叠在途」
/// 成为可确定性观测的事实（`maxConcurrentInFlight`），不需要任何让步或睡眠（D16⑤）。
/// `release()` 是**粘性**的：已放行之后的新调用直接通过，保证「实现走偏」时测试变红而不是挂死。
actor GatedPrivateAudioTransport: PrivateAudioTransport {
    /// 已进入传输的次数（每次调用一次）。
    let enteredSignal = SignalCounter()
    /// 已作废在途的次数（M8：`purge*` 真的掐了出口）。
    let cancelledSignal = SignalCounter()

    private(set) var destinations: [URL] = []
    private(set) var hosts: [String?] = []
    private(set) var sentAuthorizations: [Bool] = []
    private(set) var cancellationCount = 0
    private(set) var maxConcurrentInFlight = 0

    private var inFlight = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var bytesToWrite = 24
    /// 落盘用的字节内容（M7 用它证明「两个调用者拿到的是同一份内容」）。
    var marker: UInt8 = 0x69

    var callCount: Int { destinations.count }
    var lastDestination: URL? { destinations.last }

    func writeAudio(
        from url: URL,
        authorization: SecretString?,
        to fileURL: URL,
        expectedBytes: Int?
    ) async throws -> PrivateAudioReceipt {
        destinations.append(fileURL)
        hosts.append(url.host)
        sentAuthorizations.append(authorization != nil)
        inFlight += 1
        maxConcurrentInFlight = max(maxConcurrentInFlight, inFlight)
        enteredSignal.bump()
        await waitUntilReleased()
        inFlight -= 1
        // 刻意不带 `attributes:`（与 `StubPrivateAudioTransport` 同形）：
        // 权限收紧必须由准备器的提交面负责，m12 的断言才杀得掉「提交处漏了收紧」。
        FileManager.default.createFile(atPath: fileURL.path, contents: payload())
        return PrivateAudioReceipt(
            bytesWritten: bytesToWrite,
            expectedBytes: bytesToWrite,
            statusCode: 200
        )
    }

    func payload() -> Data { Data(repeating: marker, count: max(0, bytesToWrite)) }

    private func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    /// 放行全部在途（粘性：之后的调用直接通过）。
    func release() {
        released = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }

    func cancelInFlightTransfers() async {
        cancellationCount += 1
        cancelledSignal.bump()
    }
}

/// 删除即抛错的文件管理器（m13：删除失败不得被算成「已删除」）。
///
/// 尝试次数记在共享的 `SignalCounter` 上而不是自身：`PrivateAudioFetcher.init` 的
/// `fileManager` 参数是 `sending`（Swift 6：actor 非隔离 init 的所有权转移），
/// 夹具必须一次性构造、不能被测试再持引用。
final class ThrowingRemoveFileManager: FileManager, @unchecked Sendable {
    private let attempts: SignalCounter

    init(attempts: SignalCounter = SignalCounter()) {
        self.attempts = attempts
        super.init()
    }

    override func removeItem(at url: URL) throws {
        attempts.bump()
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}

/// 删除「静默不生效」的文件管理器（m13 的第二支：删除后复核，路径仍在就一个都不算删）。
final class SilentNoOpRemoveFileManager: FileManager, @unchecked Sendable {
    private let attempts: SignalCounter

    init(attempts: SignalCounter = SignalCounter()) {
        self.attempts = attempts
        super.init()
    }

    override func removeItem(at url: URL) throws {
        attempts.bump()
        // 「成功」但不做任何事：路径仍在磁盘上（旧实现会照报「已删 N 个」）。
    }
}

/// 「自身可观测」的桩音频会话系统（M3）：与生产 `AVAudioSessionAdapter` 同形状 ——
/// 既实现系统接口，又自己注册系统通知。用来断言「门不再依赖调用方额外传 `adapter:` 才接线」。
final class ObservingStubAudioSessionSystem: AudioSessionSystemInterface, AudioSessionNotificationObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Notification.Name: NSObjectProtocol] = [:]
    private weak var gate: AudioSessionGate?
    private var pending: AudioSessionSignal?

    /// 收到系统通知的次数（证明通知确实进了观测者，而不是只登记了个空壳）。
    let forwardedSignal = SignalCounter()

    var configureCount = 0
    var deactivateCount = 0

    // MARK: AudioSessionSystemInterface

    func configureForPlayback() throws {
        configureCount += 1
    }

    func deactivate() throws {
        deactivateCount += 1
    }

    func hasActiveOutputPorts() -> Bool { true }

    // MARK: AudioSessionNotificationObserving

    var observedNotificationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tokens.count
    }

    func attachNotifications(to gate: AudioSessionGate, routeProbe: any AudioSessionSystemInterface) async {
        attachSynchronously(to: gate)
    }

    func detachNotifications() async {
        detachSynchronously()
    }

    /// `NSLock` 不得进 async 上下文（与生产适配器同一做法）：注册/注销收敛到同步方法。
    private func attachSynchronously(to gate: AudioSessionGate) {
        lock.lock()
        self.gate = gate
        for name in AVAudioSessionAdapter.observedNotificationNames where tokens[name] == nil {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handle(notification)
            }
            tokens[name] = token
        }
        lock.unlock()
    }

    private func detachSynchronously() {
        lock.lock()
        let registered = Array(tokens.values)
        tokens = [:]
        gate = nil
        lock.unlock()
        for token in registered {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// 设定下一次通知要投进门里的信号（默认投「来电开始」）。
    func configureNextSignal(_ signal: AudioSessionSignal) {
        lock.lock()
        pending = signal
        lock.unlock()
    }

    var holdsGate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate != nil
    }

    private func handle(_ notification: Notification) {
        forwardedSignal.bump()
        lock.lock()
        let target = gate
        let signal = pending ?? .interruption(AudioInterruptionSignal(kind: .began))
        pending = nil
        lock.unlock()
        guard let target else { return }
        Task { await target.receive(signal) }
    }
}

/// **只实现协议清理面**的准备器（F-13 判据）：它不是 `PrivateAudioFetching`，
/// 所以门面无从「顺手去够实现方的 purge」—— 观测到的调用只可能来自协议要求的那一步。
actor RecordingPrivateAudioPreparer: PlaybackSourcePreparing {
    let discardedSignal = SignalCounter()
    private(set) var discardedOwners: [PrincipalID?] = []
    private(set) var prepared: [String] = []

    func prepareSource(
        for item: PlaybackItem,
        session: PlaybackSessionContext
    ) async -> Result<PlaybackItem, PlayerError> {
        prepared.append(item.id)
        return .success(item)
    }

    func discardPrivateAudio(owner: PrincipalID?) async {
        discardedOwners.append(owner)
        discardedSignal.bump()
    }

    var discardCount: Int { discardedOwners.count }
}

/// **会往磁盘写字节**的第二类准备器（环 4 · 第 6 批 MAJ-2 的判据形态）。
///
/// 它是复审给出的那个形态：只实现 `prepareSource`（真的落盘）+ 协议清理面。
/// 它**不是** `PrivateAudioFetching`，所以门面无从「顺手去够实现方的 purge」——
/// 登出后盘上干净与否，完全取决于协议面那一次调用有没有被真的实现、真的执行。
/// 旧协议带着 `discardPrivateAudio` 的默认空实现时，「忘记覆盖」是编译通过的静默失效；
/// 默认实现删除后漏覆盖直接编译不过（该义务的可证面因此从运行时上移到编译期，
/// 本类型守的是另一半：调用面真的清到了盘）。
actor FileWritingPrivateAudioPreparer: PlaybackSourcePreparing {
    let preparedSignal = SignalCounter()
    let discardedSignal = SignalCounter()
    private let directory: URL
    private let fileManager = FileManager.default
    private(set) var writtenURLs: [URL] = []
    private(set) var discardedOwners: [PrincipalID?] = []

    init(directory: URL) {
        self.directory = directory
    }

    func prepareSource(
        for item: PlaybackItem,
        session: PlaybackSessionContext
    ) async -> Result<PlaybackItem, PlayerError> {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("\(item.id).privateaudio")
            // 非空文件：与真实私有音频同形（「校验非空」那条判据也吃得到它）。
            try Data(repeating: 0x31, count: 12).write(to: target)
            writtenURLs.append(target)
            preparedSignal.bump()
            return .success(item.localized(to: try AudioURL(file: target)))
        } catch {
            return .failure(.writeFailed(Int32(truncatingIfNeeded: (error as NSError).code)))
        }
    }

    /// MAJ-2：必须实现（协议默认空实现已删除）；实现了就得真的清到磁盘。
    func discardPrivateAudio(owner: PrincipalID?) async {
        discardedOwners.append(owner)
        if writtenURLs.isEmpty == false || fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        discardedSignal.bump()
    }

    var discardCount: Int { discardedOwners.count }

    /// 仍然躺在盘上的「私有音频」文件（判据本体）。
    var survivingFiles: [URL] {
        writtenURLs.filter { fileManager.fileExists(atPath: $0.path) }
    }
}

// MARK: - 环 4 · 第 6 批：取消可观测的传输原语（MAJ-1 / MAJ-3 / MAJ-4）

/// 一路在途传输的**唤醒票据**：放行、出口作废、调用者取消三方争同一个槽。
///
/// 为什么需要它（而不是沿用 `GatedPrivateAudioTransport` 的 `waitUntilReleased`）：
/// 那只桩的挂起点**不尊重 Swift 任务取消**，于是「上层取消有没有真的终止下载」在它身上
/// 读不出来 —— 而那正是 MAJ-1 的判据。真实 `URLSession.bytes` 流的形态是「以错误结束」，
/// 所以这里的取消会唤醒等待者并抛出 `cancelError`。
///
/// `settle` 保证 continuation 恰好恢复一次（后到的一方无操作），因此不需要任何让步或睡眠
/// 就能把「谁先到」变成确定性的事实（D16⑤）。
final class TransferWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    let cancelError: Error

    init(cancelError: Error) {
        self.cancelError = cancelError
    }

    /// 决出这一路（首次生效）。返回是否真的由本次调用决出。
    @discardableResult
    func settle(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        let first = outcome == nil
        if first { outcome = result }
        lock.unlock()
        guard first, let pending else { return false }
        pending.resume(with: result)
        return true
    }

    /// 已被决出（用于登记前的粘性判定，避免「放行发生在登记之前」时漏掉结论）。
    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome != nil
    }

    /// 挂起等待；任务被取消时以 `cancelError` 收尾（`onTerminate` 只在本次取消真的决出了
    /// 这一路时触发一次 —— 它就是测试读取「传输终止了」的那个信号）。
    /// `honorsCancellation == false` 时**完全不理会取消**：只能由 `release()` 放行，
    /// 用来造出「不合作的出口」这一最坏形态（准备器提交前的取消复核是唯一防线）。
    func waitCancelling(onTerminate: @Sendable () -> Void, honorsCancellation: Bool = true) async throws {
        if honorsCancellation, Task.isCancelled {
            if settle(.failure(cancelError)) { onTerminate() }
            throw cancelError
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            guard honorsCancellation else { return }
            if self.settle(.failure(self.cancelError)) { onTerminate() }
        }
    }
}

/// **取消可观测**的落盘传输桩（MAJ-1 / MAJ-3 / MAJ-4 的触发面）。
///
/// 与真实出口同形的三件事：
/// 1. 在途挂起点尊重 Swift 任务取消（上层取消 → 这一路终止，不交付回执）；
/// 2. `cancelInFlightTransfers()` 作废**当前在途**而不打死出口（之后的请求照常服务）；
/// 3. 作废/取消抛上来的默认是**裸** `NSURLErrorDomain/-999`（真实形态），
///    于是「归一为取消、不计入失败连击」（MAJ-4）这条判据必须经过生产代码而不是桩自己。
///
/// `release()` 是粘性的：已放行之后的新调用直接通过，保证「实现走偏」时测试变红而不是挂死。
actor CancellablePrivateAudioTransport: PrivateAudioTransport {
    /// 已进入传输的次数。
    let enteredSignal = SignalCounter()
    /// 以「取消」形态终止的传输数（MAJ-1 / MAJ-3 的可观测面）。
    let terminatedSignal = SignalCounter()
    /// `cancelInFlightTransfers()` 被调用的次数（MAJ-3：清理前作废在途是义务）。
    let cancelledSignal = SignalCounter()

    private(set) var destinations: [URL] = []
    private(set) var hosts: [String?] = []
    private(set) var sentAuthorizations: [Bool] = []
    private(set) var completedCount = 0
    private(set) var cancellationRequests = 0

    private var pending: [TransferWaiter] = []
    private var released = false
    var bytesToWrite = 24
    /// true = 抛裸 `NSURLError(-999)`（真实形态，判 MAJ-4 的归一腿）；
    /// false = 抛已经归一过的 `PlayerError.cancelled`。
    var throwsRawCancellationError = true
    /// false = **完全不理会任务取消**的不合作出口（真实世界里对应「字节已在缓冲、
    /// 取消要到下一块才被看到」这一窗口）。此时唯一还站得住的防线就是准备器提交前的
    /// 那次取消复核 —— MAJ-1 的「不投递结果」腿只有用它才杀得掉。
    var honorsTaskCancellation = true
    /// 落盘字节（`release()` 路径才写盘：被取消的一路一个字节都不该交付）。
    var marker: UInt8 = 0x6c

    var callCount: Int { destinations.count }
    var inFlightCount: Int { pending.count }

    /// 设定「合作 / 不合作」（actor 隔离属性，测试经方法改）。
    func configureHonoringCancellation(_ honoring: Bool) {
        honorsTaskCancellation = honoring
    }

    func writeAudio(
        from url: URL,
        authorization: SecretString?,
        to fileURL: URL,
        expectedBytes: Int?
    ) async throws -> PrivateAudioReceipt {
        destinations.append(fileURL)
        hosts.append(url.host)
        sentAuthorizations.append(authorization != nil)
        enteredSignal.bump()
        let waiter = TransferWaiter(cancelError: cancellationError())
        if released {
            waiter.settle(.success(()))
        } else {
            pending.append(waiter)
        }
        let honoring = honorsTaskCancellation
        do {
            try await waiter.waitCancelling(
                onTerminate: { [terminatedSignal] in terminatedSignal.bump() },
                honorsCancellation: honoring
            )
        } catch {
            pending.removeAll { $0 === waiter }
            throw error
        }
        pending.removeAll { $0 === waiter }
        guard honoring == false || Task.isCancelled == false else {
            // 放行与取消撞上同一瞬间：取消优先（已作废的传输不得投递结果，D16②）。
            throw cancellationError()
        }
        completedCount += 1
        FileManager.default.createFile(atPath: fileURL.path, contents: payload())
        return PrivateAudioReceipt(
            bytesWritten: bytesToWrite,
            expectedBytes: bytesToWrite,
            statusCode: 200
        )
    }

    func payload() -> Data { Data(repeating: marker, count: max(0, bytesToWrite)) }

    /// 真实出口在会话被作废后交上来的就是这一条裸错误（MAJ-4 的机理起点）。
    private func cancellationError() -> Error {
        throwsRawCancellationError
            ? NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            : PlayerError.cancelled
    }

    /// 作废**当前在途**（MAJ-3）：协议默认空实现已删除，桩必须显式实现；
    /// 出口本身继续可用（之后的新调用照常服务）。
    func cancelInFlightTransfers() async {
        cancellationRequests += 1
        cancelledSignal.bump()
        let dying = pending
        pending = []
        for waiter in dying where waiter.settle(.failure(waiter.cancelError)) {
            terminatedSignal.bump()
        }
    }

    /// 放行全部在途（粘性）。
    func release() {
        released = true
        let waiting = pending
        pending = []
        for waiter in waiting { waiter.settle(.success(())) }
    }
}
