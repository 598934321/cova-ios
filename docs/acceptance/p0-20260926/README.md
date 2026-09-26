# P0 设备侧验收（2026-09-26）

产物来源分**三批字节**，逐文件标注（A14 要求"截图批次必须同 commit 字节"，
不同批的图不能互相顶替）：

| 批次 | 字节 | 本目录里的文件 |
|---|---|---|
| 12:18 | `0.2.71(88)`（A1 的 bootstrap 修复**之前**） | `19-studio-create-light.png`、`19-studio-create-dark.png` |
| 16:10–16:40 | `0.2.72(89)` = HEAD `08767d9` | `01-recent-history-light.png`、`19-form-light.png`、`19-task-polling-light.png`、`19-results-light.png` |
| 18:13–18:16 | 同上（`-derivedDataPath /tmp/cova-accept-dd`，18:13 重新链接产物，且仓库内无 `.swift` 比它新 ⇒ 确为 HEAD 字节） | `01-recent-history-dark.png`、`19-form-dark.png` |

设备：iPhone 17 Pro 模拟器（iOS 26.5，1206×2622），账号 `opencode@test.com`（口令不落盘）。
深浅档走 `xcrun simctl ui <udid> appearance dark`（app 内主题档位是「跟随系统」，
`cova.themeMode` 没写进 UserDefaults ⇒ 翻完外观不留任何 app 侧残留，拍完已翻回 light 并核对过 plist）。

取证方式：**XCUITest**（`CovaAcceptanceTests/P0AcceptanceTests.swift`，独立 scheme
`CovaAcceptance`）。为什么不是"人工点一下"：驱动本机会话的进程没有 macOS「辅助访问」权限
（`cliclick` 报 `Accessibility privileges not enabled`、AppleScript 报 `-25211/1002`），
`simctl` 不提供点击，装 idb/appium 会破零第三方依赖（硬边界 4）。
XCUITest 的事件注入发生在模拟器内 ⇒ 不需要宿主权限，且**可复现**。

```
# A1（不花钱，可反复跑）
TEST_RUNNER_COVA_ACCEPT_EMAIL=… TEST_RUNNER_COVA_ACCEPT_PASSWORD=… \
TEST_RUNNER_COVA_EXPECT_TITLES="$(curl -s -H "Authorization: Bearer $T" \
  'https://covalink.cn/api/play-history?limit=50' | python3 -c '…逐条 titleCn…')" \
xcodebuild test -project Cova.xcodeproj -scheme CovaAcceptance \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CovaAcceptanceTests/P0AcceptanceTests/testRecentHistoryRendersServerRows
```

⚠️ **`TEST_RUNNER_` 前缀是必须的**：`xcodebuild` 不把普通环境变量转给测试运行器。
少了前缀 ⇒ 用例走 `XCTSkip`，而 xcodebuild 照样打 `** TEST SUCCEEDED **`
（本轮第一次跑就"绿"过一次，是 `xcresulttool` 的 `skippedTests=1` 揭穿的）。
⇒ 这条链只认 `xcrun xcresulttool get test-results summary`，不认 xcodebuild 的最后一行。

## 已证

| 文件 | 判据 | 屏外对账 |
|---|---|---|
| `01-recent-history-light.png` | **A1**：「继续聆听」渲染服务端 play-history 的 **5/5 条**（未寄出的冬天 / Morning Leash Parade / 粉墙初晴 / Woven Map Awakens the Clocktower / Woven Balloon），逐条点名断言（`testRecentHistoryRendersServerRows` passed，15.8s） | `curl GET /api/play-history?limit=50` ⇒ `ITEM_COUNT=5 KIND_TALLY work=0 library=5`，与屏上逐条对齐。**每行副标题都带时长（02:01…02:59）—— 本机账 `RecentPlayRow` 回落分支刻意不给 `duration` ⇒ 时长出现在屏上本身就是"这一份来自服务端"的判别** |
| `19-form-light.png` | 19 空表单：占位文案、`0/2,000` 计数、CTA disabled 形态；D/E 区不渲染 | — |
| `19-task-polling-light.png` | **A3 中段**：「本次任务 / 制作中 已等 00:34 / 不确定条 / 本次消耗 100 co」，CTA 在途不可点 | 提交确实发生：ledger 由 6 条 → **7 条**，新行 `reason=studio_create_generation`（扣 100 co，非 315 —— 315 是账号里那条旧 one-step 账） |
| `19-results-light.png` | **A3 终态**：「已完成 · 本次消耗 100 co」+「作品（2）」两行（Boardwalk After Hours 03:52 / 03:57，各带 ▶ 与 ↓），CTA 转「再做一首」 | `GET /api/studio/create/works?limit=3` ⇒ 新 job `c7fe0807-…` 两行 `status=succeeded`、`source=studio-create`；`generation-jobs?id=` 亦回 `{job}` 且 `status=succeeded` |
| `19-studio-create-light.png` / `-dark.png` | 19 屏深浅两档（**12:18 旧批次**，早于 A1 的 bootstrap 修复）：色值全部走 token 双值 | — |
| `01-recent-history-dark.png` | **A14 深色档**：与 `01-recent-history-light.png` 同一屏同一份数据，「继续聆听」5 行全在（未寄出的冬天 / Morning Leash Parade / 粉墙初晴 / Woven Map Awakens the Clocktower / Woven Balloon），各带时长；近黑底 + 白字 + 橙强调，无一处硬编码色 | 同一次 `testRecentHistoryRendersServerRows`（**passed 21.4s**，`xcresulttool`：`passed=1 failed=0 skipped=0`）的逐条点名断言，判据与浅色那张同源 |
| `19-form-dark.png` | **A14 深色档**：19 空表单（占位文案、`0/2,000`、CTA disabled 形态、D/E 区不渲染），与 `19-form-light.png` 同屏对照 | 零扣费：`COVA_PREVIEW_ROUTE=studioCreate` 只 push 路由，不提交 |
| —（无截图：这一条是服务端不变式，屏上不体现新信息） | **A11 幂等两层去重** + **A3 的 curl 半条**（「复用同 idempotencyKey 重放 → 同 jobId 且余额不二次扣」）。生产实测三连，同一 prompt：① `key=K1` 首次 ⇒ `{ok:true, jobId:3b4f59bc…, charge:100}`；② **`key=K2`（不同键、同指纹、10min 内）** ⇒ **同一个 jobId**；③ **`key=K1` 重放** ⇒ **同一个 jobId** | **ledger 只多一条**：`-100`，余额 `19415 → 19315`（三次提交、一次扣费）。⚠️ 顺带抓出一条契约缺口并登记 **§7 #40**：重放响应里**没有** `idempotentReplay` 键，而 `charge` 三条都回 100 —— 它回的是"这一单的价格"不是"本次新扣了多少"，所以"没扣"这件事只能从 jobId 相等 + 余额推出，19 屏的「本次消耗」文案在同指纹换键这条路上会说错（待办已记） |

## A14 覆盖到哪、还差什么（不写成"已齐"）

P0 这两屏（01 继续聆听、19 做一首歌）**浅/深各一图，且都在 HEAD 字节上** ⇒ §6 A14 对
P0 涉及的屏成立。两条边界要说清：

- 19 的**中途态**（任务卡 + 不确定条）与**终态**（作品两行）只有浅色。拍深色要再提交一次
  生成 = 再扣 100 co，而 A14 的判据是"每屏"双主题、不是"每个状态"双主题 ⇒ 这一笔不花，
  状态级的颜色证据由 `CovaTokens` 的动态 provider（单测覆盖）+ 表单屏的双档实拍承担。
- 其余各屏的双主题不在 P0 范围内。如实说现状：`docs/acceptance/wave-20260925/` 那 28 张
  是**浅色档 + 字号档**走查，没有深色配对 ⇒ 那 20 屏的 A14 仍欠，按各自里程碑补。

**静态屏（不需要点击的那批）走的是另一条更便宜的路**，不必动用 XCUITest：

```
SIMCTL_CHILD_COVA_PREVIEW_LOGIN_EMAIL=… SIMCTL_CHILD_COVA_PREVIEW_LOGIN_PASSWORD=… \
SIMCTL_CHILD_COVA_PREVIEW_ROUTE=studioCreate \
  xcrun simctl launch --terminate-running-process <udid> cn.covalink.ios
xcrun simctl io <udid> screenshot /tmp/shot.png
```

⚠️ **`sleep 9` 之后拍到的是一张首页**：`CovaRootView.task` 是 `bootstrap → 真登录 → 才
path.append(route)`，登录那两步没回来之前路由还没 push（约 1 分钟后再拍才落到 19）。
⇒ 这条链不能按固定 sleep 收判据，**每拍一张都要读图**（本轮差点把那张首页存成 `19-form-dark.png`）。
翻外观前后各读一次 `appearance` 与 app 的 plist，确认没把 `cova.themeMode`
或 `COVA_PREVIEW_*` 留在沙盒里（`previewRoute()` 会回读 UserDefaults，残留会污染下一次启动）。

## 未证，以及为什么（这条是本轮最有价值的产出）

> ⚠️ **本节原来的结论已被同日推翻**，保留原文以免"改了就当没发生过"。
> 原文写的是「A5/A6 在 iOS 上今天做不到，根因在后端的签名主机」——**错了**：
> 我只试了服务端签发的那一条 `intent=play`。同一个 `ref`、同一台 host 换 `intent=download`
> 是 **200 `audio/mpeg`、5,315,422 B、零跳转**（服务端 `media/objects/[id]/route.ts:127`
> 那个 `intent !== 'download'` 的分支；web 侧自己的下载链就走这条）。
> ⇒ 根因在**客户端挑错了 intent**，不在后端。已修于 commit `59500c5`
> （`CovaEnvironment.workAudioDirectFetchURL`，**D23 名单一个字都没放宽**），档案更正见 §7 #39。
> 下面这段"没有放宽名单"的决定**当时是对的**（在没有安全结论前不放开用户私产桶），
> 但它掩盖了"再试一个参数就行"这个更便宜的解释 —— 教训记进 [[feedback-verify-own-claims-before-archiving]]：
> 判据卡在外部系统时，先把**同一台机器的其它形状**试完，再宣布"等别人改"。

**A5 / A6 现状**：解阻，设备侧待验收 —— 验收腿改骑 works 列表屏（对**已存在**的作品行点 ▶/↓ ⇒ 零扣费）。

### 原文（2026-09-26 16:40 那次判读，保留）

- 现象：点 ↓ 后标记不翻成「已在本机」，180s 超时（`testStudioCreateLoop…` 红在第 151 行）。
- 直接取证（只读 GET，只打状态码与落地 host，不打签名串）：
  ```
  GET https://covalink.cn/api/media/objects/mo_f12d83ad…   (带 Bearer)
  → 302  Location host = covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com
  ```
  而 §3/D23 的存储名单只有 `covalink-covers-…` 与 `covalink-audio-…`（**刻意不含 uploads，
  那是用户私产桶**，web 侧正因为这点被否过一次）。
- 于是两条腿同时断：
  · **播放**：`audioUrl` 是生产出口 ⇒ 带 Bearer 发出 ⇒ 302 落在非名单桶 ⇒
    `mediaHopEgress` 判 `.refused` ⇒ `PrivateAudioFetcher` 回 `.hostRejected` ⇒
    引擎没出声 ⇒ 集次上报不发生 ⇒ `work_listens` 不增长（实测 `KIND_TALLY work=0`）。
  · **直存**：`WorkDownloadStore` 同一条 D23 规则 ⇒ 同一处拒 ⇒ 沙盒无文件。
- 这与 **NEEDS-29 是同一族**（"有权益整曲 302→COS ⇒ 客户端按 D23 拒 ⇒ 放不出来"），
  只是这次落在作品上、且落的是名单外的那个桶。已登记 **§7 #39**。
- **我没有去放宽名单**。把 `covalink-uploads-…` 加进 `sanctionedStorageBuckets` 会让这条链
  立刻"变绿"，但那是在没有安全结论的前提下把一个用户私产桶变成凭证可落地的出口 ——
  要后端改签 `covalink-audio-…`（已在名单）或给出该桶的公开/私读语义结论，再动 D23。
- 连带影响：**A1 的"混排含 work 行"这一半也没拿到屏上证据**（01 那 5 行全是库曲行）。
  逻辑侧是有证的：`PlayHistoryDTOTests` 用真实 work 投影（22 键、`bpm/artist/favoriteCount`
  为 null、`waveformPeaks` 空）钉住"库曲 DTO 直解必抛 ⇒ 整份历史全丢"，
  以及裸 jobId 行按 `workId` 认出、标为不可播。缺的只是"服务端真有一条 work listen"。

## 门禁

`bash Scripts/check.sh` 的复跑结果记在 commit message 里（本轮改了 `AppSession.bootstrap`、
`StudioCreateView` 的两个 accessibilityIdentifier 与 `project.yml` 的新 target ⇒ 必须重跑）。

## 已知测试侧噪声（不影响判据，但影响"再跑一次"的稳定性）

- 软件键盘的**候选栏会吞掉一部分点击**：A3 那张 `19-results` 顶部计数是 76/2,000 而非 53，
  因为后续点击把键盘候选词追加进了输入框。判据（两行结果、扣费、状态名）不受影响。
- `typeText` 打不出中文、`⌘V` 在软件键盘下无效 ⇒ A3 的 prompt 用 ASCII。
  A3 的判据是"填 prompt → 生成 → 两首"，与语言无关；要测中文得先解决输入通道，不是换断言。
