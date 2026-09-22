# NEEDS.md — 后端协作需求（阻塞登记）

> 规则：客户端发现接口缺口一律登记在此，**不得自行改后端**。每项标注阻塞的里程碑。
> 继承自 `多端/mobile/NEEDS.md`（RN 版同样未解决），按优先级排序。

| # | 编号 | 需求 | 阻塞 | 验收标准 |
|---|---|---|---|---|
| 1 | AUTH-LOGIN-TOKENS | `POST /api/auth/login` 返回 Bearer 契约 `{user, token, refreshToken, expiresIn}`；`POST /api/auth/refresh` refresh 旋转；`POST /api/auth/logout` | M1 | 真机完成登录→带 token 请求→401 自动 refresh 重放→登出。**补充（2026-09-17 只读核对）**：`{token, refreshToken, expiresIn}` 已符合契约，但 `user` 只含 `{id, email, name, role}`，缺 `covaId / phone / isArtist / isPartner`，无法解码为契约的完整 `AuthUser` → 需补齐。**客户端处置（2026-09-22，D20）**：登录解码已容忍 `isArtist/isPartner/covaId/phone` 缺席（布尔缺席一律读 `false` = 保守不放大权限；`id/name/role` 仍严格必需，缺席照旧报错）⇒ 登录不再被本缺口整体阻塞。**缺口本身仍开放**：补齐后客户端才能真实展示 `covaId` / 艺术家·合作方身份 |
| 2 | PLAY-SOURCE-MOBILE | 播放上报 allowlist 增加 `app-ios` | M1 | `POST /api/tracks/play` 带 `source:"app-ios"` 返回 2xx |
| 3 | ENTITLEMENTS | `GET /api/auth/me` 稳定返回 `{user, entitlements:{plan, creditsBalance, monthlyCredits, canDownload, canUseCovaAI, canRequestProjects}}` | M1 | 字段齐全且与网页端一致 |
| 4 | ACCOUNT-DELETE | 账号删除端点（App Store 强制） | G4 | 提审前可用；删除后登录态失效 |
| 5 | APPLE-SIGNIN | Sign in with Apple 端点（若提供任何第三方登录则 Apple 强制；v1.0 仅邮箱登录可豁免，建议预留） | 上架可选 | — |
| 6 | LIBRARY-DOWNLOAD-RANGE | `GET /api/downloads/:id/file` 支持 Range（断点续传） | M3 | Range 请求返回 206 与正确字节 |
| 7 | PUSH-DEVICE-TOKEN | 远程推送设备 token 注册端点（生成完成推送） | M3 可选 | v1.0 用本地通知兜底，不阻塞 |
| 8 | TRACK-DETAIL-VARIANT-FIELDS | `GET /api/tracks/:id` 详情响应的 `track` 缺少列表接口（`GET /api/tracks`）中存在的变体字段族 `variantGroupId / variantRole / variantCount / variants`（2026-09-17 实测：列表有、详情无） | M1（非阻塞，客户端已按可选容忍） | 同一曲目在列表与详情返回一致的变体字段；否则详情页无法展示 A/B 变体 |
| 9 | PLAYLIST-DETAIL-SAVE-STATE | `GET /api/playlists/:id` 详情响应的 `playlist` 缺少列表接口中存在的用户态字段 `isSaved / writable / disabledReason / saveAction`（2026-09-17 实测：列表有、详情无） | M1（非阻塞，客户端已按可选容忍） | 详情响应带上收藏态，或提供明确的替代收藏态来源 |
| 10 | TRACK-SIMILAR-PROJECTION-CONSISTENCY | `GET /api/tracks/:id` 的 `similar[]` 与 `GET /api/tracks` 的 `tracks[]` 是**两套不一致的序列化**（2026-09-17 实测 10 详情 / 40 元素）：`similar[]` 用 snake_case `preview_start/preview_end`（**无** camel 别名）、`featured` 为数字 0/1（列表为 Bool）、`play_count/created_at/audio_duration` 仅 snake_case、`artist`/`tags` 为裁剪结构；客户端已按真实投影建独立 `SimilarTrackDto` | M1（非阻塞） | 同一「曲目」资源在 列表 / 详情 / similar 三处使用一致键名与值类型（或提供版本化投影说明） |
| 11 | FAVORITES-NOTE-ITEMS | `GET /api/favorites` 的 `{tracks}` 中混入「生成音乐收藏」条目（带 `source:"note"` / `noteId`，字段集与 `TrackDto` 不同），单一模型无法解码整个数组 | M1（非阻塞；客户端暂只建模库曲条目） | 提供类型判别字段与稳定条目模型，或拆为独立端点 |
| 12 | TRACK-SIMILAR-TO-PROJECTION | `GET /api/tracks?similarTo=<id>` 的 `tracks[]` 返回 **similar 投影**（`featured` 数字、仅 snake_case `preview_start/end/play_count/created_at/audio_duration`、多出 `similarityScore`、封套回显 `similarTo`），与同一端点的其余筛选（普通列表投影）不一致（2026-09-17 实测：3 个 seed × 5 条，`featured` 全为 int、camel `preview*` 0 命中；`search/energy/sort/vocalType` 对照仍为普通投影）。客户端已建 `SimilarTrackPageDto` / `SimilarTrackDto` 分别承接 | M1（非阻塞） | 统一 `tracks[]` 投影（建议全部走普通列表投影，或提供版本化投影标识），使同一端点只有一种元素模型 |
| 13 | SSE-AGENT-PAYLOAD-SCHEMA | `POST /api/studio/agent` 的**请求体字段**与 `thinking/text/error/done/plan_card/run_*` 各事件的**载荷 schema** 未在契约文档化；「坏事件」判定口径亦未定义（客户端暂按 web 源码与推断实现：`thinking/text/error`=`{text}`、`done`=`{}`、`plan_card`=卡投影；坏事件 = `data:` 载荷非合法 JSON，容忍未知/`run_*` 事件名） | M2（非阻塞，客户端已按推断实现并容忍未知字段） | 契约补齐 agent 请求体与各事件载荷 schema，并明确「坏事件」判定口径，使降级触发的「3 个坏事件」有据可依 |

| 14 | PLAY-REPORT-RESPONSE-SCHEMA | `POST /api/tracks/play` 的**响应 schema 未文档化**。客户端 `PlayReportResponseDto{message, recorded, idempotentReplay, authenticated, play}` 是按 web 源码与推断写的**目标形态**，且 `idempotentReplay` 直接驱动客户端的去重分支（把它当服务端事实用）。 | M1（非阻塞：客户端已按可选容忍） | 文档化真实响应 schema 并给一份可回灌的脱敏样本；明确 `idempotentReplay`/`recorded` 的语义与幂等重放时的状态码 |
| 15 | PRIVATE-AUDIO-HOST-SHAPE | 私有候选音频的**签名地址 host 形状未文档化**。客户端出口守卫要求 host **恰为** `covalink.cn`（`CovaEnvironment.isProductionOrigin`）；若服务端把签名地址落在子域（如 `cdn.covalink.cn`），D7 的「先 Bearer 下载再本地播」会被 `.hostRejected` **永久堵死**。 | M1（解锁前私有候选试听不可用） | 明确候选音频/下载文件的实际 host（同域或子域清单）；若允许子域，需协调者批准收窄后的白名单，客户端不得自行放宽 |
| 16 | PRIVATE-AUDIO-CONTENT-LENGTH | 私有音频响应若不带 `Content-Length`（chunked 传输），客户端**只能判「非空」，判不出「早断」**——截断文件会被当作有效缓存交付播放。 | M1（非阻塞，与 #6 同源） | 私有音频响应恒带准确 `Content-Length`，或提供校验和/`ETag`/Range 支持（#6），使完成性可判定 |
| 17 | SESSION-MESSAGE-FIELDS | `GET /api/find-my-song/sessions/:id` 的**消息条目字段键名未文档化**（角色、文本、客户端消息 id 的具体键名与可空性），客户端只能按 web 源码推断解码。 | M2 | 文档化消息条目 schema（含 `clientMessageId` 归属校验所需字段，用于「计划卡归属 `sourceMessage.messageId === clientMessageId` 才解锁开始制作」） |
| 18 | SESSION-DELETE | **无会话删除端点**（会话列表左滑删除无处可调）。 | M2 | 提供 `DELETE /api/find-my-song/sessions/:id`（幂等），或明确「客户端隐藏删除」的产品口径 |
| 19 | CREATIONS-SUMMARY | 「我的创作」所需的**聚合摘要字段缺失**（每个会话的候选数/进行中任务/最后更新时间未随列表返回）。 | M3（非阻塞：可由列表页本地聚合降级） | 会话列表返回稳定摘要字段，或提供计数端点 |
| 20 | DOWNLOADS-LIST | **无「已下载」列表端点**：现有只有 `GET/POST /api/downloads/checkout` 与 `GET /api/downloads/:id/file`，无法呈现已下载曲目清单与空间占用统计。 | M3（且受 D12 合规门禁约束） | 提供已下载清单端点（含文件名/大小/时间），或明确「已下载只读本地缓存」的产品口径 |
| 21 | FAVORITES-BATCH | **无批量收藏态查询**：`GET /api/favorites` 返回整表，列表/详情页要判断「本屏哪些曲目已收藏」只能全量拉取或逐条查询。 | M1（非阻塞：降级为不显示收藏态或整表拉取） | 支持 `GET /api/favorites?trackIds=`（或返回可建的 id 集合），并明确分页/上限语义 |
| 22 | ARTIST-PROFILE | **无 AI 音乐人档案端点**：`GET /api/tracks?artistId=` 只能筛曲目，人设页所需的头像/简介/标签无处可取。 | M3 | 提供艺人档案端点（或明确由曲目投影聚合的字段清单） |

## 已确认可用（无需等待，可并行开发）

- 曲库：`GET /api/tracks`（多维筛选/搜索/分页/排序/similarTo）、`GET /api/tracks/:id`、
  `GET /api/tracks/:id/preview-url`、`GET /api/library/taxonomy`
- 歌单：`GET /api/playlists`、`GET /api/playlists/:id`、`GET/POST/DELETE /api/saved-playlists`
- 收藏：`GET/POST/DELETE /api/favorites`
- Cova AI：`POST /api/find-my-song/sessions`、`GET /api/find-my-song/sessions[/:id]`、
  `GET /api/find-my-song/generation-jobs?id=`、`GET /api/studio/one-step/plans?sessionId=`、
  `POST /api/studio/one-step/plans/start`、`POST /api/studio/agent`（SSE）、
  `PATCH /api/media/references/:id/retention`
- 下载 checkout：`GET/POST /api/downloads/checkout`（扣费带幂等键，owned 跳过重复扣费）

字段级契约见 `docs/api-contracts.md`。
