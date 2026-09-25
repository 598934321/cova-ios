import CovaCore
import CovaUI
import SwiftUI
import UIKit

/// 登录（design 10）：邮箱 + 密码 + 游客入口。
/// 失败文案区分「凭证错 / 网络 / 后端缺口(NEEDS-1)」；密码框 `secureContent`，
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
                CovaButton("登录", isLoading: busy) { Task { await signIn() } }
                CovaButton("先随便看看", style: .secondary) { Task { await session.continueAsGuest() } }
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

    /// §6：「covaId，CV 8 F 2 K 3 A，可复制」的**读法串**（整行一条）。
    public static func covaIdRowSpoken(_ raw: String) -> String {
        "covaId，\(covaIdSpoken(raw))，可复制"
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

    /// §6：F 商业组的行读成「会员权益，前往官网了解」（§3.F 的右值就是这句话）。
    public static func commerceSpoken(_ title: String) -> String {
        "\(title)，前往官网了解"
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

/// 「我的」（design 11）：B 用户卡 / C 余额与套餐卡 / D-E 资产入口 / F 商业组 / G 设置 / H 关于。
///
/// **D12（11 §验收第 1 条）**：全屏无充值/购买/升级字样与按钮，余额只读，C 卡整卡**不可点**；
/// 余额 0 与余额 128 的布局完全同构（没有任何催促文案）。
/// **「我的」计数行整项不构造**（§7 v1.0 裁决：无聚合计数端点）——不是显 `--`，是右值不存在。
public struct MineView: View {
    @Environment(AppSession.self) private var session
    /// 11 §6 Dynamic Type：C 卡的套餐徽标在 AX 档换到「余额」标签上方。
    @Environment(\.covaAXLayout) private var axLayout

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
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.xl) {
                identity
                balanceCard
                assets
                commerce
                others
            }
            .padding(.vertical, CovaSpace.xl)
        }
        .covaPage()
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        // `/me` 的账本在 `AppSession`（04 抽屉 G 区与本页读**同一份**）：
        // 这里只按认证阶段变化触发一次，`loadMe` 自己会合并同身份的重复请求。
        .task(id: authPhaseKey) { await session.loadMe() }
    }

    // MARK: B 用户卡（§3.B：**无卡底**，直接铺在 canvas 上，免得与 C 卡双层抬升）

    @ViewBuilder
    private var identity: some View {
        switch session.authPhase {
        case .signedIn:
            VStack(alignment: .leading, spacing: CovaSpace.md) {
                HStack(alignment: .center, spacing: CovaSpace.md) {
                    avatar
                    VStack(alignment: .leading, spacing: CovaSpace.xs) {
                        Text(user?.name ?? "")
                            .font(CovaType.largeTitle).foregroundStyle(CovaColor.fg)
                            .lineLimit(1)
                    }
                    Spacer(minLength: CovaSpace.sm)
                }
                // §7 NEEDS-1：`covaId` 缺 → **整行不渲染**（不显 `--`、不用 `user.id` 冒充）。
                if let covaId = user?.covaId, covaId.isEmpty == false {
                    covaIdRow(covaId)
                }
                // §3.B 邮箱：独立一行，中段截断保留域名（`middle` 由 lineLimit+truncationMode 给）。
                if let email = user?.email, email.isEmpty == false {
                    Text(email)
                        .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                // `/me` 的失败**必须可见**（原先 `try?` 把 401 与真出错一起吞成 nil）：
                // 有旧值时 §4 走 C 卡的行内「未同步」，无旧值时才在这里说「没取到」+重试。
                if session.meState == .outOfSync, entitlements == nil {
                    HStack(spacing: CovaSpace.sm) {
                        Text("账号信息没取到")
                            .font(CovaType.subhead).foregroundStyle(CovaColor.error)
                        Button("重试") { Task { await session.loadMe(force: true) } }
                            .font(CovaType.subhead).foregroundStyle(CovaColor.accentText)
                            .buttonStyle(.plain)
                            .frame(minHeight: MineMetrics.touchMin)
                    }
                }
                CovaButton("登出", style: .secondary) { Task { await session.signOut() } }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
        default:
            CovaCard {
                VStack(spacing: CovaSpace.md) {
                    Text("未登录").font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    Text("登录后可收藏、下载与上报播放。").font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    CovaButton("去登录") { session.loginPresented = true }
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
        }
    }

    /// §3.B：契约无 `avatar` 字段 ⇒ v1.0 恒为首字母占位（surface 底 + accentText 字，04 §3.G 同档 44pt）。
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

    /// §6：双击复制 + 自定义动作「复制 covaId」；给了复制动作 ⇒ 热区 ≥44（§6 末条）。
    private func covaIdRow(_ covaId: String) -> some View {
        Button {
            UIPasteboard.general.string = covaId
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.xs) {
                // §3.B：前缀「covaId」是 caption/muted 的**标签**，值才是 mono/secondary。
                Text("covaId").font(CovaType.caption).foregroundStyle(CovaColor.muted)
                Text(covaId).font(CovaType.mono).foregroundStyle(CovaColor.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: MineMetrics.touchMin, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MineCopy.covaIdRowSpoken(covaId))
        .accessibilityAddTraits(.isButton)
        // §6 的自定义动作与系统双击激活并存（客服/配对场景要的是"念得出的一条动作"）。
        .accessibilityAction(named: "复制 covaId") { UIPasteboard.general.string = covaId }
    }

    // MARK: C 余额与套餐卡（§3.C，**整卡不可点**：D12 的有意设计）

    @ViewBuilder
    private var balanceCard: some View {
        if case .signedIn = session.authPhase {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
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
            .padding(CovaSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .fill(CovaColor.elevated)
            )
            // TG-04：1pt `color.line` 边；阴影不加（页面内卡片，非浮动件）。
            .overlay(
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .strokeBorder(CovaColor.line, lineWidth: MineMetrics.hairline)
            )
            .padding(.horizontal, CovaSpace.pageGutter)
        }
    }

    private var balanceLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
            Text("余额").font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            // §4：`me` 最近一次失败但手里还有旧值 → 右上一次性「未同步」（不弹 Toast、不整屏）。
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
                // 标签与有效期行照常放大 —— 放大后 `--`/三位数会把卡撑破，那是假的稳。
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

    // MARK: D + E 我的资产（§7 v1.0：**计数行右侧值整项不构造**）

    private var assets: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            sectionTitle("我的资产")
            VStack(spacing: 0) {
                CovaLinkRow(title: "收藏", symbol: "heart") { chevron } action: { open(.favorites) }
                CovaRowDivider()
                CovaLinkRow(title: "我的歌单", symbol: "list.bullet") { chevron } action: { open(.myPlaylists) }
                CovaRowDivider()
                CovaLinkRow(title: "我的创作", symbol: "sparkles") { chevron } action: { open(.aiSessions) }
                // 11 §1/§3.E/§7：「已下载」行在 D12 合规放行前**整项不渲染**（与 04 §3.D 同一条裁决，
                // 不是置灰/禁用）：放行前给它一个入口，等于向用户承诺一个不存在的页面。
                // §7 v1.0 同样裁决：三行右侧的**资产计数整项不构造**（无聚合计数端点，
                // 不显 `--`、不显 0）—— 视图树里就没有那个元素。
            }
        }
    }

    // MARK: F 商业组

    private var commerce: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            sectionTitle("商业")
            // §3.F：同 E 行几何，但符号与标签用 memberGold / enterpriseBlue；右值 = 「前往官网了解」+ 外链符号。
            VStack(spacing: 0) {
                CovaLinkRow(
                    title: "会员权益", symbol: "star.fill",
                    symbolColor: CovaColor.memberGold, titleColor: CovaColor.memberGold,
                    accessibilityLabel: MineCopy.commerceSpoken("会员权益")
                ) {
                    commerceTrailing
                } action: {
                    // §1 互链：会员 → 13、企业服务 → 14（外跳动作在 13/14 自己身上，本屏不发）。
                    session.path.append(.membership)
                }
                CovaRowDivider()
                CovaLinkRow(
                    title: "企业服务", symbol: "building.2",
                    symbolColor: CovaColor.enterpriseBlue, titleColor: CovaColor.enterpriseBlue,
                    accessibilityLabel: MineCopy.commerceSpoken("企业服务")
                ) {
                    commerceTrailing
                } action: {
                    session.path.append(.enterprise)
                }
            }
        }
    }

    // MARK: G 设置入口 / H 关于行

    private var others: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            sectionTitle("其他")
            VStack(spacing: 0) {
                CovaLinkRow(title: "设置", symbol: "gearshape", accessibilityLabel: "设置") {
                    chevron
                } action: {
                    session.path.append(.settings)
                }
                aboutRow
            }
        }
    }

    /// §3.H + §6 末项：版本行**只读**（无 chevron、不可点），显示值正是 `project.yml` 的两枚键。
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
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.vertical, CovaSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                MineCopy.versionSpoken(
                    short: MineCopy.bundleVersion().short, build: MineCopy.bundleVersion().build) ?? "版本")
        }
    }

    // MARK: 行零件（§3.E 的通用几何）

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
            .accessibilityHidden(true)
    }

    private var commerceTrailing: some View {
        HStack(spacing: CovaSpace.xs) {
            Text("前往官网了解").font(CovaType.caption).foregroundStyle(CovaColor.muted)
            Image(systemName: "arrow.up.right.square")
                .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
        }
        .accessibilityHidden(true)   // 这句话已经在行的 accessibilityLabel 里了
    }

    private func sectionTitle(_ title: String) -> some View {
        // §3.D/F 分组标题：caption / muted，左右 pageGutter，下间距 md（由调用侧的 spacing 给）。
        Text(title)
            .font(CovaType.caption).foregroundStyle(CovaColor.muted)
            .padding(.horizontal, CovaSpace.pageGutter)
    }

    /// 需要登录的资产入口：游客点 → 弹登录（与 04 抽屉 `.gated` 同一出口，不静默禁用）。
    private func open(_ route: AppSession.Route) {
        if session.requireLoginForCollections() { session.path.append(route) }
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
