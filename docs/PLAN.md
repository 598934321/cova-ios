# PLAN — Cova iOS 原生 App 总体计划

> 版本：v1.0（2026-09-17 固化）。本文档是本仓最高计划；变更需更新本文件并登记
> `decisions.md`。

## 0. 调研依据

| 来源 | 结论 |
|---|---|
| 本仓 | 零提交重建（原工程 2026-09 中旬清空）。本机工具链：Xcode 26.6 + xcodegen + swift CLI |
| `多端/mobile`（RN/Expo 版） | 功能蓝本完整：4 Tab、Bearer+SecureStore 认证、SSE 优先+轮询降级、双 Demo 终态硬规则、私有音频「先授权下载再本地播」、幂等键。其 `NEEDS.md` 11 项后端阻塞全部继承（见本仓 `docs/NEEDS.md`） |
| 品牌规范（`cova ip/` + web `globals.css`） | 产品 UI accent = 日落橙 `#FF6B00`；AI 渐变橙→树莓；Apple 风双主题中性色；圆角 12/18/28 + 胶囊；AppIcon 全套已就位（已复制到 `design/assets/`） |
| iOS 27（WWDC 2026） | Liquid Glass 精修版（材质不透明度可调、图标更锐利）；Siri AI + App Intents 一等公民。设计语言 = 玻璃材质、悬浮层、大圆角、流体动效 |
| DeepSeek iOS | 极简聊天 UI：左侧抽屉（历史+设置）、底部输入框、深度思考可展开 → 映射为本 App 抽屉导航 + SSE `thinking` 展示 |
| Suno 移动端 | 首页 = 顶部创作输入框 + 歌单/推荐 feed 结合体；生成结果双卡并列 |

同构参照：`多端/mac app`（G0–G4 闸门制 + 文档体系）、`词格本/docs/PRD-iPad原生-v1.0.md`
（SwiftUI + XcodeGen + SwiftPM 本地包分层 + 零第三方依赖白名单 + 纯逻辑层全 XCTest）。

## 1. 阶段与闸门

### G0 — 文档固化与工程骨架（0.5–1 天）

- [x] 文档包落盘：`PLAN.md` / `PRD.md` / `decisions.md` / `NEEDS.md` / `api-contracts.md` /
      `design-language.md` / `release-runbook.md` / `design/` 全套
- [x] 工程骨架：XcodeGen `project.yml` + SwiftPM 本地包 + 空 App 可构建 +
      `Scripts/check.sh` 绿灯 + 首个 commit（`3bbb99a`→`2591238`，8 轮隔离评审后
      0 Critical / 0 Major 通过；证据见 `docs/log/20260917.md` 环 5）
- **闸门**：用户批准 D1（部署目标 iOS 26+）与 D12（合规策略）——**2026-09-17 已批准** ✅

### G1 — Figma 设计方向稿（2–3 天）

- 产出：`design/tokens.json`（已完成，Figma Variables 可导入）+ 3 张关键屏详稿规格
  （`design/screens/01-home.md` / `02-player.md` / `03-library.md`，已完成）
- 操作：设计师/用户在 Figma 按规格搭建方向稿（流程见 `design/README.md`）
- **闸门 G1**：用户验收方向稿。未验收不写 UI 代码

### G2 — Figma 完整设计（3–5 天）

- 按 `design/screens/inventory.md`（约 18 屏）+ `design/components.md` 完成全部屏幕与
  组件库；深浅双主题、Reduce Motion 变体、动效说明
- **闸门 G2**：用户验收完整设计

### G3 — 核心层实现（3–4 天，可与 G2 部分并行）

- CovaCore：DTO（对齐 `api-contracts.md`）、API client（15s 超时、single-flight refresh）、
  SSE 解析器、幂等键、Keychain 封装、owner 绑定持久化
- CovaPlayer：队列 / 循环三态 / ±15s / 锁屏控制（MPRemoteCommandCenter）/ 播放上报去重
- CovaUI：tokens→Swift、玻璃材质组件、动效
- 门禁：XCTest 全绿（核心层 ≥80% 覆盖）+ `check.sh` 成型
- Bearer 契约未就绪期间用本地契约 mock 开发，不碰线上账号行为

### M1 — 发现与播放闭环（1–2 周）

- 抽屉导航、首页 feed（推荐歌单/继续聆听/场景精选）、曲库（三级级联筛选+搜索+分页）、
  歌单详情、邮箱密码登录、MiniPlayer+全屏播放器（歌词静态展示）、收藏（曲目/歌单）
- **验收**：匿名浏览 → 登录 → 筛选 → 播放 → 锁屏控制 → 收藏，全链路真机通过

### M2 — Cova AI 创作闭环（1–2 周）

- 会话列表/详情、SSE 对话流 + thinking 展示、计划确认卡（12 态）、双 Demo
  （试听/收藏/分享）、补充制作进度、本地通知（生成完成深链回会话）
- **验收**：「找歌」「做歌」双意图全链路、断网降级、幂等防重

### M3 — 资产与打磨（约 1 周）

- 下载管理（合规放行后开放 UI）、会员展示、AI 音乐人专栏、空态/错误态/骨架屏、
  可访问性（Dynamic Type / VoiceOver）、性能（首屏与滚动 60fps）

### G4 — 发布门（约 1 周）

- 按 `docs/release-runbook.md` 执行：check.sh 全绿 + 真机矩阵（iPhone 三档尺寸 ×
  iOS 26/27）→ TestFlight 内测 → 用户验收 → App Store 提审

**总计预估 6–9 周**（设计 1.5–2 周 + 开发 4–5 周 + 发布 1 周；后端阻塞项未就绪会顺延
M1/M2 验收）。

## 2. 风险与合规

| 风险 | 应对 |
|---|---|
| Apple IAP：co 币充值/下载扣费属数字商品，app 内售卖须走 IAP 否则拒审 | D12：v1.0 零购买入口，仅展示余额；后续评估 IAP 或网页购买合规话术 |
| 版权表述 | App 内「版权说明」跳 `covalink.cn/licensing` |
| Bearer 契约未就绪（NEEDS-1） | G3 用本地契约 mock；NEEDS 跟踪；不伪造线上数据 |
| iOS 26+ 砍掉旧机用户 | 新 app 无存量包袱；iOS 27 已发布，26+ 是绝对主流。如需覆盖旧机走备选 D1'（iOS 17+ 自制玻璃，+1–1.5 周，观感降级） |
| 设计闸门被跳过（mac app 有先例） | 坚持 G1/G2 验收；偏离须批准并登记 |

## 3. 质量门

- 口径：**Build → Verify → Commit**，每步留证据。
- `Scripts/check.sh`：xcodegen 重新生成 → Debug 构建 → 全量 XCTest。
- 测试重点（均可纯逻辑测试，RN 版有对等矩阵可移植）：SSE 解析与降级、双 Demo 终态
  判定、幂等键、refresh 竞态、owner 绑定隔离、播放上报去重。
- 产品级验收走 `测试/` 目录流程（真人版/AI 版问卷）。
