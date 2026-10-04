# 01 · 首页（对话型首页：问候 + 双态输入条 + 内容 feed）

> G2 规格。**2026-10-02 重写**（取代 G1 方向稿）：对齐 web 端序章 `HomeHeroComposer` 的
> 信息结构（问候语 → 生成/搜索切换 → 输入框 → 引导标签），输入框形态取
> **ChatGPT iOS 式底部常驻输入条**（产品裁决：web 顶部 hero 位置不照搬，内容结构照搬）。
> 外壳参照 Apple Music iOS 26（04 §2）；曲库搜索已迁出至 25 搜索页签。
> 色值/字号/间距/时长一律以 `../tokens.json` 的 token 路径引用；本文件不得出现裸字面量。
> 数据源：`/api/playlists`（推荐/场景）、`/api/play-history`（最近播放）、
> `/api/tracks?sort=newest`（新歌上架）、`/api/studio/create/works`（你的创作）、
> `/api/studio/producers`（AI 音乐人，灰度恒空则整区隐藏）、
> `POST /api/find-my-song/sessions` + `POST /api/studio/agent`（生成档提交）。

## 1. 布局总览（自上而下）

```
┌─────────────────────────────────────┐
│ 晚上好，{昵称}                        │  §2 问候区（display 字阶）
│ 今天想和 Cova 一起创作些什么？          │    Cova 的「o」着 accent 橙
│                                     │
│      ⭘ 生成 │ 搜索 ⭘                │  §3 模式切换（CovaModeTabs，居中）
│                                     │
│  [一首治愈的钢琴曲] [国风纯音乐，短视…] │  §5 引导标签（CovaTagChip，随模式换词）
│                                     │
│ ── 推荐歌单 ─────────────── 更多 ›   │  §6.A 大卡 + 横滑卡带
│ ┌──────────┐┌──────────┐ →         │
│ ── 最近播放 ─────────────────────── │  §6.B 横卡带（游客隐藏）
│ ▢▢▢▢▢▢▢▢ →                         │
│ ── 新歌上架 ─────────────────────── │  §6.C 横卡带
│ ▢▢▢▢▢▢▢▢ →                         │
│ ── 你的创作 ─────────────────────── │  §6.D 横卡带（游客隐藏）
│ ── 场景精选 ─────────────── 更多 ›   │  §6.E 沿用原场景分组横滑
│ ── AI 音乐人 ────────────────────── │  §6.F 圆形头像横滑（灰度空则不渲染）
│                                     │
│ ┌─────────────────────────────────┐ │
│ │▾曲库 │ 说出你的音乐灵感…        ⬤│ │  §4 CovaComposer 底置输入条
│ └─────────────────────────────────┘ │   （safeAreaInset，浮于
└─────────────────────────────────────┘    mini-player / 标签栏之上）
     （MiniPlayer 是 04 §4 的 tabViewBottomAccessory，
       由外壳承载；CovaComposer 位于其上方安全区插入位）
```

页边距 `pageGutter`；分区间距 `lg`；分区内间距 `md`。

## 2. 问候区（对齐 web 序章文案）

- 第一行：`{时段称呼}，{昵称}`；第二行：`今天想和 Cova 一起创作些什么？`
  ——文案逐字对齐 web `HomeHeroComposer`；「Cova」中字母「o」着 `color.accent`，
  其余字符 `color.fg`（web 同款品牌细节）。
- 时段称呼：`<5 夜深了 / <12 早上好 / <18 下午好 / 其余 晚上好`（本地时间，对齐 web
  `useSalutation`；未取到昵称时省略昵称与逗号，即 `{时段}` + 换行直接接第二行）。
- 字阶：`type.display`（28/700/tracking −0.01，2026-10-02 新增 token）；
  紧凑字阶（CovaType 其余各档）不变——display 只给本屏问候，不扩散到列表/表单屏。
- 布局：占导航条下首块，左对齐；系统大标题导航**不用**（问候本身就是标题区，
  导航条只留透明栏位）。

## 3. 模式切换（CovaModeTabs）

- 形态对齐 web `LiquidTabs`：胶囊托盘（`color.fg` 5% 底、圆角 `radius.capsule`、
  内边距 `spacing.xs`）+ 滑动选中片（`color.elevated` 底，`matchedGeometryEffect`
  位移，`motion.curve` + `duration.normal`）；两档：`生成` / `搜索`，居中放置。
- 选中档文字 `color.fg` 半粗，未选 `color.secondary`；**不**用 accent 底
  （web 选中片是中性白/黑片，着色靠对比不靠品牌色）。
- 选中态会话内记忆：切出本页签再回来保持上次档位（对齐 web `homeHeroModeMemory`；
  冷启动回默认「生成」）。
- VoiceOver：`「生成，页签，已选中/未选中」`（`accessibilityTraits = .isSelected` 由系统
  segmented 语义承担，不手拼朗读串）。

## 4. 底置输入条（CovaComposer，本屏灵魂）

- **位置**：`safeAreaInset(edge: .bottom)` 常驻底部——浮于 mini-player 与标签栏之上
  （系统安全区插入自动避让，无播放任务时贴标签栏上缘；有任务时位于 accessory 之上）。
  浮层本体：玻璃材质 `material.glass`、圆角 `radius.card`、左右外边距 `pageGutter`、
  下外边距 `sm`。
- **结构**（单行 44pt 控件区 + 聚焦时可展开选项行）：
  | 位 | 生成档 | 搜索档 |
  |---|---|---|
  | 左钮 | `sparkles`（`gradient.ai` 着色——创作入口控件，红线范围内） | `menu` 下拉钮：显示当前目标短名 `曲库`/`歌单`（`type.caption`，`color.secondary`） |
  | 输入 | 占位「说出你的音乐灵感…」（`type.body`/`color.muted`） | 占位「搜索曲名 / 艺人 / 标签」 |
  | 右钮 | 圆形发送钮 40pt：`gradient.brandButton` + 白 ↑ + `elevation.primaryButtonShadow`；空输入置灰 `color.muted` | 同 |
- **选项行**（输入聚焦时于输入区上方展开，`duration.fast`）：
  - 生成档：`深度思考` 开关 chip（开 = `color.selectedBg` 底 + `color.selected` 字 +
    1pt `color.line` 描边——开关态按 web v2.65.0「播放列表当前项」同档走中性选中）
  - 搜索档：目标选择并入左钮 menu，选项行不渲染（目标已在上屏）
- **发送行为**：
  - 生成档：`POST /api/find-my-song/sessions`（body 沿用 08 §7：恒一步模式
    `workflowMode:'one-step', skipWelcome:true`）→ 拿 sessionId → 切「创作」页签 +
    该栈回根 + push 09（04 §3 归属表），进入 09 后由 09 的既有「待发送首条消息」机制
    把文本作为首条消息发出（`deepThinking` 随开关带上，agent 请求体现有字段）。
  - 搜索档·目标=曲库：`search(text)` → 首页栈内 push 曲库列表复用件
    （`library(preset)`，03 §7；文本进 `search` 参数）；空文本发送 → push 曲库列表
    不带条件（对齐 web「空查询只进对应页面」）。
  - 搜索档·目标=歌单：`plazaSearch(text)` → 首页栈内 push 05 并带 `searchQuery`
    （05 §1 新参数）；空文本 → 无筛选 push 05。
  - **游客态**：搜索档全功能可用（公开内容）；生成档发送 → 17-S6 登录引导 sheet
    （04 §6；不建会话、不切页签）。
- **键盘交互**：`.scrollDismissesKeyboard(.interactively)`；点 feed 任意处收键盘；
  键盘升起时输入条随之上移（系统 safeAreaInset 行为）。
- **不做清单（对齐 web 时主动砍掉的能力，凭后端/产品现状）**：附件、录音、音色选择、
  workflowMode 三模式（`POST /api/studio/agent` 契约只有 `sessionId/message/deepThinking`
  三件 ⇒ **不发明 `mode` 键**）；web 序章的 WebGL 舞台与形变过渡。

## 5. 引导标签（CovaTagChip）

- 形态对齐 web `home-hero-tag`：圆角 `radius.capsule`、1pt `color.line` 描边、
  半透底（`color.elevated` 60% + 玻璃）、`type.caption`/`color.secondary`；横排流式
  （换行不横滑——web 是 wrap），居中于切换器下方。
- **生成档**（4 枚，与 web `MODE_TAGS.generate` 逐字一致）：
  `一首治愈的钢琴曲` / `国风纯音乐，短视频配乐` / `轻快电子，品牌广告` / `电影感弦乐`；
  点按 = **直接发送**（等同输入该句后点发送，走 §4 生成档链路）。
- **搜索档**（4 枚，与 web `MODE_TAGS.search` 逐字一致）：
  `轻音乐` / `Lo-fi` / `中国风` / `商务科技`；点按 = 按当前搜索目标直接执行
  （曲库 → push `library(preset:search)`；歌单 → push `plazaSearch`）。
- 文案为本地常量（无端点）；修改只改文案表，不动组件。

## 6. 内容 feed（自 §5 之下滚动）

分区顺序固定；登录态专属分区（B/D）在游客态**整区不渲染**（不留标题不留占位）。

### A 推荐歌单

- 首张大卡：宽 = 屏宽 − 2×`pageGutter`，高 200pt，圆角 `radius.hero`；封面全幅
  （`coverMedia` fit/focal 裁剪）+ 底部 45% 深色渐变遮罩；遮罩上歌单名
  （`type.headline`/白）+ 曲数·总时长（`type.subhead`/白 80%，tabular-nums）；
  右上玻璃圆形播放钮 44pt（点播整个歌单）。数据 = `/api/playlists` 精选首条。
- 大卡下接其余官方歌单横滑小卡带（140×140 方形卡，沿用原首页横滑卡规格）。
- 「更多 ›」→ push 05 歌单广场（首页栈内）。

### B 最近播放（登录态）

- 横卡带：`/api/play-history` 前 12 条；每卡 = 封面 140 方 + 标题 2 行 +
  艺人/来源 `type.caption`；work 行（`track.workId` 非空或 trackId 含 `:`）封面角标
  `sparkles`（创作产物标记）。
- 空列表 → 整区不渲染（与游客态同规则：feed 没有「空壳分区」）。

### C 新歌上架

- 横卡带：`/api/tracks?sort=newest&pageSize=12`；卡同 B 规格（140 方 + 两行 + 一行元信息）。
- 与 B 的区分：B 是「我听过的」，C 是「库里新来的」；两者可同时存在，不互相顶替。

### D 你的创作（登录态）

- 横卡带：`/api/studio/create/works`（前 12 条）；卡 = 生成封面/像素占位 +
  标题 + 状态徽标（生成中 `warning` / 完成 `success` / 失败 `error`）。
- 空列表 → 整区不渲染；空态引导句「用一句话开始你的第一首歌」并入 §5 生成档标签区
  （不再在本区另做空态卡——输入条就在屏上，CTA 多余）。

### E 场景精选

- 沿用原规格：playlists 按 scene 分组横滑卡（140 方 + 底部标题条）；「更多 ›」→ 05。

### F AI 音乐人

- `/api/studio/producers` 灰度返回空 ⇒ 整区不渲染（现状逻辑沿用，见 23 §3 同一口径）；
  非空时圆形头像 64pt 横滑 + 名字 `type.caption`。

### 分区公共规则

- 分区标题：`type.headline`/`color.fg` 左 + 「更多 ›」`type.subhead`/`color.secondary` 右
  （仅 A/E 有更多入口；B/C/D 无对应列表屏，不放）。
- 各分区独立加载：分区骨架 = 一条横排骨架卡（`color.surface` 呼吸，17-S1 形状照真实卡）。
- 分区级失败：错误条（`color.error` icon + 「重试」），不阻塞整页。

## 7. MiniPlayer（外壳承载，不属本屏）

- 本屏**不**渲染 MiniPlayer：04 §4 的 `tabViewBottomAccessory` 由外壳承载
  （有播放任务才存在）。`CovaComposer` 与其共处的避让规则见 §4（safeAreaInset 分层）。

## 8. 状态与变体

- **未登录**：feed 公开分区（A/C/E/F）正常；B/D 整区隐藏；输入条可用（搜索全功能，
  生成档发送弹 17-S6）；问候区省略昵称段。
- **加载**：问候/切换/标签/输入条立即渲染（本地内容不阻塞）；feed 各分区独立骨架。
- **错误**：分区级错误条；输入条发送失败 → Toast（不发局部错误态到条上）。
- **深色**：全部走 token dark 值；玻璃与渐变自适应；「o」accent 深色同值（accent 不分主题）。
- **Reduce Motion**：切换滑动片退化为一帧跳变；feed 入场错峰淡入关闭；输入条无动画。
- **下拉刷新**：系统原生刷新控件（accent 着色），同时重取 A/C/E/F 与登录分区的各数据源。

## 9. 交互动效

- 页面进入：问候与控件区无动画直接呈现；feed 分区自下而上错峰淡入
  （每区延迟 40ms，`duration.normal`）。
- 模式切换：`matchedGeometryEffect` 滑片 + 标签区/输入条内容交叉淡化
  （`duration.fast`；Reduce Motion 一帧切换）。
- 输入条聚焦：玻璃高光边亮度 +20% 呼吸一次（`duration.slow`）；发送钮启用态变化用
  `duration.instant` 渐变。

## 10. 数据契约

| 区块 | 端点 | 说明 |
|---|---|---|
| A/E 歌单 | `GET /api/playlists` | 全量一次取（无分页），客户端分组/精选；沿用原口径 |
| B 最近播放 | `GET /api/play-history` | 登录才有 items；游客不发该请求 |
| C 新歌 | `GET /api/tracks?sort=newest` | sort 闭集内 `newest`；**不得**发明 `relevance` |
| D 创作 | `GET /api/studio/create/works` | 登录态；`limit=12` |
| F 音乐人 | `GET /api/studio/producers` | 灰度空 ⇒ 不渲染（23 §3 同口径） |
| 生成档提交 | `POST /api/find-my-song/sessions` → 09 内 `POST /api/studio/agent` | 请求体只用契约三件（sessionId/message/deepThinking） |
| 搜索档 | 见 §4（`library(preset)` 走 03 契约；`plazaSearch` 纯客户端过滤） | — |

- 标签文案、问候语、目标列表均为本地常量——**不从 web 的 `/api/home/materials` 取**
  （该端点是 web 营销位文案，D12 口径下客户端不接）。

## 11. 验收判据

- [ ] 输入条在任何分区滚动位置都常驻底部；有/无播放任务两种状态下与 mini-player、
      标签栏三者互不遮挡（实机截图两态各一张）
- [ ] 生成/搜索切换：滑片动画 + 标签换词 + 输入条左钮/占位随之切换；切页签再回来保持档位
- [ ] 生成档发送 → 创作页签栈内出现新会话详情、首条消息已发出（含深度思考开关态）
- [ ] 搜索档曲库目标发送 → 首页栈内 push 曲库列表且 `search` 已填；歌单目标 → 05 过滤态
- [ ] 游客：搜索档全功能可用；生成档发送弹登录引导；B/D 分区不存在（无空壳）
- [ ] 引导标签：生成档 4 枚点按即发送；搜索档 4 枚按当前目标执行
- [ ] 键盘交互式下拉可收起；feed 点击收键盘
- [ ] AX3 档：问候区两行不溢出（display 跟随 Dynamic Type）、输入条不破行
      （输入区压缩、左钮与发送钮宽度不变）
- [ ] 深浅双主题各一图（`01-首页-浅.png` / `-深.png`），成对验收

## Token 缺口

| # | 缺口 | 本屏用法 |
|---|---|---|
| TG-07 | 按钮/chip 高度档 | 输入条 44 控件区、标签 36 |
| TG-03 | 最小触控目标 | 发送钮/左钮/标签 ≥44 |

## 待裁决

1. **（已裁决，2026-10-02）输入条底置**（ChatGPT iOS 式）取代 web 顶部 hero 位置；
   内容结构对齐 web 序章。验收复核底部浮层与 mini-player 的体感。
2. **（已裁决）搜索目标 = 曲库 + 歌单两档**；web 的「一步模式/歌曲匹配」在 iOS 由
   生成档承接（agent 自动判意图）。`workflowMode` 字段已记 DEVELOPMENT.md §7 后端需求，
   上线后此屏可加第三档。
3. **搜索功能重复**：01 搜索档与 25 搜索页签能力重叠（01 是「意图入口」、25 是
   「浏览+历史」）。对齐 web（web 首页搜索框与曲库页搜索并存），验收时复核是否共存。
