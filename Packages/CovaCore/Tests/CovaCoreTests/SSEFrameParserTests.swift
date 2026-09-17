import CovaCore
import Foundation
import XCTest

final class SSEFrameParserTests: XCTestCase {
    private func parse(_ text: String) -> (frames: [CovaSSEFrame], parser: SSEFrameParser) {
        var parser = SSEFrameParser()
        let frames = parser.consume(Array(text.utf8))
        return (frames, parser)
    }

    func testParsesSingleEvent() {
        let (frames, parser) = parse("event: text\ndata: {\"text\":\"hi\"}\n\n")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .text)
        XCTAssertFalse(frames[0].isMalformed)
        XCTAssertEqual(frames[0].decodePayload(CovaSSETextEventDto.self)?.text, "hi")
        XCTAssertEqual(parser.malformedEventCount, 0)
    }

    func testContractNamedAndRunLifecycleEvents() {
        let text = """
        event: thinking\ndata: {\"text\":\"a\"}\n\n\
        event: plan_card\ndata: {\"planCardId\":\"p\",\"status\":\"ready\"}\n\n\
        event: run_started\ndata: {\"runId\":\"r\"}\n\n\
        event: questionnaire\ndata: {\"id\":\"q\"}\n\n
        """
        let (frames, _) = parse(text)
        XCTAssertEqual(frames.map(\.event), [.thinking, .planCard, .runLifecycle("run_started"), .unknown("questionnaire")])
    }

    func testMultiLineDataIsJoinedWithNewline() {
        let (frames, _) = parse("event: text\ndata: {\"text\":\ndata: \"hi\"}\n\n")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(String(decoding: frames[0].payload, as: UTF8.self), "{\"text\":\n\"hi\"}")
        XCTAssertEqual(frames[0].decodePayload(CovaSSETextEventDto.self)?.text, "hi")
    }

    func testLFCRLFAndCRLineTerminators() {
        for terminator in ["\n", "\r\n", "\r"] {
            let text = "event: done\(terminator)data: {}\(terminator)\(terminator)"
            var parser = SSEFrameParser()
            let frames = parser.consume(Array(text.utf8))
            XCTAssertEqual(frames.count, 1, "terminator=\(terminator.debugDescription)")
            XCTAssertEqual(frames[0].event, .done, "terminator=\(terminator.debugDescription)")
        }
    }

    func testCRLFSplitAcrossChunksIsOneTerminator() {
        var parser = SSEFrameParser()
        XCTAssertTrue(parser.consume(Array("event: done\r".utf8)).isEmpty)
        let frames = parser.consume(Array("\ndata: {}\r\n\r\n".utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .done)
    }

    func testCommentsAndKeepAlivesAreIgnored() {
        let (frames, parser) = parse(": keep-alive\n\nevent: done\ndata: {}\n\n")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .done)
        XCTAssertEqual(parser.malformedEventCount, 0)
    }

    func testIncompleteEventAtEOFIsDiscardedAndCountedMalformed() {
        var parser = SSEFrameParser()
        XCTAssertTrue(parser.consume(Array("event: done\ndata: {}\n".utf8)).isEmpty)
        XCTAssertTrue(parser.finish().isEmpty)
        XCTAssertEqual(parser.malformedEventCount, 1)
    }

    func testFinishFlushesTrailingLineWithoutTerminator() {
        var parser = SSEFrameParser()
        XCTAssertTrue(parser.consume(Array("event: done\ndata: {}".utf8)).isEmpty)
        // 末尾行无换行：EOF 视为行终止，但无空行分帧 → 残帧不派发。
        XCTAssertTrue(parser.finish().isEmpty)
        XCTAssertEqual(parser.malformedEventCount, 1)
    }

    func testIDAndRetryFieldsIgnored() {
        let (frames, _) = parse("id: 42\nretry: 1000\nevent: text\ndata: {\"text\":\"x\"}\n\n")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .text)
    }

    func testUnnamedEventSurfacesAsUnknown() {
        let (frames, _) = parse("data: {}\n\n")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .unknown(""))
    }

    func testMalformedPayloadIsFlaggedAndCounted() {
        let (frames, parser) = parse("event: text\ndata: not-json\n\n")
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].isMalformed)
        XCTAssertEqual(parser.malformedEventCount, 1)
    }

    func testBOMAtStreamStartIsStripped() {
        var parser = SSEFrameParser()
        let bytes = Array("\u{FEFF}event: done\ndata: {}\n\n".utf8)
        XCTAssertEqual(bytes.prefix(3), [0xEF, 0xBB, 0xBF])
        let frames = parser.consume(bytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .done)
        XCTAssertEqual(parser.malformedEventCount, 0)
    }

    func testBOMSplitAcrossChunksIsStripped() {
        var parser = SSEFrameParser()
        XCTAssertTrue(parser.consume([0xEF]).isEmpty)
        XCTAssertTrue(parser.consume([0xBB]).isEmpty)
        let frames = parser.consume(Array([0xBF] + Array("event: done\ndata: {}\n\n".utf8)))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .done)
    }

    func testNonBOMLeadingBytesArePreserved() {
        var parser = SSEFrameParser()
        XCTAssertTrue(parser.consume([0xEF, 0xBB, 0x41]).isEmpty)
        let frames = parser.consume(Array(": comment\nevent: done\ndata: {}\n\n".utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .done)
    }

    func testArbitraryChunkBoundariesProduceIdenticalFrames() {
        let text = """
        event: thinking\ndata: {\"text\":\"分析中\"}\n\n\
        : keep-alive\n\n\
        event: plan_card\ndata: {\"planCardId\":\"p1\",\"status\":\"ready\"}\n\n\
        event: done\ndata: {}\n\n
        """
        let bytes = Array(text.utf8)
        var reference = SSEFrameParser()
        let expected = reference.consume(bytes)
        // thinking + plan_card + done 三条；注释行不派发。
        XCTAssertEqual(expected.count, 3)

        for split in 0...bytes.count {
            var parser = SSEFrameParser()
            var frames = parser.consume(bytes[0..<split])
            frames += parser.consume(bytes[split...])
            XCTAssertEqual(frames, expected, "切分点 \(split)")
            XCTAssertEqual(parser.malformedEventCount, 0, "切分点 \(split)")
        }
    }

    func testByteByByteFeeding() {
        let text = "event: text\ndata: {\"text\":\"逐字节\"}\n\nevent: done\ndata: {}\n\n"
        var parser = SSEFrameParser()
        var frames: [CovaSSEFrame] = []
        for byte in text.utf8 {
            frames += parser.consume([byte])
        }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].decodePayload(CovaSSETextEventDto.self)?.text, "逐字节")
        XCTAssertEqual(frames[1].event, .done)
    }

    func testMultibyteUTF8SplitAcrossChunks() {
        let text = "event: text\ndata: {\"text\":\"你好世界\"}\n\n"
        var bytes = Array(text.utf8)
        // 在中文字节中间找一个切分点。
        let needle = Array("你".utf8)
        let index = bytes.firstRange(of: needle)!.lowerBound + 1
        var parser = SSEFrameParser()
        let first = parser.consume(bytes[0..<index])
        bytes.removeFirst(index)
        let second = parser.consume(bytes)
        XCTAssertEqual(first.count + second.count, 1)
        let frame = (first + second)[0]
        XCTAssertEqual(frame.decodePayload(CovaSSETextEventDto.self)?.text, "你好世界")
    }

    func testVeryLongLineIsParsed() {
        let body = String(repeating: "x", count: 200_000)
        var parser = SSEFrameParser()
        let frames = parser.consume(Array("event: text\ndata: {\"text\":\"\(body)\"}\n\n".utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].decodePayload(CovaSSETextEventDto.self)?.text, body)
    }

    func testOverlongLineCountedAsSingleMalformedEventAndStreamContinues() {
        var parser = SSEFrameParser()
        let long = String(repeating: "x", count: SSEFrameParser.maxLineBytes + 100)
        let frames = parser.consume(Array("data: \(long)\n\nevent: done\ndata: {}\n\n".utf8))
        // 超限行 → 该事件作废（计 1 个坏事件）；随后的正常事件照常解析。
        XCTAssertEqual(parser.malformedEventCount, 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, .done)
        XCTAssertEqual(parser.discardedIncompleteEventCount, 0)
    }

    func testOverlongEventDataCountedOnceAndNotDispatched() {
        var parser = SSEFrameParser()
        let segment = String(repeating: "y", count: 1 << 19)
        var text = "data: "
        for _ in 0..<17 { text += segment + "\ndata: " }
        text += "\n\n"
        let frames = parser.consume(Array(text.utf8))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(parser.malformedEventCount, 1)
    }

    func testDiscardedIncompleteEventCountedAtEOF() {
        var parser = SSEFrameParser()
        _ = parser.consume(Array("event: text\ndata: {\"text\":\"x\"}".utf8))
        XCTAssertTrue(parser.finish().isEmpty)
        XCTAssertEqual(parser.malformedEventCount, 1)
        XCTAssertEqual(parser.discardedIncompleteEventCount, 1)
    }

    func testMultipleEventsInOneChunk() {
        let (frames, _) = parse("event: text\ndata: {\"text\":\"1\"}\n\nevent: text\ndata: {\"text\":\"2\"}\n\n")
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].decodePayload(CovaSSETextEventDto.self)?.text, "1")
        XCTAssertEqual(frames[1].decodePayload(CovaSSETextEventDto.self)?.text, "2")
    }
}

private extension Array where Element: Equatable {
    func firstRange(of pattern: [Element]) -> Range<Int>? {
        guard !pattern.isEmpty, pattern.count <= count else { return nil }
        for start in 0...(count - pattern.count) {
            if Array(self[start..<(start + pattern.count)]) == pattern {
                return start..<(start + pattern.count)
            }
        }
        return nil
    }
}
