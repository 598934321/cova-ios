# Tests/CovaCoreTests/Fixtures — 来源与标注

> 规则：fixture 是**观测记录的脱敏副本**，不是模型的示例。键名与值类型**不得人工改写**
> （只允许：替换 URL 主机为 `cdn.invalid`、脱敏签名类 query 值、截断超长数值数组）。
> fixture 仅用于单测，**不得作为验收证据**；不得包含任何真实凭证 / token / 签名 URL。

## 一、真实回灌（可无凭证只读 GET 观测，2026-09-17）

| fixture | 来源 | 说明 |
|---|---|---|
| `track-page.json` | `GET /api/tracks?page=1` | 取前 3 条；`featured` 为 Bool、`previewStart/End` 为 camelCase（列表投影） |
| `tracks-similar-to.json` | `GET /api/tracks?similarTo=<id>&pageSize=5` | **真实 similarTo 响应**：`tracks[]` 走 similar 投影（`featured` 数字、仅 snake_case `preview_start/end/play_count/created_at/audio_duration`、`similarityScore` int/float、封套回显 `similarTo`）；配 `SimilarTrackPageDto` |
| `track-detail-real-1.json` / `track-detail-real-2.json` | `GET /api/tracks/:id` | **真实详情**：`track` 无 variant 字段族；`similar[]` 为 snake_case 专属 + `featured` 数字 + 裁剪 `artist`/`tags` |
| `track-preview-url.json` | `GET /api/tracks/:id/preview-url` | 匿名 200，camelCase `previewStart/End` |
| `playlists.json` | `GET /api/playlists` | 取前 2 条；含真实长句 `disabledReason`、`coverMedia.alt` |
| `playlist-detail.json` | `GET /api/playlists/:id` | 详情 `playlist` **无** `isSaved/writable/disabledReason/saveAction`（见 NEEDS #9） |
| `taxonomy.json` | `GET /api/library/taxonomy` | 全 12 维度，每维取前 2 项 |
| `checkout-info.json` | `GET /api/downloads/checkout`（匿名） | 真实 `balance: null` |
| `error-envelope.json` | `GET /api/tracks/<不存在>` | 真实公共 404：`{error}`（无 `code`） |

## 二、契约目标形态（无法只读验证：需登录 / 写操作 / NEEDS 未对齐）

| fixture | 依据 | 待对齐 |
|---|---|---|
| `auth-me.json` | `docs/api-contracts.md` §1 + `GET /api/auth/me` | — |
| `auth-login.json` | 契约 §1 `{user, token, refreshToken, expiresIn}`（token 为占位符） | **NEEDS-1**：真实 login 的 `user` 仅 `{id,email,name,role}`，缺 `covaId/phone/isArtist/isPartner` |
| `auth-refresh.json` | `POST /api/auth/refresh` 响应 | NEEDS-1 |
| `auth-logout.json` | `POST /api/auth/logout` 响应 | — |
| `favorites-list.json` | 契约 §2 `{tracks}`（元素为真实 `TrackDto` 载荷） | **NEEDS `FAVORITES-NOTE-ITEMS`**：真实响应对「生成音乐收藏」条目用不同字段集 |
| `favorite-mutation-response.json` | 契约 §2 写操作响应 | — |
| `saved-playlists.json` | 契约 §2 `{playlists}`（真实歌单载荷 + `savedAt`） | — |
| `saved-playlist-mutation-response.json` | 契约 §2 写操作响应 | — |
| `play-report-response.json` | 契约 §2 `POST /api/tracks/play` 的 200 形态 | 2026-09-24 线上实测键名 `{authenticated, idempotentReplay, message, play, recorded}`；`play` 内为 `{trackId, source, playedAt}`，`source` 是**服务端回显的请求值**，此处取本客户端默认 `.player`（写端点不可只读回灌） |
| `one-step-plan-cards.json` | 契约 §4 计划卡投影（12 态） | — |
| `generation-job.json` / `generation-jobs.json` | 契约 §4 生成任务（6 态、`metadata` 为 JSON 字符串） | — |
| `checkout-response.json` | 契约 §3 `POST /api/downloads/checkout` | — |
| `error-envelope-code.json` | 契约 §5 业务码形态（`INSUFFICIENT_CREDITS`） | — |

## 三、合成边界样例（**非真实响应**）

| fixture | 用途 |
|---|---|
| `synthetic/track-with-variants.json` | 真实 page-1 数据里 `variantCount` 全为 0，故用合成样例覆盖「非空 `variants[]` + 未知字段忽略 + 可选字段缺失」路径 |
| `synthetic/track-page-relative-audio.json` | **R16-1 的缺失形态**：真实回灌 fixture 的 `audioUrl` 全是绝对直链，而 2026-09-24 只读探针实测 `GET /api/tracks` 的 **20/20 行是相对路径**（`/api/tracks/<id>/preview-stream`；服务端 `src/lib/api-dto.ts:135-137` 把整曲桶直链一律改写为本站代理端点）。本样例 = `track-page.json` 的同一批行，只把 `audioUrl`/`audio_url` 换成该真实形态，`cover` 保持绝对（两种拼写并存正是「画面正常、音频静默不可播」的成因）。**不是**新造的模型示例 |

## 四、写请求体（**契约目标形态**，写操作/需登录 → 无法只读验证）

编码单测把 DTO 的编码结果与这些 fixture 做结构比对，从而把「字段名（尤其 D8 幂等键
`idempotencyKey`）」钉死；字段名不符即测试失败。

| fixture | 端点 | 依据 |
|---|---|---|
| `requests/favorite-mutation-request.json` | `POST/DELETE /api/favorites` | 契约 §2 |
| `requests/saved-playlist-mutation-request.json` | `POST/DELETE /api/saved-playlists` | 契约 §2 |
| `requests/play-report-request.json` | `POST /api/tracks/play`（`source` ∈ 服务端闭合 allowlist `discover\|playlist\|project\|track_detail\|player`，取默认 `player`） | 契约 §2 + D8 |
| `requests/login-request.json` | `POST /api/auth/login`（password 为占位符，非真实凭据） | 契约 §1 + **NEEDS-1** |
| `requests/checkout-request.json` | `POST /api/downloads/checkout`（幂等键） | 契约 §3 + D8 |
| `requests/one-step-plan-start-request.json` | `POST /api/studio/one-step/plans/start`（幂等键） | 契约 §4 + D8 |
| `requests/create-session-request.json` | `POST /api/find-my-song/sessions` | 契约 §4 |
| `requests/media-retention-request.json` | `PATCH /api/media/references/:id/retention` | 契约 §4 |
