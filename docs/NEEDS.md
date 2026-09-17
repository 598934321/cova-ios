# NEEDS.md — 后端协作需求（阻塞登记）

> 规则：客户端发现接口缺口一律登记在此，**不得自行改后端**。每项标注阻塞的里程碑。
> 继承自 `多端/mobile/NEEDS.md`（RN 版同样未解决），按优先级排序。

| # | 编号 | 需求 | 阻塞 | 验收标准 |
|---|---|---|---|---|
| 1 | AUTH-LOGIN-TOKENS | `POST /api/auth/login` 返回 Bearer 契约 `{user, token, refreshToken, expiresIn}`；`POST /api/auth/refresh` refresh 旋转；`POST /api/auth/logout` | M1 | 真机完成登录→带 token 请求→401 自动 refresh 重放→登出。**补充（2026-09-17 只读核对）**：`{token, refreshToken, expiresIn}` 已符合契约，但 `user` 只含 `{id, email, name, role}`，缺 `covaId / phone / isArtist / isPartner`，无法解码为契约的完整 `AuthUser` → 需补齐 |
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
