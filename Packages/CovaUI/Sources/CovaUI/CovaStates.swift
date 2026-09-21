import SwiftUI

/// 封面图（异步加载 + 占位 + 失败回退）。**签名 URL 不回显**：日志与无障碍标签只含曲目名。
public struct CovaArtwork: View {
    private let url: URL?
    private let title: String
    @State private var phase: Phase = .loading

    private enum Phase { case loading, loaded(Image), failed }

    public init(url: URL?, title: String) {
        self.url = url
        self.title = title
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CovaRadius.control - 4, style: .continuous)
                .fill(CovaColor.surface)
            switch phase {
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded(let image):
                image.resizable().scaledToFill()
            case .failed:
                Image(systemName: "music.note")
                    .foregroundStyle(CovaColor.muted)
            }
        }
        .accessibilityLabel(title)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { phase = .failed; return }
        phase = .loading
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let ui = UIImage(data: data) { phase = .loaded(Image(uiImage: ui)) }
            else { phase = .failed }
        } catch {
            phase = .failed
        }
    }
}

/// 空态（design §17）：图标 + 标题 + 一句引导 + 可选动作；**不伪造数据**。
public struct CovaEmptyState: View {
    private let symbol: String
    private let title: String
    private let hint: String?
    private let actionTitle: String?
    private let action: (() -> Void)?
    public init(symbol: String, title: String, hint: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.hint = hint
        self.actionTitle = actionTitle
        self.action = action
    }
    public var body: some View {
        VStack(spacing: CovaSpace.md) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CovaColor.muted)
            Text(title).font(CovaType.headline).foregroundStyle(CovaColor.fg)
            if let hint {
                Text(hint).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                CovaButton(actionTitle, style: .secondary, action: action)
                    .frame(maxWidth: 220)
            }
        }
        .padding(CovaSpace.xxl)
        .frame(maxWidth: .infinity)
    }
}

/// 错误态（design §17）：区分「网络/服务端/后端缺口」三类文案；后端缺口直接点名 NEEDS 编号，
/// 让用户看到的和登记在册的是同一句话，不伪装成普通网络错误。
public struct CovaErrorState: View {
    public enum Kind { case network, server, backendGap(String) }
    private let kind: Kind
    private let retry: (() -> Void)?
    public init(kind: Kind, retry: (() -> Void)? = nil) {
        self.kind = kind
        self.retry = retry
    }
    public var body: some View {
        VStack(spacing: CovaSpace.md) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CovaColor.error.opacity(0.8))
            Text(title).font(CovaType.headline).foregroundStyle(CovaColor.fg)
            Text(hint).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                .multilineTextAlignment(.center)
            if let retry { CovaButton("重试", style: .secondary, action: retry).frame(maxWidth: 180) }
        }
        .padding(CovaSpace.xxl)
        .frame(maxWidth: .infinity)
    }
    private var symbol: String {
        if case .network = kind { return "wifi.slash" }
        if case .server = kind { return "server.rack" }
        return "wrench.and.screwdriver"
    }
    private var title: String {
        switch kind {
        case .network: return "网络不可用"
        case .server: return "服务暂时不可用"
        case .backendGap: return "该能力尚未上线"
        }
    }
    private var hint: String {
        switch kind {
        case .network: return "检查连接后重试；播放中的曲目不受影响。"
        case .server: return "稍后再试。已登记在服务端待办中。"
        case .backendGap(let id): return "后端契约缺口 \(id) 已登记（NEEDS.md），上线后此处自动可用。"
        }
    }
}

/// 骨架屏（design §17 / Reduce Motion 退化为静态灰块）：shimmer 仅在动效开启时跑。
public struct CovaSkeleton: View {
    public var rows: Int = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    public init(rows: Int = 3) { self.rows = rows }
    public var body: some View {
        VStack(spacing: CovaSpace.md) {
            ForEach(0..<rows, id: \.self) { i in
                RoundedRectangle(cornerRadius: CovaRadius.control - 4, style: .continuous)
                    .fill(CovaColor.line.opacity(phase ? 0.9 : 0.5))
                    .frame(height: i == 0 ? 64 : 44)
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
        .accessibilityLabel("加载中")
    }
}

/// Toast（design §17 错误/成功提示）：玻璃底、自动 2.5s 消失、可手动点掉；
/// 同一时刻只保留一条（由宿主 view model 去重）。
public struct CovaToast: View {
    public let message: String
    public let isError: Bool
    public init(message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }
    public var body: some View {
        HStack(spacing: CovaSpace.sm) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? CovaColor.error : CovaColor.success)
            Text(message).font(CovaType.callout).foregroundStyle(CovaColor.fg)
        }
        .padding(.horizontal, CovaSpace.lg)
        .padding(.vertical, CovaSpace.md)
        .covaGlass(elevated: true)
        .accessibilityAddTraits(.isStaticText)
    }
}
