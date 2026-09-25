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
