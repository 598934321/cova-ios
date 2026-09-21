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
                    Button { Task { await session.next() } } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CovaColor.secondary)
                    }
                    .buttonStyle(.plain)
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
        case .playing: return "正在播放 · \(snap.loopMode.description)"
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

/// 全屏播放器（design 02）：大封面 + 波形进度 + 传输控制 + 循环三态 + ±15s。
/// 进度条拖动用本地 state 跟手，松手才 `seek`（避免拖动期间打满 actor）。
public struct PlayerView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var dragPosition: Double?

    public init() {}

    public var body: some View {
        let snap = session.snapshot
        VStack(spacing: CovaSpace.xl) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.headline).foregroundStyle(CovaColor.secondary)
                }
                Spacer()
                Text(snap?.loopMode.description ?? "").font(CovaType.caption).foregroundStyle(CovaColor.muted)
            }
            artwork(snap)
            texts(snap)
            progress(snap)
            transport(snap)
            secondary(snap)
            Spacer()
        }
        .padding(CovaSpace.pageGutter)
        .covaPage()
    }

    @ViewBuilder
    private func artwork(_ snap: PlaybackSnapshot?) -> some View {
        if let item = snap?.item {
            CovaArtwork(url: item.coverURL?.value, title: item.title)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CovaRadius.hero, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        } else {
            CovaEmptyState(symbol: "music.note", title: "没有在播的曲目", hint: "从首页或曲库选一首。")
        }
    }

    @ViewBuilder
    private func texts(_ snap: PlaybackSnapshot?) -> some View {
        VStack(spacing: 2) {
            Text(snap?.item?.title ?? "—").font(CovaType.title).foregroundStyle(CovaColor.fg).lineLimit(1)
            Text(snap?.item?.artist ?? "").font(CovaType.callout).foregroundStyle(CovaColor.secondary).lineLimit(1)
        }
    }

    private func progress(_ snap: PlaybackSnapshot?) -> some View {
        let duration = snap?.duration ?? 0
        let position = dragPosition ?? (snap?.position ?? 0)
        return VStack(spacing: CovaSpace.xs) {
            Slider(
                value: Binding(
                    get: { position },
                    set: { dragPosition = $0 }
                ),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = dragPosition {
                        Task { await session.seek(target); dragPosition = nil }
                    }
                }
            )
            .tint(CovaColor.accent)
            HStack {
                CovaType.digits(format(position))
                Spacer()
                CovaType.digits(format(duration))
            }
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.muted)
        }
    }

    private func transport(_ snap: PlaybackSnapshot?) -> some View {
        HStack(spacing: CovaSpace.xxl) {
            Button { Task { await session.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 26, weight: .semibold))
            }
            Button { Task { await session.toggle() } } label: {
                Image(systemName: snap?.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(CovaColor.accent)
            }
            Button { Task { await session.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 26, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(CovaColor.fg)
    }

    private func secondary(_ snap: PlaybackSnapshot?) -> some View {
        HStack(spacing: CovaSpace.xl) {
            Button { Task { await session.seek((snap?.position ?? 0) - 15) } } label: {
                Label("15", systemImage: "gobackward.15").font(CovaType.callout)
            }
            Button { Task { await session.cycleLoop() } } label: {
                Image(systemName: loopSymbol(snap?.loopMode)).font(CovaType.headline)
            }
            Button { Task { await session.seek((snap?.position ?? 0) + 15) } } label: {
                Label("15", systemImage: "goforward.15").font(CovaType.callout)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(CovaColor.secondary)
    }

    private func loopSymbol(_ mode: LoopMode?) -> String {
        switch mode {
        case .one: return "repeat.1"
        case .all: return "repeat"
        case .off, nil: return "arrow.right.arrow.left"
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
