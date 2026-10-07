import CovaCore
import CovaUI
import SwiftUI
import UIKit

/// 登录（design 10）：邮箱 + 密码 + 游客入口。
/// 失败文案区分「凭证错 / 需要网页端继续验证 / 离线 / 其它」，不指认后端欠账；
/// 密码框 `secureContent`，
/// **密码只经 `SecretString` 交给 AuthSession，不进任何 @State 之外的地方**。
public struct LoginView: View {
    @Environment(AppSession.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

    public init() {}

    public var body: some View {
        VStack(spacing: CovaSpace.xl) {
            Spacer()
            VStack(spacing: CovaSpace.xs) {
                Text("Cova").font(CovaType.largeTitle).foregroundStyle(CovaColor.accent)
                Text("AI 音乐商用授权").font(CovaType.callout).foregroundStyle(CovaColor.secondary)
            }
            VStack(spacing: CovaSpace.md) {
                field("邮箱", text: $email, secure: false)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                field("密码", text: $password, secure: true)
                    .textContentType(.password)
                // 10 §3.H：登录是 hero CTA 档（gradient.brandButton），不走中性玻璃。
                CovaButton("登录", style: .brand, isLoading: busy) { Task { await signIn() } }
                // 10 §4「先随便看看」：游客入口也在这张 sheet 里 ⇒ 点了同样要收 sheet，
                // 不然用户「进去了」却还被登录页盖着。
                CovaButton("先随便看看", style: .secondary) {
                    Task {
                        await session.continueAsGuest()
                        session.loginPresented = false
                    }
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            if case .failed(let message) = session.authPhase {
                Text(message)
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CovaSpace.pageGutter)
            }
            Spacer()
        }
        .covaPage()
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(placeholder, text: text) }
            else { TextField(placeholder, text: text) }
        }
        .font(CovaType.body)
        .foregroundStyle(CovaColor.fg)
        .padding(CovaSpace.md)
        .background(RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous).fill(CovaColor.surface))
        .overlay(
            RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                .strokeBorder(CovaColor.line, lineWidth: 0.5)
        )
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        await session.signIn(email: email, password: password)
        password = ""
        // 登录成功这张 sheet 就没有存在的理由了（失败留在原地，错误文案仍在屏上）。
        if case .signedIn = session.authPhase { session.loginPresented = false }
    }
}

// MARK: - 套餐四档中文的唯一源（11 §8）

public extension CovaPlan {
    /// 11 §8：「套餐四档中文（**全站唯一源**，13 会员页与 04 引用本表）」：
    /// free 免费版 / creator 创作版 / pro 专业版 / enterprise 企业版。
    ///
    /// 挂在这个类型自己身上，而不是留在某一屏的 `body` 里：上一版 11 屏写的是
    /// `Text("计划：\(me.entitlements.plan.rawValue)")` ⇒ 屏上印出「计划：pro」。
    /// `rawValue` 是 wire 值（解码/上报用），只有显示面走这里 —— 与 `LoopMode.userLabel`、
    /// `PlayerFailure.Kind.userLabel` 同一族、同一个闭法。
    var userLabel: String {
        switch self {
        case .free: return "免费版"
        case .creator: return "创作版"
        case .pro: return "专业版"
        case .enterprise: return "企业版"
        }
    }
}

// MARK: - 11 屏的上屏串与读法（纯函数，可测）

/// 11 §3/§6/§7/§8 的**文案与读法裁决面**。
///
/// 为什么单独一层：§6 把 VoiceOver 串逐字钉死（「余额，128 co，仅展示」/「版本 0.2.24，第 35 版」
/// /「covaId，CV 8 F 2 K 3 A，可复制」），§7/§验收 又钉了「缺字段就**不渲染**、余额缺就显 `--`
/// 而不是 0」这种"什么时候根本不该有这行"的判据。两条都是错了会骗人的口径，埋在 `body` 里
/// 就没有任何用例能钉 —— 所以视图只负责摆，话在这里说。
public enum MineCopy {
    /// TG-29「数值占位符（`--`）」档未入库 ⇒ 本屏唯一认的占位串。
    public static let unknownValue = "--"

    /// 余额数值位（11 §3.C + §7 NEEDS-3 + §8 零值/异常值）。
    ///
    /// · `nil`（`/me` 没回来 / `creditsBalance` 缺）→ `--`，**绝不显 0**：把「没取到」印成
    ///   「0 co」是催促用户去充值的最短路径，而 §8 明令 0 与满值同构、`--` 与 0 语义不同。
    /// · 负数 → `--`（§8：可疑数字不上屏）。
    /// · 真正的 0 → 「0」：真实零值 ≠ 无数据。
    /// 「异常大值」没有阈值档（§8 未给数、TG 未入库）⇒ 不自造阈值，原样显。
    public static func balance(_ raw: Int?) -> String {
        guard let raw, raw >= 0 else { return unknownValue }
        return "\(raw)"
    }

    /// §6：「余额，128 co，仅展示」——`仅展示` 是 D12 的读法落点（余额只读、无充值入口）。
    public static func balanceSpoken(_ raw: Int?) -> String {
        "余额，\(balance(raw)) co，仅展示"
    }

    /// §6：「当前套餐，创作版」。
    public static func planSpoken(_ plan: CovaPlan) -> String {
        "当前套餐，\(plan.userLabel)"
    }

    /// 11 §3.C / 13 §3.B 的有效期行：ISO8601 → 「有效期至 YYYY年M月D日」。
    /// 取不到/解析不出 → **nil（整行不渲染）**：free 档本就无有效期，留空行才是实话。
    public static func expiryText(_ raw: String?) -> String? {
        guard let date = expiryDateText(raw) else { return nil }
        return "有效期至 \(date)"
    }

    /// 只要日期部分（13 §3.B 的副行与 11 的「有效期至」共用同一个解析器）。
    public static func expiryDateText(_ raw: String?) -> String? {
        guard let raw, raw.isEmpty == false else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        out.dateFormat = "yyyy年M月d日"
        return out.string(from: date)
    }

    /// §3.H：版本行的**显示值** = `CFBundleShortVersionString (CFBundleVersion)`。
    /// 任一键缺失 → nil ⇒ 整行不渲染（§7 版本来源是本地 Bundle，缺键就是装配出错，
    /// 而印一个「版本 —」等于把装配缺陷伪装成产品信息）。
    public static func versionValue(short: String?, build: String?) -> String? {
        guard let short = filled(short), let build = filled(build) else { return nil }
        return "\(short) (\(build))"
    }

    /// §6 第 12 项：「版本 0.2.24，第 35 版」——build 号读成「第 N 版」，
    /// 免得 VoiceOver 把括号里的数字念成无意义的尾数。
    public static func versionSpoken(short: String?, build: String?) -> String? {
        guard let short = filled(short), let build = filled(build) else { return nil }
        return "版本 \(short)，第 \(build) 版"
    }

    /// 从 Bundle 取两枚版本键（§7：本地 `Bundle`，非 API）。
    public static func bundleVersion(in bundle: Bundle = .main) -> (short: String?, build: String?) {
        let info = bundle.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String, info?["CFBundleVersion"] as? String)
    }

    /// §6：「Cova 号，CV 8 F 2 K 3 A，可复制」的**读法串**（整行一条）。
    /// 标签说人话，不说字段名（2026-10-01 C3：字段名只活在代码里，不上屏不进读屏）。
    public static func covaIdRowSpoken(_ raw: String) -> String {
        "Cova 号，\(covaIdSpoken(raw))，可复制"
    }

    /// 可读化本体：分隔符一律断开；**首段若是纯字母前缀（`CV`）整段保留**，其后逐字符断开。
    /// `type.mono` 只是呈现档，VoiceOver 拿到原始 `CV-8F2K3A` 会把整串当一个词吞掉（§6）。
    /// 没有字母前缀可保的形状（如 `CV8F2K3A`）⇒ 全部逐字符：spec 只钉了带连字符那一种读法，
    /// 这里不假装认识没被钉过的形状。
    public static func covaIdSpoken(_ raw: String) -> String {
        let groups = raw.split(whereSeparator: { $0.isLetter == false && $0.isNumber == false })
        guard let head = groups.first else { return raw }
        let parts: [String]
        if head.allSatisfy({ $0.isLetter }) {
            parts = [String(head)] + groups.dropFirst().flatMap { Array($0).map(String.init) }
        } else {
            parts = groups.flatMap { Array($0).map(String.init) }
        }
        return parts.joined(separator: " ")
    }

    /// §6：商业组两行是普通站内导航（13/14 都在 App 内），读法 = 行标签本身。
    /// （2026-10-01 D12 修订：不再有「前往官网了解」的右值——那行字暗示交易在站外。）
    public static func commerceSpoken(_ title: String) -> String {
        title
    }

    private static func filled(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 11 §3.C 的套餐徽标色（`components.md` §9「套餐徽标：会员=memberGold 系 / 企业=enterpriseBlue 系」，
/// free = `color.muted` 描边）。双主题的深浅两值**全部由 token 给**，这里不挑色（11 §5 红线）。
public enum PlanBadge {
    public static func foreground(_ plan: CovaPlan) -> Color {
        switch plan {
        case .enterprise: return CovaColor.enterpriseBlue
        case .free: return CovaColor.muted
        case .creator, .pro: return CovaColor.memberGold
        }
    }

    public static func background(_ plan: CovaPlan) -> Color {
        switch plan {
        case .enterprise: return CovaColor.enterpriseBlueSoft
        case .free: return .clear
        case .creator, .pro: return CovaColor.memberGoldSoft
        }
    }

    public static func border(_ plan: CovaPlan) -> Color {
        switch plan {
        case .enterprise: return CovaColor.enterpriseBlueBorder
        case .free: return CovaColor.muted
        case .creator, .pro: return CovaColor.memberGoldBorder
        }
    }
}

/// TG-03/04/05 三档在 G2 都还没入库，值先收在这里，不散落裸字面量。
private enum MineMetrics {
    static let avatarSize: CGFloat = 44
    static let touchMin: CGFloat = 44
    static let hairline: CGFloat = 1
}

/// 「我的」（design 11）：**页签根屏**（04 §2），容器 = `List` + `.insetGrouped`
/// （11 §2：组圆角/行分隔/底色交系统件，不再自绘 elevated+line 卡边）。
/// 组序 = 账号 → 余额与套餐 → 签到（C2，独立组）→ 我的资产 → 商业 → 其他。
/// 登出行**不在这里**（登出归 15 设置）；游客态本屏不渲染（04 §6 根区 = 17-S6 引导，
/// 由外壳接管）。**D12**：全屏无充值/购买/升级字样，余额只读、整组不可点；
/// 资产计数行右侧值整项不构造（§7 v1.0：无聚合计数端点）。
public struct MineView: View {
    @Environment(AppSession.self) private var session
    /// 11 §6 Dynamic Type：组 2 的套餐徽标在 AX 档换到「余额」标签上方；
    /// 组 1 邮箱在 AX 档并入 Cova 号行。
    @Environment(\.covaAXLayout) private var axLayout
    /// §5 P3 每日签到：这一格的状态由**服务端两格真值**拼出来（`DailyCheckinRule`），
    /// 读不懂就是 `.unknown` ⇒ 整枚不出现，不摆一枚点了不会给任何东西的钮。
    @State private var checkin: DailyCheckinBoard = .unknown
    @State private var checkinBusy = false
    @State private var checkinNote: String?

    public init() {}

    /// 认证阶段的变化键：登录/登出/换号都要重新取一次 `/me`。
    private var authPhaseKey: String {
        switch session.authPhase {
        case .restoring: return "restoring"
        case .guest: return "guest"
        case .failed: return "failed"
        case .signedIn(let user): return "signedIn:\(user.id)"
        }
    }

    private var entitlements: Entitlements? { session.me?.entitlements }
    private var user: AuthUser? { session.meUser }

    public var body: some View {
        Group {
            if case .signedIn = session.authPhase {
                if session.meState == .outOfSync, session.me == nil {
                    // §4 错误腿：无缓存且失败 → 整屏 17-S3「账号信息没取到」+「重试」
                    // （组 1/2 的全部内容都出自 `/me`，没有缓存就没有可展示的组）。
                    meErrorFallback
                } else {
                    listBody
                }
            }
            // 游客/.failed/.restoring ⇒ 什么都不渲染：04 §6 的引导形态由外壳（GuestGuideView）
            // 接管，本屏不出现 B/C/D/E/F 任何一组。
        }
        .navigationTitle("我的")
        .toolbarTitleDisplayMode(.large)
        // `/me` 的账本在 `AppSession`（11 §7）：这里只按认证阶段变化触发一次，
        // `loadMe` 自己会合并同身份的重复请求。
        .task(id: authPhaseKey) {
            await session.loadMe()
            await loadCheckin()
        }
    }

    /// §7：下拉刷新 = 重取 `me`（force）+ 重读签到两格真值。
    private var listBody: some View {
        List {
            accountSection
            balanceSection
            checkinSection
            assetsSection
            commerceSection
            othersSection
        }
        .listStyle(.insetGrouped)
        // §5：组底色/分隔线由系统 insetGrouped 承担；页面底仍走 `color.canvas`
        // （List 默认的 systemGroupedBackground 会盖住页面色 ⇒ 让背景透出 canvas）。
        .scrollContentBackground(.hidden)
        .covaPage()
        .refreshable {
            await session.loadMe(force: true)
            await loadCheckin()
        }
    }

    private var meErrorFallback: some View {
        VStack(spacing: CovaSpace.md) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(CovaSymbol.state)
                .foregroundStyle(CovaColor.error.opacity(0.8))
                .accessibilityHidden(true)
            Text("账号信息没取到").font(CovaType.headline).foregroundStyle(CovaColor.fg)
            CovaButton("重试", style: .secondary) {
                Task { await session.loadMe(force: true) }
            }
            .frame(maxWidth: 180)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .covaPage()
    }

    // MARK: 组 1 账号（§3.B：单行——头像 + 名字 + Cova 号 + 邮箱，无 header）

    /// §3.B/§6：行内件 = 头像 44 + 名字 + Cova 号 + 邮箱。整行**不是**按钮 ——
    /// §6 的朗读顺序要四停（头像「用户头像」→ 名字 → Cova 号「…可复制」→ 邮箱），
    /// 行级 Button 会把它们压成一停。「复制 Cova 号」挂在 Cova 号那一行件上：
    /// 点按 / 长按菜单 / VoiceOver 自定义动作三条路同一动作（§6）。
    /// **组不设 header**：A 大标题已承担层级，组标题只为多行组服务。
    @ViewBuilder
    private var accountSection: some View {
        Section {
            HStack(alignment: .center, spacing: CovaSpace.md) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(user?.name ?? "")
                        .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                        .lineLimit(1)
                    // §7 NEEDS-1：`covaId` 缺 → 行内件不渲染（不显 `--`、不用 `user.id` 冒充）。
                    if let covaId {
                        Button {
                            UIPasteboard.general.string = covaId
                        } label: {
                            // §3.B：前缀「Cova 号」caption/muted，值 mono/secondary；
                            // 标签说人话不说字段名（2026-10-01 C3）。§8：不截断，超长 2 行。
                            Text("Cova 号 \(Text(covaId).font(CovaType.mono).foregroundStyle(CovaColor.secondary))")
                                .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: MineMetrics.touchMin, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(MineCopy.covaIdRowSpoken(covaId))
                        // 长按菜单与 §6 的自定义动作并存：三条路（点按 / 长按 / VoiceOver 动作）都是复制。
                        .contextMenu {
                            Button("复制 Cova 号") { UIPasteboard.general.string = covaId }
                        }
                        .accessibilityAction(named: "复制 Cova 号") {
                            UIPasteboard.general.string = covaId
                        }
                    }
                    // §6 AX 档：邮箱并入本行（与 Cova 号同一行内栈），非 AX 档也在行内第三行。
                    if let email = user?.email, !email.isEmpty {
                        Text(email)
                            .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                            .lineLimit(axLayout ? 2 : 1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: CovaSpace.sm)
            }
        }
    }

    /// §3.B：契约无 `avatar` 字段 ⇒ 恒为首字母占位（surface 底 + accentText 字，TG-05 档 44pt）。
    private var avatar: some View {
        let initial = String((user?.name ?? "").prefix(1))
        return ZStack {
            Circle().fill(CovaColor.surface)
            if !initial.isEmpty {
                Text(initial).font(CovaType.headline).foregroundStyle(CovaColor.accentText)
            }
        }
        .frame(width: MineMetrics.avatarSize, height: MineMetrics.avatarSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("用户头像")
    }

    private var covaId: String? {
        guard let id = user?.covaId, !id.isEmpty else { return nil }
        return id
    }

    // MARK: 组 2 余额与套餐（§3.C，D12：整组只读、不可点、无按钮）

    @ViewBuilder
    private var balanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                if axLayout {
                    // §6 AX 档：徽标换到「余额」标签**上方**。
                    if let plan = entitlements?.plan { planBadge(plan) }
                    balanceLabel
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        balanceLabel
                        Spacer(minLength: CovaSpace.sm)
                        if let plan = entitlements?.plan { planBadge(plan) }
                    }
                }
                balanceValue
                // §3.C 有效期行：缺 `activeUntil` ⇒ 整行不渲染（free 档本就无有效期）。
                if let expiry = MineCopy.expiryText(entitlements?.activeUntil) {
                    Text(expiry).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                }
            }
            // 整组不可点（D12）：行是纯展示，不挂任何动作。
            .accessibilityElement(children: .contain)
        }
    }

    private var balanceLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
            Text("余额").font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            // §4：`me` 最近一次失败但手里还有旧值 → 行内一次性「未同步」（不弹 Toast、不整屏）。
            if session.meState == .outOfSync, entitlements != nil {
                Text("未同步").font(CovaType.caption).foregroundStyle(CovaColor.muted)
            }
        }
    }

    private var balanceValue: some View {
        HStack(alignment: .lastTextBaseline, spacing: CovaSpace.sm) {
            Text(MineCopy.balance(entitlements?.creditsBalance))
                .font(CovaType.largeTitle)
                .foregroundStyle(CovaColor.fg)
                // §6/§验收第 6 条：AX 档下数值**不放大**（`type.largeTitle` 保持设计档），
                // 标签与有效期行照常放大 —— 放大后 `--`/三位数会把行撑破，那是假的稳。
                .dynamicTypeSize(DynamicTypeSize.large)
                .monospacedDigit()
            Text("co").font(CovaType.callout).foregroundStyle(CovaColor.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MineCopy.balanceSpoken(entitlements?.creditsBalance))
    }

    /// §3.C + components §9：`plan` 缺 → 整枚不渲染（`/me` 没回来时就属此列）。
    private func planBadge(_ plan: CovaPlan) -> some View {
        Text(plan.userLabel)
            .font(CovaType.caption)
            .foregroundStyle(PlanBadge.foreground(plan))
            .padding(.horizontal, CovaSpace.sm)
            .padding(.vertical, CovaSpace.xs)
            .background(Capsule().fill(PlanBadge.background(plan)))
            .overlay(Capsule().strokeBorder(PlanBadge.border(plan), lineWidth: MineMetrics.hairline))
            .accessibilityLabel(MineCopy.planSpoken(plan))
    }

    // MARK: C2 每日签到（§5 P3）：组 2 之下、组 3 之上的**独立组**

    /// 缺席的三种情况合并成一格：没读到、读不懂、额度被配成 0
    /// （`DailyCheckinRule.board` 都折成 `.unknown`）。
    /// 已签过的那一态是**一行说明**，不是一枚点下去什么也不会发生的钮。
    @ViewBuilder
    private var checkinSection: some View {
        if let title = DailyCheckinRule.actionTitle(checkin) {
            Section {
                if checkin == .done {
                    HStack(spacing: CovaSpace.sm) {
                        Image(systemName: "checkmark.circle")
                            .font(CovaSymbol.status).foregroundStyle(CovaColor.success)
                        Text(title).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Button {
                        Task { await checkIn() }
                    } label: {
                        HStack(spacing: CovaSpace.md) {
                            Image(systemName: "giftcard")
                                .font(CovaType.callout).foregroundStyle(CovaColor.secondary)
                                .accessibilityHidden(true)
                            Text(title).font(CovaType.headline).foregroundStyle(CovaColor.fg)
                            Spacer(minLength: CovaSpace.sm)
                            if checkinBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: MineMetrics.touchMin, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(checkinBusy)
                }
                if let note = checkinNote {
                    Text(note).font(CovaType.caption).foregroundStyle(CovaColor.error)
                }
            }
        }
    }

    private func loadCheckin() async {
        guard case .signedIn = session.authPhase else {
            checkin = .unknown
            return
        }
        let read = try? await session.checkinService.state()
        checkin = DailyCheckinRule.board(from: read)
    }

    private func checkIn() async {
        guard !checkinBusy else { return }
        checkinBusy = true
        defer { checkinBusy = false }
        do {
            let receipt = try await session.checkinService.checkIn()
            checkin = DailyCheckinRule.board(fromResult: receipt)
            // 失败只说"没签到"这一件事实：服务端对失败没有机器可读的码，
            // 编一句"额度已发完"就是替后端写文案。
            checkinNote = receipt.succeeded ? nil : "这次没签到，可以再来一次"
            // 余额是另一本账，签完必须重读。这里**要 force**：`loadMe` 对「同身份 + 已 synced」的读
            // 直接 return，不 force 就是签完了屏上还是旧余额（§7 #53 的成因）。
            if receipt.succeeded { await session.loadMe(force: true) }
        } catch {
            checkinNote = "这次没签到，可以再来一次"
        }
    }

    // MARK: 组 3 我的资产（§3.D 原生 inset 行；§7 v1.0：右侧计数整项不构造）

    private var assetsSection: some View {
        Section("我的资产") {
            navRow(title: "收藏", symbol: "heart") { session.push(.favorites) }
            navRow(title: "我的歌单", symbol: "list.bullet") { session.push(.myPlaylists) }
            // 12c「我的创作」= 我的栈内 push（04 §3 归属表）；
            // 它自己的「查看全部创作」才跨栈去 08。
            navRow(title: "我的创作", symbol: "sparkles") { session.push(.myCreations) }
            // 22「co 变动明细」：组 2 整组不可点（D12），流水入口落在资产组这一排。
            // 文案只用「co / 变动 / 明细」——「积分」是 A15 明令的漂移词。
            navRow(title: "co 变动明细", symbol: "list.bullet.rectangle") { session.push(.creditsLedger) }
            // 11 §3.D/§7：「已下载」行在 D12 合规放行前**整项不渲染**（不是置灰/禁用）；
            // §7 v1.0：各行右侧**资产计数整项不构造**（无聚合计数端点，不显 `--`/0）。
        }
    }

    // MARK: 组 4 商业（§3.E：memberGold / enterpriseBlue 色行，右值普通 chevron）

    private var commerceSection: some View {
        Section("商业") {
            // §1 互链：会员 → 13、企业服务 → 14（外跳动作在 13/14 自己身上，本屏不发）。
            navRow(
                title: "会员权益", symbol: "star.fill",
                symbolColor: CovaColor.memberGold, titleColor: CovaColor.memberGold,
                accessibilityLabel: MineCopy.commerceSpoken("会员权益"),
                trailing: { commerceTrailing }
            ) { session.push(.membership) }
            navRow(
                title: "企业服务", symbol: "building.2",
                symbolColor: CovaColor.enterpriseBlue, titleColor: CovaColor.enterpriseBlue,
                accessibilityLabel: MineCopy.commerceSpoken("企业服务"),
                trailing: { commerceTrailing }
            ) { session.push(.enterprise) }
        }
    }

    // MARK: 组 5 其他（F 设置入口 → 15；G 关于行只读）

    private var othersSection: some View {
        Section("其他") {
            navRow(title: "设置", symbol: "gearshape") { session.push(.settings) }
            aboutRow
        }
    }

    /// §3.G + §6 末项：版本行**只读**（无 chevron、不可点），显示值正是 `project.yml` 的两枚键。
    @ViewBuilder
    private var aboutRow: some View {
        if let version = MineCopy.versionValue(
            short: MineCopy.bundleVersion().short, build: MineCopy.bundleVersion().build
        ) {
            HStack(spacing: CovaSpace.md) {
                Image(systemName: "info.circle")
                    .font(CovaType.callout).foregroundStyle(CovaColor.secondary)
                    .accessibilityHidden(true)
                Text("版本").font(CovaType.headline).foregroundStyle(CovaColor.fg)
                Spacer(minLength: CovaSpace.sm)
                Text(version).font(CovaType.subhead).foregroundStyle(CovaColor.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                MineCopy.versionSpoken(
                    short: MineCopy.bundleVersion().short, build: MineCopy.bundleVersion().build) ?? "版本")
        }
    }

    // MARK: 行零件（§3.D 的原生 inset 行几何）

    /// insetGrouped 里的一行导航项：符号 + 标签 + chevron（§3.D）。
    /// 用 `Button` 而不用 `NavigationLink`：行内件字体/颜色按 spec 自定（headline/fg），
    /// 且商业组要带自定义右值 —— 统一一种构造，不再为「原生 disclosure」单开一份行几何。
    private func navRow<Trailing: View>(
        title: String,
        symbol: String,
        symbolColor: Color = CovaColor.secondary,
        titleColor: Color = CovaColor.fg,
        accessibilityLabel: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CovaSpace.md) {
                Image(systemName: symbol)
                    .font(CovaType.callout).foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(CovaType.headline).foregroundStyle(titleColor)
                    // §8/§6：值不许截断（截断即失效）—— 换行消化。
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CovaSpace.sm)
                trailing()
            }
            .frame(maxWidth: .infinity, minHeight: MineMetrics.touchMin, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel ?? title)
    }

    private func navRow(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        navRow(title: title, symbol: symbol, trailing: { chevron }, action: action)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
            .accessibilityHidden(true)
    }

    private var commerceTrailing: some View {
        // 2026-10-01 D12 修订：13/14 都是站内屏，右值回归普通 chevron —
        // 「前往官网」+外链符会暗示这笔交易在站外完成。
        chevron
    }
}

/// 11 §3.E/F/G 与 14 §3.E 共用的「链接行」（TG-38 建议把它收进 `components.md`，
/// 落库前先住在本文件 —— 两处各写一遍行几何，就会有两套"行高/符号色/读法"漂移）。
///
/// 「一行 = 一个元素」（11 §6 / 14 §6）：符号与右值不进朗读序列，
/// 读法整条由 `accessibilityLabel` 给（§6 钉的是逐字串，不是系统拼出来的默认组合）。
public struct CovaLinkRow<Trailing: View>: View {
    private let title: String
    private let symbol: String
    private let symbolColor: Color
    private let titleColor: Color
    private let titleFont: Font
    private let minHeight: CGFloat
    private let gutter: CGFloat
    private let spoken: String
    @ViewBuilder private let trailing: Trailing
    private let action: () -> Void

    public init(
        title: String,
        symbol: String,
        symbolColor: Color = CovaColor.secondary,
        titleColor: Color = CovaColor.fg,
        titleFont: Font = CovaType.headline,
        minHeight: CGFloat = 52,     // TG-19：分组列表行最小高档（11 §3.E）
        gutter: CGFloat = CovaSpace.pageGutter,
        accessibilityLabel: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.titleColor = titleColor
        self.titleFont = titleFont
        self.minHeight = minHeight
        self.gutter = gutter
        self.spoken = accessibilityLabel ?? title
        self.trailing = trailing()
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: CovaSpace.md) {
                Image(systemName: symbol)
                    .font(CovaType.callout).foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(titleFont).foregroundStyle(titleColor)
                    // §8/§6：地址与 covaId **不许截断**（截断即失效）—— 常规档换行，
                    // 比把 `enterprise@covalink.cn` 印成 `enterprise@cova…` 诚实。
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CovaSpace.sm)
                trailing
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, CovaSpace.md)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }
}

/// §3.E 的行分隔：`color.lineSubtle` 1pt（TG-04），**首行不加**（由调用侧的位置保证）。
struct CovaRowDivider: View {
    var body: some View {
        Divider().overlay(CovaColor.lineSubtle).padding(.leading, CovaSpace.pageGutter)
    }
}
