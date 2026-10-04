# 2026-10-02 Apple Music 参照改版验收（0.3.1/102）

字节：`cn.covalink.ios 0.3.1(102)`，`minOS=26.0`。外壳按 Apple Music 结构重排：
五页签（首页/曲库/创作/我的 + 系统搜索位 `Tab(role:.search)`），首页改对话型
（底置输入条），歌单广场消化 `plazaSearch(q)` 回显行 + 本地过滤。
同一份 `.app`（`.build/dd` Debug）`simctl install` 落到 iPhone 17 Pro 模拟器
（UDID `0A371F98-3CF7-415A-A70D-F216CFC1B59E`，iOS 26.5）逐屏拍摄。口径同 A14：
`SIMCTL_CHILD_` 预览键 + `simctl ui appearance` 深浅两档，不点击、零扣费；
**不传 `COVA_PREVIEW_LOGIN_*`**（保持已登录测试账号，占位口令会顶成游客）。
脚本：`Scripts/a15-shoot.sh`。

## 12 屏 × 深浅 = 24 张，每张都读过

| 屏 | 验收点 | 读图结论 |
| --- | --- | --- |
| 01-home | 对话型首页：问候 + 「o」橙点、生成/搜索切换、场景·情绪标签、底置输入条；搜索位与四页签系统分隔 | 深浅一致，全部命中 |
| 25-search | 新增系统搜索页签：`.searchable` + 历史区 + 三维分类卡网格（色条标识） | 深浅一致 |
| 03-library | `.searchable` 已迁出本屏（搜索归 25） | 导航条下无搜索框，列表正常 |
| 03b-library-preset | `library(preset)` 复用件：预填 scene 条件 | chips 已选「短视频/Vlog」+ 6,215 首计数 |
| 05-plaza | 歌单广场 push 形态：三源段控件 + 场景 chips + 双列网格 | 深浅正常（深色第一拍有音符占位，重拍全部真封面——加载时序，非缺陷） |
| 05b-plaza-search | `plazaSearch(q)` 回显行 + 本地过滤空态 | **首轮发现缺陷**：非 .ready 态下 VStack 不撑高被垂直居中，回显行沉到屏中段。已修（外层顶钉 + 空态剩余区居中），重拍复核通过：回显行贴导航条、chips 顺排、空态居中「没有找到『轻音乐』相关的歌单 + 清除搜索」 |
| 08-aiSessions | 创作页签根：会话列表 + 兜底标题 | 正常 |
| 11-mine | 「我的」页分组表单 | 正常 |
| 25-search | 见上 | — |
| 12a-favorites | 收藏列表 | 正常 |
| 15-settings | insetGrouped 表单 + 版本号 | 「版本 0.3.1(102)」正确回显 |
| 13-membership | 会员页 | 「订阅与 co 包」标题下空白 = IAP 灰度未开（§7 #56 已知项），非缺陷 |
| 10-login | 登录 sheet | 深浅正常 |

## 缺陷处置记录

1. **05b 空白带（已修）**：`PlaylistsPlazaView` 外层 `VStack` 在非 `.ready` 阶段
   （骨架/整屏错误/空态）只有内容高，被父级居中——回显行、源控件、chips 整体下沉约半屏。
   修法：外层 `.frame(maxHeight: .infinity, alignment: .top)` 顶钉；
   `CovaErrorState`/`CovaEmptyState` 三处 `.frame(maxHeight: .infinity)` 在剩余区居中。
   `Packages/CovaFeature/Sources/CovaFeature/PlazaAndSettings.swift`。
2. **05 深色封面占位**：重拍后全部真封面，判为 11s 等待窗内的加载时序，不立案。

## 门禁

`bash Scripts/check.sh` EXIT=0（修改后重跑）：Core 946/0、Feature 307/0（基线 306+1）、
Player 483/0；覆盖率 94.14% / 95.15%；产物保真 `0.3.1(102) minOS=26.0`。

## 遗留（需实机复核）

- `Tab(role:.search)` 的搜索页签行为（iOS 26.5 模拟器可用，真机确认系统分隔位表现）。
- 底置输入条与 MiniPlayer（`tabViewBottomAccessory`）同屏时的遮挡关系。
- `library` 的 search-text preset 无走查键（只有 `plazaSearch:` 有），03 搜索态走查缺口已知。
