# Cova iOS 版本更新记录

> 每次发版/批次递增 `project.yml` 的 `CFBundleShortVersionString` +
> `CFBundleVersion`（小 +0.0.1 / 大 +0.1），并把那批干了什么记在这里。
> 逐日细节看 `docs/log/YYYYMMDD.md`；验收截图看 `docs/acceptance/`。
> 本文件按版本号倒序（新在上）。

---

## 0.3.9 (111) — 2026-11-06

两处 UI 修复（用户实机看过 iPad 版后提的两个问题）。**不动结构，只改位置与节奏。**

- **iPad 侧栏默认回到左侧**：用户原话「边栏为什么默认在顶上……边栏一般还是放在左侧」。
  根因是 `.tabViewStyle(.sidebarAdaptable)` 只声明「可侧栏/可顶栏」，**默认落哪边由系统按宽度自己决定** ——
  iPad 竖屏时系统收成了顶栏（6 格横排）。修法：显式加 `.defaultAdaptableTabBarPlacement(.sidebar)`
  钉死默认 = 左侧栏（iOS 18+ API，部署目标 26.0，无需 `#available`；全仓此前 0 命中）。
  竖屏是**浮层**形态（默认收起、点开覆盖），与 Apple Music 一致——**用户已确认接受浮层**，
  不改成 `NavigationSplitView`。
- **歌单页信息密度**：用户原话「歌单页看起来信息太密集了」，要求对齐新版 Apple Music。
  原值是组内 `CovaSpace.xs`=4 / 组间 `CovaSpace.lg`=16，卡片内部的留白节奏与卡片之间几乎一样
  ⇒ 眼睛看到的是一片连续文字块。改三处数值（**不动全局 token**，理由见下）：
  - 卡片内 `VStack` spacing 4 → **6**
  - 网格 `LazyVGrid` spacing 16 → **24**
  - 标题 `lineLimit` 2 → **1**（Apple Music 就是单行，超出省略）

  **为什么不改 `CovaSpace.xs/lg`**：这两个 token 被全站大量引用，改 token 值会波及每一个用它的页面，
  那是「顺手优化全站」而不是修这一屏。节奏值就近定义在 `PlaylistsPlazaView` 内的
  `private enum CardRhythm { intraCard = 6, interCard = 24 }`——私有、不可实例化，
  只有这一屏能用，别人捡不走也波及不到别处。

  像素量测（iPad 竖屏 @2x，改前 → 改后）：文字块高 64.5 → 50.5pt（标题少一行）、
  末行文字→下一封面间距 18.5 → 26.5pt（组间 16→24）、卡片节距 232.0 → 226.0pt。

**门禁**：`CovaTests` 2 / `CovaCoreTests` 1003 / `CovaFeatureTests` 345 / `CovaPlayerTests` 483，
覆盖率 5920/6279 = 94.28% 与 3806/4000 = 95.15%，`EXIT=0`。

**未覆盖**：iPad 分屏（Split View / Slide Over）未实测——`defaultAdaptableTabBarPlacement` 在 compact 宽下
会不会影响底栏，**没跑过就不能说成立**；深色模式与 AX 动态字号档同样未验；全部为模拟器，无真机。

---

## 0.3.8 (110) — 2026-11-04

本轮把 2026-10-30 起累积的三批（契约追平 / 死锁修复 / t74 设计对齐）收进同一版本锚点。
`CFBundleShortVersionString` 0.3.7→0.3.8、`CFBundleVersion` 109→110。

- **R1 Lyria 引擎清单**（COVA-20261024-003）：新增 `LyriaModelDTOs` / `GenerationPollBackoff`、
  `StudioCreateService.lyriaModels()`、`StudioCreateFlow.loadLyriaModels(force:)`；
  以 `GET /api/lyria/models` 为唯一来源，不硬编码清单、不重排；可内存缓存 ≤60s；
  失败回退上次成功结果并标「可能过期」；空列表给可重试提示。
- **引擎清单首拉死锁修复（模拟器实拍发现的真 BUG）**：`.task { await loadLyriaModels() }`
  原先挂在 `engineCard` 内部，而该卡渲染条件是 `lyriaCatalog != nil`（正是这次加载的赋值）
  ⇒ **卡等自己**：不渲染 ⇒ task 不执行 ⇒ 永远 nil，创作台「生成引擎」区块整块不出现。
  修法：`.task` 移到无条件 body 层级（`StudioCreateView.swift:71`）。
  **1817 条既有用例一条都没覆盖「视图首次出现时会不会去拉」**，纯逻辑层也表达不了这种错误形状
  ⇒ 补回归用例 `testLyriaFirstLoadIsNotNestedInsideTheConditionalCard`，变异自证：塞回卡内 1 failure，移出即绿。
- **R2 生成轮询**：终态只认 `succeeded/failed/cancelled`；退避 1/2/4/5s；页面不可见暂停、恢复可见立即补拍。
  `failed` 只按 `status` 收敛并显示 `errorMessage`，**不按 `retryable` 分档**（契约裁定 `generation_jobs`
  不提供 `error_code`/`retryable`）。
- **端点漂移基线**补 `/api/lyria/models`（单独成提交；生成动作来源待考，内容已验证
  「含该行 EXIT=0 零漂移 / 去掉 EXIT=1 报新增路径」）。
- t74 多端设计对齐（登录/播放/播放全部改中性胶囊、原生 iPad、顶层歌单页签）随本版一并计入，
  细节见下方「未发版 — 2026-11-02」条目。

**门禁**（2026-11-04 干净克隆 `bash Scripts/check.sh` 实测，EXIT=0）：`CovaTests` 2 / `CovaCoreTests` 1003 /
`CovaFeatureTests` **345**（基线 329，t74 新增 13 条 + 本批回归用例）/ `CovaPlayerTests` 483，
覆盖率 `5920/6279 = 94.28%` 与 `3806/4000 = 95.15%`；产物保真 `cn.covalink.ios 0.3.8(110)`。
**未覆盖**：真机扣费验收链（`CovaAcceptance` 不在门禁内）、
维护窗口「正在更新」文案（`.isRetryable` 判 `>=500` 行为已正确，仅缺文案，裁定不做）。

---

## 未发版 — 2026-11-02（t74 多端设计对齐，待 Xcode 验证）

- 对齐 web v2.77.75 `7003ed8a` 实拍（`qa-evidence/t74-clients/web/`）：「登录」「播放」「播放全部」由 `.brand` 渐变改为 `.primary` 中性玻璃胶囊；
  品牌渐变只保留在创作页「开始制作」（与 web 生成按钮一致）。
- 版本号不在此 PR 递增：与 PR #1（0.3.8）合并顺序由 Xcode 验证后决定。
- **原生 iPad**（用户裁决）：`TARGETED_DEVICE_FAMILY "1,2"`、iPad 四方向；`TabView` `.sidebarAdaptable`
  （对齐 web 768 宽侧栏）；歌单广场 / 搜索分类卡 regular 宽 3 列；首页输入条 regular 宽居中限宽 720pt。
- **顶层「歌单」页签**（用户裁决）：首页 / 曲库 / **歌单** / 创作 / 我的 / 搜索（对齐 web nav）。
  `plaza` 成为歌单页签根（`isTabRoot`），`plazaSearch` / `sharedPlaylist` 归歌单栈；
  `playlist(id)` 改当前栈 push（我的歌单点卡不再被拽去首页）。04 §1/§2/§3 与新增 §9 同步修订。
- 新增用例：`AdaptiveLayoutTests`（3）+ `ShellNavigationTests` t74 段（6）。
- **t74c 复审补齐**：创作/我的页签游客引导「登录」改中性胶囊（白底 `elevated` + 深字 `fg` + 1pt `lineSubtle`，50pt）；
  歌单详情「播放全部」（`PlaylistPrimaryCapsuleButton`）同改中性（web `.cova-liquid-glass-btn--accent` 早已回落中性），禁用 opacity 0.45；
  `CovaButton` 新增 `capsule:`（默认 false），登录 / 曲目详情「播放」/ 歌手「播放全部」恢复 web `rounded-full` 胶囊
  （#3 从 `.brand` 换 `.primary` 时丢了胶囊）。spec 04/06/07/10/inventory 同步；新增 `NeutralCTAAlignmentTests`（2）。
- 首页问候首行游客态保留逗号（web `{salutation}，{displayName}` 逐字，01 §2 同步）；新增 `HomeGreetingAlignmentTests`（1）。
- 同栈 `push` 页签根屏（`.plaza` / `.aiSessions`）= 回根，不叠第二层同屏；新增 `TabRootPushTests`（1）。
- 搜索页签判据补 `isPad`：iPhone Plus / Pro Max 横屏（regular 宽）不再 6 格折「更多」；04 §1 / §5 文案同步歌单与窄栏搜索入口。

---

## 0.3.7 (109) — 2026-10-26

**「可延后」清单前四项落地**（盘点 §4；后两项按下不做的判据见
`归档/qa-evidence/多端对齐-20261026/iOS-DEFERRED-VERDICT.md`）。

- **413 输入超限**：`OneStepLyricsEditRejection` 新增 `.inputTooLong`（认 **413 状态码**、不认 code），
  话术「这段歌词太长，超出一次能处理的上限；先精简再重做。」——此前落进「服务端拒绝了这次提交」，
  用户只会把同一份超长歌词再点一次。**刻意不写「没有扣费」**：这一档没有生产实测证据。
- **重做的计量事实**：`credits.turnId` 纳入 DTO 与 `OneStepLyricsRegenerateOutcome`（不进任何分支、
  不上屏，仅供客服对账）；同时把「按 token 实扣、不再一口价」写进类型注释，禁止屏上写死价位。
- **co 明细的钱包段**：`CreditLedgerPageDto` 新增可选 `wallet{balance, purchasedCredits, purchasedCreditsExpiresAt}`
  （生产 2.77.61 `me/credits/ledger/route.ts:88-90` 实测）。文件头那句「响应只有 {entries}、余额走 /me」
  已过时，就地更正；`total`/`nextCursor` 仍未建模，**顶层 balance 仍不建模**（有断言钉住）。
  `wallet` 形状坏掉只退回 nil，不连累 `entries`。
- **作品筛选补 `generated`**：服务端词表一直是 10 值（`works.ts:301-302` = `status='succeeded'`），
  iOS 闭集只有 9 个 ⇒「已生成」这一栏无从选择。现补枚举 + chip「已生成」（排在「制作中」之前，与服务端同序）。
- 测试：Core **971**（+6：`LedgerWalletDTOTests` 5 + `turnId` 容忍 1）。
  `bash Scripts/check.sh` EXIT=0 / 10 步全过（覆盖率 CovaCore 94.30%+ / CovaPlayer 95.15%）。
  既有用例 `testNoTotalNoCursorNoBalanceAreModelled` 因新增 `wallet` 而变红 —— 按它的意图改名为
  `testNoTotalNoCursorAndNoTopLevelBalanceAreModelled` 并**收紧了断言**（顶层 balance 仍必须读不出），
  不是放宽。

## 0.3.6 (108) — 2026-10-26

**生产接口对齐批（M-1 / M-2）**：盘点（`归档/qa-evidence/多端对齐-20261026/iOS.md`）
给出的 2 项「必须改」落地。两处都在同一条钱路上：`POST /api/studio/one-step/plans/start`。

- **M-1 · 402 余额不足**：`StudioService.startPlan` 改走 `performCoded`，非 2xx 交
  `StudioStartFailure.classify` 分诊（复用 `StudioCreateRejection`，不另写词表）。
  上屏从 `HTTP 402` 变为「余额不足，本次需要 N co（这次没有扣费）」。
  服务端形状（web 2.77.61 `lib/one-step/generation.ts:803` 抛 402 + `{balance,required}`）无需改动。
- **M-2 · 429 限流**：`HTTPResponse` / `CovaHTTPOutcome` 增加**只读的** `retryAfterSeconds: Int?`
  —— 传输层只搬那一格整数，**不留 headers**（头里有 `Set-Cookie`，硬边界 3）。
  只认 RFC 7231 的 delta-seconds（纯 ASCII 数字），HTTP-date 形态刻意 `nil`（不做日历/时区换算）。
  上屏从 `HTTP 429` 变为「请求过于频繁，请 N 秒后再试」，无 `Retry-After` 时回落「请求过于频繁，请稍后再试」。
- **401 仍是跨屏语义**：start 专线只截 402/429/400/5xx，401/403 仍落 `CatalogFailure.unauthenticated`。
- 测试：Core 965（`RetryAfterHeaderTests` 7 条 + `APIClientCodedOutcomeTests` 两条接线/缺省格）、
  Feature 328（`StudioStartFailureTests` 14 条）。`bash Scripts/check.sh` **EXIT=0 / 10 步全过**
  （覆盖率 CovaCore 94.30% / CovaPlayer 95.15%，D12 12 段诱饵全抓全复原）。
  变异自证：拆掉 `classify` 的 start 分支 ⇒ 3 红；让 `Retry-After` 恒 nil ⇒ 5 红；两处还原后 md5 逐字节一致。

## 0.3.5 (107) — 2026-10-06（补记）

**任务25 设计对齐**（commit `554ba68`）：深色金属色 5 对值归零到裁定档（`_meta.rulings`）；
38 处 `.font(.system(size:)` 收编进 `CovaUI.CovaSymbol` 命名尺寸档（全为 SF Symbol，pt 零变化，
刻意不随 Dynamic Type），`tokens.json` 新增 `symbol` 区镜像；手册 zOrder 自报改为已对齐。
—— 本条为**事后补记**：当时只改了 `project.yml` 的版本字段，本文件漏记。

## 0.3.4 (106) — 2026-10-04

**09 屏 spec 对齐批**（`AISessionDetailView` 对抗性审查 → 全量重写 1700→2313 行，
两轮循环）。

- CovaCore 新增 `OneStepThinkingCopy`（web `progress-status.ts` 同构白名单，
  未公开词回落「正在整理计划细节」）+ `OneStepPlanFailureCopy`（余额拒绝词表 +
  D12 合规话术）+ `OneStepStream.pollFailureCount`。
- 降级条七变体（waiting/interrupted/unstable/resuming/pollFailing/longTask/
  offline）+ 连败 ≥4 出重试钮；PlanCard 12 态全映射（analyzing 骨架 /
  patching muted 条 / starting 菊花 / manualRecovery error 条 /
  retryable_failure 幂等键换新 / archived 50% / 零余额 error 行）；
  候选卡组标题恒 2 行；composer 玻璃卡 + lineSubtle；消息窗口化（>200 留
  100）+ 计划卡折叠 + VoiceOver 全容器标签 +「1 条新回复 ⌄」浮钮。
- 第二轮复核补落：§4.1 离线变体（判据同 17-S4/22）、`send`/`submit` 发送闸
  落到行为层（`onSubmit` 与 starter chips 都不走 `canSend`）。
- 测试：Core 956 (+6)、Feature 314 (+7)；check.sh EXIT=0 ×3；
  覆盖率 94.24% / 95.15%。

## 0.3.3 (105) — 2026-10-03

**09 卡面口径批**：PlanCard 独立容器（elevated + 1pt line + radius.card +
顶部 2pt gradient.ai 装饰条，不用 CovaCard）；状态徽标转胶囊（semantic 色
+ 同义 15% 衬底）；主钮 50pt gradient.brandButton + primaryButtonShadow；
候选卡组改大卡（1:1 封面 + 40pt 玻璃播放钮 + 底部操作条）+ 终态条同卡片框。
spec `09-ai-session-detail.md` §3.G–H 先行改过并经确认。

## 0.3.2 (104) — 2026-10-03

**与 web 统一设计语言批**（web v2.65+ 增量收口）。

- tokens v1.1.0：`color.selected`/`selectedBg`（首批 8 位 hex alpha）、
  `focusRing`、`radius.cover`=16；zOrder 修 lyrics(1200)<toast(1250)。
- 按钮全量对齐 web：primary = 中性液态玻璃，`gradient.brandButton` 只留
  hero CTA（10 登录 / 详情播放 / 艺人播放全部 / 19 开始生成 / 09 开始创作）。
- 内容区选中态全灰（曲库/级联/sort/已选 chips/会员当前列/深度思考 chip），
  页签 tint 保橙；`accentSoft` 不再承担选中态。
- 截图 22 张（11 屏 × 深浅）→ `docs/acceptance/a17-20261003/`。

## 0.3.1 (103) — 2026-10-02

**web v2.65.0 对齐批**：删号真契约接手 + 会话 title。

- `POST /api/auth/delete-account` 已上线 → §7 #4 闭合。实契约与需求单不
  完全一样（无密码复核/无冷静期/无撤销端点），按实契约如实接：五档分流
  （2xx/410 → effective；401 → unauthenticated；404/501 → unavailable；
  其余 4xx → rejected；5xx/传输 → retryable）。15 §3.G 重写：
  「注销账号」红色行 → confirmationDialog 四条后果 → 确认注销。
- 会话建时落 `title`（`POST sessions` 收 `title`，route.ts:63）；
  `normalizedTitle`（首行截 30）；列表兜底链保留（proposedTitle →
  lastMessage → 「未命名会话」）。§7 #55 部分闭合、#57 更正。
- iOS 26 差异：confirmationDialog 不渲染 `role:.cancel` 钮（SO#79819697），
  规格与死代码同步移除。
- 测试：Core 950、Feature 307；截图 `a16-20261002/`。

## 0.3.1 (102) — 2026-10-02

**Apple Music 参照改版**：原生外壳第二轮。

- 五页签 = 首页/曲库/创作/我的 + `Tab(role:.search)` 系统搜索位；
  首页改对话型（web 序章 + 底置 CovaComposer，生成/搜索两档）；
  搜索目标分「曲目（25 页签）/歌单（plazaSearch push 当前栈）」。
- 规格：04-drawer.md → 04-shell.md 重写、01 重写、新增 25；03/05/08/
  inventory/tokens 同步。
- 读图抓到并修掉：05b 空态被父级垂直居中（外层 VStack 无纵向扩展件，
  老 05 继承的洞）→ `frame(maxHeight:.infinity, alignment:.top)`。
- 截图 24 张 → `a15-20261002/`。

## 0.3.0 (101) — 2026-10-01

**审核整改 B 批（原生外壳）+ A 批（上架阻塞 A1/A2）**。

- 抽屉壳 → 原生 TabView：四页签「首页/曲库/创作/我的」各自独立
  NavigationStack，共用 session.path 整个拿掉（修复「我的→设置底栏高亮
  首页」）；点当前页签回根 + `tabBarMinimizeBehavior` 滚动收起。
- 04 抽屉整个拿掉：收藏/我的歌单/我的创作/会员挪「我的」，歌单挪首页；
  左上「Cova」胶囊删。`ShellNavigationTests` 钉页签独立栈与回根语义。
- 迷你播放条改 `tabViewBottomAccessory`；无在播不渲染也不开全屏
  （iOS 26.1+ 显式 `isEnabled` 隐藏空壳，26.0 回落只挂内容闭包）。
- 曲库搜索改 `.searchable`；设置/我的改 insetGrouped；「登出」挪设置
  底部红色破坏性钮。
- **A1 账号删除**（5.1.1(v)）：15 设置页底部「删除账号」红色行 +
  两级确认 + `DELETE /api/auth/account`（幂等键）+ 本地清理链
  （队列/缓存/owner 桶/通知）——后端端点 10-02 才上线（见 0.3.1/103）。
- **A2 StoreKit 2 内购**（3.1.1/3.1.3(b)）：`/api/iap/products|verify`
  契约 + `IAPService`（purchase/restore/finish + 待决交易恢复）+
  13 会员页购买区；「前往官网/站内不售卖」话术逐条清掉。
  服务端缺口（验签未接）登记 §7 #56——上架前必须后端先补。
- 截图 24 张（11 屏 × 深浅 + 迷你条正向态）→ `wave-20261001b/`。

## 0.2.82 (100) — 2026-10-01

**C 批六修**（不等 B 的立刻修 bug）。

- LibraryDTOs 时长「138s」→ `m:ss`（`2:18`）+ 补测试；
- 无封面作品 ⚠️ → 中性 `music.note` 占位；行内次操作收 ⋯ 菜单
  （`WorksRowMenuItemTests`）；
- 「我的」字段名 `covaId` → 「Cova 号」+ 长按复制；
- 会员权益表「每月额度」空行整行不渲染；
- 提示条挪出导航栏标题位（`.top` overlay → `tabContent` `.bottom` overlay）；
- 会话「新会话」兜底名 → 首条消息截 20 字（`session.displayTitle`）。
- 截图 12 张（6 屏 × 深浅）→ `wave-20261001/`。

## 0.2.81 (99) — 2026-09-27

**§7 #53 修复**：签完 loadMe 被同身份合并吞掉 → `force: true`；
补签 #53 设备复证并关闭；A14 账本到 20 屏成对（p3-20260927 验收包）。

## 0.2.80 (98) — 2026-09-27

**§5 P3 第二条线**：me/checkin 每日签到（11 的 C2 格）+ home/materials
刻意不接（D12 闸门：运行时下发文案扫不到）。

## 0.2.79 (97) — 2026-09-27

**§5 P3 第一条线**：05 三源（官方/每日/广场）+ 新屏 24「分享的歌单」；
PlaylistDiscovery 契约 14 条 + 判定 7 条；设备证据 8 张。

## 0.2.78 (96) — 2026-09-27

**§7 #52 断流恢复**：AgentRunRecovery 纯判据 + AgentRunService 读腿 +
AISessionDetailView 恢复轮询（runId 从 run_started 取、run.status 回读
对账、终态即停）；9 条判据用例。

## 0.2.70–0.2.77 (87–95) — 2026-09-24~26

**隔离复审 19/20 轮修复**（Major/Minor/m 全处置）+ 走查播放钩子
（COVA_PREVIEW_PLAY 真取数真播放）+ FEATURE_MIN 接入 + 文案收口
（把客户端的事记到后端账上的三处）+ extras/works/credits/producers
五屏整批落地（0.2.75/93 前后）+ §7 #50 修复（.task(id:) 自我取消）。

## 0.2.65–0.2.69 (76–80) — 2026-09-24~25

**G3-e 多轮修复批**：PLAYER_MIN 连续抬升（397→409→415→422→429→442→448）、
私有音频收尾 + M1 竖切后门禁实测对齐。

## ≤0.2.64 — 2026-09-17~24

**G0–G3 工程批**（早期批次，版本 0.2.24–0.2.64）：工程骨架 XcodeGen +
四包分层、逐屏 G2 规格（04–18）、禁 UI 白名单机械化、门禁十步落地、
A1–A15 判据体系、私有音频 Bearer→沙盒、播放层自研、双 Demo 终态规则、
一步创作全链。详见 `docs/log/` 与 `docs/acceptance/` 各批档案（部分
早期日志在 G3-e 批次文档里，git tag `g3e-r13` 至 `g3e-r22`）。

---

## 版本号口径

- **小版本 +0.0.1**（0.3.3 → 0.3.4）：常规批次（新屏/修复/对齐）。
- **小版本 +0.1**（0.2.81 → 0.3.0）：结构级变化（外壳重写、大改版）。
- **Build +1**：与每次 version bump 同步递增，不回退。
- **纯文档不动**（README/DEVELOPMENT.md/HANDBOOK/CHANGELOG/log 只改文档
  时不递增版本号）。

## 测试基线账

| 版本 | CovaTests | CovaCoreTests | CovaFeatureTests | CovaPlayerTests |
|---|---|---|---|---|
| 0.3.4 | 2 | 956 | 314 | 483 |
| 0.3.3 | 2 | 950 | 307 | 483 |
| 0.3.2 | 2 | 950 | 307 | 483 |
| 0.3.1 | 2 | 950 | 307 | 483 |
| 0.2.81 | 2 | 950 | 307 | 483 |
| 0.2.78 | 2 | 902 | 251 | 483 |
| 0.2.75 | 2 | ~870 | ~240 | ~460 |
