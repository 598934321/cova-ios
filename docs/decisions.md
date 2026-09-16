# decisions.md — 锁定技术决策

> 变更流程：用户批准 → 更新本表 → 必要时更新 PLAN/PRD。状态：🔒 已锁定 / ⏳ 待批准。

| # | 决策 | 理由 | 状态 |
|---|---|---|---|
| D1 | **SwiftUI + Swift Concurrency（async/await），部署目标 iOS 26** | iOS 27 已发布（2026-09），26+ 为绝对主流；原生 Liquid Glass API（`glassEffect` 等）仅 26+ 可用；本机 Xcode 26.6 就绪 | ⏳ G0 待批准 |
| D1' | （备选）iOS 17+ + 自制玻璃 fallback | 覆盖面换材质保真，+1–1.5 周，两套视觉分支。仅当必须覆盖旧机时启用 | 备选 |
| D2 | **XcodeGen**：`project.yml` 入 git，`*.xcodeproj` 不入 | 与 mac app / 词格本惯例一致；`.gitignore` 已预留 | 🔒 |
| D3 | **SwiftPM 本地包分层 + 零第三方依赖白名单** | 包：`CovaCore`（模型/API/认证/SSE/幂等/持久化，纯逻辑全 XCTest）、`CovaPlayer`（AVPlayer 封装）、`CovaUI`（tokens/材质/组件/动效）、`CovaFeature`（各屏）。白名单初始为空，新增依赖须批准 | 🔒 |
| D4 | **AVPlayer 自研播放层** | 规避 RN 版 RNTP 商业许可问题；锁屏/耳机走 MPRemoteCommandCenter；`UIBackgroundModes: audio` | 🔒 |
| D5 | **Bearer + Keychain 认证** | access+refresh 存 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）；single-flight refresh，401 重放一次；持久化按 owner（principalId）绑定；登录 intent CAS 防竞态。阻塞依赖 NEEDS-1 | 🔒 |
| D6 | **SSE 优先 + 轮询降级** | URLSession `bytes` 解析；降级条件：10s 无首事件 / 30s 静默 / 3 个坏事件 / done 前 EOF → `GET plans` 每 5s 轮询，不与 SSE 并发 | 🔒 |
| D7 | **双 Demo 终态硬规则 + 私有音频本地化** | 只取前两候选，两个都 settled（ready+URL 或 failed）才终态；私有音频先 Bearer 下载到沙盒校验非空再 `file://` 播放；Bearer URL 不进日志/持久化 | 🔒 |
| D8 | **扣费写操作必带幂等键**；登出/换号清队列、清私有音频/封面缓存、推进会话 generation | 防重复扣费与串号 | 🔒 |
| D9 | 持久化 = **Codable JSON + 沙盒文件**，不用 SwiftData/CoreData | 词格本惯例；数据量小、迁移简单 | 🔒 |
| D10 | 播放上报 `source: "app-ios"`；网络出口仅 `https://covalink.cn` HTTPS | 复用 RN 版 source 值（NEEDS-2）；禁连 staging/私网 | 🔒 |
| D11 | 只改本仓、不碰生产；凭证禁入日志；后端需求一律写 `NEEDS.md` | 全项目硬边界 | 🔒 |
| D12 | **v1.0 无任何购买/充值入口**，仅展示余额；下载扣费代码可实现但 UI 入口待合规评审 | Apple IAP：co 币属数字商品，贸然上架必拒。沿用微信小程序 D-011 同策略 | ⏳ G0 待批准 |
| D13 | bundle id 建议 `cn.covalink.ios`；App 显示名待定（设计阶段定） | 与 RN 版 `cn.covalink.mobile` 区分，两个 App 并存 | ⏳ G4 前定 |
| D14 | 字体用系统 SF Pro / SF Mono，不打包 Inter | 省体积；系统字与品牌栈足够接近 | 🔒 |
| D15 | 歌词 = 静态展示（`track.lyrics` 文本滚动视图），不做逐行同步歌词 | 后端无时间轴数据 | 🔒 |
