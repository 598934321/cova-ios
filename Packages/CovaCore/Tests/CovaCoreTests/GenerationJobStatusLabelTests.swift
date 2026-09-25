import CovaCore
import XCTest

/// 「英文态名不得外溢」判据在**生成任务 6 态**上的落点（与 `LoopModeLabelTests`、
/// `testEveryFailureKindSurfacesChineseLabelAndNeverTheEnumName` 同族同形）。
///
/// 这一处的漏点是活的：09 的对账那句 `append(.system("已核到任务：\(newest.status.rawValue)"))`
/// 会把 `succeeded` / `processing` 直接印上屏（`AISessionDetailView.swift:474`）。
/// 本文件钉的是"标签挂在它所属的那一层，且每一档都有"；那句上屏串的改法由协调器落。
final class GenerationJobStatusLabelTests: XCTestCase {
    func testEveryGenerationJobStatusSurfacesChineseLabelNeverTheEnumName() {
        for status in GenerationJobStatus.allCases {
            XCTAssertFalse(status.userLabel.isEmpty, "\(status) 没有中文标签")
            XCTAssertNotEqual(status.userLabel, status.rawValue)
            XCTAssertFalse(
                status.userLabel.contains(status.rawValue),
                "\(status) 的上屏串露出了 wire 值：\(status.userLabel)"
            )
            XCTAssertFalse(
                status.userLabel.rangeOfCharacter(
                    from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
                ) != nil,
                "\(status) 的上屏串里不该有拉丁字母：\(status.userLabel)"
            )
        }
        // 六态逐字钉住（加一档必须同时加中文；`allCases` 的数目也一并钉）。
        XCTAssertEqual(GenerationJobStatus.allCases.count, 6)
        XCTAssertEqual(GenerationJobStatus.queued.userLabel, "排队中")
        XCTAssertEqual(GenerationJobStatus.submitted.userLabel, "已提交，正在排产")
        XCTAssertEqual(GenerationJobStatus.processing.userLabel, "制作中")
        XCTAssertEqual(GenerationJobStatus.succeeded.userLabel, "已完成")
        XCTAssertEqual(GenerationJobStatus.failed.userLabel, "没能完成")
        XCTAssertEqual(GenerationJobStatus.cancelled.userLabel, "本轮已停止")
    }

    /// 同一句话不许出现在两档上（"排队中"和"制作中"在屏上必须分得开）。
    func testLabelsAreAllDistinct() {
        let labels = GenerationJobStatus.allCases.map(\.userLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    /// 取消那句不许自己另造一份：09 §3-I 已有的固定文案就是唯一来源。
    func testStoppedLabelReusesTheExistingFixedCopy() {
        XCTAssertEqual(
            GenerationJobStatus.cancelled.userLabel, DeliveryProgressPlanner.stoppedLabel,
            "「本轮已停止」是 spec 逐字钉的固定串，不得在别处再长一张表"
        )
    }

    /// `rawValue` 是后端词表与线格式：中文标签只换显示面，wire 一个字节都不能动。
    func testCodableWireValueUnchangedByChineseLabels() throws {
        for status in GenerationJobStatus.allCases {
            let data = try JSONEncoder().encode(status)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(status.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(GenerationJobStatus.self, from: data), status)
        }
        XCTAssertEqual(
            Set(GenerationJobStatus.allCases.map(\.rawValue)),
            ["queued", "submitted", "processing", "succeeded", "failed", "cancelled"]
        )
        for raw in ["queued", "submitted", "processing", "succeeded", "failed", "cancelled"] {
            XCTAssertNotNil(
                try? JSONDecoder().decode(GenerationJobStatus.self, from: Data("\"\(raw)\"".utf8)),
                "后端词表里的 \(raw) 必须继续解得开"
            )
        }
    }
}
