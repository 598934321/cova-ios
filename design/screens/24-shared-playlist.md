# 24 · 分享的歌单（只读详情）

> §5 P3 第一条线的第二屏。基准 393×852pt。
> 数据源：`GET /api/shared-playlists/[token]`（**免登录可读**；404 `歌单不存在或未开启分享`）。
> 真实形状取自 `web/src/app/api/shared-playlists/[token]/route.ts`：
> `{playlist:{id,name,description,coverUrl,coverMedia,creatorName,trackCount,createdAt,
>  updatedAt,sharePath,isOwner}, tracks[], downloadCredits, downloadsEnabled}`。
> ⚠️ 这一支的标题键是 **`name`**，官方那支（06）是 `title` ⇒ 两个封套各解各的，不合并。

## 1. 屏与上下文

- **层级**：06 的**兄弟屏**，不是它的变体。05 的「每日推荐 / 歌单广场」两源里
  `source:"shared"` 那张卡的目的地就是这里 —— 它的 id 是**用户歌单 id**，
  拿它打 `GET /api/playlists/:id` 只会 404，所以这一屏必须有自己的一条腿。
- **入口**：① 05 两源里的分享卡；② 深链 `COVA_PREVIEW_ROUTE=sharedPlaylist:<token>`
  （只为模拟器逐屏截图存在，§6.1 同族）。
- **页签归属**：从 05/01 进来 ⇒ 属「首页」页签栈（04 §3；原「抽屉高亮歌单项」规则随抽屉移除）。

## 2. 区块

- **A 导航条**：标题「分享的歌单」（`type.title`）；左系统返回。
- **B 头部**：120pt 方形封面（`coverUrl` / `coverMedia.imageUrl`，缺 → 占位）+
  歌单名（`name`，缺 → 「未命名歌单」）+「来自 <creatorName>」（**只有给了才画**，
  不写"来自 未知"）+ 描述（给了才画）+ 一行元信息「N 首 · 分享链接」。
- **C 主人提示**：`isOwner == true` 才出现「这是你自己分享出去的链接」。
  **缺键按"不是主人"处理** —— 反过来会把一整排编辑动作交给游客。
- **D 曲目表**：一行一首 = 标题（`titleCn ?? title`，两行截断）+ `mm:ss`。
  本屏**不给播放钮**：整包播放属于 06 的腿，分享曲目的 `audioUrl` 走不走同一套出口还没核（待裁决 1）。
- **E 尾部**：无「已显示全部」—— 这一屏没有分页，一次给全。

## 3. 状态

| 态 | 触发 | 屏上 |
|---|---|---|
| 载入 | 进屏 / 下拉 | 骨架 6 行 |
| 正常 | 200 + 有 `playlist` | B(+C) + D |
| 曲目读不出 | 200 但 `tracks` 缺 / 有读不完整的条目 | 头部留着，D 位置一句「曲目没取到，只有这份歌单的头部信息。」 —— **不许**画成"这是一份空歌单" |
| 标识不合规 | token 不能安全进路径段 ⇒ **请求没发** | 空态「这个分享链接读不了 / 链接里的标识不合规则，请求没有发出去。」 |
| 读不到 | 网络 / 5xx / 404 | 错误态 + 重试，并把服务端给的那句原因单独摆在下面 |

## 4. 刻意没有的东西（都不是遗漏）

- **没有「下载全部」**：响应里有 `downloadsEnabled` / `downloadCredits`，但付费下载那一格受
  D12 与"门 1 未放行"约束（§1 硬边界）⇒ 读了也不画。
- **没有「收藏到我的歌单」**：那是 `POST /api/shared-playlists/[token]/claim`，写操作，
  本轮只交付读面。已登记在 DEVELOPMENT.md §5 P3 表。
- **没有编辑/改名/删曲**：这是**别人**的歌单，`isOwner` 只用来决定 C 那一句。

## 5. 设备证据

`docs/acceptance/p3-20260927/24-shared-playlist-bad-token-{light,dark}.png`（0.2.79/97）。
**正常态今天拍不到**：生产 `GET /api/playlists/public` 回 `{playlists:[]}` —— 一条分享歌单都没有，
所以没有一枚真 token 可用。这一格按"结构性缺证人"记在 §6.2，不算已达。

## 6. 待裁决 / Token 缺口

1. 分享曲目的音频出口是否与库曲同一套（决定 D 什么时候能给播放钮）。
2. `creatorName` 的外泄边界：服务端已经决定回这个名字（`owner?.name`），
   屏上是否要给它一个"隐藏作者"的开关 —— 属产品口径，不在本轮。
3. TG：本屏未新增 token 需求；封面/间距/字阶全部沿用既有档位。
