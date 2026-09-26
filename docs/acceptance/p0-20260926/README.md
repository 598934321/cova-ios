# P0 止血 · 设备侧走查（2026-09-26）

产物来源：commit `80af455`（`0.2.71(88)`），`bash Scripts/check.sh` ⇒ **GATE_EXIT=0**
（CovaTests 2 / CovaCoreTests 745 / CovaFeatureTests 104 / CovaPlayerTests 483，
failed=skipped=0，三个下限与实测恰好相等；CovaCore 4197/4387=95.67%、
CovaPlayer 3806/4000=95.15%；D12 面 175 个 .swift 全量归因）。

设备：iPhone 17 Pro 模拟器（iOS 26.5，1206×2622）。
安装包与构建产物**逐字节一致**（`Cova.debug.dylib` md5 `b1652b88c974f60d2706c2506e618fdc`，
构建目录与已安装容器两侧同一枚 md5）；当批符号在该 dylib 内可查
（`StudioCreateView` 7 处、`WorkDownloadStore` 4 处、`PlayHistoryItemDto`/
`StudioCreateRejection`/`studio-create-generate`/`cova-work-downloads` 各 1 处）。

## 这一组里有哪两张

| 文件 | 屏 | 这一张能证明什么 |
|---|---|---|
| `19-studio-create-light.png` | 19 创作台（浅色） | 屏真的存在且渲染：导航标题「做一首歌」、B 描述卡（占位文案 + `0/2,000` 计数）、C 主 CTA **空输入即不可点**（disabled 形态、无解释文案）。D 任务区与 E 结果区**不渲染** —— 未提交就不该有它们 |
| `19-studio-create-dark.png` | 19 创作台（深色） | 同一屏深色档：canvas / elevated 卡 / accent 按钮三档色都由 token 双值解决，无专属深色底（19 §5） |

登录走的是既有的**只读进程环境**钩子（`COVA_PREVIEW_LOGIN_EMAIL/PASSWORD`，
真跑两步 `/login` → `/me`，口令刻意不落 `UserDefaults`）。
19 屏靠本轮补的 `COVA_PREVIEW_ROUTE=studioCreate` 到达（`simctl` 不给点击，
与钩子 3/4 的既有理由同源）。

## 这一组里**没有**的，以及为什么（不许用文件名替像素说话）

A1/A3/A5/A6 的**设备侧判据全部未完成**，缺的是同一个动作：**点击与滚动**。

- 本会话的宿主进程没有「辅助访问」权限 ⇒ `cliclick` 报
  `Accessibility privileges not enabled`、AppleScript 报
  `“Qoder”不允许发送按键 (-25211/1002)` ⇒ 无法点「开始生成」/▶/↓，也无法滚动。
- 因此下面这几条**只到"逻辑层已测 + 生产端点已核"，没有屏上证据**：
  - **A1**：`GET /api/play-history` 已接通并解码（生产实测该账号 4 条库曲行、
    `work` 行 0 条），但「继续聆听」这一栏在 01 折叠线**以下**，本环境滚不到 ⇒
    没有"屏上出现真条目"这张图；
  - **A3**：轮询两端点已用真实 job 核过形状（`generation-jobs?id=` → `{job}`、
    `status=succeeded`、`costCredits=315`；`works?id=` → 2 行、`status` 均 `succeeded`），
    但**没有点过生成钮** ⇒ 未产生任何新任务、未扣费（余额实测仍为 19515）；
  - **A5**：`work_listens` 上报的 body 形状与幂等账在用例里钉死，
    但没播放过 ⇒ 服务端 `GET /api/play-history` 的 `work` 行数仍是 0；
  - **A6**：直存腿有 23 条用例（含"生产 `playbackUrl` 落在名单外的 uploads 桶 ⇒ 点名拒"），
    但没点过 ↓ ⇒ 沙盒 `Documents/Cova/cova-work-downloads/` 至今不存在。
- 顺带抓到一条**取证环境自身的坑**（值得记，因为它差点变成假证据）：
  第一次拍 `01-home-light.png` 拍到的是**艺人详情页**（上一次会话留在
  `UserDefaults` 的 `COVA_PREVIEW_ROUTE=artist:A09`）。文件名当时已经写好了。
  ⇒ 读图之前，文件名不算证据；本轮已把那两个遗留键删掉。

## 复核路径（拿到辅助访问权限后照做即可）

1. `SIMCTL_CHILD_COVA_PREVIEW_LOGIN_EMAIL=… SIMCTL_CHILD_COVA_PREVIEW_LOGIN_PASSWORD=…
   SIMCTL_CHILD_COVA_PREVIEW_ROUTE=studioCreate xcrun simctl launch <udid> cn.covalink.ios`
2. 点描述卡 → 输入 prompt → 点「开始生成」→ 拍 D 区（`排队中/制作中` + 不确定条 + 计时）
   → 等 `succeeded` → 拍 E 区两行（A3）
3. 点某行 ▶ → `curl -H "Authorization: Bearer $T" '…/api/play-history?limit=50'`
   应出现 `trackId=<jobId>:<candidateId>` 且 `track.workId` 非空的那一行（A5 + A1 混排）
4. 点该行 ↓ → `xcrun simctl get_app_container <udid> cn.covalink.ios data` 下
   `Documents/Cova/cova-work-downloads/<owner hex>/<jobId>-<candidateId>.mp3` 非 0 字节，
   `afinfo` 时长与 `duration` 一致；`GET /api/me/credits/ledger` **行数不变**（A6）
5. 01 滚到「继续聆听」拍混排那一张（A1）
6. 取证脚本已在 `/tmp/cova-verify.sh`（`ph` / `ledger` / `sandbox` / `all` 四个子命令，
   只打印键名、计数、状态码与本机文件名，不打印 token 与签名串）
