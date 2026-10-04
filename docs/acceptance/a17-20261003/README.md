# 2026-10-03 与 web 统一设计语言批验收（0.3.2/104）

字节：`cn.covalink.ios 0.3.2(104)`，`minOS=26.0`，同一份 `.app`
（`.build/check/DerivedData` Debug）`simctl install` 落到 iPhone 17 Pro 模拟器
（UDID `0A371F98-3CF7-415A-A70D-F216CFC1B59E`，iOS 26.5）。口径同 A14/A16：
`SIMCTL_CHILD_` 预览键 + `simctl ui appearance` 深浅两档，不点击、零扣费。
登录态用 `COVA_PREVIEW_LOGIN_*` 进程环境走真两步登录（账号 `opencode@test.com`，
口令不落盘）。

本批内容：与 web v2.65+ 统一设计语言 —— 按钮族改档（primary = 中性液态玻璃，
`gradient.brandButton` 只留 hero CTA）、内容区选中态全灰、焦点环独立色
`focusRing`；页签 tint 保橙为有意分歧（web 页签同为品牌橙）。

## 22 张，每张都读过

| 屏 | 验收点 | 读图结论 |
| --- | --- | --- |
| 01-home（light/dark） | 「生成/搜索」分段 chip 改中性档；建议 chips 中性 | 两色均中性灰选中，页签「首页」橙 tint 保留 ✓ |
| 03-library（light/dark） | 筛选 chip 未选态、行列表无回归 | 无选中态画面下 chips 为灰底中性；时长 m:ss ✓ |
| 03b-library-filter（light/dark，`COVA_PREVIEW_FILTER=scene:短视频/Vlog;mood:温暖`） | 已选 chips / 「完成」钮 / picked 计数去橙 | 已选 chips = `selectedBg`+`selected`+`line` 描边中性灰；「完成」钮中性玻璃+正文色 ✓ |
| 05-plaza（light/dark） | 「官方歌单」选中 tab chip 去橙 | dark 下白字灰底 ✓，light 下黑字灰底 ✓；卡片网格无回归 |
| 10-login（light/dark） | 「登录」hero CTA = `gradient.brandButton` 胶囊 | 橙→品红→橙渐变胶囊两色均正确呈现，「先随便看看」次级钮中性描边 ✓ |
| 11-mine（light/dark） | 无选中态改动；表单分组无回归 | 「Cova 号 COVA-00010462」标签正常；头像橙字装饰保留 ✓ |
| 13-membership（light/dark） | 当前方案列去橙 | 当前列 = fg 顶边 + `selectedBg` 底 + `selected` 徽标，中性灰两色均正确 ✓ |
| 15-settings（light/dark） | 无选中态改动；insetGrouped 无回归 | 「版本 0.3.2 (104)」正确回显；分组表单两色正常 ✓ |
| 19-studioCreate（light/dark） | 「开始生成」hero CTA = 渐变胶囊；模式 chips 中性 | 两色均为橙→品红→橙渐变**胶囊**（非圆角矩形），白字 ✓；「创作」选中 chip 灰 ✓ |
| 20-worksList（light/dark） | 筛选 chips「全部」选中态去橙 | 选中「全部」= 灰底 `selected` 字色，两色均正确 ✓；「排序」胶囊 accentText 橙链接保留（有意） |
| 25-search（light/dark） | 分类卡装饰竖条保留、tabViewBottomAccessory 无回归 | 场景竖条青绿/情绪竖条蓝紫装饰色保留 ✓；底部 `tabViewBottomAccessory` 搜索条两色正常 |

## 局限（屏上拍不到，由代码与规格承担）

- `focusRing`（#8A8F98）焦点描边：需真实键盘/焦点态，截图预览无法触发；
  改动点在 `StudioCreateView` 输入卡与 10/19 spec 条文，token 已进 `CovaTokens`。
- `radius.cover`（16）：新 token 备档，本批钉的卡片全部仍用 `radius.card`=18，
  无消费方——不强行接线。
- 深度思考 chip（01 §3.G）：选中态代码已改 `selectedBg/selected`，但需登录态
  会话内焦点画面才能呈现；与上方 focusRing 同属「代码已改、屏难取证」项。

## 保留橙位（有意分歧，inventory.md 已登记）

页签 tint、收藏心/书签角标、播放进度/正在播放、09 用户气泡 `accentSoft`、
已收藏胶囊、25 分类装饰竖条、文字链接 `accentText`（如 20「排序」）、
编辑态多选圈（web 购物单选圈同款橙）、09 发送钮。

## 门禁

`bash Scripts/check.sh` EXIT=0（本批字节上复跑通过，见本目录上方版本行）：
CovaTests 2、CovaCoreTests 950、CovaFeatureTests 307、CovaPlayerTests 483；
D12 诱饵自检 12 段全抓全复原；产物保真 `0.3.2(104) minOS=26.0 bg=audio`。
