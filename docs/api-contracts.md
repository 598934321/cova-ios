# api-contracts.md — 后端 API 契约参考

> 整理自 `多端/mobile`（RN 版）已验证的调用面与类型定义，供 iOS 原生实现对齐。
> 基址：`https://covalink.cn`。除公开浏览接口外均需 `Authorization: Bearer <access>`。
> 超时 15s；401 → single-flight refresh 后重放一次；写操作带幂等键。

## 1. 认证

| 端点 | 说明 |
|---|---|
| `POST /api/auth/login` | `{email, password}` → `{user, token, refreshToken, expiresIn}`。**入口是两步，不是一步**（2026-09-24 对照 web 客户端源码，见 D21）：登录响应里的 `user` 只有 `{id, email, name, role}`，**这是设计如此、不是后端缺口**（NEEDS-1 已撤销）；web 侧登录成功后不使用这份 `user`，立刻 `GET /api/auth/me` 取权威身份。iOS 的 `principal` 取 `login.user.id`，会话身份与权益取 `/me`，两者 `id` 不一致即 fail-closed 收回凭证 |
| `POST /api/auth/refresh` | refresh token 旋转（single-flight） |
| `POST /api/auth/logout` | 登出 |
| `GET /api/auth/me` | → `{user, entitlements, nameChange}`（**三键**，2026-09-24 对照 web 补齐：`nameChange` iOS 忽略即可）。`user` 在此才含 `covaId / phone / avatar / isArtist`，`/me` 另加 `isPartner / partnerType`。**未登录返回 401 + `{user: null}`** ⇒ 客户端必须按"未认证"处理，不得当成"空用户" |

**AuthUser**：`id / email / name / role / covaId / phone / isArtist / isPartner`
**Entitlements**：`plan('free'|'creator'|'pro'|'enterprise') / creditsBalance / monthlyCredits / canDownload / canUseCovaAI / canRequestProjects`

客户端状态机：`signed-out` / `guest`（可浏览公开内容，AI 与收藏需登录）/ `authenticated`。

## 2. 曲库

| 端点 | 说明 |
|---|---|
| `GET /api/tracks` | 多维筛选：`scene / mood / style / artistId / instrument / attribute / energy / vocalType / bpm / duration / search / sort / page / similarTo`。⚠️ **`similarTo` 是唯一的例外**：它返回 **similar 投影**（见下方警告），响应须用 `SimilarTrackPageDto` 解码；其余筛选（`search / sort / energy / vocalType / scene / key / createdAfter / preciseTag / category / durationMin` …）返回普通列表投影 → `TrackPageDto` |
| `GET /api/tracks/:id` | 详情 + 相似曲目（`{track, similar[]}`） |
| `GET /api/tracks/:id/preview-url` | 试听 URL + preview 区间（匿名可访问，2026-09-17 实测：`{url, previewStart, previewEnd, duration}`） |
| `GET /api/library/taxonomy` | 词表（genre→subgenre→三级延伸；scene/mood/instrument/type/energy 维度） |
| `GET /api/playlists` / `GET /api/playlists/:id` | 官方歌单 |
| `GET/POST/DELETE /api/saved-playlists` | 歌单收藏（需登录） |
| `GET/POST/DELETE /api/favorites` | 曲目收藏（需登录）。`GET → {tracks[]}`；`POST/DELETE` body `{trackId}` → `{message, favoriteCount}`。⚠️ `GET` 会混入「生成音乐收藏」条目（`source:"note"`/`noteId`，字段集不同，NEEDS #11） |
| `POST /api/tracks/play` | 播放上报，`source: "app-ios"`（NEEDS-2），幂等键 |

**TrackDto 关键字段（普通列表投影）**：`id / title / titleCn / artist{…} / cover / duration / bpm /
audioUrl / scenes[] / moods[] / tags[] / displayLabels[] / highlightStart-End / waveformPeaks[] /
lyrics / vocalType / energy / variants[]（A/B 变体）/ favoriteCount / previewStart-End`

> ⚠️ **投影不一致（2026-09-17 实测，NEEDS #10 / #12）**：同一「曲目」资源存在**两套序列化**：
> - **普通列表投影**（`GET /api/tracks` 的其余筛选、`GET /api/playlists/:id` 的 `tracks[]`）：
>   camelCase `previewStart/End`，`featured` 为 **Bool** → `TrackDto` / `TrackPageDto`。
> - **similar 投影**（`GET /api/tracks/:id` 的 `similar[]` **以及 `GET /api/tracks?similarTo=` 的 `tracks[]`**）：
>   只有 snake_case `preview_start/end / play_count / created_at / audio_duration`，
>   `featured` 为**数字 0/1**，`artist`/`tags` 为裁剪结构，另有 `similarityScore`（int 或 float）；
>   `similarTo` 响应的封套还会**回显 `similarTo` 参数** → `SimilarTrackDto` / `SimilarTrackPageDto`。
>
> **客户端不得把 similar 投影当作 `TrackDto`**（会 `typeMismatch: featured` / `keyNotFound: previewStart`）。
> 另：`GET /api/tracks/:id` 的 `track` 无 variant 字段族（NEEDS #8）。

**PlaylistDto 关键字段**：`id / title / titleCn / cover + coverMedia（fit/focal 焦点）/
trackCount / totalDuration / scene / curator / isSaved / saveAction`

## 3. 下载 / co 币

| 端点 | 说明 |
|---|---|
| `GET /api/downloads/checkout` | → `{downloadCredits, balance, enabled, format:'mp3'}` |
| `POST /api/downloads/checkout` | `{trackIds[], format:'mp3', idempotencyKey}` → `downloads[]/items[]`（签名 URL；owned 跳过重复扣费） |
| `GET /api/downloads/:downloadId/file` | 授权文件下载（暂不支持 Range，NEEDS-6） |

**DownloadItemDto**：`trackId / downloadId / url / filename / owned`
**v1.0 UI 不开放购买入口（D12）**；以上能力按合规放行后接入。

## 4. Cova AI（一步模式）

| 端点 | 说明 |
|---|---|
| `POST /api/find-my-song/sessions` | 建会话 `{workflowMode:'one-step', skipWelcome:true}` |
| `GET /api/find-my-song/sessions` / `:id` | 会话列表 / 详情（含 messages / generationJobs） |
| `POST /api/studio/agent` | **SSE 流**（`Accept: text/event-stream`），事件：`thinking / text / plan_card / error / done / run_*` |
| `GET /api/studio/one-step/plans?sessionId=` | 计划卡片（轮询降级用，5s 间隔） |
| `POST /api/studio/one-step/plans/start` | 启动制作 `{sessionId, planCardId, revision, snapshotHash, idempotencyKey}` |
| `GET /api/find-my-song/generation-jobs?id=` | 生成任务轮询（前 6 次 5s，之后 10s，上限约 30 分钟） |
| `PATCH /api/media/references/:id/retention` | 生成候选收藏 `{favorite}` |

**OneStepPlanCard**：`planCardId / sessionId / revision / status（12 态）/ type('vocal'|'instrumental') /
title{selected, candidates} / style{analysisZh, promptEn} / lyrics（LyricsDocument 分 section）/
parameters{operation, vocalGender, weirdness, styleWeight, targetDurationSec} / credits`
计划卡 12 态的中文文案映射以 web `src/lib/one-step/` 为准实现。

**GenerationJob**：`id / sessionId / status（6 态）/ costCredits / metadata（含 candidates JSON）/ idempotencyKey`
**GenerationCandidate**：`id / title / audioUrl / audioDownloadUrl / audioDownloadStatus / mediaReferenceId / favorite`

**SSE 降级规则**：10s 无首事件 / 30s 静默 / 3 个坏事件 / done 前 EOF → 转 5s 轮询，不与 SSE 并发。
**双 Demo 硬规则**：只取前两候选，两个都 settled（`audioDownloadStatus` ready+URL 或 failed）才算终态。
**归属校验**：计划卡 `sourceMessage.messageId === clientMessageId` 才解锁「开始制作」。

## 5. 安全规格（必须实现）

- token 对存 Keychain `ThisDeviceOnly`，带 principalId 绑定；禁写日志
- 私有音频：先 Bearer 完整下载到 app cache 校验非空，再 `file://` 播放；Bearer URL 不进
  MediaItem/日志/持久化索引
- 登出/换号：推进 session generation、清播放队列、销毁播放器、清私有音频/封面缓存
- 播放上报：一次实际播放一个幂等键，前台与后台转场共用去重
