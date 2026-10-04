# Covalink iOS App 交接手册

**版本**: v0.2.81 / Build 100  
**基准日期**: 2026-10-01  
**架构模式**: SwiftUI + Swift 6 strict concurrency  
**状态**: P0–P3 主流程已闭环，部分扩展功能待开发（§5 P3 剩余 8 条线）

---

## 📦 一、项目概览

### 技术栈

| 层 | 技术选型 |
|---|---|
| **UI** | SwiftUI, @Observable root state |
| **State 管理** | `@mainactor AppSession` (AppSession.swift) |
| **Services** | Actor-based `CovaAPIClient`, dependency injection |
| **分层架构** | SPM packages: `CovaCore` / `CovaPlayer` / `CovaUI` / `CovaFeature` |
| **测试** | XCTest UI tests (`XCUITest` via simulator event injection) |
| **门禁系统** | `Scripts/check.sh` (10 steps: build→test→coverage→D12 scan) |

### 目录结构

```
Packages/
├── CovaCore/           # 核心模型、DTOs、API client
├── CovaPlayer/         # 音频播放引擎、上报逻辑
├── CovaUI/            # 通用组件库
└── CovaFeature/       # 特性层（业务逻辑、视图）
    ├── Sources/CovaFeature/
    │   ├── AppSession.swift              # Root state (app-wide state)
    │   ├── CovaRootView.swift            # Root view + preview routes
    │   ├── LoginAndMine.swift            # §5 P1-P2 / §7 #50/#53
    │   ├── PlazaAndSettings.swift        # §5 P3 #54 home materials rejected
    │   ├── PlaylistDiscovery.swift       # 每日/公共/共享三份 read legs
    │   ├── CheckinService.swift          # 每日签到服务 (GET+/POST)
    │   └── AgentRunRecovery.swift        # #52 恢复腿纯逻辑层
designs/screens/      # 逐屏规格（D17）
docs/acceptance/      # 设备侧验收证据（A1–A15）
Scripts/
├── check.sh          # 门禁脚本（构建→测试→覆盖率→D12 扫描）
└── d12-copy-check.sh # D12 禁词扫描器
project.yml           # 工程配置 + Changelog (0.2.78→0.2.81)
```

### 字节批次表

| 版本 | 建码 | 关键变更 |
|---|---|---|
| 0.2.78 | 97 | P1 创作台基础闭环 |
| 0.2.79 | 98 | §5 P3 第一条线：05 三源 + 24 分享歌单 |
| 0.2.80 | 99 | §5 P3 第二条线：me/checkin 每日签到 |
| 0.2.81 | 100 | #53 复证关闭、A14 账本更新到 20 屏成对 |

---

## ✅ 二、已交付清单

### P0 止血与基线

- ✅ A1 最近播放：`GET /api/play-history`混排展示
- ✅ A3 studio/create simple 模式 generate→jobId→轮询→渲染最小闭环
- ✅ A5/A6 作品播放上报、直存同源 intent=download 取字节（不放宽 D23）
- ✅ A12+A14 门禁全绿与截图证据
- ✅ 设备侧取证改走 XCUITest（绕过辅助访问权限问题）

### P1 创作台

- ✅ A7 works 列表屏 + 7 项行内动作
- ✅ P1-2 cover/extend/remaster 入口与请求字段
- ✅ P1-5 会话详情任务轮询 + agent-runs 回读对账

### P2 交付链

- ✅ A8 extras 母带/分轨 + artifacts 同源下载
- ✅ P2-1 producers 入口 + P2-3 ledger 明细页（A9/A10）
- ✅ §7 #50 extras 面板设备侧取数失败修复（curl 同 URL 200 ⇒ task id 自身取消模式）

### P3 新线（2026-09-27 交付）

#### §5 P3 第一条线：05 三源 + 24 分享的歌单

- **文件**: `PlaylistDiscovery.swift` (208 lines), `PlazaAndSettings.swift`
- **契约面**: 14 条用例验证 daily/public/shared三份 GET
- **判据面**: 7 条目的地判定（source 枚举而非猜测 unknown→.nowhere）
- **设备腿**: 模拟器预览键免点击导航（COVA_PREVIEW_PLAZA_SOURCE=daily|shared）
- **空态真相**: `GET /api/playlists/public` ⇒ `{playlists: []}`（生产尚无分享歌单）
- **交付范围**: 只读腿，write op (`POST /shared-playlists/[token]/claim`) 排除
- **未交付**: 下载格受 D12 约束，正常态证人缺 token（结构性问题）

#### §5 P3 第二条线：me/checkin 每日签到

- **文件**: `CheckinService.swift` (77 lines), `LoginAndMine.swift`
- **契约面**: 11 条用例验证 get/post/ledger
- **设备腿**: 点「签到领 10 co」⇒ 翻绿勾 + 「今天已签到」
- **服务端对账**: `+10 每日签到 19325`流水印证
- **Bug 暴露**: §7 #53 余额刷新延迟（force:true 修复）

### Bug 修复汇总

| Issue | 症状 | 根因 | 解法 |
|---|---|---|---|
| **#50** | extras 面板 offline msg，curl 200 | `.task(id: mutable_key)`读取自身修改⇒自取消 | 改用 `workExtrasReadKey(for:)` construction-time constants |
| **#52** | agent-runs poll 断腿 | decode 路径不一致/类型形状 mismatch | 纯逻辑层恢复 + `LossyPick` helper |
| **#53** | 签后余额不变 | loadMe()去重吞掉重读 | `session.loadMe(force: true)` |

---

## ⏳ 三、阻塞项与未交付

### §5 P3 剩余 8 条线（需先出规格 per G2 交付形态）

| 线号 | 功能 | 状态 | 阻塞原因 |
|---|---|---|---|
| **Inspiration Shop** | inspiration-shop | ❌ | D12 conflict（动态数据绕过扫描器） |
| **User Playlists** | user-playlists CRUD | ❌ | Needs editor spec |
| **Shared Playlists Claim** | claim write op | ❌ | Write gate closed v1.0 |
| **Agent v2** | agent-v2 endpoints | ❌ | 3 endpoints待实现 |
| **Cover/Jobs** | 封面/工单流程 | ❌ | 3 routes待开发 |
| **Voice Profiles** | voice-profiles 展示 | ❌ | 展示层需求待明确 |
| **Producers Process** | producers full process | ❌ | 5 routes待开发 |
| **Apple/SMS Auth** | 登录认证提交 | ⚠️ | Submisison guidelines待获取 |

### A14 深色档配对缺口（6 屏）

| 屏号 | 功能 | 依赖 |
|---|---|---|
| **06** | 官方歌单详情 | Need real playlist ID |
| **07** | 每日推荐详情 | Need real playlist ID |
| **09** | 作品详情 | Need real work ID |
| **16** | 会员权益 | Needs update |
| **12c** | 收藏操作 | Needs preview key |
| **17** | 生产工作流 | Needs preview key |

### 结构性缺口（无法模拟）

- **24 正常态**: 无生产 token（与 23/12d/18 同类问题）
- **18 创作者主页**: 需要 real user ID
- **播放详情页**: 需要 real playlist/work ID

---

## 🔧 四、开发与验收指南

### 环境准备

```bash
# macOS + Xcode 16+ (Swift 6)
xcrun simctl list devices available | grep "iPhone"
```

### 门禁运行

```bash
./Scripts/check.sh
# 10 steps: 
#  ① xcodebuild clean
#  ② xcodebuild build
#  ③ xcodebuild test (CORE/PLAYER/FEATURE)
#  ④ Coverage report
#  ⑤ D12 copy-check (禁词扫描)
#  ⑥ xcresult baseline alignment
#  ...
```

### 模拟器测试（免点击）

```bash
# Preview route keys (SIMTL_CHILD_ prefix)
export SIMTL_CHILD_COVA_PREVIEW_TAB=mine
export SIMTL_CHILD_COVA_PREVIEW_ROUTE=sharedPlaylist:abc123
export SIMTL_CHILD_COVA_PREVIEW_PLAZA_SOURCE=daily

# Launch with env injection (correct form)
env SIMTL_CHILD_COVA_PREVIEW_TAB=mine \
  xcrun simctl launch --console <bundle_id>

# Or XCUIApplication injection (simulator events)
xcrun simctl openurl booted <deep-link>
```

### 设备验收命令参考

```bash
# Daily playlists source
curl -s https://covalink.cn/api/playlists/daily | jq '{date, items_count: .items|length}'

# Public playlists (empty state proof)
curl -s https://covalink.cn/api/playlists/public | jq '.playlists|length'

# Checkin status
curl -s https://covalink.cn/api/me/checkin | jq '.'
curl -s https://covalink.cn/api/me/credits/ledger?limit=3 | jq '.'

# Extras (proves #50 fix)
curl -s -H "Authorization: Bearer $TOKEN" \
  https://covalink.cn/api/work-extras/[id] | jq '.keys|length'
```

### 截屏规范

- **光源/暗源**: 每屏配 pair（light + dark）
- **版本号证据**: 首次安装用 `plutil -extract Version raw Info.plist`钉批次
- **文件名格式**: `[屏号]-[场景]-{light,dark}.png`
- **弃用原则**: bad frames（环境变量错误形制如—setenv 位置错）不归档
- **账本记账**: A14 ledger now at **20 paired screens** (batch doc in README)

---

## 🚨 五、已知问题与决策记录

### §7 #50：Extras 面板取数失败（已修复）

**问题**: `workExtras.host`被 `.task(id:)`读取，SwiftUI 在 key 变化时 cancel in-flight GET

**证据**: curl 同 URL 200 vs device offline message

**修复**: `workExtrasReadKey(for:)` computed from immutable values (`user.id | host.cacheKey`)

**验证**: Device frame shows six selectable keys visible（正常态），非 offline msg

---

### §7 #53：签后余额刷新延迟（已修复）

**问题**: `loadMe()` dedupe guard swallow re-read after sign-in

**代码位置**: `LoginAndMine.swift` line ~200

**修复**: `session.loadMe(force: true)` bypass same-identity dedupe

**验证**: Next-day fresh capture shows 19325 matching server ledger (+10 daily sign-in)

---

### §7 #54：Home Materials 刻意拒绝接入（v1.0）

**原因**: Web delivers copywriting via dynamic data delivery; D12 scanner only sees source literals

**合规要求等待**: (a)iOS whitelist section_keys,(b)D12-approved copy review pass,(c)asset URL egress classification

**决策**: Not implemented until requirements met

**归档**: §7 issue #54 with rationale in `DEVELOPMENT.md`

---

## 📁 六、验收证据索引

### A14 Screens (20 paired = 40 frames)

Location: `docs/acceptance/a14-20260927/`

| 屏号 | 文件前缀 | 状态 |
|---|---|---|
| 01 | `01-home-{light,dark}.png` | ✅ Done |
| 02 | `02-player-{light,dark}.png` | ✅ Done |
| 03 | `03-library-{light,dark}.png` | ✅ Done |
| 04 | `04-drawer-{light,dark}.png` | ✅ Done |
| 05 | `05-plaza-{official,daily,shared}-{light,dark}.png` | ✅ Done (3×2=6) |
| 08 | `08-aiSessions-{light,dark}.png` | ✅ Done |
| 10 | `10-login-{light,dark}.png` | ✅ Done |
| 11 | `11-mine-{light,dark}.png` | ✅ Done |
| 12a | `12a-favorites-{light,dark}.png` | ✅ Done |
| 12b | `12b-myPlaylists-{light,dark}.png` | ✅ Done |
| 13 | `13-membership-{light,dark}.png` | ✅ Done |
| 14 | `14-enterprise-{light,dark}.png` | ✅ Done |
| 15 | `15-settings-{light,dark}.png` | ✅ Done |

**Remaining 6 pairs**: 06/07/09/12c/16/17（need real IDs or preview keys）

### P3 Evidence

Location: `docs/acceptance/p3-20260927/`

| 屏号 | 场景 | 证据文件 |
|---|---|---|
| 05 | Plaza three-sources switch | `05-plaza-{official,daily,shared}-{light,dark}.png` |
| 24 | Shared playlist bad token | `24-shared-playlist-bad-token-{light,dark}.png` |
| 11 | Checkin row flip | `11-mine-checkin-{light,dark}.png`, `25-checkin-{before,after,tap}-{light,dark}.png` |

---

## 🔐 七、GitHub 仓库推送

当前本地 commits ready to push:

```bash
git log --oneline -5
# 0a759cf feat(#53): 补签 #53 的设备复证并关闭；更新 A14 账本到 20 屏成对
# 2884f02 fix(P3): §7 #53 的成因读代码定了 —— 签完那次 loadMe 被同身份合并吞掉，改 force: true
# ea2b74d docs(§5 P3 / §7 #53 #54): 签到那一行改成已交付并留下欠的那格
# 740d58c feat(P3): 第二条线 me/checkin 落地（11 的 C2 那一格）
# 36bd67a feat(P3): 第一条新线落地 —— 05 三源 + 新屏 24「分享的歌单」
```

**操作步骤**:

1. 在 GitHub 创建仓库：https://github.com/new
   - Repository name: `iOSApp`
   - Visibility: Private/Public
   - Don't initialize with README/.gitignore

2. 复制仓库 URL（应为 `https://github.com/YOUR_USERNAME/iOSApp.git`）

3. 执行推送:
   ```bash
   git remote set-url origin https://github.com/YOUR_USERNAME/iOSApp.git
   git push -u origin main
   ```

---

## 📞 八、联系方式与资源

### 后端真相源

- **URL**: https://covalink.cn
- **Web Repo**: `../web` directory contains Next.js API routes
- **API 查询工具**: `curl` for schema inspection before implementing

### 设计规范

- **逐屏规格**: `designs/screens/`目录下每个 `.md` 文件
- **验收标准**: 《A1–A15 Specification》文档
- **D12 合规**: 《D12 Copy Check Policy》禁词白名单

### 内部文档

- **DEVELOPMENT.md**: §5 P1–P3进度、§7 bug 追踪、门禁口径
- **AGENTS.md**: 子代理协作规则、预算/冲突策略
- **HANDOVER.md**: 本文档（交接手册）

---

## 🎯 九、下一步行动计划

### 短期（v0.3.0）

1. **补 A14 配对**: 6 屏深色档（优先 06/07 用于官方歌单深度使用）
2. **24 normal态证人**: 协调后端产分享 token（或接受 structural gap）
3. **Agent v2 endpoints**: 3 routes 落地（需 spec review）

### 中期（v0.4.0）

4. **Inspiration Shop**: 解决 D12 conflict（建议：静态文案预置 + runtime filter）
5. **User Playlists Editor**: 完整 CRUD spec + implementation
6. **Voice Profiles**: 展示层需求确认 → wireframe → code

### 长期（v1.0）

7. **Payment Gate**: D12 resolved + billing integration（收入型功能规划）
8. **Producers Full Process**: 5 routes end-to-end
9. **Apple/SMS Auth**: Submission guidelines compliance

---

**Last Updated**: 2026-10-01  
**Maintainer**: covalink-team @ GitHub  
**Repository**: https://github.com/covalink/iOSApp (pending creation)
