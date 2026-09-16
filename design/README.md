# design/README.md — 设计工作流（Figma 闸门 G1 / G2）

> AI 不能直接操作 Figma；工作方式为：**规格稿（本目录）→ Figma 搭建 → 用户验收**。
> 两道闸门未过，不写对应 UI 代码（AGENTS.md 硬边界 8）。

## 目录

| 文件 | 用途 |
|---|---|
| `tokens.json` | **设计 token 单一事实源**。深浅双主题；Figma 侧用 Tokens Studio 或 Variables 导入插件建变量库；Swift 侧 G3 转译为 `CovaUI/DesignTokens.swift` |
| `screens/01-home.md` | G1 详稿：首页（会话框 + feed） |
| `screens/02-player.md` | G1 详稿：全屏播放器 + MiniPlayer |
| `screens/03-library.md` | G1 详稿：曲库（级联筛选） |
| `screens/inventory.md` | G2 全屏清单（约 18 屏）与各屏要点 |
| `components.md` | 组件库规格（含状态与交互） |
| `assets/CovaAssets.xcassets/` | 官方 AppIcon（源：`cova ip/03_logo/platforms/canonical-v1/`，勿改） |

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
2. 按 `components.md` 建组件库（Figma Components + Variants 对应状态）
3. 深浅双主题全量校验；标注 Reduce Motion 替代态
4. 动效说明写在各屏标注层（曲线/时长用 tokens.json 的 motion 值）
5. **G2 验收**：用户确认完整设计 → 开发按图施工，色值/字号/间距只允许取 token

## 给开发的红线

- 实现时色值、圆角、字号、间距、时长**只允许引用 token**，禁止散落硬编码
- 图标必须 SF Symbols（7 动效版优先）；品牌 logo 唯一源为 `assets/` 内资产，
  禁止反色/滤镜/重着色
