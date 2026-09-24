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
///
/// TD-23：`audioUrl` / `audioDownloadUrl` 可能为授权/签名地址，收口为 `SecretString?`
/// （描述/反射面恒 `<redacted>`）；本类型与 `GenerationJobMetadataDto` 降为仅 `Decodable`，
/// 编译期禁止把敏感音频地址重新序列化进持久化索引。
public struct GenerationCandidateDto: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let audioUrl: SecretString?
    public let coverUrl: String?
    public let duration: Double?
    public let audioDownloadUrl: SecretString?
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

/// 生成任务 `metadata` JSON 字符串的结构化视图（仅 `Decodable`，见 `GenerationCandidateDto`）。
public struct GenerationJobMetadataDto: Decodable, Equatable, Sendable {
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

/// 生成任务的响应封套。同一个类型服务两个端点：
/// · `GET /api/find-my-song/generation-jobs?id=` → 真实响应 `{job}`；
/// · `POST /api/studio/one-step/plans/start` → **真实响应 `{result, summary}`，任务号在
///   `result.jobId`**（2026-09-24 真实账号实测；web 同样读 `payload.result.jobId`，见
///   `web/…/agent-v2/useAgentV2Session.ts:127-128`），而契约文档写的是 `{job:…}`。
///
/// 为什么这处形态差异必须"容忍"而不是"报错"：**扣费发生在 HTTP 2xx 那一刻**。
/// 旧实现要求 `{job}`，解不出就抛 ⇒ UI 说「这次没提交成功」⇒ 用户再点一次 ⇒
/// 换一个新的幂等键 ⇒ **第二次扣费**。所以解码永不因形态失败，
/// 拿不到任务号时降级成一个可区分的状态（`isUnresolvedSubmission`），
/// 由调用方去核对权威任务列表，而不是断言"没提交"。
public struct GenerationJobResponseDto: Decodable, Equatable, Sendable {
    public let job: GenerationJobDto?
    /// 只拿到任务号的情形（start 的真实响应就是这种）。
    public let jobId: String?

    public var resolvedJobId: String? {
        if let id = job?.id, !id.isEmpty { return id }
        if let jobId, !jobId.isEmpty { return jobId }
        return nil
    }

    /// 2xx 却没有任何任务号 ⇒ 提交可能已经发生，**绝不能说"没提交成功"**。
    public var isUnresolvedSubmission: Bool { resolvedJobId == nil }

    private enum RootKeys: String, CodingKey {
        case job
        case jobs
        case result
        case jobId
        case id
    }

    /// 容忍的是**封套形态**（哪一层包着任务），不容忍的是**任务本身缺必要字段**：
    /// 只要 `job` / `jobs` 键出现了，就严格解码 —— 缺 `status` 必须照旧抛错
    /// （`testMissingJobStatusFailsDecoding` 钉的就是这条，状态驱动整个交付 UI）。
    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        if root.contains(RootKeys.job) {
            let full = try root.decode(GenerationJobDto.self, forKey: .job)
            job = full
            jobId = full.id
            return
        }
        if root.contains(RootKeys.jobs) {
            let many = try root.decode([GenerationJobDto].self, forKey: .jobs)
            job = many.first
            jobId = many.first?.id
            return
        }
        if root.contains(RootKeys.result) {
            if let nested = try? root.nestedContainer(keyedBy: RootKeys.self, forKey: .result) {
                if nested.contains(RootKeys.job) {
                    let full = try nested.decode(GenerationJobDto.self, forKey: .job)
                    job = full
                    jobId = full.id
                    return
                }
                if nested.contains(RootKeys.jobs) {
                    let many = try nested.decode([GenerationJobDto].self, forKey: .jobs)
                    job = many.first
                    jobId = many.first?.id
                    return
                }
                job = nil
                jobId = ((try? nested.decodeIfPresent(String.self, forKey: .jobId)) ?? nil)
                    ?? ((try? nested.decodeIfPresent(String.self, forKey: .id)) ?? nil)
                return
            }
            // result 直接是任务号字符串
            job = nil
            jobId = try root.decode(String.self, forKey: .result)
            return
        }
        job = nil
        jobId = ((try? root.decodeIfPresent(String.self, forKey: .jobId)) ?? nil)
            ?? ((try? root.decodeIfPresent(String.self, forKey: .id)) ?? nil)
    }
}

/// `GET /api/find-my-song/generation-jobs` 任务列表响应（真实响应：`{jobs}`）。
public struct GenerationJobsResponseDto: Codable, Equatable, Sendable {
    public let jobs: [GenerationJobDto]

    enum CodingKeys: String, CodingKey {
        case jobs
    }
}
