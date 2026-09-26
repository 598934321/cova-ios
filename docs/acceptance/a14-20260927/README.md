# A14 深色档配对（2026-09-27，批三 = 0.2.78/96）

字节：0.2.78/96 —— `xcodebuild build` 之后 `simctl install`，屏上自证：`15-settings-{light,dark}`
的「关于 / 版本」那一行就是 **0.2.78 (96)**（不是靠 `plutil` 单方面声明）。
设备：iPhone 17 Pro 模拟器；方式：`simctl` + 预览键（不点击、零扣费），
深浅档用 `simctl ui <udid> appearance dark|light` 翻（app 档位「跟随系统」⇒ 沙盒零残留，拍完翻回 light）。

## 这一档 13 屏 × 深浅 = 26 张，每张都读过

01-home、02-player、03-library、04-drawer、05-plaza、08-ai-sessions、10-login、11-mine、
12a-favorites、12b-my-playlists、13-membership、14-enterprise、15-settings。
（01 首页在批一已有一对，这里是在**本批字节**上重拍的一份；两批各自算各批的账，见 §6.3 末格。）

## 读图这一步抓到三次"拍到的不是那屏"——这三条比图本身值钱

1. **`--setenv` 写在 bundle id 之后**：`simctl launch <udid> <bundle> --setenv K=V` 里那串
   不是环境变量，是**传给 app 的启动参数** ⇒ 12 个预览键一个没生效，第一遍 13 张里
   `02-player` 到 `15-settings` 全是 app 的默认屏（首页）。而 `01-home` 那张"看起来对"
   —— 它本来就该是首页，所以**只有逐张读才看得见这是整批废图**。
2. **`--setenv` 写在 udid 之前**：这台机器的 `simctl` 根本不认这个选项，
   直接 `Invalid device: --setenv`（RC=148）⇒ app 没起来，第二遍 26 张全是桌面（SpringBoard）。
   正确机制是 §6.1 早就写着的那一条：**`SIMCTL_CHILD_<键名>=<值>` 放在 `xcrun` 之前**
   （`env SIMCTL_CHILD_COVA_PREVIEW_ROUTE=plaza … xcrun simctl launch …`）。
   这次两屏一点即中（`plaza`→05、`settings`→15），确认机制后才重跑整批。
3. **深色档的 04/11 拍到的是"未登录态"**：暖机之后重复带口令启动会被 `/login` 限流，
   于是 11-mine 深、04-drawer 深 第一版是游客态。改法：**先带口令起一次登录，后续启动只带屏键**
   （会话已持久化）⇒ 两张重拍后与浅色档同态（账号卡 `opencode test / COVA-00010462 / co 19315 / 专业版` 都在）。
   04 深还多踩一次：shell 里 `for kv in "${spec##*|}"` 加了引号 ⇒ 两个键被当成一个，
   `DRAWER=1` 没进去，拍到的是没展开抽屉的首页。

## 还缺哪些（不要从这一档读成"A14 做完了"）

- 06 / 07 / 09 / 16：要**真数据 id** 才到得了（`playlist:<id>` / `track:<id>` / `aiSession:<id>` / `artist:<id>`）。
- 12c / 17：**没有预览键** ⇒ 要么加一枚只为截图存在的键，要么走 XCUITest 腿。
- 23 / 12d / 18：结构性拍不到（§6.2 那一条）。

## 口径

- 口令不进仓库也不进脚本：`Scripts/a14-shoot.sh` 里是 `REPLACE_ME_*` 占位，真值只活在运行时。
- 没读过的图不进这个目录（前两遍共 52 张废图留在 `/tmp`，一张都没归档）。
