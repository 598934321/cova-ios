# AGENTS.md — Cova iOS 原生客户端

> 面向 AI 编码代理与接手开发者。根工作区总览见 `../../AGENTS.md`。

## 本仓是什么

Cova iPhone 原生 App（独立 git 工程）。工作流为闸门制：**G0 文档固化 → G1 Figma 方向稿 →
G2 Figma 完整设计 → G3 核心层 → M1–M3 功能里程碑 → G4 发布门**。当前处于 G0/G1。

先读三份文件再动手：`docs/PLAN.md`（总计划）、`docs/PRD.md`（产品定义）、
`docs/decisions.md`（锁定决策 D1–D12）。

## 硬边界（踩过坑的规矩，违反即返工）

1. **只改本仓**。不得修改生产服务器、线上 env/DB、相邻仓（`多端/web`、`多端/mobile`、
   `cova api` 等）。
2. **网络出口唯一**：只访问 `https://covalink.cn` 的 HTTPS API。禁止直连 `cova api`
   （127.0.0.1:3110 provider 网关）、禁止 mock 假数据冒充线上行为（开发期契约 mock 仅限
   本地 JSON，且不得进入验收环节）。
3. **凭证安全**：token 存 Keychain（`ThisDeviceOnly`）；token/密码/签名 URL 禁写日志、
   禁入持久化索引；任何密钥不进 git。
4. **零第三方依赖白名单**：初始为空。新增任何 SwiftPM/CocoaPods 依赖须先获用户批准，
   并登记 `docs/decisions.md`。
5. **扣费与写操作必带幂等键**（下载 checkout、计划启动、播放上报）。
6. **双 Demo 终态硬规则**：一步模式只取前两个候选，两个都 settled（ready+URL 或 failed）
   才算终态；私有音频必须先 Bearer 下载到沙盒校验非空，再以 `file://` 播放。
7. **后端缺口登记制**：接口缺字段/缺端点/契约不符 → 写 `docs/NEEDS.md`，不得自己改后端。
8. **设计闸门**：G1/G2 未经用户验收 Figma 稿，不写对应 UI 代码。如获批准偏离，登记
   `docs/decisions.md` 并限期补验。
9. **App Store 合规（D12）**：v1.0 不含任何购买/充值入口，仅展示余额；下载扣费 UI 入口
   待合规评审后开放。

## 工具链约定

- Xcode 26.6+，XcodeGen（`project.yml` 是唯一工程事实源，`*.xcodeproj` 不入 git）。
- 门禁脚本：`Scripts/check.sh` = xcodegen 重新生成 + Debug 构建 + 全量 XCTest
  （G0 时创建；核心层测试覆盖目标 ≥80%）。
- 部署目标 iOS 26（D1），Swift 6 严格并发检查。
- 每次 commit 递增 `project.yml` 中的 `CFBundleShortVersionString`/`CFBundleVersion`
  （小迭代 +0.0.1 / 大迭代 +0.1，对齐主仓版本惯例）。
