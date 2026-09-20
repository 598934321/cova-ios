# 09 · 创作：会话详情（对话流 + 计划卡 + 双 Demo）

> G2 逐屏规格。基准 393×852pt。要点源：`inventory.md` 行 09。
> 数据源：`POST /api/studio/agent`（SSE）+ `GET /api/find-my-song/sessions/:id` +
> `GET /api/studio/one-step/plans?sessionId=` + `POST /api/studio/one-step/plans/start` +
> `GET /api/find-my-song/generation-jobs?id=` + `PATCH /api/media/references/:id/retention`
> （api-contracts §4）。组件规格：`../components.md` §4 PlanCard / §5 CandidateCard / §6 ComposerChips。
> 通用态规范源：`17-state-gallery.md`。
> **本屏是 M2 的核心与最易做错处**：12 态、降级四触发、双 Demo 终态硬规则（D7）、`run_*` 展示（TD-31）
> 全部在本文钉死。

## 1. 屏与上下文

- **层级**：push 自 08（或 01 会话卡提交后直接进入）；入导航栈；左缘右滑返回 08。
- **入口**：① 08 会话行；② 01 会话卡提交（做歌意图 → 先 `POST sessions` 再进本屏；找歌意图
  → 结果内嵌 01，不进本屏，见 01 §2）；③ 18 本地通知深链（§7 路由参数）；④ 12c/11 的「我的创作」。
- **互链**：候选卡 → 02 播放器（试听态，02 §8）；候选卡 ⋯ → 07（若候选已被后端收录为库曲，
  v1.0 一般不可 → 不渲染该菜单项）；标题候选/歌词编辑均在本屏内（不跳屏）。
- **返回行为**：流式进行中返回 → **不中断服务端**（服务端为事实源，PRD 4.2）：
  本屏退到后台时 SSE/轮询按 D16 有界取消语义终止本地任务，回到本屏重新拉一次 plans + jobs 对账。
- **登录门槛**：需登录 + `entitlements.canUseCovaAI`（NEEDS-3）。

## 2. 布局（393×852）

```
┌─────────────────────────────────────┐
│ [‹]  夏夜城市                   [⋯] │  A 导航条（会话标题可被后端重命名）
│ ┌ 连接状态条（仅降级时出现）───────┐ │  B 降级条（§3.B，四种触发）
│ │  连接中断，已切为自动刷新          │ │
│ └─────────────────────────────────┘ │
│ ┌───────────────────────────────┐   │
│ │            帮我做一首夏日… [我] │   │  C 用户气泡（accentSoft，右对齐）
│ │  ✦ Cova                         │   │  D agent 文本（无气泡，左对齐）
│ │  先确认这次做带唱还是纯音乐。     │   │
│ │  ▸ 深度思考 · 5 步        ⌄     │   │  E thinking 折叠块（muted）
│ │  ─ 正在设计曲风 · 68% ────────  │   │  F run_* 运行状态行（§3.F，TD-31）
│ │ ╭─ 计划卡（components §4）─────╮ │   │  G PlanCard（12 态，§4）
│ │ │ [草拟中]  标题候选 ▸ chips    │ │
│ │ │ 风格分析… 歌词折叠… 参数 chips │ │
│ │ │ credits 12 · 余额 128         │ │
│ │ │ [ 开始制作 ]  [修改要求]       │ │
│ │ ╰──────────────────────────────╯ │
│ │ ╭ 双 Demo 候选卡组（§5）───────╮ │   │  H CandidateCard ×2 + 终态条
│ │ │ [候选 A 50%] [候选 B 50%]     │ │
│ │ │ 就绪 1/2 · 等另一个候选完成    │ │
│ │ ╰──────────────────────────────╯ │
│ │ ▮▮ 补充制作进度（delivery_*）    │   │  I 交付进度条
│ └───────────────────────────────────┘ │     （列表可滚动，锚底）
│ ╭─ 会话输入卡（01 §2 同规格）──────╮ │  J Composer（吸底）
│ │ ✨ 继续说… [找歌][做歌][深度思考⌄]│ │
│ ╰─────────────────────────────────╯ │
└─────────────────────────────────────┘
```

## 3. 区块规格

### A 导航条

- `material.navGlass`；标题 `type.headline` / `color.fg`，1 行截断（会话名来自后端，未文档化时
  显「创作会话」，同 08 §7 降级）；右 ⋯（重命名/删除均受 08 待裁决 2 约束 → v1.0 ⋯ 仅「查看会话信息」
  只读 sheet，不做写操作）
- 图标按钮 ≥44pt（TG-03）

### B 连接状态条（SSE→轮询降级的唯一可视出口）

- 容器：整宽，`radius.control` 内衬 + `color.warning` 1pt 描边 + `color.accentSoft` 底（warning 描边，
  缺口 TG-21「warningSoft」衬底未入库 → 用 `color.accentSoft` 过渡并登记缺口）；高 = 文本 +
  上下 `spacing.md`；`type.subhead` / `color.fg`；左侧 `arrow.triangle.2.circlepath` 符号
- 常驻（不自动消失），只在**本轮流结束（done/终态）或 SSE 恢复**后收起，收起 `motion.duration.normal`
- 四种触发各自文案与视觉差异见 §4.2（**同一容器、同一位置，仅文案与图标节奏不同**——
  避免用户看到四个不同告警）

### C 用户气泡

- 右对齐；底 `color.accentSoft`；文字 `type.body` / `color.fg`；内边距 `spacing.md`（TG-22 气泡内边距）；
  圆角 `radius.card`（靠尾角一侧收 `radius.control`，指向说话人）
- 最大宽 = 屏宽 × 78%（TG-01 复用为「气泡最大宽比例」并登记）

### D agent 文本

- **无气泡**、左对齐，`type.body` / `color.fg`；最大宽 = 屏宽 − 2×`spacing.pageGutter` −
  agent 头像位（24pt 档 TG-18）
- 头像/标识：`sparkles` 符号用 `gradient.ai` 着色（AI 渐变只用于创作语境，design-language §2）
- 流式打字效果：逐 token 追加，**不做假光标闪烁**；结束时不做回弹
- Markdown/换行：保留段落；超长无空格串按字符截断换行（不溢出）

### E thinking 折叠块

- 收起态：一行 `▸ 深度思考 · N 步`，`type.subhead` / `color.muted`，整行 ≥44pt 热区
- 展开：逐条列表（`type.callout` / `color.muted`，序号 `type.mono`），左内缩 `spacing.lg` +
  2pt `color.line` 竖线（TG-04）；展开/收起 `motion.duration.fast` + `motion.curve`
- 公开步骤文案 = SSE `thinking` 事件的 `{text}`（NEEDS-13：载荷按 `{text}` 推断）。
  **不得**把内部实现词（schema repair / verifier / constraint retry）透出：
  若 `thinking.text` 命中未公开化字样，展示层按白名单短语回退为「正在整理计划细节」
  （短语集与 web 一步模式公开进度文案同构，见 §7 待裁决 5）
- 流式中的收起态行左侧带一次性脉冲（`color.muted`）， Reduce Motion 下静止

### F `run_*` 运行状态行（TD-31 方案）

- **形态**：单行 caption 级状态条，出现在当前 agent 段末尾（不进气泡、不占独立消息位）：
  `[符号] <短语> · <百分比或耗时（可选）>`，`type.caption` / `color.muted`，
  符号 12pt 档（TG-18），行上下 `spacing.xs`
- **事件 → 短语/符号映射（本屏唯一允许的实现表）**：

  | SSE 事件名 | 短语（zh） | 符号 | 颜色 | 是否计入「本轮仍在跑」 |
  |---|---|---|---|---|
  | `run_started` | 开始处理 | `sparkles` | `color.muted` | 是 |
  | `reasoning_summary` | 正在判断 | `brain.head.profile` | `color.muted` | 是 |
  | `run_waiting_user` | 等待你的决定 | `person.crop.circle.badge.questionmark` | `color.warning` | 否（需用户动作） |
  | `run_waiting_worker` | 歌曲制作中 | `hammer` | `color.muted` | 是 |
  | `run_completed` | 处理完成 | `checkmark.circle` | `color.success` | 否（该行 3s 后淡出） |
  | `run_failed` | 处理失败 | `xmark.octagon` | `color.error` | 否，且**同时**驱动 §4.2 之外的错误态 |
  | 其他 `run_*`（未知名） | **不显示** | — | — | 保持「处理中」不回落 |
- 规则：**只保留最后一条**运行状态行（新事件替换旧行，不堆叠历史，历史由 thinking 折叠块承载）；
  未知 `run_*` 名与任何未知事件名 → 静默忽略，**不计为坏事件**（坏事件口径 = `data:` 载荷非合法 JSON，
  NEEDS-13；此口径直接决定 §4.2 的「3 个坏事件」触发）
- `run_failed` 的 `recoverable` 类载荷未文档化 → 一律按「本轮未完成，可继续说」处理，
  **不**自动重试写操作

### G PlanCard

- 完全按 `../components.md` §4：`color.elevated` 底 + 1pt `color.line` 边 + `radius.card` +
  顶部 2pt `gradient.ai` 装饰条（宽度 100%）；内边距 `spacing.lg`；上下与消息流间距 `spacing.lg`
- 标题候选：选中项 `type.headline` / `color.fg`；候选 chips 高 36（TG-07），
  选中 `color.accentSoft`+`color.accentText`+1pt `color.accent` 边（components §6）
- 风格分析：`style.analysisZh` → `type.callout` / `color.fg`；`style.promptEn` → `type.mono`
  （tokens 中 mono 无 weight/size 之外的行高，caption 档字号）/ `color.muted`，默认折叠，
  「展开」文字钮
- 歌词预览：`lyrics.sections[]` 按 `order` 升序分节折叠，节标题 `type.subhead` / `color.secondary`，
  正文 `type.body` / `color.fg`，每节默认收起；`lyrics.displayText` 缺失时回落 `generationText`
  （两键均在 CovaCore DTO 中）
- 参数行：`parameters.{operation,vocalGender,targetDurationSec,weirdness,styleWeight}` →
  键值 chips（`type.caption` / `color.secondary`，`color.surface` 底）；
  `weirdness/styleWeight` 为 0–1 单位值 → 显示为百分数（「风格权重 65%」）；
  `targetDurationSec` 与 `durationSec` 同时存在时**以 `targetDurationSec` 为准**（契约字段优先级）
- 费用行：`credits`（`type.mono` / `color.accentText`，「预计消耗 N co」）+ 余额
  （`type.caption` / `color.secondary`，「余额 M」）；余额源 `entitlements.creditsBalance`（NEEDS-3）
- 底部操作：「开始制作」主钮（`gradient.brandButton`，高 50，TG-07）+「修改要求」文字钮
  （`color.accentText`）
- **状态徽标**（卡内左上）：`../components.md` §9 语义（success/warning/error/muted 胶囊 caption）
- 归属校验未通过（`sourceMessage.messageId !== clientMessageId`）→ 卡体置灰 50% +
  顶部 warning 条（components §4 已钉），「开始制作」禁用

### H 双 Demo 候选卡组

- 容器：把两张 `CandidateCard`（`../components.md` §5）包在一起，横排各 50%（间距 `spacing.sm`），
  与卡组底部「终态条」同一卡片框（`color.elevated` + 1pt `color.line`，`radius.card`）
- 终态条（本屏硬规则的视觉表达，§5）：`type.subhead`，高 = 文本 + `spacing.md`
- 单卡：封面方（比例 TG-10）或像素呼吸占位 + 标题 `type.subhead` + 时长 `type.mono` +
  状态徽标 §9 + 玻璃播放钮 40pt 悬浮居中（缺口 TG-22 玻璃圆钮尺寸档）+ 底部操作条（♡ 收藏 / ↓ 下载 / ⤴ 分享）

### I 补充制作进度条

- 仅 `status = delivery_preparing` 或 `rehydrating` 时出现：细轨道（`color.line`，
  高 4 档 TG-23）+ `color.accent` 进度；左文案「补充制作中」`type.subhead` / `color.secondary`，
  右百分比 `type.mono` / `color.muted`
- 完成（`fullMediaReady`）→ 条收起，候选卡上出现「完整音频」徽标（`color.success`）

### J Composer

- 与 01 §2 会话输入卡**同一组件同一规格**（玻璃卡、`radius.card`、模式 chips、深度思考 toggle、
  发送钮 40 圆形 `gradient.brandButton`）；吸底、键盘联动走系统默认
- 差异：本屏输入卡上沿加 1px `color.lineSubtle` 分隔（TG-04）；「找歌/做歌」默认沿用上轮选择；
  流式进行中发送钮禁用（`color.muted` 底）并显「停止生成」文字钮（见 §8 并发）

## 4. 状态变体

### 4.1 会话级

| 态 | 表现 |
|---|---|
| 首载 | A/B/J 立即可用；消息区 3 段骨架（一条短文本条 + 一张计划卡轮廓 + 一张候选卡组轮廓），`color.surface` 呼吸 |
| 空会话（新会话无消息） | 不显示空态插画（会打断创作心流）→ 显 J 上方一次性引导：`type.callout`/`color.secondary`「说一句你想要的歌：场景、情绪、时长」+ 3 枚 starter chips（08 §4 同源常量） |
| 错误 | `GET sessions/:id` 首载失败 → 整屏错误态「这个会话打不开」+「重试」；404 → 「这个会话已经不在了」（返回按钮回 08）；写操作失败（start/retention）→ Toast（不阻塞流） |
| 离线 | 有缓存消息 → 正常显示 + B 位换成 17-S4 离线条「离线，历史消息可看，暂不能继续」；J 发送禁用；候选试听按已下载沙盒文件可播（私有音频本地化，D7），未下载的显「离线不可试听」 |
| 未登录 | 不可进（01/08 已拦）；他端登出 → 本屏当帧终止流（D16 有界取消），落 17-S6 登录引导 sheet |
| 游客 | 同未登录 |
| Reduce Motion | 逐 token 打字效果 → **整段一次呈现**；像素呼吸 → 静止占位 + 「生成中」文字；进度条百分比仍更新（数据非动画）；卡片入场错峰淡入关闭；折叠展开 → 一帧撑开；音量 symbol 动画关闭（02 §5） |

### 4.2 SSE→轮询降级的四个触发条件（D6）在 UI 上的样子

降级后统一转 `GET /api/studio/one-step/plans?sessionId=` **每 5s** 轮询（不与 SSE 并发），
B 条常驻；**本次降级不回切 SSE**，下一次用户发送时重开 SSE（避免双通道并发的视觉不确定）。

| # | 触发（D6） | B 条文案 | 图标节奏 | 消息区附加表现 | 用户可做的动作 |
|---|---|---|---|---|---|
| 1 | 10s 无首事件（连上了但一个事件都没来） | 「连接较慢，正在等待 Cova 回应」 | 慢旋（Reduce Motion 下静止） | J 发送钮保持禁用，composer 上方出现一条 `type.caption`/`color.muted`「仍在处理刚才那句」；**不**显示计划卡骨架（尚无 plan 可锚） | 「停止」→ 终止本轮、恢复 J |
| 2 | 30s 静默（已收到事件后静默） | 「连接中断，已切为自动刷新」 | 慢旋 | 最后一段 agent 文本尾部**停止追加**（不出现半句话的光标闪烁）；thinking 折叠块收起态定格并追加「（已停止更新）」`color.muted`；已到达的计划卡**保持可交互**（卡状态以 plans 轮询为准） | 可继续在卡上操作；「停止」 |
| 3 | 3 个坏事件（`data:` 载荷非合法 JSON 累计 3 次） | 「连接不稳定，已切为自动刷新」 | 慢旋 + 一次性 warning 闪 | 与 #2 相同；**绝不**把「坏事件/JSON/schema」等技术词透出；E 块内保留已收到的合法 thinking 条目 | 同 #2 |
| 4 | `done` 前 EOF（流被截断） | 「本轮回复未结束，正在继续获取」 | 慢旋 | 若此时**无**计划卡：消息尾部显一条 `type.caption`/`color.muted`「正在从服务器补全这一步」；若**有**计划卡：卡片状态以 plans 轮询返回值覆盖本地最后已知状态（服务端为事实源） | 同 #2 |

- 四条共用一条 UI 容器，差异仅在文案与是否出现「composer 上方等待行」——**验收点**：
  任何一条触发都不得出现两个并发告警或红色 error 态（降级是恢复手段，不是错误）
- 轮询本身连续失败：前 3 次静默（B 条文案不变），第 4 次起 B 条文案换
  「自动刷新也拿不到，检查网络后点重试」并在条尾出现「重试」文字钮（`color.accentText`）；
  上限/退避策略未定（TD-32）→ 见「待裁决 3」

## 5. 双 Demo 终态硬规则的视觉表达（D7）

**规则**：一步模式只取**前两个**候选；两个都 settled（`audioDownloadStatus` = ready 且有 URL，
或 failed）才算**终态**。UI 必须把「单卡就绪」与「本轮终态」区分开。

| 两候选状态 | 终态条文案（`type.subhead`） | 终态条色 | 卡面 | 组内可做的动作 |
|---|---|---|---|---|
| pending + pending | 「两个版本制作中」 | `color.muted` | 两张均为像素呼吸占位 + 生成中徽标（`color.warning`） | 仅试听不可用；收藏/下载禁用（无 `mediaReferenceId` 时整钮不渲染） |
| ready + pending | 「就绪 1/2 · 等另一个版本完成」 | `color.warning` | 已就绪卡显封面+播放钮+时长；另一张仍占位 | **试听已就绪卡可用**（先 Bearer 下载到沙盒校验非空再 `file://`，D7）；收藏可用；「选这版继续制作」**禁用**并带说明（点击 → Toast「两个版本都完成后可以继续」） |
| failed + pending | 「1/2 遇到问题 · 等另一个版本完成」 | `color.warning` | 失败卡 error 遮罩 + 「重试」（components §5） | 同上前两行叠加 |
| ready + ready（**终态**） | 「两个版本都好了，挑一版继续」 | `color.success` | 两卡均就绪 | 试听/收藏/分享全开；出现「选一版继续制作」主钮（选一 → 后续补充制作，§4.1-I）；下载入口仍按 D12 隐藏 |
| ready + failed（**终态**） | 「一版完成，另一版失败」 | `color.warning` | 就绪卡可交互；失败卡 error 遮罩 + 「重试」 | 「选一版继续制作」可用（唯一可选）；重试该候选需后端支持（未见端点 → 重试钮走 `plans/start` 重开一轮，登记「待裁决 4」） |
| failed + failed（**终态**） | 「两个版本都没能完成」 | `color.error` | 两张失败卡 + 各自「重试」 | 引导「换一句话再来一次」（聚焦 J）；**不显示**任何扣费/退款话术（D12 只展示余额，退款口径后端未文档化） |
| 候选数 >2（后端返回 3+） | 同上按前 2 条判定 | — | **只渲染前 2**（硬规则） | 多余候选不出现在本屏任何列表/收藏入口 |

- 三张以上候选、无 `mediaReferenceId` 的候选、`title` 为空的候选 → 分别按「只取前二」/
  「收藏钮不渲染」/「标题回落 `版本 1`、`版本 2`」处理
- 归属：候选卡与计划卡同属一轮（`jobId` 关联），同轮多卡并存时按 `createdAt` 升序排列（09 详情
  `generationJobs` 已 reverse 为正序，与 web 一致）

## 6. 深浅双主题差异

- 消息流底 `color.canvas`；agent 文本 `color.fg`（Dark 下为 token 给出的暖白值，本文件不写值）
- 用户气泡 `color.accentSoft`：Light 浅橙衬底 / Dark 深橙衬底——同一 token 双值，
  **不得**在 Dark 下自造半透明橙
- 计划卡与候选卡组 `color.elevated`（Dark 下抬升一档）+ 1pt `color.line`
- 状态徽标语义色（success/warning/error）双主题同值，muted/secondary 双值
- `gradient.ai` 装饰条与 `gradient.brandButton` 双主题共用；Dark 下 B 条 warning 描边在同色
  `color.warning` 上仍可读（衬底切 `color.accentSoft` Dark 深橙，对比由 `color.fg` 保证）
- 播放中的音量 symbol、玻璃播放钮：`material.glass` 系统自适应；阴影切
  `elevation.glassButtonShadowLight` / `…Dark`

## 7. 可访问性

- **朗读顺序（自上而下，动态跟随流）**：A 返回 → 标题 →（有 B 条时）「连接状态，<文案>」→
  每条消息一个**容器元素**：
  - 用户：「你，<文本>」
  - agent：「Cova，<文本>」
  - thinking：「深度思考，N 步，已收起，按钮」→ 展开后逐条「第 N 步，<短语>」
  - 运行状态行：「运行状态，<短语>」（**不**播报事件名 `run_started` 等技术串）
  - 计划卡：「制作计划，状态 <中文态>，标题候选 <选中项>，可用候选 <n> 项，风格分析 <可展开>，
    歌词 <N> 段，参数 <逐条>，预计消耗 <N> co，余额 <M>，开始制作 按钮 <已禁用时：禁用，原因 …>」
  - 候选卡组：「两个版本，<终态条文案>」→ 每卡「版本 N，<标题>，<时长>，<状态>，试听 按钮，
    收藏 按钮，分享 按钮」
  - 交付进度：「补充制作中，<百分比>」（值变化时**不**逐帧播报，仅在元素被聚焦时读当前值）
- 新消息到达**不打断**当前朗读（无 `aria-live` 式强插）：改用一次性「1 条新回复 ⌄」浮动钮
  （`color.elevated` 底 + `color.accentText` 字，≥44pt），点按滚动到最新——避免 VoiceOver 被流打断
- **Dynamic Type**：AX 档下——气泡最大宽 78% → 100% − 2×`spacing.pageGutter`；候选卡组由横排
  50%+50% 改为**纵向堆叠两卡**（终态条移到卡组底部，仍在同一容器）；计划卡参数 chips 换行、
  费用行与操作行上下堆叠；B 条允许 2 行；进度条与状态行保持同宽
- **触控目标 ≥44pt**：⋯ / 每条 thinking 折叠行 / 每个候选标题 chip / 歌词节标题 /
  promptEn 展开 / 「开始制作」/「修改要求」/「重试」/ 每卡播放钮（40 视觉 + 扩展热区至 44）/
  ♡ / ↓ / ⤴ / 停止生成 / 降级条「重试」/ 新回复浮动钮 / J 的模式 chips 与发送钮

## 8. 数据契约

| 用途 | 端点 | 消费字段 |
|---|---|---|
| 历史与对账 | `GET /api/find-my-song/sessions/:id` | `messages[]`（角色 + 文本 + 客户端消息 id）、`generationJobs[]`（§下） |
| 流式 | `POST /api/studio/agent`（SSE） | 事件：`thinking{text}` / `text{text}` / `plan_card{卡投影}` / `error{text}` / `done{}` / `run_*` |
| 降级轮询 | `GET /api/studio/one-step/plans?sessionId=` → `{planCards[]}` | `OneStepPlanCardDto` 全字段（§9 表） |
| 启动制作 | `POST /api/studio/one-step/plans/start` `{sessionId,planCardId,revision,snapshotHash,idempotencyKey}` | 写操作，幂等键必带（D8） |
| 生成任务 | `GET /api/find-my-song/generation-jobs?id=` | 节奏：前 6 次 5s、之后 10s、上限约 30 分钟（api-contracts §4） |
| 候选收藏 | `PATCH /api/media/references/:id/retention` `{favorite}` | `mediaReferenceId` 缺失时不渲染 ♡ |
| 余额 | `GET /api/auth/me` → `entitlements.creditsBalance` | 卡内费用行；启动成功后强制刷新 |

- **`clientMessageId` 归属校验**：发送时本地生成、与 `messages[]` 回读对齐；计划卡
  `sourceMessage.messageId !== clientMessageId` → 未解锁态（components §4 置灰 + warning 条）。
  **不得**在没有匹配时放开「开始制作」（M2 验收硬口径）
- **`snapshotHash` 必用**：`start` 请求需带卡当前 `snapshotHash` 与 `revision`；
  响应若指示卡已变（版本/hash 不符）→ 重新拉 plans 并刷新卡，不自动重放写请求（幂等键复用同键，
  TD-19 口径由实现层保证）
- **GenerationJob 6 态**（`queued/submitted/processing/succeeded/failed/cancelled`）
  → 只驱动 I 进度条与 H 终态条，**不**在界面上出现英文态名
- **GenerationCandidate 字段**：`id / title / audioUrl / audioDownloadUrl / audioDownloadStatus /
  mediaReferenceId / favorite`（+ `coverUrl / duration`）。
  `audioUrl` / `audioDownloadUrl` 为授权地址（CovaCore 收口 `SecretString`）→
  **不显示、不写日志、不入持久化索引**（AGENTS 硬边界 3 / D7 / TD-23）
- **私有音频试听（D7）**：先 Bearer 完整下载到沙盒 → 校验非空 → `file://` 播放；
  下载中该卡播放钮为菊花态（02 §9 缓冲语义），校验失败 → 该行内错误「试听文件没取到，重试」
- **NEEDS 关联（逐项显式）**：
  - **NEEDS-13 未解锁**：agent 请求体与各事件载荷 schema 未文档化 → UI 采用降级：
    ① 载荷按 `{text}` / 卡投影推断；②「坏事件」按 `data:` 非合法 JSON 判定（§4.2 第 3 行的口径来源）；
    ③ 未知事件名（含 `run_*`）静默容忍，不报错、不显技术文案
  - **NEEDS-3 未解锁**：`entitlements` 缺 → 费用行的「余额 M」不渲染（**不显 0**），
    「开始制作」不因余额未知而禁用（余额不足由后端在 start 时拒绝 → §8 零余额话术）
  - **NEEDS-1 未解锁**：`user.covaId` 缺与本屏无关；但 `me` 拉不到时余额位同上
  - **NEEDS-7 未就绪**：远程推送缺 → 生成完成走本地通知兜底（`18-local-notification.md`），
    本屏**不**承诺退后台后仍能收到推送；回本屏时按 plans/jobs 对账
  - **NEEDS-6 未解锁**：下载文件不支持 Range → 本屏下载入口本身受 D12 隐藏；放行后若需断点续传仍受限
- **字段可空规则**：`summary` 空 → 不渲染概要行；`title.candidates` 空 → 只显 `selected`（无 chips）；
  `style/promptEn` 空 → 折叠行不渲染；`lyrics` 空 → 「歌词」节不渲染（不显「无歌词」，纯音乐由
  `type` 决定并显「纯音乐」参数 chip）；`credits` 空 → 费用行整行不渲染
- **刷新策略**：进入本屏 = 一次 `GET sessions/:id` + 一次 `plans`（不轮询，除非有未终态 job）；
  有未终态 job 时按 §4.2 与 jobs 节奏继续；下拉刷新 = 重取 `sessions/:id` + `plans`，
  **不**重开 SSE

## 9. 计划卡 12 态 × UI 映射（TD-31）

契约枚举（api-contracts §4「status（12 态）」= `OneStepPlanStatus`，与 CovaCore 建模逐字一致）：

| # | `status` | 中文态（本屏定名） | 徽标色 | 「开始制作」 | 「修改要求」 | 卡体附加表现 |
|---|---|---|---|---|---|---|
| 1 | `analyzing` | 草拟中 | `color.muted` | 禁用 | 可用 | 内容区骨架（标题/分析/歌词位）、无费用行 |
| 2 | `ready` | 待确认 | `color.warning` | **可用**（需归属校验通过 + `snapshotHash` 存在） | 可用 | 费用行完整、参数 chips 完整 |
| 3 | `patching` | 修改中 | `color.muted` | 禁用 | 禁用 | 卡体保持旧内容 + 顶部一条 `type.caption`/`color.muted`「正在按你的批注修改」 |
| 4 | `starting` | 已启动 | `color.warning` | 禁用（防重扣，D8） | 禁用 | 主钮位显示菊花 + 「已提交，正在排产」 |
| 5 | `generating` | 生成中 | `color.warning` | 禁用 | 禁用 | 候选卡组出现并按 §5 规则推进 |
| 6 | `media_staging` | 音频落位中 | `color.warning` | 禁用 | 禁用 | 候选卡若已 ready 仍可试听（D7 就绪即可播） |
| 7 | `demos_ready` | Demo 就绪 | `color.success` | 禁用（本轮已产出） | 可用 | 终态条按 §5；「选一版继续制作」为主动作 |
| 8 | `delivery_preparing` | 补充制作中 | `color.warning` | 禁用 | 禁用 | I 进度条出现 |
| 9 | `rehydrating` | 文件恢复中 | `color.warning` | 禁用 | 禁用 | I 条文案「正在恢复完整音频」；试听回落 preview |
| 10 | `manual_recovery` | 需人工处理 | `color.error` | 禁用 | 禁用 | 顶部 error 条「这一步暂时卡住了，可以重新描述需求再来一次」+ 聚焦 J 的引导钮；**不**出现「联系客服」类话术（v1.0 无客服端点） |
| 11 | `retryable_failure` | 未完成，可重试 | `color.error` | 文案改「重新制作」并可用（幂等键**换新**，属新一轮写） | 可用 | `job.errorMessage` 若为余额/额度类 → 按 §8 零余额话术；否则显中性「这次没做成」 |
| 12 | `archived` | 已归档 | `color.muted` | 禁用 | 禁用 | 卡体 `color.surface` 底 + 50% 透明（非置灰图片），徽标「已归档」；历史仍可浏览、候选仍可试听 |

- **与 `../components.md` §4 的 12 个中文名不重合** → 裁决：以契约枚举为准（上表）。
  components 的「部分失败/已取消/过期/参数错误/余额不足」不是状态枚举值，降级为**表现层语义**：
  「部分失败」= 候选一 ready 一 failed（§5 终态条）；「已取消」= `GenerationJobStatus.cancelled`
  （I 条文案「本轮已停止」）；「过期」= `archived`；「参数错误」= 归属校验未通过（置灰 + warning 条）；
  「余额不足」= start 被拒/`retryable_failure` + 余额类 errorMessage。见「待裁决 1」
- **未知枚举值**（后端新增态）：TD-12 口径——当前 DTO 为封闭枚举，会整包解码失败。
  UI 侧要求：M2 实现需以「未知态 → 卡体只读 + 徽标 `color.muted`『状态更新中』」承接，
  **需实现层配合放宽解码**（登记「待裁决 2」，不得在规格里假装已解决）

## 10. 边界与文案

- **截断**：标题候选选中项 2 行、候选 chip 单行（>10 字 → 10 字 + `…`）；候选卡标题 2 行；
  agent 文本不限行（可滚）；`analysisZh` 收起 4 行 + 「展开」
- **零余额（D12）**：
  - 「开始制作」前**不**做本地余额预判拦截（`creditsBalance` 可能因 NEEDS-3 不可得，误拦更糟）
  - 后端拒绝（余额/额度）→ **行内**：卡内费用行整行转 `color.error` + 文案
    「这次没有扣费，余额不足以开始制作」；主钮回落可点（若 `retryable_failure` 则同态 11）
  - **禁止**出现「去充值 / 购买 / 补余额 / 价格对比」等任何话术与入口（D12、AGENTS 硬边界 9）；
    13 会员页只作为「了解套餐」的静态展示 + 外跳，不在本屏错误路径里出现
- **长任务**：`generation-jobs` 上限约 30 分钟 → 到时仍非终态：B 位（复用同一条容器）显
  「这次制作时间超出预期，可以先离开，做好会在通知里找你」，本地按 18 兜底调度；
  **不**出现倒计时焦虑设计
- **并发冲突**：
  - 流式中发送 → J 发送禁用 + 「停止生成」文字钮（终止本地任务遵循 D16 有界语义：
    不再调度新周期、在途传输立即取消且结果不投递）
  - 同轮两卡并发点「开始制作」（多张 `ready` 卡）→ 全局只允许一个在途 start 请求，
    后到者按钮 loading 且被吞（幂等键不同卡各自独立）
  - 候选 ♡ 与「选一版继续」互不阻塞；同一候选连点 ♡ 吞后发
  - 两设备同会话：本屏进入即对账 plans，若 `revision` 已前进 → 显示「计划已在别处更新」
    一次性 `type.caption`/`color.muted`，并把卡刷到最新；不出现「冲突解决」对话框
- **极值**：单会话消息 >200 条 → 分组窗口化（仅保留最近 100 条 + 「加载更早消息」文字钮，
  分页参数未文档化 → 由本地已取集合承接，不发明 `?before=`）；计划卡 >5 张 → 全部保留（历史事实），
  最新一张默认展开、其余收起为「计划卡摘要行」（标题 + 状态徽标）
- **文案清单（固定，禁改）**：`草拟中` `待确认` `修改中` `已启动` `生成中` `音频落位中` `Demo 就绪`
  `补充制作中` `文件恢复中` `需人工处理` `未完成，可重试` `已归档` / `开始制作` `重新制作` `修改要求`
  `选一版继续制作` `两个版本制作中` `就绪 1/2 · 等另一个版本完成` `一版完成，另一版失败`
  `两个版本都没能完成` `连接较慢，正在等待 Cova 回应` `连接中断，已切为自动刷新`
  `连接不稳定，已切为自动刷新` `本轮回复未结束，正在继续获取` `自动刷新也拿不到，检查网络后点重试`
  `仍在处理刚才那句` `停止生成` `这次没有扣费，余额不足以开始制作` `1 条新回复`

## 11. 验收判据

- [ ] **12 态全覆盖**：逐一构造/回放（本地契约 mock，不入验收数据）验证上表每一行的
      徽标色、两钮可用性、卡体附加表现三条全对
- [ ] **降级四触发各有独立表现**：网络条件下分别命中 10s 无首事件 / 30s 静默 / 3 坏事件 / done 前 EOF，
      B 条文案一一对应；任一触发下**无**并发 SSE + 轮询（网络面板仅一条通道），且无红色 error 态
- [ ] **D7 终态硬规则**：`ready + pending` 时「选一版继续制作」禁用且给出理由文案；
      两候选都 settled 后才出现终态；后端回 3 候选时界面只见 2
- [ ] 私有音频试听：抓包确认先完整下载（Bearer）→ 校验非空 → `file://`；UI/日志/持久化中
      搜不到 `audioUrl`/`audioDownloadUrl` 明文
- [ ] `run_*`：`run_waiting_user` 停下不旋转且提示需用户动作；未知 `run_*` 不显示且**不**触发降级；
      运行状态行任何时刻至多一条
- [ ] 归属校验不通过 → 卡体置灰 + warning 条 + 主钮禁用（无法通过任何 UI 路径绕过）
- [ ] 余额不足路径不出现充值/购买话术或入口（D12 合规扫描）
- [ ] Reduce Motion：打字效果、像素呼吸、symbol 脉冲全为静态替代，信息不丢失
- [ ] AX5 档：候选卡组纵向堆叠、B 条 2 行、无横向溢出；VoiceOver 下新消息不打断朗读
- [ ] 全部尺寸/色值/时长为 token 引用；tokens 缺失项均出现在「Token 缺口」而非散落字面量

## Token 缺口

| # | 缺口 | 本屏用法 |
|---|---|---|
| TG-01 | 分栏/最大宽比例档 | 用户气泡 78% 最大宽 |
| TG-03 | 最小触控目标 | 全部文字钮 / 折叠行 / 卡上操作 |
| TG-04 | 描边宽度档 | 2pt AI 装饰条、1pt 卡边、进度线宽 |
| TG-07 | 按钮高度档 | 主钮 50、chip 36 |
| TG-18 | 图标/小尺寸档 | agent 标识 24、运行状态符号 12 |
| TG-21 | 无 `warningSoft` / `errorSoft` 衬底 | B 条、error 行内底 |
| TG-22 | 玻璃浮动钮尺寸档 | 卡上播放钮 40 |
| TG-23 | 细进度条高厚档 | I 条 4 |
| TG-24 | 骨架「轮廓卡」规格（整卡轮廓呼吸） | 首载计划卡轮廓 |
| TG-25 | 消息流间距/锚底滚动语义档 | 新消息插入时的滚动行为 |
| TG-26 | 置灰/只读的不透明度档（50%） | 归档卡、归属未通过卡 |

## 待裁决

1. **计划卡 12 态中文名单不一致（TD-31 核心）**：`../components.md` §4 的 12 个中文名
   （草拟/待确认/已确认/已启动/生成中/部分失败/完成/已取消/失败/过期/参数错误/余额不足）与契约枚举
   （`OneStepPlanStatus` 12 值）**不同源**。本屏以契约枚举为准并把前者降级为表现层语义（§9 末注）。
   需 G2 验收时二选一并回写 `components.md`（本任务红线不改该文件）。
2. **`run_*` 展示与解码前向兼容（TD-31 另一半）**：§3.F 映射表 + 只读渲染要求「未知态/未知事件不炸」。
   未知事件名可静默忽略；**未知 `plan.status` 枚举值**需实现层放宽解码（TD-12）→ 请协调者裁决：
   M2 是否给 `OneStepPlanStatus` 增 `unknown` 兜底（属 CovaCore 契约建模变更，需登记 decisions/NEEDS）。
3. **降级后是否回切 SSE（D6 未言）** + 轮询失败上限/退避（TD-32）：本屏钉「本次不回切、下次发送重开」，
   连续失败 4 次后给用户手动「重试」。上限数值待 TD-32 一并裁决。
4. **失败候选的「重试」语义**：契约无「单候选重试」端点 → 本规格把重试解释为「重新发起一轮制作」
   （新幂等键、`plans/start` 或重新描述）。若产品要求「只补做失败那一版」，需后端补端点（NEEDS 候选）。
5. **thinking 公开短语白名单**：§3.E 要求过滤内部实现词，短语集需与 web `one-step` 公开进度文案对齐
   （仓内可参照 web 的公开文案口径）。**是否硬编码同集短语**待裁决。
6. **`GET sessions/:id` 的 `messages[]` 字段清单未文档化**（角色/文本/客户端消息 id 的具体键名）
   → 影响归属校验实现，建议随 `SESSION-LIST-FIELDS`（08 待裁决 1）一并补契约。
7. **30 分钟超时的本地通知兜底**与 18 的调度边界（是否允许多轮未终态时重复通知）见 18 §7。
