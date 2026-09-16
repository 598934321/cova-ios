# components.md — 组件库规格

> Figma 建 Components + Variants；开发侧对应 `CovaUI` 包。状态齐全是验收重点。

## 1. TrackRow（曲目行）

- 尺寸：高 64pt，横贯屏宽 − 2×pageGutter
- 构成：封面 48pt(radius 8) | 标题 subhead/fg + 艺人 caption/secondary（两行截断）
  | 时长 mono/caption/muted | ♡ | ⋯
- 变体：默认 / 播放中（标题 accentText + 音量 symbol 动画）/ 选中 / 禁用（灰 50%）
- 交互：点击播放（替换队列）；长按预览卡；左滑收藏/菜单

## 2. PlaylistCard（歌单卡）

- 大卡（首页今日推荐）：宽 100%，高 200pt，radius hero，封面 + 底部渐变遮罩 +
  标题 headline/白 + 元信息 subhead/白80% + 右上玻璃播放钮 44pt
- 小卡（场景精选/广场）：140×140pt 或双列网格，radius card，封面 + 标题条

## 3. MiniPlayer

见 `screens/01-home.md` §7。变体：播放 / 暂停 / 缓冲（封面转菊花）/ 隐藏。

## 4. PlanCard（计划确认卡，创作核心组件）

- 容器：elevated 底 + 1pt line 边 + radius card；AI 渐变顶部 2pt 装饰条
- 内容区（自上而下）：
  - 标题候选：selected 大字 headline + 候选 chips（可点选切换）
  - 风格分析：analysisZh 段落（callout/fg）+ style prompt（mono/caption/muted，可展开）
  - 歌词预览：分 section 折叠（Verse/Chorus…），每节默认收起
  - 参数行：type（演唱/纯音乐）· vocalGender · targetDuration · weirdness/styleWeight
    以键值 chips 展示
  - 费用行：`credits` 数值（mono，accentText）+ 「余额 xx」caption
- 底部操作：「开始制作」渐变主钮（胶囊 50pt）+「修改要求」文字钮
- **状态变体 12 态**（文案以 web `src/lib/one-step` 为准）：草拟/待确认/已确认/已启动/
  生成中/部分失败/完成/已取消/失败/过期/参数错误/余额不足；每态对应按钮可用性
  与徽标色（success/warning/error/muted）
- 归属校验未通过（`sourceMessage.messageId` 不匹配）：卡体置灰 + 顶部 warning 条

## 5. CandidateCard（生成候选卡，双 Demo）

- 双卡并列（会话内横排各 50% 宽）或 feed 网格卡
- 构成：封面（或像素呼吸占位）| 标题 subhead | 时长 mono | 状态徽标 |
  播放钮（玻璃圆 40pt 居中悬浮封面）| 底部操作条（♡ 收藏 retention / ↓ 下载 / ⤴ 分享）
- 状态：生成中（封面像素呼吸 + 进度环）/ 就绪 / 失败（error 遮罩 + 重试）
- 试听行为：私有音频先下载到沙盒再播（D7），播放中封面右上音量 symbol 动画

## 6. ComposerChips（会话框 chips）

- 模式 chip（找歌/做歌）：胶囊 36pt 高，选中 accentSoft+accentText+1pt accent 边
- prompt starter chip：surface 底 secondary 字，横滑，点击填入输入框
- 深度思考 toggle：胶囊带开关圆点，开=accent 底

## 7. TaxonomyCascade（级联筛选面板）

见 `screens/03-library.md` §2。变体：三栏级联（风格）/ 单栏多选网格（其余维度）。
词条行高 44pt，选中 accentText + 左 2pt accent 指示条。

## 8. 反馈组件

- **Toast**：顶部下滑胶囊，elevated 底 + 状态色 icon，3s 自动消失；z 序最高
- **Dialog**：居中 elevated 卡 radius card，标题 + 正文 + 主/次按钮；
   destructive 操作主钮 error 色
- **骨架屏**：surface 色块呼吸（1.2s 周期），形状跟随真实布局
- **空态**：插画位 + 标题 headline + 引导文 callout/secondary + CTA 胶囊

## 9. 徽标与标签

- 状态徽标：胶囊 caption，生成中 warning / 完成 success / 失败 error / 私有 warning 描边
- 标签胶囊：scene=tagScene / mood=tagMood / 其余 muted 描边
- 套餐徽标：会员=memberGold 系；企业=enterpriseBlue 系

## 10. 按钮体系

| 类型 | 规格 |
|---|---|
| 主按钮 | 胶囊 50pt，`gradient.brandButton` 底 + 白字，`primaryButtonShadow`；禁用 muted 底 |
| 次按钮 | 胶囊 50pt，surface 底 + fg 字 + 1pt line 边 |
| 文字按钮 | accentText，无底色 |
| 图标按钮 | ≥44pt 触控区，fg 或 secondary |
| 玻璃浮动钮 | Liquid Glass 圆形，用于卡上播放/发送 |
