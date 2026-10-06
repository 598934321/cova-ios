# 任务25：`.font(.system(size:)` token 化映射表（2026-10-06）

范围：`Packages/CovaFeature/Sources` + `Packages/CovaPlayer/Sources`（后者本就 0 处）。
**全部 38 处均为 `Image(systemName:)` 的 SF Symbol**——没有一处是文本字号，
所以规则 (a)/(b) 的「文本 → CovaType 语义档」没有适用点；全部走规则 (c)：
CovaUI 新增 `CovaSymbol` 命名尺寸档（`CovaTokens.swift`，与 `CovaType` 同文件同注释风格），
刻意固定 pt、不随 Dynamic Type（图标按触控目标与版式定位，见 enum 头注释与
`刻意偏差登记.md` D-01/D-02 同族登记）。

连带收编：`CovaUI/CovaStates.swift` 里还有 2 处同类字面量（CovaEmptyState /
CovaErrorState 的 34 light）——同一档，一并收编，不留第二处真值。
`WorkExtrasMetrics.symbolSize/checkboxSize` 改为 `CovaSymbol.rowSymbolPoint /
controlLargePoint` 的别名（框宽几何仍走该常量，字级走新档）。

## 新增档（`design/tokens.json` 已加 `symbol` 区镜像，注明 iOS 端载体）

state 34 light ｜ playerMain 64 regular ｜ playerControl 26 semibold ｜
playerSeek 24 medium ｜ loopControl 22 medium ｜ playerAction 20 semibold ｜
controlLarge 22 regular ｜ rowSymbol 20 regular ｜ controlProminent 18 semibold ｜
control 16 semibold ｜ controlPlain 16 regular ｜ status 15 regular ｜
agentMark 14 semibold ｜ linkExternal 13 regular ｜ statusSmall 12 regular ｜
badge 11 semibold ｜ chevron 10 regular ｜ chevronCompact 9 semibold

## 映射表（旧值 → 新档；pt/字重全部零变化）

| 文件:行（改前） | 旧值 | 新档 | 默认 pt 变化 |
|---|---|---|---|
| DetailViews.swift:456 | 16 semibold（xmark 关闭） | `control` | 无 |
| DetailViews.swift:470 | 16 semibold（ellipsis 更多） | `control` | 无 |
| DetailViews.swift:503 | 22 regular（收藏心） | `controlLarge` | 无 |
| DetailViews.swift:569 | 10 regular（歌词展开 chevron） | `chevron` | 无 |
| CreditsLedgerView.swift:311 | 34 light（空态插图符号） | `state` | 无 |
| CreditsLedgerView.swift:342 | 34 light（整屏错误符号） | `state` | 无 |
| CollectionsViews.swift:134 | 22 regular（多选勾选圈） | `controlLarge` | 无 |
| CollectionsViews.swift:475 | 22 regular（多选勾选圈） | `controlLarge` | 无 |
| LoginAndMine.swift:324 | 34 light（账号错误符号） | `state` | 无 |
| LoginAndMine.swift:486 | 15 regular（签到态 checkmark） | `status` | 无 |
| HomeView.swift:246 | 18 semibold（大卡播放钮） | `controlProminent` | 无 |
| HomeView.swift:691 | 11 semibold（作品卡 sparkles 角标） | `badge` | 无 |
| PlayerViews.swift:31 | 20 semibold（迷你条播放/暂停） | `playerAction` | 无 |
| PlayerViews.swift:38 | 16 semibold（迷你条下一首） | `control` | 无 |
| PlayerViews.swift:121 | 18 semibold（播放页 ⋯ 菜单） | `controlProminent` | 无 |
| PlayerViews.swift:180 | 20 semibold（播放页收藏心） | `playerAction` | 无 |
| PlayerViews.swift:327 | 26 semibold（backward.fill） | `playerControl` | 无 |
| PlayerViews.swift:333 | 24 medium（gobackward.15） | `playerSeek` | 无 |
| PlayerViews.swift:340 | 64 regular（播放/暂停主钮） | `playerMain` | 无 |
| PlayerViews.swift:345 | 24 medium（goforward.15） | `playerSeek` | 无 |
| PlayerViews.swift:351 | 26 semibold（forward.fill） | `playerControl` | 无 |
| PlayerViews.swift:414 | 22 medium（循环三态钮） | `loopControl` | 无 |
| WorkExtrasPanelView.swift:136 | 16 semibold（xmark 关闭） | `control` | 无 |
| WorkExtrasPanelView.swift:199 | 20 = `symbolSize`（行首符号） | `rowSymbol` | 无 |
| WorkExtrasPanelView.swift:332 | 22 = `checkboxSize`（勾选圈） | `controlLarge` | 无 |
| WorkExtrasPanelView.swift:361 | 20 = `symbolSize`（行首符号） | `rowSymbol` | 无 |
| WorkExtrasPanelView.swift:540 | 34 light（整面板错误符号） | `state` | 无 |
| HomeComposer.swift:200 | 18 semibold（sparkles 创作入口） | `controlProminent` | 无 |
| HomeComposer.swift:223 | 9 semibold（搜索目标 chevron） | `chevronCompact` | 无 |
| HomeComposer.swift:250 | 16 semibold（发送钮 arrow.up） | `control` | 无 |
| WorksListView.swift:562 | 34 light（整屏错误符号） | `state` | 无 |
| AISessionDetailView.swift:373 | 14 semibold（agent 标识 sparkles） | `agentMark` | 无 |
| AISessionDetailView.swift:464 | 12 regular（运行状态行符号） | `statusSmall` | 无 |
| AISessionDetailView.swift:679 | 16 semibold（候选卡试听钮） | `control` | 无 |
| AISessionDetailView.swift:853 | 16 regular（候选卡收藏心） | `controlPlain` | 无 |
| AISessionDetailView.swift:1296 | 16 semibold（会话发送钮） | `control` | 无 |
| PlazaAndSettings.swift:302 | 12 regular（已收藏角标） | `statusSmall` | 无 |
| PlazaAndSettings.swift:618 | 13 regular（外链指示） | `linkExternal` | 无 |

## 收编外但同批收编（CovaUI 内残留）

| 文件:行 | 旧值 | 新档 | 默认 pt 变化 |
|---|---|---|---|
| CovaStates.swift:349 | 34 light（CovaEmptyState） | `state` | 无 |
| CovaStates.swift:381 | 34 light（CovaErrorState） | `state` | 无 |

## 统计

零变化 **38/38**（+2 处 CovaUI 内连带），有变化 0 处。
文本字号替换 = 0 处（范围内不存在文本 `.system(size:)` 调用）。

自证：`grep -rn '\.font(\.system(size:' Packages/CovaFeature/Sources
Packages/CovaPlayer/Sources` → 0 命中；`Font.system(size:` 仅存于
`CovaUI/CovaTokens.swift` 的 `CovaSymbol` 定义（单一真值源）。
