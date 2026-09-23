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

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: CovaSpace.lg) {
                profile
                entries
            }
            .padding(.vertical, CovaSpace.xl)
        }
        .covaPage()
        .task { me = try? await CatalogService(client: session.client).me() }
    }

    @ViewBuilder
    private var profile: some View {
        switch session.authPhase {
        case .signedIn(let user):
            CovaCard {
                VStack(alignment: .leading, spacing: CovaSpace.sm) {
                    Text(user.name).font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    if let me {
                        Text("计划：\(me.entitlements.plan.rawValue)")
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                        // D12：只展示余额，**不放任何购买/充值入口**。
                        Text("剩余 co 币：\(me.entitlements.creditsBalance)")
                            .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
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
            ForEach(["收藏", "我的歌单", "我的创作", "下载管理"], id: \.self) { title in
                CovaListRow(title: title, subtitle: nil, artwork: nil) {
                    Image(systemName: "chevron.right").foregroundStyle(CovaColor.muted)
                } action: {
                    switch title {
                    case "收藏":
                        if session.requireLoginForCollections() { session.path.append(.favorites) }
                    case "我的歌单":
                        if session.requireLoginForCollections() { session.path.append(.myPlaylists) }
                    default:
                        // 我的创作 = M2（AI 会话），下载管理 = M3 且受 D12 合规门控。
                        session.showToast("\(title)：该页在 M2/M3 接入（当前仅登记入口）")
                    }
                }
            }
        }
    }
}
