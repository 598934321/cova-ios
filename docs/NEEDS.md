# NEEDS.md — 后端协作需求（阻塞登记）

> 规则：客户端发现接口缺口一律登记在此，**不得自行改后端**。每项标注阻塞的里程碑。
> 继承自 `多端/mobile/NEEDS.md`（RN 版同样未解决），按优先级排序。

| # | 编号 | 需求 | 阻塞 | 验收标准 |
|---|---|---|---|---|
| 1 | AUTH-LOGIN-TOKENS | `POST /api/auth/login` 返回 Bearer 契约 `{user, token, refreshToken, expiresIn}`；`POST /api/auth/refresh` refresh 旋转；`POST /api/auth/logout` | M1 | 真机完成登录→带 token 请求→401 自动 refresh 重放→登出 |
| 2 | PLAY-SOURCE-MOBILE | 播放上报 allowlist 增加 `app-ios` | M1 | `POST /api/tracks/play` 带 `source:"app-ios"` 返回 2xx |
| 3 | ENTITLEMENTS | `GET /api/auth/me` 稳定返回 `{user, entitlements:{plan, creditsBalance, monthlyCredits, canDownload, canUseCovaAI, canRequestProjects}}` | M1 | 字段齐全且与网页端一致 |
| 4 | ACCOUNT-DELETE | 账号删除端点（App Store 强制） | G4 | 提审前可用；删除后登录态失效 |
| 5 | APPLE-SIGNIN | Sign in with Apple 端点（若提供任何第三方登录则 Apple 强制；v1.0 仅邮箱登录可豁免，建议预留） | 上架可选 | — |
| 6 | LIBRARY-DOWNLOAD-RANGE | `GET /api/downloads/:id/file` 支持 Range（断点续传） | M3 | Range 请求返回 206 与正确字节 |
| 7 | PUSH-DEVICE-TOKEN | 远程推送设备 token 注册端点（生成完成推送） | M3 可选 | v1.0 用本地通知兜底，不阻塞 |

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
