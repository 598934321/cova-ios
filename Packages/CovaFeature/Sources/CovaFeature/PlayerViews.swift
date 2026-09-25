import CovaCore
import CovaPlayer
import CovaUI
import SwiftUI

/// MiniPlayer（design 02 的常驻条）：封面 + 标题 + 播放/暂停 + 下一首；点击展开全屏。
/// **状态全部读快照**：不自己维护播放状态（单一事实源 = 协调器）。
public struct MiniPlayerView: View {
    @Environment(AppSession.self) private var session

    public init() {}

    public var body: some View {
        let snap = session.snapshot
        if let item = snap?.item {
            Button {
                session.playerSheetOpen = true
            } label: {
                HStack(spacing: CovaSpace.md) {
                    CovaArtwork(url: item.coverURL?.value, title: item.title)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(CovaType.callout).foregroundStyle(CovaColor.fg).lineLimit(1)
                        Text(statusText(snap)).font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                    }
                    Spacer()
                    Button { Task { await session.toggle() } } label: {
                        Image(systemName: snap?.state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(CovaColor.fg)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(snap?.state == .playing ? "暂停" : "播放")
                    Button { Task { await session.next() } } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CovaColor.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("下一首")
                }
                .padding(.horizontal, CovaSpace.md)
                .padding(.vertical, CovaSpace.sm)
                .covaGlass(elevated: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, CovaSpace.pageGutter)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func statusText(_ snap: PlaybackSnapshot?) -> String {
        guard let snap else { return "准备中" }
        switch snap.state {
        case .playing: return "正在播放 · \(snap.loopMode.userLabel)"
        case .paused: return "已暂停"
        case .loading: return "加载私有音频中…"
        case .buffering: return "缓冲中…"
        case .stopped:
            if let failure = snap.lastFailure { return "已停止：\(failure.description)" }
            return "已停止"
        case .idle: return "待播"
        }
    }
}

/// 全屏播放器（design 02）：大封面 + 波形进度条（§3）+ 传输控制（§4）+ 次级操作行（§5）。
/// 进度条拖动用本地 state 跟手，松手才 `seek`（避免拖动期间打满 actor）。
public struct PlayerView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var dragPosition: Double?
    /// 02 §2/§5：点封面切换底部面板内容（歌词 / 队列）。默认歌词。
    @State private var panel: PlayerPanel = .lyrics
    /// 02 §3 的波形事实源：`TrackDto.waveformPeaks` 归一后的柱高（空 = 细线退化形态）。
    @State private var barHeights: [Double] = []
    /// `highlightStart/End` 折算的时间轴占比（nil = 不放刻度带）。
    @State private var highlightFraction: ClosedRange<Double>?

    enum PlayerPanel { case lyrics, queue }

    public init() {}

    public var body: some View {
        let snap = session.snapshot
        // D24 构图：主栈 24→16。封面/波形/传输/面板原来各段之间都是 `xl`，配合大字号把一屏
        // 切成三段式堆叠；紧凑档下靠留白**对比**（段内 sm、段间 lg）拉开层级。
        VStack(spacing: CovaSpace.lg) {
            topBar(snap)
            artwork(snap)
            texts(snap)
            progress(snap)
            transport(snap)
            secondary(snap)
            bottomPanel
            Spacer()
        }
        .padding(CovaSpace.pageGutter)
        .covaPage()
        .task(id: waveformKey(snap?.item)) {
            await loadWaveform(for: snap?.item)
        }
    }

    /// 顶部条（02 §1）：⌄ 收起 + ⋯ 更多。**⋯ 里只放真有 backing 的条目**：
    /// 面板跳转 + 分享（曲库曲目）。D12 放行前**不构造**「下载」条目（不是置灰、不是隐藏）。
    private func topBar(_ snap: PlaybackSnapshot?) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).foregroundStyle(CovaColor.secondary)
                    .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("收起播放器")
            Spacer()
            Menu {
                Button(panel == .lyrics ? "看播放队列" : "看歌词") { togglePanel() }
                if let item = snap?.item, item.kind == .libraryTrack,
                   let page = PlayerView.publicTrackPage(itemID: item.id) {
                    ShareLink(item: page) { Label("分享", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CovaColor.secondary)
                    .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")
        }
    }

    @ViewBuilder
    private func artwork(_ snap: PlaybackSnapshot?) -> some View {
        if let item = snap?.item {
            Button { withAnimation(.easeOut(duration: 0.18)) { togglePanel() } } label: {
                CovaArtwork(url: item.coverURL?.value, title: item.title)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: CovaRadius.hero, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换歌词与队列面板")
        } else {
            CovaEmptyState(symbol: "music.note", title: "没有在播的曲目", hint: "从首页或曲库选一首。")
        }
    }

    @ViewBuilder
    private func texts(_ snap: PlaybackSnapshot?) -> some View {
        VStack(spacing: 2) {
            // 02 §8：私有候选在标题栏下方挂「生成候选 · 仅本人可见」徽标（warning 色），
            // 且这一类条目**不触发播放上报**、也不放收藏 ♡（收藏走候选卡上的 retention 接口）。
            if snap?.item?.kind == .privateCandidate {
                Text("生成候选 · 仅本人可见")
                    .font(CovaType.caption).foregroundStyle(CovaColor.warning)
                    .padding(.horizontal, CovaSpace.sm).padding(.vertical, 2)
                    .background(Capsule().fill(CovaColor.warning.opacity(0.12)))
            }
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                Text(snap?.item?.title ?? "—").font(CovaType.title).foregroundStyle(CovaColor.fg).lineLimit(1)
                Spacer(minLength: CovaSpace.sm)
                // 02 §5：♡ 收藏在标题右侧。**私有候选不渲染**（02 §8：候选走候选卡上的
                // retention 接口，这里没有可收藏的事实源）。
                if let item = snap?.item, item.kind == .libraryTrack {
                    favoriteButton(item.id)
                }
            }
            Text(snap?.item?.artist ?? "").font(CovaType.callout).foregroundStyle(CovaColor.secondary).lineLimit(1)
        }
    }

    /// 收藏钮：与 07 详情同一口径 —— 游客点击弹登录（`requireLoginForCollections`），不静默。
    private func favoriteButton(_ trackID: String) -> some View {
        let on = session.favoriteIDs.contains(trackID)
        return Button {
            Task {
                if session.requireLoginForCollections() { await session.toggleFavorite(trackID) }
            }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? CovaColor.accent : CovaColor.muted)
                .symbolEffect(.bounce, value: on)  // 02 §5：选中态缩放弹跳
                .frame(width: PlayerMetrics.touchMin, height: PlayerMetrics.touchMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "取消收藏" : "收藏")
    }

    private func togglePanel() {
        panel = panel == .lyrics ? .queue : .lyrics
    }

    /// 底部面板（02 §5/§6）。歌词是**静态文本滚动**（D15：后端没有时间轴数据，
    /// 逐行时间轴歌词是全局禁令），取不到就显示「纯音乐 / 暂无歌词」。
    @ViewBuilder
    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            HStack {
                Text(panel == .lyrics ? "歌词" : "播放队列")
                    .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                Spacer()
                Button(panel == .lyrics ? "看队列" : "看歌词") { togglePanel() }
                    .font(CovaType.caption).foregroundStyle(CovaColor.accent)
            }
            if panel == .lyrics {
                lyricsBlock
            } else {
                queueBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var lyricsBlock: some View {
        if let lyrics = session.lyricsForCurrentItem, !lyrics.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                Text(lyrics)
                    .font(CovaType.body).foregroundStyle(CovaColor.fg)
                    .lineSpacing(6)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxHeight: 140)
        } else {
            Text("纯音乐 / 暂无歌词")
                .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, CovaSpace.lg)
        }
    }

    /// 队列面板只显**快照里有的**信息；没有队列事实源时不编造列表。
    private var queueBlock: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                if let item = session.snapshot?.item {
                    HStack(spacing: CovaSpace.sm) {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(CovaColor.accent)
                            .accessibilityHidden(true)
                        Text(item.title).font(CovaType.callout).foregroundStyle(CovaColor.fg)
                        Text(item.artist).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    }
                }
                Text("完整队列的编辑在下一版接入（当前只有当前项这一个事实源）")
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
    }

    // MARK: - 02 §3 波形进度条

    /// 02 §3：波形进度条 + 时间行（`00:42` / `-02:18`）。拖动 seek 走的仍是
    /// 既有的 `session.seek` 单一路径；无波形数据时退化 3pt 细线（同一拖动腿）。
    private func progress(_ snap: PlaybackSnapshot?) -> some View {
        let duration = snap?.duration ?? 0
        let position = dragPosition ?? (snap?.position ?? 0)
        return VStack(spacing: CovaSpace.xs) {
            GeometryReader { geo in
                WaveformProgress(
                    fraction: WaveformBars.progress(position: position, duration: duration),
                    barHeights: barHeights,
                    highlight: highlightFraction,
                    isSeeking: dragPosition != nil,
                    seekText: PlayerTime.elapsed(position)
                )
                .contentShape(Rectangle())
                .gesture(seekGesture(duration: duration, width: geo.size.width))
            }
            .frame(height: PlayerMetrics.waveformHeight)
            .accessibilityElement()
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(PlayerTime.elapsed(position))，剩余 \(PlayerTime.remaining(position: position, duration: duration))")
            HStack {
                CovaType.digits(PlayerTime.elapsed(position))
                Spacer()
                CovaType.digits(PlayerTime.remaining(position: position, duration: duration))
            }
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.muted)
        }
    }

    private func seekGesture(duration: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0, width > 0 else { return }
                let x = min(max(value.location.x, 0), width)
                dragPosition = Double(x / width) * duration
            }
            .onEnded { _ in
                if let target = dragPosition {
                    Task { await session.seek(target); dragPosition = nil }
                }
            }
    }

    private func waveformKey(_ item: PlaybackItem?) -> String? {
        guard let item else { return nil }
        return "\(item.kind.rawValue):\(item.id)"
    }

    /// 波形数据只属于**曲库曲目**：私有候选不在 `/api/tracks` 里（02 §8），不请求、
    /// 直接细线。取不到（网络失败/字段缺失）也按 §3 退化为细线，不报错打断播放。
    private func loadWaveform(for item: PlaybackItem?) async {
        barHeights = []
        highlightFraction = nil
        guard let item, item.kind == .libraryTrack else { return }
        guard let detail = try? await session.catalog.trackDetail(item.id) else { return }
        let track = detail.track
        barHeights = WaveformBars.heights(peaks: track.waveformPeaks)
        let span = track.duration > 0 ? track.duration : (item.duration ?? 0)
        highlightFraction = WaveformBars.highlightFraction(
            start: track.highlightStart, end: track.highlightEnd, duration: span
        )
    }

    // MARK: - 02 §4 传输控制

    private func transport(_ snap: PlaybackSnapshot?) -> some View {
        HStack(spacing: CovaSpace.xl) {
            Button { Task { await session.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 26, weight: .semibold))
                    .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("上一首")
            Button { Task { await session.seek((snap?.position ?? 0) - 15) } } label: {
                Image(systemName: "gobackward.15").font(.system(size: 24, weight: .medium))
                    .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("后退 15 秒")
            Button { Task { await session.toggle() } } label: {
                Image(systemName: snap?.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(CovaColor.accent)
            }
            .accessibilityLabel(snap?.state == .playing ? "暂停" : "播放")
            Button { Task { await session.seek((snap?.position ?? 0) + 15) } } label: {
                Image(systemName: "goforward.15").font(.system(size: 24, weight: .medium))
                    .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("前进 15 秒")
            Button { Task { await session.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 26, weight: .semibold))
                    .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("下一首")
        }
        .buttonStyle(.plain)
        .foregroundStyle(CovaColor.fg)
    }

    // MARK: - 02 §5 次级操作行：循环（三态图标）/ 歌词 / 分享

    /// 「下载」**不构造**：D12 明令 v1.0 不开任何扣费入口（02 §5），合规放行后再接。
    private func secondary(_ snap: PlaybackSnapshot?) -> some View {
        let mode = snap?.loopMode ?? .off
        return HStack(spacing: CovaSpace.xl) {   // D24 紧凑：次级操作行 32→24，三枚钮仍各 ≥44pt 触控
            Button { Task { await session.cycleLoop() } } label: {
                loopLabel(mode)
                    .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("循环模式")
            // 三态靠图标说话，`userLabel`（「不循环/列表循环/单曲循环」）退居无障碍读法。
            .accessibilityValue(mode.userLabel)
            .foregroundStyle(mode == .off ? CovaColor.secondary : CovaColor.accentText)

            Button { togglePanel() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "text.book.closed")
                    Text("歌词").font(CovaType.caption)
                }
                .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("歌词面板")
            .foregroundStyle(panel == .lyrics ? CovaColor.accentText : CovaColor.secondary)

            // 02 §8：候选没有公开页 ⇒ 不提供分享（NEEDS-24，与 09 候选卡同一裁决）。
            if let item = snap?.item, item.kind == .libraryTrack,
               let page = PlayerView.publicTrackPage(itemID: item.id) {
                ShareLink(item: page) {
                    VStack(spacing: 2) {
                        Image(systemName: "square.and.arrow.up")
                        Text("分享").font(CovaType.caption)
                    }
                    .frame(minWidth: PlayerMetrics.touchMin, minHeight: PlayerMetrics.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享这首歌")
                .foregroundStyle(CovaColor.secondary)
            } else {
                Color.clear
                    .frame(width: PlayerMetrics.touchMin, height: PlayerMetrics.touchMin)
            }
        }
        .buttonStyle(.plain)
    }

    /// 三态图标（02 §5）：`repeat` → `repeat`+accent 点 → `repeat.1`。
    @ViewBuilder
    private func loopLabel(_ mode: LoopMode) -> some View {
        Image(systemName: mode == .one ? "repeat.1" : "repeat")
            .font(.system(size: 22, weight: .medium))
            .overlay(alignment: .topTrailing) {
                if mode == .all {
                    Circle().fill(CovaColor.accent).frame(width: 6, height: 6).offset(x: 4, y: -2)
                }
            }
    }

    /// 分享目标是 web 侧真实存在的公开页 `/tracks/:id`（2026-09 对照
    /// `web/src/app/tracks/[id]/page.tsx` 的 `window.location.href` 口径）。
    /// id 已过 `PlaybackItem` 的字符白名单校验，直接拼串不引入注入面。
    private static func publicTrackPage(itemID: String) -> URL? {
        URL(string: "https://covalink.cn/tracks/\(itemID)")
    }
}

/// 02 §3 的进度条本体：有波形 ⇒ 48 根柱（已播 accent、未播 muted 35%、高亮区间上方
/// 2pt 刻度带）；无波形 ⇒ 退化为 3pt 细线胶囊（§3 的兜底口径，非占位假数据）。
private struct WaveformProgress: View {
    let fraction: Double
    let barHeights: [Double]
    let highlight: ClosedRange<Double>?
    let isSeeking: Bool
    let seekText: String

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    if let highlight {
                        Capsule()
                            .fill(CovaColor.accent.opacity(0.75))
                            .frame(width: max(2, (highlight.upperBound - highlight.lowerBound) * width), height: 2)
                            .offset(x: highlight.lowerBound * width)
                    }
                }
                .frame(height: 2)
                if barHeights.isEmpty {
                    thinLine
                } else {
                    bars(in: geo.size)
                }
            }
            if isSeeking {
                // §3：拖动中 mono 时间气泡跟随。
                CovaType.digits(seekText)
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.fg)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(CovaColor.elevated))
                    .offset(x: min(max(fraction * width - 28, 0), max(width - 56, 0)), y: -26)
                    .allowsHitTesting(false)
            }
        }
    }

    private var thinLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CovaColor.muted.opacity(0.35))
                Capsule().fill(CovaColor.accent)
                    .frame(width: max(3, fraction * geo.size.width))
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func bars(in size: CGSize) -> some View {
        // 柱数在归一层就已钳成 barHeights.count（48，与 web 紧凑播放器同口径）。
        HStack(alignment: .center, spacing: 2) {
            ForEach(barHeights.indices, id: \.self) { index in
                let played = Double(index + 1) / Double(barHeights.count) <= fraction
                Capsule()
                    .fill(played ? CovaColor.accent : CovaColor.muted.opacity(0.35))
                    .frame(height: max(3, barHeights[index] * size.height))
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// 02 屏反复出现的几何值（对齐 `CovaRootView` 的 `DrawerMetrics` 做法：token 缺口先集中成
/// 命名常量，不散落字面量）。touchMin = AGENTS/inventory 通用 ≥44pt 触控底线。
enum PlayerMetrics {
    static let touchMin: CGFloat = 44
    static let waveformHeight: CGFloat = 34
}
