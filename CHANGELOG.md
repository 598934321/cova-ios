# Cova iOS 版本更新记录

> 每次发版/批次递增 `project.yml` 的 `CFBundleShortVersionString` +
> `CFBundleVersion`（小 +0.0.1 / 大 +0.1），并把那批干了什么记在这里。
> 逐日细节看 `docs/log/YYYYMMDD.md`；验收截图看 `docs/acceptance/`。
> 本文件按版本号倒序（新在上）。

---

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
