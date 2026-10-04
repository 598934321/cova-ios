# 2026-10-01 C 批小修验收（0.2.82/100）

字节：0.2.82(100) —— `bash Scripts/check.sh` 构建产物保真行：`cn.covalink.ios 0.2.82(100)
minOS=26.0 bg=audio`；同一份 `.app` 经 `simctl install` 落到 iPhone 17 Pro 模拟器
（UDID `0A371F98-…`）后逐屏拍摄。方式与 A14 同口径：`SIMCTL_CHILD_` 预览键
+ `simctl ui appearance` 深浅两档；登录态沿用模拟器里已持久化的测试账号
（`opencode test / COVA-00010462 / co 19315 / 专业版`），本批没有重放 `/login`
⇒ 没碰限流。拍完翻回 light、terminate。

## 6 屏 × 深浅 = 12 张，每张都读过

| 屏 | 验收点（对应 C 批） | 读图结论 |
| --- | --- | --- |
| 01-home | C5 周边：外壳下缘留给提示条的空位不再压导航栏 | 问候/AI 卡/推荐歌单正常，深浅一致 |
| 03-library | C1：行内时长 `m:ss`（`0:32`/`2:18`/`3:14`…），副标题 `艺人 · m:ss · BPM n` | 深浅两档均 `m:ss`，无 `Ns` 残留 |
| 08-aiSessions | C6：会话标题兜底链 | 整列无「新会话」：有 `lastMessage` 的行显「我是 Cova，很高兴认识你。你可以…」（截 20 字 + …），取不到的行显「未命名会话」 |
| 11-mine | C3：「Cova 号 COVA-00010462」替掉字段名 `covaId`（长按复制在屏外验证不了，靠代码 `contextMenu`） | 深浅两档均新标签；登出钮仍在原屏内（B5 挪位属 B 批，未实现） |
| 13-membership | C4：「每月额度」行整行删除 | 对比表只剩 商用授权 / AI 生成 / 下载与扣费 / 企业项目申请 四行；当前列（专业版）高亮不变；逐字脚注两句仍在 |
| 20-worksList | C1+C2：`04:03`/`04:12`/`03:52`/`03:57` 时长；无封面行显中性 `music.note` 占位；行内只剩单枚 ⋯ | 深浅两档一致；`⚠` 不再出现；次要操作不在行内铺开 |

## 屏上看不到、用别的证据补的两条

- **C5（提示条不盖导航栏）**：本批没有可复现的触发路径能仅靠预览键让 toast 出现
  （`COVA_PREVIEW_*` 无 toast 钩子）。判据在代码层：提示条从外壳 `.top` overlay 挪到
  `tabContent` `.bottom` overlay（`CovaRootView.swift` mainShell），落在 MiniPlayer 之上、
  抽屉层之下。屏证据 = 01 深浅两张「导航标题区域无遮挡」。
- **C2 的 ⋯ 菜单内容**：simctl 不点击，菜单弹层拍不到；菜单项可用性分档由
  `WorksRowMenuItemTests`（5 条纯函数用例）钉。
