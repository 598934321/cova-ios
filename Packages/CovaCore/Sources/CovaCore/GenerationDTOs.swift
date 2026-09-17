import Foundation

/// 生成任务 6 态（逐字对齐后端 `generationJobStatus`）。
public enum GenerationJobStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case submitted
    case processing
    case succeeded
    case failed
    case cancelled
}

/// 候选音频下载状态（D7「settled」判定 = `ready` 且有 URL，或 `failed`）。
public enum GenerationCandidateDownloadStatus: String, Codable, Equatable, Sendable {
    case pending
    case ready
    case failed
}

/// 生成候选（api-contracts 4：`GenerationCandidate`）。
public struct GenerationCandidateDto: Codable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let audioUrl: String?
    public let coverUrl: String?
    public let duration: Double?
    public let audioDownloadUrl: String?
    public let audioDownloadStatus: GenerationCandidateDownloadStatus?
    public let mediaReferenceId: String?
    public let favorite: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case audioUrl
        case coverUrl
        case duration
        case audioDownloadUrl
        case audioDownloadStatus
        case mediaReferenceId
        case favorite
    }
}

/// 生成任务 `metadata` JSON 字符串的结构化视图。
public struct GenerationJobMetadataDto: Codable, Equatable, Sendable {
    public let candidates: [GenerationCandidateDto]?
    public let makeInstrumental: Bool?

    enum CodingKeys: String, CodingKey {
        case candidates
        case makeInstrumental
    }
}

/// 生成任务（api-contracts 4：`GenerationJob`）。
///
/// `metadata` 在真实响应里是 **JSON 字符串**（非嵌套对象），故原样保留为 `String`，
/// 需要时用 `decodedMetadata()` / `candidates()` 取结构化视图。
public struct GenerationJobDto: Codable, Equatable, Sendable {
    public let id: String
    public let status: GenerationJobStatus

    public let sessionId: String?
    public let costCredits: Int?
    public let metadata: String?
    public let idempotencyKey: String?
    public let errorMessage: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case sessionId
        case costCredits
        case metadata
        case idempotencyKey
        case errorMessage
        case createdAt
        case updatedAt
        case completedAt
    }

    /// `metadata` → 结构化视图；缺失或非法 JSON 返回 `nil`（不抛出、不影响主解码）。
    public func decodedMetadata() -> GenerationJobMetadataDto? {
        guard let metadata, let data = metadata.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GenerationJobMetadataDto.self, from: data)
    }

    /// 便利访问：候选列表（缺失时为空数组）。
    public func candidates() -> [GenerationCandidateDto] {
        decodedMetadata()?.candidates ?? []
    }
}

/// `GET /api/find-my-song/generation-jobs?id=` 单任务响应（真实响应：`{job}`）。
public struct GenerationJobResponseDto: Codable, Equatable, Sendable {
    public let job: GenerationJobDto

    enum CodingKeys: String, CodingKey {
        case job
    }
}

/// `GET /api/find-my-song/generation-jobs` 任务列表响应（真实响应：`{jobs}`）。
public struct GenerationJobsResponseDto: Codable, Equatable, Sendable {
    public let jobs: [GenerationJobDto]

    enum CodingKeys: String, CodingKey {
        case jobs
    }
}
