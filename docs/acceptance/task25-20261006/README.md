# 任务25 截图证据（2026-10-06，0.3.5/107）

钉的字节：HEAD = `554ba68`（feat/task25-design-alignment，产物保真
`cn.covalink.ios 0.3.5(107)`，check.sh 4/10 实测）。设备：iPhone 17 Pro 模拟器，
`SIMCTL_CHILD_COVA_PREVIEW_*` + `simctl io screenshot` 零扣费；深浅档用
`simctl ui appearance dark|light`（app 档位「跟随系统」⇒ 沙盒零残留，拍完已翻回 light）。

## 登录态说明（诚实记录）

本机已安装的 0.3.5(107) 是 check.sh 测试运行覆盖安装的 ⇒ 原持久化的测试账号
（`opencode test / COVA-00010462`）会话已丢，口令不落盘、本会话取不到
（`~/.covalink/ops.md` 无，`~/.config/covalink/credentials.json` access token 已于
2026-10-03 过期）。所以这批是**游客态**：13 没有账号卡/当前套餐高亮，02 无收藏态数据。
游客态不影响本批判据——任务25 只改了图标尺寸的来源（值逐处相同）与深色金属色
（游客态同样渲染对比表）。

## 逐张结论（每张都读过）

| 图 | 屏 | 内容 | 对比基线 | 判定 |
|---|---|---|---|---|
| `02-player-light.png` | 02 播放器 | 传输控制族（26/24/64/24/26）+ ⋯(18) + ♡(20) + 循环(22) + 歌词/分享 | `a14-20260927/02-player-{light,dark}.png` | **无视觉回退**：全部图标尺寸逐位一致（CovaSymbol 档值 = 原字面值），版式、波形、时码、封面不变 |
| `02-player-dark.png` | 同上 | 同上 | 同上 | 同上 |
| `13-membership-light.png` | 13 会员权益（游客态） | 权益对比表（免费/创作/专业/企业） | `a14-20260927/13-membership-light.png` | **无回退**：浅色档不变（浅色 memberGold #66511F 未动） |
| `13-membership-dark.png` | 同上（深色） | 同上 | `a14-20260927/13-membership-dark.png` | **有意差异（非回退）**：金色系按 2026-10-06 裁定从 #D9A52F 族改为 #F2DDA2/#8A7440/#2A2413（web .dark 实测唯一准），色块更浅更亮是裁定本身的效果 |

## 结构性缺证（两屏，如实记不硬拍）

- **21 补充制作面板**：**没有走查键直达**（源码注释原话：「它是 sheet，宿主是行菜单，
  靠键假装到得了等于有一张截图但没有这一屏」）；simctl 不提供点击 ⇒ 历史批次
  （`p12-20260926`）是走 XCUITest 腿拍的，而 XCUITest 需要 `COVA_ACCEPT_*` 口令
  （本机不可得，见上）。本批改动对 21 的影响面：✕ 16 / 行首符号 20 / 勾选圈 22 /
  错误符号 34 全部改走 CovaSymbol 同名同值档（pt 零变化），**风险为零变化**。
- **09 会话详情**：`COVA_PREVIEW_ROUTE=aiSession:<id>` 需要**真数据 id + 登录态**
  （§6.2 早记「要真数据 id 才到得了」），同缺口令。

## 残留清理

`COVA_PREVIEW_*` 只走 `SIMCTL_CHILD_` 进程环境（不落 UserDefaults）；拍完
`simctl ui appearance light` 已翻回浅色、app 已 terminate。无沙盒残留。
