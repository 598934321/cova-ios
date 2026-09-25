# Cova iOS 开发手册（对齐 web v2.40.1）

> 本手册是 iOS 端唯一开发手册，替代旧的 PLAN/PRD/NEEDS/api-contracts/decisions 等文档
> （旧文档已于 2026-09-26 打 bundle 存档至 `/tmp/ios-app-manuals-archive-20260926.bundle` 后删除）。
> 契约单一事实源是 web 仓代码：`多端/web/src/app/api/**/route.ts` 与其 `src/lib/` 实现，
> 设计 token 单一事实源是 `多端/web/src/app/globals.css`（@theme + `:root`/`.dark`）。
> 对齐基线：web **v2.40.1**（commit `39e80643`）；iOS 最后同步点 2026-09-25 `263e913`，
> 多端同步度审核（`多端/web/docs/multi-end-sync-audit-20260926.md`）评 **5.5/14**——
> 低分主因是 studio/create、制作人、账单流水、播放历史等新线整组未接，存量链路质量较高。

---

## 1. 产品定位与本端范围

Cova = 「会创作、可授权的音乐流媒体」：网易云式发现播放 × Suno 式一句话创作 ×
音乐 Agent（找歌/做歌同一会话入口）× 商用授权闭环（co 币）。

iOS 端 v1.0 范围（已实现 → 本手册扩展的次序）：

- **已实现（存量）**：抽屉导航 + 首页 feed；曲库多维筛选/搜索/分页；官方歌单与收藏；
  曲目收藏（含生成 note 双账分流）；邮箱密码登录（两步：建凭证 → `/me` 取权威身份）；
  AVPlayer 自研播放层（队列/循环三态/±15s/锁屏/后台播放）+ 播放上报；
  一步创作（会话/SSE/计划卡 12 态/双 Demo/候选收藏）。
- **本手册新增（对齐 web v2.40.1）**：最近播放、高级创作台（studio/create 全组）、
  作品播放上报（work_listens）与作品直存下载、extras 交付快照、制作人模式入口、
  co 币流水页；远期新线（灵感商店/签到/自建歌单/每日推荐/歌单广场/分享歌单）。
- **v1.0 不做**：任何购买/充值入口（D12 合规闸门，仅展示余额与流水）；账号删除待后端
  端点（上架前必须）；远程推送（本地通知兜底）；iPad 专版布局。

---

## 2. 技术栈与工程结构（现状）

- SwiftUI + Swift Concurrency（Swift 6 严格并发），部署目标 **iOS 26**（原生 Liquid Glass）。
- XcodeGen：`project.yml` 是唯一工程事实源，`*.xcodeproj` 不入 git；`Config/Info.plist`
  持 bundle id 与 `UIBackgroundModes: audio`。
- 版本：`CFBundleShortVersionString 0.2.70` / `CFBundleVersion 87`（project.yml:117-118）。
- **零第三方依赖白名单**（当前为空；新增依赖须批准并登记到 §7 决策账）。
- 门禁：`Scripts/check.sh` 一条命令 = xcodegen 重生成 → Debug 构建 → 全量 XCTest
  （CovaTests / CovaCoreTests / CovaPlayerTests）+ 覆盖率阈值（核心层与播放层各 ≥94%
  棘轮只升不降）+ 禁 UI 白名单 + D12 禁词扫描 + 测试数下限（`Scripts/test-count-baseline.env`）。
  `EXIT=0` 才算过；测试只调试用 `swift test --package-path Packages/CovaCore` 等，不替代门禁。

```
多端/ios app/
├── project.yml / Config/Info.plist / Cova/CovaApp.swift / CovaTests/
├── Packages/
│   ├── CovaCore/    # 纯逻辑层（平台中立：禁 UIKit/SwiftUI/#if；全 XCTest）
│   │     CovaEnvironment.swift   出口守卫（仅 https://covalink.cn；sanctionedStorageHosts 精确名单）
│   │     CovaAPIClient.swift     get/post/patch/delete + Bearer 注入 + 401 single-flight 重放
│   │     AuthSession.swift       signed-out/guest/authenticated；refresh 旋转（先 refresh 后 access 落盘）
│   │     *DTOs.swift             Auth/Library/Collection/OneStepPlan/Generation/Download/PlayReport/SSE
│   │     SSEStreaming.swift      SSE 传输 + HTTPOneStepPlanPoller
│   │     OneStepStream.swift     SSE→轮询降级状态机（10s 首事件/30s 静默/3 坏事件/EOF）
│   │     Idempotency.swift       IdempotencyKey + IdempotentRequestToken（operation↔key 绑定）
│   │     SecureStore/KeychainStore/OwnerScopedStorage/SessionLifecycle（凭证与 owner 隔离）
│   ├── CovaPlayer/  # AVPlayer 播放层（禁 UI import：仅 Foundation/AVFoundation/CovaCore/MediaPlayer）
│   │     PlayReportCoordinator.swift  播放上报去重（一次播放一键，前后台共用）
│   ├── CovaUI/      # tokens→Swift、Liquid Glass 组件、骨架/空态/徽标（无测试 target，见 §7 TD-48）
│   └── CovaFeature/ # 各屏；API 端点散在 CatalogService.swift / StudioService.swift / CovaDependencies.swift
├── Scripts/check.sh + test-count-baseline.env
├── design/          # tokens.json（iOS 单一 token 源，已测与 web 微漂移见 §3）+ screens/ + assets/
└── docs/            # log/ 分日记录 + acceptance/ 验收截图（历史档案，非手册）
```

**硬边界（原 AGENTS.md 9 条，违反即返工）**：
1. 只改本仓；不碰生产 env/DB/服务器与相邻仓。
2. 网络出口唯一 `https://covalink.cn` HTTPS；禁直连 `cova api`（127.0.0.1:3110）；
   未获批准不调写/扣费端点（只读 GET 可直连）。
3. token 对存 Keychain（`ThisDeviceOnly`，按 principalId 绑定）；token/密码/签名 URL
   禁写日志、禁入持久化索引；密钥不进 git。
4. 零第三方依赖白名单；新增须批准并登记决策。
5. 扣费与写操作必带幂等键（见 §4「幂等」列）。
6. 双 Demo 终态硬规则：一步模式只取前两候选，双双 settled（ready+URL 或 failed）才终态；
   私有音频先 Bearer 下载到沙盒校验非空，再 `file://` 播放，Bearer URL 不进日志/持久化。
7. 后端缺口登记制：缺字段/缺端点/契约不符记入 §7，**客户端不得自行改后端**。
8. 设计闸门：UI 以对齐本手册 §3 与 `design/` 为准；大改版面先出规格再实现。
9. App Store 合规（D12）：无购买/充值入口，仅展示余额；下载扣费 UI 入口待合规评审放行。

**协作约定**：Build → Verify → Commit，每步留证据；纯文档 commit 不递增版本号，
影响产物的 commit 递增 `project.yml` 两个版本字段（小 +0.0.1 / 大 +0.1）。

---

## 3. 设计规范（web token 对齐表）

来源：`web/src/app/globals.css` @theme（构建期常量）+ `:root`/`.dark`（语义层按主题切换）。
px→pt 一一对应；iOS 消费文件 `design/tokens.json` → `CovaUI`。

### 3.1 品牌色与 accent 态

| Token | 浅色 | 深色 | 用法 |
|---|---|---|---|
| `--color-cova-accent` | `#FF6B00` | `#FF6B00` | 唯一 accent：选中、主 CTA、播放中 |
| `--color-cova-accent-hover` | `#E66000` | `#FF7A1A`（tokens.json 深色档） | hover/active |
| `--color-cova-accent-soft` | `#FFF1E6` | `#3A1D05`（`.dark .cova-accent-surface` 实测） | accent 衬底/chip 选中底 |
| `--color-cova-accent-text` | `#C24E00` | `#FFB173`（`.dark .cova-accent-text`） | 浅底 accent 文字须用深橙（对比度≥4.5:1） |
| `--color-cova-ai-start/mid/end` | `#E66000 / #FF6B00 / #FFA25E` | 同 | AI 渐变组件色 |
| `--cova-ai-gradient` | `linear-gradient(110deg, #FF9A3D, #FF6B00 42%, #E84E8A, #FF9A3D)` | 同族提亮 `#FFB173/#FF8A3D/#FF7AB8` | 仅创作入口与 agent 文字 |
| `--cova-brand-gradient` | `linear-gradient(110deg, #D04E00, #C24E00 42%, #C03470, #D04E00)` | 同 | 主按钮深渐变（白字达标） |

### 3.2 中性色（`:root` / `.dark` 语义层，web v2.26 口径）

| Token | 浅色 | 深色 |
|---|---|---|
| canvas 页面背景 | `#FFFFFF` | `#0C0C14` |
| surface 分组/工具条 | `#F5F5F7` | `#12121A` |
| elevated 浮层 | `#FFFFFF` | `#1A1A24` |
| fg / fg-secondary / fg-muted | `#1D1D1F` / `#6E6E73` / `#86868B` | `#F2F0EC` / `#A1A1AA` / `#6E6E73` |
| line / line-subtle | `#E8E8ED` / `#D2D2D7` | `#252530` / `#1E1E2A` |
| hover（light/dark-hover 常量） | `#E8E8ED` | `#1E1E2A` |

历史常量（token 漂移注意）：`--color-dark-bg=#08080F`、`--color-light-bg=#F5F5F7`
已降级——页面画布一律用 canvas 语义层，不引这两个。

### 3.3 语义色 / 商务色 / 标签色

| Token | 浅色 | 深色（tokens.json 档） |
|---|---|---|
| success / error / warning | `#30D158` / `#FF453A` / `#FF9F0A` | 同 |
| membership-metal 会员金 | `#66511F`（soft `#F7F0D8` / border `#C8AA5A`） | `#D9A52F` / `#2A2210` / `#66511F` |
| enterprise-metal 企业蓝 | `#006EDC`（soft `#EAF4FF` / border `#84BDF3`） | `#79BEFF` / `#0A2540` / `#1D4ED8` |
| tag-scene / tag-mood | `#0D9488` / `#6366F1` | `#2DD4BF` / `#818CF8` |

### 3.4 字阶（iOS pt，SF Pro；全局 tabular-nums）

| 档 | 字号 | 字重 | 备注 |
|---|---|---|---|
| largeTitle / title | 34 / 28 | 700 | 字距 -0.01em |
| headline / body | 17 | 600 / 400 | body 行高 1.47（对齐 web line-height 1.47059） |
| callout / subhead / caption | 15 / 13 / 11 | 400 | — |
| mono | 13 | 400 | SF Mono / `monospacedDigit`，时码与数字位 |

### 3.5 圆角 / 间距 / 触控 / z 序

- 圆角（pt）：control **12**、surface/card **18**（`--cova-radius-surface: 18px`）、
  hero 大卡 **28**、capsule **9999**（按钮/输入/芯片）。
- 间距（pt）：xs 4 / sm 8 / md 12 / lg 16 / xl 24 / xxl 32 / pageGutter 20。
- 触控目标 ≥44pt；主按钮胶囊高 50、chip 36。
- z 序（web `--z-index-*` 实测，语义契约 toast > lyrics > dialog > overlay > player > nav）：
  nav **40** < player **1000** < overlay **1080** < dialog **1100** < lyrics **1200** < toast **1250**。
  ⚠️ `design/tokens.json` 的 zOrder 写 toast 1150 且无 lyrics 层——与 web 现行值漂移，
  iOS 以本表为准并修 tokens.json。

### 3.6 组件态

| 态 | 规则 |
|---|---|
| 默认 | fg 文字 / surface 或 elevated 底 / line 描边 |
| hover/active | accent-hover 或 `--color-light-hover #E8E8ED`（浅）/ `#1E1E2A`（深）；iOS 触控用 pressed 态映射 |
| 选中 | accentSoft 底 + accentText 字 + 1pt accent 边（chip/词条） |
| disabled | muted 底/字或灰 50% 透明；不可点的功能（如 D12 下载扣费）**不渲染**而非置灰 |
| 材质 | Liquid Glass（系统 `.glassEffect`/`regularMaterial`）承载会话框、MiniPlayer、抽屉、浮动钮；不自建模糊 |

动效：弹簧曲线对齐 `cubic-bezier(0.32,0.72,0.24,1)`；时长档 200/240/300/360/520/700ms；
全部装饰性动效必须有 Reduce Motion 替代态。

---

## 4. API 契约（以 web `route.ts` + `src/lib` 为准实测）

基址 `https://covalink.cn`；除公开浏览外均 `Authorization: Bearer <access>`；
普通请求 15s 超时；401 → single-flight refresh 重放一次。**幂等键字符集（服务端实测
`play-history.ts`）：`^[A-Za-z0-9._:-]{8,128}$`**，所有写操作沿用同一规则生成。

### 4.1 认证（已接，契约已核）

| 端点 | 请求 | 响应 / 语义 |
|---|---|---|
| `POST /api/auth/login` | `{email,password}` | `{user{id,email,name,role}, token, refreshToken, expiresIn}`；登录响应 user 是**简化身份**，权威身份走 `/me`（两步登录 D21） |
| `GET /api/auth/me` | — | 三键 `{user, entitlements, nameChange}`；`user` 在此才含 `covaId/phone/avatar/isArtist/isPartner/partnerType`；**未登录 = 401 + `{user:null}`** |
| `POST /api/auth/refresh` | `{refreshToken}` | 旋转：新 access+refresh 成对返回，先落 refresh 后落 access（D22③） |
| `POST /api/auth/logout` | — | 撤销整个 session family |
| 缺失 | `login/apple|sms|wechat|device`、账号删除 | 见 §7（NEEDS-4/5） |

### 4.2 曲库 / 歌单 / 收藏（已接）

| 端点 | 要点 |
|---|---|
| `GET /api/tracks` | 全维度 `scene/mood/genre/subgenre/style/type/instrument/attribute/energy/vocalType/key` + `search/sort/page/artistId/similarTo`；**`similarTo` 返回 similar 投影**（snake_case、featured 数字、封套回显 similarTo）⇒ 用 `SimilarTrackPageDto`，其余筛选用 `TrackPageDto`——**两套 DTO 不得混用** |
| `GET /api/tracks/:id` | `{track, similar[]}`；track 无 variant 字段族（§7 #8） |
| `GET /api/tracks/:id/preview-url` | `{url, previewStart, previewEnd, duration}`，匿名可访问 |
| `GET /api/library/taxonomy` | 词表；`subscene` 服务端未打标 → 场景维度暂渲染两级（§7 #31） |
| `GET /api/playlists` / `:id` | 官方歌单；详情缺 `isSaved/writable/saveAction` 用户态（§7 #9） |
| `GET/POST/DELETE /api/saved-playlists` | 歌单收藏 |
| `GET/POST/DELETE /api/favorites` + `POST/DELETE /api/notes/:id/favorite` | 双账：库曲走 favorites，生成 note 走 notes 端点；GET favorites 混排 `source:"note"`/`noteId` 条目须分型解码 |
| 未接 | `user-playlists`、`shared-playlists`、`playlists/daily|public`、`favorites?trackIds` 批量（§7 #21） |

### 4.3 播放上报与最近播放 —— 本阶段重点

**`POST /api/tracks/play`**（iOS 现行通道；web 走同函数的 `/api/play-history` POST）

- body：`{trackId, source, idempotencyKey}`；游客可报（计入总播放量，不入个人历史）。
- **source 是服务端闭合枚举**（`src/lib/play-history.ts:8`）：
  `discover / playlist / project / track_detail / player`，越界 400 `PLAY_SOURCE_INVALID`。
  **不得自造值**（`app-ios`/`miniprogram` 均被拒）。iOS `PlayReportSource` enum 已钉死；
  语境口径：曲库/推荐位 `discover`、歌单与收藏 `playlist`、曲目详情/相似 `track_detail`、
  生成结果/作品内试听 `project`、未指明一律 `player`（当前唯一生产调用点落 `.player`）。
- 幂等：digest = `sha256(actorKey|key)`；**同键下 `(trackId,source)` 任一不同 → 409
  `IDEMPOTENCY_CONFLICT`** ⇒ 重试必须连 source 一起复用（集次账记来源，不重新取默认）。
- 限流：120 次/分/actor（user 或 IP），429 + `Retry-After`。
- 响应：`{message:"ok", recorded, idempotentReplay, authenticated, play:{trackId,source,playedAt}}`。

**`work_listens` 作品播放（v2.39.09 新增，iOS 未接）**

- **伪 trackId 契约**：`trackId = "{jobId}:{candidateId}"`（无候选后缀时可为裸 jobId）。
  服务端：非库曲且命中 generation_jobs → INSERT 进 `work_listens`；幂等语义同上。
- **只要接作品试听，必须同车**：① 上报带伪 trackId；② GET play-history 的 items
  能解码 work 形态（`trackId` 含 `:`、track 字段为 work 投影）——库曲 DTO 直接解码会丢行。

**`GET /api/play-history`**（iOS 未接，P0 第一项）

- 登录态：`{items[]}`（track_listens 与 work_listens 合并按时间序，`limit` 默认 50）；
  未登录 401 `{error:"请先登录", code:"AUTH_REQUIRED", authenticated:false, items:[]}`。
- item：`{id, trackId, playedAt, source, track}`；work 行 trackId 形如 `jobId:candidateId`。

### 4.4 studio/create 高级创作台（iOS 整组未接，P0–P1 主战场）

**`POST /api/studio/create/generate`** → `{ok:true, jobId, charge}`

- mode：`simple`（prompt 必填≤2000，歌词服务端 `lyricsMode:auto` 代写）｜
  `advanced`（lyrics≤5000 + stylePrompt≤1000，二者至少其一或勾纯音乐）｜
  `melody`（语义=哼唱 cover，必须 `sourceClipId` 或 `uploadAudioId`，**operation 强制
  cover，显式传其他值 400**）。
- operation（默认 create）：`create / cover / extend / remaster`；非 create 必须带
  `sourceClipId` 或 `uploadAudioId`；`extend` 的 `continueAt`（0–3600s，缺省=源曲末尾，
  越界钳到结尾，读不到源长则扣费前 400 fail-fast）。
- `idempotencyKey` **必填**；**服务端双层幂等**：① 同键重放直接返回已有 jobId
  （不重复扣费）；② 同指纹（规范化请求体 SHA-256，键除外）**10 分钟窗口**
  （`COVA_CREATE_DEDUP_WINDOW_MS`，默认 600_000，v2.40.1 由 60s 放宽）内活动任务
  复用 jobId——**客户端每点一次生成可换新键，服务端指纹兜底**，但同一次提交的重试
  必须复用同键。
- 计费：reason = `studio_create_generation`；**先落 job 后扣费**（ledger metadata
  携 `jobId/idempotencyKey/operation/mode`）；余额不足 402
  `{error:"credits_insufficient", balance, required}`；提交失败自动退款（refund reason
  `generation_refund`）。`COVA_SUNO_AGENT_ENABLED` 关时 charged:false（开发环境）。
- modelVersion：`chirp-hawk`（V6 默认）/ `chirp-goose`（V6-mini）/ `chirp-hawk-wild`；
  旧值（v5.5/v5/v4.5plus…）服务端归一为默认 V6；Lyria（`'Lyria 3.5'`/`'Lyria 3 Pro'`）
  仅支持 `operation=create`、无 sourceClip、无音色。
- 其他字段：`title≤200`、`negativeTags≤500`、`voiceProfileId`（+Voice 音色，
  非 create 互斥除 cover+clip）、`controls{vocalGender m|f, styleWeight/weirdnessConstraint/
  audioWeight 0–1, durationSec 10–360}`、`inspirationSource{type:'shop',…}`。
- 错误码：`invalid_request 400` / `credits_insufficient 402` / `voice_not_found 404` /
  `voice_not_ready 409` / `submit_failed 502|503`；统一信封 `{error, code?, ...details}`。

**作品列表与详情：`GET /api/studio/create/works`**

- query：`id`（含 `:` 为 clip 行详情轮询；纯 jobId 返回该 job 全部行）｜
  `filter∈{all,generating,vocal,instrumental,liked,disliked,cover,extend,remaster}`｜
  `sort∈{newest,oldest}`｜`q`｜`cursor`｜`limit`。
- 响应 `{works:CreateWorkItem[], nextCursor, total}`；`Cache-Control: no-store`。
- **CreateWorkItem 字段**（`app/studio/components/create/types.ts`，clip 打平一行=一首）：
  `id`（`jobId:candidateId` 或裸 jobId）、`jobId`、`title`、`coverUrl?`、
  `audioUrl?`（可播放签名代理 URL，生成中/失败 null）、`playbackUrl?`（**免 Authorization
  预签名直链 TTL 900s，App 后台播控必须用它**）、`duration?`、`status∈{queued,submitted,
  processing,succeeded,failed,cancelled}`、`tags`、`lyrics`、`modelVersion`、`instrumental`、
  `voiceName?`、`errorMessage?`、`createdAt`、`source`（studio-create/one-step/song-match）、
  `melody?`、`operation?`、`providerClipId?`、`favorited?`、`disliked?`。
- `PATCH /api/studio/create/works/:id` `{title 1-200}` → `{ok,work}`；
  `DELETE` 软删（metadata.deletedAt）→ `{ok:true}`。

**作品行内动作**

| 端点 | 语义 |
|---|---|
| `POST works/:id/favorite` `{favorite?}` | 物化 note 并进「我喜欢的音乐」feed；与 dislike 互斥；限流 120/分 |
| `POST works/:id/dislike` `{dislike?}` | 个人信号 user_work_dislikes；点踩撤收藏；120/分 |
| `POST works/:id/note` | work→music_note 幂等物化 → `{ok,noteId}`（进歌单用）；60/分 |
| `GET works/:id/timing` | 对齐歌词 LRC：作品→providerClipId→上游 get_aligned_lyrics；**任何失败/纯音乐/无 clip 回 `{ok:true,lrc:null}`**，客户端回退纯文本；60/分 |
| `POST/GET/DELETE works/:id/share` | 公开分享 `/share/work/<token>`（免登录可听）；POST 开/复用（未生成完 409）、GET 查态、DELETE 关（token 保留可重开） |
| `POST/GET works/:id/extras` | 作品级补充制作（同会话 extras 管线，幂等复用）→ `{ok,files}` |

**辅助端点**：`POST /api/studio/create/lyrics`（`{prompt≤1000}` → `{ok,title,lyrics}`，
上游约 90s+排队，路由 maxDuration 150s、限流 20/时）；`POST …/style-suggest`
（→ `{ok,styles[],optimizedStyle,optimizedSource}`）；`POST …/upload`（multipart
`audio`/`file` ≤50MB → `{ok,audioId}`，作 cover/extend 素材；30/时）；
`POST …/upload-from-work`（把作品音频回灌成 audioId）。

**上游排队语义**：cova api provider lane 被占回 `423 provider_lease_busy /
confirmed_not_submitted`——可安全重试的排队信号，web 侧就地等待重试；iOS 收到 423
按「排队中」展示并重试，不当作失败。

### 4.5 一步创作（已接，新线补齐项）

已接：sessions CRUD、`POST /api/studio/agent`（SSE）、`one-step/plans[/:id]`
GET/PATCH/`start`、`lyrics/regenerate`、`versions`、`media/references/:id/retention`。
待补（P1–P2）：`GET /api/find-my-song/generation-jobs?id=`（轮询：前 6 次 5s、
之后 10s、上限约 30min；响应 `{job}`，列表 `{jobs}`，`?health=1` 探活）、
`GET /api/studio/agent-runs/:id`（SSE 断流恢复）、`GET/POST /api/studio/extras`
（会话级交付快照 `{ok,files,deliveryRevision}`）、
`GET /api/studio/extras/artifacts/:jobId/:artifactId`（产物下载）、
`POST /api/studio/publish-demo`、候选级 retry（见 §7 #30）。

### 4.6 下载与计费

- `GET/POST /api/downloads/checkout`（DTO 与 `downloadCheckout` 幂等键型已备好，
  **全仓无调用点**——D12 合规门禁未放行，P1 只接 BUG-15 作品直存）。
- **BUG-15 作品直存**：作品行下载走 `CreateWorkItem.audioUrl`（或 `playbackUrl`）
  **直接保存**，不走 downloads/checkout、不扣费；这是作品与库曲下载的双路径分野。
- `GET /api/me/credits/ledger?limit≤100`（P2 流水页）：`{entries[]}`，
  每条 `{id, type, amount, balanceAfter, reason, reasonLabel, jobId, createdAt}`。
  **`jobId` 由服务端从 `metadata.jobId` 解出**，明细页用它渲染「任务」关联
  （点击可跳任务/作品）。reasonLabel 映射已含 `studio_create_generation=AI 音乐生成`、
  `generation_refund=生成失败退款`、`daily_checkin=每日签到`、灵感商店一族等；
  未识别 reason 回落「其他变动」，客户端容忍新值。
- `GET /api/studio/producers`（P2 制作人入口）：`{producers[]}`，每 producer
  `{id,displayName,fictional,tagline,audience,greeting,stages[{id,label,summary}],
  deliverables,extensions,demoCount,cardCount}`；**灰度关闭时返回空列表 ⇒ 按空态隐藏
  入口**；限流 120/时。`producers/projects` 及 `:id/actions|surveys` 属 P3。

---

## 5. 开发阶段（每阶段可独立验收）

> 阶段间允许并行编码，验收按序。每阶段完成判据见 §6。

### P0 止血（同步度 5.5→7）

1. **`GET /api/play-history` 读接入**：「继续聆听/最近播放」数据源切到服务端历史；
   items 分型解码（库曲 track 形态 + `jobId:candidateId` work 形态容错）。
2. **studio/create generate 最小闭环**：仅 `mode:'simple'` + `operation:'create'`：
   表单（prompt）→ POST generate（带幂等键）→ 任务轮询
   （`GET …/create/works?id=<jobId>` 或 `generation-jobs?id=`，前 6×5s 后 10s）
   → 双曲落列表；402/400/503 错误如实展示，**不静默吞 `idempotentReplay`**。
3. 工件：CreateWork DTO 全套 + 幂等键型 `studioCreateGenerate` + works 轮询器。

### P1 创作台（7→10）

1. **works 列表**：筛选/搜索/游标分页/状态徽标；行内 favorite·dislike·note·timing·share·
   rename·delete；`playbackUrl` 优先播放（免 Bearer）。
2. **cover/extend/remaster**：作品详情提供「翻唱/续写/重制」入口，sourceClipId=
   `providerClipId`；extend 给 continueAt 选择（缺省=结尾）；melody 模式可后置。
3. **作品播放上报（work_listens）**：播放作品时按 `{jobId}:{candidateId}` 报
   `tracks/play`（source=`project` 或 `player`），同车验证 GET play-history 混排不丢行。
4. **BUG-15 作品直存下载**：`audioUrl` 直接存文件（不 checkout、不扣费），进
   「已下载」本地清单；库曲 checkout 路径仍受 D12 门禁不接 UI。
5. **轮询断链补腿**：`GET …/generation-jobs?id=` 接进会话详情
   （`AISessionDetailView.swift:514` 自认未接）+ `agent-runs/:id` SSE 恢复。

### P2 交付链（10→12）

1. **extras 快照**：`GET/POST /api/studio/extras`（会话）+ `works/:id/extras`（作品）；
   keys：`wav`母带/`stems`分轨/`vocal_stems`人声/`accompaniment`伴奏/`lyrics_video`/
   `lyrics_timing`；`deliveryRevision` 驱动 UI 版本；artifacts 端点下载。
2. **制作人模式入口**：`GET /api/studio/producers` 空列表=隐藏；非空在创作输入「+」
   面板渲染制作人卡（displayName/tagline/stages/deliverables）。
3. **ledger 明细页**：`GET /api/me/credits/ledger` 分页；行 =
   `±amount reasonLabel 余额 balanceAfter 时间`，`jobId` 非空渲染「任务」关联链接；
   未识别 reason 显示原文+「其他变动」兜底。

### P3 新线（按产品排期）

- 灵感商店 `/api/inspiration-shop/*`（11 条）、`me/checkin` 签到、
  `user-playlists` 自建歌单、`shared-playlists` 分享歌单、`playlists/daily|public`
  每日/广场、`agent-v2/*`、`cover/jobs`、`home/materials`、`voice-profiles` 展示、
  `producers/projects|deliveries|surveys` 全流程、`auth/login/apple|sms`（上架口径见 §7）。

---

## 6. 验收标准（每项可机械判定）

| # | 项 | 判定方式 |
|---|---|---|
| A1 | play-history 读 | 模拟器登录 → 「最近播放」列表出现真条目；`sqlite`/`curl -H "Authorization: Bearer $T" 'https://covalink.cn/api/play-history?limit=5'` 返回 items 非空且 iOS 渲染行数一致；work 行（trackId 含 `:`）不丢、不崩 |
| A2 | source 闭合枚举 | 断点/`os_signpost` 抓取实际上报 body，`source ∈ {discover,playlist,project,track_detail,player}`；代码面 `grep -rn '"app-ios"\|"miniprogram"' Packages/` = 0 命中 |
| A3 | generate simple 闭环 | 真机：填 prompt → 生成 → ≤30min 内列表出现 2 首 `succeeded` 行；期间 Console 无红错；`curl` 复用同 idempotencyKey 重放 → 同 jobId 且余额不二次扣 |
| A4 | 402/400 错误展示 | 构造余额不足/缺 prompt → UI 分别显示「余额不足，本次需要 N」「请填写音乐描述」（透传服务端文案）；无「未知错误」糊词 |
| A5 | work_listens 上报 | 播放一首作品 → `POST /api/tracks/play` body trackId=`{jobId}:{candidateId}` → 响应 `recorded:true`；随后 `GET /api/play-history` items 含该 work 行 |
| A6 | 作品直存 | 作品行 ↓ → 沙盒出现完整音频文件（非 0 字节、时长与 duration 一致）；`creditLedger` 无新增扣费行（ledger 页核对） |
| A7 | works 行内动作 | favorite → `GET /api/favorites` 出现 note 条目；dislike → 收藏被撤；share → POST 返回 `sharePath` 且 `https://covalink.cn/share/work/<token>` 免登录可听；timing → 有词作品返回 `lrc` 非 null |
| A8 | extras | POST `works/:id/extras {keys:["wav","stems"]}` → files 含母带 wav 与分轨 zip；GET 复列幂等不重复制作 |
| A9 | ledger 页 | `curl …/me/credits/ledger?limit=10` → entries 每项含 `reasonLabel`；`studio_create_generation` 行 `jobId` 非空；UI 点击「任务」跳转到对应作品 |
| A10 | producers 入口 | 灰度账号 GET producers 返回非空 →「+」面板出现制作人卡；普通账号 `{producers:[]}` → 入口不可见（不是置灰） |
| A11 | 幂等不变式 | 双击生成钮（两键不同）：10min 内同指纹 → 服务端复用 jobId（A3 的 curl 变体）；同键重试 → `idempotentReplay` 语义不重复扣费 |
| A12 | 门禁 | `Scripts/check.sh` EXIT=0：三测试 target 全过、覆盖率 ≥94%、D12 禁词 0 命中 |
| A13 | 私有音频 | 候选/作品音频仍走「Bearer 下载→校验非空→file://」；`grep -rn "audioUrl" Packages/CovaPlayer` 无直链 https 播放私有候选的路径（`playbackUrl` 作品除外，它本就是免凭证直链） |
| A14 | 截图证据 | 每屏深/浅双主题各一图存 `docs/acceptance/<date>/`，命名 `NN-屏-主题.png`；截图批次必须同 commit 字节（构建退出码 0 + 产物含当批符号，TD-50 教训） |
| A15 | 术语口径 | UI 文案只用「co / 作品 / 任务」词表（对齐 `GenerationJobStatusCopy`）；不得出现「积分/歌曲任务」等漂移词 |

---

## 7. 已知历史问题（旧 NEEDS 仍未解决项；已修复/已否证的不录）

> 口径：以下为**后端侧仍欠**或**前端侧待办**，按编号保留。标注「待答」=需后端明确；
> 「待办」=客户端自己欠的。

| # | 主题 | 现状 | 阻塞 |
|---|---|---|---|
| 4 | ACCOUNT-DELETE 账号删除端点 | 待答：端点不存在 | **上架 P0**（App Store 强制） |
| 5 | APPLE-SIGNIN / sms 登录 | 待答：无 `login/apple|sms` | P2（若提供第三方登录则 Apple 强制） |
| 6 | `downloads/:id/file` Range | 待答：不支持 206 | M3 断点续传 |
| 8 | `tracks/:id` 详情缺 variant 字段族 | 待答：列表有详情无；客户端按可选容忍 | 非阻塞 |
| 9 | `playlists/:id` 详情缺 isSaved/writable/saveAction | 待答 | 非阻塞 |
| 10/12 | similar 投影与列表投影双形态 | 待答：建议统一或版本化；客户端已分 `SimilarTrackDto` | 非阻塞 |
| 11 | favorites 条目稳定 id 语义 + note 项缺 `favoriteCount/energy/tags` 是否有意 | 待答两项 | 非阻塞 |
| 13 | agent 请求体与 SSE 事件载荷 schema 未文档化；「选中候选」无机器可读载体（现走自然语言 message） | 待答 + 契约待写 | 非阻塞 |
| 14 | `tracks/play` 响应 schema 未文档化（`idempotentReplay` 被当事实用） | 待答 | 非阻塞 |
| 15 | 私有音频签名 host 形状未文档化（子域会被出口守卫拒） | 待答 | 私有试听潜在堵点 |
| 16 | 私有音频无 Content-Length 时无法判早断 | 待答 | 非阻塞 |
| 17/23/28 | sessions 消息字段/schema/稳定消息 id 未文档化（客户端合成 view: 键） | 待答 | 非阻塞 |
| 18 | 无 `DELETE sessions/:id` | 待答 | 会话删除无处调 |
| 19 | 会话列表无聚合摘要字段 | 待答（本地聚合降级） | 非阻塞 |
| 20 | 无「已下载」列表端点 | 待答（本地缓存口径？） | P1 直存清单需对齐 |
| 21 | 无 favorites 批量查询 | 待答（整表拉取降级） | 非阻塞 |
| 22 | 无 AI 音乐人档案端点 | 待答 | 艺人页缺数据 |
| 24 | 生成候选无公开分享目标 | 待答（现状：不渲染分享钮；works/:id/share 只解 create 作品） | 一步候选分享禁用 |
| 25/33 | 计划卡 `revision/snapshotHash`、workflowState 键集、`fullMediaReady` 完成布尔 | 待答（缺值就地拒发；百分比挂计划卡状态） | 非阻塞 |
| 26 | SSE 事件字典超契约（reasoning_summary/credits/skill_* 等） | 待答（未知事件显式忽略） | 非阻塞 |
| 27 | `plans/start` 响应实际 `{result:{jobId},summary}` 非契约 `{job}` | 待答（客户端容忍双形态） | **扣费写路径** |
| 29 | 有权益整曲 302→COS 桶：客户端已通（剥凭证匿名重放），仍请后端改同源代理 + `audioUrl` 相对路径写进契约 + DTO 给 `previewOnly` | 待答 3 件 | 非阻塞（播放已通） |
| 30 | 无候选级 retry 端点（重试只能权威回读，不能重跑失败候选） | 待答 | spec「重试」语义未交付 |
| 31 | `subscene` 打标计划未明 → 场景维度暂两级 | 待答一句口径 | 非阻塞 |
| 32 | `sort=relevance` 无 search 时 500；未知 sort 静默回落 | 待答（非法值应 400） | 非阻塞 |
| 34 | `GET /api/find-my-song/generation-jobs?id=` 与 `agent-runs/:id` 未接 | **待办（iOS 侧）** | P1 轮询断链 |
| 35 | studio/create 全组、play-history GET、ledger、producers、extras、user-playlists/shared/daily/public、inspiration-shop、checkin、device/apple/sms auth | **待办（iOS 侧）** | 即本手册 §5 全部阶段 |

> 共 **23 条后端待答/待端点**（#4,5,6,8,9,10/12,11,13,14,15,16,17/23/28,18,19,20,21,22,24,25/33,26,27,29,30,31,32）
> + **2 条端侧待办**（#34,#35）。已关闭不录：NEEDS-1（登录契约误判）、2（source 用错值已改）、
> 3（/me 三键已核）、7（推送 token，本地通知兜底）。

**iOS 侧技术债（接手必知）**：TD-41 禁 UI 白名单不拦反射/`dlopen`；
TD-42 锁屏命令「已受理未完成」需真机冒烟；TD-43 MPRemoteCommandCenter 共享面无可隔离
（只做可观测票据）；TD-44 残余=纵深防御项（跨 host GET 未核准，凭证已被系统剥）；
TD-45 门面层缺「取消→⏭」复现腿；TD-46 导航矩阵成本须拆用例；TD-47 `@unchecked Sendable`
9 处已核真锁但缺 `// SAFETY:` 标记机制化；TD-48 **CovaUI/CovaFeature 无测试 target**
（UI 层只有构建+截图自证）；TD-49 骨架屏未按五族分屏型；TD-50 证据纪律（截图必须钉
构建退出码 0 + 产物符号）；版本号口径=「影响产物的 commit 才递增」待用户拍板。

---

## 附：变更纪律速查

- 新增端点 → 先在 CovaCore 建 DTO（字段缺失即不建模，不填默认值）→ 服务层 → UI。
- 新增写操作 → `Idempotency.swift` 登记新 operation 键型；同 (scope) 重试复用同键。
- 契约不符 → 登记 §7 表 + 不猜字段名（宁可后端Gap错显式报出）。
- 设计值 → 只引 `design/tokens.json`（发现与 §3 漂移时先修 tokens.json 再用）。
