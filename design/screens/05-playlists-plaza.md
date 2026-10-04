# 05 · 歌单广场（官方歌单网格）

> G2 逐屏规格。基准 393×852pt。要点源：`inventory.md` 行 05。
> 数据源：`GET /api/playlists`（api-contracts §2）+ 分类词表 `GET /api/library/taxonomy`。
> 值一律 token 路径引用；缺口登记见文末「Token 缺口」（编号跨屏连续，汇总在 `17-state-gallery.md`）。

## 1. 屏与上下文

- **层级**：push 自 01（首页栈内），入「首页」页签栈（04 §3：原「抽屉歌单项 → 主内容屏」废除，
  歌单广场改由首页 feed 进入）。push 形态下底部有页签栏。
- **入口**：① 首页 01「推荐歌单 › 更多」与「场景精选 › 更多」；② 深链 `playlists`；
  ③ **01 搜索档目标=歌单的发送 / 搜索档歌单类标签点按**（`plazaSearch(q)` 路由，
  04 §3，2026-10-02 新增）。
- **返回**：左上系统返回「‹」退栈回 01；系统左缘右滑返回。
- **互链**：卡片 → 06 歌单详情；分类 chips 数据 ← taxonomy；MiniPlayer（01 §7）常驻悬浮。
- **`searchQuery` 入屏参数**（2026-10-02 新增）：携带时导航条下显示回显行
  「搜索：{query} ✕」（`color.surface` 底 + `color.fg` 字；✕ 清除条件），网格按
  `titleCn ?? title` 客户端过滤（纯本地过滤，不发新请求——本屏本来就是全量本地账，§7）；
  过滤为空 → 空态换「没有找到『{query}』相关的歌单」（插画位沿用 §4 空态规格，
  次级 CTA「清除搜索」= ✕ 同动作）。

## 2. 布局（393×852）

```
┌─────────────────────────────────────┐
│ [‹]  歌单                          │  A 导航条（玻璃 material.navGlass），左 = 系统返回
│ [咖啡馆][通勤][运动][专注][睡眠] →   │  B 分类 chips（横滑，按 scene）
│ ┌───────────┐  ┌───────────┐       │
│ │ 16:10 封面 │  │ 16:10 封面 │       │  C 双列网格（PlaylistCard 小卡）
│ │ 标题       │  │ 标题        │      │     + 标题 + 曲数·时长
│ │ 12 首 · 48 分│ │ 9 首 · 31 分│     │
│ └───────────┘  └───────────┘       │
│ ┌───────────┐  ┌───────────┐       │
│ │           │  │           │       │
│ └───────────┘  └───────────┘       │
│           「加载中…」 / 「已显示全部」 │  D 列表尾部状态行
│ ╭─ MiniPlayer ──────────────────╮  │
└─────────────────────────────────────┘
```

## 3. 区块规格

### A 导航条

- 材质 `material.navGlass`，z 序 `elevation.zOrder` nav 层；标题 `type.title`（28/700）/ `color.fg`，
  滚动时收敛为 `type.headline`（01/03 同规则）
- 左 = 系统返回「‹」（push 屏；不显示品牌位）。**不**放搜索钮：
  歌单搜索经 01 输入条的搜索档进入本屏（`searchQuery` 参数，§1）；曲目搜索在 25 页签。

### B 分类 chips

- chip 高 36（components §10，TG-07）、圆角 `radius.capsule`、水平内边距 `spacing.lg`、
  间距 `spacing.sm`；整行左起 `spacing.pageGutter`、右缘渐隐、隐藏滚动条
- 首项恒为「全部」（默认选中）；其后按 `taxonomy.scene` 顺序，仅保留**在本屏列表中至少命中
  1 个歌单**的 scene（不出现点了必为空的分类）
- 选中：`color.selectedBg` 底 + `color.selected` 字 + 1pt `color.line` 描边（TG-04；
  web v2.65.0 去橙化选中档，design/README「与 web 的统一设计语言」）；
  未选：`color.surface` 底 + `color.secondary` 字
- chips 行与网格间距 `spacing.lg`；吸顶（滚动时粘在导航条下沿，玻璃底）

### C 双列网格卡（本屏主内容）

- 列数 2；列间距 `spacing.md`；行间距 `spacing.lg`；左右 `spacing.pageGutter`
- 卡宽 = (屏宽 − 2×`spacing.pageGutter` − `spacing.md`) / 2；封面 **16:10**（inventory 钉死；
  与 `../components.md` §2 小卡 140×140 方形冲突 → 裁决见「待裁决 1」）
- 封面：圆角 `radius.card`，按 `playlist.coverMedia.fit / focalX / focalY` 裁剪，
  缺 `coverMedia` 时回落 `playlist.cover` / `coverUrl`；均缺 → 占位（`color.surface` + 音符符号 `color.muted`）
- 标题条（封面上方独立文本区，非叠字）：`playlist.titleCn ?? title`，`type.headline` / `color.fg`，2 行
- 元信息：`trackCount` 曲数 + `totalDuration` 折算分钟，`type.caption` / `color.muted`，`type.mono` 数字
- 收藏角标：`playlist.isSaved == true` 时封面右上书签符号（`color.accentText`，玻璃圆底），
  仅指示不可点（收藏动作在 06）
- 卡片整体为一个点击目标（≥44pt 天然满足）

### D 列表尾部状态行

- `type.subhead` / `color.muted`，上下 `spacing.xl`；文案见 §8

## 4. 状态变体

> 通用态规范源：`17-state-gallery.md`。

- **加载（首载）**：chips 行显 4 枚「全部」+3 枚呼吸胶囊（宽度按 `spacing` 比例的短/中/长三档，TG-06）；
  网格显 6 张骨架卡（16:10 封面块 + 一条标题块 + 一条元信息块，`color.surface` 呼吸）。
  骨架形状严格照 §3.C 真实几何，不做通用灰条
- **加载（切分类）**：**不重新骨架**——分类是本地过滤（§7），只让网格内容做
  `motion.duration.fast` 交叉淡入；Reduce Motion 下直接替换
- **空态**：当前分类无歌单（理论已在 chips 生成时过滤，仍可能因刷新变空）→
  17-S2 规范空态：插画位 + 「这个场景还没有歌单」(`type.headline`/`color.fg`) +
  「换一个场景看看，或直接说你想要什么氛围」(`type.callout`/`color.secondary`) +
  CTA 胶囊「去首页说一句」→ 01 并聚焦会话卡
- **错误**：**整屏错误态**（仅首载失败时）——理由：本屏无本地内容可降级，行内条与 Toast 都会留下
  一个空网格；17-S3 判定表「首载失败且无可留内容 → 整屏」。error 插画 + 「歌单没加载出来」+
  「检查网络后重试」+ 主钮「重试」。**分页/刷新失败 → Toast**（本屏无分页，实际仅下拉刷新会命中）
- **离线**：命中本地缓存列表 → 正常显示 + 顶部 17-S4 离线横幅「离线，展示上次内容」；
  无缓存 → 整屏错误态，文案「离线：歌单需要联网获取」+「重试」
- **未登录 / 游客**：本屏公开内容，正常浏览、正常进 06。收藏动作在 06 才需要登录（03 §6 同款引导 sheet）
- **Reduce Motion**：卡片入场错峰淡入（17-S5 矩阵）全部关闭 → 一次性呈现；下拉刷新保留系统控件；
  chips 切换交叉淡入关闭

## 5. 深浅双主题差异

- 背景 `color.canvas`；卡片文字 `color.fg`/`color.muted`；chips `color.surface`→`color.accentSoft`——
  全部走 `color.*` 双 mode，无本屏专属差异值
- 封面占位底：Light `color.surface` / Dark `color.elevated`（避免深底上「更深的灰」）
- 导航条 `material.navGlass` 已定义 light/dark 两值（tokens `material.navGlass`），不自建模糊
- 收藏角标玻璃底随系统材质自适应；符号色 `color.accentText` 双 mode 已备对比度

## 6. 可访问性

- **朗读顺序**：导航条「歌单，标题」→（带 `searchQuery` 时）「搜索：{query}」回显行 →
  「场景分类，横向滚动」→ 每个 chip
  （「咖啡馆，已选中」）→「歌单列表，N 项」→ 每卡单元素：
  「<标题>，<trackCount> 首，约 <分钟> 分钟，<已收藏时> 已收藏，按钮」→ 尾部状态行
- 卡片封面 `accessibilityHidden`（信息已在标签内）；`coverMedia.alt` 存在时作为图片元素的补充朗读，
  但**不与卡标签重复**（合并进同一元素标签尾部）
- **Dynamic Type**：AX 档下网格由 2 列降为 1 列（卡宽 = 屏宽 − 2×`spacing.pageGutter`，
  封面比例仍 16:10）；chips 行仍横滑不折行；标题仍 2 行上限
- **触控目标**：每个 chip（高 36 + 上下扩展至 44，TG-03）/ 每张卡 / 重试主钮 / 搜索回显行 ≥44pt
- 选中态不仅靠颜色：`selectedBg` 底 + `selected` 字重语义 + 描边 + VoiceOver「已选中」四重表达

## 7. 数据契约

- **主数据**：`GET /api/playlists` → `{playlists[]}`（`PlaylistDto`）。使用字段：
  `id / title / titleCn / cover / coverUrl / coverMedia{imageUrl,fallbackUrl,alt,fit,focalX,focalY} /
  scene / trackCount / totalDuration / isSaved / curator`
- **分类词表**：`GET /api/library/taxonomy` → `taxonomy.scene[]`（`{id,label,sortOrder}`），
  只用于 chips 的顺序与中文名；词表本地缓存、每次冷启动刷新一次
- **过滤为纯客户端行为**：`docs/api-contracts.md` §2 记录的 `GET /api/playlists` **无 `scene` 参数、
  无 `page`/`sort` 参数、无分页封套**（响应是 `{playlists}`，不含 `total/page/totalPages`）。
  → 本屏一次性取全量、本地按 `playlist.scene` 分组过滤。**不得**发明 `?scene=` 或 `?page=` 请求。
- **刷新策略**：进入本屏不自动请求（命中缓存 ≤ 24h 时直显，缺口 TG-09 缓存时效档）；
  下拉刷新强制重取；刷新后保留当前分类选中态
- **可空/缺失字段的 UI 规则**：
  - `titleCn` 空 → 用 `title`；两者都空（不应发生）→ 卡不渲染并入「异常条目」计数，
    末尾状态行不提示（不向用户暴露脏数据）
  - `trackCount` 空 → 元信息只显时长；`totalDuration` 空 → 只显曲数；两者空 → 元信息整行省略
  - `scene` 空 → 该卡只出现在「全部」分类下
  - `isSaved` 空（未登录时后端亦可能不给）→ 不渲染收藏角标
  - 封面族字段全空 → 占位块
- **NEEDS 关联**：本屏无字段被 NEEDS 阻塞（列表端点已确认可用，见 NEEDS「已确认可用」）。
  `isSaved` 需登录才有意义：NEEDS-1/3 未解锁期间游客视角恒为无角标，**不视为缺陷**

## 8. 边界与文案

- **截断**：歌单名中文优先 2 行、超出加 `…`；`curator`（06 用）不在此屏；数字用 `type.mono` + tabular-nums
- **时长折算**：`totalDuration`（秒）→ `≥60` 显示「N 分钟」（向下取整，最小 1 分钟），`<60` 显示「N 秒」；
  不做「时:分:秒」
- **零结果**：见 §4 空态；`playlists` 整体为空（后端异常）→ 空态文案换「歌单还在准备中」
- **极值**：列表 >200 条时仍不分页（客户端分帧渲染，滚动 60fps 为准，PRD §5）；
  同名歌单并存时以 `id` 稳定排序，不做去重
- **并发冲突**：下拉刷新与「切分类」互斥——刷新中禁点 chips（不置灰、点击入队最后一次生效）；
  刷新返回时若用户已切分类，结果按新分类过滤后呈现，不跳回
- **文案清单**：`歌单` / `全部` / `加载中…` / `已显示全部` / `这个场景还没有歌单` /
  `换一个场景看看，或直接说你想要什么氛围` / `去首页说一句` / `歌单没加载出来` / `重试` /
  `离线，展示上次内容` / `没有找到『%@』相关的歌单` / `清除搜索`

## 9. 验收判据

- [ ] 双列网格封面为 16:10，卡宽、列间距、行间距与 §3 的 token 表达式逐项对得上（无裸 pt 值）
- [ ] chips 只出现「至少有一个歌单」的 scene；切换分类不触发网络请求（抓包/日志确认零请求）
- [ ] 首载失败为整屏错误态且含「重试」；下拉刷新失败为 Toast，两者不混用
- [ ] 未登录可完整浏览并进 06；无登录打断
- [ ] AX5 档下网格自动单列、无横向滚动、卡片信息完整
- [ ] 全量列表下滚动帧率 60fps（Instruments/模拟器 Color Blended Layers 无异常叠加）
- [ ] 请求 URL 中不存在 `scene=` / `page=` 等契约外参数

## Token 缺口

| # | 缺口 | 本屏用法 |
|---|---|---|
| TG-02 | 品牌 logo 显示尺寸 | 导航条 logo |
| TG-03 | 最小触控目标 | 图标按钮 / chip 扩展热区 |
| TG-04 | 描边宽度档 | chip 选中 1pt 描边 |
| TG-06 | 骨架块宽度比例档 | chips 骨架三档 |
| TG-07 | 按钮/chip 高度档 | chip 36 |
| TG-10 | 无「网格列数/封面比例」维度 | 双列 + 16:10（inventory 钉死） |
| TG-11 | 无列表吸顶/渐隐遮罩规格 | chips 吸顶行 |
| TG-09 | 无缓存时效/新鲜度档位 | 24h 列表缓存 |

## 待裁决

1. **封面比例冲突**：`../components.md` §2 规定小卡 140×140（方形），`inventory.md` 行 05 规定
   双列封面 16:10。本规格裁决：**广场双列 = 16:10（信息密度更高）、首页横滑 = 方形 140×140**，
   `PlaylistCard` 需增 `ratio` 变体。改 `components.md` 需 G2 验收确认（本任务红线不改该文件）。
2. **（已裁决，2026-10-02）歌单搜索入口**：本屏不接搜索钮；歌单搜索经 01 输入条
   搜索档（目标=歌单）以 `searchQuery` 参数进入（§1），过滤为纯客户端行为。
3. **分页端点**：若歌单量级增长需服务端分页，得先由后端在 `GET /api/playlists` 加封套
   （建议登记 NEEDS），在此之前本屏恒为全量本地过滤。

## 9. 三源段控件（2026-09-27 加，§5 P3 第一条线）

- 位置：A 导航条之下、B 场景 chips 之上；一枚一段，横向排布，沿用 `CovaChip` 的选中语汇
  （`color.accentSoft` 底 + `color.accentText` 字 + 1pt `color.accent` 描边），不建第二套段控件。
- 三段：**官方歌单 / 每日推荐 / 歌单广场**。标签是本地词表 —— 服务端给的是
  `source:"official"|"shared"` 这种机器名，直接上屏就是把工程词给用户看。
- 数据源逐段：
  · 官方歌单 = `GET /api/playlists`（既有那条腿，一次全量、无分页）；
  · 每日推荐 = `GET /api/playlists/daily`（`{date, items}`；服务端把任意 `date` 钳到
    [昨日, 今日]，非 `YYYY-MM-DD` 回 400 ⇒ 客户端只在形状合法时才带这个参数）；
  · 歌单广场 = `GET /api/playlists/public`（`{playlists}`，只含已开分享的用户歌单）。
- **B 场景 chips 只在「官方歌单」这一段出现**：daily / public 两支的投影里都没有 `scene`
  （逐条核过 web 的 select）⇒ 另两段不给一排"点了必然为空"的分类。
- 换段 = 整屏重取（一份推荐位属于一个源，不叠成一本总账）；
  回来时若用户已经换段，那一趟**只丢不写**（与任务轮询同一裁决）。
- 卡的目的地由 `source` 决定，不由 id 长得像谁决定：
  `official` → 06；`shared` → **24**（目的地取 `href` 里的 token，
  `href` 不是 `/share/playlist/<token>` 这个形状 ⇒ 这张卡渲染成**不可点**，
  不"先按官方试一下"——猜错端点拿到的 404 会被算成服务端的错）。
- 空态文案逐段不同：官方「歌单还在准备中」；每日「今天还没有推荐位 / 明天这个时候再来看一次」；
  广场「还没有人把歌单分享出来 / 在官方歌单里挑一张，或自己去建一张」。
- 走查键：`COVA_PREVIEW_PLAZA_SOURCE=daily|shared`（段控件要点击才换，而 `simctl` 不给点击）。
- 设备证据：`docs/acceptance/p3-20260927/05-plaza-{official,daily,shared}-{light,dark}.png`
  （0.2.79/97，六张逐张读过）。
