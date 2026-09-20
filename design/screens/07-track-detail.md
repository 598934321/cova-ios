# 07 · 曲目详情（半屏 modal）

> G2 逐屏规格。基准 393×852pt。要点源：`inventory.md` 行 07（03 §4 已预告同一形态）。
> 数据源：`GET /api/tracks/:id` → `{track, similar[]}`（api-contracts §2；`similar[]` 为
> **similar 投影**，NEEDS-10/#12）。通用态规范源：`17-state-gallery.md`。

## 1. 屏与上下文

- **层级**：`modal` 半屏 sheet（present，不入导航栈）；`elevation.zOrder` 属 overlay 层，
  在 MiniPlayer（1000）之上、dialog（1100）之下。
- **入口**：① 03/05/06/12a/12d 的 TrackRow ⋯ 菜单「查看详情」；② 长按行的预览卡「查看详情」；
  ③ 02 播放器 ⋯ 更多「曲目信息」；④ 09 相似曲推荐；⑤ 深链 `tracks/:id`。
- **返回**：下滑手势 / 点遮罩（顶部露出的底层内容）关闭，回到来处屏且不改变其滚动位置；
  深链进入关闭后落 03。
- **互链**：艺人行 → 16 AI 音乐人主页；相似曲目卡 → 替换本 sheet 内容（不叠层，见「待裁决 1」）；
  「加入队列」→ 02；收藏 → 本地态；分享 → 系统分享面板。

## 2. 布局（393×852）

```
│┄┄┄┄┄┄┄ 遮罩（底层屏，30% 高可见）┄┄┄┄┄┄│
┌─────────────────────────────────────┐  ← sheet 顶（拖拽指示条）
│            ──                      │   A 拖拽条（居中，仅提示，非按钮）
│ [✕]                          [⋯]   │   B 顶部操作条
│      ╭─────────────────╮           │
│      │                 │            │   C 大封面（1:1，居中，宽度 = 屏宽−2×xxl）
│      │    cover        │           │
│      ╰─────────────────╯           │
│  夏日回声                            │   D 标题（largeTitle）
│  Echo Summer · Cova 音乐人 A07       │   E 艺人行（可点 → 16）
│  [ ▶ 播放 ]  [ ＋ 加入队列 ]         │   F 主操作行
│  ── 标签 ─────────────────         │
│  (咖啡馆)(平静)(Lo-Fi)(器乐)(BPM 84) │   G 标签流（多行 wrap）
│  ── 歌词 ────────────  全文 ⌄      │
│  主歌一 窗台的绿萝慢了一拍…           │   H 歌词摘要（静态文本，D15）
│  ── 相似曲目 ──────── 播放全部 ›    │
│  [卡][卡][卡] →                    │   I 相似横滑（similar 投影）
│                                    │
│  （下半屏，可上滑展开为近全屏）        │
└─────────────────────────────────────┘
```

- sheet 默认高 = 屏高 60%（缺口 TG-15 sheet 高度档）；上滑至 92% 全展开（两档吸附）

## 3. 区块规格

### A/B 拖拽条与顶部操作条

- 拖拽指示条：`color.line` 色、胶囊（TG-16 指示条几何）；不作为按钮
- ✕（关闭）与 ⋯（更多菜单：分享 / 复制链接 / 查看艺人）图标按钮 ≥44pt（TG-03），`color.fg`
- sheet 底：`color.elevated`，顶部圆角 `radius.hero`

### C 大封面

- 宽 = 屏宽 − 2×`spacing.xxl`，`1:1`，圆角 `radius.card`（比 06 头图小一级）
- 加载占位：PixelCard 式像素块呼吸（`color.surface`）；失败 → 音符占位（不空白）

### D/E 标题与艺人

- 标题 `titleCn ?? title`：`type.largeTitle` / `color.fg`，中文优先 2 行
- 艺人行：`type.subhead` / `color.secondary`；`artist.nameCn ?? artist.name`；
  整行为一个点击目标（≥44pt 热区）→ 16；`countryFlag`/`styleCn` 不在本行显示

### F 主操作行

- 「播放」：`gradient.brandButton` 主钮，高 50（TG-07）、`radius.capsule`，图标 `play.fill`；
  语义 = **替换队列并从本曲开始播**（components §1 一致）
- 「加入队列」：次按钮（`color.surface` 底 + `color.fg` 字 + 1pt `color.line` 描边，TG-04），同高
- 「收藏 ♡」：**从 ⋯ 菜单升到操作行之外**——本屏收藏钮放在 D 区右侧（与 02 播放器一致），
  选中态 `color.accent` 填充 + `duration.fast` 缩放弹跳（02 §5 同规格）
- 「下载」：D12 放行前**整钮不渲染**（见 §7 与 `12d-downloads.md` §7）；放行后走
  checkout 确认（余额 + 幂等键）→ 下载

### G 标签流

- 内容源：`scenes[]` + `moods[]` + `displayLabels[]`（去重后）；标签胶囊按
  `../components.md` §9：scene → `color.tagScene`、mood → `color.tagMood`、其余 → `color.muted` 描边
- `type.caption`，水平内边距 `spacing.md`、垂直 `spacing.xs`、间距 `spacing.sm`、行间距 `spacing.sm`，
  多行 wrap，最多 3 行 + 「+N」追加胶囊（点开=展开全部）
- 每个标签胶囊可点 → 关闭本 sheet 并跳 03 预填该维度筛选（与 03 §7 联动规则一致）

### H 歌词摘要

- `track.lyrics`：静态文本（D15，无时间轴），`type.body` / `color.fg`，行距 1.47（token 内定义），
  收起态最多 4 行；「全文 ⌄」文字钮（`color.accentText`，`type.subhead`，≥44pt 热区）
  展开至 sheet 内滚动（不外跳）
- 无歌词 / 纯音乐（`vocalType` 为器乐或 `lyrics` 空）→ 整区替换为一行
  「纯音乐 · 无歌词」（`type.callout` / `color.muted`），不显示插画

### I 相似曲目横滑

- 卡：封面方图（宽 = 屏宽 38%，TG-10 比例档复用）+ 标题 `type.subhead` 2 行 +
  相似度**不显示**（`similarityScore` 属实现细节，见「待裁决 2」）
- 点击 → 目标曲详情内容替换本 sheet（同一 sheet 内替换 + 顶部出现「‹ 返回上一首」文字钮）
- 「播放全部 ›」：文字钮 → 用 `similar[]` 替换队列并从第一条播

## 4. 状态变体

- **加载（首载）**：C 区像素呼吸块；D/E 两条骨架文本；F 两枚胶囊骨架；G 三枚呼吸胶囊；
  H 四条呼吸文本条；I 两个呼吸方卡。全部 `color.surface`（17-S1）
- **空态**：`similar[]` 空 → I 区整区不渲染（**不显示空态插画**——相似区是加分项，空态会喧宾夺主，
  17-S3 判定「可选区块 → 静默隐藏」）；`tags`/`displayLabels` 全空 → G 区不渲染；
  `lyrics` 空 → 见 §3.H 一行文本
- **错误**：
  - 首载失败 → **sheet 内整屏错误态**（替换 C–I，保留 B 顶条 ✕）：error 图标 +
    「曲目信息没取到」+ 主钮「重试」。理由：半屏容器内不能塞「整页错误」，也不能只 Toast
    （用户会盯着一张空 sheet），17-S3 增补规则见「待裁决 3」
  - 二次操作失败（收藏/加入队列）→ Toast；标签点跳失败 → 目标屏自处理
- **离线**：命中本地缓存的详情 → 正常显示 + 顶部 17-S4 离线细条（sheet 内，非横幅）；
  无缓存 → 整屏错误态「离线：需要联网查看」；播放走 03 的 preview/缓存降级由播放层决定，
  本屏不承诺离线可播
- **未登录 / 游客**：本屏全部公开内容可看（详情 + 歌词 + 相似 + 试听）；收藏/加入队列 →
  17-S6 登录引导 sheet；下载入口对游客与登录者同样隐藏（D12）
- **Reduce Motion**：sheet 弹出（`motion.duration.page` 弹簧）→ 退化为直接呈现；
  收藏缩放弹跳、横滑弹簧回弹、两档吸附动画 → 直接到位（吸附点保留）；「全文」展开退化为一帧撑开

## 5. 深浅双主题差异

- sheet 底 `color.elevated`（Light 为抬升白、Dark 为抬升深蓝黑，两值由 tokens 的 mode 给出）；
  遮罩用系统 scrim 材质，其强度档**尚未入库**（缺口 TG-08 / TG-12：需 light/dark 双值），
  未裁决前按系统默认强度施工，不自造色值
- 歌词文本 `color.fg` 在 Dark 下为 token 给出的暖白值（tokens 已备双值），
  封面阴影 `elevation.glassButtonShadowDark`
- 标签三色系（tagScene/tagMood/muted 描边）Dark 下均已有更亮值，无需本屏调整
- 主按钮渐变与白字双主题同值

## 6. 可访问性

- **朗读顺序**：弹出即焦点到「曲目详情，<标题>」→ ✕ → ⋯ → 封面（「封面图，<曲名>」，
  有 `description` 时并入）→ 标题 → 艺人「艺人，X，按钮」→ 收藏钮（「收藏，已选中/未选中」）→
  播放 → 加入队列 →「标签，N 项」→ 每条「Lo-Fi，标签，按钮」→「歌词」区块标题 + 全文钮 →
  「相似曲目」+ 每卡 → 「播放全部相似」。sheet 为**模态容器**，底层屏内容不可被朗读到
- **Dynamic Type**：AX 档下 sheet 默认高由 60% → 自动近全屏（内容优先，TG-15）；
  C 封面缩为屏宽 − 2×`spacing.xxl` 的 60%（避免挤出内容）；G 标签允许 6 行；H 摘要仍 4 行 + 全文钮
- **触控目标 ≥44pt**：✕ / ⋯ / 艺人行 / 收藏钮 / 播放 / 加入队列 / 每个标签胶囊 / 全文钮 /
  每张相似卡 / +N / 播放全部 / sheet 内错误重试

## 7. 数据契约

| 用途 | 端点 | 字段 |
|---|---|---|
| 详情 | `GET /api/tracks/:id` → `{track, similar[]}` | `track{id,title,titleCn,cover,duration,bpm,artist{id,name,nameCn},scenes,moods,tags[],displayLabels,lyrics,vocalType,energy,style,styleCn,key,playCount,favoriteCount,copyright}` |
| 相似 | 同响应 `similar[]`（**similar 投影**） | `id,title,cover,duration,artist,bpm` 等投影内字段；`audioUrl` 仅用于播放，不展示 |
| 试听 URL | `GET /api/tracks/:id/preview-url` → `{url,previewStart,previewEnd,duration}`（匿名可访问） | 播放层消费；**URL 不显示、不入日志、不入持久化** |
| 收藏 | `POST` / `DELETE /api/favorites` `{trackId}` → `{message,favoriteCount}` | 乐观更新本地态 |
| 下载（放行后） | `GET /api/downloads/checkout`（`{downloadCredits,balance,enabled,format}`）→ `POST /api/downloads/checkout`（`{trackIds,format:'mp3',idempotencyKey}`）→ `GET /api/downloads/:downloadId/file` | v1.0 入口隐藏 |

- **投影硬规则**：`similar[]` **不得**按 `TrackDto` 解码（`featured` 为数字、仅 snake_case
  `preview_start/end`、`artist`/`tags` 为裁剪结构 → `typeMismatch`/`keyNotFound`）。
  本屏只用投影内稳定存在的字段：`id / title / cover / duration / artist / bpm`。
  `displayLabels`、`waveformPeaks`、`highlightStart/End` 在 similar 投影中不可依赖 → I 区不显示标签/波形
- **NEEDS-8 未解锁**（详情 `track` 无 `variantGroupId / variantRole / variantCount / variants`）
  → UI 降级：本屏**不做 A/B 变体展示与切换**（无区块、无占位文案）。若列表带来的 track 带
  `variants`，也不得在详情里展示（同一曲目两处口径不一致会造成「详情比列表少」的困惑）→
  统一以详情响应为准；解锁后增补「版本」区块（预留标题位见 §8 文案清单）
- **NEEDS-11/#10/#12 未解锁** → 相关字段本屏不消费，不产生新降级
- **可空/缺失规则**：`titleCn`→`title`；`lyrics` 空 → 一行「纯音乐 · 无歌词」；`bpm`/`key` 为 0 或空 →
  该标签不进 G 区（不显示「BPM 0」）；`favoriteCount` 空 → 不显示；`copyright` 空 → 不显示版权行
  （本屏不放版权长文，版权说明在 15 设置外链）
- **刷新/缓存**：详情按 `trackId` 本地缓存，二次进入先显缓存再静默刷新；`similar[]` 每次进入
  不自动重取（同曲相似性稳定）

## 8. 边界与文案

- **截断**：标题 2 行；相似卡标题 2 行；艺人名单行；标签词本身超长 → 单词内截断至 12 字 + `…`
- **零结果**：`similar[]` 空 → 整区隐藏；`scenes/moods/displayLabels` 全空 → G 区隐藏
- **极值**：`lyrics` 超长（>2000 字）→ 收起 4 行、全文展开后 sheet 内部滚动，不新开屏；
  标签 >30 个 → 前 20 个 + 「+N」
- **并发冲突**：
  - sheet 打开期间收到「同曲另一入口再次点开」→ 复用当前 sheet，内容替换并滚回顶（不叠第二个）
  - 收藏连点 → 乐观态只吞后发，最终以后端 `{favoriteCount}` 回填
  - 相似替换浏览（I 区点击）与底层屏播放中的 MiniPlayer → MiniPlayer 在 sheet 之后（z 序），
    替换浏览不打断播放；「播放全部」会替换队列（明确覆盖，弹 Toast「已替换播放队列」）
- **零余额 / D12**：本屏任何文案不得出现「购买 / 充值 / 价格 / 解锁下载」；`copyright` 类
  商用授权表述若后端给出，仅以中性一行「商用授权详见官网」呈现（外链，无价格）
- **文案清单**：`纯音乐 · 无歌词` / `全文` / `相似曲目` / `播放全部` / `加入队列` / `已加入队列` /
  `已替换播放队列` / `曲目信息没取到` / `重试` / `离线：需要联网查看` / `版本`（NEEDS-8 解锁后预留）

## 9. 验收判据

- [ ] `similar[]` 用独立投影解码，真机/契约样本下不出现 `featured` 类型或 `previewStart` 缺失崩溃
- [ ] NEEDS-8 未解锁时本屏无「A/B 变体」区块、无空占位、无错误提示（静默缺席而非未实现）
- [ ] D12：下载钮不渲染且不出现在 ⋯ 菜单与 VoiceOver 元素序列中
- [ ] sheet 两档吸附在真机可用；AX5 档自动近全屏、无内容被挤出
- [ ] 标签点击关闭 sheet 并在 03 正确预填对应维度筛选（scene/mood/style 三类各验一次）
- [ ] 无歌词曲目显示「纯音乐 · 无歌词」，不出现插画位或空框
- [ ] 播放/加入队列与 MiniPlayer 的队列语义与 components §1 一致（替换 vs 追加可对拍）

## Token 缺口

| # | 缺口 | 本屏用法 |
|---|---|---|
| TG-03 | 最小触控目标 | ✕ / ⋯ / 标签 / 文字钮 |
| TG-04 | 描边宽度档 | 次按钮、muted 标签描边 |
| TG-07 | 按钮高度档 | 主/次按钮 50 |
| TG-10 | 封面比例档 | 大封面 1:1、相似卡 |
| TG-15 | sheet 高度档（60% / 92% / AX 近全屏） | 本屏容器 |
| TG-16 | 拖拽指示条几何 | A 区 |
| TG-12 | 遮罩强度（light/dark） | 底层遮罩 |
| TG-17 | 文本行数上限档（2/3/4 行） | D / 简介 / 歌词摘要 / 相似卡 |

## 待裁决

1. **相似浏览的栈语义**：本规格用「同 sheet 内替换 + 返回上一首」，另一选项是再开一层 sheet。
   iOS 规范下 sheet 套 sheet 体验差，建议采纳替换；**待 G2 验收确认**。
2. **`similarityScore` 是否外露**：投影里有，但数值含义（int/float 混用，NEEDS-12）未文档化 →
   本屏不显示。若产品要在相似卡上显示「相似 92%」需先由后端钉口径。
3. **半屏容器内的「整屏错误」形态**：17-S3 判定表原文只分「Toast / 整屏 / 行内」。本屏引入
   「sheet 内整块替换」子形态，需在 17-S3 里正式登记（本文件已在 §4 说明选择理由）。
4. **长按预览卡与本屏的关系**：03 §4 的预览卡是否等价于本屏的轻量态（只 C/D/F）？
   建议预览卡 = 本屏收起态（复用同一组件），**待 G2 验收确认**。
