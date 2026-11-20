import SwiftUI

/// COVA-142 · AI 生成内容的显式标识（客户端共用）。
///
/// **法定义务，不是装修**：我方是生成合成服务提供者，端上呈现 AI 生成曲目/作品的界面
/// 必须在**内容展示时可见**地标注。文案定死三档，不许自创：
///
/// - L1 徽标（列表行/卡片，面积极小）：`AI 生成` 四字
/// - L2 短句（详情/播放器等单内容界面）：`本作品由 Cova AI 生成`
/// - L3 完整声明（导出/分享等站外传播路径）：`本作品由 Cova AI（CovaLink）使用人工智能技术生成合成。`
/// - 英文：`AI-generated`
///
/// **禁写「AI 创作」**：法条原文是「生成合成」，「创作」弱化了机器参与且不是法规用词。
///
/// 视觉层级：徽标表达的是**来源属性**，不做卖点。所以用 `surface` 底 + `secondary` 文字，
/// 不占品牌橙（品牌色配额红线），也不与「可商用」这类授权徽标抢层级。
public enum AIOrigin {
    /// 唯一取值：迄今为止本端所有呈现的曲目/作品都是 Cova AI 生成的
    /// （本端没有「用户上传音频」的呈现路径——依据 `归档/qa-evidence/COVA-20261118-142/
    /// 三端核查-20261119.md` §1「判定前提」）。将来若出现非 AI 内容，再加 `.human` 之类取值，
    /// 调用点按 `AIOrigin?` 判断，不要在渲染处写布尔。
    case aiGenerated
}

/// 三档文案的唯一来源。测试直接钉这里的字面量，**不要**在别处再抄一份字符串。
public enum AIMarkText {
    /// L1：列表行/卡片徽标（四字，法规语境下的最短显式提示）
    public static let level1 = "AI 生成"
    /// L2：单内容界面整句
    public static let level2 = "本作品由 Cova AI 生成"
    /// L3：导出/分享（会被转发到站外）
    public static let level3 = "本作品由 Cova AI（CovaLink）使用人工智能技术生成合成。"
    /// 英文站
    public static let english = "AI-generated"

    /// 禁词：法条原文用「生成合成」，写「创作」会弱化机器参与且不是法规用词。
    /// 门禁脚本按这个常量扫全仓（`Scripts/check-ai-mark.sh`）。
    public static let forbidden = "AI 创作"
}

/// L1 徽标：四字小胶囊。**不换行、不收缩**——被压成「AI…」就失去标识意义。
///
/// `origin == nil` 时 **完全空视图**（不是空 Text）：空的 `Text("")` 仍有
/// 12×18pt 的固有尺寸，会在「本来就不该有标识」的行（歌单卡、会员权益行）
/// 里留下一个看不见的空隙。实测见 `AIMarkLayoutTests.testNilOriginRendersNothing`。
public struct AIOriginBadge: View {
    private let text: String

    public init(_ origin: AIOrigin?) {
        // 目前只有一个取值；保留 `AIOrigin?` 形参让调用点显式表达「这一行是 AI 内容」，
        // 而不是在渲染层判断来源。
        self.text = origin == nil ? "" : AIMarkText.level1
    }

    public var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            Text(text)
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(CovaColor.surface))
                .overlay(Capsule().strokeBorder(CovaColor.line, lineWidth: 0.5))
                .accessibilityLabel(AIMarkText.level1)
        }
    }
}

/// L2 整句：单内容界面（详情页/播放器）用一行 `caption` 文字。
/// 不包胶囊——整句已经足够显眼，包起来反而像标签墙。
public struct AIOriginNotice: View {
    private let text: String
    private let alignment: HorizontalAlignment

    public init(_ origin: AIOrigin?, alignment: HorizontalAlignment = .leading) {
        self.text = origin == nil ? "" : AIMarkText.level2
        self.alignment = alignment
    }

    public var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            Text(text)
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.secondary)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(AIMarkText.level2)
        }
    }
}

public extension View {
    /// 把 L1 徽标挂到当前 view 之后（同一 HStack 里用）。`origin == nil` 时不渲染任何东西，
    /// 这样不带标识的调用点（歌单卡、会员权益行）零改动。
    @ViewBuilder
    func aiOriginBadge(_ origin: AIOrigin?) -> some View {
        if origin != nil {
            HStack(spacing: CovaSpace.xs) {
                self
                AIOriginBadge(origin)
            }
        } else {
            self
        }
    }
}

/// 封面角标版 L1 徽标：给**卡片**用（首页 140pt 横滑卡、网格卡）。
///
/// 为什么卡片用角标而不是文字行：卡宽只有 140pt，「艺人 · 时长」已经把那一行占满，
/// 再塞 4 字徽标必然把艺人名压成「林…」。角标叠在封面上 ⇒ **卡片高度 Δ0**，
/// 且和 web `TrackCard` 的「封面右上徽标栈」同一形态。
///
/// 底色用 `elevated`（不透明）而不是半透明材质：封面可能是纯白的，
/// 半透明底在那上面会隐形成「白底白字」。
public struct AIOriginCoverBadge: View {
    private let text: String
    public init(_ origin: AIOrigin?) {
        self.text = origin == nil ? "" : AIMarkText.level1
    }
    public var body: some View {
        Text(text)
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(CovaColor.elevated))
            .overlay(Capsule().strokeBorder(CovaColor.line, lineWidth: 0.5))
            .accessibilityLabel(AIMarkText.level1)
    }
}
