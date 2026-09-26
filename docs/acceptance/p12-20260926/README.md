# P1/P2 设备侧验收（2026-09-26）

产物字节（**两批，每张图各归各的批**）：
- 批一：app 二进制链接于 2026-09-27 03:24（= commit `1e1a7ec` 的应用代码；其后的
  `ce2de7c` / `c3d0487` 只动 `CovaAcceptanceTests`，不随 app 出货）⇒ 20、22 那几张。
  门禁：`bash Scripts/check.sh` 在 `1e1a7ec` 上 ✅ 全部通过 —— 四个 target
  `CovaTests 2 / CovaCoreTests 901 / CovaFeatureTests 242 / CovaPlayerTests 483`，
  全部 `failed=0 skipped=0`，基线与实测**恰好相等**；覆盖率 CovaCore 5468/5799=94.29%、
  CovaPlayer 3806/4000=95.15%；D12 禁词 0 命中。
- 批二（本轮补的三张）：**0.2.77/95**，app 二进制链接于 2026-09-27 04:52
  （`plutil` 读 `Cova.app/Info.plist` 的 `CFBundleShortVersionString=0.2.77` / `CFBundleVersion=95`
  核过，不是按 commit 推的）⇒ `21-extras-light.png` / `21-extras-dark.png` /
  `20-disliked-favorite-withdrawn.png`。门禁：同一批字节上 `bash Scripts/check.sh` ✅
  （`CovaTests 2 / CovaCoreTests 902 / CovaFeatureTests 242 / CovaPlayerTests 483`，
  全部 `failed=0 skipped=0`，基线与实测恰好相等；覆盖率 94.29% / 95.15%；D12 禁词 0 命中）。
  这一批改的是 §7 #50（21 面板那一发 GET 的自我取消），所以 21 的正常态只有从这批字节起才拍得出来。
设备：iPhone 17 Pro 模拟器（iOS 26.5，1206×2622），账号 `opencode@test.com`（口令不落盘）。

取证方式与上一轮相同（XCUITest + 不需点击的屏走 `simctl launch`），
两条链的坑都写在 `DEVELOPMENT.md` §6.1。

## 已达（逐条：判据 → 走过哪条路径 → 屏外对账）

| 判据 | 屏上证人 | 屏外对账 |
|---|---|---|
| **A5** work_listens 上报 | `20-after-play.png` / `20-after-listen.png`：对**已存在**的作品行点 ▶，MiniPlayer 走到 `mm:ss` 在走那一态（不是停在「加载私有音频中…」） | `GET /api/play-history?limit=50` ⇒ `ITEM_COUNT 35，WORK ROWS 1`，`trackId=3b4f59bc…:ae4b0454…`、`track.workId` 非空、`source=player`。**零扣费**（这一条不新建生成任务） |
| **A1** 混排（库曲 + 作品） | `01-recent-history-light/dark.png` 之外，本轮把逐条点名的期望值抬到**全部 35 条**标题（含那条作品行），滚动预算 14→34 后 passed | 与上面同一份 curl；行数一致是断言本身，不是"看到区块标题" |
| **A6** 作品直存 | `20-saved.png`：点 ↓ 后那一枚翻成绿勾 + toast「已在本机」；深色档 `20-works-list-dark.png` 里同组两行都留痕 | 走的是 §7 #39 那条同源 `intent=download`；ledger 无新增扣费行（19315 不变） |
| **A7**（部分，见下）行内动作的作用域 | `20-group-menu.png`：组头 ⋯ 里 job 级三项齐、每句都带「本次生成的作品」；`20-row-menu.png`：行 ⋯ 只有 clip 级 + 21 的入口，**没有**那三项 | 点 ♡ 后 `GET works?id=<伪id>` 回 `favorited=true / disliked 缺键`，`GET /api/favorites` 多出 `note:c325ba9d…` 一条（正是判据那句「出现 note 条目」）；点「歌词」⇒ `GET works/{id}/timing` 回 `lrc` 非 null、52 行。**dislike 那一半本轮补了专门一条腿**（`testWorksListDislikeWithdrawsTheFavorite`，批二）：先把 ♡ 钉成点亮态（服务端 `setWorkFavorite(true)` 顺手删 dislike 行 ⇒ 起始态确定），行 ⋯ 点「不喜欢」⇒ 判据原句"收藏被撤"的屏上证人就是 ♡ 由实心翻成描边（`20-disliked-favorite-withdrawn.png`，与上一帧同一行「Harbour at… 04:03」）⇒ 再开一次 ⋯ 断标签翻成「不喜欢（已选）」并点回去复位（撤点踩**不**还原收藏，所以 `started` 为真时再补一次 ♡）。屏外对账在 web 仓：`src/lib/studio/create/work-actions.ts` 的 `setWorkDislike` 明写"喜欢/点踩互斥：点踩时撤掉该 clip 的收藏" |
| **A9** ledger 页 | `22-credits-ledger-light.png` / `-dark.png`：`±amount reasonLabel 余额 balanceAfter 时间`，同一屏同时有「任务」与无「任务」两种行 | 「任务」跳 20 的 job 锚定态由设备腿证明（passed 19.5s）。§7 #38 同日已被服务端修好：17:19 那条新行带 jobId，更早的行仍 null ⇒ 两种形态都是真数据，不是构造 |
| **A11** 幂等两层去重 | 无截图（服务端不变式，屏上不体现新信息） | 同一 prompt 三连（K1 首发 / K2 换键同指纹 / K1 重放）⇒ 三次同一个 jobId `3b4f59bc…`，ledger **只多一条** -100（19415→19315）。顺带抓出 §7 #40：重放响应没有机器可读标记，`charge` 三条都回 100 |
| **A14** 双主题 | 20、22 两屏深浅各一图（批一，同一批字节）+ **21 两屏深浅各一图（批二）**：`21-extras-light.png` / `21-extras-dark.png` 都是面板的**正常态**（「可以再做的」+ 六枚 key：母带 WAV / 分轨 / 人声分轨 / 伴奏 / 歌词时间轴 / 歌词视频 + 置灰的主钮「开始补充制作」）；深色档由 `simctl ui appearance dark` 翻（app 档位是「跟随系统」⇒ 沙盒零残留，拍完已翻回 light） | 两张各自跑过一条腿：批二 light `passed=2 failed=0 skipped=0`（21 + dislike）、dark `passed=1 failed=0 skipped=0`。**一句口径要说清**：断言里的「这里不消耗 co」在主钮**下方**（21 §3.H），这一帧的可视区没到那里 ⇒ 它取的是元素树，不是像素；失败态那张里这一句整个不存在，所以断言不是恒真 |

## 未达 / 降级（每条都写清缺的是哪一格、为什么）

**A7 只剩 `share` 那一半没做**：只证到"入口在、状态读得到"（`GET …/share` 回
`enabled=false / sharePath=null`），**没有真的 POST 开一条公开链接** —— 那会在生产上留下一个
免登录可听的 URL，属于对外可见的副作用，留给人工裁决。（`dislike` 那一半本轮已闭合，见上表
A7 行末；它不需要人工裁决，因为点踩/收藏都是账号内的读态，且腿跑完自己复位。）

**A8 卡在服务端**（§7 #46）：`POST works/{id}/extras {keys:["wav","stems"]}` 回 200 两行
`补充制作准备中`、**无 url**、不扣费；每 20s 复列，约 6 分钟后两行都翻成 `已取消`。
两次独立提交、换第三行只提交 `wav`，同结局 ⇒ 不是"没等到"。
已达的一半：请求形状 / 两条腿的字段差（作品级无 `deliveryRevision`、不计价）/ pending 不渲染保存钮 /
`已取消` 如实上屏。未达的一半：「files 含母带 wav 与分轨 zip」与产物同源 200 流的下载腿 —— **没有 url 就没有下载腿可验**。
另记 §7 #47：同键集再 POST 返回的是**全新 artifact id** ⇒ A8 那句"幂等不重复制作"只在读一侧成立。

**A10 只有空态这一半**（§7 #44）：生产 `PRODUCER_MODE` 未设 ⇒ 恒 `{producers:[]}` ⇒
「+」入口整个不出现（这正是判据要的"不可见，不是置灰"）。非空那一半只有 fixture 单测 +
代码路径，**没有屏上证人**；要它出现需要服务端把账号加进灰度名单，是一行配置不是契约缺口。

**A4 的 402 档**（§7 #43）：要屏上出现那句必须服务端真回 402，测试号 19315 co / 单次 100 co
⇒ 花光要提交约 190 次；造零余额号又要注册端点（生产没有）。400 档同样不可达（空 prompt 本地就拦）。
判据降级为：信封与文案的对应由单测证，屏上只有"本地拦"那一格看得见。

**21 屏的 A14 已经补齐**（`21-extras-light.png` + `21-extras-dark.png`，批二 0.2.77/95）。
上一版这里写的是"只拿到失败态那一张"：腿跑通了、面板开出来了，但那一发
`GET works/{伪id}/extras` 在设备上被判成网络失败（屏上「离线：补充制作需要联网」+「补充制作没取到」），
而同一条 URL 用同一份 Bearer 从 curl 打是 **200**（裸 `:` 与 `%3A` 都 200）⇒ 登记为 **§7 #50**。
本轮定因：**不是网络、不是编码、不是登录态，是面板把自己那一发请求取消了** ——
`.task(id:)` 的键读了 `openWorkExtras` 自己会写的那份状态 ⇒ 键中途变化 ⇒ SwiftUI 取消这次任务
⇒ `CovaAPIError.cancelled` 被 `classify` 折进 `.network` ⇒ 屏上说了句不是事实的「离线」。
修法与证据都在 §7 #50 那一行。**`21-extras-load-failed-state.png` 保留**，它是这条探针的
"先红"那一半（失败态里「这里不消耗 co」与「可以再做的，6 项，多选」两句都不存在 ⇒ 断言不是恒真），
不是 21 的正常态证据，文件名也按失败态钉着。
A8 的两道锁现在只剩 **#46**（服务端把每一单补充制作都取消 ⇒ 产物字节今天取不到）。

## 顺带抓到、当场登记的三条（都不是"顺手改掉"）

- **§7 #49**：作品行的 `coverUrl` 是 Suno CDN 原链（`cdn2.suno.ai`，名单外）⇒ 作品封面这一端一张都不出；
  更糟的是出口守卫那句**诊断文本被拼进整行的 VoiceOver 标签**，读屏每听一行要先听 40 字内部原因。
  本轮所有 20 屏截图里作品行都是 ⚠ 占位图，就是这个原因，不是"截图没截到"。
- **测试自己的三处错判**（写在 `CovaAcceptanceTests` 的注释里，不静默改掉）：
  组头标识符按源码猜错了（设备上实际是 `cova.works.group.<序号>`）；
  两步写在同一次会话里导致"存在但点不到"（拆成一条一起点）；
  断"点 ♡ 后按钮清单必须变"量错了格（♡ 翻面走 `isSelected`，标签恒为「喜欢」，
  而那一次红的时候服务端已经建好 note 条目了）。
- **A5 曾经"假过"**：上一版 sleep 12s 就截图，判据只是"起过一个弹层"。
  读图发现停在「加载私有音频中…」⇒ 声音从来没起来、上报没发生。
  判据改成"必须看到 `mm:ss` 在走 + 再等 45s 让集次上报真的发生"之后才第一次真过。
