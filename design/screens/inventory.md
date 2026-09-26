# G2 全屏清单（约 19 屏）

> G1 详稿（01 首页 / 02 播放器 / 03 曲库）之外的全部屏幕要点。G2 阶段按此清单
> 逐屏出 Figma 稿并验收。共用规范（材质/字级/间距/动效）见 `../tokens.json` 与
> `../components.md`。
>
> **交付形态说明（本轮）**：Figma MCP 在本环境不可用 → G2 的可落地交付 =
> 本目录下的**逐屏规格文件**（「规格」列的链接），它是后续 Figma 搭建与 SwiftUI 实现的
> 唯一依据。04–19 已全数实例化；`01–03` 为 G1 已产出物，**未改动**（改动需验收）。

| # | 屏幕 | 要点 | 规格 |
|---|---|---|---|
| 01 | 首页 | 见 `01-home.md` | `01-home.md`（G1，已产出待验收） |
| 02 | 全屏播放器 | 见 `02-player.md` | `02-player.md`（G1，已产出待验收） |
| 03 | 曲库 | 见 `03-library.md` | `03-library.md`（G1，已产出待验收） |
| 04 | **左侧抽屉** | 玻璃材质，宽 78% 屏宽。分区：主导航（首页/曲库/歌单/创作——创作项 AI 渐变文字）/ 我的资产（收藏/歌单/创作/已下载）/ 商业（会员·金色调、企业服务·蓝色调，跳网页）/ 底部我的卡片（头像+名字+余额胶囊+设置齿轮）。手势：左缘右滑/点 logo 打开；点遮罩或左滑关闭 | `04-drawer.md` |
| 05 | **歌单广场** | 官方歌单网格双列（封面 16:10 + 标题 + 曲数），顶部分类 chips（按 scene）；下拉刷新 | `05-playlists-plaza.md` |
| 06 | **歌单详情** | 大封面头图（fit/focal 焦点）+ 标题/策展人/简介 + 「播放全部」渐变胶囊 + 收藏 ♡ + TrackRow 列表；头图上滑折叠进导航条 | `06-playlist-detail.md` |
| 07 | **曲目详情** | modal 半屏：大封面、标签流、歌词摘要、相似曲目横滑、操作行（收藏/下载/分享） | `07-track-detail.md` |
| 08 | **创作：会话列表** | 左滑删除；每行：会话标题、最后消息摘要、时间、进行中的生成任务带进度环；顶部「新会话」渐变胶囊；空态 = 引导语 + prompt starters | `08-ai-sessions.md` |
| 09 | **创作：会话详情** | DeepSeek 式对话流：用户气泡（accentSoft 底右对齐）/ agent 文本（无气泡左对齐）/ thinking 折叠块（「深度思考」展开逐条，muted 字）/ 计划卡（组件 §4）/ 双 Demo 候选卡（组件 §5）/ 补充制作进度条。底部输入框同首页会话卡。SSE 断线时顶部细条提示「连接中断，轮询中」 | `09-ai-session-detail.md` |
| 10 | **登录** | logo 64pt + 邮箱/密码输入（胶囊 50pt，focus accent 描边）+ 登录渐变主钮 + 「游客浏览」文字钮 + 隐私/条款链接。登录中按钮转菊花；错误行内提示（error 色） | `10-login.md` |
| 11 | **我的** | 用户卡（头像/名字/covaId）+ 余额与套餐卡（co 余额大字 tabular-nums + 套餐徽标；**无充值按钮，D12**）+ 资产入口列表（收藏/歌单/创作/下载）+ 设置入口 | `11-mine.md` |
| 12 | **我的收藏 / 我的歌单 / 我的创作 / 已下载** | 四屏同构列表页：TrackRow 或 PlaylistCard 列表 + 空态引导。「已下载」含空间占用统计与 Wi-Fi 仅下载开关（D12 放行后可见） | `12a-favorites.md`（**同构基线**）/ `12b-my-playlists.md` / `12c-my-creations.md` / `12d-downloads.md` |
| 13 | **会员** | 权益对比表（免费/创作/专业/企业），金属金色调；**仅展示与跳网页**（「前往官网了解」Safari），无购买 | `13-membership.md` |
| 14 | **企业服务** | 简介 + 案例 + 「联系 enterprise@covalink.cn」跳网页/邮件 | `14-enterprise.md` |
| 15 | **设置** | 主题（跟随系统/浅/深）、音频质量、清除缓存（显示占用）、通知开关、隐私/条款/版权说明外链、关于（版本号）、登出（红色，二次确认） | `15-settings.md`（「音频质量」被裁决移除，见其 §待裁决 5） |
| 16 | **AI 音乐人主页** | 头像大图 + 人设简介 + 曲目列表（artistId 筛选） | `16-ai-artist-home.md` |
| 17 | **空态/加载/错误组件页** | 设计规范页：每类状态的标准样式（空态插画+引导语+CTA；骨架屏；错误+重试） | `17-state-gallery.md`（**通用状态唯一源**，编号 S1–S9） |
| 18 | **本地通知样式** | 生成完成通知：标题「你的歌做好了」+ 双候选名，点击深链回会话详情 | `18-local-notification.md` |
| 19 | **创作台（一句话做歌）** | `POST /api/studio/create/generate` 的最小闭环：prompt 表单 → 幂等键提交 → 任务轮询（不确定条 + 计时，**无百分比**）→ 双作品行（▶ 试听带伪 trackId 上报 / ↓ 本机直存不扣费）。P0 只施工 `mode:'simple'`+`operation:'create'`；D12：不报价、无充值入口 | `19-studio-create.md`（2026-09-26 P0 新增） |

## 通用要求

- 每屏交付出**浅色 + 深色**两版（token mode 切换），标注 Reduce Motion 替代态
  → **本轮落地口径**：无 Figma 时「两版」= 各屏 §深浅双主题差异 小节逐条声明该屏所有差异
    均可由 `../tokens.json` 的 `color.*` light/dark 双值与 `material.*` 双值解决；
    Reduce Motion 由 **唯一源** `17-state-gallery.md` §S5 退化矩阵承接，各屏只列命中项。
    有 Figma MCP 后按本口径出双版画板。**待 G1/G2 验收确认**
- 所有列表/feed 页标注骨架态；所有网络页标注错误态
  → 具体形态（含行数与形状）**不在各屏自定义**，一律引用 `17-state-gallery.md` 的 S1（骨架）
    与 S3（错误四形态 + 判定表）；各屏 §状态变体只写实例与差异
- 触控目标 ≥44pt；文字最长截断规则逐屏标注（中文优先 2 行截断）
  → 已逐屏「可访问性」小节逐一列名确认；44pt 与「文本行数上限」目前是 **token 缺口**
    （TG-03 / TG-17），未入库前按 `inventory` 钉死值施工，见 `17-state-gallery.md` §12 汇总
- 动效标注：曲线取 `motion.curve`，时长取 `motion.duration` 档位
  → 实际键名为 `motion.duration.{instant,fast,normal,slow,page,hero}`（单位 ms，
    `tokens.json` 的 `motion.duration.$type = "ms"`）；骨架呼吸 1.2s 与 Toast 3s 只存在于
    `../components.md` §8，tokens 无对应档 → 缺口 TG-41
- **（新增）不得发明后端字段/端点**：每屏「数据契约」小节只允许引用 `docs/api-contracts.md`
  已记录的端点与字段；契约未记录的一律写「未文档化 → 降级形态」并进该屏「待裁决」。
  本轮据此产生的 NEEDS 候选清单（**本任务红线不改 `docs/NEEDS.md`，由协调者登记**）：
  `SESSION-LIST-FIELDS`（08/09/12c）、`FAVORITES-NOTE-ITEMS`（NEEDS-11 已存在，12a 消费）、
  `FAVORITES-BATCH`（12a）、`CREATIONS-SUMMARY`（12c）、`DOWNLOADS-LIST`（12d）、
  `ARTIST-PROFILE`（16）、`DRAWER-ASSET-COUNTS`（04/11）
- **（新增）Token 缺口登记制**：各屏文末「Token 缺口」只登记该屏命中项，
  全集与消费屏映射汇总在 `17-state-gallery.md` §12（TG-01…TG-43）。
  **任何人不得为了消缺口而直接改 `../tokens.json`** —— 须 G2 验收裁决后由设计侧统一回写
- **（新增）屏幕归属澄清**：`inventory` 行 05 是**歌单广场**；「播放器下载入口」属
  `02-player.md` §5（G1 已产出物，未改）。D12 下载入口的**隐藏规则**统一钉在
  `12d-downloads.md` §1（三门判定）与 `07-track-detail.md` §3.F，其他屏引用之
- **（新增）与 `../components.md` 的已知冲突（本目录已作裁决，待验收确认）**：
  | 冲突 | 本目录裁决 | 出处 |
  |---|---|---|
  | PlaylistCard 小卡 140×140 方形 vs 广场双列 16:10 | 广场双列 16:10、首页横滑方形；组件需加 `ratio` 变体 | `05-playlists-plaza.md` 待裁决 1 |
  | 计划卡「12 态」中文名单（components §4）≠ 契约枚举 `OneStepPlanStatus` 12 值 | 以契约枚举为准；components 名单降为表现层语义 | `09-ai-session-detail.md` §9 |
  | 歌单收藏符号 ♡（本表行 06）vs `saveAction.kind = "bookmark"` | 歌单用书签、爱心专属曲目 | `06-playlist-detail.md` 待裁决 1 |
  | 设置「音频质量」（本表行 15）无契约支撑（`audioUrl` 单一，无码率参数） | 移除该项，由「只连 Wi‑Fi 下载」承担省流诉求 | `15-settings.md` 待裁决 5 |
