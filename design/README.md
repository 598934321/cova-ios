# design/README.md — 设计工作流（Figma 闸门 G1 / G2）

> AI 不能直接操作 Figma；工作方式为：**规格稿（本目录）→ Figma 搭建 → 用户验收**。
> 两道闸门未过，不写对应 UI 代码（AGENTS.md 硬边界 8）。

## 目录

| 文件 | 用途 |
|---|---|
| `tokens.json` | **设计 token 单一事实源**。深浅双主题；Figma 侧用 Tokens Studio 或 Variables 导入插件建变量库；Swift 侧 G3 转译为 `CovaUI/DesignTokens.swift` |
| `screens/01-home.md` | G2 详稿：首页（2026-10-02 重写为对话型首页：问候 + 生成/搜索切换 + 底置输入条 + feed） |
| `screens/02-player.md` | G1 详稿：全屏播放器 + MiniPlayer |
| `screens/03-library.md` | G1 详稿：曲库（级联筛选；搜索已迁出至 25） |
| `screens/04-shell.md` | G2 详稿：App 外壳（五页签 TabView + `role:.search` 位 + 迷你条 accessory；原 `04-drawer.md` 抽屉方案已废） |
| `screens/25-search.md` | G2 详稿：搜索页签根屏（历史 + 分类浏览网格 + 结果态） |
| `screens/inventory.md` | G2 全屏清单（编号法与偏差登记表）与各屏要点 |
| `assets/CovaAssets.xcassets/` | 官方 AppIcon（源：`cova ip/03_logo/platforms/canonical-v1/`，勿改） |

> ⚠️ 本目录**没有** `components.md`：它在 `e84e295` 随旧契约文档一起删除，组件规格现在住在
> 各屏规格的 §3 区块规格与 `Packages/CovaUI` 的组件源码里。下面 G2 步骤第 2 条按此读。

## G1 操作步骤（方向稿）

1. 在 Figma 新建文件「Cova iOS」，导入 `tokens.json` 建变量库（Light / Dark 两个 mode）
2. 按 `screens/01–03` 规格搭建 3 张方向稿：首页、播放器、曲库（先做浅色，深色用变量
   mode 切换校验）
3. 画板基准：iPhone 16 Pro 393×852pt
4. 参考观感：DeepSeek iOS（极简会话）+ Suno 移动端（首页输入框+feed）+ Apple Music
   （播放器沉浸感）；品牌层叠加 Cova 橙与玻璃材质
5. **G1 验收**：用户确认方向 → 进入 G2

## G2 操作步骤（完整设计）

1. 按 `inventory.md` 完成全部屏幕（含空态/加载/错误态）
2. 组件规格取各屏 §3 区块规格 + `Packages/CovaUI` 组件源码（原 `components.md` 已删，见上）
3. 深浅双主题全量校验；标注 Reduce Motion 替代态
4. 动效说明写在各屏标注层（曲线/时长用 tokens.json 的 motion 值）
5. **G2 验收**：用户确认完整设计 → 开发按图施工，色值/字号/间距只允许取 token

## 给开发的红线

- 实现时色值、圆角、字号、间距、时长**只允许引用 token**，禁止散落硬编码
- 图标必须 SF Symbols（7 动效版优先）；品牌 logo 唯一源为 `assets/` 内资产，
  禁止反色/滤镜/重着色

## 与 web 的统一设计语言（v2.65 口径，2026-10-03 对齐批）

- **橙色职责**：`color.accent` 只承担强调/反馈（页签 tint、收藏心、播放进度、
  文字链接、主 CTA 渐变、AI 渐变装饰）；**不承担选中填充**。
- **选中态**：筛选 chip、分段控件、列表当前项、级联选中一律
  `color.selected` 字 + `color.selectedBg` 底（web `.cova-filter-current` 同值）。
- **按钮族**：primary = **中性液态玻璃**（`material.glass`，fg 字 + hairline）；
  `gradient.brandButton` 橙渐变只留给高可见 CTA（登录、生成、播放全部、开始创作）。
  secondary = 细描边（`color.line`）+ `color.surface` 底；danger = `color.error` 语义。
- **玻璃范围**（对齐 web「液态玻璃范围修订-20260930」）：玻璃只给浮在内容上的
  操作/导航层——顶栏钮、模式切换托盘、头像胶囊、迷你条、确认 Dialog、输入条。
  内容卡/表单/列表保 `color.surface`/`canvas` 纯色底板。
- **焦点环**：输入聚焦描边用 `color.focusRing`（中性灰），不用橙。
- **有意分歧**（登记，不算漂移）：字体 SF Pro（Dynamic Type 唯一引擎，web Inter
  不移植）；`tracking -0.01` 不落地；字号走 D24 紧凑档（比 web px 值整体低一档）；
  页签 tint 保橙（原生导航原语，web 无同位元素）。
