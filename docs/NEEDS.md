# NEEDS.md — 后端协作需求（阻塞登记）

> 规则：客户端发现接口缺口一律登记在此，**不得自行改后端**。每项标注阻塞的里程碑。
> 继承自 `多端/mobile/NEEDS.md`（RN 版同样未解决），按优先级排序。

| # | 编号 | 需求 | 阻塞 | 验收标准 |
|---|---|---|---|---|
| 1 | AUTH-LOGIN-TOKENS | `POST /api/auth/login` 返回 Bearer 契约 `{user, token, refreshToken, expiresIn}`；`POST /api/auth/refresh` refresh 旋转；`POST /api/auth/logout` | M1 | 真机完成登录→带 token 请求→401 自动 refresh 重放→登出。**✅ 已关闭（2026-09-24 对照 web 客户端源码，本项前提被否证）**：`user` 只含 `{id, email, name, role}` **不是后端缺口，而是设计如此** —— web 客户端登录成功后**不使用**登录响应的 `user`（`src/app/login/LoginForm.tsx:48-50` 只读 `data.error`，随后立刻 `refresh(true)` 走 `/me`），权威身份由 `getAuthUser()` 构造（`src/lib/auth/index.ts:268-277`：`id/covaId/email/name/role/phone/avatar/isArtist`），`/me` 再补 `isPartner/partnerType`（`src/app/api/auth/me/route.ts:13-24`）。⇒ **真正的缺陷在客户端**：iOS 把 `response.user` 当成会话身份，于是"刚登录的那一次会话"缺 `covaId`/身份标记/权益，直到冷启动走 `/me` 恢复路径才补齐（两处口径不一致）。已修：`signIn` 改为两步（建凭证 → `/me` 取身份），并新增两次响应 `id` 必须一致否则 fail-closed 收回凭证（登记为 **D21**，D20 的前提同时被更正）。**当初把这条报成后端缺字段，是我方读契约时把"目标形态"当成了"应当由后端补的洞"** —— 记在这里，避免后端同学按这条去改一个本来正确的实现 |
| 2 | PLAY-SOURCE-MOBILE | 播放上报 allowlist 增加 `app-ios` | M1 | `POST /api/tracks/play` 带 `source:"app-ios"` 返回 2xx |
| 3 | ENTITLEMENTS | `GET /api/auth/me` 稳定返回 `{user, entitlements:{plan, creditsBalance, monthlyCredits, canDownload, canUseCovaAI, canRequestProjects}}` | M1 | 字段齐全且与网页端一致。**2026-09-24 对照 web 更新**：真实形态是 **三键** `{user, entitlements, nameChange}`（`src/app/api/auth/me/route.ts:20-28`），`UserEntitlements` 另有 `subscriptionId/activeUntil/subscriptionSource/canFreeDownload/downloadQuota/licenseTier`（`src/lib/entitlements.ts:11-28`）⇒ iOS 侧多出的 `nameChange` 键被解码忽略（不报错），已核；**未登录时 `/me` 是 401 + `{user: null}`**（`me/route.ts:12`），iOS 必须按"未认证"处理而不是按"空用户"处理。**本项从"缺字段"降级为"已确认契约一致"**，剩余只是文档没写第三键 |
| 4 | ACCOUNT-DELETE | 账号删除端点（App Store 强制） | G4 | 提审前可用；删除后登录态失效 |
| 5 | APPLE-SIGNIN | Sign in with Apple 端点（若提供任何第三方登录则 Apple 强制；v1.0 仅邮箱登录可豁免，建议预留） | 上架可选 | — |
| 6 | LIBRARY-DOWNLOAD-RANGE | `GET /api/downloads/:id/file` 支持 Range（断点续传） | M3 | Range 请求返回 206 与正确字节 |
| 7 | PUSH-DEVICE-TOKEN | 远程推送设备 token 注册端点（生成完成推送） | M3 可选 | v1.0 用本地通知兜底，不阻塞 |
| 8 | TRACK-DETAIL-VARIANT-FIELDS | `GET /api/tracks/:id` 详情响应的 `track` 缺少列表接口（`GET /api/tracks`）中存在的变体字段族 `variantGroupId / variantRole / variantCount / variants`（2026-09-17 实测：列表有、详情无） | M1（非阻塞，客户端已按可选容忍） | 同一曲目在列表与详情返回一致的变体字段；否则详情页无法展示 A/B 变体 |
| 9 | PLAYLIST-DETAIL-SAVE-STATE | `GET /api/playlists/:id` 详情响应的 `playlist` 缺少列表接口中存在的用户态字段 `isSaved / writable / disabledReason / saveAction`（2026-09-17 实测：列表有、详情无） | M1（非阻塞，客户端已按可选容忍） | 详情响应带上收藏态，或提供明确的替代收藏态来源 |
| 10 | TRACK-SIMILAR-PROJECTION-CONSISTENCY | `GET /api/tracks/:id` 的 `similar[]` 与 `GET /api/tracks` 的 `tracks[]` 是**两套不一致的序列化**（2026-09-17 实测 10 详情 / 40 元素）：`similar[]` 用 snake_case `preview_start/preview_end`（**无** camel 别名）、`featured` 为数字 0/1（列表为 Bool）、`play_count/created_at/audio_duration` 仅 snake_case、`artist`/`tags` 为裁剪结构；客户端已按真实投影建独立 `SimilarTrackDto` | M1（非阻塞） | 同一「曲目」资源在 列表 / 详情 / similar 三处使用一致键名与值类型（或提供版本化投影说明） |
| 11 | FAVORITES-NOTE-ITEMS | `GET /api/favorites` 的 `{tracks}` 中混入「生成音乐收藏」条目（带 `source:"note"` / `noteId`，字段集与 `TrackDto` 不同），单一模型无法解码整个数组 | M1（非阻塞；客户端暂只建模库曲条目） | 提供类型判别字段与稳定条目模型，或拆为独立端点 |
| 12 | TRACK-SIMILAR-TO-PROJECTION | `GET /api/tracks?similarTo=<id>` 的 `tracks[]` 返回 **similar 投影**（`featured` 数字、仅 snake_case `preview_start/end/play_count/created_at/audio_duration`、多出 `similarityScore`、封套回显 `similarTo`），与同一端点的其余筛选（普通列表投影）不一致（2026-09-17 实测：3 个 seed × 5 条，`featured` 全为 int、camel `preview*` 0 命中；`search/energy/sort/vocalType` 对照仍为普通投影）。客户端已建 `SimilarTrackPageDto` / `SimilarTrackDto` 分别承接 | M1（非阻塞） | 统一 `tracks[]` 投影（建议全部走普通列表投影，或提供版本化投影标识），使同一端点只有一种元素模型 |
| 13 | SSE-AGENT-PAYLOAD-SCHEMA | `POST /api/studio/agent` 的**请求体字段**与 `thinking/text/error/done/plan_card/run_*` 各事件的**载荷 schema** 未在契约文档化；「坏事件」判定口径亦未定义（客户端暂按 web 源码与推断实现：`thinking/text/error`=`{text}`、`done`=`{}`、`plan_card`=卡投影；坏事件 = `data:` 载荷非合法 JSON，容忍未知/`run_*` 事件名）。**补充（2026-09-24，09「选一版继续制作」）**：请求体 schema 未文档化还带来一个具体后果 ——「用户挑了哪一个候选」**没有机器可读载体**（`plans/start` 只带计划卡四件套、`retention` 只有 `{favorite}`、候选投影里没有 chosen 字段），客户端因此把选择作为**自然语言 `message`** 走同一个 agent 通道发出（不新增键、不猜字段名）。需后端明确该意图的正规载体（agent 请求体里的结构化字段，或 `plans/start` 增候选位），或另给一个「候选选定」端点 | M2（非阻塞，客户端已按推断实现并容忍未知字段） | 契约补齐 agent 请求体与各事件载荷 schema，并明确「坏事件」判定口径，使降级触发的「3 个坏事件」有据可依；另需给「选中哪一版」一个正规载体 |

| 14 | PLAY-REPORT-RESPONSE-SCHEMA | `POST /api/tracks/play` 的**响应 schema 未文档化**。客户端 `PlayReportResponseDto{message, recorded, idempotentReplay, authenticated, play}` 是按 web 源码与推断写的**目标形态**，且 `idempotentReplay` 直接驱动客户端的去重分支（把它当服务端事实用）。 | M1（非阻塞：客户端已按可选容忍） | 文档化真实响应 schema 并给一份可回灌的脱敏样本；明确 `idempotentReplay`/`recorded` 的语义与幂等重放时的状态码 |
| 15 | PRIVATE-AUDIO-HOST-SHAPE | 私有候选音频的**签名地址 host 形状未文档化**。客户端出口守卫要求 host **恰为** `covalink.cn`（`CovaEnvironment.isProductionOrigin`）；若服务端把签名地址落在子域（如 `cdn.covalink.cn`），D7 的「先 Bearer 下载再本地播」会被 `.hostRejected` **永久堵死**。 | M1（解锁前私有候选试听不可用） | 明确候选音频/下载文件的实际 host（同域或子域清单）；若允许子域，需协调者批准收窄后的白名单，客户端不得自行放宽 |
| 16 | PRIVATE-AUDIO-CONTENT-LENGTH | 私有音频响应若不带 `Content-Length`（chunked 传输），客户端**只能判「非空」，判不出「早断」**——截断文件会被当作有效缓存交付播放。 | M1（非阻塞，与 #6 同源） | 私有音频响应恒带准确 `Content-Length`，或提供校验和/`ETag`/Range 支持（#6），使完成性可判定 |
| 17 | SESSION-MESSAGE-FIELDS | `GET /api/find-my-song/sessions/:id` 的**消息条目字段键名未文档化**（角色、文本、客户端消息 id 的具体键名与可空性），客户端只能按 web 源码推断解码。 | M2 | 文档化消息条目 schema（含 `clientMessageId` 归属校验所需字段，用于「计划卡归属 `sourceMessage.messageId === clientMessageId` 才解锁开始制作」） |
| 18 | SESSION-DELETE | **无会话删除端点**（会话列表左滑删除无处可调）。 | M2 | 提供 `DELETE /api/find-my-song/sessions/:id`（幂等），或明确「客户端隐藏删除」的产品口径 |
| 19 | CREATIONS-SUMMARY | 「我的创作」所需的**聚合摘要字段缺失**（每个会话的候选数/进行中任务/最后更新时间未随列表返回）。 | M3（非阻塞：可由列表页本地聚合降级） | 会话列表返回稳定摘要字段，或提供计数端点 |
| 20 | DOWNLOADS-LIST | **无「已下载」列表端点**：现有只有 `GET/POST /api/downloads/checkout` 与 `GET /api/downloads/:id/file`，无法呈现已下载曲目清单与空间占用统计。 | M3（且受 D12 合规门禁约束） | 提供已下载清单端点（含文件名/大小/时间），或明确「已下载只读本地缓存」的产品口径 |
| 21 | FAVORITES-BATCH | **无批量收藏态查询**：`GET /api/favorites` 返回整表，列表/详情页要判断「本屏哪些曲目已收藏」只能全量拉取或逐条查询。 | M1（非阻塞：降级为不显示收藏态或整表拉取） | 支持 `GET /api/favorites?trackIds=`（或返回可建的 id 集合），并明确分页/上限语义 |
| 22 | ARTIST-PROFILE | **无 AI 音乐人档案端点**：`GET /api/tracks?artistId=` 只能筛曲目，人设页所需的头像/简介/标签无处可取。 | M3 | 提供艺人档案端点（或明确由曲目投影聚合的字段清单） |
| 23 | STUDIO-SESSION-SCHEMA | **创作会话的条目 schema 未文档化**：`docs/api-contracts.md` §4 只给了 `GET /api/find-my-song/sessions` / `…/:id` 两个路径与「详情含 `messages[] / generationJobs[]`」这一句，**没有任何字段清单**；`POST …/sessions` 的响应信封也没写（客户端目前容忍 `{session:{id}}` 与 `{id}` 两种，列表容忍 `{sessions[]}` / `{items[]}` / `{data[]}` / 裸数组四种，全接不上即报错而不是当空列表）。另需明确：消息条目里哪个键是正文（`text` 还是 `content`）、`role` 的取值集合、以及是否存在分页参数（客户端**不发明** `?limit=`/`?before=`）。 | M2（非阻塞：08/09/12c 已按「只渲染取得到的字段」实现） | 给出会话/消息条目的字段清单与响应信封（含建会话响应），并说明有无分页 |
| 24 | CANDIDATE-SHARE-TARGET | **生成候选没有可公开访问的分享目标**。09 §3-H 的候选操作条列了「♡ 收藏 / ↓ 下载 / ⤴ 分享」三件，但 api-contracts §4 全表（sessions / plans / generation-jobs / agent / retention）里**既没有**「候选公开页」也**没有**任何 share/短链端点。可分享的两处常量链接（16 的 `covalink.cn/artists/:id`、02 与 07 的 `covalink.cn/tracks/:id`）承载的都是**公开曲库资源**；生成候选不是曲库曲目（09 §1 自己写着「若候选已被后端收录为库曲，v1.0 一般不可」）。剩下唯一可用的地址是 `audioUrl` / `audioDownloadUrl` —— 那是 Bearer 授权地址，交出去等于把凭证送出设备（硬边界 3 / D7 / TD-23 三面禁止）。 | M2（**客户端已按「不渲染分享钮」实现**，不放坏路径） | 二选一：① 提供候选的公开只读页（或其曲目化后的 `tracks/:id`）并写明 URL 形状与是否需要登录；② 提供 `POST /api/media/references/:id/share` 之类的服务端签发的短链/公开令牌端点。若产品口径是「生成物永不公开分享」，请明确写成一句话，客户端据此把 09 §3-H 的分享项从规格里划掉 |
| 25 | DELIVERY-PROGRESS-FIELD | **补充制作没有进度数值，也没有交付完成事实**：09 §3-I 要「左文案 + 右百分比」，并以 `fullMediaReady` 作为收起条件，但 `OneStepPlanCardDto`（12 态）与 `GenerationJob`（6 态 + `costCredits` + `metadata`）里**都没有** `progress` / `percent` / `deliveryProgress` / `fullMediaReady` 任何一类字段。客户端已降级为**里程碑而非百分比**：条只在 `delivery_preparing` / `rehydrating` 出现，填充比 = 契约前进状态序列里的位置，分母额外含那一格**观察不到的完成态** ⇒ 窗口内永不填满；右列显示 `7/9` 这类阶段计数而**不是一个猜出来的百分数**；「完整音频」徽标**不渲染**（没有完成事实可依据）。 | M2（非阻塞：已按降级形态实现，不显示假数字） | 给一个有据可依的进度数值（0–1 或 `done`/`total`）与一个明确的**完成布尔**（`fullMediaReady` 或等价字段，落在计划卡或候选投影里）；并说明取消/失败时该数值如何解释 |
| 26 | SSE-EVENT-VOCAB | **`POST /api/studio/agent` 的事件名比契约多**。契约 §4 只列 `thinking / text / plan_card / error / done / run_*`；2026-09-24 用真实账号实测一条完整跑动，另见到 `reasoning_summary`、`credits`、`skill_started`、`skill_completed`、`repair_started`、`verification_completed`、`run_completed`。iOS 当前对未知事件**刻意忽略**（不猜语义、也不当错误上报），但这些名字明显带信息（`credits` 像余额、`verification_completed` 像交付事实、`repair_started` 像用户可感知的等待）。需后端把**事件字典与各字段语义**文档化 | M2 | 事件字典写进 `docs/api-contracts.md` §4；iOS 对每个新事件给出显式处置（使用，或在注释里写明"知道它、选择忽略"的理由），不允许靠"未知即忽略"长期兜底 |

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
