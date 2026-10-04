# 19 · 创作台（一句话做歌 · P0 最小闭环）

> 逐屏规格。基准 393×852pt。骨架基线：`09-ai-session-detail.md` §2–§6 与 `12a-favorites.md` 行几何。
> 数据源：`POST /api/studio/create/generate`、`GET /api/find-my-song/generation-jobs?id=`、
> `GET /api/studio/create/works?id=`（契约见 `DEVELOPMENT.md` §4.4）。
> **本屏只施工 `mode:'simple'` + `operation:'create'`**（DEVELOPMENT.md §5 P0-2）；
> advanced / melody / cover / extend / remaster 属 P1，**入口与控件一律不渲染**（不是置灰）。

## 1. 屏与上下文

- **层级**：push 自 08；入导航栈。深链 `studio-create`。
- **入口**：① 08 会话列表顶部动作区「直接做歌」文字钮（与「新会话」并列，语义分工见下）；
  ② 深链 `studio-create`。
- **与 08/09 的职责划分（本屏存在的前提，必须钉清）**：
  | | 08/09 一句话创作 | 19 创作台 |
  |---|---|---|
  | 通道 | `POST /api/studio/agent`（SSE 会话，agent 决定找歌或做歌） | `POST /api/studio/create/generate`（直接下任务） |
  | 心智 | 「跟它聊」——计划卡 12 态、可改词、可重做 | 「一句话交活」——提交 → 任务 → 两首作品 |
  | 计费 | `plans/start` | reason = `studio_create_generation`，**先落 job 后扣费** |
- **互链**：结果行 → 02 播放器（作品试听态）；结果行 ↓ → 本机直存（**不走 12d**，见 §7）；
  失败行「查看任务」→ 无（P0 不做任务详情页，`errorMessage` 就地展示）。
- **返回**：同 12a。**登录门槛**：需登录（未登录 → 17-S6，CTA「登录」）。
- **D12 合规**：本屏**无购买/充值入口**、无价格表、无「余额不足请充值」类文案；
  余额不足只说服务端给的事实（§8）。扣费数字只来自**响应回显**（`charge`），不预先报价
  （契约无「生成预估价」端点 ⇒ 不发明）。

## 2. 布局（393×852）

```
┌─────────────────────────────────────┐
│ [‹]  做一首歌                        │  A 导航条
│ ╭─ 描述卡 ────────────────────────╮ │
│ │ 说场景、说情绪、说人声…            │ │  B prompt 多行输入
│ │                                 │ │     （card 圆角 / elevated 底 / 1pt line）
│ │                          0/2000 │ │     计数 type.mono caption
│ ╰─────────────────────────────────╯ │
│ [        开始生成        ]           │  C 主 CTA（胶囊 50，gradient.brandButton，白字）
│ ── 本次任务 ─────────────────────    │  D 任务区（提交后出现，未提交整区不渲染）
│ │ 制作中 · 已等 1 分 20 秒           │ │     状态行 type.subhead + type.mono 计时
│ │ ▓▓▓▓▓▓▓▓░░░░░░（不确定条）         │ │     高 4，accent，indeterminate
│ ╰─ 本次消耗 20 co ────────────────╯ │     charge 回显（仅 >0 时出现）
│ ── 作品（2）─────────────────────    │  E 结果区（终态后出现）
│ │ ♪ 封面  夏夜城市        2:38  ▶ ↓ │ │     CovaListRow（封面 48 / 行高 64）
│ │ ♪ 封面  夏夜城市（副歌）  2:41  ▶ ↓ │ │     ↓ 已存后转 checkmark.circle success
│ ╭─ MiniPlayer ──────────────────╮  │
└─────────────────────────────────────┘
```

页边距 `pageGutter`；分区间距 `xl`；D/E 分组标题同 12c §3.C（`type.caption` / `color.muted`）。

## 3. 区块规格

- **A 导航条**：`material.navGlass`；标题「做一首歌」`type.headline`；无右侧动作。
- **B 描述卡**：`color.elevated` + 1pt `color.line` + `radius.card`，内边距 `spacing.lg`；
  多行输入最少 4 行高、最多 8 行后内部滚动；占位文字 `type.body` / `color.muted`
  「说场景、说情绪、说人声…（例如：夏夜城市里的合成器流行，女声，中速）」；
  聚焦时 1pt `color.focusRing` 描边（中性灰焦点环，web 同款；10 §3 输入态同步改用）；
  计数右下 `type.mono` / `type.caption`：`<utf8 字数>/2000`，
  **达上限转 `color.warning`**，超出由输入端截断（不允许提交超长串去换服务端 400）。
- **C 主 CTA**：胶囊高 50、`gradient.brandButton` 底、白字 `type.headline`；
  **prompt 去空白后为空 ⇒ 不渲染为可点**（`disabled` 态按 §3.6：muted 底/字，
  且**不显示**任何解释文案——空输入不需要教训用户）；
  提交在途 ⇒ 菊花替换文字、**不可二次点击**（幂等键纪律的 UI 面：一次点击 = 一个键，
  见 §7「幂等」）；成功后 CTA 文案转「再做一首」（点击 = 清空 B 与 D/E，回到初始态）。
- **D 任务区**：
  - 状态行文案一律取 `GenerationJobStatusCopy`（A15 术语口径唯一源），
    计时 `已等 <m 分 s 秒>`（`type.mono`，秒级刷新，**不印百分比**——契约无进度字段）；
  - 不确定条：轨道 `color.surface`、填充 `color.accent`、高 4、`radius.capsule`，
    左右往返位移（`motion.duration.slow`）；**不是**确定进度条；
  - 终态 `succeeded` ⇒ D 区收成一行「已完成 · 用时 <…>」，不确定条消失；
  - 终态 `failed` / `cancelled` ⇒ 状态行转 `color.error`，下方就地展示
    `errorMessage`（服务端原文；为空时兜底「这次没做成，可以再试一次」），
    并出现文字钮「重新生成」（= 一次**新的**逻辑提交 ⇒ 新幂等键）；
  - `charge > 0` 时追加一行「本次消耗 <N> co」（`type.caption` / `color.muted`，
    `type.mono` 数字）；`charge == 0` 或缺失 ⇒ **该行不渲染**（不写「免费」，
    因为 0 也可能是开发环境开关关闭，客户端无从判别）。
- **E 结果区**：`CovaListRow`（封面 48 / 行高 64 / 分隔 `color.lineSubtle` 1pt）
  - 主标题 = 作品 `title`（缺失回落「未命名作品」）；副标题 = 时长（`type.mono`）
    + `instrumental == true` 时追加「纯音乐」徽标（`type.caption` / `color.muted`）；
  - 右侧两枚 ≥44pt 图标钮：▶ 播放（`play.circle`，玻璃底 TG-22 同族）、
    ↓ 直存（`arrow.down.circle`）；已存 ⇒ `checkmark.circle` / `color.success`，
    再点 = 删除本机文件（二次确认 Alert：「删除本机文件？」/「删除」「取消」）；
  - **不渲染** ♡ / ⋯ / 分享 / 重命名 / 歌词 / 波形 / bpm —— 那些是 P1 的行内动作与
    库曲专属字段（作品行契约里 `bpm` 恒 null、`waveformPeaks` 恒空，见 §7）；
  - 行点击（非按钮区）= 同 ▶。
- **播放与上报**：▶ 走作品试听（02 播放器），条目 `kind = .work`、
  `id = "{jobId}:{candidateId}"`；起播即产生一次 `POST /api/tracks/play`
  （`source = player`，见 §7「上报」）。

## 4. 状态变体

- **加载**：本屏**无首屏骨架**——初始态就是空表单（B/C 立即可用），D/E 未提交前不存在，
  骨架会制造「应该有内容」的错觉（同 12c §4 F 区口径）。
- **提交在途**：C 菊花 + D 区「排队中」；此时返回上一页 ⇒ 任务**继续在后台轮询**
  （轮询器归会话层持有，不归本视图），回到本屏按当前状态续显。
- **轮询中**：D 区计时走秒；`queued/submitted/processing` 三态文案不同（`GenerationJobStatusCopy`）。
- **错误**（就地，不 Toast 刷屏；文案见 §8）：
  | 触发 | 表现 |
  |---|---|
  | 400 `invalid_request`（缺 prompt / 超长） | D 区状态行 `color.error` + 服务端 `error` 原文 |
  | 402 `credits_insufficient` | 「余额不足，本次需要 <required> co」；`required` 缺失 ⇒ 「余额不足」 |
  | 409 `IDEMPOTENCY_CONFLICT` | 「这次提交和上一次撞了，请重试」（不自动重发写操作） |
  | 429 | 服务端 `error` 原文（「请求过于频繁，请稍后再试」）。**不做倒计时**：`HTTPResponse` 不携响应头 ⇒ `Retry-After` 客户端读不到（§7「不得发明」） |
  | 502/503 `submit_failed` | 服务端 `error` 原文 + 「重新生成」钮 |
  | 401/403 | 17-S6 登录态（不显示「凭证错」类糊词） |
  | 网络/超时/出口拒绝 | 17-S4 离线条 + 「重试」（重试 = 同一次提交 ⇒ **复用同一幂等键**） |
  | 轮询到 `failed` | D 区失败态（§3.D）+ `errorMessage` |
  | 轮询超上限（约 30min） | D 区「还在做，稍后回来看」+ 停止轮询（**不说失败**：任务可能仍在跑） |
- **空态**：无（B 的占位文字即引导）。
- **离线**：C 禁用（同「输入为空」的 disabled 形态）+ 17-S4 离线条；
  E 区若已有本机文件仍可播（`file://`，不发网络）。
- **Reduce Motion**：不确定条往返位移 → 静态满条（`color.accent`，透明度 60%）；
  行插入位移 → 一帧；CTA 按压弹簧 → 无。

## 5. 深浅双主题差异

- 纯 token 双值：B 卡 `color.elevated` / 1pt `color.line`、D 条轨道 `color.surface` /
  填充 `color.accent`、E 行分隔 `color.lineSubtle`，双主题均已定义 ⇒ **本屏无专属深色底**。
- C 主 CTA 用 `gradient.brandButton`（深浅同族，白字对比度达标）。
- ▶ 钮玻璃材质系统自适应。

## 6. 可访问性

- **朗读顺序**：「做一首歌，标题」→ 返回 → B「音乐描述，多行输入，<占位>」→
  计数（「120，共 2000 字」）→ C「开始生成，按钮」→（D 存在时）「本次任务」→
  「制作中，已等 1 分 20 秒」→（charge 行）「本次消耗 20 co」→（E 存在时）「作品，2 项」→
  每行「<标题>，2 分 38 秒，播放 按钮，保存到本机 按钮」（已存 ⇒「已在本机，删除本机文件 按钮」）。
- **不确定条不独立成元素**（状态已在标签内）；计时**不**随秒自动重复播报（只在聚焦时读当前值，
  09 §7 同规则）。
- **Dynamic Type**：AX 档下 D 区状态行与计时两行堆叠；E 行副标题（时长 + 徽标）换到第三行，
  行高自适应；C 保持单行。
- **触控目标 ≥44pt**：返回 / B 输入区 / C / ▶ / ↓ / 「重新生成」/「重新做一首」/ Alert 两钮。

## 7. 数据契约

| 用途 | 端点 | 字段与说明 |
|---|---|---|
| 提交 | `POST /api/studio/create/generate` | body `{mode:'simple', prompt, idempotencyKey}`；响应 `{ok:true, jobId, charge:<数字>}`。**`charge` 是数字不是对象**（实测 `web/src/lib/studio/create/generate.ts:526-530`）；未开 `COVA_SUNO_AGENT_ENABLED` 时恒 0 |
| 任务轮询 | `GET /api/find-my-song/generation-jobs?id=<jobId>` | `{job:{…}}`；`status ∈ queued\|submitted\|processing\|succeeded\|failed\|cancelled`；`metadata` 是 **JSON 字符串**，候选在 `metadata.candidates[]`（键 `id/title/audioUrl/coverUrl/duration`） |
| 作品行 | `GET /api/studio/create/works?id=<jobId>` | `{works:[CreateWorkItem], nextCursor, total}`；`id` = `jobId:candidateId`；生成中为占位行 `id="<jobId>:pending-1\|2"`，`coverUrl/audioUrl/duration/providerClipId` 全 null |
| 结果音频 | `CreateWorkItem.audioUrl` | **站内相对路径**三种形态：`/audio/*.mp3`（公开静态，免凭证）｜`/api/media/objects/<id>?…`（需 Bearer，且 `intent!=download` 时 302→COS）｜`/api/proxy/audio?…`（HMAC 签名，TTL 30min，不 302） |
| 免凭证直链 | `CreateWorkItem.playbackUrl` | 预签名 COS **绝对** https，TTL 900s，免请求头；**仅 `/api/media/objects/` 形态才签发**，经典 worker 路径（`/audio/*`）恒缺 ⇒ 客户端按可选处理 |
| 本机直存 | 无端点 | 走 `audioUrl`（缺则 `playbackUrl`）**直接落盘**，**不经 `/api/downloads/checkout`、不扣费**（BUG-15 双路径分野；证据：works/playback-url/objects/proxy-audio 五个实现文件里 `consumeCredits\|grantCredits\|ledger` 零命中，且 `checkoutDownloads` 只接受已发布库曲 `trackIds`，`jobId:candidateId` 根本无法进入） |

- **幂等（本屏最要紧的一条）**：`idempotencyKey` **必填**，字符集服务端实测
  `^[A-Za-z0-9._:-]{8,128}$`（本仓 `IdempotencyKey` 的 `[A-Za-z0-9_-]` 是其子集 ⇒ 恒被接受）。
  ① **一次点击 = 一个新键**（`IdempotentRequestToken(operation: .studioCreateGenerate)`）；
  ② **同一次提交的重试（网络重放/离线恢复）必须复用同键** ⇒ 服务端返回已有 jobId、不二次扣费；
  ③ 「重新生成」「再做一首」是**新的逻辑提交** ⇒ 新键；
  ④ 服务端另有 **10 分钟同指纹去重**（`COVA_CREATE_DEDUP_WINDOW_MS`，默认 600000）：
  两把不同键但请求体相同 ⇒ 复用同一 jobId。**响应与首次完全同形，没有任何复用标记**
  （实测 `generate.ts:446-449`、`:486-489`）⇒ 客户端**不得**声称「服务端告诉我们这是重放」，
  也不得靠标记去重；UI 只在**同键重放**时按 `jobId` 相同这一事实收敛（不印「重复提交」类断言）。
- **上报（work_listens）**：作品起播 ⇒ `POST /api/tracks/play`，
  `trackId = "{jobId}:{candidateId}"`（**伪 trackId**；服务端 `play-history.ts:50` 判
  `!track && (trackId.includes(':') || jobExists(trackId))` ⇒ 裸 jobId 也接受，但裸 jobId 行在
  GET 历史里可能因取不到音频而**整行被丢弃**，故本屏一律带候选后缀），
  `source` 只取闭合枚举 `player`（`PlayReportSource` 类型钉死；越界恒 400）。
  同键下 `(trackId, source)` 任一不同 ⇒ 409，故重试连 source 一起复用（`PlayReportCoordinator` 已按集次固定）。
- **历史可见性**：上报成功后 `GET /api/play-history` 的 items 会出现该作品行
  （`trackId` 含 `:`、`track.workId` 非空、`bpm`/`artist`/`artistId` 为 null、
  `favoriteCount` 为 null、`waveformPeaks` 为空数组）⇒ 01「继续聆听」必须分型解码（见 `01-home.md`）。
- **不得发明的字段/端点**：`progress`/`percent`/`eta`（无进度字段 ⇒ 不印百分比）、
  `estimatedCost`/`price`（无预估价端点 ⇒ CTA 不报价）、`423 provider_lease_busy`
  （**generate 永不返回 423**：上游 423 被 catch-all 吞成 `submit_failed` 502/503，
  实测 `generate.ts:531-536`；423 只存在于 lyrics/style-suggest 通道）、
  `Retry-After` 倒计时（本仓 `HTTPResponse` 只有 `statusCode` 与 `body`，**没有 header 面**
  ⇒ 读不到就不承诺；要它得先给传输层加 header，属另一批活）、
  `works`/`creations` 聚合计数端点（12c 待裁决 1 同源）。

## 8. 边界与文案

- **截断**：作品标题 1 行（AX 2 行）；`errorMessage` 最多 3 行后中段截断。
- **极值**：prompt 2000 字（服务端上限，超出**本地截断**，不发出去换 400）；
  结果行数恒 ≤2（双曲）；轮询上限约 30min（前 6 次 5s、之后 10s）。
- **并发冲突**：本屏在途时进入 09 的 `plans/start` ⇒ 两条写路径各自持键，互不复用；
  同一任务被两处轮询（本屏 + 08 进度环）⇒ 轮询器归会话层单实例，两处共读一份状态。
- **零余额 / D12**：本屏**永不**出现「充值 / 购买 / 价格 / 余额不足请充值」；
  余额不足只说 §4 表里那一句（事实 + 服务端给的数字）。
- **文案清单**：`做一首歌` / `直接做歌` / `开始生成` / `再做一首` / `重新生成` /
  `说场景、说情绪、说人声…（例如：夏夜城市里的合成器流行，女声，中速）` /
  `本次任务` / `已等 %d 分 %d 秒` / `用时 %d 分 %d 秒` / `本次消耗 %d co` /
  `作品（%d）` / `未命名作品` / `纯音乐` / `已完成` / `还在做，稍后回来看` /
  `这次没做成，可以再试一次` / `余额不足，本次需要 %d co` / `余额不足` /
  `这次提交和上一次撞了，请重试` / `删除本机文件？` / `删除` / `取消` /
  `已在本机` / `保存到本机` / `播放`

## 9. 验收判据

- [ ] prompt 为空 ⇒ CTA 不可点，且**不发任何请求**（网络面板取证）
- [ ] 一次点击 = 一个幂等键；同一次提交的离线重试复用同键（抓包：两次请求 `idempotencyKey` 相同、
      第二次响应 `jobId` 与首次一致、`charge` 不二次扣）
- [ ] 「重新生成」产生**新**键（抓包：键不同）
- [ ] D 区状态文案全部来自 `GenerationJobStatusCopy`，屏上无英文态名（`queued`/`processing` 等）
- [ ] 无进度百分比、无预估价、无「免费」字样
- [ ] 402 显示「余额不足，本次需要 N co」；400 显示服务端中文原文；两者都不出现「未知错误」
- [ ] `succeeded` ⇒ E 区恰 2 行；`failed` ⇒ `errorMessage` 就地展示 + 「重新生成」
- [ ] ▶ 起播 ⇒ `POST /api/tracks/play` 的 `trackId` 形如 `<jobId>:<candidateId>`、
      `source == "player"`、响应 `recorded:true`；随后 `GET /api/play-history` items 含该行
- [ ] ↓ ⇒ 沙盒出现非 0 字节音频文件、时长与 `duration` 一致；`GET /api/me/credits/ledger`
      **无新增扣费行**；行内标记转「已在本机」，再点 = 删除（二次确认）
- [ ] 屏内无 ♡ / ⋯ / 分享 / 重命名 / 波形 / bpm（作品行契约里这些恒空）
- [ ] 全部值 token 化；深浅双主题各一图；Reduce Motion 替代态可见

## Token 缺口

继承 12a（TG-03 触控 / TG-04 描边 / TG-09 缓存时限 / TG-18 行高 / TG-31 分组标题）与
09 的输入区规格，另加：

| # | 缺口 | 本屏用法 |
|---|---|---|
| TG-23 | 细条高度档 | D 不确定条（高 4） |
| TG-22 | 玻璃浮动钮尺寸档 | E 行 ▶ 钮 |
| TG-42 | 多行输入的最小/最大行高档 | B（4 行起、8 行后内滚） |
| TG-43 | 字数计数字号与达限色档 | B 计数（`type.mono` caption / 达限 `color.warning`） |

## 待裁决

1. **advanced / melody 模式的表单形态**：P1 才施工，届时 B 区需扩展为「歌词 + 风格」双输入
   与 `continueAt` 选择器；本屏 §1 的「只施工 simple」是 P0 的**范围**声明，不是终态设计。
2. **任务详情页**：`errorMessage` 就地展示 vs 独立任务页（P1 works 列表落地后再定）。
3. **`charge == 0` 的语义**：开发环境开关关闭与真实免费在响应上不可区分 ⇒ 本规格采「不渲染该行」；
   若产品要求区分，需后端在响应里加标记（NEEDS 候选 `CREATE-CHARGE-FLAG`）。
