# 2026-10-02 web v2.65.0 对齐批验收（0.3.1/103）

字节：`cn.covalink.ios 0.3.1(103)`，`minOS=26.0`，同一份 `.app`
（`.build/check/DerivedData` Debug）`simctl install` 落到 iPhone 17 Pro 模拟器
（UDID `0A371F98-3CF7-415A-A70D-F216CFC1B59E`，iOS 26.5）。口径同 A14：
`SIMCTL_CHILD_` 预览键 + `simctl ui appearance` 深浅两档，不点击、零扣费。
登录态用 `COVA_PREVIEW_LOGIN_*` 进程环境走真两步登录（账号 `opencode@test.com`，
口令不落盘）。

## 4 张，每张都读过

| 屏 | 验收点 | 读图结论 |
| --- | --- | --- |
| 15-settings（light/dark，游客态） | insetGrouped 表单：外观/播放与网络/通知/条款与说明/关于 | 「版本 0.3.1 (103)」正确回显；「账号」段不渲染（按 §3 规格，游客不挂登录引导行） |
| 15-settings-signedin（light/dark） | 同上 + 账号段 | 已登录（`COVA_PREVIEW_LOGIN_*` 真登 opencode@test.com）；「版本 0.3.1 (103)」正确回显。「账号」段在列表底部，单屏取景未滚到 —— 该段的屏上证据由验收腿附件（`15-account-section` / `15-delete-confirm`）承担 |

## 验收腿（XCUITest，scheme `CovaAcceptance`）

新增 `testSettingsAccountSectionShowsDeleteAndLogout`
（`CovaAcceptanceTests/P0AcceptanceTests.swift`）：登录 → 路由 `settings` →
滚动到底 → 断言「账号」分组、「注销账号」行、「登出」行 → 点行开
「确认注销账号？」Dialog 截图 → 断四条后果逐条可见 → 断言「确认注销」存在、
**「取消」不存在**（iOS 26 系统事实：confirmationDialog 不再渲染 cancel 钮，
SO#79819697 + 实测 any/button/cell/other 全类型 0 命中；规格 15 §3.G②/H
与清缓存条已同步改口径，`PlazaAndSettings.swift` 三枚死代码取消钮随之删除）
→ 点 Dialog 之外的导航条返回钮关闭 → 断言 sheet 消失。**已 passed（25.9s）**。
中途断言面修正按实改：insetGrouped List 在 AX 里是 `collectionViews`
不是 `scrollViews`；Dialog 按钮挂在应用级（`dialog.buttons` 为空）。

## 门禁

`bash Scripts/check.sh` EXIT=0（本批字节上）：
CovaTests 2、CovaCoreTests 950（基线已抬 950）、CovaFeatureTests 307
（基线已抬 307）、CovaPlayerTests 483；覆盖率 94.22% / 95.15%；
产物保真 `0.3.1(103) minOS=26.0 bg=audio`。

## 与 web v2.65.0 契约的差异（按实契约呈现，不是漏做）

- 无密码复核、无冷静期/撤销端点（`DEVELOPMENT.md` §7 #4 差异登记，标「闭合」）。
