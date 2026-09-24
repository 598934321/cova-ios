import SwiftUI
import ImageIO
import CovaCore

/// 封面取图的**出口守卫**（D23②）：跳转逐跳裁决，不合规的那一跳**在出站之前**就被拒。
///
/// 为什么这里必须有 delegate：`URLSession` 默认会自动跟随跨主机 302（2026-09-25 本地环回
/// 探针实测：无 delegate 时落地那台确实收到了 GET），所以只在拿到数据之后判 origin
/// 等于「让出去一次再后悔」。
private final class CovaArtworkEgressGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let landing = request.url else {
            completionHandler(nil)
            return
        }
        // 封面腿一个凭证都不该带；带了就走「凭证类」那一条（只能同源），名单主机一律不跟。
        let carriesCredentials = request.value(forHTTPHeaderField: "Authorization") != nil
        guard CovaEnvironment.mediaRedirectAllowed(
            from: original,
            to: landing,
            carriesCredentials: carriesCredentials
        ) else {
            completionHandler(nil)
            return
        }
        var sanitized = request
        sanitized.httpMethod = "GET"
        // 纵深防御：放行也不许把 Authorization 带进存储主机（硬边界 3）。
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(sanitized)
    }
}

// MARK: - 美术腿的唯一裁决面（D23 / R18-2）

/// 服务端**美术原文**（`artist.avatar` / `track.cover` / `playlist.coverUrl` /
/// `coverMedia.imageUrl` / 本机 `recent.coverURLString`…）→ 三件**互相可分辨**的事实之一。
///
/// 为什么这一层必须有它（这是 R16-1 家族在这一层的**第二条** live 缺陷，R18-2）：
/// 2026-09-25 本仓只读复核 `GET /api/artists` —— 13 行里 **12 行的 `artist.avatar` 是站内相对路径**
/// （剩下 1 行是封面桶绝对地址）；`GET /api/tracks` 20 行里 `cover` 20/20 是封面桶绝对地址，
/// 而**内嵌**的 `artist.avatar` 是 11 行站内相对 + 9 行没有。另按 `docs/decisions.md` §S补充3
/// 的第 18 轮实测（测试账号，匿名打同一端点是 401，本仓复现不了原文）：
/// `GET /api/user-playlists` 的 `coverUrl` / `imageUrl` 是**站内相对且带查询串**。
/// 而各条美术腿原先直接 `URL(string: 服务端原文)` 交给 `CovaArtwork`：相对串没有 scheme ⇒
/// `CovaArtworkCache.fetch` 的出口判定为假 ⇒ **一次请求都不发**，只留下一张音符占位 ——
/// 没 error、没日志，用户唯一能看到的是"图没出来"。
///
/// 本类型**不新增任何判据**，只把 CovaCore 已有的三道按顺序接起来，UI 层因此不可能写歪：
/// · `CovaEnvironment.resolveMediaURL`：站内相对补成生产 origin，查询串**逐字节**带走（R17-6）；
/// · `CovaEnvironment.isSanctionedMediaURL`：生产出口 ∪ 许可名单存储主机
///   （名单只在 `CovaEnvironment.sanctionedStorageBuckets` 一处定义）；
/// · `CovaEnvironment.egressHostLabel`：拒绝时点名的那台 host（D23③，与音频腿/跳转腿同一口径，
///   取不出 host 时同样是 `unnameableHostLabel` 而不是整串地址）。
///
/// 拒绝必须**看得见是哪一台 host**（D23③）：桶名或存储区一变，这里的文案就是那条故障的
/// 唯一可定位线索 —— 而不是又一张悄悄出现的占位图。
public enum CovaArtworkResolution: Equatable, Sendable {
    /// 服务端这一行**没给**美术（nil / 空串）⇒ 占位是**正确**行为，不是故障。
    case absent
    /// 有可出站的地址：站内相对已补成生产 origin、查询串原样保留、host 在名单内。
    case resolved(URL)
    /// 服务端**给了**一个不可出站的地址：非名单 host、`http://`、协议相对 `//host/x`、
    /// userinfo 逃逸 `https://covalink.cn@evil.test/`（host 如实报 `evil.test`）——
    /// 点名那一台 host（只有 host：path / query / userinfo 一概不带，硬边界 3）。
    case refused(host: String)

    /// 美术腿的正路：服务端原文 → 裁决结果。
    /// nil 与空串都是「这一行没给图」⇒ `.absent`（占位是正确答案，不是故障）。
    public init(serverValue raw: String?) {
        guard let raw, raw.isEmpty == false else {
            self = .absent
            return
        }
        // 第一道：形状与补全（相对→生产 origin，查询逐字节；非法形态一律 nil）。
        guard let url = CovaEnvironment.resolveMediaURL(raw) else {
            self = .refused(host: Self.hostLabel(of: raw))
            return
        }
        // 第二道：出口名单（与 `CovaArtworkCache.fetch` 同一函数，这里只是把它提前到
        // **发起之前**并给出可读结论；`fetch` 里那道兜底原样保留，不拆）。
        guard CovaEnvironment.isSanctionedMediaURL(url) else {
            self = .refused(host: Self.hostLabel(of: url.absoluteString))
            return
        }
        self = .resolved(url)
    }

    /// 同一张图的**多个候选字段**按顺序裁决（歌单图在线上被写在 `cover` / `coverUrl` /
    /// `coverMedia.imageUrl` 三处，同一行未必三处都有）。
    ///
    /// 取第一个**非空**原文再判一次：空串在这里当"没给"处理，好让后面那个真值有机会出现 ——
    /// 这是原 `??` 链的一个真实失效面（`cover == ""` 会把 `coverUrl` 挡掉，图就此空白且无声）。
    public init(serverValues raws: [String?]) {
        guard let raw = raws.first(where: { $0?.isEmpty == false }) else {
            self = .absent
            return
        }
        self.init(serverValue: raw)
    }

    /// 上游已经解析好的地址（播放器 `item.coverURL?.value` 那一类腿）：**同一条名单判据**，
    /// 不因"已经是个 URL"就免检 —— 否则第二条静默占位通道就从这里长回来。
    public init(resolvedURL url: URL?) {
        guard let url else {
            self = .absent
            return
        }
        self = CovaEnvironment.isSanctionedMediaURL(url)
            ? .resolved(url)
            : .refused(host: Self.hostLabel(of: url.absoluteString))
    }

    /// 可直接取图的地址；`.absent` / `.refused` 为 nil（调用方不得拿它去发请求）。
    public var url: URL? {
        if case .resolved(let url) = self { return url }
        return nil
    }

    /// 拒绝时给人读的那一句：分支 + host，**只有**这些。
    /// 没有 path、没有查询串、没有 userinfo —— 签名可能住在其中任何一处（硬边界 3）。
    public var refusalMessage: String? {
        guard case .refused(let host) = self else { return nil }
        return "美术地址不可出站：\(host) 不是生产出口也不在许可名单的存储主机内（该次请求未发出）"
    }

    /// 拒绝时要点名的那一台主机：一律交回 `CovaEnvironment.egressHostLabel`（D23③ 的唯一口径 ——
    /// 只有小写 host，path / query / userinfo 一概不带；取不出 host 即 `unnameableHostLabel`）。
    /// **绝不**回退成整串地址：签名就住在查询里（硬边界 3）。
    private static func hostLabel(of raw: String) -> String {
        guard let url = URL(string: raw) else { return CovaEnvironment.unnameableHostLabel }
        return CovaEnvironment.egressHostLabel(of: url)
    }
}

/// 封面位图的**内存缓存**（PLAN M3：首屏与滚动 60fps）。
///
/// 原实现没有缓存：`CovaArtwork` 每次在列表里重新出现就重跑一次 `.task` ⇒
/// 「滚一条 20 项的列表」＝「把 20 张封面重下重解 20 遍」；而 `UIImage(data:)` 会把
/// 后端给的整幅原图（常见 1200–3000px）解出来，那笔解码落在主 actor 上就是掉帧。
/// 两件事一起补：按 URL 缓存已解出的位图 + 用 ImageIO 直接解出降采样位图。
///
/// 封面是公开资源（不含 token / 签名参数），所以缓存不需要随登出清理；
/// `NSCache.totalCostLimit` 负责淘汰。
enum CovaArtworkCache {
    /// 降采样上限（长边像素）。本 App 最大的封面位是全屏播放器的封面 ≈ 340pt，
    /// @3x 也只要 1020px —— 取 1024 既不掉画质也不留原图的体积。
    private static let maxPixel: CGFloat = 1024

    /// 出口受控的取图会话（D23②）：`URLSession.shared` 在 CovaUI 里从此不再出现 ——
    /// ephemeral（地址与字节都不进磁盘缓存）+ 禁 cookie + 跳转按上面的守卫裁决。
    /// 超时按「小图快取」形状给（不是音频那套 7 天资源超时）。
    nonisolated(unsafe) private static let egressSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 5 * 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: CovaArtworkEgressGuard(),
            delegateQueue: nil
        )
    }()

    /// D23② 的出口判定：生产 origin ∪ 许可名单存储主机（名单只在
    /// `CovaEnvironment.sanctionedStorageHosts` 一处定义）。**发起之前**判。
    static func isSanctioned(_ url: URL) -> Bool {
        CovaEnvironment.isSanctionedMediaURL(url)
    }

    @MainActor private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024  // cost 以 KB 计 ⇒ ≈64MB 位图
        return cache
    }()

    @MainActor static func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    @MainActor static func insert(_ image: UIImage, for url: URL) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: url.absoluteString as NSString,
                        cost: max(1, Int(pixels / 1_024)))
    }

    /// 下载 + 解码都在**非主 actor** 上做；主 actor 只碰缓存与最终位图。
    ///
    /// 名单之外的地址返回 nil，**不发一次请求** —— 不是红屏：
    /// 封面今天就是跨源在 COS 上，把「唯一出口」照字面执行成「只准 covalink.cn」
    /// 会让每一张封花都失败（那是把守卫写错，不是把策略写对；见 D23 的理由列）。
    ///
    /// 这一道是**第二层**：发起之前该拒的 host 由 `CovaArtworkResolution` 裁决并让 UI 说得出口
    /// （R18-2），这里只保证「绕过裁决面的那条腿」（`init(url:)` 直接喂地址）同样出不了网。
    @MainActor static func fetch(_ url: URL) async -> UIImage? {
        if let hit = image(for: url) { return hit }
        guard isSanctioned(url) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let (data, response) = try? await Self.egressSession.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  // 投递面兜底（与音频层 C2 同一口径）：落地那一条仍必须在名单内。
                  // delegate 只挂在**我们自己建的**会话上，判一次不贵。
                  let landing = http.url, Self.isSanctioned(landing) else { return nil }
            return downsampled(data)
        }.value
    }

    private nonisolated static func downsampled(_ data: Data) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumb = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

/// 封面图（异步加载 + 占位 + 失败回退）。**签名 URL 不回显**：日志与无障碍标签只含曲目名。
///
/// 两条入口，同一个裁决面（R18-2）：
/// · `init(resolution:title:)` —— 服务端**原文**腿（封面 / 头像 / 歌单图）走这里，
///   进位前已由 `CovaArtworkResolution` 补全 + 名单裁决（各屏的腿在 `CovaFeature`）；
/// · `init(url:title:)` —— 上游已解析成 `URL` 的腿（播放器封面）走这里，
///   但**同样过一遍名单判据**（`CovaArtworkResolution.init(resolvedURL:)`），不免检。
///
/// 「没给图」与「给了但不可出站」是**两种不同**的占位：前者是正确行为（音符），
/// 后者是一次看得见的出口拒绝（警示三角 + 无障碍标签点名 host）。
public struct CovaArtwork: View {
    private let resolution: CovaArtworkResolution
    private let title: String
    @State private var phase: Phase

    /// `.placeholder` = 「这一行没有可显示的封面」（服务端没给，或给了但取不到）；
    /// `.refused` = 「给了一个不可出站的地址」—— 两类占位分家就是 R18-2 要的可见性。
    private enum Phase { case loading, loaded(Image), placeholder, refused }

    public init(resolution: CovaArtworkResolution, title: String) {
        self.resolution = resolution
        self.title = title
        // 只有「还要去取」的那一档才进 `.loading`：缺图与拒绝在构造时就已定案，
        // 让它们先闪一下转圈再变占位，读起来像"在取但很慢"。
        switch resolution {
        case .resolved: _phase = State(initialValue: .loading)
        case .absent: _phase = State(initialValue: .placeholder)
        case .refused: _phase = State(initialValue: .refused)
        }
    }

    /// 上游已解析成 `URL` 的腿（播放器 `coverURL`）：**同一条名单判据**，不免检。
    public init(url: URL?, title: String) {
        self.init(resolution: CovaArtworkResolution(resolvedURL: url), title: title)
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
            case .placeholder:
                Image(systemName: "music.note")
                    .foregroundStyle(CovaColor.muted)
            case .refused:
                // 与 `.placeholder` 分家的唯一理由：出口拒绝是**故障**，
                // 不该长得像"这首本来就没封面"。
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(CovaColor.muted)
            }
        }
        .accessibilityLabel(accessibilityText)
        .task(id: resolution) { await load() }
    }

    /// 拒绝时把「是哪一台 host」并进无障碍标签（VoiceOver 与人工走查都读得到）；
    /// 其余只报曲名 —— 地址本身（含查询里的签名）一次都不回显。
    private var accessibilityText: String {
        guard case .refused = phase, let message = resolution.refusalMessage else { return title }
        return "\(title)：\(message)"
    }

    private func load() async {
        switch resolution {
        case .absent:
            phase = .placeholder
        case .refused:
            // 出口拒绝不重试：重放只会把同一条裁决再判一次，且**一次请求都不该发**。
            phase = .refused
        case .resolved(let url):
            if let cached = CovaArtworkCache.image(for: url) {
                phase = .loaded(Image(uiImage: cached))
                return
            }
            phase = .loading
            let image = await CovaArtworkCache.fetch(url)
            // 被取消**不是失败**（`.task(id: resolution)` 换封面时就会取消上一轮）：
            // 这里若把取消写成占位，列表换绑的瞬间会闪一下音符。
            guard !Task.isCancelled else { return }
            guard let image else { phase = .placeholder; return }
            CovaArtworkCache.insert(image, for: url)
            phase = .loaded(Image(uiImage: image))
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
    /// `unauthenticated` 单独立一种：design 08/09 要求 401 说「登录状态已过期，请重新登录」，
    /// 而不是混进通用的「服务暂时不可用」—— 用户能自己解决的事，不该长得像服务端故障。
    public enum Kind { case network, server, unauthenticated, backendGap(String) }
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
        if case .unauthenticated = kind { return "person.crop.circle.badge.xmark" }
        return "wrench.and.screwdriver"
    }
    private var title: String {
        switch kind {
        case .network: return "网络不可用"
        case .server: return "服务暂时不可用"
        case .unauthenticated: return "登录状态已过期"
        case .backendGap: return "该能力尚未上线"
        }
    }
    private var hint: String {
        switch kind {
        case .network: return "检查连接后重试；播放中的曲目不受影响。"
        case .server: return "稍后再试。已登记在服务端待办中。"
        case .unauthenticated: return "请重新登录后继续。本机不会替你保留未同步的写操作。"
        case .backendGap(let id): return "后端契约缺口 \(id) 已登记（NEEDS.md），上线后此处自动可用。"
        }
    }
}

/// 骨架屏。**这里是"整块呼吸"，不是 shimmer** —— design §17 §S1「不做的事」明令不做高光扫过
/// （与克制基调冲突，且低值机型掉帧），Reduce Motion 下退化为静态灰块。
/// 与 §S1 的完整"骨架族"仍有差距，已登记 TD-49（分族、行数与文本条长度档）。
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
