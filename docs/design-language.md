# design-language.md — iOS 27 Liquid Glass × Cova 品牌

> token 数值的单一事实源是 `design/tokens.json`（Figma Variables 与 Swift 双端消费）。
> 本文档只讲**映射规则与设计意图**。

## 1. iOS 27 语汇 → Cova 落法

| iOS 27 特性 | Cova 用法 |
|---|---|
| Liquid Glass 材质（`.glassEffect` / `.regularMaterial` 等系统 API） | 会话输入框、MiniPlayer、左侧抽屉、浮动操作按钮。对应 web 的 `backdrop-filter: blur(28px) saturate(180%)` 语汇 |
| 用户可调玻璃不透明度 | 完全遵循系统设置，App 内不自建开关 |
| 更锐利的新图标规范 | 直接使用 `design/assets/CovaAssets.xcassets`（官方 canonical-v1，RGB 不透明浅底，无预烘焙圆角，交系统 mask） |
| 流体动效 | 统一弹簧曲线，对齐 web `cubic-bezier(0.32, 0.72, 0.24, 1)`；时长档 200/240/300/360/520/700ms；全量支持 Reduce Motion |
| SF Symbols 动效 | 播放/暂停、生成中状态用 `.symbolEffect`（如 `variableValue`、`.pulse`） |
| Siri AI / App Intents 一等公民 | v1.0 不做；预留：「用 Cova 找歌/做歌」Shortcut intent 列入 backlog |

## 2. 品牌色（产品 UI 唯一 accent：日落橙）

- accent `#FF6B00` / hover `#E66000` / soft 衬底 `#FFF1E6`（深色 `#3A1D05`）
- 浅底上 accent 文字用深橙 `#C24E00`（对比度 ≥4.5:1）；深底用 `#FFB173`
- **IP 吉祥物彩虹色板（#3B82F6 等）只用于吉祥物/营销场景，不进产品 UI**
- AI 语境渐变（仅创作入口与 agent 文字）：`110deg, #FF9A3D → #FF6B00 42% → #E84E8A → #FF9A3D`
- 主按钮深渐变（白字达标）：`110deg, #D04E00 → #C24E00 42% → #C03470 → #D04E00`

## 3. 中性色与材质（双主题）

| Token | 浅色 | 深色 |
|---|---|---|
| canvas 页面背景 | `#FFFFFF` | `#0C0C14` |
| surface 分组/工具条 | `#F5F5F7` | `#12121A` |
| elevated 浮层 | `#FFFFFF` | `#1A1A24` |
| fg / secondary / muted | `#1D1D1F` / `#6E6E73` / `#86868B` | `#F2F0EC` / `#A1A1AA` / `#6E6E73` |
| line / line-subtle | `#E8E8ED` / `#D2D2D7` | `#252530` / `#1E1E2A` |

语义色用系统色：success `#30D158` / error `#FF453A` / warning `#FF9F0A`。
会员金 `#66511F`（soft `#F7F0D8` / border `#C8AA5A`）；企业蓝 `#006EDC`（soft `#EAF4FF` /
border `#84BDF3`，深色文字 `#79BEFF`）；标签色 scene `#0D9488`、mood `#6366F1`。

## 4. 形状 / 字体 / 布局

- 圆角：卡片 18、控件 12、首页大卡 28、按钮与输入胶囊（全圆角）
- 字体：SF Pro（标题 700、字距 -0.01em、行高约 1.47）；数字/时码 SF Mono 或
  SF Pro `monospacedDigit`；全局 tabular-nums
- 层级 z 序对齐 web 语义：内容 < 导航 < MiniPlayer < 覆盖层 < 对话框 < Toast
- 触控目标 ≥44pt；胶囊按钮高 50（主操作）/ 36（chip）
- 全屏播放器封面圆角 28，背景取封面主色模糊铺底

## 5. 基调

「Musicbed 式电影感 + Apple 式中性灰」：内容优先、克制动效、深浅双主题对等质量、
AI 语境用橙→树莓渐变文字点睛。所有装饰性动效必须有 Reduce Motion 替代态。
