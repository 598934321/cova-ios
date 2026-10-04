# Cova iOS 接手手册

> 给下一个接手这仓的人：读完这份就能开工。版本账与逐日发布内容看
> `CHANGELOG.md`；设计闸门、契约口径、已知后端缺口的权威文档是
> `DEVELOPMENT.md`（868 行，不要跳读）。

**版本**：0.3.4 / Build 106（`project.yml:217-218`）
**基准日期**：2026-10-04
**最低系统**：iOS 26（原生 Liquid Glass）
**架构**：SwiftUI + Swift 6 strict concurrency + XcodeGen（`project.yml` 是工程
唯一事实源，`*.xcodeproj` 不入 git）+ 4 个本地 SwiftPM 包

---

## 一、30 秒上手

```bash
# 1. 确认工具
xcodegen --version || brew install xcodegen
xcodebuild -version

# 2. 全量门禁（这条命令 = 构建 + 全测试 + 覆盖率 + D12 禁词 + 依赖白名单）
bash Scripts/check.sh
# EXIT=0 才算过；任何一步红就停，别绕过。

# 3. 跑应用（模拟器）
xcodebuild -project Cova.xcodeproj -scheme Cova \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

⚠️ **跑 `check.sh` 之前先 `git status` 确认工作树干净**：第 3/10 步的 D12 自检
会往 `Cova/CovaApp.swift`、`AccountDeletionDTOs.swift`、`project.yml`、
`MembershipAndEnterprise.swift` 植诱饵再按 md5 复原——与别人的编辑并发会互相盖。

---

## 二、这仓是什么

Cova（CovaLink）AI 音乐商用授权平台的 iPhone 原生 App——「会创作、可授权的
音乐流媒体」：网易云式发现播放 × Suno 式一句话创作 × 音乐 Agent（找歌/做歌
同一会话入口）× co 币商用授权闭环。

**iOS v1.0 范围**（现状）：

- 原生五页签外壳（TabView + 每页签独立 `NavigationStack`，2026-10-01 由
  抽屉壳改造，10-02 再加 `Tab(role:.search)` 系统搜索位）：首页 / 曲库 /
  创作 / 我的 + 搜索。
- 首页对话型（底置 `CovaComposer` 输入条，生成/搜索两档）。
- 曲库多维筛选 / `.searchable` / 分页；官方歌单、每日推荐、歌单广场、
  分享歌单（只读）。
- 曲目收藏 + 生成 note 双账分流；邮箱密码两步登录。
- AVPlayer 自研播放层（队列/循环三态/±15s/锁屏/后台播放）+ 播放上报。
- 一步创作（会话 / SSE / 计划卡 12 态 / 双 Demo 终态规则 / 候选收藏）。
- studio/create 高级创作台（simple/advanced/melody 三模式、cover/extend/
  remaster、works 列表、extras 补充制作、producers 入口、credits 明细）。
- **StoreKit 2 内购**（会员订阅 4 档 + co 包 3 档，`/api/iap/products|verify`）。
- **账号删除**（`POST /api/auth/delete-account`，5.1.1(v) 合规）。

**v1.0 不做**：远程推送（本地通知兜底）、iPad 专版、灵感商店（D12 合规未放行）。

---

## 三、信息都在哪里（别再问）

| 你要找什么 | 去哪里 |
|---|---|
| **权威开发手册**（硬边界 9 条、API 契约实测卡、验收判据 A1–A15、
  后端缺口 §7、技术债清单） | `DEVELOPMENT.md` |
| **设计 token 单一事实源** | `design/tokens.json` → `Packages/CovaUI` |
| **逐屏规格**（UI 改动必须先改这里的规格，设计闸门） | `design/screens/*.md` |
| **组件规格**（TrackRow/PlanCard/MiniPlayer 等） | `design/components.md` |
| **每日工作日志**（哪批改了什么、踩了什么坑） | `docs/log/YYYYMMDD.md` |
| **版本更新账**（每个版本干了什么） | `CHANGELOG.md` |
| **验收截图证据**（A14 口径：每屏深浅成对，逐张读过） | `docs/acceptance/<批次>/` |
| **门禁脚本**（10 步：构建→测试→覆盖率→D12→基线） | `Scripts/check.sh` |
| **测试数基线**（只升不降） | `Scripts/test-count-baseline.env` |
| **工程配置**（版本号、target、签名） | `project.yml` |
| **后端契约真相源**（别凭记忆写契约） | `../web/src/app/api/**/route.ts` + `src/lib/` |

---

## 四、硬边界（违反即返工，DEVELOPMENT.md §2 同文）

1. 只改本仓；不碰生产 env/DB/服务器与相邻仓（`../web` 只读引用）。
2. 网络出口唯一 `https://covalink.cn` HTTPS；写/扣费端点未获批准不调。
3. token 存 Keychain（`ThisDeviceOnly` + principalId）；token/密码/签名 URL
   禁写日志、禁入持久化索引。
4. 零第三方依赖白名单（当前为空）；新增须批准并登记决策。
5. 扣费与写操作必带幂等键（`Idempotency.swift` 登记新 operation）。
6. 双 Demo 终态硬规则：一步模式只取前两候选，双双 settled 才终态；私有
   音频先 Bearer 下载沙盒校验非空再 `file://`。
7. 后端缺口登记制：缺字段/缺端点/契约不符记入 §7，客户端不得自行改后端。
8. **设计闸门**：UI 改动先改 `design/screens/` 规格，经确认后再写码。
9. **D12 合规**：App 内购买只走 StoreKit 2；不出现任何站外购买引导
   （「前往官网/充值/App 内不售卖」词表由 `d12-copy-check.sh` 机械执行）。

**协作约定**：Build → Verify → Commit，每步留证据；纯文档不递增版本号，
影响产物的递增 `project.yml` 两个版本字段（小 +0.0.1 / 大 +0.1）。

---

## 五、分层架构与代码地图

```
Packages/
├── CovaCore/    # 纯逻辑层（平台中立：禁 UIKit/SwiftUI/#if；全 XCTest）
│   CovaEnvironment.swift   出口守卫（仅 covalink.cn + sanctionedStorageHosts）
│   CovaAPIClient.swift     get/post/patch/delete + Bearer + 401 single-flight
│   AuthSession.swift       signed-out/guest/authenticated；refresh 旋转
│   *DTOs.swift             Auth/Library/Collection/OneStep/Generation/IAP/
│                           AccountDeletion/StudioCreate/PlayReport/SSE
│   SSEStreaming.swift      SSE 传输 + HTTPOneStepPlanPoller
│   OneStepStream.swift     SSE→轮询降级状态机（10s 首事件/30s 静默/3 坏事件/EOF
│                           + pollFailureCount）
│   OneStepThinkingCopy.swift  thinking 公开短语白名单（web 同构表）
│   OneStepPlanFailureCopy.swift 余额拒绝词表 + 零余额话术
│   Idempotency.swift       IdempotencyKey + IdempotentRequestToken
│   SecureStore/KeychainStore/OwnerScopedStorage/SessionLifecycle
├── CovaPlayer/  # AVPlayer 播放层（禁 UI import：Foundation/AVFoundation/
│                # MediaPlayer/CovaCore 白名单）
│   PlayReportCoordinator.swift  播放上报去重（一次播放一键）
├── CovaUI/      # tokens→Swift、Liquid Glass 组件、骨架/空态/徽标
│   CovaTokens.swift    dynamicAlpha（8 位 hex）、selectedBg、focusRing
│   CovaComponents.swift CovaButton（primary=中性液态玻璃、.brand=hero CTA
│                        渐变胶囊）、CovaChip、CovaCard、CovaTagChip
│   CovaStates.swift     CovaErrorState、骨架条、CovaPixelCover
└── CovaFeature/ # 各屏 + 业务服务
    AppSession.swift            Root state（@MainActor @Observable）
    CovaRootView.swift          Root view + preview routes
    HomeView.swift              01 对话型首页（CovaComposer）
    HomeComposer.swift          底置输入条组件
    SearchTabView.swift         25 搜索页签（.searchable）
    LibraryView.swift           03 曲库级联筛选
    PlazaAndSettings.swift      05 歌单广场三源 + 15 设置 + 11 我的
    LoginAndMine.swift          10 登录 + 11 我的（签到/余额/Cova 号）
    WorksListView.swift         20 作品列表
    StudioCreateView.swift      19 高级创作台
    StudioService.swift         studio 端点收口 + classify
    StudioViews.swift           PlanStatusCopy / RunLineCopy / TranscriptLine
    AISessionDetailView.swift   09 会话详情（2313 行，本屏独立容器族）
    CollectionsViews.swift      收藏/歌单/我的创作/下载（12a–d）
    MembershipAndEnterprise.swift 13 会员 + 14 企业
    IAPService.swift            StoreKit 2 购买 + verify + 恢复
    AccountService.swift        账号删除（performCoded + 五档分流）
    CatalogService.swift        目录/收藏/歌单类型化访问
    ArtistHomeView.swift        16 音乐人主页
    DetailViews.swift           06/07/17 详情屏
    PlayerViews.swift           02 播放器 + 迷你条 + tabViewBottomAccessory
    ProducersPanelView.swift    23 制作人入口面板
    CreditsLedgerView/Flow      22 co 明细
    WorkExtrasPanelView/Flow    21 补充制作
    AgentRunRecovery.swift      #52 断流恢复纯判据层
    CheckinService.swift        每日签到
    PlaylistDiscovery.swift     每日/公共/共享三份 read legs
```

**测试基线**（`Scripts/test-count-baseline.env`，只升不降）：
CovaTests 2 / CovaCoreTests 956 / CovaFeatureTests 314 / CovaPlayerTests 483。
新增测试 → 对应 MIN 抬到实测值。

---

## 六、还没做完的（下一轮的账）

### 上架阻塞（P0）

- **§7 #56 IAP 核销链**：`verify` 的 production 分支恒拒（x5c 验签未接）、
  生产下沙盒不可达、ASSN 通知无端点、productId 权威清单——**验签未上线前
  内购只能灰度内测，不上架**。
- **A4/A10 设备证据结构性拿不到**：402 档要零余额账号、producers 非空档
  要服务端灰度（判据已降级 + 替代证据登记）。

### 功能性缺口（后端，§7 待答）

- #57 消息侧 `workflowMode`（`POST /api/studio/agent` 不收 mode）。
- #30 候选级 retry 端点（「重试」现为只读对账，不能重跑失败候选）。
- #45/#47 extras POST 无幂等键 + 不按键集去重（扣费路径缺协议保证）。
- #46 作品级补充制作生产上恒被取消（A8 产物字节拿不到）。
- #48 `.mp3` 硬编码后缀（字节对、后缀错）。
- NEEDS-23/24 会话条目 schema / 分享短链；09 待裁决 3/4/6（轮询上限/
  只补做一版/title.candidates）。

### 端侧待办（小账）

- #51 `.cancelled` 仍被 `classify` 折进 `.network`（真取消时说「离线」）。
- #18 类注释漂移（5 处把屏 22 叫「积分流水」，规格名是「co 币明细」）。
- 09 屏登录态截图（无 `COVA_ACCEPT_*` 凭证，屏上证据待真机/验收腿）。
- A14 缺的 6 屏深浅配对（06/07/09/16 要真数据 id、12c/17 要预览键）。
- 24 分享歌单正常态（生产无 token，结构性缺证人）。

### 技术债（DEVELOPMENT.md 末尾清单）

TD-41~TD-50 十条（禁 UI 白名单不拦反射、锁屏命令真机冒烟、`@unchecked
Sendable` SAFETY 标记、CovaUI/CovaFeature 无测试 target、骨架五族、
证据纪律等）。

---

## 七、开发时的坑（都踩过了，别再踩）

- **`check.sh` 的 D12 自检会改源码**：植诱饵 → 扫描 → md5 复原；并发编辑
  会互相盖。跑之前确认 `git status` 干净。
- **TextField `.onSubmit` 不走 `canSend`**：发送闸要落在 `submit` 行为层
  不是按钮态（09 屏的教训）。
- **`xcodebuild` 不把普通环境变量转给测试运行器**：XCUITest 要 `TEST_RUNNER_`
  前缀；少了就用例 `XCTSkip` 但 `xcodebuild` 仍报 SUCCEEDED——验收必须读
  `xcresulttool get test-results summary`，不许读最后一行。
- **截图要钉字节**：A14 的账是「每屏深浅成对 + 钉在同一批字节上」；屏没变、
  代码变了、图还是旧的 = 悄悄失效。
- **`simctl` 不能点击**：要点击走 XCUITest（独立 scheme `CovaAcceptance`）；
  不要点击的屏用 `SIMCTL_CHILD_COVA_PREVIEW_*` 环境变量 + `simctl io
  screenshot`（零扣费）。
- **`project.yml` 里 `CFBundleShortVersionString` 与 `CFBundleVersion` 都要动**。
- **门禁产物保真会读版本号**：`check.sh` 4/10 步打印 `cn.covalink.ios
  X.Y.Z(N)`，截图验收时核对这个数对不对得上。

---

## 八、联系与真相源

- **后端**：`https://covalink.cn`（生产）；`../web`（Next.js 源码，契约
  唯一事实源）。
- **本仓 git**：无 remote（不 push）；提交惯例是叙事式中文 message
  （conventional 前缀 + 版本号 + 证据段）。
- **设计**：`design/` 仓内规格（无 Figma 外部依赖）；token 改动双端同步
  （`tokens.json` → `CovaUI/CovaTokens.swift`）。

---

**接手三件事**：
① `bash Scripts/check.sh` 看绿不绿；
② `git log --oneline -5` + `docs/log/` 最新一份看上一批干了什么；
③ `DEVELOPMENT.md` §7 看后端欠的账。
