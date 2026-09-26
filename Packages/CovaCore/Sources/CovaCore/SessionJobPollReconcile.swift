import Foundation

/// 09 会话详情「轮询断链补腿」的判决层（DEVELOPMENT.md §5 P1-5）。
///
/// 为什么要单独收成一层：这条腿的每一个决定都是「要不要改屏上已经画着的东西」，
/// 而它的失败模式是**绿 build、红屏幕**那一类（本仓反复被烧的那一类）—— 一次不该写的赋值
/// 会把两张候选卡从屏上洗掉，编译器一个字都不会报。于是判决必须是纯函数 + 用例钉死，
/// 视图只负责执行判决，自己不持有任何判据。
///
/// ### 核对过的事实一：两个端点**是同一个投影**（所以轮询行带得出候选）
/// `GET …/generation-jobs?id=` 与 `GET …/sessions/:id` 的 `session.generationJobs`
/// 各自定义了**逐字相同**的投影函数
/// `projectGenerationJob(job) = { ...withPlayableAudio(job), ...(timing || {}) }`：
/// · `web/src/app/api/find-my-song/generation-jobs/route.ts:26-32`（+ 单任务分支 `:44-67`）
/// · `web/src/app/api/find-my-song/sessions/[id]/route.ts:40-46`（+ `:163-169`、`:196`）
/// 两边读的都是 `generation_jobs` 的**整行**（`getGenerationJob` =
/// `web/src/lib/generation/jobs.ts:846-848`），`metadata` 两边走的都是 **JSON 字符串**
/// （与 `GenerationJobDto.metadata` 的形态约定同一件事）。
/// 2026-09-27 真实账号只读双向 GET 实测同一个 succeeded 任务：两次读回的**键集合完全相同**
/// （23 键，两侧差集均为空），`metadata` 里都是 2 条候选，除签名地址一族之外所有同名键
/// **逐字节相等**。⇒ 「轮询回来的那一行」在**任务级**上是权威的，可以整行换上屏。
///
/// ### 核对过的事实二：投影相同 **不等于** 时点相同（所以候选清单另说）
/// 轮询只跑在**未终态**那一区间，而服务端恰恰在那一区间里不保证有候选：
/// · 任务刚落库时 `metadata` 里**根本没有 `candidates` 这个键**
///   （`web/src/lib/one-step/generation.ts:1122-1151` 的初始 INSERT 只有 title / stylePrompt /
///   controls / outputs / billingState 那一族，`status='submitted'`）；
/// · **重试**把同一行改回 `submitted` 时**显式**写 `candidates: []`、`candidateCount: 0`
///   （`web/src/lib/one-step/generation.ts:2461-2472`）。
/// 于是「`latestJob = 轮询行; candidates = 轮询行.candidates()`」这一句在「任务进行中」与
/// 「刚重试」两个时刻都会把屏上那两张卡（连同它们带着的试听/收藏态）**清空**，
/// 要等下一次载荷到达才又长回来 —— 那就是每 5 秒一次的红色屏幕。
/// ⇒ 判决把「换整行」与「换候选」拆成两个独立开关（`writesJob` / `writesCandidates`），
///   并把后者的判据收成**一条**：轮询那一行**自己带着非空候选**才允许上屏。
///   空数组与"根本没有这个键"两种形态一律原样留着屏上的清单 —— 这一条对"读得到状态"
///   的几档统一成立，所以"永不洗卡"不靠某一句特例 `if`，而是靠判据本身的形状。
///   「清单其实没变」那一次重复赋值留给视图侧比较挡掉（`GenerationCandidateDto` 是
///   `Equatable`）：本层看不见屏上现在挂着哪几张卡，而 ♡ 的乐观值经不起 5 秒一次的重播种。
public enum SessionJobPollReconcile {

    /// 一次轮询观测里判决要用的两件事。
    ///
    /// 只取这两件是刻意的：`status` 决定收不收口，`carriesCandidates` 决定候选清单动不动。
    /// 其余字段（时间戳、成本、签名地址）一律不参与判定 —— 参与就得在本文件里再立一张
    /// 「哪些字段算权威」的表，而那张表契约里没有。
    public struct Observation: Equatable, Sendable {
        /// 「这一趟什么都没读到」那一档的观测：视图在**发请求之前**问"这一趟还该不该发"时，
        /// 用的就是它 —— 于是"停不停"这一件事在整条腿上只有一个回答处，不必在视图里
        /// 再写一遍 `while schedule.shouldPoll(...)`。
        public static let nothingRead = Observation(status: nil, carriesCandidates: false)

        /// 轮询到的状态；`nil` = **这一趟没读到**（请求失败 / 信封里没有 `job`），
        /// 与"读到了但状态未知"是两件事，不许混成一档。
        public let status: GenerationJobStatus?
        /// 这一行的 `metadata` 里**确实**带着非空候选清单。
        public let carriesCandidates: Bool

        public init(status: GenerationJobStatus?, carriesCandidates: Bool) {
            self.status = status
            self.carriesCandidates = carriesCandidates
        }

        /// 从轮询回来的那一行取观测（`job` 为 `nil` ⇒ 这一趟没读到状态）。
        public init(job: GenerationJobDto?) {
            status = job?.status
            carriesCandidates = job.map { $0.candidates().isEmpty == false } ?? false
        }
    }

    /// 判决的**唯一**出口档位。每一档都对应屏上一条独立的规则，用例逐档钉。
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// 本机正在读这一轮的流 ⇒ 流是这一轮的主人，轮询一个字都不写，这条腿就此让位
        /// （`AISessionDetailView` 的 `busy` 语义：那段时间屏上的 `candidates / latestJob`
        /// 还是这一轮开始**之前**的载荷）。
        case streamOwnsRound
        /// 已到 `StudioCreatePollSchedule` 的等待上限 ⇒ 停。
        /// **停不等于失败**：服务端可能仍在跑（那一次 `refreshGenerationJob` 也可能只是慢），
        /// 客户端"没再读到"绝不能被写成"这一轮没能完成"—— 那是把观察者的预算限制
        /// 冒充成被观察者的结论。屏上保持最后一次已知状态，19 屏同一档位叫 `.unconfirmed`。
        case capReached
        /// 这一趟没读到状态（单次网络/解码失败）：不终止整条腿，也不改屏上任何东西。
        case noObservation
        /// 轮询到的状态与屏上正在显示的那一个相同 ⇒ **不换行**（同一件事不必再写一遍），
        /// 但清单那一维照旧只看"行里带没带着候选"：状态不动而候选落地是真实存在的一种推进。
        case unchanged
        /// 读到终态（succeeded / failed / cancelled）⇒ 换行 + 走**既有**收口腿 + 停。
        case terminalObserved
        /// 屏上那一行**已经**是这一个终态 ⇒ 什么都不写、**不再收口第二次**，只把腿停掉。
        /// 正常路径走不到这一档（`canArm` 拒绝以终态开局、`.terminalObserved` 本身就把腿停了），
        /// 它存在是因为"同一个终态收口两次"这件事必须由判决层挡住，而不是只靠视图那边不出错。
        case alreadySettled
        /// 未终态但状态前进了（排队中 → 已提交 → 制作中）⇒ 换行、继续投；
        /// 清单那一维仍只由"行里带着非空候选"决定（见 `Decision.writesCandidates`）。
        case advanced
    }

    /// 一次判决：改哪些面、要不要收口、这条腿停不停。
    ///
    /// 每个字段都是**开关**而不是结论，视图那边就是照着这几个开关赋值；
    /// 把结论留在本层，屏上就不会长出第二套判据（本仓的原判据）。
    public struct Decision: Equatable, Sendable {
        /// 是否把屏上那一路 job 的**整行**读数换成轮询到的这一行。
        public let writesJob: Bool
        /// 是否允许这条腿改**候选清单**。
        /// 判据只有一条：**轮询那一行自己带着非空候选**。空清单（submitted 那一行没有
        /// `candidates` 键、重试那行显式写 `[]`）一律不许上屏 —— 那正是"绿 build 红屏幕"
        /// 会走的那条路（理由见文件头「核对过的事实二」）。
        public let writesCandidates: Bool
        /// 是否要走屏上**已有的**收口腿（08 那一格的环收口 + `StudioNotifier.reconcileTerminal`）。
        /// 这里不建第二条通知路 —— 本层只说"到了该收的那一刻"。
        public let settles: Bool
        /// 这条腿是否到此为止（读到终态 / 到上限 / 让位给流 / 同一个终态第二次读到）。
        public let stops: Bool
        /// 这条腿要不要**自己下一句失败判词**。
        /// **每一档都是 `false`**，而且这是一个刻意的常量：屏上关于失败的那句话只有一个来源 ——
        /// 载荷里那一份 `errorMessage` 与 `status.userLabel`。轮询的职责是"什么时候值得再去看一眼"，
        /// 它从不判定失败（连读到 `failed` 那一档，也只是把"该收口了"交出去，
        /// 那句失败话术仍归载荷那一份）。字段留在这里，
        /// 是为了让"到上限 ⇒ 说失败"这种改法在**用例**上撞死，而不是在注释里被劝退。
        public let claimsFailure: Bool
        public let reason: Reason

        init(
            writesJob: Bool,
            writesCandidates: Bool,
            settles: Bool,
            stops: Bool,
            reason: Reason
        ) {
            self.writesJob = writesJob
            self.writesCandidates = writesCandidates
            self.settles = settles
            self.stops = stops
            self.claimsFailure = false
            self.reason = reason
        }
    }

    /// 一次轮询观测 ⇒ 该做什么。
    ///
    /// 判序**每一条都有理由**（用例按这条顺序钉）：
    /// 1. **先让位给流**：`busy` 期间屏上那两份状态是上一轮的载荷，轮询写它就是抢主人；
    /// 2. **再问预算**：到上限就停，且停在"什么都没改"上（见 `.capReached` 那段）；
    /// 3. **读到没有**：单次失败不杀腿（网络抖动不等于任务失败，19 屏同一口径）；
    /// 4. **终态排在"与屏上一致"之前**：一条腿绝不该在任务已经结束时继续投到上限 ——
    ///    屏上的跟踪状态理论上不会以终态开局（`canArm` 挡着），真的出现了就只收口一次
    ///    （`.alreadySettled` 那一档连收口都不做），而不是变成第二次轮询；
    /// 5. 相同 ⇒ 不换行；不同且未终态 ⇒ 换行。两档的清单判据都只有一个来源：
    ///    `Observation.carriesCandidates`（行里带着非空候选才允许上屏）。
    public static func decide(
        previous: GenerationJobStatus?,
        observation: Observation,
        streamMidRound: Bool,
        attempt: Int,
        schedule: StudioCreatePollSchedule = StudioCreatePollSchedule()
    ) -> Decision {
        if streamMidRound {
            return Decision(
                writesJob: false, writesCandidates: false, settles: false,
                stops: true, reason: .streamOwnsRound
            )
        }
        if !schedule.shouldPoll(attempt: attempt) {
            return Decision(
                writesJob: false, writesCandidates: false, settles: false,
                stops: true, reason: .capReached
            )
        }
        guard let status = observation.status else {
            return Decision(
                writesJob: false, writesCandidates: false, settles: false,
                stops: false, reason: .noObservation
            )
        }
        if status.isTerminal {
            guard status != previous else {
                // 同一个终态读第二遍不构成第二次收口：屏上已经收过，环也已经摘掉了。
                return Decision(
                    writesJob: false, writesCandidates: false, settles: false,
                    stops: true, reason: .alreadySettled
                )
            }
            return Decision(
                writesJob: true,
                writesCandidates: observation.carriesCandidates,
                settles: true,
                stops: true,
                reason: .terminalObserved
            )
        }
        if status == previous {
            // 状态没动也可能有别的东西到了（worker 把两张占位卡写进 metadata 而 status 不变）
            // ⇒ 清单这一维**不**跟着"状态相同"一起免写，但它仍然只认"行里带着非空候选"。
            return Decision(
                writesJob: false,
                writesCandidates: observation.carriesCandidates,
                settles: false,
                stops: false,
                reason: .unchanged
            )
        }
        return Decision(
            writesJob: true,
            writesCandidates: observation.carriesCandidates,
            settles: false,
            stops: false,
            reason: .advanced
        )
    }

    /// 这条腿该不该在屏上跑起来：三件**缺一不可**。
    ///
    /// · 没有任务号 ⇒ 没有任何东西可投（不猜、不拿会话号当任务号）；
    /// · 本机正在读这一轮的流 ⇒ 主人是流（跑起来也只是抢着写同一件事，见 `decide` 第 1 条）；
    /// · 屏上那一行已经终态 ⇒ 这一轮完了，继续投就是拿预算去问一件已经有答案的事。
    /// 「屏在不在」这一件**不在这里判**：它是视图生命周期（`.task` / `.onDisappear`）的事，
    /// 本层看不见屏幕，硬要判就得给 CovaCore 引 UI —— 那是本仓禁止的方向。
    public static func canArm(
        jobID: String?,
        status: GenerationJobStatus?,
        streamMidRound: Bool
    ) -> Bool {
        guard !streamMidRound else { return false }
        guard let id = jobID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return false
        }
        return status?.isTerminal != true
    }
}

/// 后端 6 态里"这一路完了"的那三个。
///
/// 为什么不另立一套：`AISessionDetailView.roundIsSettled` 已经用这三个 case 判终态，
/// 轮询再写一份 `switch` 就是同一件事的第二个口径（漂移只是时间问题）。
/// `queued / submitted / processing` 是"服务端还在动它"，与 `StudioTerminalNotification`
/// 那本「候选都 settled 才算真终态」的账不冲突 —— 那一本账照旧由 D7 判，这里只回答
/// "这一路还要不要再问"。
extension GenerationJobStatus {
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        case .queued, .submitted, .processing: return false
        }
    }
}
