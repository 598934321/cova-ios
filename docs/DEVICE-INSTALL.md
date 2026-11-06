# 装到自己手机上（真机测试）

> 目标读者：手上有 iPhone/iPad 和一台 Mac，想把这个 App 装上去看看的人。
> **不需要付费开发者资格**（99 美元/年那个），免费 Apple ID 就够。
> 前提：Xcode 已装、`xcodegen` 已装（`brew install xcodegen`）。

---

## 一句话版本

```bash
cd "多端/ios app"
# ① 把 Team ID 填进 Config/DeviceLocal.xcconfig（下面讲怎么拿）
# ② 手机用数据线连上 Mac，点「信任」
xcodegen generate --spec project.yml
xcodebuild -project Cova.xcodeproj -scheme Cova \
  -configuration DeviceLocal \
  -destination 'platform=iOS,id=<你的设备UDID>' \
  -allowProvisioningUpdates build
```

装完的一步用 Xcode 打开工程按 ▶ 最省事，见下面 §4。

---

## 0. 为什么有 `DeviceLocal` 这个配置

仓里原来的两个配置 **Debug / Release 都是 adhoc 签名**：

```
CODE_SIGN_STYLE     = Manual
CODE_SIGN_IDENTITY  = -        ← adhoc，不认任何开发者身份
DEVELOPMENT_TEAM    = (空)
```

adhoc 只能装进**模拟器**，装不进真机。而门禁 `Scripts/check.sh` 与 CI 全跑在这两个
配置上（`CONFIGURATIONS="Debug Release"`），**动它们等于换尺子**。

所以新增了独立的第四个配置 **`DeviceLocal`**：

| 设置 | Debug / Release（不动） | DeviceLocal |
|---|---|---|
| `CODE_SIGN_STYLE` | `Manual` | `Automatic` |
| `CODE_SIGN_IDENTITY` | `-`（adhoc） | `Apple Development` |
| `DEVELOPMENT_TEAM` | 空 | 取自 `Config/DeviceLocal.xcconfig` |
| `AD_HOC_CODE_SIGNING_ALLOWED` | `YES` | `NO` |

**验证没污染**（可复跑，见 §6）：Debug/Release 的有效构建设置与新增配置之前**逐行相同**。

---

## 1. 登记你的 Apple ID（只需一次）

1. 打开 Xcode → 菜单 **Xcode › Settings…**（`⌘,`）
2. 切到 **Accounts** 标签
3. 左下角 **`+`** → 选 **Apple ID** → 登录你的 Apple ID
   （免费账号就行，不用买开发者计划）
4. 登录后右侧会列出 **Personal Team**，后面跟着 **`(Personal Team)`** 和你
   **Team ID**（10 位，形如 `AB12CD34EF`）

**拿不到 Team ID 的备用办法**：
```bash
security find-identity -v -p codesigning
# 输出里形如：
#   1) ABCDEF...0123 "Apple Development: your@email.com (AB12CD34EF)"
#                                                        ↑ 括号里就是 Team ID
```
但注意：**免费账号在第一次成功签名之前，钥匙串里没有这张证书**，所以首次请走 Xcode 图形界面。

---

## 2. 填 Team ID

编辑 `Config/DeviceLocal.xcconfig`：

```diff
-DEVELOPMENT_TEAM =
+DEVELOPMENT_TEAM = AB12CD34EF
```

**为什么 Team ID 不写进 `project.yml`**：它是**本机私有值**（每个开发者不同），
写进项目文件会让每次 `git pull` 都冲突，而且不该进版本库。

**更省事的方式**：把这一行写进 `Config/Local.xcconfig`（已在 `.gitignore` 里，
不会进 git），`DeviceLocal.xcconfig` 末尾有 `#include? "Local.xcconfig"`，
会自动加载：

```bash
cat > "多端/ios app/Config/Local.xcconfig" <<'EOF'
DEVELOPMENT_TEAM = AB12CD34EF
EOF
```
> `#include?` 带问号 = 文件不存在也不报错，所以团队里没这个文件的人照样能编译。

---

## 3. 第一次装（推荐用 Xcode 图形界面）

命令行首次签名最容易卡在「设备没注册 / Bundle ID 被占 / 证书没生成」。
**第一次用 Xcode 点一下最省事**，成功后再用命令行也行。

1. 手机用**数据线**连 Mac，手机上点「信任此电脑」
2. 打开 `Cova.xcodeproj`（若没有，先 `xcodegen generate --spec project.yml`）
3. 顶部工具栏 scheme 选 **Cova**，目标选**你的手机**（不是模拟器）
4. **左侧工程导航选 `Cova` 项目 → TARGETS 里的 `Cova` → Signing & Capabilities**
5. 勾 **Automatically manage signing**，Team 选你的 **Personal Team**
6. 点 **▶ Run**

构建完手机会出现 Cova 图标。**首次运行会被系统拦一次**：

> 设置 → 通用 → VPN与设备管理 → 开发者App → 选你的 Apple ID → **信任**

（免费账号第一次装必然要这一步，不是配错了。）

---

## 4. 命令行装（Xcode 成功过一次之后）

```bash
cd "多端/ios app"

# 拿设备 UDID（手机连着时才有输出）
xcrun devicectl list devices
#   → 形如 00008110-000A1B2C3D4E5F6G  或  d7f3a9...（40 位十六进制）

xcodegen generate --spec project.yml

xcodebuild -project Cova.xcodeproj -scheme Cova \
  -configuration DeviceLocal \
  -destination 'platform=iOS,id=<UDID>' \
  -allowProvisioningUpdates \
  build
```

`-allowProvisioningUpdates` 让 Xcode 自动去 Apple 那边注册设备、申请证书——
**不加这条，免费账号的首次签名会直接失败**（提示 `No profiles for 'cn.covalink.ios' were found`）。

装到手机（`build` 之后产物在 DerivedData，也可加 `-derivedDataPath` 指定）：

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Cova.app" -path "*DeviceLocal-iphoneos*" | head -1)
xcrun devicectl device install app --device <UDID> "$APP"
xcrun devicectl device process launch --device <UDID> cn.covalink.ios
```

---

## 5. 7 天过期后怎么重装

免费 Apple ID 签出来的包**有效期 7 天**（这是 Apple 的限制，付费账号是 1 年）。
到期后 App 打不开，提示「开发者需要重新验证」或直接闪退。**重装一次即可续 7 天**：

```bash
# 手机连上，重复 §4 的两条命令即可（不需要改任何配置）
xcodebuild -project Cova.xcodeproj -scheme Cova -configuration DeviceLocal \
  -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates build
# 然后 devicectl device install 覆盖装
```

**最省事的续期姿势**：Xcode 打开工程，手机连着，按一次 **▶**。

**注意**：7 天到期**不会**自动续。想长期用就买个付费开发者资格（99 美元/年，1 年有效期），
那时可以把这个 DeviceLocal 配置里的 Team 换成付费 Team，其他不用动。

---

## 6. 怎么证明「没污染现有配置」

```bash
cd "多端/ios app"
xcodegen generate --spec project.yml

# Debug / Release 必须仍是 adhoc
xcodebuild -project Cova.xcodeproj -scheme Cova -configuration Debug -showBuildSettings \
  | grep -E "CODE_SIGN_STYLE|CODE_SIGN_IDENTITY|DEVELOPMENT_TEAM|AD_HOC_CODE_SIGNING_ALLOWED"
#   期望：Manual / "-" / (空) / YES

xcodebuild -project Cova.xcodeproj -scheme Cova -configuration Release -showBuildSettings \
  | grep -E "CODE_SIGN_STYLE|CODE_SIGN_IDENTITY|DEVELOPMENT_TEAM|AD_HOC_CODE_SIGNING_ALLOWED"
#   期望：同上

# 新配置必须能被解析出来，且是 Automatic
xcodebuild -project Cova.xcodeproj -list | sed -n '/Build Configurations/,+4p'
#   期望看到 Debug / DeviceLocal / Release

xcodebuild -project Cova.xcodeproj -target Cova -configuration DeviceLocal -sdk iphoneos -showBuildSettings \
  | grep -E "CODE_SIGN_STYLE|CODE_SIGN_IDENTITY|DEVELOPMENT_TEAM|AD_HOC_CODE_SIGNING_ALLOWED"
#   期望：Automatic / "Apple Development" / <你的Team> / NO
```

门禁只看 `Debug Release`（`Scripts/check.sh:106`），所以：

```bash
bash Scripts/check.sh      # 仍应全绿，与加配置之前一致
```

---

## 7. 常见错误

| 错误 | 原因 | 解法 |
|---|---|---|
| `No profiles for 'cn.covalink.ios' were found` | 首次签名没让 Xcode 自动注册 | 加 `-allowProvisioningUpdates`；或先在 Xcode 里 ▶ 一次 |
| `Failed to register bundle identifier` | `cn.covalink.ios` 已被别人（付费账号）注册过 | 把 `Config/DeviceLocal.xcconfig` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 取消注释改成独有值，如 `cn.covalink.ios.yourname`。**只影响 DeviceLocal** |
| `Untrusted Developer` | 免费账号首次装的正常拦截 | 设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID |
| `Signing for "Cova" requires a development team` | `DEVELOPMENT_TEAM` 还是空的 | §2 |
| App 装好了但 7 天后打不开 | 免费账号证书过期 | §5 重装 |
| `xcodebuild: error: Unable to find a destination matching ...` | UDID 写错，或手机没连/没信任 | `xcrun devicectl list devices` 重新拿；检查数据线和「信任此电脑」 |

---

## 8. 边界（先说清楚，免得误会）

- **装上 ≠ 能上架**。免费账号只能装**你自己名下**的设备，不能分发、不能走 App Store、
  不能用 TestFlight。
- **内购不可用**。免费账号签的 App 走不了沙盒内购，`iap/verify` 那条验签链也还没接
  （见 `DEVELOPMENT.md` §7）。真机测试**只能测不花钱的路径**（浏览、搜索、播放、登录），
  **测不了真实购买扣费**。
- **推送通知**在免费个人团队下不可用（需要付费 Team 的 Push 能力）。
- 要上架或收钱，必须先办付费开发者资格，且 `iap/verify` 验签必须先修好。
