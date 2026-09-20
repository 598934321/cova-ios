# 16 · AI 音乐人主页（人设 + 曲目）

> G2 逐屏规格。基准 393×852pt。要点源：`inventory.md` 行 16。
> 数据源：`GET /api/tracks?artistId=<id>`（api-contracts §2，普通列表投影 `TrackPageDto`）；
> 人设字段来自响应内嵌的 `tracks[].artist`（`ArtistDto`）。
> 列表骨架基线：`12a-favorites.md` §2–§6；曲目行：`../components.md` §1。

## 1. 屏与上下文

- **层级**：push 自 01/03/07；入导航栈。
- **入口**：① 01 §6「AI 音乐人」头像横滑（**注意**：01 §6 现钉的落点是「曲库预填 artistId」，
  本屏施工后应改为进本屏 → 01 属 G1 已产出物，本任务不改，**见待裁决 1**）；
  ② 03 TrackRow 艺人名 / ⋯ 菜单「查看艺人」；③ 07 艺人行；④ 深链 `artists/:id`。
- **互链**：曲目行 → 播放（02 + MiniPlayer）/ ♡ 收藏 / ⋯ → 07；空态 CTA → 03 曲库；
  「在曲库里浏览全部」→ 03 预填 `artistId` 筛选（保留 01 §6 的旧路径作为二级出口）。
- **返回**：退栈回来源；从深链进入关闭后落 01。
- **登录门槛**：无。艺人页与曲目均为公开内容；仅 ♡ / 队列需登录（17-S6）。

## 2. 布局（393×852）

```
┌─────────────────────────────────────┐
│ [‹]                        [⋯ 分享] │  A 导航条（透明叠头图 → 玻璃）
│ ╭──────── 头区（人设）─────────────╮│
│ │  (大图头像)                        ││  B 头像（圆形，居中）
│ │  Cova A07                          ││  C 艺人名（largeTitle，居中）
│ │  Lo-Fi · 温柔克制                  ││  D 风格短语行
│ │  「深夜的窗边，我留一盏灯。」        ││  E 人设一句话（italic 感，不用 italic 字）
│ │  [ 播放全部 ]   [ ♥ 关注? 无端点 ] ││  F 主操作行
│ ╰───────────────────────────────────╯│
│ ── 曲目（12）──────────────────      │  G 分组标题 + 计数
│ TrackRow                             │  H 曲目列表（分页）
│ TrackRow                             │
│ … 「加载中…」/「已显示全部」           │  I 尾部状态行
│ ╭─ MiniPlayer ──────────────────╮   │
└─────────────────────────────────────┘
```

## 3. 区块规格

- **A 导航条**：初始透明（叠在 B 头区上，白字/白色符号），滚动越过阈值后淡入 `material.navGlass`
  + `color.fg`；⋯ → 分享（系统分享面板，链接 `covalink.cn/artists/:id`）；均 ≥44pt（TG-03）
- **头区容器（B–F）**：底为「艺人主色 → `color.canvas`」的柔和铺底
  （主色源 `artist.colorPalette`，字符串 → 解析规则见 §7；解析失败 → 回落 `color.surface`，
  **不**猜品牌橙）；下内边距 `spacing.xl`
- **B 头像**：圆形，直径 112（TG-05 头像档需新增一档）；源 `artist.avatar`（**契约有该字段**）；
  加载中 = `color.surface` 圆呼吸；失败/缺失 = 首字母占位（`color.accentText` / `color.surface`）
- **C 艺人名**：`artist.nameCn ?? artist.name`，`type.largeTitle` / `color.fg`，居中，2 行；
  编号（A01–A15）**不**单独成行，若后端名字里已含则照显，否则不拼（§7）
- **D 风格短语行**：`artist.styleCn ?? artist.style`（+ 可选 `coreInstruments`）·
  `type.subhead` / `color.secondary`，居中，1 行截断；两字段皆空 → 整行不渲染
- **E 人设一句话**：`artist.personality`，`type.callout` / `color.secondary`，居中，最多 3 行；
  空 → 不渲染（**不**用 `sceneResponsibility` / `stylePrompt` / `lyricsPrompt` 填充：
  那三个是**生成用提示词**，不是给用户看的文案，露出会泄漏内部 prompt → 硬性禁令）
- **F 主操作行**：「播放全部」主按钮（`gradient.brandButton`，高 50，TG-07，图标 `play.fill`，
  宽 = 屏宽 − 2×`spacing.xxl`）；**右侧不放「关注」**（无关注端点，见 §7）
- **G 分组标题**：`曲目（N）`，`type.caption` / `color.muted`，左右 `spacing.pageGutter`
  （`N` 取自 `TrackPageDto.total`；缺 → 只写「曲目」）
- **H 曲目列表**：TrackRow 原样（高 64 / 封面 48 / 圆角 TG-31）+ 行间 `color.lineSubtle` 1pt；
  行内第二行显示最多 3 个 `displayLabels` 标签胶囊（03 §4 同规则，`color.tagScene`/`color.tagMood`/
  `color.muted`），因为本屏信息焦点是「这个人的风格分布」

## 4. 状态变体

- **加载（首载）**：头区 = 112 圆呼吸 + 三条居中文本条（宽度 60%/40%/70%）；F 一枚胶囊骨架；
  H = 5 行 TrackRow 骨架；A 透明态保持（不骨架导航条）
- **空态**（两种，分别定义）：
  1. **`tracks` 为空但 `artist` 可得** → 头区照常（人设是这个屏的价值），列表区 17-S2：
     小插画位 + 「这位音乐人还没有公开曲目」+「先去曲库听听别的」+ CTA「去曲库」→ 03；
     F「播放全部」**禁用**（`color.muted` 底，components §10）
  2. **`tracks` 为空且无 `artist`**（`artistId` 不存在/无效）→ 整屏错误态形态：
     「找不到这位音乐人」+ 主钮「回首页」（**不**给「重试」，404 重试无意义）
- **错误**：首载失败（网络/5xx）→ 整屏错误态「音乐人页没取到」+「重试」；
  分页失败 → Toast + 行内重试；分享失败 → 系统面板自处理
- **离线**：有缓存（头区 + 已取曲目）→ 正常显示 + 17-S4 离线条；「播放全部」可点（队列本地可建，
  实际出声由播放层按 preview/缓存降级）；无缓存 → 整屏错误态「离线：需要联网查看」
- **未登录 / 游客**：整屏可读可试听（preview URL 匿名可取）；♡ 与加入队列 → 17-S6 登录引导
- **Reduce Motion**：头区铺底的色彩过渡退化为一帧；A 条玻璃淡入一帧到位；
  头像入场缩放关闭；列表错峰淡入关闭；TrackRow 播放中的音量 symbol 动画 → 静态符号

## 5. 深浅双主题差异

- 头区铺底：以 `artist.colorPalette` 解析色为主色，**Light 下 12% 不透明度叠 `color.canvas`、
  Dark 下 22% 叠 `color.canvas`**（透明度需 token 化，缺口 TG-40；两档不同是白/黑底上
  同一透明度观感不等价的必然结果）
- 文本 `color.fg/secondary/muted` 双值；A 条文字在透明态为白（靠铺底深色渐变保证对比，TG-12）
- 标签三色系双值（`tagScene/tagMuted`）
- 头像不加边框（两主题均由 `radius.capsule` 与铺底差值分离）

## 6. 可访问性

- **朗读顺序**：返回 → 分享 → 头像（「<艺人名> 的头像」，有 `alt` 时用；无则用艺人名生成）→
  艺人名（作为屏幕标题）→ D（「风格，Lo-Fi，温柔克制」）→ E（人设句）→
  「播放全部，按钮」→「曲目，12 首」→ 每行三元素（同 12a：主行 / ♡ / ⋯）→ 尾部状态行
- 铺底色**不**播报；`colorPalette` 解析失败**不**产生任何提示
- **Dynamic Type**：AX 档下头像 112 → 88（让位给文本），C 允许 2 行、E 允许 4 行、
  F 主钮单行不换行（宽度撑满），H 行文本各 2 行
- **触控目标 ≥44pt**：返回 / ⋯ 分享 / 播放全部 / 整行 / ♡ / ⋯ / CTA / 重试

## 7. 数据契约

| 用途 | 端点 | 字段 |
|---|---|---|
| 曲目列表 | `GET /api/tracks?artistId=<id>&page=<n>` → `TrackPageDto` | `tracks[]`（普通投影：`id/title/titleCn/cover/duration/artist/displayLabels/audioUrl/waveformPeaks/…`）、`total/page/pageSize/totalPages` |
| 人设 | **同响应的 `tracks[].artist`**（`ArtistDto`） | `id/name/nameCn/avatar/style/styleCn/personality/coreInstruments/colorPalette/country/countryFlag` |
| 试听 | `GET /api/tracks/:id/preview-url` | 播放层消费，URL 不外显 |
| 收藏 | `POST/DELETE /api/favorites` `{trackId}` | ♡ 乐观更新 |
| 分享 | 无端点 | 常量链接 `covalink.cn/artists/:id` |

- **人设来源的硬裁决（本屏最重要的一条）**：`docs/api-contracts.md` **无**
  `GET /api/artists` / `GET /api/artists/:id` 端点（只有 `tracks` 的 `artistId` 筛选与内嵌 `artist`）。
  因此：
  1. 人设 = **首条曲目的 `artist` 对象**；有曲目即有人设；
  2. `total > 0` 但首页曲目缺失（脏数据）→ 退化为「只显列表、不显头区」；
  3. **不得**为拿人设去发明 `/api/artists/:id`，也**不得**把 `ai音乐人/` 目录里的人设文档
     在运行时当数据源读（那是 IP 资料，不是 API；写进 App 会变成「假数据冒充线上行为」）；
  4. 需要独立人设端点 → NEEDS 候选 `ARTIST-PROFILE`（见待裁决 2）。
- **禁止使用的字段**：`artist.stylePrompt` / `artist.lyricsPrompt` / `artist.sceneResponsibility` /
  `style`（英文提示词向）→ **不展示**（生成提示词，非用户文案，§3.E 同源禁令）。
  `userId` 不展示。`country/countryFlag` v1.0 不展示（「中国/🇨🇳」的排版会引入 emoji 字体不确定，
  且非屏焦点）。
- **`colorPalette` 解析规则**：契约类型为 `String?`，格式未在契约中定义
  （可能是 `#RRGGBB`、逗号分隔、命名色）→ **实现要求**：仅接受 `#RGB/#RRGGBB` 形态，
  解析失败即回落 `color.surface`；**不得**尝试任意字符串当色值（会崩溃或出脏色）。
  该不确定性登记为「待裁决 3」，并在 §5 用透明度档位收敛风险。
- **分页**：`page` 参数契约有（api-contracts §2 `page`）→ 滚动到底加载下一页，`pageSize` 由后端定；
  `totalPages` 到达后显「已显示全部」；下拉刷新回到第 1 页
- **可空/异常规则**：`nameCn`→`name`；两者空 → 头区 C 行不渲染、屏幕标题回落「AI 音乐人」；
  `avatar` 空/加载失败 → 首字母占位；`total` 空 → G 标题只写「曲目」；
  某条曲目 `title*` 全空 → **该行不渲染**（同 12a 异常条目原则），但**不**因此调整 `total` 显示
- **NEEDS 关联**：本屏不依赖 NEEDS-1/3（公开内容）；NEEDS-10/#12 不适用（本屏不走 similar 投影）；
  NEEDS-8 不适用（不使用 variants）

## 8. 边界与文案

- **截断**：C 2 行、D 1 行、E 3 行（AX 4 行）、H 曲名/艺人按 components §1
- **零结果**：见 §4 空态 1/2
- **极值**：曲目 >1000 → 分页 + 分帧渲染；`displayLabels` >3 → 只取 3（03 同规则）；
  艺人名超长（>24 字）→ 2 行截断；人设句 >200 字 → 3 行截断（不出现「展开」，头区要克制）
- **并发冲突**：
  - ♡ 连点吞后发；「播放全部」与分页加载中同时发生 → 用已取到的曲目先建队列并 Toast
    「先播已加载的部分」（不做静默等待）
  - 同一艺人从 03/07 两路进入 → 复用栈上已有实例（不叠两个同 id 页）
  - 深链 `artists/:id` 与 03 的 `artistId` 筛选页并存时：03 是列表、本屏是人设页，
    两者不互相替换（保留各自返回栈）
- **D12**：无下载/购买入口（H 的 ⋯ 菜单里「下载」项放行前不渲染，同 07/12a）
- **文案清单**：`曲目` / `曲目（%d）` / `播放全部` / `这位音乐人还没有公开曲目` / `先去曲库听听别的` /
  `去曲库` / `找不到这位音乐人` / `回首页` / `音乐人页没取到` / `重试` / `离线：需要联网查看` /
  `先播已加载的部分` / `已显示全部` / `加载中…` / `分享`

## 9. 验收判据

- [ ] 人设仅由 `tracks[].artist` 得来；网络面板中**无** `/api/artists…` 类契约外请求
- [ ] `stylePrompt / lyricsPrompt / sceneResponsibility` 在屏幕上与 VoiceOver 树中均不出现（取证项）
- [ ] `colorPalette` 为非法/未知格式时头区回落 `color.surface`，无崩溃、无脏色
- [ ] `total > 0` 但曲目全为空时只显列表不显头区；`total = 0` 且有人设时走空态 1（头区在、播放钮禁用）
- [ ] 分页 `page` 递增不重复不跳页；到底出现「已显示全部」
- [ ] 游客可完整浏览与试听；♡ 走登录引导且取消后回到本屏原位
- [ ] 01 §6 的落点问题以「待裁决 1」在验收会上定案（若改 01 需 G1 偏离登记）
- [ ] 全部值 token 化（含头区透明度TG-40）

## Token 缺口

| # | 缺口 | 本屏用法 |
|---|---|---|
| TG-03 | 最小触控目标 | 返回 / ⋯ / 主钮 / 行 |
| TG-04 | 描边宽度档 | 行间 1pt |
| TG-05 | 头像尺寸档 | 112 / AX 88 |
| TG-07 | 按钮高度档 | 播放全部 50 |
| TG-12 | 遮罩/铺底强度（light/dark） | A 透明态白字对比 |
| TG-31 | TrackRow 封面圆角档 | H 区 |
| TG-40 | 主色铺底透明度档（Light/Dark 不同值） | 头区 |
| TG-17 | 文本行数上限档 | C/D/E |
| TG-30 | 分组标题 + 计数排版档 | G |

## 待裁决

1. **01 §6 的落点冲突**：01（G1 已产出）写「点击进音乐人曲目列表（曲库预填 artistId）」，
   `inventory.md` 行 16 又要求独立音乐人主页。两者并存 = 同一意图两条路径。
   **建议**：01 头像 → 本屏；本屏 F 右侧保留「在曲库浏览全部」二级出口。改 01 需 G1 偏离登记，
   **由协调者提交用户裁决**。
2. **独立人设端点 `ARTIST-PROFILE`**：当 `total = 0`（无曲目）时本屏头区完全依赖曲目内嵌 artist →
   新人设（0 曲）无法呈现。若 PRD 的 A01–A15 需要「未发曲也有人设」，必须补端点（NEEDS 候选）。
3. **`colorPalette` 格式**：契约未定义字符串格式 → 需后端给出口径（或改为数组/结构化）。
   在此之前 §5 的铺底按「解析失败即中性」施工，视觉上是**降级态**，G2 验收时应确认是否接受。
4. **是否提供「关注/粉丝」**：v1.0 无社交（PRD 4.4）→ 不做，头区右侧因此为空。
   若产品要「收藏音乐人」，属新端点 + 新屏语义。
