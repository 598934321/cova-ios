import CovaCore
import SwiftUI

// MARK: - 像素占位（PixelCard 式）
//
// design 01 §5「封面（生成封面或 **PixelCard 式像素占位呼吸**）」、02 §2 同族、
// components §5 CandidateCard「封面（或像素呼吸占位）」。
//
// 这一格为什么必须存在（而不是继续画那张音符）：`StudioSessionCover.hasCoverFieldInListPayload`
// 是 `false` —— 会话列表载荷里没有任何封面字段（`StudioSessionDTOs.swift` 里
// `cover` / `coverUrl` / `imageUrl` / `thumbnail` 零命中），§数据源又明令**不得**为封面逐行
// 去发详情请求（N+1）。所以"没有封面"在这些屏里是**长期事实**而不是故障，
// 需要一个诚实的、不成其为"某张真图"的形状：像素网格只说"这里是一格还没有内容的封面位"。
public struct CovaPixelCover: View {
    /// 档名与取值理由（4×4、0.9s 与 §S1 不做扫过的关系、Reduce Motion 的静态那一档）
    /// 全部写在 `PixelCoverFacts`（CovaCore）：CovaUI 没有测试目标，数字放在这里就是
    /// 没人能钉住的数，放在 CovaCore 才进得了 XCTest。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let cell = min(proxy.size.width, proxy.size.height) / CGFloat(PixelCoverFacts.cellsPerSide)
            ZStack(alignment: .topLeading) {
                CovaColor.surface
                ForEach(
                    0..<PixelCoverFacts.cellsPerSide * PixelCoverFacts.cellsPerSide, id: \.self
                ) { index in
                    let row = index / PixelCoverFacts.cellsPerSide
                    let column = index % PixelCoverFacts.cellsPerSide
                    Rectangle()
                        .fill(CovaColor.muted.opacity(PixelCoverFacts.cellAlpha(
                            row: row, column: column, lit: lit, reduceMotion: reduceMotion
                        )))
                        .frame(width: cell, height: cell)
                        .offset(x: CGFloat(column) * cell, y: CGFloat(row) * cell)
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            // §8「Reduce Motion：封面呼吸/渐变动画关闭，直接静态呈现」⇒ 这一档根本不起动画。
            withAnimation(
                .easeInOut(duration: PixelCoverFacts.breatheDuration).repeatForever(autoreverses: true)
            ) {
                lit = true
            }
        }
        // 占位不携带内容，也没有可朗读的事实（标题已经在那一格的文字位上说了）。
        .accessibilityHidden(true)
    }
}

// MARK: - 主色铺底（16 §3 / §5；02 §1 是同一族的另一张脸）
//
// 16 §3：头区容器「底为『艺人主色 → `color.canvas`』的柔和铺底」；§5 给了叠加强度
// （TG-40：Light 12% / Dark 22%）；§7 给了**唯一**允许的解析口径（只认 `#RGB`/`#RRGGBB`）。
//
// 为什么这一格今天拿得到"真主色"而不必假称取色：16 的主色源是 `artist.colorPalette`
// （后端直接给的颜色串，2026-09-25 实测为 JSON 字符串数组 `["#…", …]`），
// 不是"从封面图上算一个主色"。**从封面取主色**是 02 §1 那一档，它要的是解出来的位图
// ——而 `CovaArtwork`/`CovaArtworkCache` 今天不把解出的 `UIImage` 交回调用方
// （CovaStates 不在本批可改面），所以 02 那一档今天做不了，也**不**在这里用一个常数色冒充。
public struct CovaSwashBackdrop: View {
    /// 解析失败 ⇒ `nil` ⇒ 回落 `color.surface`（16 §3 明令"不猜品牌橙"）。
    private let tint: Color?
    /// 交叉淡入的触发身份：换艺人 / 换主色就换这个串。用 `Color` 本身当值不可靠 ——
    /// 动态 `Color(uiColor:)` 的相等性看的是底层 provider，不保证"色变了动画就变"。
    private let identity: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tint: Color?, identity: String) {
        self.tint = tint
        self.identity = identity
    }

    public var body: some View {
        ZStack {
            CovaColor.canvas
            if let tint {
                LinearGradient(
                    colors: [tint.opacity(Self.overlayAlpha(light: scheme != .dark)), CovaColor.canvas],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                CovaColor.surface
            }
        }
        // 16 §4：Reduce Motion 下"色彩过渡退化为一帧" ⇒ 直接把动画整个拿掉。
        .animation(
            reduceMotion ? nil : .easeInOut(duration: ArtistSwash.crossFadeDuration),
            value: identity
        )
        // 16 §6：铺底色不播报，解析失败也不产生任何提示。
        .accessibilityHidden(true)
    }

    /// TG-40 的两档（Light 12% / Dark 22%）。两档不同值是 §5 的理由：
    /// 同一个透明度压在白底与黑底上观感不等价。
    static func overlayAlpha(light: Bool) -> Double {
        light ? ArtistSwash.overlayLightAlpha : ArtistSwash.overlayDarkAlpha
    }
}
