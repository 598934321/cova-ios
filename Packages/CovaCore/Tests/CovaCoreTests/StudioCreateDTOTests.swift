@testable import CovaCore
import Foundation
import XCTest

/// studio/create 提交与作品行的契约面（DEVELOPMENT.md A3/A4/A11/A15）。
///
/// 三组判据，每组都对应一个**已经踩过的坑**：
/// · 响应形状：`charge` 是**数字**不是对象；`ok:true` 而缺 `jobId` 时不许说「没提交成功」
///   （扣费发生在 2xx 那一刻，与 `GenerationJobResponseDto.isUnresolvedSubmission` 同源）；
/// · 错误话术：400 透传服务端中文原文、402 按 `required` 组装，**屏上不许出现英文码**（A15）；
/// · 幂等：一次点击一把新键、键恒在服务端字符集内、同一次提交的重试复用同一把（A11）。
final class StudioCreateDTOTests: XCTestCase {

    // MARK: - 提交响应

    func testGenerateResponseDecodesChargeAsANumber() throws {
        let response = try Fixture.decode(
            StudioCreateGenerateResponseDto.self, "studio-create-generate-response"
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.jobId, "job-test-0001")
        XCTAssertEqual(response.charge, 20, "charge 是数字（generate.ts:526-530），不是对象")
        XCTAssertFalse(response.isUnresolvedSubmission)
    }

    /// 钱路纪律：2xx 却拿不到任务号 ⇒ **绝不能说「没提交成功」**（用户会再点一次 ⇒ 二次扣费）。
    func testOkWithoutJobIdIsAnUnresolvedSubmissionNotAFailure() throws {
        let response = try JSONDecoder().decode(
            StudioCreateGenerateResponseDto.self, from: Data(#"{"ok":true}"#.utf8)
        )
        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.jobId)
        XCTAssertTrue(response.isUnresolvedSubmission)

        let emptyJobId = try JSONDecoder().decode(
            StudioCreateGenerateResponseDto.self,
            from: Data(#"{"ok":true,"jobId":"","charge":20}"#.utf8)
        )
        XCTAssertTrue(emptyJobId.isUnresolvedSubmission, "空串任务号同样等于没拿到")
    }

    /// 开发环境 `COVA_SUNO_AGENT_ENABLED` 关时 `charge` 恒 0 ⇒ **0 不等于免费**，
    /// 客户端无从判别，所以只把数字原样交出去（渲染判据在 UI 层：>0 才印）。
    func testZeroChargeIsCarriedAsFactNotReadAsFree() throws {
        let response = try JSONDecoder().decode(
            StudioCreateGenerateResponseDto.self,
            from: Data(#"{"ok":true,"jobId":"job-1","charge":0}"#.utf8)
        )
        XCTAssertEqual(response.charge, 0)
    }

    // MARK: - 提交请求

    private func token(
        _ operation: IdempotentOperation = .studioCreateGenerate,
        hex: String = String(repeating: "0", count: 32)
    ) throws -> IdempotentRequestToken {
        try IdempotentRequestToken(
            operation: operation, key: IdempotencyKey(validating: operation.keyPrefix + hex)
        )
    }

    func testRequestEncodesExactlyTheContractKeys() throws {
        let request = try StudioCreateGenerateRequestDto(
            prompt: "夏夜城市里的合成器流行，女声，中速", token: token()
        )
        XCTAssertEqual(request.mode, .simple, "P0 只施工 simple")
        XCTAssertEqual(request.operation, .create)
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request), fixture: "requests/studio-create-generate-request"
        )
    }

    func testEmptyAndWhitespaceOnlyPromptNeverReachesTheNetwork() throws {
        for bad in ["", "   ", "\n\t ", " \u{00a0} "] {
            XCTAssertThrowsError(
                try StudioCreateGenerateRequestDto(prompt: bad, token: token()),
                "空描述必须本地就拦下，不该拿一次 400 往返去换"
            ) { error in
                XCTAssertEqual(error as? StudioCreateRequestError, .emptyPrompt)
            }
        }
    }

    func testOverlongPromptIsRejectedLocallyWithBothNumbers() throws {
        let limit = StudioCreateGenerateRequestDto.promptMaximumLength
        XCTAssertEqual(limit, 2000, "服务端上限（generate.ts:105）")
        let tooLong = String(repeating: "夏", count: limit + 1)
        XCTAssertThrowsError(try StudioCreateGenerateRequestDto(prompt: tooLong, token: token())) { error in
            XCTAssertEqual(
                error as? StudioCreateRequestError,
                .promptTooLong(limit: limit, actual: limit + 1)
            )
        }
        // 恰好等于上限必须放行（边界不是「超过才拒」的近似）。
        XCTAssertNoThrow(
            try StudioCreateGenerateRequestDto(
                prompt: String(repeating: "夏", count: limit), token: token()
            )
        )
    }

    func testPromptIsTrimmedBeforeSending() throws {
        let request = try StudioCreateGenerateRequestDto(prompt: "  夏夜城市  \n", token: token())
        XCTAssertEqual(request.prompt, "夏夜城市")
    }

    /// TD-24 同族：串用别的写操作的键在 init 就抛，而不是发出去让服务端 409。
    func testRequestRejectsATokenFromAnotherOperation() throws {
        XCTAssertThrowsError(
            try StudioCreateGenerateRequestDto(prompt: "夏夜城市", token: token(.playReport))
        ) { error in
            XCTAssertEqual(error as? StudioCreateRequestError, .operationMismatch)
        }
    }

    // MARK: - 幂等（A11）

    func testEachClickMintsAFreshKeyInsideTheServerCharset() throws {
        // 服务端校验正则：^[A-Za-z0-9._:-]{8,128}$（play-history.ts:46）
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        var seen = Set<String>()
        for _ in 0..<32 {
            let minted = IdempotentRequestToken(operation: .studioCreateGenerate)
            let raw = minted.key.rawValue
            XCTAssertFalse(seen.contains(raw), "两次点击不得复用同一把键")
            seen.insert(raw)
            XCTAssertTrue(
                (8...128).contains(raw.utf8.count),
                "长度必须落在服务端窗口内（实际 \(raw.utf8.count)）"
            )
            XCTAssertTrue(
                raw.allSatisfy(allowed.contains),
                "字符集必须是服务端允许集的子集"
            )
            XCTAssertTrue(minted.key.isCanonical(for: .studioCreateGenerate))
        }
        XCTAssertEqual(seen.count, 32)
        XCTAssertEqual(IdempotentOperation.studioCreateGenerate.keyPrefix, "cova-studio-create-generate-")
    }

    /// 「同一次提交的重试复用同键」是**调用方纪律**，本层能保证的是：token 是值类型、
    /// 复用同一个 token 就复用同一把键（不会被偷偷换掉）。
    func testReusingOneTokenKeepsOneKey() throws {
        let once = try token(hex: String(repeating: "a", count: 32))
        let first = try StudioCreateGenerateRequestDto(prompt: "夏夜城市", token: once)
        let retry = try StudioCreateGenerateRequestDto(prompt: "夏夜城市", token: once)
        XCTAssertEqual(first.idempotencyKey, retry.idempotencyKey)
        XCTAssertEqual(first, retry)
        // 线格式比较走**规范形态**（`.sortedKeys`）：`JSONEncoder` 不承诺键序，
        // 直接比原始字节在本机 macOS 上恰好相等、在模拟器上就红（同一份值、142 vs 142 字节）。
        // 断"两次编码字节相同"从来不是本用例的判据 —— 判据是"同键同载荷"。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(decoding: try encoder.encode(first), as: UTF8.self),
            String(decoding: try encoder.encode(retry), as: UTF8.self),
            "同键同载荷 ⇒ 服务端 10 分钟指纹去重也会收敛到同一个 jobId"
        )
    }

    // MARK: - 错误信封与话术（A4 / A15）

    func testCreditsInsufficientEnvelopeCarriesBothNumbers() throws {
        let envelope = try Fixture.decode(
            StudioCreateErrorDto.self, "studio-create-error-credits-insufficient"
        )
        XCTAssertEqual(envelope.error, "credits_insufficient")
        XCTAssertNil(envelope.code, "402 那一档服务端不给 code 键（route.ts:24-30）")
        XCTAssertEqual(envelope.balance, 3)
        XCTAssertEqual(envelope.required, 20)
    }

    func testInvalidRequestEnvelopeCarriesTheChineseMessage() throws {
        let envelope = try Fixture.decode(
            StudioCreateErrorDto.self, "studio-create-error-invalid-request"
        )
        XCTAssertEqual(envelope.error, "请填写音乐描述")
        XCTAssertEqual(envelope.code, "invalid_request")
    }

    func testClassificationMapsStatusCodesOntoContractBuckets() throws {
        let body402 = try Fixture.data("studio-create-error-credits-insufficient")
        let body400 = try Fixture.data("studio-create-error-invalid-request")
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 400, body: body400),
            .invalidRequest(serverMessage: "请填写音乐描述")
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 402, body: body402),
            .creditsInsufficient(balance: 3, required: 20)
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 409, body: nil), .idempotencyConflict
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 429, body: nil), .rateLimited(serverMessage: nil)
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 401, body: nil), .unauthenticated
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 403, body: nil), .unauthenticated
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 500, body: nil),
            .server(statusCode: 500, serverMessage: nil)
        )
    }

    func testUserMessagesAreTheSpecifiedCopies() throws {
        let body402 = try Fixture.data("studio-create-error-credits-insufficient")
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 402, body: body402).userMessage,
            "余额不足，本次需要 20 co"
        )
        // `required` 缺失/为 0 ⇒ 不编数字（宁短不假）。
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 402, body: Data(#"{"error":"credits_insufficient"}"#.utf8)).userMessage,
            "余额不足"
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 402, body: Data(#"{"error":"credits_insufficient","required":0}"#.utf8)).userMessage,
            "余额不足"
        )
        let body400 = try Fixture.data("studio-create-error-invalid-request")
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 400, body: body400).userMessage,
            "请填写音乐描述",
            "400 透传服务端中文原文（A4）"
        )
        // 服务端没给文案 ⇒ 说清「未说明原因」，不糊一个「未知错误」。
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 400, body: nil).userMessage,
            "这次提交没被接受（服务端未说明原因）"
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 502, body: nil).userMessage,
            "创作任务提交失败，请稍后再试"
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 409, body: nil).userMessage,
            "这次提交和上一次撞了，请重试"
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 429, body: nil).userMessage,
            "请求过于频繁，请稍后再试"
        )
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 500, body: nil).userMessage,
            "服务端错误（500）"
        )
    }

    /// A15：英文码只进分支判断，**一个都不许上屏**。
    func testNoEnglishCodeLeaksIntoAnyUserMessage() throws {
        let bodies: [Data?] = [
            try Fixture.data("studio-create-error-credits-insufficient"),
            try Fixture.data("studio-create-error-invalid-request"),
            Data(#"{"error":"submit_failed","code":"submit_failed"}"#.utf8),
            Data(#"{"error":"provider_lease_busy","code":"provider_lease_busy"}"#.utf8),
            nil,
        ]
        let forbidden = ["credits_insufficient", "invalid_request", "submit_failed",
                         "provider_lease_busy", "IDEMPOTENCY_CONFLICT", "AUTH_REQUIRED"]
        for status in [400, 401, 402, 403, 409, 429, 500, 502, 503] {
            for body in bodies {
                let message = StudioCreateRejection.classify(statusCode: status, body: body).userMessage
                for word in forbidden {
                    XCTAssertFalse(
                        message.contains(word),
                        "英文码上屏（\(status) → \(word)）：\(message)"
                    )
                }
                XCTAssertFalse(message.contains("未知错误"), "A4 明令不许有糊词")
            }
        }
    }

    /// `error` 是服务端可控字符串 ⇒ 透传的那几档只透传**中文人话**那一份；
    /// 402 那一档服务端给的是英文码，所以它走组装、不走透传（本层唯一裁决点）。
    func testCreditsInsufficientNeverPassesTheEnglishErrorThrough() {
        let body = Data(#"{"error":"credits_insufficient","balance":3,"required":20}"#.utf8)
        let message = StudioCreateRejection.classify(statusCode: 402, body: body).userMessage
        XCTAssertFalse(message.contains("credits_insufficient"))
        XCTAssertTrue(message.contains("20"))
    }

    /// 「裸码形状」的闸要真拦得住：400 档是**透传**档，若服务端在 `error` 里回一个
    /// 标识符（同一字段在 402 档已被实测这么用过），不许原样上屏（A15）。
    func testBareCodeShapedServerMessageIsNotPassedThrough() {
        for status in [400, 429, 502, 503, 500] {
            let body = Data(#"{"error":"provider_lease_busy"}"#.utf8)
            let message = StudioCreateRejection.classify(statusCode: status, body: body).userMessage
            XCTAssertFalse(message.contains("provider_lease_busy"), "\(status) 档把裸码印上屏了")
            XCTAssertFalse(message.isEmpty)
        }
        // 反过来：带空格/标点/中文的一律当人话透传（不许把服务端的话改掉）。
        let sentence = Data(#"{"error":"Music description is too long, please shorten it"}"#.utf8)
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 400, body: sentence).userMessage,
            "Music description is too long, please shorten it"
        )
        let chinese = Data(#"{"error":"音乐描述过长（最多 2000 字）"}"#.utf8)
        XCTAssertEqual(
            StudioCreateRejection.classify(statusCode: 400, body: chinese).userMessage,
            "音乐描述过长（最多 2000 字）"
        )
    }

    // MARK: - 作品行

    func testSucceededWorksDecodeBothRowsWithOptionalPlaybackUrl() throws {
        let page = try Fixture.decode(CreateWorksResponseDto.self, "create-works-succeeded")
        XCTAssertEqual(page.total, 2)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.works.count, 2)
        XCTAssertEqual(page.playableWorks.count, 2)

        let first = try XCTUnwrap(page.works.first)
        XCTAssertEqual(first.id, "job-test-0001:cand-1")
        XCTAssertEqual(first.jobId, "job-test-0001")
        XCTAssertEqual(first.status, .succeeded)
        XCTAssertNil(first.playbackUrl, "经典 worker 路径不签发 playbackUrl")
        XCTAssertEqual(first.audioUrl?.rawValue, "/audio/summer-signal_9f3a1c2b4d5e6f70.mp3")
        XCTAssertEqual(first.duration, 118.4)
        XCTAssertEqual(first.instrumental, false)
        XCTAssertEqual(first.displayTitle, "Summer Signal")
        XCTAssertTrue(first.isPlayable)
        XCTAssertFalse(first.isPendingPlaceholder)

        let second = try XCTUnwrap(page.works.last)
        XCTAssertEqual(second.id, "job-test-0001:cand-2")
        XCTAssertEqual(second.instrumental, true)
        XCTAssertNotNil(second.playbackUrl, "media/objects 形态才签发免凭证直链")
    }

    func testGeneratingRowsArePlaceholdersAndNotPlayable() throws {
        let page = try Fixture.decode(CreateWorksResponseDto.self, "create-works-generating")
        XCTAssertEqual(page.works.count, 2)
        XCTAssertTrue(page.playableWorks.isEmpty, "生成中没有可播/可存的作品")
        for work in page.works {
            XCTAssertTrue(work.isPendingPlaceholder, "\(work.id) 是占位行")
            XCTAssertFalse(work.isPlayable)
            XCTAssertNil(work.audioUrl)
            XCTAssertNil(work.duration)
        }
        // 状态文案走唯一词表（A15）：屏上不出现 queued/processing。
        XCTAssertEqual(page.works.first?.status?.userLabel, "制作中")
        XCTAssertEqual(page.works.last?.status?.userLabel, "排队中")
    }

    /// 失败行有 `errorMessage`，但没有音频 ⇒ 不可播、不可存（19 §3.D 就地展示错误）。
    func testFailedWorkCarriesErrorMessageAndIsNotPlayable() throws {
        let data = Data(#"""
        {"works":[{"id":"job-9:cand-1","jobId":"job-9","title":"夏夜","status":"failed",
        "audioUrl":null,"errorMessage":"上游制作失败","duration":null}],"total":1}
        """#.utf8)
        let page = try JSONDecoder().decode(CreateWorksResponseDto.self, from: data)
        let work = try XCTUnwrap(page.works.first)
        XCTAssertEqual(work.status, .failed)
        XCTAssertEqual(work.errorMessage, "上游制作失败")
        XCTAssertFalse(work.isPlayable)
        XCTAssertTrue(page.playableWorks.isEmpty)
        XCTAssertEqual(work.status?.userLabel, "没能完成")
    }

    /// 签名地址不许经反射/描述泄漏（TD-23 口径）。
    func testSignedAudioUrlsNeverSurfaceInDescriptions() throws {
        let page = try Fixture.decode(CreateWorksResponseDto.self, "create-works-succeeded")
        let second = try XCTUnwrap(page.works.last)
        let playback = try XCTUnwrap(second.playbackUrl?.rawValue)
        let described = String(describing: page)
        let dumped = String(reflecting: page)
        XCTAssertFalse(described.contains(playback), "description 泄漏了签名串")
        XCTAssertFalse(dumped.contains(playback), "反射面泄漏了签名串")
        XCTAssertTrue(described.contains("<redacted>"))
    }

    // MARK: - 伪 trackId

    func testPseudoTrackIdConstructionAndSplitting() {
        XCTAssertEqual(
            StudioCreateWorkIdentifier.pseudoTrackId(jobId: "job-1", candidateId: "cand-2"),
            "job-1:cand-2"
        )
        XCTAssertNil(StudioCreateWorkIdentifier.pseudoTrackId(jobId: "", candidateId: "cand-2"))
        XCTAssertNil(StudioCreateWorkIdentifier.pseudoTrackId(jobId: "job-1", candidateId: "  "))
        XCTAssertNil(
            StudioCreateWorkIdentifier.pseudoTrackId(jobId: "job-1:evil", candidateId: "cand"),
            "段里带冒号会造出三段 id，服务端的 split(':')[0] 会认错 jobId"
        )
        XCTAssertEqual(
            StudioCreateWorkIdentifier.split("job-1:cand-2")?.jobId, "job-1"
        )
        XCTAssertEqual(
            StudioCreateWorkIdentifier.split("job-1:cand-2")?.candidateId, "cand-2"
        )
        XCTAssertEqual(StudioCreateWorkIdentifier.split("job-1")?.jobId, "job-1")
        XCTAssertNil(StudioCreateWorkIdentifier.split("job-1")?.candidateId)
        XCTAssertNil(StudioCreateWorkIdentifier.split(""))
        XCTAssertNil(StudioCreateWorkIdentifier.split(":cand"), "空 jobId 段")
        XCTAssertNil(StudioCreateWorkIdentifier.split("job-1:"), "空 candidateId 段")
        XCTAssertNil(StudioCreateWorkIdentifier.split("a:b:c"), "三段不是契约形状")
    }

    func testPendingPlaceholderDetection() {
        XCTAssertTrue(StudioCreateWorkIdentifier.isPendingPlaceholder(candidateId: "pending-1"))
        XCTAssertTrue(StudioCreateWorkIdentifier.isPendingPlaceholder(candidateId: "pending-2"))
        XCTAssertFalse(StudioCreateWorkIdentifier.isPendingPlaceholder(candidateId: "cand-1"))
        XCTAssertFalse(StudioCreateWorkIdentifier.isPendingPlaceholder(candidateId: nil))
    }

    // MARK: - 轮询节拍

    func testPollScheduleMatchesTheDocumentedCadence() {
        let schedule = StudioCreatePollSchedule()
        XCTAssertEqual(schedule.fastPollCount, 6)
        XCTAssertEqual(schedule.fastInterval, 5)
        XCTAssertEqual(schedule.slowInterval, 10)
        XCTAssertEqual(schedule.maximumElapsed, 1800, "上限约 30min")

        for attempt in 1...6 {
            XCTAssertEqual(schedule.interval(forAttempt: attempt), 5, "前 6 次 5s")
        }
        XCTAssertEqual(schedule.interval(forAttempt: 7), 10, "第 7 次起 10s")
        XCTAssertEqual(schedule.interval(forAttempt: 60), 10)

        XCTAssertEqual(schedule.elapsed(beforeAttempt: 1), 0)
        XCTAssertEqual(schedule.elapsed(beforeAttempt: 7), 30)
        XCTAssertEqual(schedule.elapsed(beforeAttempt: 8), 40)

        XCTAssertTrue(schedule.shouldPoll(attempt: 1))
        XCTAssertFalse(schedule.shouldPoll(attempt: 0), "0 基不是合法尝试号")
        XCTAssertEqual(schedule.maximumAttemptCount, 183)
        XCTAssertLessThan(schedule.elapsed(beforeAttempt: schedule.maximumAttemptCount), 1800)
        XCTAssertFalse(schedule.shouldPoll(attempt: schedule.maximumAttemptCount + 1))
    }

    /// 构造期 clamp：病态参数不许造出「永不轮询」或「无限轮询」的调度器。
    func testPollScheduleClampsDegenerateParameters() {
        let degenerate = StudioCreatePollSchedule(
            fastPollCount: -3, fastInterval: -1, slowInterval: 0, maximumElapsed: -10
        )
        XCTAssertEqual(degenerate.fastPollCount, 0)
        XCTAssertEqual(degenerate.fastInterval, 0)
        XCTAssertEqual(degenerate.slowInterval, 0)
        XCTAssertEqual(degenerate.maximumElapsed, 0)
        XCTAssertFalse(degenerate.shouldPoll(attempt: 1), "上限 0 ⇒ 一次都不发")
        XCTAssertEqual(degenerate.maximumAttemptCount, 0)

        let generous = StudioCreatePollSchedule(maximumElapsed: 60)
        // 6 次 ×5s = 30s，之后每 10s 一次：第 7/8/9 次的累计等待是 30/40/50，
        // 第 10 次要到 60s ⇒ 不满足「< 上限」。
        XCTAssertEqual(generous.maximumAttemptCount, 9)
        XCTAssertEqual(generous.elapsed(beforeAttempt: 10), 60)
    }

    // MARK: - P1-2：翻唱 / 续写 / 重制的入参（§4.7）

    private func body(_ request: StudioCreateGenerateRequestDto) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    /// 没填的键**不许以 null 出现**：create 那一档的线上形状必须与 P0 验收时逐字节一致，
    /// 否则 19 屏已归档的那张证据就不是这一版代码拍出来的了。
    func testRemixFieldsAreAbsentNotNullForPlainCreate() throws {
        let request = try StudioCreateGenerateRequestDto(prompt: "a", token: token())
        XCTAssertEqual(
            Set(try body(request).keys),
            ["mode", "operation", "prompt", "idempotencyKey"],
            "create 的线上形状不许因为加了新字段而变"
        )
    }

    func testCoverCarriesTheSourceClipAndKeepsCreateKeys() throws {
        let request = try StudioCreateGenerateRequestDto(
            prompt: "同一旋律换成粤语", mode: .advanced, operation: .cover,
            sourceClipId: "clip-1", token: token()
        )
        let encoded = try body(request)
        XCTAssertEqual(encoded["operation"] as? String, "cover")
        XCTAssertEqual(encoded["mode"] as? String, "advanced")
        XCTAssertEqual(encoded["sourceClipId"] as? String, "clip-1")
        XCTAssertFalse(
            encoded.keys.contains("continueAt"),
            "续写起点只有 extend 才有意义，不许顺手带上"
        )
    }

    /// 服务端把 `continueAt` 按 0.1 取整（`generate.ts:147-152`）⇒ 客户端也按 0.1 落，
    /// 屏上显示 12.34 而发出去 12.3 就是"看到的与发出去的不是同一份数"。
    func testContinueAtIsRoundedToTheServerPrecision() throws {
        let request = try StudioCreateGenerateRequestDto(
            prompt: "接着唱", mode: .advanced, operation: .extend,
            sourceClipId: "clip-1", continueAt: 12.34, token: token()
        )
        XCTAssertEqual(try body(request)["continueAt"] as? Double, 12.3)
    }

    /// 三种"要有源"的操作，没源就在本地拦下 —— 服务端对这一格**完全不校验**，
    /// 放它出去只会换来一次真扣费 + 一个异步 failed。
    func testNonCreateOperationsCannotLeaveWithoutASource() throws {
        for operation in [
            StudioCreateOperation.cover, .extend, .remaster
        ] {
            for blank in [nil, "", "   "] {
                XCTAssertThrowsError(
                    try StudioCreateGenerateRequestDto(
                        prompt: "p", operation: operation, sourceClipId: blank, token: token()
                    ),
                    "\(operation.rawValue) 在 sourceClipId=\(String(describing: blank)) 时不该被放行"
                ) { error in
                    XCTAssertEqual(error as? StudioCreateRequestError, .missingSourceClip)
                }
            }
        }
    }

    /// 「prompt 必填」只在 simple 成立（`generate.ts:107`）：advanced 那一档可以只给源。
    func testEmptyPromptIsOnlyRejectedWhereTheServerRequiresIt() throws {
        XCTAssertThrowsError(
            try StudioCreateGenerateRequestDto(prompt: "  ", token: token())
        ) { error in
            XCTAssertEqual(error as? StudioCreateRequestError, .emptyPrompt)
        }
        XCTAssertNoThrow(
            try StudioCreateGenerateRequestDto(
                prompt: "  ", mode: .advanced, operation: .remaster,
                sourceClipId: "clip-1", token: token()
            )
        )
    }

    func testRemixBoundsMatchTheServer() throws {
        XCTAssertThrowsError(
            try StudioCreateGenerateRequestDto(
                prompt: "p", operation: .cover,
                sourceClipId: String(repeating: "c", count: 201), token: token()
            )
        ) { error in
            XCTAssertEqual(
                error as? StudioCreateRequestError,
                .sourceClipIDTooLong(limit: 200, actual: 201)
            )
        }
        for bad in [-1.0, 3601.0, Double.nan, Double.infinity] {
            XCTAssertThrowsError(
                try StudioCreateGenerateRequestDto(
                    prompt: "p", operation: .extend, sourceClipId: "clip-1",
                    continueAt: bad, token: token()
                ),
                "continueAt=\(bad) 不该被放行"
            ) { error in
                XCTAssertEqual(
                    error as? StudioCreateRequestError,
                    .continueAtOutOfRange(limit: 3600)
                )
            }
        }
    }
}
