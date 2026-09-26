import CovaCore
import CovaPlayer
import Foundation

/// 创作台（19 屏）的会话层腿：提交 → 轮询 → 结果行 → 播放 / 直存（A3/A4/A5/A6/A11）。
///
/// 为什么整条腿住在这里而不是视图里（`design/screens/19-studio-create.md` §4）：
/// 「提交在途时返回上一页 ⇒ 任务继续轮询」。轮询器跟着视图生死，用户一退屏
/// 就再也看不到结果 —— 而**钱已经扣了**，那比看不到更糟。
///
/// 幂等（A11）的三条都在这一层落实，视图没有绕过它们的入口：
/// · 一次点击 = 一个新 `IdempotentRequestToken`；
/// · 同一次提交的重试（`.unreachable(.network)`）复用**同一把**键；
/// · 「重新生成」= 新提交 = 新键。
extension AppSession {
    public var studioCreateService: StudioCreateService { StudioCreateService(client: client) }

    // MARK: - 提交

    /// 「开始生成」/「重新生成」。调用即返回，进度看 `studioCreate`。
    public func submitStudioCreate() {
        startStudioCreate(reusingToken: nil)
    }

    /// 同一次提交的重试：**复用同一把幂等键**（服务端同键重放返回已有 jobId、不二次扣费）。
    public func retryStudioCreateSubmission() {
        guard let token = studioCreateToken else {
            submitStudioCreate()
            return
        }
        startStudioCreate(reusingToken: token)
    }

    private func startStudioCreate(reusingToken: IdempotentRequestToken?) {
        cancelStudioCreate()
        let prompt = studioCreatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            // 本地就拦：不花一次往返去换服务端那句同样的话（19 §4）。
            studioCreate = StudioCreateState(
                phase: .failed,
                message: StudioCreateSubmissionFailure.invalidInput(.emptyPrompt).userMessage
            )
            return
        }
        let token = reusingToken ?? IdempotentRequestToken(operation: .studioCreateGenerate)
        studioCreateToken = token
        studioCreate = StudioCreateState(phase: .submitting)
        studioCreateSubmitID += 1
        let submitID = studioCreateSubmitID
        studioCreateTask = Task { @MainActor [weak self] in
            await self?.runStudioCreateSubmission(prompt: prompt, token: token, submitID: submitID)
        }
    }

    private func runStudioCreateSubmission(
        prompt: String, token: IdempotentRequestToken, submitID: Int
    ) async {
        do {
            let response = try await studioCreateService.generate(prompt: prompt, token: token)
            guard studioCreateSubmitID == submitID else { return }
            guard let jobId = response.jobId else {
                studioCreate.phase = .unconfirmed
                studioCreate.message = StudioCreateSubmissionFailure
                    .unresolvedSubmission.userMessage
                return
            }
            studioCreate.jobId = jobId
            studioCreate.charge = response.charge
            studioCreate.phase = .polling(.queued)
            await pollStudioCreate(jobId: jobId, submitID: submitID)
        } catch let failure as StudioCreateSubmissionFailure {
            guard studioCreateSubmitID == submitID else { return }
            studioCreate.phase = failure.isRetryableWithSameKey ? .unconfirmed : .failed
            studioCreate.message = failure.userMessage
        } catch {
            guard studioCreateSubmitID == submitID else { return }
            let failure = StudioCreateSubmissionFailure.unreachable(
                CatalogService.classify(error)
            )
            studioCreate.phase = failure.isRetryableWithSameKey ? .unconfirmed : .failed
            studioCreate.message = failure.userMessage
        }
    }

    // MARK: - 轮询（前 6 次 5s、之后 10s、上限约 30min）

    private func pollStudioCreate(jobId: String, submitID: Int) async {
        let schedule = StudioCreatePollSchedule()
        let startedAt = Date()
        startStudioCreateTicker(startedAt: startedAt, submitID: submitID)
        defer { stopStudioCreateTicker() }
        var attempt = 1
        // 连续投到第 N 次还没成 ⇒ 把「轮询本身在报错」说到屏上（不静默）。
        let warnAfter = 3
        var lastObserved: GenerationJobStatus?
        while schedule.shouldPoll(attempt: attempt) {
            if studioCreateSubmitID != submitID || Task.isCancelled { return }
            do {
                let response = try await studioCreateService.generationJob(id: jobId)
                guard studioCreateSubmitID == submitID else { return }
                if let status = response.job?.status {
                    lastObserved = status
                    switch status {
                    case .succeeded:
                        await loadStudioCreateWorks(jobId: jobId, submitID: submitID)
                        return
                    case .failed, .cancelled:
                        studioCreate.phase = .failed
                        studioCreate.message = response.job?.errorMessage
                        return
                    case .queued, .submitted, .processing:
                        studioCreate.phase = .polling(status)
                    }
                }
            } catch {
                guard studioCreateSubmitID == submitID else { return }
                // 单次轮询失败**不终止整条腿**（网络抖动不等于任务失败）：
                // 继续按节拍投，直到上限。但这一格要说出来，不能静默。
                if attempt >= warnAfter {
                    studioCreate.message = StudioCreateSubmissionFailure
                        .unreachable(CatalogService.classify(error)).userMessage
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(schedule.interval(forAttempt: attempt) * 1_000_000_000))
            if Task.isCancelled, studioCreateSubmitID == submitID { return }
            attempt += 1
        }
        guard studioCreateSubmitID == submitID else { return }
        // 到上限：**不说失败**（服务端可能仍在跑），也不说完成。
        studioCreate.phase = .unconfirmed
        studioCreate.message = lastObserved == nil
            ? "还没读到这次任务的状态，稍后再回来看看"
            : "还在做，稍后回来看"
    }

    private func loadStudioCreateWorks(jobId: String, submitID: Int) async {
        do {
            let page = try await studioCreateService.works(id: jobId)
            guard studioCreateSubmitID == submitID else { return }
            studioCreate.phase = .succeeded
            studioCreate.works = page.works
            studioCreate.message = page.works.isEmpty ? "做好了，但作品列表是空的" : nil
            await refreshSavedWorks()
        } catch {
            guard studioCreateSubmitID == submitID else { return }
            // 任务确实完成了（钱已扣）⇒ 说「已完成」，同时把读不回来这件事讲清楚，
            // 不许把它混进「没能完成」。
            studioCreate.phase = .succeeded
            studioCreate.works = []
            studioCreate.message = "做好了，但作品列表没读到：\(CatalogService.classify(error).userText)"
        }
    }

    /// 1s 一跳的计时（D 区「已等 N 分 N 秒」）。
    private func startStudioCreateTicker(startedAt: Date, submitID: Int) {
        studioCreateTicker?.cancel()
        studioCreateTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.studioCreateSubmitID == submitID else { return }
                self.studioCreate.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopStudioCreateTicker() {
        studioCreateTicker?.cancel()
        studioCreateTicker = nil
    }

    /// 停轮询但**留着屏上的状态**（切屏回来还能看见上一次的结果）。
    public func cancelStudioCreate() {
        studioCreateSubmitID += 1
        studioCreateTask?.cancel()
        studioCreateTask = nil
        stopStudioCreateTicker()
    }

    /// 全清（登出/换号、「再做一首」）。
    public func resetStudioCreate() {
        cancelStudioCreate()
        studioCreateToken = nil
        studioCreate = StudioCreateState()
        studioCreatePrompt = ""
        savedWorkIDs = []
    }

    /// 当前凭证快照的会话上下文（owner 分桶与 generation 作废都靠它）。
    /// 读不出来 = `nil` ⇒ 上层一律**不做**，而不是猜一个身份（fail-closed）。
    private func currentPlaybackSession() async -> PlaybackSessionContext? {
        guard let snapshot = try? await auth.currentSession() else { return nil }
        return PlaybackSessionContext(owner: snapshot.principal, generation: snapshot.generation)
    }

    // MARK: - 作品播放（A5：伪 trackId 上报）

    /// 播一首作品。条目 id **就是**伪 trackId `{jobId}:{candidateId}` ⇒ 播放层的
    /// 集次上报会把它原样发给 `POST /api/tracks/play`（服务端记进 `work_listens`）。
    public func playWork(_ work: CreateWorkItemDto) async {
        guard let item = Self.workPlaybackItem(from: work) else {
            showToast("这首的音频地址不可用，暂时播不了", isError: true)
            return
        }
        await play(items: [item], at: 0)
    }

    /// `CreateWorkItem` → `PlaybackItem`。
    ///
    /// 只吃 `audioUrl`，**不吃 `playbackUrl`**：后者是 COS 绝对直链，而 D23 之后
    /// `.publicDirect` 只认生产出口（`CovaEnvironment.isPublicDirectEgressAllowed`），
    /// 交给 `AVPlayer` 自己起的那次出站本层管不到 ⇒ 作品的试听仍走 D7
    /// 「Bearer 下载 → 校验非空 → `file://`」（A13）。`playbackUrl` 只用于直存。
    public static func workPlaybackItem(from work: CreateWorkItemDto) -> PlaybackItem? {
        guard work.isPlayable, let raw = work.audioUrl?.rawValue,
              let audio = CovaEnvironment.resolveMediaURL(raw),
              let audioURL = try? AudioURL(https: audio) else { return nil }
        let cover = CovaEnvironment.resolveMediaURL(work.coverUrl)
            .flatMap { try? AudioURL(https: $0) }
        return try? PlaybackItem(
            id: work.id,
            title: work.displayTitle ?? "未命名作品",
            artist: "Cova AI",
            duration: work.duration,
            coverURL: cover,
            audioSource: .bearerRequired(audioURL),
            kind: .work
        )
    }

    // MARK: - 作品直存（A6：不 checkout、不扣费）

    /// 把作品音频直存到本机。**这里没有任何扣费路径**：走的是
    /// `WorkDownloadStore`（Documents + 清单），而不是 `downloads/checkout`。
    public func saveWork(_ work: CreateWorkItemDto) async {
        guard let session = await currentPlaybackSession(),
              let item = Self.workDownloadRequest(from: work, session: session) else {
            showToast("这首的音频地址不可用，存不了", isError: true)
            return
        }
        switch await workDownloads.save(item) {
        case .success(let entry):
            savedWorkIDs.insert(entry.workId)
            showToast("已存到本机")
        case .failure(let error):
            showToast(error.description, isError: true)
        }
    }

    /// 已存的再点一次 = 删除本机文件（19 §3.E，二次确认在视图侧）。
    public func removeSavedWork(_ work: CreateWorkItemDto) async {
        guard let session = await currentPlaybackSession(), let owner = session.owner else { return }
        if await workDownloads.remove(workId: work.id, owner: owner) {
            savedWorkIDs.remove(work.id)
            showToast("已删除本机文件")
        } else {
            showToast("本机文件没删掉", isError: true)
        }
    }

    /// 刷新「已在本机」标记（事实源是盘上文件，不是内存猜测）。
    public func refreshSavedWorks() async {
        guard let session = await currentPlaybackSession(), let owner = session.owner else {
            savedWorkIDs = []
            return
        }
        savedWorkIDs = Set(await workDownloads.entries(owner: owner).map(\.workId))
    }

    /// 登出/换号：该身份名下保存的作品文件与清单一并清掉（D8 owner 隔离）。
    ///
    /// `owner` 必须在**签出之前**取 —— 签出之后凭证快照已经没了，
    /// 届时连"该清谁的那一份"都说不出来。
    public func resetWorkDownloads(owner: PrincipalID?) async {
        if let owner { _ = await workDownloads.purge(owner: owner) }
        savedWorkIDs = []
    }

    public static func workDownloadRequest(
        from work: CreateWorkItemDto, session: PlaybackSessionContext?
    ) -> WorkDownloadRequest? {
        // owner 先成立才谈得上「存到谁的名下」：没有归属就不存，
        // 而不是先落进一个无主目录、再指望 `WorkDownloadStore` 拒掉它。
        guard let session, session.owner != nil, work.isPlayable,
              let raw = (work.audioUrl ?? work.playbackUrl)?.rawValue,
              let url = CovaEnvironment.resolveMediaURL(raw),
              let source = try? AudioURL(https: url) else { return nil }
        return WorkDownloadRequest(
            workId: work.id,
            title: work.displayTitle ?? "未命名作品",
            artist: nil,
            duration: work.duration,
            source: source,
            session: session
        )
    }
}

/// `CatalogFailure` 的可读面（19 §4 的错误表要说得出是哪一类）。
extension CatalogFailure {
    var userText: String {
        switch self {
        case .network: return "网络没通"
        case .server(let message): return message
        case .unauthenticated: return "登录状态已过期"
        case .backendGap(let id): return "后端契约缺口（\(id)）"
        }
    }
}
