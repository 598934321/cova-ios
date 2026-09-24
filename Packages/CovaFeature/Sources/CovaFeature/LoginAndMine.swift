import CovaCore
import CovaUI
import SwiftUI

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

/// 「我的」（design 11）：登录态显示用户与权益（**仅展示余额，D12：无购买入口**）；
/// 游客态给登录入口。收藏/歌单/创作/下载四个入口走抽屉同款列表。
public struct MineView: View {
    @Environment(AppSession.self) private var session
    @State private var me: CovaMeResponse?
    /// `/me` 的失败**必须可见**：原先写成 `try?`，把「未登录竞态下的 401」和「真出错」
    /// 一起吞成 nil ⇒ 已登录却满屏没有权益与余额，而且永不重试（截图实测到的正是这个）。
    @State private var meFailed = false

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

    public var body: some View {
        ScrollView {
            VStack(spacing: CovaSpace.lg) {
                profile
                entries
            }
            .padding(.vertical, CovaSpace.xl)
        }
        .covaPage()
        // `task(id:)`：换号 / 登录后自动重取，不靠"恰好在这屏才登录"的运气。
        .task(id: authPhaseKey) { await loadMe() }
    }

    @MainActor
    private func loadMe() async {
        guard case .signedIn = session.authPhase else { me = nil; meFailed = false; return }
        meFailed = false
        do {
            me = try await CatalogService(client: session.client).me()
        } catch {
            // 失败要说出来并给重试，而不是安静地少画两行。
            me = nil
            meFailed = true
        }
    }

    @ViewBuilder
    private var profile: some View {
        switch session.authPhase {
        case .signedIn(let user):
            CovaCard {
                VStack(alignment: .leading, spacing: CovaSpace.sm) {
                    Text(user.name).font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    // 11 §3-B：次行是 covaId（等宽数字）或邮箱。`covaId` 只在 `/me` 上给，
                    // 登录响应的 `user` 没有 —— 所以这一行同时也是「两步入口是否走通」的可见证据。
                    Text(user.covaId ?? user.email ?? "")
                        .font(CovaType.mono).foregroundStyle(CovaColor.secondary)
                    if let me {
                        Text("计划：\(me.entitlements.plan.rawValue)")
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                        // D12：只展示余额，**不放任何购买/充值入口**。
                        Text("剩余 co 币：\(me.entitlements.creditsBalance)")
                            .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                    } else if meFailed {
                        // 取不到就说取不到：少画两行与"这账号没有权益"在两回事。
                        Text("权益没取到").font(CovaType.subhead).foregroundStyle(CovaColor.error)
                        Button("重试") { Task { await loadMe() } }
                            .font(CovaType.subhead).foregroundStyle(CovaColor.accentText)
                            .buttonStyle(.plain)
                    }
                    CovaButton("登出", style: .secondary) { Task { await session.signOut() } }
                }
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

    private var entries: some View {
        VStack(spacing: 0) {
            // 11 §1/§3-F/§7：「已下载」行在 D12 合规放行前**整项不渲染**（与 04 §3.D 同一条裁决，
            // 也不是置灰/禁用）。放行前给它一个只弹 Toast 的入口，等于向用户承诺一个不存在的页面。
            ForEach(["收藏", "我的歌单", "我的创作"], id: \.self) { title in
                CovaListRow(title: title, subtitle: nil, artwork: nil) {
                    Image(systemName: "chevron.right").foregroundStyle(CovaColor.muted)
                        .accessibilityHidden(true)
                } action: {
                    switch title {
                    case "收藏":
                        if session.requireLoginForCollections() { session.path.append(.favorites) }
                    case "我的歌单":
                        if session.requireLoginForCollections() { session.path.append(.myPlaylists) }
                    case "我的创作":
                        if session.requireLoginForCollections() { session.path.append(.aiSessions) }
                    default:
                        // 下载管理 = M3 且受 D12 合规门控。
                        session.showToast("\(title)：该页在 M3 接入（当前仅登记入口）")
                    }
                }
            }
        }
    }
}
