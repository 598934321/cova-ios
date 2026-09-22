# decisions.md — 锁定技术决策

> 变更流程：用户批准 → 更新本表 → 必要时更新 PLAN/PRD。状态：🔒 已锁定 / ⏳ 待批准。

| # | 决策 | 理由 | 状态 |
|---|---|---|---|
| D1 | **SwiftUI + Swift Concurrency（async/await），部署目标 iOS 26** | iOS 27 已发布（2026-09），26+ 为绝对主流；原生 Liquid Glass API（`glassEffect` 等）仅 26+ 可用；本机 Xcode 27.0 + iOS 27 SDK 就绪（部署目标仍为 26） | 🔒 已批准（2026-09-17 G0 闸门） |
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
| D12 | **v1.0 无任何购买/充值入口**，仅展示余额；下载扣费代码可实现但 UI 入口待合规评审 | Apple IAP：co 币属数字商品，贸然上架必拒。沿用微信小程序 D-011 同策略 | 🔒 已批准（2026-09-17 G0 闸门） |
| D13 | bundle id 建议 `cn.covalink.ios`；App 显示名待定（设计阶段定） | 与 RN 版 `cn.covalink.mobile` 区分，两个 App 并存 | ⏳ G4 前定 |
| D14 | 字体用系统 SF Pro / SF Mono，不打包 Inter | 省体积；系统字与品牌栈足够接近 | 🔒 |
| D15 | 歌词 = 静态展示（`track.lyrics` 文本滚动视图），不做逐行同步歌词 | 后端无时间轴数据 | 🔒 |
| D16 | **取消语义 = 有界语义**（OneStep 流式会话）：① `cancel()` 返回后**不再调度新的轮询/SSE 周期**；② 任何已发起（已授权）的传输**必须被立即取消**（URLSession 层），不得完成或投递结果；③ 允许「取消检查与传输发起之间」的窄窗口出现**一次已授权的传输调用**，但它必须被取消且结果不得投递；④ 该窗口**不得用于任何写/扣费操作**（SSE 与 plans 轮询均为读路径；写/扣费路径需在此之上另加同步门）；⑤ 门禁测试必须**确定性**，禁止依赖调度竞态断言绝对「零传输调用」 | 协作式取消无法把「`Task.isCancelled` 检查 + `await` 发起传输」原子化——检查与发起之间有 await 边界，除非引入同步临界区（与 Swift Concurrency 结构性冲突、代价过高）。绝对「cancel 返回后零传输调用」在当前架构下不可达；改为可验证的有界不变量 | 🔒 已批准（2026-09-17 G3-d 复审协调者裁决） |
| D17 | **设计闸门偏离登记（2026-09-21，用户裁决）**：G1 方向稿经用户验收**判定未通过**，而用户同时裁决「**先由代理补 G2 全量稿**」⇒ 本轮 `design/screens/` 21 份逐屏规格（18 屏 + 12 号屏拆 a–d）+ `inventory.md` 由代理代产出，属 AGENTS.md 硬边界 8「G1/G2 未经用户验收不写 UI 代码」的**顺序偏离**，按该条要求在此登记并**限期补验** | 偏离的只是「设计文档由谁先写」：**UI 代码禁令一条都没解除** —— 门禁第 6 步已把禁 UI 换成**白名单**形态机制化（播放器层只允许 `Foundation/AVFoundation/CovaCore/MediaPlayer`，测试 target 再加 `XCTest`；UIKit 仅容忍 weak 形态），不是口头承诺。**补验期限 = M1 开工前**：G1/G2 必须由用户逐屏验收，代产出的规格在验收前只是「待审草案」，任何一格未过即按用户意见回炉，不得默认当作已批 | ⏳ 待用户验收（M1 前） |
| D18 | **失败终态的唯一来源 = 计数账**（G3-e 环 4 定口径，第 11 批/11B）：`failureStreak` 是「自动推进已停止」的唯一裁决依据；`lastFailure` 降格为**回显账**（含 `.cancelled` / `.staleSession` 这类不计数形态），只供 UI 提示与诊断，**不参与任何裁决**。被取消的装载收敛为 `.stopped` 且**不开终态** | design §9「连续 3 次失败停止并提示」的「失败」原本未区分计数/回显，两种形态混在一本账上会造出「没有失败却进失败终态」的谎报（F-A 修了两轮才定位到这里）。M1 的错误 UI 必须按这条读：**提示**读 `lastFailure`，**是否停止自动推进**读 `isFailureTerminal`/`failureStreak`；两者的清空时机也不同（重试入口清两本，良性导航一本都不清） | 🔒 已批准（2026-09-22 G3-e 环 4 协调者裁决，待第 7 轮复审确认） |
| D19 | **用户授权「先做完整、后看效果再提修改意见」**（2026-09-22 用户原话：「需要决策时你从专业角度做决策，我需要看到开发完成的效果再给你修改意见」）⇒ ① 硬边界 8 的偏离**扩档**：允许按代理产出的 G2 规格（D17）实现 UI 代码，用户验收从「开工前」改为「看到可运行效果后」；补验 = 用户逐屏修改意见回炉，期限 = 用户首次反馈后一周内。② 产品口径裁决权移交协调者（含 §14 D′ 第 5 条：单元素 `.all` 正在响时 ⏭ = **重播**，与 `PlayQueue` 既有 `.userInitiated→wrap` 口径一致；若用户看效果后反对再同改 `PlayQueue.wrap` 与 design §9）。③ **不变的红线**：网络出口仅 `https://covalink.cn`；契约 mock 仅限本地 JSON 且**不得进入验收证据**；凭证/签名 URL 禁日志；零第三方依赖；后端缺口只登记 NEEDS | 用户明确把决策权与验收次序交给执行侧；AGENTS.md 硬边界 8 允许「获批准偏离 + 登记 + 限期补验」 | 🔒 已批准（2026-09-22 用户） |
| D20 | **登录解码在客户端侧容忍后端缺字段（NEEDS-1 的处置，不改后端、不删契约）**：`AuthUser` 手写 `init(from:)` —— 身份标记 `isArtist`/`isPartner` 缺席读 `false`（**保守方向**：绝不因后端缺字段放大权限），`email`/`covaId`/`phone` 缺席读 `nil`；而 `id`/`name`/`role` **仍严格必需**，缺任一个照旧抛 `CovaAPIError.decoding(field:)`（身份不许猜）。契约形态一个字段不删，`docs/NEEDS.md` #1 仍是开放项，后端补齐后容忍逻辑自动退化为无操作。同时改写 `testLoginResponseRequiresFullAuthUserContract` → `testLoginToleratesRealBackendUserShapeButKeepsIdentityStrict`（容忍侧 + 严格侧同一用例双向钉住） | 旧口径把真实响应钉成「必须解码失败」⇒ 真机上**永远登不进来**，登录后的私有音频下载（D7 Bearer）与播放上报（P5）整条链路无从被用户看见/验收，直接抵触 D19「看到开发完成的效果」。仓内既有先例：NEEDS-8/9/10/11/12 均为「客户端已按可选容忍」 | ⚙️ 协调者依 D19② 专业裁决（2026-09-22）；待用户看效果后确认 |

> **D18 附注（第 13 批，R7C 裁决落档）**：非法 `consecutiveFailureLimit`（≤0）取 **clamp 到 1**，
> 不取「惰性」。理由：非法配置不得静默改写自动推进策略 —— 惰性等于「永不进终态」= 无限自动
> 重试 / 无限私有音频出站与扣费面；clamp 到值域下限至多让播放器更早停下请用户处置。
> 「终态 ⟹ streak>0」在两种口径下都不破，故这是口径而非缺陷；clamp 到 `default(3)` 被否，
> 因为把用户写的数字换成默认值等于撒谎。第 8 轮 b 复审认可此裁决。
