import CovaCore
import CovaPlayer
import CovaUI
import Foundation
import SwiftUI

/// 会话详情（design 09）：对话流 + 深度思考折叠 + 唯一一条 run 行 + 计划卡 + 双 Demo + 输入框。
///
/// 这一屏的规则几乎全是「不许做什么」，逐条落进代码：
/// · **不做本地余额预检**（缺钱由服务端说，UI 只回显它给的）；
/// · 不出现「充值 / 购买 / 价格 / 客服」任何字样，也不显示英文状态名；
/// · `audioUrl` / `audioDownloadStatus` 的签名地址**不显示、不写日志、不落盘**（`SecretString` 三面脱敏）；
/// · 双 Demo 只渲染**前两个**候选，两个都 settled 才算终态（硬边界 6）；
/// · 「开始制作」必须同时满足：状态 `ready` + 归因（`sourceMessage.messageId == 本次客户端消息号`）
///   + 带 `snapshotHash`，三者缺一律置灰，不放宽；
/// · 未知 `run_*` 事件**隐藏且不算坏事件**；未知计划卡状态渲染只读卡 + 「状态更新中」。
public struct AISessionDetailView: View {
    @Environment(AppSession.self) private var session
    private let sessionID: String

    @State private var phase: Phase = .loading
    @State private var lines: [TranscriptLine] = []
    @State private var plans: [OneStepPlanCardDto] = []
    @State private var candidates: [GenerationCandidateDto] = []
    @State private var creditsBalance: Int?
    @State private var runLabel: String?
    @State private var degradeLabel: String?
    @State private var draft = ""
    @State private var deepThinking = false
    @State private var busy = false
    @State private var thinkingSteps = 0
    @State private var lineCounter = 0
    @State private var agentBuffer = ""

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init(sessionID: String) { self.sessionID = sessionID }

    public var body: some View {
        VStack(spacing: 0) {
            if let degradeLabel { degradationBar(degradeLabel) }
            transcript
            composer
        }
        .covaPage()
        .navigationTitle("创作会话")
        .navigationBarTitleDisplayMode(.inline)
        .task { await openSession() }
        .onDisappear { Task { await session.cancelStudioStream() } }
    }

    // MARK: 流式过程

    @ViewBuilder
    private var transcript: some View {
        switch phase {
        case .loading:
            CovaSkeleton(rows: 5)
        case .failed(let failure):
            CovaErrorState(kind: Self.kind(failure)) { Task { await openSession() } }
        case .ready:
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: CovaSpace.md) {
                        ForEach(lines) { line in
                            row(line).id(line.id)
                        }
                        ForEach(plans, id: \.planCardId) { plan in
                            PlanCardView(
                                plan: plan,
                                canStart: canStart(plan),
                                creditsBalance: creditsBalance,
                                onStart: { Task { await start(plan) } },
                                onRevise: { draft = "请修改：" }
                            )
                        }
                        if !candidates.isEmpty { candidateBlock }
                    }
                    .padding(CovaSpace.pageGutter)
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last { scroll.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: TranscriptLine) -> some View {
        switch line.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(CovaType.body).foregroundStyle(CovaColor.accentText)
                    .padding(CovaSpace.md)
                    .background(
                        RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                            .fill(CovaColor.accentSoft)
                    )
            }
        case .agentText(let text):
            Text(text)
                .font(CovaType.body).foregroundStyle(CovaColor.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let steps, _):
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                Text("▸ 深度思考 · \(steps) 步")
                    .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            }
        case .run(let label):
            HStack(spacing: CovaSpace.sm) {
                Image(systemName: "circle.dashed").foregroundStyle(CovaColor.secondary)
                Text(label).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            }
        case .system(let text):
            Text(text).font(CovaType.caption).foregroundStyle(CovaColor.error)
        case .plan:
            EmptyView()   // 计划卡本体在 plans 那一层渲染，这里只留位置
        }
    }

    private func degradationBar(_ text: String) -> some View {
        HStack(spacing: CovaSpace.sm) {
            Image(systemName: "wifi.slash").foregroundStyle(CovaColor.secondary)
            Text(text).font(CovaType.caption).foregroundStyle(CovaColor.secondary)
            Spacer()
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
        .background(CovaColor.surface)
    }

    // MARK: 双 Demo（只渲染前两个候选）

    @ViewBuilder
    private var candidateBlock: some View {
        let pair = Array(candidates.prefix(2))
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            Text(terminalText(pair)).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            ForEach(pair.indices, id: \.self) { index in
                candidateRow(pair[index], index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidateRow(_ candidate: GenerationCandidateDto, index: Int) -> some View {
        let settled: Bool
        if let status = candidate.audioDownloadStatus {
            settled = status == .ready || status == .failed
        } else {
            settled = candidate.audioUrl?.rawValue.isEmpty == false
        }
        return CovaListRow(
            title: candidate.title ?? "版本 \(index + 1)",
            subtitle: settled ? "可以试听" : "制作中",
            artwork: CovaArtwork(url: URL(string: candidate.coverUrl ?? ""), title: candidate.title ?? "")
        ) {
            Image(systemName: settled ? "play.circle" : "hourglass").foregroundStyle(CovaColor.muted)
        } action: {
            guard settled, let raw = candidate.audioUrl?.rawValue, let url = URL(string: raw),
                  let item = Self.playbackItem(for: candidate, url: url) else {
                session.showToast("试听文件没取到，重试", isError: true)
                return
            }
            Task { await session.play(items: [item], at: 0) }
        }
    }

    /// 私有音频走 D7 硬顺序：交给 `PrivateAudioFetcher` 先 Bearer 下载 → 校验非空 → `file://`。
    private static func playbackItem(
        for candidate: GenerationCandidateDto, url: URL
    ) -> PlaybackItem? {
        guard let audio = try? AudioURL(https: url) else { return nil }
        return try? PlaybackItem(
            id: candidate.mediaReferenceId ?? candidate.id,
            title: candidate.title ?? "生成候选",
            artist: "Cova AI",
            album: nil,
            duration: candidate.duration,
            coverURL: URL(string: candidate.coverUrl ?? "").flatMap { try? AudioURL(https: $0) },
            audioSource: .bearerRequired(audio),
            kind: .privateCandidate
        )
    }

    /// 终态文案（design 09 §H）。**两个都 settled 才算终态**。
    private func terminalText(_ pair: [GenerationCandidateDto]) -> String {
        func settled(_ candidate: GenerationCandidateDto) -> Bool {
            if let status = candidate.audioDownloadStatus { return status == .ready }
            return candidate.audioUrl?.rawValue.isEmpty == false
        }
        func failed(_ candidate: GenerationCandidateDto) -> Bool {
            candidate.audioDownloadStatus == .failed
        }
        guard pair.count == 2 else { return "两个版本制作中" }
        let readyCount = pair.filter { settled($0) }.count
        let failedCount = pair.filter { failed($0) }.count
        if readyCount == 2 { return "两个版本都好了，挑一版继续" }
        if failedCount == 2 { return "两个版本都没能完成" }
        if failedCount == 1, readyCount == 1 { return "一版完成，另一版失败" }
        if readyCount == 1 { return "就绪 1/2 · 等另一个版本完成" }
        if failedCount == 1 { return "1/2 遇到问题 · 等另一个版本完成" }
        return "两个版本制作中"
    }

    // MARK: 输入框

    private var composer: some View {
        VStack(spacing: CovaSpace.sm) {
            HStack(spacing: CovaSpace.sm) {
                CovaChip("深度思考", isSelected: deepThinking) { deepThinking.toggle() }
                Spacer()
                if busy {
                    Button("停止生成") { Task { await session.cancelStudioStream() } }
                        .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                }
            }
            HStack(spacing: CovaSpace.sm) {
                TextField("想听什么？找歌或做歌，一句话搞定", text: $draft)
                    .font(CovaType.body).foregroundStyle(CovaColor.fg)
                    .padding(CovaSpace.md)
                    .background(
                        RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                            .fill(CovaColor.surface)
                    )
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CovaColor.accentText)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(CovaColor.accent))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                .opacity(draft.isEmpty ? 0.4 : 1)
            }
        }
        .padding(CovaSpace.pageGutter)
        .background(CovaColor.canvas.opacity(0.95))
    }

    // MARK: 行为

    private func openSession() async {
        phase = .loading
        do {
            async let detail = session.studio.session(sessionID)
            async let cards = session.studio.planCards(sessionID: sessionID)
            let result = try await detail
            let planList = (try? await cards) ?? []
            lines = result.messages.compactMap { message in
                guard let text = message.displayText else { return nil }   // 取不到正文就跳过
                lineCounter += 1
                return TranscriptLine(
                    id: lineCounter,
                    kind: message.isFromUser ? .user(text) : .agentText(text)
                )
            }
            plans = planList
            candidates = result.generationJobs.last?.candidates() ?? []
            creditsBalance = try? await session.catalog.me().entitlements.creditsBalance
            phase = .ready
        } catch {
            phase = .failed(StudioService.classify(error))
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        busy = true
        defer { busy = false }
        append(.user(text))
        agentBuffer = ""
        thinkingSteps = 0
        do {
            let body = try StudioService.agentRequestBody(
                sessionID: sessionID, message: text, deepThinking: deepThinking
            )
            let request = try CovaSSERequests.agent(jsonBody: body)
            for try await frame in try await session.beginStudioStream(sessionID: sessionID, request: request) {
                await consume(frame)
                if Task.isCancelled { break }
            }
        } catch {
            append(.system("这次没有成功：\(StudioService.classify(error).uiMessage)"))
        }
        degradeLabel = nil
        runLabel = nil
    }

    private func consume(_ frame: CovaSSEFrame) async {
        switch frame.event {
        case .text:
            if let chunk = Self.decodeText(frame.payload) {
                agentBuffer += chunk
                replaceLatestAgentText(agentBuffer)
            }
        case .thinking:
            thinkingSteps += 1
            appendOrReplaceThinking(steps: thinkingSteps)
        case .planCard:
            if let cards = Self.decodeCards(frame.payload) {
                plans = cards
                plans.sort { ($0.cardIndex ?? 0) < ($1.cardIndex ?? 0) }
            }
        case .error:
            append(.system("这一步暂时卡住了，可以重新描述需求再来一次"))
        case .done:
            degradeLabel = nil
        case .runLifecycle(let name):
            // 只保留**唯一一条** run 行；未知 run_* 不显示、也不算坏事件。
            if let label = Self.runLabel(name) { runLabel = label; appendOrReplaceRun(label) }
        case .unknown:
            break
        }
    }

    private static func runLabel(_ raw: String) -> String? {
        switch raw {
        case "run_started": return "开始处理"
        case "reasoning_summary": return "正在判断"
        case "run_waiting_user": return "等待你的决定"
        case "run_waiting_worker": return "歌曲制作中"
        case "run_completed": return "处理完成"
        case "run_failed": return "处理失败"
        default: return nil
        }
    }

    private static func decodeText(_ payload: Data) -> String? {
        (try? JSONDecoder().decode(CovaSSETextEventDto.self, from: payload))?.text
    }

    private static func decodeCards(_ payload: Data) -> [OneStepPlanCardDto]? {
        if let envelope = try? JSONDecoder().decode(OneStepPlanCardsResponseDto.self, from: payload) {
            return envelope.planCards
        }
        if let single = try? JSONDecoder().decode(OneStepPlanCardDto.self, from: payload) {
            return [single]
        }
        return try? JSONDecoder().decode([OneStepPlanCardDto].self, from: payload)
    }

    private func canStart(_ plan: OneStepPlanCardDto) -> Bool {
        PlanStatusCopy.canStart(plan.status)
            && plan.snapshotHash != nil
            && plan.sourceMessage?.messageId != nil
    }

    private func start(_ plan: OneStepPlanCardDto) async {
        do {
            // 用户主动点的这一次 = 一次新的逻辑操作 ⇒ 由服务侧生成新 token；
            // 本屏**不做自动重放**（design 09：hash 失配后不得自动重发写操作）。
            _ = try await session.studio.startPlan(sessionID: sessionID, plan: plan)
            append(.system("已提交，正在排产"))
            if let cards = try? await session.studio.planCards(sessionID: sessionID) { plans = cards }
        } catch {
            append(.system("这次没提交成功：\(StudioService.classify(error).uiMessage)"))
        }
    }

    // MARK: 行内小工具（保持 lines 只有一条 agent 正文 / 一条 thinking / 一条 run）

    private func append(_ kind: TranscriptLine.Kind) {
        lineCounter += 1
        lines.append(TranscriptLine(id: lineCounter, kind: kind))
    }

    private func replaceLatestAgentText(_ text: String) {
        if let index = lines.lastIndex(where: { if case .agentText = $0.kind { return true } else { return false } }) {
            lines[index] = TranscriptLine(id: lines[index].id, kind: .agentText(text))
        } else {
            append(.agentText(text))
        }
    }

    private func appendOrReplaceThinking(steps: Int) {
        if let index = lines.firstIndex(where: { if case .thinking = $0.kind { return true } else { return false } }) {
            lines[index] = TranscriptLine(id: lines[index].id, kind: .thinking(stepCount: steps, expanded: false))
        } else {
            append(.thinking(stepCount: steps, expanded: false))
        }
    }

    private func appendOrReplaceRun(_ label: String) {
        if let index = lines.firstIndex(where: { if case .run = $0.kind { return true } else { return false } }) {
            lines[index] = TranscriptLine(id: lines[index].id, kind: .run(label))
        } else {
            append(.run(label))
        }
    }

    private static func kind(_ failure: CatalogFailure) -> CovaErrorState.Kind {
        switch failure {
        case .network: return .network
        case .server: return .server
        case .backendGap(let id): return .backendGap(id)
        }
    }
}

/// 计划卡（design 09 §G）。缺 `snapshotHash` / 归因 ⇒ 主按钮置灰，**不放宽**。
struct PlanCardView: View {
    let plan: OneStepPlanCardDto
    let canStart: Bool
    let creditsBalance: Int?
    let onStart: () -> Void
    let onRevise: () -> Void
    @State private var promptExpanded = false

    var body: some View {
        CovaCard {
            VStack(alignment: .leading, spacing: CovaSpace.md) {
                HStack(alignment: .top) {
                    Text(plan.title?.selected ?? plan.summary ?? "制作计划")
                        .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    Spacer()
                    Text(PlanStatusCopy.label(plan.status))
                        .font(CovaType.caption)
                        .foregroundStyle(badgeColor)
                }
                if let analysis = plan.style?.analysisZh, !analysis.isEmpty {
                    Text(analysis).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                }
                if let promptEn = plan.style?.promptEn, !promptEn.isEmpty {
                    Button(promptExpanded ? "收起提示词" : "查看提示词") { promptExpanded.toggle() }
                        .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    if promptExpanded {
                        Text(promptEn).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    }
                }
                ForEach(Array(sectionsOf(plan).enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 2) {
                        // 段名与正文都只在**后端给了**的时候渲染（不补占位）。
                        if let label = section.label, !label.isEmpty {
                            Text(label).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                        }
                        if let text = section.text, !text.isEmpty {
                            Text(text).font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                        }
                    }
                }
                let chips = parameterChips(plan.parameters)
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: CovaSpace.sm) {
                            ForEach(chips, id: \.self) { chip in
                                CovaChip(chip, isSelected: false) {}
                            }
                        }
                    }
                }
                HStack {
                    if let credits = plan.credits {
                        Text("预计消耗 \(credits) co")
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    }
                    if let balance = creditsBalance {
                        Text("余额 \(balance)")
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: CovaSpace.sm) {
                    Button(action: onStart) {
                        Text(PlanStatusCopy.primaryAction(plan.status))
                            .font(CovaType.callout)
                            .foregroundStyle(canStart ? CovaColor.accentText : CovaColor.muted)
                            .padding(.horizontal, CovaSpace.lg).padding(.vertical, CovaSpace.sm)
                            .background(Capsule().fill(canStart ? CovaColor.accent : CovaColor.surface))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    Button("修改要求", action: onRevise)
                        .font(CovaType.callout).foregroundStyle(CovaColor.secondary)
                }
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    private func sectionsOf(_ plan: OneStepPlanCardDto) -> [OneStepLyricsSectionDto] {
        (plan.lyrics?.sections ?? []).sorted { ($0.order ?? .max) < ($1.order ?? .max) }
    }

    /// 参数胶囊只由**契约里真实存在的字段**拼，一个都不发明；全取不到 ⇒ 整段不渲染。
    private func parameterChips(_ parameters: OneStepPlanParametersDto?) -> [String] {
        guard let parameters else { return [] }
        var chips: [String] = []
        if let vocalGender = parameters.vocalGender, !vocalGender.isEmpty { chips.append(vocalGender) }
        if let duration = parameters.targetDurationSec ?? parameters.durationSec {
            chips.append("\(duration)s")
        }
        if let weirdness = parameters.weirdness { chips.append("weirdness \(weirdness)") }
        if let styleWeight = parameters.styleWeight { chips.append("styleWeight \(styleWeight)") }
        return chips
    }

    private var badgeColor: Color {
        switch plan.status {
        case .demosReady: return CovaColor.success
        case .manualRecovery, .retryableFailure: return CovaColor.error
        case .ready, .starting, .generating, .mediaStaging, .deliveryPreparing, .rehydrating:
            return CovaColor.warning
        case .analyzing, .patching, .archived:
            return CovaColor.muted
        }
    }
}
