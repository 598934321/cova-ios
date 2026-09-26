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
- ⚠️ **「trackId 含 `:`」不是 work 行的权威判别**（2026-09-26 逐行核对
  `web/src/lib/play-history.ts`）：服务端 POST 侧的判据是
  `!track && (trackId.includes(':') || jobExists(trackId))`（`:50`）⇒ **裸 jobId 也会记进
  `work_listens`**，而它在 GET 里的 `track` 投影**同样带 `workId`**（`:157-182`，
  注释明写「标位供前端区分」）—— 那种行不含冒号，只按冒号判就会认成库曲。
  ⇒ iOS 的判别顺序（`PlayHistoryItemDto.rowKind`）：① `track.workId` 非空 = work；
  ② 否则 `trackId` 含 `:` = work（track 投影缺失时的兜底）；③ 其余 = 库曲。
  另：裸 jobId 行在 GET 侧若 `result_audio_url` 为空会被**整行丢弃**（`:149-153`）
  ⇒ iOS 上报一律带候选后缀，且把"没有 candidateId 的 work 行"渲染但**标为不可播**。
- ⚠️ **`workId` 这个键在库曲行上也存在，只是值为 `null`**（2026-09-26 生产实测
  `GET /api/play-history?limit=5`：该账号 4/4 条库曲行的 `track` 都是 58 键、含 `workId: null`）
  ⇒ 判别必须写成「非空字符串」，**不能**写成「这个键在不在」。按存在性判会把
  每一条库曲行都认成作品行（`PlayHistoryDTOTests` 里那条断言钉的就是这个）。

**`GET /api/play-history`**（iOS 未接，P0 第一项）

- 登录态：`{items[]}`（track_listens 与 work_listens 合并按时间序，`limit` 默认 50）；
  未登录 401 `{error:"请先登录", code:"AUTH_REQUIRED", authenticated:false, items:[]}`。
- item：`{id, trackId, playedAt, source, track}`；work 行 trackId 形如 `jobId:candidateId`。

### 4.4 studio/create 高级创作台（iOS 整组未接，P0–P1 主战场）

**`POST /api/studio/create/generate`** → `{ok:true, jobId, charge}`
（⚠️ **`charge` 是数字，不是对象**，实测 `web/src/lib/studio/create/generate.ts:526-530`；
本节下面写的 `charged:false` 是同一个字段的旧措辞，读作「`charge` 为 0」。）

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
  `{error:"credits_insufficient", balance, required}`
  ⚠️ **402 这一档的 `error` 值就是英文码、且不带 `code` 键**（实测
  `api/studio/create/generate/route.ts:24-30`）—— 其余档（400/502）的 `error` 是中文人话。
  所以「余额不足」那句只能由客户端按 `required` 组装，而 400 才能透传服务端原文；
  本仓的裁决面是 `StudioCreateRejection.userMessage`（并把"裸码形状"的 `error` 挡在上屏之外，A15）。
  提交失败自动退款（refund reason `generation_refund`）。`COVA_SUNO_AGENT_ENABLED` 关时 `charge` 恒 0
  （开发环境）⇒ **0 不等于免费**，客户端无从判别 ⇒ UI 只在 `charge > 0` 时渲染扣费那一行。
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
- ⚠️ **`playbackUrl` 这一腿在 iOS 上今天走不通**（上面那句「App 后台播控必须用它」不成立）：
  2026-09-26 生产实测 `GET /api/studio/create/works?limit=6` **6/6 行同形** ——
  `audioUrl` 是站内相对 `/api/media?…`（同源，走 D7 的 Bearer 下载→校验→`file://`），
  而 `playbackUrl` 落在 **`covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com`**，
  该桶**不在** §3/D23 的存储名单内（名单只有 covers 与 audio，刻意不含 uploads 这个用户私产桶）
  ⇒ 直链会被出口守卫点名主机拒掉（`WorkDownloadStoreTests` 钉的就是这一条）。
  所以本端**播放只吃 `audioUrl`**，`playbackUrl` 仅作直存兜底；
  P1 若要真按「playbackUrl 优先播放」，须后端改签名单内的桶（登记 §7 #37），
  **客户端不许自己放宽名单**（D23②）。
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
⚠️ **但这条不适用于 `studio/create/generate`**（2026-09-26 逐行核对）：generate 的提交异常
被 catch-all 统一吞成 `submit_failed`（`lib/studio/create/generate.ts:531-536`），
**永不返回 423**；`423→503` 的映射只存在于 `lib/studio/create/cova-upstream.ts:205`，
服务的是 lyrics 代写 / style-suggest 两条通道（响应体 `{ok:false, error:"…通道正忙…"}`）。
⇒ P0/P1 的 generate 客户端**不实现 423 分支**；接 lyrics 那一屏时再按本句处理。

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
  ⚠️ 硬边界 9（D12）**仍然管着库曲那条腿**：作品的免费直存不等于「下载入口已放行」，
  加库曲 checkout 的 UI 之前必须先有合规结论。
- **BUG-15 作品直存**：作品行下载走 `CreateWorkItem.audioUrl`（或 `playbackUrl`）
  **直接保存**，不走 downloads/checkout、不扣费；这是作品与库曲下载的双路径分野。
  ⚠️ 落点是 `Documents/Cova/cova-work-downloads/<owner hex>/{jobId}-{candidateId}.mp3` +
  同目录 `manifest.json`（**与播放器的 `Caches` 试听缓存分家**，两条生命周期不同：
  缓存文件名带 `#形态@g代次`、重新登录就换名，用它承载「已在本机」会让用户亲手按出来的
  标记凭空消失）。清单只落本地文件名与展示字段，**不落任何 URL**（硬边界 3）。
  12d §7 那句「本机沙盒存在且校验通过的文件 + 本地元数据 = 列表事实源」在方法上成立、
  落点不是本屏（作品直存不是付费下载，12d 的门 1 不适用），登记在 §7 末尾。
- `GET /api/me/credits/ledger?limit≤100`（P2 流水页）：`{entries[]}`，
  每条 `{id, type, amount, balanceAfter, reason, reasonLabel, jobId, createdAt}`。
  **`jobId` 由服务端从 `metadata.jobId` 解出**，明细页用它渲染「任务」关联
  （点击可跳任务/作品）。⚠️ **2026-09-26 生产实测该字段全为 `null`**
  （`GET /api/me/credits/ledger?limit=100` ⇒ 本账号 6 条，含 1 条 `studio_create_generation`，
  `jobId` 6/6 null）⇒ A9「`studio_create_generation` 行 `jobId` 非空」今天已成立（17:19 那条新行带 jobId；更早的行仍是 null，见 §7 #38 的工期更正），
  已登记 §7 #38（也可能是这批账目早于该字段上线，故按"待答"记而不判后端缺陷）；
  客户端按可选建模、null 时**不渲染**「任务」链接，不猜一个号。reasonLabel 映射已含 `studio_create_generation=AI 音乐生成`、
  `generation_refund=生成失败退款`、`daily_checkin=每日签到`、灵感商店一族等；
  未识别 reason 回落「其他变动」，客户端容忍新值。
- `GET /api/studio/producers`（P2 制作人入口）：`{producers[]}`，每 producer
  `{id,displayName,fictional,tagline,audience,greeting,stages[{id,label,summary}],
  deliverables,extensions,demoCount,cardCount}`；**灰度关闭时返回空列表 ⇒ 按空态隐藏
  入口**；限流 120/时。`producers/projects` 及 `:id/actions|surveys` 属 P3。

---

### 4.7 P1/P2 契约实测卡（2026-09-26 逐条打生产 + 逐行读 `../web` 得到）

> 这一节是 P1/P2 那五件的**唯一落点口径**。上面 §4.4–§4.6 里与它冲突的写法以本节为准，
> 冲突处已就地标注（不再留两份事实源）。

**works 列表**：`GET /api/studio/create/works`（不带 `id`）⇒ `{works, nextCursor, total}`，
实测 `limit=6` 回 `nextCursor="6" total=8`。参数只有 `q` / `filter` / `sort` / `cursor` / `limit`：
`filter` ∈ `all|generating|vocal|instrumental|liked|disliked|cover|extend|remaster`（未知值服务端当 `all`）、
`sort` ∈ `newest|oldest`、`cursor` 是**字符串化的行偏移**（服务端 v1 简化，不是不透明游标）、
`limit` 夹在 1..100 默认 30。**没有** `status`/`offset`/`page`/`source` 参数 ⇒ 不许建模。
行 `id` 有**四种形状**且必须原样保留：`{jobId}:{candidateId}`、`{jobId}:pending-N`、裸 `{jobId}`、
以及同一 job 两行共用 id 前缀。`favorited`/`disliked` **为 false 时服务端整个键都不发**
⇒ 缺键即 false 是服务端行为，不是客户端填默认值。

**行内动作**：七个端点**都接受伪 id**（`favorite`/`dislike`/`note`/`timing`/`share`/`PATCH`/`DELETE`），
三个坑必须写进 UI：① `favorite`/`dislike` 的 body 里 **缺键 ≠ false**（服务端缺省为 `true`）
⇒ 取消收藏必须显式发 `false`；② **`rename`/`delete`/`share` 是 job 级不是行级**
（一次生成两行 ⇒ 改一行等于改两行），屏上怎么交代归规格；③ `note` 是**物化成笔记**（返回 `noteId`），
备注文本要走 `PATCH /api/notes/{id}`，而 `storyText` 同时是物化关联键 ⇒ 改它会断开收藏回读。
`favorite` 与 `dislike` 服务端互斥（点踩会撤收藏）。错误形如 `{error:字符串}`，409 = 作品尚未生成完成。

**extras 产物的 `type` 是哪来的（2026-09-26 逐行读 `web/src/lib/studio/extras-service.ts:313-322`）**
—— 这一格必须写死在这里，因为**它不是一对一**，按"类型名像什么"去反推 key 会画出真 bug：

| 服务端 kind | 线上 `type` |
| --- | --- |
| `master_wav` | `audio-wav` |
| `accompaniment` | `instrumental-wav`（mime 含 wav）／`instrumental-mp3` |
| `stems`、`vocals` | **都是 `stems`** |
| `video`（或 mime 是视频） | `video` |
| `timing`、`lyrics`、`metadata` | **都是 `doc`** |
| `cover` / image | `cover` |

⇒ 只有 `audio-wav⇒wav`、`instrumental-*⇒accompaniment`、`video⇒lyrics_video` 三对是**一对一**，
可以用来把"已经做好的那个 key"从可选组里收掉；`stems`（分轨 + 人声分轨两枚）与 `doc`
（时间轴 + 歌词 + 元数据三枚）**多义，不许拿它隐藏任何 key** —— 按 `type` 猜就会把
"做过伴奏的作品"上的「母带 WAV」整行抹掉。认不出身份的产物行**不渲染**（画不出标签就不画），
可认但多义的行标签用 §8 两枚标签的连接形态「分轨 / 人声分轨」，说"两者之一"而不替服务端指认。
> 本段是**对协调者任务书的一次纠正**：任务书里写的是「`instrumental-wav` ⇒ wav」，
> 照抄就会出上述那个 bug。实测在此，谁的旧说法与这段冲突以这段为准。

**extras 的 ledger 与幂等**：reason 是 `media_extra`（扣费，**不在**服务端 `reasonLabel` 映射里
⇒ 流水页显示「其他变动」）与 `media_extra_refund`（退款，有标签「素材加工退款」）；
两条 POST 的体里**没有**幂等键字段（§7 #45），且作品级那一条**不按键集去重**（§7 #47）
⇒ 客户端只落"一次点击 = 一次在途、在途不可再点、失败不自动重发"这一条纪律，
屏上也不许出现"服务端说这是复用"那类断言。

**extras 的 key 闭集是 6 个**，`instrumental == true` 时服务端**滤掉**
`lyrics_video/vocal_stems/accompaniment/lyrics_timing` ⇒ 客户端选项集必须跟着滤。
`works/{id}/extras` **只认伪 id**（裸 jobId 404）且**不回 `deliveryRevision`**；
`/api/studio/extras?sessionId=` 才回（它是工作流计数器）。`files[].url` 里的 jobId 是
**worker job 不是生成 job** ⇒ 只许原样消费、不许自己拼。待做时 `url` 缺键、状态文本塞在 `version` 里
⇒ 建模成枚举不是字符串。**作品级这一支服务端不扣费**，会话级按 `MEDIA_EXTRA_PRICES` 扣
（wav 20 / accompaniment 30 / stems 50 / vocal_stems 50 / lyrics_timing 10 / lyrics_video 100）
⇒ 文案不许在免费的那条腿上暗示价格。产物下载是**同源 200 流**（`Content-Disposition: attachment`），
`accompaniment` 是**同源 302 到 `intent=download`** —— 与 §7 #39 同一条腿，名单外桶不出现在下载路径上。

**ledger**：`GET /api/me/credits/ledger` **只有 `limit`**（1..100 默认 50），
**没有 offset/cursor**、响应里**没有 total/balance/nextCursor**，排序固定 `createdAt DESC, id DESC`
⇒ 「只能看最近 100 条」要如实呈现，不许假装能翻页。
`reasonLabel` 由服务端映射且**映射表与真实 reason 不同步**：24 个在写的 reason 里 13 个落到「其他变动」
（含 `media_extra`、`cova_ai_agent_generation`、灵感商店购买/收益、`iap_credits_purchase`、admin 三件）
⇒ 客户端**原样显示服务端字符串**，绝不自己再映射一遍。
⚠️ 顺带更正 §4.6 的一处措辞：不存在 `generation_refund` 这个 reason，真实值是
`cova_one_step_generation_refund` / `cova_ai_agent_generation_refund`（退款标签映射在它们身上）。

**会话详情的"轮询断链补腿"（§5 P1-5）——原写法要改口径**：`GET /api/studio/agent-runs/{id}`
**是普通 JSON 不是 SSE**（`{run}`，`run` 带 `status/currentStep/timeline[]/retryCount/stopReason`），
而 `/api/studio/agent` 那条 SSE **每帧只有 `event:`/`data:`、没有 `id:` 行**，服务端
**没有 `Last-Event-ID` 处理、没有环形缓冲**（客户端断开后事件被静默丢弃）
⇒ "SSE 恢复"在这台服务端上**不存在**，能做的只有按 `run.status` / `currentStep` /
`timeline[].sequence` **轮询对账**。§5 那句「+ `agent-runs/:id` SSE 恢复」按此更正。

**generate 的完整入参**（§4.4 只写了 simple 那一格）：`mode` ∈ `simple|advanced|melody`
（`melody` 强制 cover，配其他 operation 直接 400）、`operation` ∈ `create|cover|extend|remaster`
（`replace_section` 被这个端点拒）、`prompt≤2000`（simple 必填）/`lyrics≤5000`/`stylePrompt≤1000`/
`negativeTags≤500`/`title≤200`/`makeInstrumental`/`modelVersion`/`voiceProfileId`/
`controls{vocalGender,styleWeight,weirdnessConstraint,durationSec 10-360,audioWeight}`/
`sourceClipId≤200`/`uploadAudioId`（别名进 `sourceClipId`）/`continueAt 0-3600`（只有
`extend`+`sourceClipId` 才消费）/`inspirationSource{type:'shop',inspirationId,transactionId}`。
`melody` **不是入参**（服务端按 `mode` 写 metadata）。
⚠️ **`sourceClipId` 服务端完全不校验**（无存在性/归属/格式检查）⇒ 一个错的 clip id 会
**照常 200 + 新 jobId + 真扣费**，然后异步失败只在行的 `status=failed`+`errorMessage` 上显形。
⇒ 客户端只能自己保证只送**本机已知属于本账号**的 `providerClipId`，并把"提交成功"和"做出来了"
在 UI 上分成两件事（19 屏已经是这个形状）。

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
   rename·delete。（2026-09-26 部分交付：伪 trackId 的**读**已通 —— 01「继续聆听」与
   19 结果区都能按 `{jobId}:{candidateId}` 回读单行；筛选/分页/行内动作仍未接。）
2. **cover/extend/remaster**：作品详情提供「翻唱/续写/重制」入口，sourceClipId=
   `providerClipId`；extend 给 continueAt 选择（缺省=结尾）；melody 模式可后置。
   （2026-09-26 交付：契约半条 `sourceClipId`/`continueAt` 与服务端同精度取整 + 本地拦"没选源"；
   UI 半条落在 **19 的 B 区**（19 待裁决 1 本来就把那一格预留给 `continueAt` 选择器），
   四档操作 chip + 源选择 sheet + 起点滑杆。
   ⚠️ **这是对 19 §1「非 P0 控件一律不渲染」的一次有记录的范围变更**（不是遗漏后的补漏：
   那条写的是 P0 期间的口径）。源那一格**只接受本机刚从 `GET works` 读回的那一行**，
   因为服务端对 `sourceClipId` 完全不校验（§4.7）——拼一个/留一个过期值出去，
   换来的是 200 + 真扣费 + 异步 failed。`advanced`（歌词/风格分栏）与 `melody` 仍不渲染。）
3. **作品播放上报（work_listens）**：✅ **代码与单测已交付（2026-09-26）**；
   ⚠️ **设备侧待验收** —— 原先记的"被 302 卡死"是错的（§7 #39 同日推翻）：客户端把同源
   媒体 URL 的 `intent=play` 换成 `intent=download` 即可 200 取字节，D23 名单未放宽。
   验收改骑 works 列表屏（对已存在的作品点播 ⇒ 零扣费）。
   两处与上面写法的偏差，按实测事实保留：`source` 用 `player`（不是 `project`——全 App 只有一个播放面，
   语境没有从视图层传到播放层，见 §4.3 的语境口径）、播放地址用 `audioUrl`
   （不是 `playbackUrl`——后者是名单桶直链，D23 之后不许直接交给播放器）。
4. **BUG-15 作品直存下载**：✅ 代码与单测已交付（Documents + 本机清单，不 checkout、不扣费）；
   ⚠️ **设备侧待验收**：与上一条同一次解阻（同源 `intent=download`），沙盒落文件已无阻塞。
   但**没有**进 12d 那套「已下载」屏（那是付费下载清单，门 1 未放行且本屏不可达）：
   作品直存的入口在作品行内（↓ / 「已在本机」/ 删除）。要给它一个独立清单页需先出规格。
   库曲 checkout 路径仍受 D12 门禁不接 UI。
5. **轮询断链补腿**：`GET …/generation-jobs?id=` 接进会话详情
   （`AISessionDetailView.swift:514` 自认未接）+ `agent-runs/:id` 恢复。
   （2026-09-26：该端点已在 19 屏的任务轮询里接通；**会话详情那一处仍未接**。
   ⚠️ 原写法里的「SSE 恢复」按 §4.7 更正：`agent-runs/:id` 是**纯 JSON**，而 agent 那条 SSE
   既不发 `id:` 也无 `Last-Event-ID`/缓冲 ⇒ 断流后**无法续播**，能做的只有按
   `run.status/currentStep/timeline[].sequence` 轮询对账。）

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
| A1 | play-history 读 | 模拟器登录 → 「最近播放」列表出现真条目；`sqlite`/`curl -H "Authorization: Bearer $T" 'https://covalink.cn/api/play-history?limit=5'` 返回 items 非空且 iOS 渲染行数一致；work 行（**`track.workId` 非空**，或 trackId 含 `:`）不丢、不崩 |
| A2 | source 闭合枚举 | 三条机械判据，缺一不可：① **类型面**——上报体的 `source` 只能由 `PlayReportSource` 表达（闭集枚举，越界值在编译期写不出来），且 `PlayReportRequestDto` 的 init 只收 `IdempotentRequestToken`；② **生产码面**——`grep -rn '"app-ios"\|"miniprogram"' Packages/*/Sources --include="*.swift \| grep -vE ':[0-9]+: *(///\|//\|\*)'` **0 命中**（生产码非注释行里不许出现自造值）；③ **反向断言必须在**——`PlayReportDTOTests.swift:74`、`PlayReportCoordinatorTests.swift:384,543` 那三条"这个值再回来就红"的断言不许删。⒊ 抓取实际上报 body 的 `source ∈ {discover,playlist,project,track_detail,player}`。<br>⚠️ **判定式于 2026-09-26 改写**：原式写作 `grep … Packages/ = 0 命中`，实测有 8 处命中，其中 5 处是"该值曾被服务端 400 拒"的注释、3 处在测试面（含那三条反向断言）。原式**分不开"代码在发这个值"与"代码在防这个值回来"** ⇒ 想让它归零只能删掉防回归证据，那是把判据做窄。改后既保住断言，又多了一条原式没有的类型面判据（扫描域从"全 Packages"收窄到"生产码"，作为交换补上 ① 与 ③）。 |
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

### 6.1 设备侧判据怎么执行（A1/A3/A5/A6/A14）

这些判据要**点击与滚动**，而驱动本机会话的进程没有 macOS「辅助访问」权限
（`cliclick` 报 `Accessibility privileges not enabled`、AppleScript 报 `-25211/1002`），
`simctl` 本身不提供点击，装 idb/appium 会破零第三方依赖（硬边界 4）。
⇒ 落点是 **XCUITest**：事件注入发生在模拟器内、由 Xcode 测试基础设施驱动，不需要宿主权限，
且可复现。载体是独立 target `CovaAcceptanceTests` + 独立 scheme `CovaAcceptance`
（`CovaAcceptanceTests/P0AcceptanceTests.swift`，一条链跑完 A3→A6→A5→A1）。

```
TEST_RUNNER_COVA_ACCEPT_EMAIL=… TEST_RUNNER_COVA_ACCEPT_PASSWORD=… \
xcodebuild test -project Cova.xcodeproj -scheme CovaAcceptance \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /tmp/acc.xcresult
```

三条不可省：
- **`TEST_RUNNER_` 前缀是必须的**：`xcodebuild` 不会把普通环境变量转给测试运行器；
  少了前缀 ⇒ 用例走 `XCTSkip`，而 `xcodebuild` 仍报 `** TEST SUCCEEDED **`
  （2026-09-26 实付：第一次跑"绿"了，`xcresulttool` 的 `skippedTests=1` 才揭穿）。
  ⇒ 这条链的验收必须读 `xcresulttool get test-results summary`，不许读 xcodebuild 的最后一行。
- **口令不进仓库也不进日志**：只从运行器环境读，缺失即 skip（不是失败，也不是通过）。
- **它不是门禁的一部分**：这条链要真等一个生成任务（分钟级）并真扣一次 co，
  塞进 `check.sh` 等于把门禁做成不可靠判据；`check.sh` 的 `Cova` scheme 不引用它。
  代价说清楚：**这条链红了没人拦**（无基线、无 CI 挂钩），所以每次动了 19/01/播放/直存腿
  都要手动跑一次并把截图落 `docs/acceptance/`。
- 截图落在运行器容器的 tmp，同时挂成 xcresult 附件。取回时的 bundle id **要带 `.xctrunner`
  后缀**（`xcrun simctl get_app_container <udid> cn.covalink.ios.acceptance-tests.xctrunner data`）；
  少了后缀 2026-09-26 实测报 `No such file or directory`，会让人误判"截图没落盘"。
- **不需要点击的屏不必动用 XCUITest**：`SIMCTL_CHILD_COVA_PREVIEW_ROUTE=…`（同族
  `_LOGIN_EMAIL/_LOGIN_PASSWORD/_TAB/_SHEET/_DRAWER`）配 `xcrun simctl launch` +
  `simctl io screenshot` 就够，且**零扣费**；深浅档用 `simctl ui <udid> appearance dark|light`
  翻，app 侧不留残留（主题档位是「跟随系统」时）。两个坑：① 路由是 `bootstrap → 真登录 →`
  才 push，`sleep 9` 拍到的还是首页 ⇒ 每拍一张都要读图；② `previewRoute()` 会回读
  `UserDefaults`，别把 `COVA_PREVIEW_*` 留在沙盒里污染下一次启动。

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
| 36 | 作品直存的**清单落点**与 12d 不同屏：本仓落 `Documents/Cova/cova-work-downloads/`（owner 分桶 + `manifest.json`，只存本地文件名与展示字段），入口在 19 作品行内（↓ /「已在本机」/ 删除），**没有**「已下载」整屏 | 已按此交付（2026-09-26）；12d §7 的「本机沙盒 + 本地元数据」方法成立、屏不通用 | 要独立清单页须先出规格（设计闸门硬边界 8）|
| 37 | 作品 `playbackUrl` 实测签在 **`covalink-uploads-…`** 桶（2026-09-26 生产只读探针，`GET /api/studio/create/works?limit=6` ⇒ 6/6 行同形），不在 D23 存储名单（只有 covers/audio）内 ⇒ iOS 出口守卫按主机名拒掉，**§4.4 那句「App 后台播控必须用它」在本端今天不可用** | 待答：能否改签名单内的桶（或论证把 uploads 桶纳入名单——它是用户私产桶，web 侧正因为这点被否过一次） | 非阻塞（播放走 `audioUrl` + D7 本地化已通） |
| 38 | `GET /api/me/credits/ledger` 的 `jobId`：2026-09-26 **按新账复测过了，结论是后端缺陷而非"早于字段上线"**。同一份响应 7 条里——**今天 16:10 那次 `studio_create_generation`（-100，bal 19415）`jobId=null` / `unlinked=true`**，而**更早**的 09-24 `cova_one_step_generation` 与 09-16 `library_download_checkout` 都带 jobId。⇒ "旧行没这字段"的解释被这条新行否证：写路径确实存在（`web/src/lib/studio/create/generate.ts:206-211` 明写把 `{jobId,…}` 传给 `consumeCredits`，且 BUG-18 那条"先落 job 后扣费"的顺序注释就在旁边），但 **`studio_create_generation` 这一支在生产上没落进 metadata**（要么部署落后于 `cd5fc48c`，要么这一支的 metadata 没接上） | 待修（不再是待答）：请按 `studio_create_generation` 这一支查 metadata 写入；`cova_one_step_generation` 那支是好的，可作对照 | **A9 的「`studio_create_generation` 行 jobId 非空」今天不可能达**。客户端按 §4.6 既定口径：null ⇒ **不渲染**「任务」链接，不猜号 |<br>⚠️ **同日 20:16 本条被服务端修好，就地更正**：17:19 那次提交产生的账行现在回 `jobId=3b4f59bc-74c7-4718-b5e4-a30edd6b1747` / `unlinked=false`，而更早的 08:10 那行仍是 null ⇒ 修复发生在两次提交之间（「新行有、旧行没有」正是部署刚推上去的样子）。**A9 的后半条因此今天可达并已证**：22 屏同一份清单里同时看得见「有链接」（17:19 / 09-24 / 曲目下载 / 09-17 四行）与「没链接」（08:10、09-17 的 -315、两行其他变动），点「任务」跳到 20 的 job 锚定态（设备腿 `testCreditsLedgerRendersRowsAndLinksAJob` passed 19.5s）。教训：这条结论从测出到失效不到两小时 —— 依赖外部系统的判据每次交付前都要重测，不要引用旧档案。
| 39 | ~~作品的音频既播不出也存不下~~ —— **本条结论已于同日推翻，是我取证取窄了**。当时只试了服务端签发的那一条 `intent=play`：它确实 **302 → `covalink-uploads-…`**（名单外）⇒ 出口守卫拒。但**同一个 `ref`、同一台 host** 换 `intent=download` 是 **200 `audio/mpeg`、`Accept-Ranges: bytes`、零跳转**（实测 5,315,422 B、ID3 头），即 `web/src/app/api/media/objects/[id]/route.ts:127` 那个 `intent !== 'download'` 的分支判断——服务端**本来就有一条同源直出字节的腿**，而且它正是 web 侧自己的下载链路（`extra-artifact-cos.ts:17`）。⇒ 根因不在后端，在**客户端挑了错的 intent** | 客户端已修：`CovaEnvironment.workAudioDirectFetchURL`（播放与直存两条腿共用，只改「生产同源 + `/api/media/objects/` + 独立成项且全文唯一的 `intent=play`」这一种形状，其余原样交回；不走 `queryItems` 往返，R17-6）。**D23 名单一个字都没放宽**，且这条比"追一跳再剥凭证"更保守（凭证一步都不出源）。仍请后端（并入 #29 那一族）：给 App 的作品音频**直接签发可用 intent**，别让客户端靠字符串改写猜语义 | A5/A6 **解阻**，设备侧验收改骑 works 列表屏（对**已存在**的 8 行点播/直存 ⇒ 零扣费），见 §5 P1-1 |
| 40 | **`POST /api/studio/create/generate` 的重放响应没有机器可读的重放标记**。2026-09-26 生产实测三连（同一 prompt）：① key=K1 首次 ⇒ `{ok:true,jobId:3b4f59bc…,charge:100}`；② **key=K2（不同键、同指纹、10min 内）** ⇒ **同一个 jobId**、`charge:100`；③ **key=K1 重放** ⇒ **同一个 jobId**、`charge:100`。ledger 只多**一条** -100（19415 → 19315）⇒ 两层去重都成立、确实没有二次扣费（**A11 因此达**）。但响应体里**没有 `idempotentReplay` 这个键**，而 `charge` 三条都是 100 —— 它回的是「这一单的价格」，不是「本次新扣了多少」 | 待答：给重放一个机器可读标记（或让 `charge` 在重放时为 0）。§5 P0-2 那句「不静默吞 `idempotentReplay`」在**这个端点上没有可读取的载体** | 19 屏的「本次消耗 N co」在**同指纹换键重放**这条路径上会把"没扣"说成"扣了"。现状如实：客户端只做到了「同一次提交的重试复用同一把键」（`StudioCreateFlow.swift:25`），**没有**"回到的 jobId 与已知同一 ⇒ 改口成未重复扣费"这一格 ⇒ 待办（记在 §5 P1 的 19 屏改造里）|

| 41 | **works 列表屏（`design/screens/20-works-list.md`）开出 12 条待答**，逐条列在该规格末尾「待答」节，此处按指针登记。最需要先答的四条：① `total` 是筛选后还是全量、含不含 `failed/cancelled`；② `cursor` 是**字符串化的行偏移** ⇒ 中途增删行会让翻页漂移或重复，服务端能否给 job 边界对齐（客户端现按 `id` 去重 + 断处重复组头承接）；③ `works/:id/share` 对 `source ∈ {one-step, song-match}` 的行是否可用（现按 `source == "studio-create"` 判可见）；④ `favorite` 与 `PATCH /api/media/references/:id/retention` 是不是同一个布尔、谁是事实源 | 待答（指针：20 §待答 1-12）| 非阻塞（屏按"取不到态就保持已知态"设计）；但 ⑤「rename/delete/share 是 job 级、一次生成产 2 行」这条**必须**进 §4.4 正文，客户端已按端侧核对写死 |
| 42 | **extras 屏（`design/screens/21-work-extras.md`）开出 8 条待答**（同指针格式）。其中两条**本轮已由 `../web` 逐行答掉**，就地更正以免再问：① 纯音乐被滤掉的确实是 `lyrics_video / vocal_stems / accompaniment / lyrics_timing` 四个 key，且这是**服务端**在 `extras.ts:127-133` 滤的（不是客户端推测）；② extras 的 ledger reason 是 `media_extra`（扣费）与 `media_extra_refund`（退款，标签「素材加工退款」在册），而 `media_extra` **不在**服务端 `reasonLabel` 映射里 ⇒ 流水页会显示「其他变动」（§4.7 已记 13/24 落到兜底这一族就是其一）。仍待答：`artifactId` 取自哪个字段、6 个价目要不要进 §4.6、作品路径是否永远不计费、extras POST 的幂等键字段名 | 部分待答 | 非阻塞；价目硬编码的漂移风险按"只回显服务端字符串、不自算"承接 |

| 43 | **A4 的 402 那一档拿不到设备侧证据，且不是"再试一次"能解决的**：要屏上出现「余额不足，本次需要 N co」必须让服务端真的回 402，而测试账号余额 19,315 co、单次生成 100 co ⇒ 要花光它得提交 ~190 次（且会造出 ~380 个作品行）。另一条路是造一个零余额账号——生产**没有注册端点**（#5 同族），也不该由客户端去开号。400 那一档同样不可达：空 prompt 在本地就被拦（19 §4 明令不花一次往返去换同一句话），CTA 在空输入时是 disabled ⇒ 屏上没有任何路径能发出一个"缺 prompt"的请求 | 待答：给一个**长期零余额的验收账号**（或允许本仓在验收窗口把测试号余额临时清零），否则 A4 的设备半条永远欠着 | **A4 判据降级**：`charge`/400/402 三条信封与两句文案的对应关系由 `StudioCreateDTOTests`（402 信封、`error` 就是英文码且无 `code` 键、裸码不许透传）+ 代码路径证；屏上证据只有 400 的**本地拦**那一格（CTA disabled）看得见 |
| 44 | **A10 的"非空"分支同样拿不到设备证据**：`GET /api/studio/producers` 的灰度是 `PRODUCER_MODE=on\|off\|allowlist`，而**未设 + `NODE_ENV=production` ⇒ off**（`web/src/lib/producer/flags.ts:10-14`）⇒ 生产上恒回 200 `{producers:[]}`。注册表里其实有一个启用的制作人（`lin-zhixia`），但要它出现需要服务端把开关打到 `on` 或把本账号写进 `PRODUCER_MODE_ALLOWLIST` | 待答：把验收账号加进 `PRODUCER_MODE_ALLOWLIST`（或给一个灰度环境）。这是**服务端一行配置**，不是契约缺口 | 非阻塞。**空列表那一半（入口不可见、不是置灰）今天就能设备验收**；非空那一半由 `ProducersDTOTests` 的真实形状夹具 + 视图代码路径证，并在屏上如实区分"灰度没开"与"没读到"（`producersReadFailed` 与空数组不是一回事）|

| 45 | **会话级补充制作是扣费写操作，但契约里没有任何幂等键的位置**：`POST /api/studio/extras` 的体只有 `{sessionId, keys}`（`web/src/app/api/studio/extras/route.ts:30-39`、`extras-service.ts:465-487` 在事务内按 `MEDIA_EXTRA_PRICES` 扣费），而硬边界 5 要求"扣费写操作必带幂等键"。作品级那一条腿不扣费所以无所谓，会话级这一条**连击两次就是两次扣费**（同键重放/同指纹去重在服务端这一支都没有实现痕迹） | 待答：给 `POST /api/studio/extras` 加 `idempotencyKey`（或复用 `Idempotency-Key` 请求头并在契约里写明），并说明是否有同指纹窗口。客户端**不自己发明字段**（硬边界 7）⇒ 现在能做的只有 UI 侧的"一次点击 = 一次在途、在途不可再点" | 21 屏的会话路径：主钮在途禁用是**唯一**的重复扣费防线，那是交互约束不是协议保证。已同步记在 `design/screens/21-work-extras.md` 待答（8） |

| 46 | **作品级补充制作在生产上恒被取消，A8 的产物字节今天拿不到**。2026-09-26 实测（同一行 `e091da30…:054e7f3d…`，两次独立提交、间隔约 8 分钟）：`POST works/{id}/extras {keys:["wav","stems"]}` ⇒ **200** + `{ok,files}` 两行 `version=补充制作准备中`、**无 `url`**；此后每 20s 复列一次，**约 6 分钟后两行都翻成 `version=已取消`**，两批都是这个结局（换第三行只提交 `wav` 也一样）。全程 **ledger 无新增行**（19315 不变）⇒ 与 §4.7 一致：作品级这一支不扣费。所以不是"我没等到"，是**接单之后被取消**：`wav→get_wav`、`stems→create_stems` 这些 worker 任务在这套部署上没有跑起来（与 #29 记的"rehydrate worker 自 2026-08 起离线"同族的症状，但这是另一条 worker 路径） | 待修/待答：这一支 worker 是否需要某个开关（如 `COVA_SUNO_AGENT_ENABLED` 那类）才启用？作品级不扣费却又派工，是否本来就被设计成"只登记不执行"？请给一句结论。**客户端不猜**：`已取消` 就画 `已取消`，不重试成"多试几次总会好" | **A8 判据降级**：已达的一半 = 请求形状 / 200 信封 / 两条腿的字段差（作品级无 `deliveryRevision`、会话级有）/ 不扣费 / pending 无 url 不渲染保存钮 / `已取消` 状态如实上屏；**未达的一半 = 「files 含母带 wav 与分轨 zip」与产物同源 200 流的下载腿**（没有 url 就没有下载腿可验）。21 屏的下载那一格因此只能停在"契约与实现备好、服务端不产出" |
| 47 | **作品级 extras 的 POST 不按键集去重**：同一行、同一 `{keys:["wav","stems"]}` 第二次 POST ⇒ **返回两个全新的 artifact id**（`extra-c933eb1e…`/`extra-27ff57a0…` 之后又出现 `extra-f096fcd1…`/`extra-e6e5df81…`），而不是复用已有那两条。⇒ §6 A8 那句「GET 复列幂等不重复制作」只在**读**这一侧成立（GET 是纯读，复列恒等）；**写这一侧没有去重**。作品级不扣费所以后果只是多派几份被取消的工，但**会话级那一条腿是扣费的**（wav 20 / stems 50 …）且 #45 已记它没有幂等键 ⇒ 两条合起来 = 用户连点两次「开始补充制作」就是两次扣费，服务端不会替我们兜 | 待答：extras 的 POST 请给同指纹/同键集去重窗口，或按 #45 收 `idempotencyKey`。客户端侧已做的只有"一次点击 = 一次在途、在途不可再点"（`ExtrasService` 的 busy 门 + 21 屏主钮在途换菊花且不可点），**那是交互约束不是协议保证** | 加重 #45；A8 的"幂等"那一半按上面降级口径写，不许写成已达 |

| 48 | **产物落沙盒后文件名的扩展名恒为 `.mp3`，与真实容器不符**：21 的「保存到本机」复用了 `WorkDownloadStore`（作品直存那套 Documents + `manifest.json`），而 `WorkDownloadPath.fileName(forWorkId:)` 写死 `.mp3` 后缀。母带是 wav、分轨是 zip ⇒ **字节是对的、文件名是错的**：`afinfo`/Quick Look 仍按内容识别，但用户拖到"文件"里或第三方 app 按后缀猜容器时会拿到一个假的 `.mp3` | 待办（端侧，不阻塞 A8）：给 store 一个"内容类型 → 后缀"的一格（wav/zip/mp3），或由服务端在 `files[].name` 里给权威文件名（21 待答 1 的一部分）。**不改 store 的命名面属于本屏可改范围之外**，所以先如实记下 | 非阻塞：A8 的产物字节今天本来就取不到（#46），这一格要在服务端修好之后、真正做设备验收之前补 |

| 49 | **作品行的封面是第三方直链，且拒绝原因漏进了整行的 VoiceOver 标签**。2026-09-26 设备侧按钮清单实测：每一行的标签都是「`Harbour at Dawn：美术地址不可出站：cdn2.suno.ai 不是生产出口也不在许可名单的存储主机内（该次请求未发出）`、Harbour at Dawn、04:03」这样。两件事：① 作品的 `coverUrl` 是 **Suno 的 CDN 原链**（不像 `audioUrl` 那样被签成同源代理路径），D23 拒得对 ⇒ **作品封面在这一端一张都不出**；② 出口守卫那句**诊断文本被当成美术的替代文本拼进了行标签** ⇒ 读屏用户每听一行都要先听一遍 40 字的内部原因，这是把工程诊断当无障碍文案用 | 待答（后端）：作品的封面请一并走同源代理（与 `audioUrl` 同一做法，`playbackUrl` 那条另记在 #37）。待办（端侧）：拒绝原因只该出现在调试面，美术的替代文本最多是一句「封面不可用」——**这条改动会碰到 `ArtworkResolutionContractTests` 钉住的那条 message 串**，改的是"用在哪"而不是"这句话本身"，动它要连用例一起过一遍 | 非阻塞：封面不出不影响播放/直存/上报（那三条腿走的是 `audioUrl`）；但 20/19 的截图里作品行一律是占位图，读屏序列里每一行都带一句诊断 |

> 共 **23 条后端待答/待端点**（#4,5,6,8,9,10/12,11,13,14,15,16,17/23/28,18,19,20,21,22,24,25/33,26,27,29,30,31,32）
> + **2 条端侧待办**（#34,#35）**+ 1 条端侧落点登记**（#36：作品直存清单落点与 12d 不同屏）
> + **4 条本轮生产实测新增**（#37 `playbackUrl` 落在名单外的桶、#38 `ledger.jobId` 按新账复测仍 null ⇒ 转后端待修、**#39 已推翻：同源 `intent=download` 直出字节，A5/A6 不是被阻塞而是客户端挑错了 intent**、#40 重放响应无机器可读标记）。
>   四条都是 2026-09-26 用生产实测得到的（只读 GET + 一次已授权的 A11 提交），不是从代码推的。
> + **2 条规格开出的待答指针**（#41 works 列表 12 条、#42 extras 8 条，逐条在
>   `design/screens/20-works-list.md` / `21-work-extras.md` 末尾；#42 里两条本轮已答）
>   **+ 2 条"设备证据今天结构性拿不到"的降级登记**（#43 A4 的 402 档要零余额账号、
>   #44 A10 的非空档要服务端灰度）——这两条不是"还没做"，是**做了也拿不到证人**，
>   所以按判据降级 + 替代证据登记，不写成已验收。
>   **+ 1 条协议缺口**（#45：会话级补充制作是扣费写操作，但契约里没有幂等键的位置
>   ⇒ 硬边界 5 在这一支落不了地，现在唯一的防线是 UI 的在途禁用——那是交互约束不是协议保证）
>   **+ 2 条 extras 的生产实测缺陷**（#46 作品级补充制作**恒被取消**：200 接单、不扣费、
>   约 6 分钟后翻 `已取消`，两批独立提交同结局 ⇒ A8 的产物字节今天拿不到，判据降级；
>   #47 POST 不按键集去重（第二次提交换全新 artifact id）⇒ 与会话级扣费叠加就是连点两次
>   扣两次，A8 那句"幂等"只在读这一侧成立）。
> 已关闭不录：NEEDS-1（登录契约误判）、2（source 用错值已改）、
> 3（/me 三键已核）、7（推送 token，本地通知兜底）。

**iOS 侧技术债（接手必知）**：TD-41 禁 UI 白名单不拦反射/`dlopen`；
TD-42 锁屏命令「已受理未完成」需真机冒烟；TD-43 MPRemoteCommandCenter 共享面无可隔离
（只做可观测票据）；TD-44 残余=纵深防御项（跨 host GET 未核准，凭证已被系统剥）；
TD-45 门面层缺「取消→⏭」复现腿；TD-46 导航矩阵成本须拆用例；TD-47 `@unchecked Sendable`
9 处已核真锁但缺 `// SAFETY:` 标记机制化；TD-48 **CovaUI/CovaFeature 无测试 target**
（UI 层只有构建+截图自证）；TD-49 骨架屏未按五族分屏型；TD-50 证据纪律（截图必须钉
构建退出码 0 + 产物符号）；版本号口径**已消解**：以 §2「纯文档不递增 / 影响产物才递增」为准
（原记「待用户拍板」，2026-09-26 按 §2 收敛，两处表述不再打架）。

---

## 附：变更纪律速查

- 新增端点 → 先在 CovaCore 建 DTO（字段缺失即不建模，不填默认值）→ 服务层 → UI。
- 新增写操作 → `Idempotency.swift` 登记新 operation 键型；同 (scope) 重试复用同键。
- 契约不符 → 登记 §7 表 + 不猜字段名（宁可后端Gap错显式报出）。
- 设计值 → 只引 `design/tokens.json`（发现与 §3 漂移时先修 tokens.json 再用）。
