# Covalink iOS App 交接 Prompt

## 📌 核心目标

**当前状态**: v0.2.81 / Build 100，P0–P3 主流程已闭环  
**短期目标**: 补 A14 配对 + 解阻塞 §5 P3 剩余 8 条线  
**中期目标**: v0.4.0 完成 Inspiration Shop + User Playlists Editor  
**长期目标**: v1.0 收入型功能 gate 通过后上线支付流

---

## 🔥 优先级最高任务（本周执行）

### #16 补 A14 双主题（6 屏深色档）

**依赖**: 模拟器预览键改造或真实 ID

| 屏号 | 屏名 | 问题 | 解决方案 |
|---|---|---|---|
| 06 | 官方歌单详情 | Need real playlist ID (`/playlists/[id]`) | 从 `GET /api/playlists/daily`取 items[0].href 提取 id |
| 07 | 每日推荐详情 | Need real playlist ID | 同上，daily API 返回的私藏分享歌单即可 |
| 09 | 作品详情 | Need real work ID | 从 home works 列表截图中提取任一 work.id |
| 12c | 收藏操作 | Needs preview key | 新增 `COVA_PREVIEW_FAVORITES_MODE=add`注入 |
| 16 | 会员权益 | Needs update | 查 Web repo `/api/membership`响应形状重绘 |
| 17 | 生产工作流 | Needs preview key | 新增 `COVA_PREVIEW_WORKFLOW_STAGE=mastering` |

**执行步骤**:
```bash
# 1. 找真实 ID（以 06 为例）
curl -s https://covalink.cn/api/playlists/daily | jq '.items[0].href'
# ⇒ "/playlists/abc123def" → extract "abc123def"

# 2. 构造预览 launch 命令
env SIMTL_CHILD_COVA_PREVIEW_ROUTE="playlist:abc123def" \
  xcrun simctl launch --console <bundle_id>

# 3. 截图并命名
cp screenshot.png docs/acceptance/a14-20260927/06-playlist-detail-dark.png

# 4. 重复 light mode（切换设备 darkContentScheme）
```

**验收标准**: 
- 每张图按「屏 × 批次」记账到 README.md
- light/dark pair 齐全（文件名带 `{light,dark}`后缀）
- 版本号证据钉在首次安装截图

---

### #24 解决 24 正常态证人（结构性缺口）

**问题**: 生产无分享歌单 → 无 token → 无法演示正常态

**方案 A（推荐）**: 协调后端发一枚 share token
```bash
# 请求示例（需 web team 协助）
POST /api/shared-playlists (write op)
Body: {playlistId: "public-daily-2026-09-27", visibility: "public"}
→ 返回 token: "xyz789"

# 然后模拟
env SIMTL_CHILD_COVA_PREVIEW_ROUTE="sharedPlaylist:xyz789" \
  xcrun simctl launch --console <bundle_id>
```

**方案 B（接受 gap）**: 写 spec 注释说明结构性限制
```markdown
> **Note**: Normal state cannot be demonstrated on device without production share tokens.
> Contract tests pass (14用例), but device evidence deferred until backend enables shares.
```

**决策**: 优先方案 A，若 backend 一周内无法提供则降为方案 B 并更新文档

---

## ⚠️ 阻塞项深度分析（需突破）

### §5 P3 Inspiration Shop（D12 conflict）

**根因**: Web 通过 dynamic data delivery 注入 copywriting，D12 scanner 只扫描 source literals → 直接渲染会绕过合规 gate

**现状**: iOS 端 ready to render（已有 placeholder view），但被 D12 策略卡住

**突破方案 3 选 1**:

#### 方案 1: Static Copy Whitelist（推荐）
- **做法**: 预置一套 approved copy 在 code bundle 中，runtime filter 决定显示哪套
- **优点**: D12 可扫描静态字符串，完全合规
- **缺点**: 运营改文案需发版（周级周期）
- **可行性**: ⭐⭐⭐⭐⭐ 立即执行

#### 方案 2: Runtime API Fetch
- **做法**: 首屏 fetch `/api/inspiration-copy`（后端预存 approved 版本）
- **优点**: 运营可热更文案
- **缺点**: D12 可能 still complain（网络请求内容无法静态分析）
- **可行性**: ⭐⭐⭐ 需 D12 policy clarification

#### 方案 3: Asset URL Egress Classification
- **做法**: 把 copy 拆成 CDN-hosted images/text files，iOS 端引用外部 URL
- **优点**: Source literals 只有占位符，D12 pass
- **缺点**: 第三方存储 egress 需 classification review
- **可行性**: ⭐⭐ 审批周期长

**建议**: 先实施方案 1（static whitelist），同时向 compliance team 申请方案 2/3政策澄清

---

### §5 P3 Share Claim Write Operation（Gate Closed）

**问题**: `POST /api/shared-playlists/[token]/claim` endpoint exists but gated in v1.0

**原因**: 涉及 credits deduction → D12 revenue features require additional review

**绕行方案**: 
```swift
// PlaylistDiscovery.swift line ~150
if source == .shared && claimsDisabled {
    // Render disabled state instead of tappable card
    DisabledPlaylistCard(token: token)
}
```

**状态**: Documented in code comments, awaiting v1.0 gate approval

---

## 🎯 §5 P3 其余 8 条线开发顺序建议

### Phase 1: Non-D12 Conflict Lines（Week 1–2）

#### #1 会话详情的 Agent v2（3 endpoints）
**优先级**: ⭐⭐⭐⭐⭐  
**依赖**: 前端已实现 agent-runs polling（#52 恢复腿），仅需扩充 v2 schema

**实施步骤**:
```swift
// Packages/CovaFeature/Sources/CovaFeature/AgentRunRecovery.swift
extension AgentRunDto {
    static func decodeV2(from json: Data) throws -> AgentRunV2Dto {
        // Add new fields: {duration, cost, outputs: [output1, output2]}
    }
}
```

**验收**: Contract tests 新增 6 用例（v2 schema decoding + validation）

---

#### #2 User Playlists CRUD（需 editor spec）
**优先级**: ⭐⭐⭐⭐  
**阻塞**: 缺少 editor UI spec（create/edit/delete workflows）

**行动项**: 
1. Design team 输出 figma specs（参考 24 shared detail 布局）
2. DTOs 确认 add/update request shapes
3. Implementation with optimistic UI updates

**预计工期**: 5 days（含 design review）

---

### Phase 2: Media Assets（Week 3）

#### #3 Cover/Jobs（3 routes）
**优先级**: ⭐⭐⭐  
**依赖**: D12 policy for media uploads（是否算 third-party egress?）

**路由表**:
```
POST   /api/works/[id]/cover      ← upload image
GET    /api/jobs/active           ← list remix tasks
POST   /api/jobs/[id]/accept      ← claim task
```

**风险**: Image upload requires storage bucket credentials（AWS S3?）

---

#### #4 Voice Profiles（展示层）
**优先级**: ⭐⭐  
**需求**: 仅 read-only display of user voice settings

**API**: `GET /api/user/voice-profile`

**实施**: Simple SwiftUI Form with switch toggles

---

### Phase 3: Full Workflows（Week 4+）

#### #5 Producers Process（5 routes）
**优先级**: ⭐⭐  
**复杂度**: High（multi-step workflow: submit → review → publish）

**建议**: 推迟到 payment gate通过后（避免多 feature 并发）

---

#### #6 Apple/SMS Auth（submission guidelines）
**优先级**: ⭐  
**阻塞**: 等待 Apple Developer Program submission requirements

**Action**: Read《Apple Authentication Integration Guide》, prepare app private key

---

## 🧪 测试覆盖指南

### 门禁基线对齐

**文件**: `Scripts/test-count-baseline.env`

当前值:
```
CORE_MIN=927  (#52/#53/#54 added 26 tests)
FEATURE_MIN=258 (playlist discovery checks added 14)
PLAYER_MIN=483 (stable)
APP_MIN=2 (stable)
```

**规则**: 
- 每次添加新功能需递增对应 MIN 值
- justification 段落必须写在注释中解释新增数量
- PR check 时自动对比 baseline env + actual coverage

---

### 设备侧取证原则

**黄金法则**: 「选择器/观测量必须来自设备 dump 而非读源码」

**示例**:
```swift
// ❌ Wrong: Hardcoded identifier from source analysis
expect(text("Sign In Button").exists).to(beTrue())

// ✅ Right: Device-derived observable
expect(staticTexts.containing("签到领 10 co").firstElement.waitForExistence(timeout: 5))
    .to(beTrue())
```

**工具**:
```bash
# Dump device tree
xcrun simctl spawn booted dyld_print_dylibs

# Inspect accessibility hierarchy
xcuitest debug --target "<bundle_id>" --dump-tree
```

---

## 🔐 合规注意事项（D12 Scan）

### 禁词白名单（UI 层不得出现）

| 禁词 | 替代方案 | 适用功能 |
|---|---|---|
| "购买" / "Purchase" | "获取" / "Get" | 所有付费相关 UI |
| "订阅" / "Subscribe" | "升级" / "Upgrade" | 会员权益页（13） |
| "充值" / "Top-up" | "领取" / "Claim" | 余额卡片、签到行 |
| "价格" / "Price" | "成本" / "Credits" | 任何计费描述 |

**扫描命令**:
```bash
./Scripts/d12-copy-check.sh
# 检查范围：Packages/CovaFeature/Sources/**/*.swift
# 排除：DTOs（数据本身不算违规）
```

**注意**: 动态数据（API response）不受 D12 约束，仅 scan source literals

---

## 🚀 构建与部署

### Xcode 项目结构

**Root**: `project.yml` (SPM workspace)

**Packages**:
- `CovaCore/`: Core models + DTOs + API client
- `CovaPlayer/`: Audio engine + analytics上报
- `CovaUI/`: Shared components (Loaders, Cards, Chips)
- `CovaFeature/`: Feature logic + views (+ tests)

**Build Command**:
```bash
xcodebuild clean build \
  -workspace Cova.xcworkspace \
  -scheme Cova \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

---

### Changelog 递增规则

**文件**: `project.yml` → `changelog` section

**格式**:
```yaml
changelog:
  - version: 0.2.82
    date: 2026-10-08
    changes:
      - feat(A14): Add dark theme pairs for screens 06/07/09
      - fix(#24): Resolve structural gap for shared playlist normal state
```

**递增原则**:
- **纯文档不递增** (README/DEVELOPMENT.md updates)
- **影响产物才递增** (代码变更、新视图、API integration)

---

## 📞 紧急联系人

| 角色 | 责任人 | 领域 |
|---|---|---|
| Backend Lead | @web-team | API schema changes |
| Compliance | @d12-owner | D12 policy questions |
| Design | @figma-team | Screen specs |
| QA | @test-automation | Device lab access |

---

## 🎬 快速启动 Checklist

**新人上手三步**:

1. **Clone & Setup**:
   ```bash
   git clone https://github.com/covalink/iOSApp.git
   cd "ios app"
   brew install swiftlint  # Optional linting
   ```

2. **Read Critical Docs**:
   - `HANDBOOK.md` (本项目全貌)
   - `DEVELOPMENT.md` (§5 P1–P3进度 + §7 bug log)
   - `docs/acceptance/p3-20260927/README.md` (最新交付证据)

3. **First Task Assignment**:
   - Start with **#16 A14 pairing** (most isolated, 1 screen ≈ 2 hours)
   - Then tackle **#24 structural gap resolution** (coordination heavy)
   - Finally pursue **Phase 1 features** (agent-v2, user playlists)

---

**Last Updated**: 2026-10-01  
**Maintainer**: covalink-ios-team  
**Status**: Ready for handoff to next developer
