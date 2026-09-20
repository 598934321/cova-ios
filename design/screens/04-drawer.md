# 04 · 左侧抽屉（全局导航 + 我的卡片）

> G2 逐屏规格。基准画板 iPhone 16 Pro 393×852pt。要点源：`inventory.md` 行 04。
> 色值/字号/间距/时长一律以 `../tokens.json` 的 token 路径引用；本文件不得出现裸字面量。
> 缺失 token 不自行新增，统一登记在文末「Token 缺口」。
> **闸门状态**：G1 未验收 → 本文件是设计事实源，不是实现许可（AGENTS.md 硬边界 8）。

## 1. 屏与上下文

- **层级**：覆盖层（`elevation.zOrder` 的 overlay 层），**不是** modal sheet，也**不入**导航栈。
  打开时不改变底层屏的路由状态。
- **入口（两个）**：① 顶层屏顶栏左上 logo；② 屏幕左缘右滑手势（起点在左缘手势带内）。
  任何屏都可打开；本屏自身不可再开本屏。
- **关闭**：点右侧遮罩 / 遮罩上左滑 / 选中任一导航项（自动关闭）/ 从抽屉内返回上层屏时不重复关闭。
- **互链**：首页（01）、曲库（03）、歌单广场（05）、创作会话列表（08）、我的收藏（12a）、
  我的歌单（12b）、我的创作（12c）、已下载（12d，放行前隐藏）、会员（13）、企业服务（14）、
  我的（11）、设置（15）、登录（10，由底部未登录态唤起）。
- **返回行为**：抽屉内无系统返回手势；关闭 = 回到打开前的屏与滚动位置（不重置 feed）。
- **iPad**：v1.0 不做专版布局（PRD §3），抽屉按 iPhone 宽度比例呈现，不做 `sidebarAdaptable` 适配验收。

## 2. 布局（393×852）

```
┌──────────────────────────┬────┐
│ ╭─ 顶栏区 ─────────────╮ │    │
│ │ [logo] Cova      [✕] │ │ 遮 │   A 顶栏（品牌 + 关闭）
│ ╰─────────────────────╯ │ 罩 │   （遮罩宽 = 屏宽 − 抽屉宽）
│  主导航                  │    │
│  ⌂ 首页                 │    │   B 主导航组（4 项）
│  ♫ 曲库                 │    │
│  ☰ 歌单                 │    │
│  ✨ 创作  (AI 渐变文字)  │    │
│  ─────────────────────── │    │   C 分组分隔线
│  我的资产                │    │
│  ♡ 收藏                 │    │   D 资产组（3–4 项）
│  ☰ 歌单                 │    │
│  ✨ 创作                │    │
│  ↓ 已下载（放行后可见）  │    │
│  ─────────────────────── │    │   E 分组分隔线
│  商业                   │    │
│  ★ 会员   (金色调)      │    │   F 商业组（2 项，跳网页）
│  ▣ 企业服务 (蓝色调)    │    │
│                          │    │
│ ╭─ 我的卡片 ───────────╮ │    │   G 底部我的卡片
│ │ (头像) 名字           │ │    │
│ │        covaId/邮箱    │ │    │
│ │  [余额胶囊 co 128]    │ │    │
│ │  套餐徽标 [创作]  [⚙] │ │    │
│ ╰─────────────────────╯ │    │
└──────────────────────────┴────┘
```

- 抽屉宽 = 屏宽 × 78%（inventory 钉死；tokens 无对应档位 → 缺口 TG-01）
- 内容左右内边距 `spacing.pageGutter`；组标题与项之间 `spacing.lg`；组间距 `spacing.xl`

## 3. 区块规格

### A 顶栏区

- 高：手势安全区 + 品牌行；品牌行内上下内边距 `spacing.lg`
- logo：`design/assets/CovaAssets.xcassets` 官方资产，显示尺寸沿用 01 顶栏规范（28pt，缺口 TG-02）；
  **禁止反色/滤镜/重着色**（design/README 红线）
- 字标「Cova」：`type.headline` / `color.fg`，字距随 token
- 关闭按钮（✕）：图标按钮，触控区 ≥44pt（缺口 TG-03 = 最小触控档未入库），图标色 `color.secondary`
- 底边：`color.lineSubtle` 1pt 分隔线（描边宽度缺口 TG-04）

### B 主导航组

- 组标题：`type.caption` / `color.muted`，下间距 `spacing.md`
- 导航项：行高 = 内容 + 上下 `spacing.md`；圆角 `radius.control`；水平内边距 `spacing.md`
  - 图标 `color.secondary` → 选中项图标/文字 `color.accentText` + 底 `color.accentSoft`
  - 左侧指示条：选中显 2pt accent 竖条（宽度缺口 TG-04），与 `../components.md` §7 词条行同规格
  - 「创作」项文字用 `gradient.ai` 着色（design-language §2：AI 渐变只用于创作入口与 agent 文字），
    其余项**不得**使用渐变
- 状态语义：当前所在屏对应的项常驻选中态；子屏（如 06 歌单详情）保持父项（05 歌单）高亮

### C/E 分隔线

- `color.lineSubtle`，上下各 `spacing.xl` 留白

### D 我的资产组

- 同 B 的项规格；右侧计数徽标（可选）：`type.caption` / `color.muted`，`spacing.sm` 左间距
- 「已下载」项：D12 合规放行前 **整项不渲染**（不是置灰、不是禁用），详见 `12d-downloads.md` §7

### F 商业组

- 会员项：图标与文字 `color.memberGold`；行底 `color.memberGoldSoft`，1pt `color.memberGoldBorder` 描边
- 企业服务项：图标与文字 `color.enterpriseBlue`；行底 `color.enterpriseBlueSoft`，
  1pt `color.enterpriseBlueBorder` 描边
- 两项右侧统一显示 `arrow.up.right.square`（外链语义），`color.muted`
- 点击行为：跳网页（Safari 打开 `covalink.cn` 对应页），**App 内不出现价格、购买、充值、支付**（D12）

### G 底部我的卡片

- 容器：`material.glass`（同会话卡/MiniPlayer 语汇）；圆角 `radius.card`；内边距 `spacing.lg`；
  阴影 `elevation.glassButtonShadowLight` / Dark 下 `elevation.glassButtonShadowDark`
- 头像：圆形，显示尺寸 44pt（缺口 TG-05），占位为 `color.surface` 底 + 人形符号 `color.muted`
- 名字：`type.headline` / `color.fg`，单行截断（规则见 §8）
- 次行（covaId 或邮箱）：`type.subhead` / `color.secondary`，`type.mono` 呈现 covaId（tabular-nums）
- 余额胶囊：`radius.capsule`，底 `color.surface`，文字 `type.caption` / `color.accentText`，
  数值走 `type.mono`；**只读展示**（D12），无点击态、无「充值」副文案
- 套餐徽标：`../components.md` §9 套餐徽标规范（会员=memberGold 系 / 企业=enterpriseBlue 系 /
  free=描边 muted）
- 设置齿轮：图标按钮 ≥44pt，`color.secondary` → 15 设置

## 4. 状态变体

> 通用态定义（骨架/空态/错误三选一判定、离线横幅、游客引导、Reduce Motion 退化矩阵）
> 的唯一规范源是 `17-state-gallery.md`。本节只写本屏差异项。

- **加载（首帧）**：抽屉本身依赖本地缓存即可渲染，不出现整屏骨架。仅 G 区做局部骨架：
  头像 = 圆形 `color.surface` 呼吸块；名字/covaId = 两条圆角条（宽度分别约行宽 55% / 35%，
  缺口 TG-06 骨架比例档）；余额胶囊 = 短胶囊呼吸块。B/D/F 导航组**永不骨架**（导航必须即刻可用）
- **空态**：抽屉无空态语义（导航恒在）。唯一空态是 G 区未登录 → 见下
- **错误**：`GET /api/auth/me` 失败 → **行内降级**，不弹 Toast、不整屏：G 区保留上次缓存值，
  余额胶囊数值位显示 `--`，副文本 `color.muted` 显示「未同步」+ 点击重试图标。
  理由：抽屉是导航容器，错误不得阻塞导航；整屏/Toast 均违反 17-S3 判定表首条
- **离线**：抽屉内容与导航项照常可用；点击需网络的项（05/08/12a…）时由目标屏处理离线态。
  G 区余额显示缓存值 + 「未同步」（同错误态文案，不区分）
- **未登录（guest / signed-out）**：G 区换态——头像位显 `color.surface` 占位；
  文字「登录解锁创作与收藏」（`type.headline` / `color.fg`）；余额胶囊与套餐徽标**不渲染**；
  「登录」渐变主钮（`gradient.brandButton` + 白字，高沿用主按钮 50pt 档，缺口 TG-07）→ 10 登录；
  次行文字按钮「先逛逛」→ 关闭抽屉。游客可正常浏览 01/03/05/06/07/16 与试听（PRD 4.1）
- **authenticated**：正常态；从 10 登录成功回跳本屏时保持打开，便于继续点资产项
- **登出后**：G 区立即回落未登录态（D8：清队列/销毁播放器/清私有音频与封面缓存/推进 generation），
  缓存余额与用户名不留残留
- **Reduce Motion**：抽屉滑入（`motion.duration.page` + `motion.curve`）退化为直接呈现（无位移、无淡入）；
  遮罩透明度渐入退化为一帧到位；导航项选中态底色的弹性缩放关闭，改为一帧换色；
  G 区余额数字滚动（若有）退化为直接显值

## 5. 深浅双主题差异

- 全部差异由 `color.*` 的 light/dark 双值解决，**不允许**屏内硬编码：
  - 遮罩：Dark 下更深、Light 下偏灰；系统 scrim 材质（不新增色值，缺口 TG-08 = scrim 强度 token）
  - 玻璃卡片：`material.glass` 系统自适应；阴影切 `elevation.glassButtonShadowLight` →
    `elevation.glassButtonShadowDark`
  - 描边：`color.lineSubtle`（light / dark 两值由 token 决定，本文件不写值）
  - 会员金/企业蓝：Light 下文字用深色金/蓝，Dark 下用亮色金/蓝——**这正是 tokens 已备双值的原因**，
    实现只引用 `color.memberGold` / `color.enterpriseBlue`，不得自行选值
  - `gradient.ai` / `gradient.brandButton`：双主题共用同一渐变定义，Dark 下不额外降饱和
- Dark 下 `color.accentSoft` 为深橙衬底，B/D 组选中态观感与 Light 等权，不得只调 Light

## 6. 可访问性

- **VoiceOver 朗读顺序**（焦点在进入抽屉时移到第一项，关闭时归还给触发它的 logo 按钮）：
  1. 「Cova 导航抽屉，标题」→ 2. 关闭按钮「关闭抽屉」→ 3. 组标题「主导航」→
  4. 各导航项（标签：`首页，标签页` / `创作，AI 创作，当前选中`）→ 5. 组标题「我的资产」→
  6. 各资产项 → 7. 组标题「商业」→ 8. 「会员，前往网页了解」→ 9. 「企业服务，前往网页联系」→
  10. 「我的卡片」：头像「用户头像」→ 名字 → covaId（读作「Cova 身份编号，X」，逐字符不朗读符号）→
  余额「余额 128 co，仅展示」→ 套餐徽标「当前套餐 创作」→ 「设置，按钮」
- 「已下载」项在放行前对 VoiceOver 也**完全不存在**（非 hidden 元素）
- 组合标签：导航项整行一个元素（图标 `accessibilityHidden`），避免图标+文字分开朗读
- **Dynamic Type**：AX 档（AX1–AX5）下——组标题隐藏（分组由语义标题承担）；B/D/F 组项文字换 2 行，
  行高自适应；G 卡片改为纵向堆叠（头像与文字两行，余额胶囊与徽标换行，设置钮右上角绝对定位），
  抽屉宽保持比例值不随字号变（横向溢出禁止）；G 区名字允许 2 行
- **触控目标**：逐一确认 ≥44pt——关闭按钮 / 每个导航项（整行为一目标）/ 会员项 / 企业项 /
  登录主钮 / 设置齿轮 / 余额重试图标 / 遮罩（关闭手势）；抽屉内无 28pt/24pt 级小图标

## 7. 数据契约

| 用途 | 端点 | 用到的字段 | 刷新/分页 |
|---|---|---|---|
| 我的卡片（头像/名字/身份/套餐/余额） | `GET /api/auth/me` → `{user, entitlements}` | `user.name`、`user.covaId`、`user.email`、`user.avatar?`（契约无此字段 → 见下）、`entitlements.plan`、`entitlements.creditsBalance` | 打开抽屉时若距上次 `me` > 5min（客户端策略值，缺口 TG-09）才刷新；下拉刷新（底层屏）时顺带刷新；登录成功、启动制作扣费后强制刷新 |
| 资产项计数徽标 | 不请求 | — | v1.0 **不显示计数**：`GET /api/favorites`、`GET /api/saved-playlists`、`GET /api/find-my-song/sessions` 均无 count 字段，为抽屉发 3 次列表请求属性能浪费且无契约支持。徽标位保留但恒不渲染，待后端提供聚合计数端点（建议登记 NEEDS，见 `待裁决`） |
| 商业组跳转 | 无端点（外跳网页） | — | 目标 URL 为常量路由，不拼用户数据 |

- **可空字段的 UI 规则**：
  - `user.name` 空 → 回落显示 `user.email`；两者都空 → 显示「Cova 用户」
  - `user.covaId`：NEEDS-1 未解锁（`/api/auth/login` 的 `user` 实测仅
    `{id,email,name,role}`，`/api/auth/me` 的 `covaId` 由 NEEDS-3 覆盖）→ UI 采用降级：
    次行不显示编号、整行省略，不留 `--` 占位（避免用户误以为账号异常）。**不得**用 `user.id` 冒充 covaId
  - `entitlements.creditsBalance`：NEEDS-3 未解锁 → 余额胶囊不渲染（等同未登录的余额位处理），
    解锁后恢复；**不得**显示 0（0 与「无数据」在扣费语境下语义不同，属误导）
  - `entitlements.plan` 缺 → 套餐徽标不渲染
  - 头像：`AuthUser` 契约（api-contracts §1）**无 avatar 字段** → v1.0 抽屉头像恒为
    首字母占位（`color.surface` 底 + `color.accentText` 字），不猜字段
- **游客态**：不发 `me`；G 区显未登录态；抽屉其余部分完全本地渲染
- **缓存与合规**：`me` 响应缓存进 owner 绑定持久化（D9 Codable JSON + 沙盒文件，按 principalId 分桶）；
  token/签名 URL **不进**该缓存、不进日志（AGENTS 硬边界 3）

## 8. 边界与文案

- **截断**：名字/邮箱/covaId 单行尾部截断（中文按字、英文按词，截断处 `…`）；
  导航项标签恒为固定短词不截断；AX 档下允许 2 行（§6）
- **零余额**：`creditsBalance = 0` → 余额胶囊显示「co 0」，副文案「余额为 0，创作与下载的扣费入口待合规开放」
  **不出现**（D12：App 内不作充值/购买引导，也不做负向催促话术）。零余额的**行为**提示只在
  09 计划卡启动时出现（见 `09-ai-session-detail.md` §8）
- **长邮箱**：优先显示 covaId（NEEDS 解锁后），否则邮箱中段省略（保留域名可见性由实现侧决定，
  规格只钉「不出现整行截断到无法辨识」）
- **套餐档位**：`free | creator | pro | enterprise` 四档中文分别「免费版 / 创作版 / 专业版 / 企业版」，
  与 13 会员页表头一致（唯一源在 `13-membership.md` §8）
- **并发冲突**：抽屉打开期间收到登出（他端吊销 / 401 刷新失败）→ G 区当帧回落未登录态，
  不弹额外提示（登出由 15 或全局会话层负责告知）
- **文案清单**（固定，禁改）：`主导航` / `我的资产` / `商业` / `首页` / `曲库` / `歌单` / `创作` /
  `收藏` / `我的歌单` / `我的创作` / `已下载` / `会员` / `企业服务` / `设置` /
  `登录解锁创作与收藏` / `先逛逛` / `未同步`

## 9. 验收判据

- [ ] 抽屉宽为屏宽 78%，右侧遮罩可点关闭；左缘右滑打开、遮罩左滑关闭，两条手势在真机不冲突
- [ ] 抽屉内**全部**颜色/圆角/间距/时长取自 token：截图逐区比对 tokens.json，无一处裸字面量；
      Dark/Light 仅切 token mode 即可两版皆正确
- [ ] 「创作」项为 `gradient.ai` 文字，其余任何导航项无渐变
- [ ] 未登录：G 区无余额胶囊与套餐徽标，登录主钮 + 「先逛逛」两枚控件；点登录进 10，点先逛逛关抽屉
- [ ] `me` 失败（断网/401）：导航项 100% 可用，G 区显「未同步」或整块降级，**无** Toast、**无**整屏错误
- [ ] 放行前 `已下载` 项在视图树与 VoiceOver 元素序列中均不存在（用辅助功能检查器取证）
- [ ] VoiceOver 从左→右、上→下顺序朗读，导航项整行单元素；AX5 档无横向溢出且组标题隐藏
- [ ] Reduce Motion 开启：抽屉出现无位移动画，遮罩一帧到位，功能无损失

## Token 缺口（待裁决，不写入 tokens.json）

| # | 缺口 | 本屏用法 | 建议（仅建议） |
|---|---|---|---|
| TG-01 | 无「抽屉宽/分栏比例」维度 | 78% 屏宽（inventory 钉死） | 新增 `layout.drawerWidthRatio`；G2 验收前按 78% 施工 |
| TG-02 | 无品牌 logo 显示尺寸档 | 顶栏 28pt（01 钉死） | 新增 `size.logo` |
| TG-03 | 无「最小触控目标」维度 | ≥44pt（AGENTS/inventory 通用要求） | 新增 `size.touchMin = 44` |
| TG-04 | 无描边/指示条宽度档 | 1pt 分隔线、2pt 选中指示条（components §7） | 新增 `border.hairline=1` / `border.indicator=2` |
| TG-05 | 无头像尺寸档 | 44pt（本屏）/32pt（01 顶栏）/64pt（01 音乐人） | 新增 `size.avatar.sm/md/lg` |
| TG-06 | 无骨架块宽度比例档 | 55%/35% 呼吸条 | 新增 `skeleton.width.*` 或规定「跟随真实布局」免档 |
| TG-07 | 无按钮高度档 | 主按钮 50 / chip 36（components §10 钉死） | 新增 `size.control.primary=50` / `size.control.chip=36` |
| TG-08 | 无遮罩（scrim）强度 | Light/Dark 遮罩不透明度 | 新增 `material.scrim.light/dark` |
| TG-09 | 无「数据新鲜度窗口」维度 | `me` 5min 缓存 | 属策略常量，建议归 `CovaCore` 配置而非 tokens（登记备查） |

## 待裁决（设计/契约）

1. **资产计数徽标无端点**：需要聚合计数（收藏/歌单/创作/下载）才可在抽屉显示，
   `docs/api-contracts.md` 无此端点 → v1.0 该位不渲染。建议登记 NEEDS（`DRAWER-ASSET-COUNTS`），
   **待 G1/G2 验收确认**。
2. **头像字段**：`AuthUser` 无 `avatar`（api-contracts §1）→ v1.0 用首字母占位。若产品要求真头像，
   需后端补字段，同 NEEDS-1 一并解决；**待用户裁决**。
3. **抽屉与 11「我的」的职责重叠**：本屏底部卡片 = 轻量入口，11 = 完整资产页。是否保留抽屉内余额胶囊
   （避免与 11 重复）**待 G1 验收时一并裁决**；当前规格保留（与 web 左栏用户区一致）。
