# P0 设备侧验收（2026-09-26）

产物来源：commit `80af455` 之上的工作树（含 A1 的 bootstrap 修复与验收 target），
版本 `0.2.71(88)`；门禁复跑结果见本目录末尾「门禁」。
设备：iPhone 17 Pro 模拟器（iOS 26.5，1206×2622），账号 `opencode@test.com`（口令不落盘）。

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
| `19-studio-create-light.png` / `-dark.png` | **A14 双主题**：同一屏深浅两档，色值全部走 token 双值 | — |

## 未证，以及为什么（这条是本轮最有价值的产出）

**A5（作品播放上报）与 A6（作品直存）在 iOS 上今天做不到，根因在后端的签名主机，不在本仓。**

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
