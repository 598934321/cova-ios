import CovaCore
import CovaUI
import SwiftUI

// MARK: - 13 会员（只读展示；D12：App 内不售卖）

/// 会员权益（design 13）。这一屏的**全部风险都在"说了不该说的话"**上，所以：
/// · B 卡只读、**卡内不放任何按钮**、整卡不可点；
/// · 未登录 ⇒ B 卡整卡不渲染（也不出现「登录后查看」这种引导卡）；
/// · 额度数字（30/200/800）**没有端点来源** ⇒ 渲染「—」+「额度以官网为准」，不编数；
/// · 脚注 F 必须逐字存在（缺失按 Critical 计）；
/// · 全屏文案（含 VoiceOver 标签）**禁止**出现：购买 / 充值 / 支付 / 立即开通 / 升级 /
///   订阅管理 / 付款 / 价格 / ¥ / 元/月 / 限时 / 优惠 / 恢复购买；
/// · `me` 取不到时**静默**（本屏按 spec 无骨架、无 Toast、无整屏错误态）。
public struct MembershipView: View {
    @Environment(AppSession.self) private var session
    @State private var entitlements: Entitlements?
    @State private var activeUntil: String?

    public init() {}

    /// 对比表的内容是**本地静态常量**（spec 明令：无端点）。这里只列「能力有没有」，
    /// 不列额度数字与任何金额；额度那一行统一给「额度以官网为准」。
    private static let rows: [(label: String, values: [String])] = [
        ("商用授权", ["支持", "支持", "支持", "定制"]),
        ("AI 生成（Cova AI）", ["支持", "支持", "支持", "定制"]),
        ("下载与扣费", ["不支持", "支持", "支持", "定制"]),
        ("企业项目申请", ["不支持", "不支持", "支持", "定制"]),
        ("每月额度", ["—", "—", "—", "—"]),
    ]

    private static let planNames = ["免费版", "创作版", "专业版", "企业版"]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.xl) {
                if let entitlements, case .signedIn = session.authPhase {
                    myPlanCard(entitlements)
                }
                comparison
                notes
                footer
            }
            .padding(.vertical, CovaSpace.lg)
        }
        .covaPage()
        .navigationTitle("会员权益")
        .navigationBarTitleDisplayMode(.inline)
        .task { await read() }
    }

    /// 只读卡：**内部没有任何按钮**，也不可点。
    private func myPlanCard(_ entitlements: Entitlements) -> some View {
        CovaCard {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                Text("当前套餐").font(CovaType.caption).foregroundStyle(CovaColor.muted)
                Text(Self.planName(for: entitlements.plan))
                    .font(CovaType.title).foregroundStyle(CovaColor.fg)
                // free 无有效期 ⇒ 副行整行不渲染（不是显示「—」，也不是显示未同步）。
                if let until = Self.expiryText(activeUntil) {
                    Text("有效期至 \(until)")
                        .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                }
                Text("剩余 co 币：\(entitlements.creditsBalance)")
                    .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            CovaSectionHeader("权益对比")
            VStack(spacing: 0) {
                HStack(spacing: CovaSpace.sm) {
                    Text(" ").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Self.planNames, id: \.self) { name in
                        Text(name).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                            .frame(width: 56)
                    }
                }
                .padding(.vertical, CovaSpace.xs)
                ForEach(Self.rows, id: \.label) { row in
                    HStack(spacing: CovaSpace.sm) {
                        Text(row.label).font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .font(CovaType.caption)
                                .foregroundStyle(Self.cellColor(value))
                                .frame(width: 56)
                        }
                    }
                    .padding(.vertical, CovaSpace.sm)
                    Divider().overlay(CovaColor.line)
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            Text("额度以官网为准").font(CovaType.caption).foregroundStyle(CovaColor.muted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            Text("这些不含在套餐里").font(CovaType.headline).foregroundStyle(CovaColor.fg)
                .padding(.horizontal, CovaSpace.pageGutter)
            Text("定制合作与批量授权走企业服务，App 内不办理。")
                .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                .padding(.horizontal, CovaSpace.pageGutter)
            // E 区：**文字按钮**（无底色、无渐变、不用主按钮样式）。
            Button {
                session.path.append(.enterprise)
            } label: {
                HStack(spacing: CovaSpace.xs) {
                    Text("前往官网了解")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(CovaType.callout)
                .foregroundStyle(CovaColor.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, CovaSpace.pageGutter)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            // F 合规脚注：**逐字**，缺失按 Critical 计。
            Text("套餐说明以官网为准，App 内不售卖。")
            Text("下载与扣费入口目前未在 App 内开放，请在官网了解与使用。")
        }
        .font(CovaType.caption).foregroundStyle(CovaColor.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.top, CovaSpace.lg)
    }

    private static func planName(for plan: CovaPlan) -> String {
        switch plan {
        case .free: return "免费版"
        case .creator: return "创作版"
        case .pro: return "专业版"
        case .enterprise: return "企业版"
        }
    }

    /// 颜色只表达「有没有」；「不支持」用 muted 而不是 error（spec 明令 ✕ 不用错误色）。
    private static func cellColor(_ value: String) -> Color {
        switch value {
        case "支持": return CovaColor.success
        case "不支持": return CovaColor.muted
        default: return CovaColor.warning
        }
    }

    /// `activeUntil` 不是契约字段（NEEDS-3 未闭合）⇒ 取不到就**不渲染副行**，
    /// 也不显示「未同步」这类催促话术。
    private static func expiryText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        out.dateFormat = "yyyy年M月d日"
        return out.string(from: date)
    }

    private func read() async {
        guard case .signedIn = session.authPhase else { return }
        // 本屏无骨架、无错误态：取不到就按「未登录之外什么都不显示」处理（spec §静默）。
        guard let me = try? await session.catalog.me() else { return }
        entitlements = me.entitlements
        activeUntil = nil   // `activeUntil` 在 `Entitlements` 里是真实响应附加字段，缺失即不渲染
    }
}

// MARK: - 14 企业服务（零网络请求）

/// 企业服务（design 14）。**这一屏不发任何请求**（连静默的 `me` 刷新都不发），
/// 全部内容是本仓写死的常量 + 两个外跳；案例数据没有端点 ⇒ **整区不渲染**，
/// 不放「敬请期待」，也不放占位灰图。
public struct EnterpriseView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL

    private static let contactEmail = "enterprise@covalink.cn"
    private static let sitePath = "https://covalink.cn/enterprise"

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.xl) {
                VStack(alignment: .leading, spacing: CovaSpace.sm) {
                    Text("为品牌、平台与团队提供可商用的 AI 音乐与授权")
                        .font(CovaType.title).foregroundStyle(CovaColor.fg)
                    Text("按项目谈范围、交付与授权，不套套餐表。")
                        .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                }
                .padding(.horizontal, CovaSpace.pageGutter)

                capabilities

                // 案例区：没有端点 ⇒ 整区不渲染（连标题都不出现）。
                // 若将来后端给出案例，这里按 ≤6 条渲染。

                contact
                footnote
            }
            .padding(.vertical, CovaSpace.lg)
        }
        .covaPage()
        .navigationTitle("企业服务")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            CovaSectionHeader("我们能做什么")
            ForEach(["定制曲库", "商用授权", "团队协作", "交付与归档"], id: \.self) { item in
                CovaListRow(title: item, subtitle: nil, artwork: nil) { EmptyView() } action: {}
            }
        }
    }

    private var contact: some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            CovaSectionHeader("怎么开始")
            // 两行都是**文字行样式**，不是主按钮。
            Button {
                UIPasteboard.general.string = Self.contactEmail
                session.showToast("已复制，请在邮件应用里粘贴")
            } label: {
                Text("复制邮箱地址 \(Self.contactEmail)")
                    .font(CovaType.callout).foregroundStyle(CovaColor.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, CovaSpace.pageGutter)

            Button {
                if let url = URL(string: Self.sitePath) { openURL(url) }
            } label: {
                HStack(spacing: CovaSpace.xs) {
                    Text("在官网了解")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(CovaType.callout).foregroundStyle(CovaColor.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, CovaSpace.pageGutter)

            Text("长按复制")
                .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                .padding(.horizontal, CovaSpace.pageGutter)
        }
    }

    private var footnote: some View {
        Text("套餐说明以官网为准，App 内不售卖。")
            .font(CovaType.caption).foregroundStyle(CovaColor.muted)
            .padding(.horizontal, CovaSpace.pageGutter)
    }
}
