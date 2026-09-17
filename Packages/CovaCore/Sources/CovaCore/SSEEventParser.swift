import Foundation

/// SSE 增量解析器（纯逻辑，逐字节/逐块喂入）。
///
/// 支持面（api-contracts §4 的 `text/event-stream`）：
/// - 字段：`event:` / `data:` / `id:` / `retry:`；`:` 开头为注释行（丢弃）；未知字段忽略；
/// - 空行分帧；多行 `data:` 以 `\n` 拼接；
/// - 行终止符 CR / LF / CRLF（含 CRLF 被块边界切断的情形）；
/// - 任意切分点（含多字节 UTF-8 被切断——按字节缓冲整行后才解码）；
/// - 流首 BOM（`EF BB BF`，可被块边界切断）剥离。
///
/// **坏事件计数**：帧载荷不是合法 JSON 时标记 `isMalformed` 并累加
/// `malformedEventCount`（D6「3 个坏事件」降级的依据）。事件名未知/`run_*` 不算坏事件
/// （前向兼容，见 `CovaSSEEventType`）。EOF 处未以空行收尾的残帧不派发，计一个坏事件。
///
/// 本类型不抛错、不阻塞、不做 I/O；线程语义由调用方（actor）保证。
public struct SSEFrameParser: Sendable {
    /// 单行字节上限（1 MiB，fail-closed）。
    ///
    /// 超过即丢弃该行并把当前事件计为一个坏事件；防止恶意/异常服务端用无换行的超长行
    /// 导致内存无上限增长。契约中的计划卡/歌词 JSON 远小于此值。
    public static let maxLineBytes = 1 << 20
    /// 单事件 `data:` 累计字节上限（8 MiB，fail-closed）。
    public static let maxEventDataBytes = 8 << 20

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// 流首 BOM 判别中尚未定论的字节。
    private var bomCandidate: [UInt8] = []
    private var inspectingBOM = true

    /// 当前行累积的字节（未遇到行终止符前）。
    private var lineBuffer: [UInt8] = []
    /// 当前行因超限被截断（剩余字节丢弃，行结束时计一个坏事件）。
    private var lineTruncated = false
    /// 上一个字节是 CR：紧随的 LF 视作同一行终止符。
    private var pendingLineFeed = false

    /// 当前帧累积的事件名与数据行。
    private var eventName = ""
    private var dataLines: [String] = []
    private var pendingDataBytes = 0
    /// 当前事件已计坏事件，忽略其余字段直到空行。
    private var suppressCurrentEvent = false

    /// 格式错误（载荷非法 JSON / 超限 / EOF 残帧）事件累计数。
    public private(set) var malformedEventCount = 0
    /// EOF 处被丢弃的残帧数（已计入 `malformedEventCount`；供协调器统一口径，m1）。
    public private(set) var discardedIncompleteEventCount = 0

    public init() {}

    /// 喂入一段字节，返回本次可派发的完整帧（可能 0..n 个）。
    public mutating func consume<Bytes: Sequence>(_ bytes: Bytes) -> [CovaSSEFrame]
    where Bytes.Element == UInt8 {
        var frames: [CovaSSEFrame] = []
        for byte in bytes {
            feed(byte, into: &frames)
        }
        return frames
    }

    /// 流正常结束（EOF）：冲刷末尾无终止符的行；未收尾的残帧不派发并计坏事件。
    public mutating func finish() -> [CovaSSEFrame] {
        var frames: [CovaSSEFrame] = []
        if inspectingBOM, !bomCandidate.isEmpty {
            let pending = bomCandidate
            bomCandidate.removeAll()
            inspectingBOM = false
            for byte in pending { feedLineByte(byte, into: &frames) }
        }
        if lineTruncated {
            lineTruncated = false
            lineBuffer.removeAll(keepingCapacity: true)
            markCurrentEventMalformed()
        } else if !lineBuffer.isEmpty {
            finishLine(into: &frames)
        }
        if !dataLines.isEmpty {
            malformedEventCount += 1
            discardedIncompleteEventCount += 1
        }
        resetEvent()
        pendingLineFeed = false
        return frames
    }

    // MARK: - 内部

    private mutating func feed(_ byte: UInt8, into frames: inout [CovaSSEFrame]) {
        if inspectingBOM {
            bomCandidate.append(byte)
            let index = bomCandidate.count - 1
            if bomCandidate[index] != Self.bom[index] {
                let pending = bomCandidate
                bomCandidate.removeAll(keepingCapacity: true)
                inspectingBOM = false
                for pendingByte in pending { feedLineByte(pendingByte, into: &frames) }
                return
            }
            if bomCandidate.count == Self.bom.count {
                bomCandidate.removeAll(keepingCapacity: true)
                inspectingBOM = false
            }
            return
        }
        feedLineByte(byte, into: &frames)
    }

    private mutating func feedLineByte(_ byte: UInt8, into frames: inout [CovaSSEFrame]) {
        if pendingLineFeed {
            pendingLineFeed = false
            if byte == 0x0A { return }
        }
        switch byte {
        case 0x0D: // CR
            finishLine(into: &frames)
            pendingLineFeed = true
        case 0x0A: // LF
            finishLine(into: &frames)
        default:
            if lineBuffer.count >= Self.maxLineBytes {
                lineTruncated = true
            } else {
                lineBuffer.append(byte)
            }
        }
    }

    private mutating func finishLine(into frames: inout [CovaSSEFrame]) {
        if lineTruncated {
            lineTruncated = false
            lineBuffer.removeAll(keepingCapacity: true)
            markCurrentEventMalformed()
            suppressCurrentEvent = true
            return
        }
        // 整行字节齐备后才解码：多字节 UTF-8 不会跨行（行终止符均为 ASCII）。
        let line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)
        process(line: line, into: &frames)
    }

    private mutating func process(line: String, into frames: inout [CovaSSEFrame]) {
        if suppressCurrentEvent {
            if line.isEmpty { suppressCurrentEvent = false }
            return
        }
        if line.isEmpty {
            dispatch(into: &frames)
            return
        }
        if line.hasPrefix(":") { return }
        let (field, value) = Self.splitField(line)
        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
            pendingDataBytes += value.utf8.count
            if pendingDataBytes > Self.maxEventDataBytes {
                markCurrentEventMalformed()
                suppressCurrentEvent = true
            }
        case "id", "retry":
            break
        default:
            break
        }
    }

    /// 当前事件作废并计一个坏事件（超限/损坏路径）。
    private mutating func markCurrentEventMalformed() {
        malformedEventCount += 1
        eventName = ""
        dataLines.removeAll(keepingCapacity: true)
        pendingDataBytes = 0
    }

    private mutating func resetEvent() {
        eventName = ""
        dataLines.removeAll(keepingCapacity: true)
        pendingDataBytes = 0
        suppressCurrentEvent = false
    }

    /// `field: value` → (field, value)；行内无冒号时 value 为空串；
    /// value 仅去掉**一个**前导空格（SSE 规范）。
    static func splitField(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }

    private mutating func dispatch(into frames: inout [CovaSSEFrame]) {
        if suppressCurrentEvent {
            suppressCurrentEvent = false
            resetEvent()
            return
        }
        guard !dataLines.isEmpty else {
            resetEvent()
            return
        }
        let name = eventName
        let payload = Data(dataLines.joined(separator: "\n").utf8)
        let malformed = !Self.isValidJSONPayload(payload)
        if malformed { malformedEventCount += 1 }
        resetEvent()
        frames.append(
            CovaSSEFrame(rawEventName: name, payload: payload, isMalformed: malformed)
        )
    }

    /// 载荷是否为合法 JSON（契约中 `data:` 恒为 JSON；顶层标量亦接受）。
    static func isValidJSONPayload(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }
}
