# release-runbook.md — 发布门（G4）

> 原则：fail-closed；任何一步不过就停，修好后从头重跑。无自动更新、无线上回滚。

## 1. 门禁（本地）

```bash
Scripts/check.sh   # xcodegen 重新生成 → Debug 构建 → 全量 XCTest（核心层 ≥80%）
```

全绿后递增版本号（`project.yml`：小迭代 +0.0.1 / 大迭代 +0.1）并 commit。

## 2. 构建与签名

- Release Archive（Xcode 26.6+，iOS 26 SDK）
- 签名：Apple Distribution 证书 + App Store Connect  provisioning（bundle id 见 D13）
- 产物：`.ipa` + SHA256 记录 + dSYM 归档

## 3. 真机矩阵（TestFlight 前）

| 机型档 | 系统 | 必过项 |
|---|---|---|
| 小屏（iPhone mini/SE 档） | iOS 26 | 首页/抽屉/播放器/曲库/创作主链 |
| 中屏（标准 Pro 档） | iOS 26 + iOS 27 | 同上 + 深浅主题 + Reduce Motion |
| 大屏（Pro Max 档） | iOS 27 | 同上 + Dynamic Type 最大档抽查 |

主链：匿名浏览 → 登录 → 筛选播放（锁屏控制/后台播放）→ 收藏 → 会话找歌 →
会话做歌（计划卡→双 Demo→试听收藏）→ 登出换号隔离。

## 4. App Store 资料清单

- [ ] bundle id 注册（建议 `cn.covalink.ios`，D13）
- [ ] AppIcon：使用 `design/assets/CovaAssets.xcassets`（勿改）
- [ ] 隐私清单（Privacy Manifest）：声明网络/Keychain/本地通知用途；隐私政策 URL
- [ ] 截图与预览：6.7"/6.5"/5.5" 三档，首页/曲库/播放器/创作 4 组
- [ ] 文案：名称/副标题/描述/关键词（「AI 音乐」「商用授权」「BGM」）
- [ ] 年龄分级问卷；版权说明页可达（`covalink.cn/licensing`）
- [ ] **合规自检（D12）**：二进制内无购买/充值入口；无 IAP 之外的数字商品售卖暗示
- [ ] 账号删除端点已上线并可演示（NEEDS-4，审核必查）
- [ ] 审核备注：提供演示账号；说明「试听免费、生成需登录、无应用内购买」

## 5. 提审与发布

TestFlight 内部测试 → 用户验收（真人版测试流程 `文档/测试流程-真人版.md`）→
提审 → 通过后手动发布。审核被拒：逐条对应修复，重跑本门。
