import CovaCore
import CovaUI
import SwiftUI

// MARK: - 13 会员（只读展示；D12：App 内不售卖）

/// 会员权益（design 13）。这一屏的**全部风险都在"说了不该说的话"**上，所以：
/// · B 卡只读、**卡内不放任何按钮**、整卡不可点；
/// · 未登录 ⇒ B 卡整卡不渲染（也不出现「登录后查看」这种引导卡）；
/// · 额度数字（30/200/800）**没有端点来源** ⇒ 渲染「—」+「额度以官网为准」，不编数；
/// · 脚注 F 必须逐字存在（缺失按 Critical 计，`Scripts/d12-copy-check.sh` 按字面量扫本文件）；
/// · 全屏文案（含 VoiceOver 标签）**禁止**出现：购买 / 充值 / 支付 / 立即开通 / 升级 /
///   订阅管理 / 付款 / 价格 / ¥ / 元/月 / 限时 / 优惠 / 恢复购买；
/// · `me` 取不到时**静默**（本屏按 spec 无骨架、无 Toast、无整屏错误态），
///   并且**当前列不高亮** —— 猜一个档位比不画更坏。
public struct MembershipView: View {
    @Environment(AppSession.self) private var session
    /// 13 §Dynamic Type：AX 档下权益对照表换形态（表 → 逐套餐纵向卡片）。
    @Environment(\.covaAXLayout) private var axLayout

    public init() {}

    /// 对比表的内容是**本地静态常量**（spec 明令：无端点）。这里只列「能力有没有」，
    /// 不列额度数字与任何金额；额度那一行统一给「额度以官网为准」。
    /// `internal`（不是 private）：用例要钉「每行的值数 == 列数」——对不齐时表不会崩，
    /// 只会把「支持」印到错的套餐头上，那正是这张表最贵的错。
    static let rows: [(label: String, values: [String])] = [
        ("商用授权", ["支持", "支持", "支持", "定制"]),
        ("AI 生成（Cova AI）", ["支持", "支持", "支持", "定制"]),
        ("下载与扣费", ["不支持", "支持", "支持", "定制"]),
        ("企业项目申请", ["不支持", "不支持", "支持", "定制"]),
        ("每月额度", ["—", "—", "—", "—"]),
    ]

    /// 列序 = `CovaPlan` 四档（13 §7 硬要求「与枚举严格同集，不增不减」）。
    /// 表头中文由 `CovaPlan.userLabel`（11 §8 唯一源）生成，**本文件不再另立一张表**；
    /// 而"枚举多了第五档"这件事由 `MineCopy`/各处穷举 switch 在编译期拦住。
    static let columns: [CovaPlan] = [.free, .creator, .pro, .enterprise]
    static let planNames: [String] = columns.map { $0.userLabel }
    /// 单元格宽度：4 列 × 56 + 首列弹性，是横向表在设计档下的排印宽度（TG-37 未入库）。
    private static let cellWidth: CGFloat = 56
    private static let currentEdgeWidth: CGFloat = 2    // §3.C：当前列 2pt `color.accent` 顶边（TG-04）

    /// §3.C 的「当前套餐列」：只有登录且 `plan` 取得到才有。**取不到 = 不高亮**（游客、
    /// `me` 失败、NEEDS-3 未解锁三支都落这里 —— §4 明令这些形态下"其余完全一致"）。
    private var currentPlan: CovaPlan? {
        guard case .signedIn = session.authPhase else { return nil }
        return session.me?.entitlements.plan
    }

    /// §3.B 的 B 卡数据：同上，只读 `AppSession` 那一份共享账（§并发：本屏**不**发独立请求）。
    private var entitlements: Entitlements? {
        guard case .signedIn = session.authPhase else { return nil }
        return session.me?.entitlements
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.xl) {
                if let entitlements {
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
        // 与 11/04 同一本 `/me` 账：`loadMe` 自己合并同身份的在途请求，游客直接早退。
        .task { await session.loadMe() }
    }

    /// 只读卡：**内部没有任何按钮**，也不可点。
    /// §3.B 底 `memberGoldSoft` + 1pt `memberGoldBorder`（双主题的深浅两值全在 token 里，§5）。
    private func myPlanCard(_ entitlements: Entitlements) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                Text(entitlements.plan.userLabel)
                    .font(CovaType.headline).foregroundStyle(CovaColor.memberGold)
                Spacer(minLength: CovaSpace.sm)
                // §4：有缓存但最近一次失败 → 「未同步」（muted），不弹 Toast、不整屏。
                if session.meState == .outOfSync {
                    Text("未同步").font(CovaType.caption).foregroundStyle(CovaColor.muted)
                }
            }
            // free 无有效期 ⇒ 副行整行不渲染（不是显示「—」，也不是显示未同步）。
            if let expiry = MineCopy.expiryText(entitlements.activeUntil) {
                Text(expiry).font(CovaType.caption).foregroundStyle(CovaColor.memberGold)
            }
            // D12：只读余额，卡内无动作（11 §3.C 同规则）。取不到时走 `--`，不显 0。
            Text("剩余 co 币：\(MineCopy.balance(entitlements.creditsBalance))")
                .font(CovaType.callout).foregroundStyle(CovaColor.memberGold)
                .accessibilityLabel(MineCopy.balanceSpoken(entitlements.creditsBalance))
        }
        .padding(CovaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                .fill(CovaColor.memberGoldSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                .strokeBorder(CovaColor.memberGoldBorder, lineWidth: 1)
        )
        .padding(.horizontal, CovaSpace.pageGutter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(planCardSpoken(entitlements))
    }

    /// §6：「当前套餐，创作版，有效期至 …」——一条元素说完，顺序与 §3.B 的视觉顺序一致。
    private func planCardSpoken(_ entitlements: Entitlements) -> String {
        var parts = [MineCopy.planSpoken(entitlements.plan)]
        if let expiry = MineCopy.expiryText(entitlements.activeUntil) { parts.append(expiry) }
        parts.append(MineCopy.balanceSpoken(entitlements.creditsBalance))
        if session.meState == .outOfSync { parts.append("未同步") }
        return parts.joined(separator: "，")
    }

    private var comparison: some View {
        let current = columnIndex
        return VStack(alignment: .leading, spacing: CovaSpace.md) {
            CovaSectionHeader("权益对比")
            // 表体那 56pt 的单元格是**为对照密度设计的**：字号一放大就截断，
            // 与其让「不支持」变成「不支…」，不如在 AX 档换成逐套餐卡片（13 §Dynamic Type）。
            if axLayout {
                axPlanCards
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: CovaSpace.sm) {
                        Text(" ").frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(Self.planNames.enumerated()), id: \.offset) { index, name in
                            headerCell(name, isCurrent: index == current)
                        }
                    }
                    .padding(.vertical, CovaSpace.xs)
                    ForEach(Self.rows, id: \.label) { row in
                        HStack(spacing: CovaSpace.sm) {
                            Text(row.label).font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                                cell(value, isCurrent: index == current)
                            }
                        }
                        .padding(.vertical, CovaSpace.sm)
                        Divider().overlay(CovaColor.line)
                    }
                }
                .padding(.horizontal, CovaSpace.pageGutter)
            }
            Text("额度以官网为准").font(CovaType.caption).foregroundStyle(CovaColor.muted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 当前列的下标（`columns` 与 `planNames`/每行 `values` 同序）。取不到 → nil ⇒ 一格都不点亮。
    private var columnIndex: Int? {
        guard let current = currentPlan else { return nil }
        return Self.columns.firstIndex(of: current)
    }

    /// §3.C：表头 = 套餐名 `type.callout` / `color.memberGold`；当前列另加 2pt `color.accent`
    /// 顶边 + 列底 `color.accentSoft` + 「当前套餐」徽标（§8 允许措辞里就这三个词）。
    private func headerCell(_ name: String, isCurrent: Bool) -> some View {
        VStack(spacing: CovaSpace.xs) {
            Text(name)
                .font(CovaType.callout)
                .foregroundStyle(CovaColor.memberGold)
                .lineLimit(1)
                .layoutPriority(1)
            // 徽标位**恒存在**（当前/非当前都占同一格高度），否则点亮的瞬间整表会跳一行
            // —— 而 §4 要求那一帧的过渡是「一帧到位」，不是布局抖动。
            Text(isCurrent ? "当前套餐" : " ")
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.accentText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: Self.cellWidth)
        .padding(.top, isCurrent ? Self.currentEdgeWidth : 0)
        .background(isCurrent ? CovaColor.accentSoft : Color.clear)
        .overlay(alignment: .top) {
            if isCurrent {
                Rectangle().fill(CovaColor.accent).frame(height: Self.currentEdgeWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCurrent ? "当前套餐 \(name)" : name)
    }

    private func cell(_ value: String, isCurrent: Bool) -> some View {
        Text(value)
            .font(CovaType.caption)
            .foregroundStyle(Self.cellColor(value))
            .frame(width: Self.cellWidth)
            .background(isCurrent ? CovaColor.accentSoft : Color.clear)
    }

    /// AX 档的替代形态：每套餐一张卡，卡内是「权益名 : 值」的纵向列表（13 §Dynamic Type）。
    /// 取值走 `indices.contains` 而不是直接下标 —— `rows`/`planNames` 是两处静态常量，
    /// 长度对不上时**宁可显示「—」也不能崩**。
    private var axPlanCards: some View {
        let current = currentPlan
        return VStack(alignment: .leading, spacing: CovaSpace.md) {
            ForEach(Array(Self.columns.enumerated()), id: \.offset) { index, plan in
                CovaCard {
                    VStack(alignment: .leading, spacing: CovaSpace.xs) {
                        HStack(spacing: CovaSpace.xs) {
                            Text(plan.userLabel)
                                .font(CovaType.headline)
                                .foregroundStyle(CovaColor.memberGold)
                            if plan == current {
                                Text("当前套餐")
                                    .font(CovaType.caption).foregroundStyle(CovaColor.accentText)
                            }
                        }
                        ForEach(Self.rows, id: \.label) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                                Spacer(minLength: CovaSpace.sm)
                                Text(row.values.indices.contains(index) ? row.values[index] : "—")
                                    .font(CovaType.caption)
                                    .foregroundStyle(
                                        Self.cellColor(
                                            row.values.indices.contains(index) ? row.values[index] : "—"))
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
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

    /// 颜色只表达「有没有」；「不支持」用 muted 而不是 error（spec 明令 ✕ 不用错误色）。
    /// 支持/不支持的色档同样照 §3.C 走：✓=memberGold、✕=muted、文字值（定制/—）=secondary
    /// —— 上一版给「定制」上了 warning 橙，那是 §3.C 与 §5 都没有的一档自造色。
    /// `internal`：这三条是「色 == 语义」的映射，用例逐格钉（尤其钉死"不支持 ≠ error"）。
    static func cellColor(_ value: String) -> Color {
        switch value {
        case "支持": return CovaColor.memberGold
        case "不支持": return CovaColor.muted
        default: return CovaColor.secondary
        }
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
