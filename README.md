# Cova iOS 原生客户端

> Cova（CovaLink）AI 音乐商用授权平台的 iPhone 原生 App。
> 定位：**会创作、可授权的音乐流媒体** —— 网易云音乐（歌单发现与沉浸播放）× Suno（一句话创作）× 音乐 Agent（找歌/做歌统一会话入口）。

## 当前阶段

**G0 已完成（2026-09-17）；G1 待用户验收 Figma 方向稿**。G0 交付工程骨架：XcodeGen
`project.yml` + 四个本地 SwiftPM 包（CovaCore / CovaPlayer / CovaUI / CovaFeature）+ 门禁
`Scripts/check.sh`（构建 + XCTest + 核心层覆盖率 + 依赖与平台中立性校验），锁定决策
D1/D12 已获用户批准。G1 起的设计/UI 代码须待 Figma 方向稿验收后开工。开发从阅读
`docs/PLAN.md` 开始，严格按闸门制推进。

## 文档索引

| 文件 | 内容 |
|---|---|
| `docs/PLAN.md` | **总计划**：调研依据、阶段闸门 G0–G4、里程碑 M1–M3、风险与合规 |
| `docs/PRD.md` | 产品需求：定位、信息架构、功能清单、范围边界 |
| `docs/decisions.md` | 锁定技术决策 D1–D15（未经批准不得偏离） |
| `docs/NEEDS.md` | 后端协作需求（阻塞项登记，**不允许客户端自行改后端**） |
| `docs/api-contracts.md` | 后端 HTTP API 契约参考（端点 + 数据模型字段） |
| `docs/design-language.md` | iOS 27 Liquid Glass × Cova 品牌设计语言映射 |
| `docs/release-runbook.md` | 发布门：构建门禁 → TestFlight → App Store |
| `design/README.md` | 设计工作流（Figma 闸门 G1/G2 操作方式） |
| `design/tokens.json` | 设计 token 单一事实源（Figma Variables / Swift 双端消费，深浅双主题） |
| `design/screens/` | 屏幕规格：`01-home` / `02-player` / `03-library` 为 G1 详稿，`inventory.md` 为全屏清单 |
| `design/components.md` | 组件库规格（TrackRow / PlaylistCard / MiniPlayer / PlanCard 等） |
| `design/assets/CovaAssets.xcassets/` | 官方 AppIcon 全套（源自 `cova ip/03_logo/platforms/canonical-v1/`，勿改） |

## 技术速览（详见 decisions.md）

SwiftUI + Swift Concurrency · iOS 26+（原生 Liquid Glass）· XcodeGen（`project.yml` 入 git）·
SwiftPM 本地包分层（CovaCore / CovaPlayer / CovaUI / CovaFeature）· **零第三方依赖白名单** ·
AVPlayer 自研播放层 · Bearer + Keychain 认证 · SSE 优先 + 轮询降级 · 仅访问 `https://covalink.cn`

## 协作硬边界

见 `AGENTS.md`。要点：只改本仓；不碰生产服务器/线上 env/DB；凭证不入库不写日志；
扣费写操作必带幂等键；后端缺口一律登记 `docs/NEEDS.md`。
