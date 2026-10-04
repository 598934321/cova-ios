# 2026-10-01 B 批外壳 + A1/A2 验收（0.3.0/101）

字节：`cn.covalink.ios 0.3.0(101)`，`minOS=26.0`。同一份 `.app`（check.sh 产物目录
`.build/check/DerivedData`）经 `simctl install` 落到 iPhone 17 Pro 模拟器
（UDID `0A371F98-3CF7-415A-A70D-F216CFC1B59E`）逐屏拍摄。口径同 A14：
`SIMCTL_CHILD_` 预览键 + `simctl ui appearance` 深浅两档。
**登录态走模拟器里已持久化的测试账号**（`opencode test / COVA-00010462 / 专业版`，
co 19315）——不传 `COVA_PREVIEW_LOGIN_*`：脚本里的 `EMAIL/PASS` 是占位符，
那两键会把已恢复的 Keychain 会话顶成游客态（a14 第一批 22 张因此作废，不重发）。
拍完翻回 light、terminate。

## 11 屏 × 深浅 + 迷你条正向态 2 张 = 24 张，每张都读过

| 屏 | 验收点 | 读图结论 |
| --- | --- | --- |
| 01-home | 四页签栏、无左上角「Cova」胶囊、无抽屉入口 | 深浅一致；标签栏 = 首页/曲库/创作/我的，选中态胶囊高亮正确 |
| 01-miniplayer | B3：有播放任务时迷你条存在 | 浅深两档均见 accessory 位：封面 +「Folded Sunset」+「加载私有音频中…」+ 播放/下一首；播放器 sheet 尚未展开的空窗（启动后 ~9s）拍 |
| 03-library | B4 `.searchable` + C1 时长 | 搜索框在导航条下栏位；行内全部 `m:ss`（`0:32`/`2:18`/`1:55`/`3:14`…）+ `BPM n` |
| 05-plaza | 歌单广场（抽屉拆迁后的新去处） | 分段控件 + 场景标签 + 歌单网格正常；页签栏在 |
| 08-aiSessions | C6 会话标题兜底 | 登录态列表：有 `lastMessage` 的行显首条消息截断，取不到的显「未命名会话」，无「新会话」 |
| 10-login | 游客 sheet | 深浅两档正常（sheet 半屏形态） |
| 11-mine | B2 抽屉项新去处 + C3 | 「Cova 号 COVA-00010462」标签正确；我的资产 = 收藏/我的歌单/我的创作三行；我的页签高亮（修掉「设置高亮首页」类问题） |
| 12a-favorites | C1 漏网行（本轮修的） | `水畔更漏 陈筴 · 3:00`、`Corridor and Trail 克洛依·贝内特 · 2:34` —— `Ns` 无残留 |
| 12b-myPlaylists | 抽屉项去处 | 空态「还没收藏歌单」+「去歌单广场」CTA 正常 |
| 13-membership | A2 购买区 + C4 | 「订阅与 co 包」区块不渲染（`iapPhase=.unavailable`，按 §4.8 纪律：镜像/ASC 任一侧缺商品 ⇒ 整区不画买不了的卡）；权益对比剩 4 行（每月额度行已删）；「恢复购买」+「购买即代表同意《服务条款》与《隐私政策》」+ 法务链在 |
| 14-enterprise | 企业服务页 | 邮箱行 +「covalink.cn/enterprise」+「App 内不办理任何业务」陈述句；无购买词 |
| 15-settings | B5 insetGrouped + 版本号 | 分组表单：外观/播放与网络/通知/条款与说明/关于；版本行显 `0.3.0 (101)`；登出与删号行在屏下（simctl 不滚动，见下） |

## 屏上看不到、以代码证据补的三条

- **15 屏「账号」组**（登出红字 + 删除账号）：在表单最底，simctl 无滚动能力拍不到。
  存在性由 `PlazaAndSettings.swift` 的 Section("账号") + `SettingsViewTests` 钉；删号流程
  两级确认 → `DELETE /api/auth/account`（幂等键）→ 本地清理链（队列/缓存/owner 桶/通知）
  有单测覆盖。端点服务端未上线 ⇒ 404 时回落文案「删除服务暂未上线」。
- **07 曲目详情相似曲卡时长**：sheet 首屏放不下相似区，`simctl` 不给滚动。
  该卡与 12a/03 共用 `TrackRowCopy.subtitle`（m:ss 已在三屏实测）。
- **VoiceOver/AX3**：非本次 `simctl` 截图可及范围；`Label` 与选中态由系统 `Tab` 承载
  （`Tab(title, systemImage:, value:)` 自带 selected trait），AX3 布局依赖分组表单与
  系统字阶，未单独出图。

## 本批发现并修复的缺陷

`tabViewBottomAccessory` 在 iOS 26.1+（模拟器 26.5）对空内容仍画出一条**空胶囊壳**
（26.0 会自动收壳，`isEnabled:` 形参也是 26.1 才有）。修法：`#available(iOS 26.1, *)`
静态分流——26.1+ 走 `isEnabled: snapshot?.item != nil` 显式隐藏，26.0 回落只挂内容闭包。
`#available` 不在运行期换边，TabView 身份稳定。证据：修前 `/tmp/a14b` 全屏有白条，
修后本批全屏无；`01-miniplayer-*` 两张证明有播放任务时条正常出现。
