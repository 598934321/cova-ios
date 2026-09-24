#!/usr/bin/env bash
# 本地门禁（G0–G4 全程复用，fail-closed）：
#   0 预热模拟器 → 1 生成工程 → 2 结构/语言模式/工程依赖令牌 → 3 依赖图 + 平台中立性 + 播放器无 UI 不变量
#   → 4 有效构建设置（配置×SDK）+ clean build + 实际编译语言版本 + 产物保真
#   → 5 应用测试（xcresult passed/failed）+ xccov 采集有效性 → 6 核心层 iOS 测试
#   → 7 核心层覆盖率（SwiftPM 插桩，含编译集合一致性与实际语言版本断言）
#   → 8 播放器层 iOS 测试（xcresult passed/failed，产出模拟器侧插桩 profraw/profdata）
#   → 9 播放器层行覆盖率（**与 7/10 同方法论**：8/10 的 Coverage.profdata + 测试二进制走
#     llvm-cov lcov；含「全部 target」编译集合一致性、映射侧↔运行侧文件集一致性与产物侧无 UI 判据）
#
# 判定方法论（第五轮评审裁决）：
#   * 能用机器可读产物表达的事实，一律不得用文本正则判定：
#       - 依赖方向/依赖类型/语言版本/目标类型 → `swift package dump-package`（JSON，plutil 解析）
#       - 实际编译语言版本 → 实际构建日志（Xcode *.xcactivitylog / SwiftPM -v 的 -swift-version）
#       - 实际被编译的文件集合 → SwiftPM .SwiftFileList 产物
#       - 测试执行数 → xcresult（只认 passed，failed 必须为 0）
#   * 文本仅用于「字面令牌存在性」判定（无法被语法伪装、且与语义等价）：
#       #if（条件编译）、iOS-only 模块名（词边界）、XCRemoteSwiftPackageReference、-swift-version、
#       .binaryTarget(、.swiftLanguageMode(( 后两者同时有 dump-package 权威兜底）。
#   * 威胁模型边界：本门禁防「无意回归」与「锁定决策失守」，**不防**蓄意编辑 check.sh 自身
#     （那等同删除门禁，超出仓内门禁能力边界）。修复目标是让绕过必须直接改门禁文件，
#     而不是靠日常合法语法变体（空白/注释/条件键/路径重定向/target 级覆盖）。
#   * 字面令牌判定可能因注释/字符串误报 —— 这是刻意的 fail-closed；若命中，请删除该文本或调整实现，
#     不要为此弱化门禁。
#   * 环 4 修复（G-9/G-10/G-11/G-12/G-13）新增的口径：
#       - G-9：覆盖率判据必须**从干净 clone 可复现**。xccov 在同一份产物上会把本地包目标折叠进
#         测试 target（干净副本实测 `CovaPlayer 0.00% (0/0)` + 报告 0 行点名 Sources），故 9/10
#         不再消费 xccov 文本，改消费 8/10 真实运行产出的 Coverage.profdata（llvm-cov lcov）。
#       - G-10：入库的 .env 文件**不再被 `.` source**，只做键名白名单逐行解析（否则它可以覆写
#         脚本里钉死的常量，绕过无需改 check.sh）。
#       - G-11：「播放器层禁 UI」不再只靠行首 import 正则：加 dump-package 的 **target 级**依赖与
#         源路径校验、包内符号链接整类禁令、以及构建产物侧判据（目标 .o 的符号引用 + 测试二进制
#         的 dylib 依赖）。字面正则保留为附加防线，且只收紧不放宽。
#       - G-12：覆盖率分母必须等于「被编译且产物带 __llvm_covmap 区间」的文件集合，且运行侧点名的
#         文件集合必须等于同一批二进制的映射侧（`--empty-profile`）集合 —— 只报局部文件的报告与
#         陈旧二进制都不再可能放行。无区间文件（协议 / 仅 case 枚举 / 仅注释）两侧同时缺席，
#         故不按「编译文件数」强等（那会在合法文件上误红，TD-9；见 7/10 同类结论）。
#   * 环 4 第 2 批（复审 F-9 / F-10）再收两条，仍遵循「只追加、不放宽」：
#       - G-14：播放器层「禁 UI」的三条判据改由**单一词源** PLAYER_UI_MODULES（12 项）派生。
#         上一轮词表只有 `SwiftUI|UIKit`，复审实例往 Sources/CovaPlayer/ 放 `import AVKit` +
#         构造/配置 AVPlayerViewController 后**完整门禁 EXIT=0**（步骤 3 打印「无 UI import」、
#         步骤 9 打印「无 UI 符号引用」、分母 16 文件证明确实编译了）。
#       - G-15：G-12 的 __llvm_covmap 真分母判定**无条件生效**。旧实现按「.o 与源文件 basename
#         同名」猜测归因，任一猜不到就整段跳过（只 echo 一行提示）⇒ 布局漂移即静默免检。
#         现改为消费编译器自己写出的 <Target>-OutputFileMap.json（机器可读产物），
#         并做「编译集合 ↔ map ↔ objdir 内 .o」三向全等，归因不可能一律 fail-closed。
#         ⚠ 可达性据实说明见 9.1 段首（第 3 轮复审实测：篡改 OutputFileMap / 替换 .o 会被
#           构建自修 ⇒ 那两条攻击形态在本步不可达，属纵深防御，不要当作「已实测拦住」）。
#   * 环 4 第 3 批（**同一失守面第 3 次复现 → 换判据形态**，手册 §4 第 8 条）：
#       - G-16（主判据换形态：黑名单 → 白名单）：播放器层（含其**测试 target**）的 import
#         只允许固定允许清单 PLAYER_ALLOWED_NONTEST_MODULES（测试侧再 +XCTest）；
#         任何不在清单内的模块（含未来出现的任何新 UI 框架）即红。
#         为什么必须换形态：G-11 的 L1 只认 SwiftUI/UIKit → 复审判 AVKit 全绿（G-14，扩到 12 项）
#         → 第 3 轮复审又判 `import WebKit` + `WKWebView(frame:.zero)` + `loadHTMLString` 放进
#         Sources/CovaPlayer/ **完整门禁 EXIT=0**（`import SafariServices`、`import MessageUI`
#         各自也 EXIT=0）。根因不是「少列了三个框架」，而是**黑名单靠人列举，永远漏**：
#         推导基 IOS_ONLY_MODULES 是「iOS-only 框架」集，WebKit/SafariServices/MessageUI 因
#         macOS 也有而不在其中 ⇒「UI 框架全集」无法由它派生，只能反过来钉「允许清单」。
#         清单成员全部来自实测（见常量区注释），并加规模/成员下界断言，防止清空或删项放行。
#         旧黑名单（PLAYER_UI_MODULES，本轮再补 WebKit/SafariServices/MessageUI 三项实证）
#         保留为**附加防线**，一字不放宽。
#       - G-17（三层判据一律覆盖**测试 target**，第 3 轮复审实测缺口）：复审把
#         `import UIKit` + `UIView` 只放进 CovaPlayerTests 后三层皆不可见 ——
#         L1 只扫 `m_type = "regular"`；符号层 objdir 集合只含产品 target 的 CovaPlayer-t.build
#         （`CovaPlayerTests-p.build/GateUIKitInTests.o` 里的 `_OBJC_CLASS_$_UIView` 从未被读）；
#         dylib 层对 UIKit **整名**豁免。现三层都纳入测试 target，且 UIKit 豁免**收窄为
#         「UIKit 且 weak」**。实测依据（本批干净 clone 产物）：合法态测试二进制的 UIKit 条目是
#         `/System/Library/Frameworks/UIKit.framework/UIKit (compatibility version 1.0.0,
#         current version 9127.0.84, weak)`，由 AVFoundation 的 Swift overlay 以 -weak_framework
#         拖入；一旦本层直接引用即变**强依赖** ⇒ weak 确实承载信号。上一批写进注释的
#         「weak 与否不承载信号」已被实测否证，本批据实改判（这是收窄，不是放宽）。
# 任一步失败均非零退出；日志落在 .build/check/ 下（.build/ 不入 git）。
# 用法：./Scripts/check.sh
set -euo pipefail

# 物理路径（pwd -P）：dump-package / .SwiftFileList 由工具链输出真实路径，
# 若本仓经符号链接访问（如 /tmp -> /private/tmp），非物理 ROOT 会导致前缀比对误判。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

SCHEME="Cova"
PROJECT="Cova.xcodeproj"
PBX="$PROJECT/project.pbxproj"
SIM_NAME="${COVA_SIM_NAME:-iPhone 17 Pro}"
DESTINATION="platform=iOS Simulator,name=$SIM_NAME"
LOG_DIR="$ROOT/.build/check"
DERIVED_DATA="$LOG_DIR/DerivedData"
PACKAGE_DERIVED_DATA="$LOG_DIR/DerivedData-CovaCore"
BUILD_MARKER="$LOG_DIR/.build-start-marker"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Cova.app"
RESULT_BUNDLE="$LOG_DIR/Cova.xcresult"
CORE_RESULT_BUNDLE="$LOG_DIR/CovaCoreTests.xcresult"
PLAYER_RESULT_BUNDLE="$LOG_DIR/CovaPlayerTests.xcresult"
PLAYER_PACKAGE_DERIVED_DATA="$LOG_DIR/DerivedData-CovaPlayer"
PLAYER_PROF_MARKER="$LOG_DIR/.player-profile-start-marker"
# 3/10 从 dump-package 落盘的目标清单：pkg \t type \t 物理源目录（9/10 复用，避免二次解析口径漂移）
TARGET_MANIFEST="$LOG_DIR/target-manifest.tsv"
BASELINE_FILE="$ROOT/Scripts/test-count-baseline.env"
mkdir -p "$LOG_DIR"

PACKAGES="CovaCore CovaPlayer CovaUI CovaFeature"
CORE_DIR="Packages/CovaCore"
CORE_PACKAGE_SWIFT="$CORE_DIR/Package.swift"
CONFIGURATIONS="Debug Release"
# 实际构建与设置校验使用的 SDK 必须一致
SETTINGS_SDKS="iphonesimulator iphoneos"

# 覆盖率阈值：常量基准，环境变量只允许抬高（防止把门禁调到 0 绕过）
COVERAGE_FLOOR=80
# R11-7（第 11 轮）：文档过去把**实测值**写成阈值（「CovaPlayer 94.80%，≥94.80% 达标」），
# 而脚本阈值其实是 `COVERAGE_FLOOR` = 80 ⇒ 行覆盖掉到 80.01% 照样 EXIT=0，
# 「只允许抬高」那条逻辑没有持久落点（抬阈值只能靠一次性环境变量）。
# 现在把两层各钉到 94（实测 CovaCore 95.31% / CovaPlayer 94.79% 之下，远高于基准 80）：
# 文档与门禁说的是同一件事，且阈值只能再往上抬。
CORE_COVERAGE_MIN=94
PLAYER_COVERAGE_MIN=94

# 钉死的关键配置（D1 / D13 / AGENTS 版本规则）
REQUIRED_APP_BUNDLE_ID="cn.covalink.ios"
REQUIRED_TEST_BUNDLE_ID="cn.covalink.ios.tests"
REQUIRED_DEPLOYMENT_TARGET="26.0"
REQUIRED_SWIFT_VERSION="6.0"
REQUIRED_EFFECTIVE_SWIFT="6"
REQUIRED_STRICT_CONCURRENCY="complete"
REQUIRED_LANGUAGE_VERSION="6"
# CovaCore 是纯逻辑层（D3/D9），覆盖率在宿主侧测量 → 不得引用 iOS-only 框架
# （字面令牌按词边界匹配：无法用 import/* */Foo 之类语法伪装；注释误报属 fail-closed）
# G-16 追加 WebKit / SafariServices / MessageUI：这三个在 macOS 上**也有**，所以历史上没被
# 归进「iOS-only」集（第 3 轮复审正是从这条缝里过去的）。但 CovaCore 是平台中立的纯逻辑层，
# 它禁的是「任何 UI / 设备侧框架」，不是「只有 iOS 才有的框架」⇒ 补进来既符合 D3/D9 语义，
# 也堵住「把 UI 代码放进 CovaCore、让播放器层通过 import CovaCore 间接拿到 UI」这条传递路径
# （CovaPlayer 唯一允许依赖的包就是 CovaCore）。只追加、不删除 ⇒ 对 CovaCore 是净收紧。
IOS_ONLY_MODULES="UIKit SwiftUI AVFoundation AVKit ARKit RealityKit CoreMotion HealthKit WidgetKit Photos PhotosUI BackgroundTasks CallKit WatchKit SpriteKit MetalKit MapKit RoomPlan WebKit SafariServices MessageUI"
# CovaCore 平台声明白名单（.macOS 仅用于宿主侧覆盖率测量，不得用于产品分支）
REQUIRED_CORE_PLATFORMS=".iOS(.v26),.macOS(.v14)"
# G-18（第 3 批 Minor-4）：**四个包**的 platforms 都必须钉死到 D1（iOS 26）。
# 权威来源是 dump-package（`platforms:` 行文本可被整行删除 / 注释 / 拆成多行来绕过 grep 判据，
# 上一轮就是只有 CovaCore 被等值钉住，其余三个改成 .v15 不触红）。形态 = "name=version" 集合。
required_platforms_for() {
  case "$1" in
    CovaCore)    echo "ios=26.0 macos=14.0" ;;
    CovaPlayer)  echo "ios=26.0" ;;
    CovaUI)      echo "ios=26.0" ;;
    CovaFeature) echo "ios=26.0" ;;
    *)           echo "" ;;
  esac
}
# 播放器层（G3-e）：包名 + 两套方向的判据 —— 主判据 G-16 白名单（PLAYER_ALLOWED_*），
# 附加防线 G-14 黑名单（PLAYER_UI_MODULES，三处判据的单一词源）。
PLAYER_PKG="CovaPlayer"
PLAYER_PKG_DIR="Packages/CovaPlayer"
# 行首 import（附加防线的第一段 + G-16 白名单的锚定段）：在既有 `(@属性 )*import` 基础上
# **只追加**可识别的前缀形态 —— 块注释前缀（`/* c */ import`）、访问级修饰符
# （public/internal/private/fileprivate/package）、带参数的属性（`@_spi(Cova) import` /
# `@_exported(…) import`；环 4 第 2 批补漏：实测 `@_spi(Cova) import WidgetKit` 在旧写法下绕过 L1），
# 以及本轮补的 `preconcurrency import`（实测旧写法漏检）。
# 每一类都是**可选组** ⇒ 命中集合只增不减（新 PLAYER_IMPORT_LINE_RE 是旧写法的严格超集）。
# 不允许 `//` 行注释前缀，故「注释掉的 import」依旧不误红（TD-9 合法工程对照；
# 实测 Sources/CovaPlayer/NowPlayingController.swift 的文档注释里就有「刻意不引入 UIKit」字样，
# 整文件词边界扫描会在合法工程误红 ⇒ 播放器层的字面判据必须保持行锚定形态）。
# 声明式 import（`import class AVKit.AVPlayerViewController`）本就命中段 1（只看行首的
# `import`），G-16 的模块名解析取 `class` 之后的第一段 ⇒ 也红。
# 本轮再补两个可选前缀形态（都是可选组 ⇒ 命中集合只增不减）：
#   * `*/ import X`：跨行块注释的**收尾行**与 import 同行（旧 RE 看不见，实测可编译）；
#   * `preconcurrency import X`：旧 RE 的修饰符组里没有它（实测漏检）。
# 拆成 TOKEN + 尾部两段：TOKEN 供 grep -oE 剥前缀用（BSD sed -E 不接受本 RE 里的 `\(`，
# 实测报「parentheses not balanced」，故不能用 sed 剥），尾部区分「同行有模块名」与
# 「模块名在下一行」两种形态（后者实测 Swift 可编译：`import` 换行 + 缩进 + 模块名）。
PLAYER_IMPORT_TOKEN_RE='^[[:space:]]*((\*[[:space:]]*)*/[[:space:]]*)?(/\*[^*]*\*+([^/*][^*]*\*+)*/[[:space:]]*)*(@[A-Za-z_]+(\([^()]*\))?[[:space:]]+)*(public[[:space:]]+|internal[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|package[[:space:]]+|preconcurrency[[:space:]]+)?import'
PLAYER_IMPORT_LINE_RE="${PLAYER_IMPORT_TOKEN_RE}[[:space:]]"
# 行尾即 import（模块名被换行拆开）：旧 L1 完全看不见这种形态，G-16 一并纳入
PLAYER_IMPORT_CONT_RE="${PLAYER_IMPORT_TOKEN_RE}[[:space:]]*\$"
# ── G-16（**主判据**）：播放器层 import 白名单。判据方向与黑名单相反 ——
#    黑名单要人列举「哪些框架算 UI」（已连漏三轮），白名单只需钉住「本层实际用到哪些」，
#    于是任何新框架（WebKit / SafariServices / MessageUI / 未来任何 UI 框架）默认即红。
#    成员**全部来自实测**，不是拍脑袋：
#      $ grep -rE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)?(public |internal |private |fileprivate |package )?import ' \
#          Packages/CovaPlayer/{Sources,Tests}
#      → 非测试 15 个源文件：AVFoundation(3) CovaCore(6) Foundation(16) MediaPlayer(1)，**无其它**
#        测试 11 个文件：     AVFoundation(4) CovaCore(9) Foundation(8) MediaPlayer(1) XCTest(10)
#                             @testable CovaPlayer(11)
#    ⇒ 允许清单 = 实测集合，**不含任何未使用的模块**（刻意不预先塞 Darwin/Dispatch/os/CoreGraphics/
#      CoreMedia 这类「以后可能用到」的项：清单里每一项都被真实源码使用 ⇒「删掉任意一项」当场即红，
#      这比任何下界断言都硬，也正是 Minor-2 要的闭合方式）。将来确需新模块时必须显式改本清单，
#      该改动随 commit 进入审查；而任何 UI 框架塞进清单会被下方的「允许清单 ∩ UI 词源 = ∅」断言
#      与 L1 黑名单、符号层、依赖表层同时拦住（四道，不是一道）。
#    判据面（据实说明，不夸大）：白名单拦的是「编译期模块依赖」（import 语句的各种合法写法），
#      符号层/依赖表层拦的是「产物里真的引用/链接了 UI 框架符号」。纯字符串反射
#      （`NSClassFromString("WKWebView")`）与 dlopen 不产生编译期依赖也不产生 UI 符号 ⇒
#      不在本门禁的拦截面内，那属「蓄意伪装」，与开头「威胁模型边界」一致（要拦它得靠静态
#      语法级检查或运行时白名单，超出仓内门禁能力）。
PLAYER_ALLOWED_NONTEST_MODULES="Foundation AVFoundation MediaPlayer CovaCore"
# 测试 target 在此之上追加：XCTest（框架）+ 被测模块本身（`@testable import CovaPlayer`）
PLAYER_ALLOWED_TEST_EXTRA_MODULES="XCTest"
# 下界（Minor-2）：规模与成员都不许缩。REQUIRED_* 是上面实测得到的集合。
PLAYER_ALLOWED_NONTEST_MIN=4
PLAYER_ALLOWED_TEST_MIN=5
PLAYER_ALLOWED_REQUIRED_NONTEST="Foundation AVFoundation MediaPlayer CovaCore"
PLAYER_ALLOWED_REQUIRED_TEST="Foundation AVFoundation MediaPlayer CovaCore XCTest"
# ── 附加防线（G-14 黑名单，只追加不放宽）：本轮把第 3 轮复审实测漏掉的三个框架点名补进词源。
#    三条判据（L1 字面 import / L3 目标 .o 的 Swift mangling / L3 测试二进制的框架依赖表）
#    **全部**由本变量派生，不再各写一份字面量 —— 上一轮正是「三层共用一份只有 SwiftUI|UIKit
#    的词表」被一次 `import AVKit` 整体绕过。
#    为什么不能由 IOS_ONLY_MODULES 推导（Major-1）：那是「iOS-only 框架」集，
#    WebKit/SafariServices/MessageUI 在 macOS 上也有 ⇒ 不在其中 ⇒「UI 框架全集」无法派生。
#    **不含**播放器层合法依赖：AVFoundation / MediaPlayer / CoreMedia / Foundation / CovaCore。
#    三处匹配都是「整名」形态，故前缀不会互相误伤（实测合法工程三处均零命中）：
#      L1 词边界（`AVFoundation` 不含词 `AVKit`）、L3 长度前缀（`$s12AVFoundation` ≠ `$s5AVKit`、
#      `Metal` ≠ `MetalKit`）、L3 `<名>.framework` 字面子串（`Photos` 不在词表内，`PhotosUI` 独享）。
PLAYER_UI_MODULES="SwiftUI UIKit AVKit PhotosUI MapKit MetalKit SpriteKit WidgetKit CallKit WatchKit RealityKit RoomPlan WebKit SafariServices MessageUI"
# L3 框架依赖表里**只在「该框架且 weak」时**容忍的项（G-17，第 3 轮实测）：
# 合法态测试二进制确实带 UIKit，但是 weak（AVFoundation 的 Swift overlay 以 -weak_framework 拖入）；
# 本层一旦出现直接引用即变强依赖 ⇒ 「weak 与否」承载信号，豁免面从「整名」收窄为「名 + weak 属性」。
# 上一轮的 PLAYER_UI_DYLIB_EXEMPT（整名豁免）与「weak 不承载信号」的依据均已被实测否证。
PLAYER_UI_DYLIB_WEAK_OK="UIKit"
# 产物侧判据（L3 符号层）：Swift mangling 里模块名带长度前缀，可精确归属（llvm-nm 输出形如
# `_$s5AVKit…`）；UIKit 的 ObjC 类只能按类名前缀归属（`_OBJC_CLASS_$_UIView` 等）——实测合法工程
# （AV*/MP*）零命中。
# 注意：`__swift_FORCE_LOAD_$_swiftUIKit` 在**合法**工程里也存在（AVFoundation 的 Swift overlay 拖入），
# 故不得作为判据，否则合法工程必误红（TD-9）。
# 另：实测 ObjC 类 UI 控制器（AVPlayerViewController）在 .o 里**只有** `_OBJC_CLASS_$_…` 形态、
# 没有 `$s5AVKit` mangling —— 所以符号层必须与框架依赖表层同时存在，缺一即有漏检面。

fail() {
  echo "❌ $1"
  exit 1
}

# ── G-16：白名单自检 —— 清单本身不许被缩/被清空/被塞进 UI 框架（Minor-2 的闭合面）。
# 三处扫描（3/10 目录级、9/10 编译集合级，均含测试 target）都从这两个变量派生。
PLAYER_ALLOWED_TEST_MODULES="${PLAYER_ALLOWED_NONTEST_MODULES} ${PLAYER_ALLOWED_TEST_EXTRA_MODULES}"
# (a) 规模下界
PLAYER_ALLOWED_NONTEST_N="$(printf '%s\n' "$PLAYER_ALLOWED_NONTEST_MODULES" | wc -w | tr -d ' ')"
PLAYER_ALLOWED_TEST_N="$(printf '%s\n' "$PLAYER_ALLOWED_TEST_MODULES" | wc -w | tr -d ' ')"
[ "${PLAYER_ALLOWED_NONTEST_N:-0}" -ge "$PLAYER_ALLOWED_NONTEST_MIN" ] \
  || fail "G-16 播放器层非测试允许清单规模 ${PLAYER_ALLOWED_NONTEST_N} < 下界 ${PLAYER_ALLOWED_NONTEST_MIN}：清空/裁剪清单不得成为放行手段"
[ "${PLAYER_ALLOWED_TEST_N:-0}" -ge "$PLAYER_ALLOWED_TEST_MIN" ] \
  || fail "G-16 播放器层测试允许清单规模 ${PLAYER_ALLOWED_TEST_N} < 下界 ${PLAYER_ALLOWED_TEST_MIN}：清空/裁剪清单不得成为放行手段"
# (b) 逐成员存在性（「从清单里删一项」当场即红，不依赖是否还有代码用到它）
for _am in $PLAYER_ALLOWED_REQUIRED_NONTEST; do
  case " $PLAYER_ALLOWED_NONTEST_MODULES " in
    *" $_am "*) ;;
    *) fail "G-16 非测试允许清单缺必需成员 '${_am}'（实测 15 个源文件正在 import 它）：删项即删判据，拒绝执行" ;;
  esac
done
for _am in $PLAYER_ALLOWED_REQUIRED_TEST; do
  case " $PLAYER_ALLOWED_TEST_MODULES " in
    *" $_am "*) ;;
    *) fail "G-16 测试允许清单缺必需成员 '${_am}'（实测测试文件正在 import 它）：删项即删判据，拒绝执行" ;;
  esac
done
# (c) 允许清单与 UI 词源必须互斥（「把 SwiftUI/WebKit 加进白名单」不是可用的绕过路径）
for _am in $PLAYER_ALLOWED_NONTEST_MODULES $PLAYER_ALLOWED_TEST_EXTRA_MODULES; do
  case " $PLAYER_UI_MODULES " in
    *" $_am "*) fail "G-16 允许清单含 UI 词源成员 '${_am}'：白名单被污染即失去判据（G-14 词源为禁）" ;;
  esac
done
# (d) 白名单必须比黑名单「窄」到不含任何 UI 面（由 (c) 保证）；再断言黑名单非空，
#     防止有人把 PLAYER_UI_MODULES 清空来同时抹掉三条附加防线。
[ -n "$PLAYER_UI_MODULES" ] || fail "G-14 黑名单 PLAYER_UI_MODULES 为空：三条附加防线同时失效"

# ── G-14：三处判据的词表**全部**从 PLAYER_UI_MODULES 派生（同源），并自检派生一致性。
# L1：import 行的模块词（grep -w 词边界）
PLAYER_UI_WORD_RE="$(printf '%s' "$PLAYER_UI_MODULES" | tr ' ' '|')"
# L3 符号层：`$s<字节数><模块名>` mangling 前缀 alternation（长度前缀即精确归属的依据）
PLAYER_UI_MANGLE=""
for _ui_m in $PLAYER_UI_MODULES; do
  _ui_len=$(( ${#_ui_m} ))
  if [ -z "$PLAYER_UI_MANGLE" ]; then PLAYER_UI_MANGLE="${_ui_len}${_ui_m}"
  else PLAYER_UI_MANGLE="${PLAYER_UI_MANGLE}|${_ui_len}${_ui_m}"; fi
done
[ -n "$PLAYER_UI_MANGLE" ] || fail "PLAYER_UI_MODULES 为空：禁 UI 判据被清空（G-14 词源自检）"
# ObjC 类前缀只能按类名前缀归属：UI*（UIKit）、WK*（WebKit）、SF*（SafariServices）、
# MF*（MessageUI）—— 实测合法工程（AV*/MP*/NS*/XCTest*）四类前缀零命中。
PLAYER_UI_OBJC_PREFIXES="UI WK SF MF"
PLAYER_UI_OBJC_ALT="$(printf '%s' "$PLAYER_UI_OBJC_PREFIXES" | tr ' ' '|')"
PLAYER_UI_SYMBOL_RE='\$s('"$PLAYER_UI_MANGLE"')|_OBJC_CLASS_\$_('"$PLAYER_UI_OBJC_ALT"')[A-Z]'
# L3 依赖表层：词源**全量**参与判定（G-17 起不再有「整名豁免」，只在「名 + weak」时容忍）
PLAYER_UI_DYLIB_MODULES="$PLAYER_UI_MODULES"
# 词源自检：weak 容忍表必须是词表的子集，否则「从词表删掉某项」会让该表静默漂移
for _ui_e in $PLAYER_UI_DYLIB_WEAK_OK; do
  case " $PLAYER_UI_MODULES " in
    *" $_ui_e "*) ;;
    *) fail "PLAYER_UI_DYLIB_WEAK_OK 含不在词源里的 '${_ui_e}'：G-14/G-17 词表已漂移，请人工复核三处判据" ;;
  esac
done
# 词源自检：任何一层被清空都等于删掉该层判据
[ -n "$PLAYER_UI_WORD_RE" ] || fail "L1 字面词表为空（G-14 词源自检）"
[ -n "$PLAYER_UI_DYLIB_MODULES" ] || fail "L3 框架依赖词表为空（G-14/G-17 词源自检）"
[ -n "$PLAYER_UI_OBJC_ALT" ] || fail "L3 符号层的 ObjC 类前缀表为空（G-14 词源自检）"
# G-17：weak 容忍表**规模上界**= 1。目前只有 UIKit 一个经验证的「被 overlay 以 -weak_framework
# 拖入」的项；把任何别的框架塞进这张表都是在扩大豁免面，必须与实测证据一起走评审，而不是改一行。
[ "$(printf '%s\n' "$PLAYER_UI_DYLIB_WEAK_OK" | wc -w | tr -d ' ')" -le 1 ] \
  || fail "PLAYER_UI_DYLIB_WEAK_OK 规模 > 1：G-17 只允许 UIKit 一项以 weak 形态豁免（扩大豁免面需评审）"

# 阈值只允许抬高：任何低于基准的取值一律拒绝执行（fail-closed）
if [ -n "${COVA_CORE_COVERAGE_MIN:-}" ]; then
  case "$COVA_CORE_COVERAGE_MIN" in
    ''|*[!0-9]*) fail "COVA_CORE_COVERAGE_MIN 必须是整数，收到 '${COVA_CORE_COVERAGE_MIN}'" ;;
  esac
  [ "$COVA_CORE_COVERAGE_MIN" -ge "$COVERAGE_FLOOR" ] \
    || fail "COVA_CORE_COVERAGE_MIN=${COVA_CORE_COVERAGE_MIN} < 基准 ${COVERAGE_FLOOR}：阈值只允许抬高，拒绝执行"
  CORE_COVERAGE_MIN="$COVA_CORE_COVERAGE_MIN"
  echo "提示：核心层覆盖率阈值被抬高到 ${CORE_COVERAGE_MIN}%（基准 ${COVERAGE_FLOOR}%）"
fi

if [ -n "${COVA_PLAYER_COVERAGE_MIN:-}" ]; then
  case "$COVA_PLAYER_COVERAGE_MIN" in
    ''|*[!0-9]*) fail "COVA_PLAYER_COVERAGE_MIN 必须是整数，收到 '${COVA_PLAYER_COVERAGE_MIN}'" ;;
  esac
  [ "$COVA_PLAYER_COVERAGE_MIN" -ge "$COVERAGE_FLOOR" ] \
    || fail "COVA_PLAYER_COVERAGE_MIN=${COVA_PLAYER_COVERAGE_MIN} < 基准 ${COVERAGE_FLOOR}：阈值只允许抬高，拒绝执行"
  PLAYER_COVERAGE_MIN="$COVA_PLAYER_COVERAGE_MIN"
  echo "提示：播放器层覆盖率阈值被抬高到 ${PLAYER_COVERAGE_MIN}%（基准 ${COVERAGE_FLOOR}%）"
fi

# 测试数量下限来自入库基线文件（删测试必须显式改它，随 commit 进入审查）。
# G-10：本文件**不再被 `.` source**。被 source 时它可以覆写脚本里钉死的常量
# （CORE_COVERAGE_MIN / PLAYER_COVERAGE_MIN 在本段之后才被消费，REQUIRED_DEPLOYMENT_TARGET、
#  IOS_ONLY_MODULES 同理），于是「阈值抬高失守 + iOS-only 扫描整轮空转」可以在不改 check.sh 一行
# 的情况下发生。改为按键名白名单逐行解析：只接受 APP_MIN / CORE_MIN / PLAYER_MIN 三个整数键，
# 其余任何行（其它键、赋值形态、内联注释、重复键）一律拒绝并非零退出。
[ -f "$BASELINE_FILE" ] || fail "缺少测试数量基线文件 ${BASELINE_FILE}"
BASELINE_KEYS="APP_MIN CORE_MIN PLAYER_MIN"
APP_MIN="" CORE_MIN="" PLAYER_MIN=""
BASELINE_LINENO=0
while IFS= read -r bline || [ -n "$bline" ]; do
  BASELINE_LINENO=$((BASELINE_LINENO + 1))
  # 前导/行尾空白剪裁（bash 3.2 兼容写法；空白不承载语义，但也不允许夹带赋值）
  btrim="${bline#"${bline%%[![:space:]]*}"}"
  btrim="${btrim%"${btrim##*[![:space:]]}"}"
  [ -n "$btrim" ] || continue                 # 空行/纯空白
  case "$btrim" in '#'*) continue ;; esac     # 整行注释
  case "$btrim" in
    *=*) ;;
    *) fail "基线文件第 ${BASELINE_LINENO} 行不是 KEY=VALUE 形态：'${btrim}'" ;;
  esac
  bkey="${btrim%%=*}"
  bval="${btrim#*=}"
  case " $BASELINE_KEYS " in
    *" $bkey "*) ;;
    *) fail "基线文件第 ${BASELINE_LINENO} 行含非白名单键 '${bkey}'：本文件不被 source，" \
"只允许 ${BASELINE_KEYS} 三个整数键（否则它可以覆写门禁钉死的常量，见 G-10）" ;;
  esac
  case "$bval" in
    ''|*[!0-9]*) fail "基线 ${bkey} 的值必须是纯整数（禁内联注释/空白/负数），收到 '${bval}'" ;;
  esac
  bprev="$(eval "printf '%s' \"\${${bkey}}\"")"
  [ -z "$bprev" ] || fail "基线键 '${bkey}' 重复赋值（先 ${bprev} 后 ${bval}）：拒绝最后一行覆盖前一行的静默改写"
  eval "${bkey}=\${bval}"
done < "$BASELINE_FILE"
[ -n "$APP_MIN" ] || fail "基线文件缺少 APP_MIN"
[ -n "$CORE_MIN" ] || fail "基线文件缺少 CORE_MIN"
[ -n "$PLAYER_MIN" ] || fail "基线文件缺少 PLAYER_MIN"
[ "$APP_MIN" -ge 1 ] || fail "基线 APP_MIN=${APP_MIN} 必须 >= 1（零测试不允许）"
[ "$CORE_MIN" -ge 1 ] || fail "基线 CORE_MIN=${CORE_MIN} 必须 >= 1（零测试不允许）"
# 播放器层是 G3 交付物之一，下限单独收紧（与 test-count-baseline.env 的注释口径一致）：
# 30 = 「队列 / 循环 / ±15s / 中断映射 / 上报去重 / 私有音频」六类规则的最小可断言面。
[ "$PLAYER_MIN" -ge 30 ] || fail "基线 PLAYER_MIN=${PLAYER_MIN} 必须 >= 30（播放器层最小可断言面）"

allowed_deps() {
  case "$1" in
    CovaCore)    echo "" ;;
    CovaPlayer)  echo "CovaCore" ;;
    CovaUI)      echo "CovaCore" ;;
    CovaFeature) echo "CovaCore CovaPlayer CovaUI" ;;
  esac
}

# 取包清单的权威机器可读表示（JSON）
DUMP_JSON=""
load_dump() { # $1 = pkg
  DUMP_JSON="$LOG_DIR/dump-$1.json"
  swift package --package-path "Packages/$1" dump-package > "$DUMP_JSON" 2>/dev/null
}

# 可信计数源：xcresult（只认 passed；failed 必须为 0；skipped 不计入）
xcresult_counts() { # bundle -> "passed failed skipped"
  local bundle="$1" json="$LOG_DIR/xcresult-summary.json" p f s
  xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$json" 2>/dev/null || return 1
  p="$(plutil -extract passedTests raw -o - "$json" 2>/dev/null || true)"
  f="$(plutil -extract failedTests raw -o - "$json" 2>/dev/null || true)"
  s="$(plutil -extract skippedTests raw -o - "$json" 2>/dev/null || true)"
  for v in "$p" "$f" "$s"; do
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  echo "$p $f $s"
}

assert_tests() { # label "passed failed skipped" baseline
  local label="$1" counts="$2" baseline="$3" p f s
  read -r p f s <<< "${counts:-}"
  case "${p:-}" in ''|*[!0-9]*) fail "${label}：无法取得可信用例计数（值='${counts:-}'）" ;; esac
  # G-13：三个计数与基线都必须是整数 —— 否则 `[ -eq` 会先吐「integer expression expected」
  # 再靠 set -e 退出，诊断信息被噪音淹没；这里给出明确判据（判定强度不变，仍是 fail-closed）。
  case "${f:-}" in ''|*[!0-9]*) fail "${label}：failed 计数不是整数（值='${counts:-}'）" ;; esac
  case "${s:-}" in ''|*[!0-9]*) fail "${label}：skipped 计数不是整数（值='${counts:-}'）" ;; esac
  case "${baseline:-}" in ''|*[!0-9]*) fail "${label}：基线值不是整数（值='${baseline:-}'）" ;; esac
  echo "    ${label}：passed=${p} failed=${f} skipped=${s}，基线=${baseline}（只认 passed）"
  [ "$f" -eq 0 ] || fail "${label}：failed=${f} 必须为 0"
  [ "$p" -ge "$baseline" ] \
    || fail "${label}：passed=${p} < 基线 ${baseline}（skipped 不计入，不得删除/弱化既有测试）"
}

echo "==> 0/10 预热模拟器（${SIM_NAME}）"
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null

echo "==> 1/10 生成工程（XcodeGen $(xcodegen --version | awk '{print $NF}')）"
xcodegen generate --spec project.yml

echo "==> 2/10 校验工程结构、语言模式与工程依赖令牌"
test -f project.yml || fail "缺少 project.yml"
test -f Config/Info.plist || fail "缺少 Config/Info.plist"
test -f Cova/CovaApp.swift || fail "缺少 Cova/CovaApp.swift"
test -d design/assets/CovaAssets.xcassets/AppIcon.appiconset || fail "缺少官方 AppIcon 资产"
test -f design/assets/CovaAssets.xcassets/AppIcon.appiconset/Contents.json || fail "AppIcon 资产缺少 Contents.json"
test -d CovaTests || fail "缺少 CovaTests 目录"
test -d "$CORE_DIR/Tests" || fail "缺少核心层测试目录 ${CORE_DIR}/Tests"
for pkg in $PACKAGES; do
  test -f "Packages/$pkg/Package.swift" || fail "缺少本地包 Packages/$pkg/Package.swift"
done

# project.yml 的字面令牌：远程包 / 框架声明（白名单为空；命中即失败，含注释）
for tok in 'url:' 'framework:' 'frameworks:'; do
  if grep -q --fixed-strings "$tok" project.yml; then
    fail "project.yml 含 '${tok}'：远程包/框架声明不在零第三方依赖白名单内（AGENTS.md 硬边界 4）"
  fi
done

# 生成物 pbxproj：不得有远程包引用；本地包引用必须恰为仓内 4 个
if grep -q --fixed-strings 'XCRemoteSwiftPackageReference' "$PBX"; then
  fail "工程含远程 SwiftPM 包引用（XCRemoteSwiftPackageReference）"
fi
EXPECTED_REFS="Packages/CovaCore Packages/CovaPlayer Packages/CovaUI Packages/CovaFeature"
REF_COUNT="$(grep -oE 'relativePath = [^;]+' "$PBX" | wc -l | tr -d ' ')"
[ "$REF_COUNT" = "4" ] || fail "工程本地包引用数 = ${REF_COUNT}，应为 4"
{ grep -oE 'relativePath = [^;]+' "$PBX" | sed -E 's/relativePath = //' | tr -d ' ' || true; } > "$LOG_DIR/pkg-refs.txt"
while IFS= read -r r; do
  [ -n "$r" ] || continue
  case " $EXPECTED_REFS " in
    *" $r "*) ;;
    *) fail "工程引用了非预期本地包路径：${r}（只允许仓内 Packages/ 四个包）" ;;
  esac
done < "$LOG_DIR/pkg-refs.txt"

# 语言模式：来自 dump-package（权威），并禁止 target 级语言模式覆盖与二进制制品（字面令牌）
for pkg in $PACKAGES; do
  load_dump "$pkg" || fail "无法获取 Packages/$pkg 的 dump-package（清单不可解析）"
  LANG_COUNT="$(plutil -extract swiftLanguageVersions raw -o - "$DUMP_JSON" 2>/dev/null || echo 0)"
  [ "${LANG_COUNT:-0}" -ge 1 ] || fail "Packages/$pkg 未声明 Swift 语言版本"
  i=0
  while [ "$i" -lt "$LANG_COUNT" ]; do
    v="$(plutil -extract "swiftLanguageVersions.$i" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    [ "$v" = "$REQUIRED_LANGUAGE_VERSION" ] \
      || fail "Packages/$pkg 的 Swift 语言版本为 '${v}'，必须为 ${REQUIRED_LANGUAGE_VERSION}"
    i=$((i + 1))
  done
  T_COUNT="$(plutil -extract targets raw -o - "$DUMP_JSON" 2>/dev/null || echo 0)"
  j=0
  while [ "$j" -lt "${T_COUNT:-0}" ]; do
    tt="$(plutil -extract "targets.$j.type" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    case "$tt" in
      regular|test) ;;
      *) fail "Packages/$pkg 的目标类型 '${tt}' 不被允许（只允许 regular/test，禁止二进制制品/插件）" ;;
    esac
    j=$((j + 1))
  done
  if grep -q --fixed-strings '.swiftLanguageMode(' "Packages/$pkg/Package.swift"; then
    fail "Packages/$pkg/Package.swift 含 .swiftLanguageMode(：可由 target 级下调语言模式"
  fi
  if grep -q --fixed-strings '.binaryTarget(' "Packages/$pkg/Package.swift"; then
    fail "Packages/$pkg/Package.swift 含 .binaryTarget(：二进制制品不在零依赖白名单内"
  fi
  # G-15 前置：9/10 的「.o ↔ 源文件」归因以 **per-file 编译布局**为前提（OutputFileMap 的
  # "object" 键）。`.unsafeFlags(` 可注入 -wmo 之类旗标把布局改成单产物，让真分母判定失去依据；
  # CovaCore 的清单早有同一禁令（见下方 .when(platforms)/.define/.unsafeFlags 令牌检查）。
  if grep -q --fixed-strings '.unsafeFlags(' "Packages/$pkg/Package.swift"; then
    fail "Packages/$pkg/Package.swift 含 .unsafeFlags(：可注入 -wmo 等编译旗标，破坏 7/10 与 9/10 的逐文件产物归因（G-15）"
  fi
  # G-18：平台声明以 dump-package 为权威逐项比对（缺失 / 多一个平台 / 版本被改，三种形态都红）。
  EXPECT_PLATFORMS="$(required_platforms_for "$pkg")"
  [ -n "$EXPECT_PLATFORMS" ] || fail "包 $pkg 无平台钉死值：D1 要求四个包都显式声明 platforms"
  PLAT_N="$(plutil -extract platforms raw -o - "$DUMP_JSON" 2>/dev/null || echo 0)"
  OBS_PLATFORMS=""
  pi=0
  while [ "$pi" -lt "${PLAT_N:-0}" ]; do
    pname="$(plutil -extract "platforms.$pi.platformName" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    pver="$(plutil -extract "platforms.$pi.version" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    { [ -n "$pname" ] && [ -n "$pver" ]; } \
      || fail "Packages/$pkg 的 platforms 第 $pi 项缺 platformName 或 version（dump-package 形态异常）"
    OBS_PLATFORMS="${OBS_PLATFORMS} ${pname}=${pver}"
    pi=$((pi + 1))
  done
  [ -n "${OBS_PLATFORMS# }" ] || fail "Packages/$pkg 未声明 platforms：部署目标必须由清单钉死（D1）"
  # 两侧都排序归一后逐字比对（声明顺序不承载语义，成员与版本承载）
  [ "$(printf '%s\n' ${OBS_PLATFORMS# } | sort | tr '\n' ' ')" = "$(printf '%s\n' ${EXPECT_PLATFORMS} | sort | tr '\n' ' ')" ] \
    || fail "Packages/$pkg 的 platforms 实为 [${OBS_PLATFORMS# }]，必须恰为 [${EXPECT_PLATFORMS}]（D1 钉死 iOS 26；CovaCore 另需 macOS 14 供宿主侧覆盖率测量）"
done
echo "    结构校验通过（4 个本地包、语言模式 6、无远程包/框架/二进制制品/unsafeFlags）"

echo "==> 3/10 依赖图（dump-package）+ 核心层平台中立性 + 播放器无 UI 不变量"
: > "$TARGET_MANIFEST"
violations=0
for pkg in $PACKAGES; do
  load_dump "$pkg" || fail "无法获取 Packages/$pkg 的 dump-package"
  DEP_COUNT="$(plutil -extract dependencies raw -o - "$DUMP_JSON" 2>/dev/null || echo 0)"
  k=0
  while [ "$k" -lt "${DEP_COUNT:-0}" ]; do
    dep_path="$(plutil -extract "dependencies.$k.fileSystem.0.path" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    [ -n "$dep_path" ] \
      || fail "Packages/$pkg 含非本地（sourceControl/registry）依赖：违反零第三方依赖白名单（硬边界 4）"
    case "$dep_path" in
      "$ROOT"/Packages/*) ;;
      *) fail "Packages/$pkg 依赖了仓外路径：${dep_path}" ;;
    esac
    dep_name="$(basename "$dep_path")"
    case " $PACKAGES " in
      *" $dep_name "*) ;;
      *) fail "Packages/$pkg 依赖了未登记的包：${dep_name}" ;;
    esac
    case " $(allowed_deps "$pkg") " in
      *" $dep_name "*) ;;
      *) echo "    依赖方向违规：$pkg 依赖了 ${dep_name}（D3 分层）"; violations=1 ;;
    esac
    k=$((k + 1))
  done

  # G-11（target 级失明修复）：包级 dependencies[] 之外还必须校验 **targets[].dependencies**，
  # 否则「在包内加一个 path: 指向包外的第二 target，并从 target 级依赖它」可以绕开第 3 步与第 9 步。
  # 权威来源同为 dump-package：byName / target / product 三种形态逐一判定，未知形态即失败。
  TGT_N="$(plutil -extract targets raw -o - "$DUMP_JSON" 2>/dev/null || echo 0)"
  OWN_TGTS=""
  z=0
  while [ "$z" -lt "${TGT_N:-0}" ]; do
    tname="$(plutil -extract "targets.$z.name" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    [ -n "$tname" ] || fail "Packages/$pkg 第 $z 个目标缺 name（dump-package 形态异常）"
    OWN_TGTS="${OWN_TGTS} ${tname}"
    z=$((z + 1))
  done
  m=0
  while [ "$m" -lt "${TGT_N:-0}" ]; do
    tname="$(plutil -extract "targets.$m.name" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    ttype="$(plutil -extract "targets.$m.type" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    TD_N="$(plutil -extract "targets.$m.dependencies" raw -o - "$DUMP_JSON" 2>/dev/null || echo 0)"
    d=0
    while [ "$d" -lt "${TD_N:-0}" ]; do
      dep_product="$(plutil -extract "targets.$m.dependencies.$d.product.0" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
      dep_product_pkg="$(plutil -extract "targets.$m.dependencies.$d.product.1" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
      dep_byname="$(plutil -extract "targets.$m.dependencies.$d.byName.0" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
      dep_target="$(plutil -extract "targets.$m.dependencies.$d.target.0" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
      if [ -n "$dep_product" ]; then
        # product 依赖：归属包必须已登记且在白名单方向内
        [ -n "$dep_product_pkg" ] \
          || { echo "    目标 $pkg/$tname 的 product 依赖 '${dep_product}' 未指明归属包（可被解析到任意包）"; violations=1; }
        case " $PACKAGES " in
          *" ${dep_product_pkg} "*) ;;
          *) echo "    目标 $pkg/$tname 依赖了未登记的包 ${dep_product_pkg}（target 级）"; violations=1 ;;
        esac
        case " $(allowed_deps "$pkg") " in
          *" ${dep_product_pkg} "*) ;;
          *) echo "    依赖方向违规（target 级）：$pkg/$tname 依赖了 ${dep_product_pkg}（D3 分层）"; violations=1 ;;
        esac
      elif [ -n "$dep_target" ]; then
        # target 依赖必须指向同包目标
        case " $OWN_TGTS " in
          *" $dep_target "*) ;;
          *) echo "    目标 $pkg/$tname 依赖了非本包目标 '${dep_target}'（target 级）"; violations=1 ;;
        esac
      elif [ -n "$dep_byname" ]; then
        # byName 可解析到同包目标或依赖包的产品：两种身份都必须已判定
        case " $OWN_TGTS " in
          *" $dep_byname "*) ;;
          *)
            case " $(allowed_deps "$pkg") " in
              *" $dep_byname "*) ;;
              *) echo "    目标 $pkg/$tname 的 byName 依赖 '${dep_byname}' 既非本包目标也非白名单包（target 级）"; violations=1 ;;
            esac ;;
        esac
      else
        echo "    目标 $pkg/$tname 出现无法识别的 target 级依赖形态（第 $d 项）：新增形态需评审"
        violations=1
      fi
      d=$((d + 1))
    done

    # 源路径：显式 path: 必须留在本包目录内（禁止绝对路径与 ..；符号链接另有整类禁令）
    trel="$(plutil -extract "targets.$m.path" raw -o - "$DUMP_JSON" 2>/dev/null || true)"
    if [ -z "$trel" ]; then
      case "$ttype" in
        test) trel="Tests/$tname" ;;
        *) trel="Sources/$tname" ;;
      esac
    fi
    case "$trel" in
      /*) echo "    目标 $pkg/$tname 的源路径为绝对路径：${trel}"; violations=1; trel="" ;;
      *..*) echo "    目标 $pkg/$tname 的源路径含 ..（越出包目录）：${trel}"; violations=1; trel="" ;;
    esac
    tdir=""
    if [ -n "$trel" ]; then
      if tdir="$(cd "$ROOT/Packages/$pkg/$trel" 2>/dev/null && pwd -P)"; then
        case "$tdir" in
          "$ROOT"/Packages/"$pkg"*) ;;
          *) echo "    目标 $pkg/$tname 声明路径 '${trel}' 经符号链接解析后越出包目录：${tdir}"; violations=1; tdir="" ;;
        esac
      else
        echo "    目标 $pkg/$tname 的源目录不存在：Packages/$pkg/$trel"
        violations=1
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$pkg" "$ttype" "$tdir" "$tname" >> "$TARGET_MANIFEST"
    m=$((m + 1))
  done
done

# 符号链接整类禁止（CovaCore 内）：SwiftPM 会跟随并编译，而 .SwiftFileList 记录词法路径，
# 二者差异正是「链接目录指向包外」的绕过机制；CovaCore 是纯逻辑层，不需要符号链接。
SYMLINKS="$(find Packages/CovaCore -type l -not -path '*/.*' 2>/dev/null || true)"
if [ -n "$SYMLINKS" ]; then
  printf '%s\n' "$SYMLINKS" | head -10 | sed 's/^/    /'
  fail "CovaCore 内存在符号链接（整类禁止，点号路径除外——SwiftPM 不编译点号目录；如需共享源文件请改为仓内真实文件）"
fi

# G-11：播放器层同款禁令。BSD `grep -r` 不跟随符号链接、`find -type f` 也不计符号链接，
# 而 SwiftPM 会跟随并编译 —— 「Sources/CovaPlayer/x.swift → 包外文件」或「目录级链接指向包外」
# 正好落在扫描域之外（12 个 .swift 只看得到 11）。播放器层不需要符号链接。
SYMLINKS_PLAYER="$(find Packages/CovaPlayer -type l -not -path '*/.*' 2>/dev/null || true)"
if [ -n "$SYMLINKS_PLAYER" ]; then
  printf '%s\n' "$SYMLINKS_PLAYER" | head -10 | sed 's/^/    /'
  fail "CovaPlayer 内存在符号链接（整类禁止：SwiftPM 跟随编译，而 grep -r / find -type f 都不看符号链接）"
fi

# 平台中立性不变量：字面 #if 即失败（条件编译整类禁止；注释/字符串中的命中亦拦，fail-closed）
CC_HITS="$(grep -rn --fixed-strings '#if' "$CORE_DIR" --exclude-dir=.build 2>/dev/null || true)"
if [ -n "$CC_HITS" ]; then
  echo "$CC_HITS" | head -20 | sed 's/^/    /'
  echo "    ↑ CovaCore 出现字面 #if：违反平台中立性不变量（整类禁止，含注释/字符串中的命中）"
  violations=1
fi
# iOS-only 框架：字面令牌（词边界，无法被 import/* */Foo 之类语法伪装）
IOS_HITS=""
for m in $IOS_ONLY_MODULES; do
  hit="$(grep -rnw "$m" "$CORE_DIR" --exclude-dir=.build 2>/dev/null || true)"
  [ -n "$hit" ] && IOS_HITS="${IOS_HITS}${hit}"$'\n'
done
if [ -n "$IOS_HITS" ]; then
  printf '%s' "$IOS_HITS" | head -20 | sed 's/^/    /'
  echo "    ↑ CovaCore 出现 iOS-only 框架字面令牌：宿主侧覆盖率口径无效"
  violations=1
fi
# Package.swift：平台条件构建设置（字面令牌）
if grep -Eq '\.when[[:space:]]*\([[:space:]]*platforms|\.define[[:space:]]*\(|\.unsafeFlags[[:space:]]*\(' "$CORE_PACKAGE_SWIFT"; then
  echo "    CovaCore/Package.swift 含平台条件构建设置（.when(platforms:) / .define( / .unsafeFlags(）"
  violations=1
fi
CORE_PLATFORMS="$(grep -E '^[[:space:]]*platforms:' "$CORE_PACKAGE_SWIFT" | head -1 \
  | sed -E 's/.*\[(.*)\].*/\1/' | tr -d ' ')"
[ "$CORE_PLATFORMS" = "$REQUIRED_CORE_PLATFORMS" ] \
  || { echo "    CovaCore 平台声明为 [${CORE_PLATFORMS}]，必须恰为 [${REQUIRED_CORE_PLATFORMS}]（.macOS 仅供宿主侧覆盖率测量）"; violations=1; }

# 播放器层无 UI 不变量（AGENTS 硬边界 8「G1/G2 未验收不写 UI」+ D3/D4 分层的机械化为门禁）。
# 判据分两层方向（环 4 第 3 批：主判据换成白名单形态）：
#   ┌ 主判据 G-16 **白名单**：播放器层（含测试 target）的 import 模块名必须落在
#   │   PLAYER_ALLOWED_NONTEST_MODULES / PLAYER_ALLOWED_TEST_MODULES 内，其余一律红。
#   │   方向与黑名单相反 ⇒ 不需要任何人再「补一个漏掉的 UI 框架」。
#   └ 附加防线 G-11/G-14 **黑名单**（一字不放宽，本轮还补了 WebKit/SafariServices/MessageUI）：
#     L1 字面（行锚定 import 正则 + 单一词源）、L3 符号层（.o 的 mangling + ObjC 类前缀）、
#     L3 依赖表层（测试二进制的框架依赖表，UIKit 仅在 weak 时容忍）。
# 支撑层的既有事实：
#   L2 源集合可信性：符号链接整类禁止 + 扫描域 = 「Packages/CovaPlayer/Sources」∪ dump-package
#      声明的每个目标源目录（BSD grep -r 与 find -type f 都不跟随符号链接，12 个 .swift 只看得到 11）。
#   L3 构建产物侧（9/10）：目标 .o 的 Swift mangling 符号引用 + 测试二进制的 dylib 依赖表。
player_ui_scan() { # 目录（空则跳过）
  local d="$1"
  if [ -z "$d" ] || [ ! -d "$d" ]; then return 0; fi
  { find "$d" -name '*.swift' -type f -not -path '*/.*' -print0 2>/dev/null \
      | xargs -0 grep -HnE "$PLAYER_IMPORT_LINE_RE" 2>/dev/null | grep -wE "$PLAYER_UI_WORD_RE"; } || true
}
# ── G-16：白名单 import 扫描。
# $1 = 允许清单（空格分隔）  $2 = 同包 target 名集合（包内模块互相 import 恒允许：测试 target
#      要 `@testable import CovaPlayer`；跨包/包外依赖已由 3/10 的 target 级依赖白名单判定）
#      其余 = 文件参数
# 输出每行「<文件>\t<行号>\t<模块名>」；解析不出模块名的 import 行也输出（fail-closed）。
# 实现口径：
#   * 行是否算 import 语句：由**既有** PLAYER_IMPORT_LINE_RE（超集见常量区）+ 新增的
#     PLAYER_IMPORT_CONT_RE（模块名被换行拆开，实测可编译）判定 —— 不用 awk 判锚定，
#     因为本机 awk（one-true-awk 20200816）对同一 RE 的命中集合与 grep -E **不一致**
#     （实测漏 `@_spi(Cova) import`、`/* c */ import`，却多命中 `// import UIKit` ⇒ 会同时漏检+误红）。
#   * 前缀剥离用 grep -oE（BSD sed -E 对本 RE 报「parentheses not balanced」，实测）。
#   * 声明式 import 的关键字（class/struct/…）先剥掉，再取「第一个标识符段」，
#     故 `import class WebKit.WKWebView` → WebKit、`import struct Foundation.URL` → Foundation。
player_import_whitelist_scan() {
  local allowed own f hit rest lineno content prefix mod nl trimmed
  allowed=" $1 "
  own=" $2 "
  shift 2
  for f in "$@"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      rest="${hit#"$f":}"
      lineno="${rest%%:*}"
      content="${rest#*:}"
      case "$lineno" in ''|*[!0-9]*) lineno="" ;; esac
      prefix=""
      if [ -n "$lineno" ]; then
        # 锚定 ⇒ 每行至多一处匹配，可直接取整段（不再走 `| head -1`/`| sed -n 1p`：
        # 提前退出的下游会让上游收 SIGPIPE，在 pipefail 下返回 141 ⇒ 合法工程随机误红）
        prefix="$(printf '%s' "$content" | { grep -oE "$PLAYER_IMPORT_LINE_RE" || true; })"
      fi
      if [ -n "$prefix" ]; then
        mod="${content#"$prefix"}"
      elif [ -n "$lineno" ]; then
        # import 结尾行：模块名在后续第一个非空、非注释行
        mod=""
        while IFS= read -r nl; do
          trimmed="$(printf '%s' "$nl" | sed -E 's/^[[:space:]]+//')"
          case "$trimmed" in
            ''|'//'*|'/*'*|'*'*) continue ;;
          esac
          mod="$trimmed"
          break
        done < <(sed -n "$((lineno + 1)),$((lineno + 9))p" "$f" 2>/dev/null || true)
      else
        mod="$content"      # 行号解析异常：原样交给下面的解析（大概率判为「无法解析」而红）
      fi
      mod="$(printf '%s' "$mod" | sed -E \
        -e 's/^[[:space:]]+//' \
        -e 's/[[:space:]]*(\/\/|\/\*).*$/ /' \
        -e 's/^`+//' \
        -e 's/^(class|struct|enum|protocol|extension|typealias|func|var|let|actor|macro|operator|precedencegroup)[[:space:]]+//' \
        -e 's/^`+//' \
        -e 's/[^A-Za-z0-9_].*$//')"
      if [ -z "$mod" ]; then
        printf '%s\t%s\t(无法解析的 import 形态)\n' "$f" "${lineno:-?}"
        continue
      fi
      case "$allowed" in
        *" $mod "*) continue ;;
      esac
      case "$own" in
        *" $mod "*) continue ;;
      esac
      printf '%s\t%s\t%s\n' "$f" "${lineno:-?}" "$mod"
    done < <(grep -HnE "$PLAYER_IMPORT_LINE_RE|$PLAYER_IMPORT_CONT_RE" "$f" 2>/dev/null || true)
  done
  return 0
}
player_whitelist_scan_dir() { # $1=目录 $2=允许清单 $3=同包 target 名集合
  local d="$1" allowed="$2" own="$3" f
  if [ -z "$d" ] || [ ! -d "$d" ]; then return 0; fi
  set --
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    set -- "$@" "$f"
  done < <(find "$d" -name '*.swift' \( -type f -o -type l \) -not -path '*/.*' 2>/dev/null | sort)
  [ "$#" -gt 0 ] || return 0
  player_import_whitelist_scan "$allowed" "$own" "$@"
  return 0
}
echo "    禁 UI 白名单（G-16 主判据）：非测试 [${PLAYER_ALLOWED_NONTEST_MODULES}] / 测试再 +[${PLAYER_ALLOWED_TEST_EXTRA_MODULES}]"
echo "    禁 UI 词源（G-14 附加防线，三处判据同源派生）：$(printf '%s\n' "$PLAYER_UI_MODULES" | wc -w | tr -d ' ') 项 [${PLAYER_UI_MODULES}]"
echo "      L3 框架依赖表仅在「名 + weak」容忍：[${PLAYER_UI_DYLIB_WEAK_OK}]（第 3 轮实测：合法态即 weak，直接引用即变强依赖）；该层判据词表：${PLAYER_UI_DYLIB_MODULES}"

PLAYER_UI_HITS="$(player_ui_scan "$PLAYER_PKG_DIR/Sources")"
# L2：逐目标扫描（覆盖 Sources/ 之外的第二 target 目录）。
# G-17：范围含**测试 target**（修复前只 regular ⇒ 复审把 import UIKit + UIView 放进
# CovaPlayerTests 时三层皆不可见）。扫描域扩大、判据不变 ⇒ 只收紧不放宽。
# 注意：清单是 4 列（pkg/type/dir/name），read 的最后一个变量会吞掉其余列 ⇒ 必须读满 4 个。
# 同包 target 名集合：包内模块互相 import 恒允许（测试 target 要 @testable import 被测模块）；
# 「import 一个不在本包清单里的模块」由上面 3/10 的 target 级依赖判定拦，不由本判据拦。
PLAYER_PKG_TARGET_NAMES=""
while IFS="$(printf '\t')" read -r m_pkg m_type m_dir m_name; do
  if [ "$m_pkg" = "$PLAYER_PKG" ] && [ -n "$m_name" ]; then
    PLAYER_PKG_TARGET_NAMES="${PLAYER_PKG_TARGET_NAMES} ${m_name}"
  fi
done < "$TARGET_MANIFEST"
PLAYER_UI_HITS_EXTRA=""
PLAYER_WHITELIST_VIOL=""
PLAYER_WHITELIST_TARGETS=0
PLAYER_WHITELIST_FILES=0
while IFS="$(printf '\t')" read -r m_pkg m_type m_dir m_name; do
  if [ "$m_pkg" != "$PLAYER_PKG" ]; then continue; fi
  case "$m_type" in
    regular) wl_allowed="$PLAYER_ALLOWED_NONTEST_MODULES" ;;
    test)    wl_allowed="$PLAYER_ALLOWED_TEST_MODULES" ;;
    *) fail "播放器包出现未知 target 类型 '${m_type}'（${m_name}）：白名单判据需按类型补口径" ;;
  esac
  hit="$(player_ui_scan "$m_dir")"
  if [ -n "$hit" ]; then PLAYER_UI_HITS_EXTRA="${PLAYER_UI_HITS_EXTRA}${hit}"$'\n'; fi
  wlv="$(player_whitelist_scan_dir "$m_dir" "$wl_allowed" "$PLAYER_PKG_TARGET_NAMES")"
  if [ -n "$wlv" ]; then PLAYER_WHITELIST_VIOL="${PLAYER_WHITELIST_VIOL}${wlv}"$'\n'; fi
  wl_n="$( { find "$m_dir" -name '*.swift' -type f -not -path '*/.*' 2>/dev/null || true; } | wc -l | tr -d ' ')"
  PLAYER_WHITELIST_FILES=$((PLAYER_WHITELIST_FILES + ${wl_n:-0}))
  PLAYER_WHITELIST_TARGETS=$((PLAYER_WHITELIST_TARGETS + 1))
done < "$TARGET_MANIFEST"
# 白名单判据自身不得空转：target 数 / 文件数为 0（清单被掏空）都等于没判
[ "${PLAYER_WHITELIST_TARGETS:-0}" -ge 1 ] \
  || { echo "    dump-package 未报告 CovaPlayer 的任何 target：白名单扫描空转"; violations=1; }
[ "${PLAYER_WHITELIST_FILES:-0}" -ge 1 ] \
  || { echo "    播放器层各 target 的源目录内没有 .swift：白名单扫描空转（清空源目录不得绕过）"; violations=1; }
if [ -n "$PLAYER_WHITELIST_VIOL" ]; then
  { printf '%s\n' "$PLAYER_WHITELIST_VIOL" | sed '/^$/d' | head -10 | sed 's/^/      /' || true; }
  echo "    ↑ G-16 白名单：以上是播放器层（含测试 target）import 了允许清单之外的模块"
  echo "      非测试允许清单 [${PLAYER_ALLOWED_NONTEST_MODULES}]"
  echo "      测试允许清单   [${PLAYER_ALLOWED_TEST_MODULES}]"
  echo "      同包模块（自动允许）[${PLAYER_PKG_TARGET_NAMES# }]"
  echo "      新增合法依赖必须显式改 Scripts/check.sh 的允许清单，并随 commit 进入审查。"
  violations=1
fi
# 两段扫描的域会重叠（target 目录本就在 Sources 之下）⇒ 去重，避免同一行打印两遍
PLAYER_UI_HITS="$( { printf '%s\n' "$PLAYER_UI_HITS"; printf '%s\n' "$PLAYER_UI_HITS_EXTRA"; } \
  | sed '/^$/d' | sort -u )"
if [ -n "$PLAYER_UI_HITS" ]; then
  { printf '%s\n' "$PLAYER_UI_HITS" | head -10 | sed 's/^/    /' || true; }
  echo "    ↑ CovaPlayer 引入了 UI 框架：设计闸门（G1/G2）未验收前禁止编写 UI 代码"
  violations=1
fi
# 反向防绕过：源集合为空时上面的扫描恒真通过（清空目录即免检），故要求播放器层非空。
PLAYER_SRC_COUNT="$(find Packages/CovaPlayer/Sources -name '*.swift' -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "${PLAYER_SRC_COUNT:-0}" -ge 1 ] \
  || { echo "    CovaPlayer/Sources 下无任何 .swift 源文件（清空源目录不得绕过无 UI 不变量）"; violations=1; }
# L2 反向守卫：包内**全部** .swift（含符号链接、含任意目录；只排除包根清单 Package.swift 本身）
# 必须落在「包根声明的源目录 ∪ dump-package 每个 target 的源目录」之内，否则存在无主源文件
# ——「未登记目标的源目录」与「目录级符号链接」正是今天的绕过面。
PLAYER_SCANNED_DIRS="$LOG_DIR/player-scanned-dirs.txt"
{ printf '%s\n' "$PLAYER_PKG_DIR/Sources"
  while IFS="$(printf '\t')" read -r m_pkg m_type m_dir m_name; do
    if [ "$m_pkg" = "$PLAYER_PKG" ] && [ -n "$m_dir" ]; then printf '%s\n' "$m_dir"; fi
  done < "$TARGET_MANIFEST"; } | sed '/^$/d' | sort -u > "$PLAYER_SCANNED_DIRS"
PLAYER_SWIFT_ANY="$(find "$PLAYER_PKG_DIR" -name '*.swift' \( -type f -o -type l \) \
  -not -path '*/.*' ! -path "$PLAYER_PKG_DIR/Package.swift" 2>/dev/null \
  | while IFS= read -r f; do realpath "$f" 2>/dev/null || printf '%s\n' "$f"; done | sort -u)"
PLAYER_SWIFT_SCANNED="$(while IFS= read -r d; do
    if [ -d "$d" ]; then
      find "$d" -name '*.swift' \( -type f -o -type l \) -not -path '*/.*' 2>/dev/null \
        | while IFS= read -r f; do realpath "$f" 2>/dev/null || printf '%s\n' "$f"; done
    fi
  done < "$PLAYER_SCANNED_DIRS" | sort -u)"
PLAYER_SWIFT_UNCOVERED="$(comm -23 <(printf '%s\n' "$PLAYER_SWIFT_ANY") <(printf '%s\n' "$PLAYER_SWIFT_SCANNED"))"
if [ -n "$PLAYER_SWIFT_UNCOVERED" ]; then
  printf '%s\n' "$PLAYER_SWIFT_UNCOVERED" | head -10 | sed 's/^/      /'
  echo "    ↑ CovaPlayer 包内存在无主 .swift 文件（不在任何已声明 target 的源目录内 / 符号链接目录）"
  violations=1
fi

[ "$violations" -eq 0 ] || fail "依赖方向 / 平台中立性 / 播放器无 UI 不变量校验未通过"
echo "    依赖图与不变量校验通过（CovaCore 无字面 #if 与 iOS-only 令牌；CovaPlayer ${PLAYER_SRC_COUNT} 个源文件：G-16 白名单内 ${PLAYER_WHITELIST_FILES} 个文件（含测试 target）的 import 全部允许，G-14 黑名单 ${PLAYER_UI_MODULES} 零命中）"

# 3/10 追加判据（D12 合规文案）：禁词命中必须为 0、逐字脚注必须在册。
# 为什么放进门禁而不是靠自觉：design 13 §8 把「禁止字样」写成表并规定命中数为 0，
# 13 §F 的脚注缺失按 Critical 计 —— 这类规则一旦被"记得住"当成保障就会漂移。
# 脚本自带负例自检（植入禁词必须被抓到），所以它不是一条永绿的空规则。
echo "==> 3/10 追加：D12 合规文案门禁（Scripts/d12-copy-check.sh）"
"$ROOT/Scripts/d12-copy-check.sh"

echo "==> 4/10 有效构建设置（配置×SDK）+ clean build + 实际编译语言版本 + 产物保真"
eff() {
  { grep -E "^[[:space:]]+$2 = " "$1" || true; } | head -1 | sed -E "s/^[[:space:]]+$2 = //"
}
assert_eff() { # file key expected label
  local got
  got="$(eff "$1" "$2")"
  [ "$got" = "$3" ] || fail "$4：有效构建设置 $2='${got}'，应为 '$3'（不得被 target/config/sdk 级覆盖）"
}
assert_no_language_override_flags() { # file label
  local got
  got="$(eff "$1" OTHER_SWIFT_FLAGS)"
  case "$got" in
    *"-swift-version"*) fail "$2：OTHER_SWIFT_FLAGS 含 -swift-version（可绕过语言版本钉死）：'${got}'" ;;
  esac
  case "$got" in
    *"-strict-concurrency"*) fail "$2：OTHER_SWIFT_FLAGS 含 -strict-concurrency（可绕过严格并发钉死）：'${got}'" ;;
  esac
}

# 实际编译日志中的 -strict-concurrency 令牌：**若出现**则取值必须为 complete。
# 据实说明：Swift 6 语言模式已隐含 complete，Xcode 通常不输出该 flag（干净构建日志中 0 次命中），
# 因此本检查在缺数据时通过 —— 它拦的是「显式注入其它取值」，不构成对默认行为的实测校验。
# 默认行为的权威校验在有效构建设置层（SWIFT_STRICT_CONCURRENCY=complete + OTHER_SWIFT_FLAGS 令牌禁用）。
assert_strict_concurrency_complete() { # tokens label
  local tokens="$1" label="$2" t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in
      '-strict-concurrency=complete'|'-strict-concurrency complete'|'-strict-concurrency\=complete') ;;
      *) fail "${label}：编译日志出现非 complete 的严格并发令牌（显式注入）：${t}" ;;
    esac
  done <<< "$tokens"
}
for cfg in $CONFIGURATIONS; do
  for sdk in $SETTINGS_SDKS; do
    APPSET="$LOG_DIR/settings-app-$cfg-$sdk.log"
    xcodebuild -project "$PROJECT" -target Cova -configuration "$cfg" -sdk "$sdk" -showBuildSettings \
      > "$APPSET" 2>&1 || fail "无法读取 Cova target 的 ${cfg}/${sdk} 有效构建设置"
    assert_eff "$APPSET" SWIFT_VERSION "$REQUIRED_SWIFT_VERSION" "Cova[${cfg}/${sdk}] SWIFT_VERSION"
    assert_eff "$APPSET" EFFECTIVE_SWIFT_VERSION "$REQUIRED_EFFECTIVE_SWIFT" "Cova[${cfg}/${sdk}] Swift 语言版本"
    assert_eff "$APPSET" SWIFT_STRICT_CONCURRENCY "$REQUIRED_STRICT_CONCURRENCY" "Cova[${cfg}/${sdk}] 严格并发"
    assert_eff "$APPSET" IPHONEOS_DEPLOYMENT_TARGET "$REQUIRED_DEPLOYMENT_TARGET" "Cova[${cfg}/${sdk}] 部署目标（D1）"
    assert_eff "$APPSET" PRODUCT_BUNDLE_IDENTIFIER "$REQUIRED_APP_BUNDLE_ID" "Cova[${cfg}/${sdk}] bundle id（D13）"
    assert_no_language_override_flags "$APPSET" "Cova[${cfg}/${sdk}]"
  done
done
for cfg in $CONFIGURATIONS; do
  TESTSET="$LOG_DIR/settings-tests-$cfg.log"
  xcodebuild -project "$PROJECT" -target CovaTests -configuration "$cfg" -sdk iphonesimulator -showBuildSettings \
    > "$TESTSET" 2>&1 || fail "无法读取 CovaTests target 的 ${cfg} 有效构建设置"
  assert_eff "$TESTSET" SWIFT_VERSION "$REQUIRED_SWIFT_VERSION" "CovaTests[${cfg}] SWIFT_VERSION"
  assert_eff "$TESTSET" SWIFT_STRICT_CONCURRENCY "$REQUIRED_STRICT_CONCURRENCY" "CovaTests[${cfg}] 严格并发"
  assert_eff "$TESTSET" PRODUCT_BUNDLE_IDENTIFIER "$REQUIRED_TEST_BUNDLE_ID" "CovaTests[${cfg}] bundle id"
  assert_no_language_override_flags "$TESTSET" "CovaTests[${cfg}]"
done

APPSET_DEBUG="$LOG_DIR/settings-app-Debug-iphonesimulator.log"
EXPECT_VERSION="$(eff "$APPSET_DEBUG" CFBundleShortVersionString)"
EXPECT_BUILD="$(eff "$APPSET_DEBUG" CFBundleVersion)"
[ -n "$EXPECT_VERSION" ] && [ -n "$EXPECT_BUILD" ] || fail "无法从有效构建设置取版本号"
echo "$EXPECT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "CFBundleShortVersionString='${EXPECT_VERSION}' 不符合 X.Y.Z（AGENTS 版本规则）"
echo "$EXPECT_BUILD" | grep -qE '^[1-9][0-9]*$' \
  || fail "CFBundleVersion='${EXPECT_BUILD}' 必须为正整数"

touch "$BUILD_MARKER"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" clean build \
  > "$LOG_DIR/build.log" 2>&1; then
  echo "构建失败，日志尾部（完整日志 ${LOG_DIR}/build.log）："
  tail -60 "$LOG_DIR/build.log"
  exit 1
fi
{ grep -E "^\*\* BUILD (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/build.log" || true; } | tail -1

# 从构建日志（xcactivitylog）提取令牌。
# ⚠️ 必须先把 gunzip 输出落盘、再 `strings <file>`：`... | strings` 从 stdin 读取时按约 1KB
# 分块，并把超长可打印串截断到 1022 字符，而 `-swift-version 6` 处于数万字符的连续可打印串内，
# 会被截断导致正则恒不命中（评审干净克隆连续 EXIT=1 的根因）。落盘读取使用完整行长，判据不变。
extract_build_log_tokens() { # $1 = 正则（grep -E）
  find "$DERIVED_DATA/Logs/Build" -name '*.xcactivitylog' -newer "$BUILD_MARKER" 2>/dev/null \
    | while IFS= read -r l; do
        tmp="$(mktemp "$LOG_DIR/xcactivity.XXXXXX")"
        gunzip -c "$l" 2>/dev/null > "$tmp" || true
        strings "$tmp" 2>/dev/null | grep -oE -- "$1" || true
        rm -f "$tmp"
      done \
    | sort -u
}

# 实际编译语言版本：从构建日志解析编译器调用（权威，不受构建设置清单影响）
APP_SWIFT_VERSIONS="$(extract_build_log_tokens '-swift-version [0-9]+')"
[ -n "$APP_SWIFT_VERSIONS" ] \
  || fail "构建日志（xcactivitylog）中未出现任何 -swift-version：无法证明实际编译语言版本"
[ "$APP_SWIFT_VERSIONS" = "-swift-version $REQUIRED_LANGUAGE_VERSION" ] \
  || fail "App 实际编译语言版本异常：$(echo "$APP_SWIFT_VERSIONS" | tr '\n' ' ')"
echo "    实际编译语言版本（App/构建日志）：$(echo "$APP_SWIFT_VERSIONS" | tr '\n' ' ')"
APP_SC_TOKENS="$(extract_build_log_tokens '-strict-concurrency[\\]?[= ]?[a-z]*')"
assert_strict_concurrency_complete "$APP_SC_TOKENS" "App"
if [ -n "$APP_SC_TOKENS" ]; then
  echo "    编译日志中的严格并发令牌（App）：$(echo "$APP_SC_TOKENS" | tr '\n' ' ')（均须为 complete）"
else
  echo "    编译日志未出现 -strict-concurrency 令牌（Swift 6 模式通常不输出，符合预期）"
fi

[ -d "$APP_BUNDLE" ] || fail "构建产物不存在：$APP_BUNDLE"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_BUNDLE/Info.plist" 2>/dev/null; }
ACT_VERSION="$(plist CFBundleShortVersionString)"
ACT_BUILD="$(plist CFBundleVersion)"
ACT_BUNDLE_ID="$(plist CFBundleIdentifier)"
ACT_MIN_OS="$(plist MinimumOSVersion)"
ACT_BG_MODE="$(plist UIBackgroundModes:0)"
[ "$ACT_VERSION" = "$EXPECT_VERSION" ] || fail "产物 CFBundleShortVersionString=${ACT_VERSION}，有效设置=${EXPECT_VERSION}"
[ "$ACT_BUILD" = "$EXPECT_BUILD" ] || fail "产物 CFBundleVersion=${ACT_BUILD}，有效设置=${EXPECT_BUILD}"
[ "$ACT_BUNDLE_ID" = "$REQUIRED_APP_BUNDLE_ID" ] \
  || fail "产物 bundle id=${ACT_BUNDLE_ID}，钉死值=${REQUIRED_APP_BUNDLE_ID}（D13）"
[ "$ACT_MIN_OS" = "$REQUIRED_DEPLOYMENT_TARGET" ] || fail "产物 MinimumOSVersion=${ACT_MIN_OS}，应为 ${REQUIRED_DEPLOYMENT_TARGET}（D1）"
[ "$ACT_BG_MODE" = "audio" ] || fail "产物 UIBackgroundModes[0]=${ACT_BG_MODE}，应为 audio（D4）"
echo "    产物保真：${ACT_BUNDLE_ID} ${ACT_VERSION}(${ACT_BUILD}) minOS=${ACT_MIN_OS} bg=${ACT_BG_MODE}"

echo "==> 5/10 应用工程测试（CovaTests，iOS Simulator）"
rm -rf "$RESULT_BUNDLE"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:CovaTests test > "$LOG_DIR/test-app.log" 2>&1; then
  echo "测试失败，日志尾部（完整日志 ${LOG_DIR}/test-app.log）："
  tail -80 "$LOG_DIR/test-app.log"
  exit 1
fi
{ grep -E "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/test-app.log" || true; } | tail -1
APP_COUNTS="$(xcresult_counts "$RESULT_BUNDLE" || true)"
assert_tests "CovaTests" "$APP_COUNTS" "$APP_MIN"
xcrun xccov view --report "$RESULT_BUNDLE" > "$LOG_DIR/xccov.txt" 2>/dev/null \
  || fail "无法读取覆盖率报告（gatherCoverageData 未生效？）"
MAX_EXEC_LINES="$( { grep -oE '\([0-9]+/[0-9]+\)' "$LOG_DIR/xccov.txt" || true; } | tr -d '()' \
  | awk -F/ '{ if ($2 + 0 > max) max = $2 + 0 } END { print max + 0 }' )"
[ "${MAX_EXEC_LINES:-0}" -gt 0 ] \
  || fail "覆盖率报告无任何含可执行行的 target（全部 0/0）——采集实际未生效"
echo "    xccov 采集有效：target 数 $(grep -cE '^Cova' "$LOG_DIR/xccov.txt")，最大可执行行数 ${MAX_EXEC_LINES}"

echo "==> 6/10 核心层包测试（CovaCoreTests，iOS Simulator）"
rm -rf "$CORE_RESULT_BUNDLE"
if ! (cd Packages/CovaCore && xcodebuild -scheme CovaCore -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$PACKAGE_DERIVED_DATA" \
  -resultBundlePath "$CORE_RESULT_BUNDLE" \
  test > "$LOG_DIR/test-core-ios.log" 2>&1); then
  echo "核心层测试失败，日志尾部（完整日志 ${LOG_DIR}/test-core-ios.log）："
  tail -60 "$LOG_DIR/test-core-ios.log"
  exit 1
fi
{ grep -E "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/test-core-ios.log" || true; } | tail -1
CORE_IOS_COUNTS="$(xcresult_counts "$CORE_RESULT_BUNDLE" || true)"
assert_tests "CovaCoreTests(iOS)" "$CORE_IOS_COUNTS" "$CORE_MIN"

echo "==> 7/10 核心层行覆盖率（SwiftPM 插桩 + llvm-cov，阈值 ${CORE_COVERAGE_MIN}%）"
echo "    说明：Xcode 不为本地 SwiftPM 包目标产出 xccov 覆盖率，故由 SwiftPM 插桩测量；"
echo "          被测源码与 iOS 运行同一份，平台中立性已由 3/10 不变量强制。"
rm -rf Packages/CovaCore/.build
if ! swift test --package-path Packages/CovaCore --enable-code-coverage -v \
  > "$LOG_DIR/test-core-coverage.log" 2>&1; then
  echo "覆盖率测试运行失败，日志尾部："
  tail -60 "$LOG_DIR/test-core-coverage.log"
  exit 1
fi
# 实际编译语言版本（权威：SwiftPM 编译器调用）
PKG_SWIFT_VERSIONS="$( { grep -oE -- '-swift-version [0-9]+' "$LOG_DIR/test-core-coverage.log" || true; } | sort -u )"
[ -n "$PKG_SWIFT_VERSIONS" ] \
  || fail "SwiftPM 构建日志未出现 -swift-version：无法证明包的实际编译语言版本"
[ "$PKG_SWIFT_VERSIONS" = "-swift-version $REQUIRED_LANGUAGE_VERSION" ] \
  || fail "包实际编译语言版本异常：$(echo "$PKG_SWIFT_VERSIONS" | tr '\n' ' ')"
echo "    实际编译语言版本（CovaCore 包）：$(echo "$PKG_SWIFT_VERSIONS" | tr '\n' ' ')"
PKG_SC_TOKENS="$( { grep -oE -- '-strict-concurrency[\\]?[= ]?[a-z]*' "$LOG_DIR/test-core-coverage.log" || true; } | sort -u )"
assert_strict_concurrency_complete "$PKG_SC_TOKENS" "CovaCore 包"

# 编译集合（权威）：以 CovaCore 目标的 .SwiftFileList 为域，realpath 解析符号链接后与源目录全集双向比对。
# 依据：目录 ≠ 编译集合 —— 目录符号链接（grep -r 不跟随、SwiftPM 跟随）、exclude:/sources: 收缩、
#       包外链接目录都会让两者背离，而 .SwiftFileList 记录的是词法路径（前缀断言会恒真）。
CORE_TARGET_FL="$(find Packages/CovaCore/.build -name 'CovaCore.SwiftFileList' 2>/dev/null | head -1)"
[ -n "$CORE_TARGET_FL" ] || fail "未找到 CovaCore 目标的编译文件清单（CovaCore.SwiftFileList）"
COMPILED="$( { while IFS= read -r l; do [ -n "$l" ] || continue; realpath "$(printf '%s' "$l" | sed 's/\\ / /g')"; done < "$CORE_TARGET_FL"; } | sort -u )"
# 源集合定义：包内全部目标源文件。与 SwiftPM 的忽略规则对齐 —— 排除 Tests/、清单 Package.swift 本身，
# 以及所有「点号路径分量」（含 .build 自身与其内部、SwiftPM 忽略的点号目录/文件）。
SOURCES="$(find Packages/CovaCore -name '*.swift' -not -name 'Package.swift' -not -path '*/Tests/*' -not -path '*/.*' 2>/dev/null \
  | while IFS= read -r f; do realpath "$f"; done | sort -u)"
[ -n "$COMPILED" ] || fail "CovaCore 编译集合为空（.SwiftFileList 无可读条目）"
[ -n "$SOURCES" ] || fail "CovaCore 源目录 .swift 集合为空"
if [ "$COMPILED" != "$SOURCES" ]; then
  echo "    仅被编译、不在源目录（realpath 后）："
  comm -23 <(printf '%s\n' "$COMPILED") <(printf '%s\n' "$SOURCES") | head -5 | sed 's/^/      /'
  echo "    仅在源目录、未被编译："
  comm -13 <(printf '%s\n' "$COMPILED") <(printf '%s\n' "$SOURCES") | head -5 | sed 's/^/      /'
  fail "CovaCore 编译集合与源目录 .swift 全集不一致（符号链接/exclude/包外源文件均不允许）"
fi
# 逐文件扫描「实际被编译的」文件（realpath 后读取），而非扫目录
IOS_ONLY_REGEX="$(echo "$IOS_ONLY_MODULES" | tr ' ' '|')"
CC_BAD=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -q --fixed-strings '#if' "$f" 2>/dev/null; then
    echo "    含字面 #if（被编译文件）：${f}"; CC_BAD=1
  fi
  if grep -qwE "$IOS_ONLY_REGEX" "$f" 2>/dev/null; then
    echo "    含 iOS-only 框架令牌（被编译文件）：${f}"; CC_BAD=1
  fi
done <<< "$COMPILED"
[ "$CC_BAD" -eq 0 ] || fail "被编译的 CovaCore 源文件违反平台中立性（逐文件扫描编译集合）"
echo "    编译集合与源集合双向一致：$(printf '%s\n' "$COMPILED" | wc -l | tr -d ' ') 个文件，且均平台中立"

# 稳健发现产物：不硬编码二进制名/目录布局
CORE_BIN_DIR="$(swift build --package-path Packages/CovaCore --show-bin-path 2>/dev/null | tail -1)"
if [ -z "$CORE_BIN_DIR" ] || [ ! -d "$CORE_BIN_DIR" ]; then
  CORE_BIN_DIR="$(find Packages/CovaCore/.build -type d -name Debug 2>/dev/null | head -1)"
fi
[ -n "$CORE_BIN_DIR" ] && [ -d "$CORE_BIN_DIR" ] \
  || fail "无法定位 SwiftPM 产物目录（--show-bin-path 与 glob 均失败）"
CORE_BIN="$(find "$CORE_BIN_DIR" -type f -path '*.xctest/Contents/MacOS/*' -not -path '*dSYM*' 2>/dev/null | head -1)"
[ -n "$CORE_BIN" ] || fail "在 ${CORE_BIN_DIR} 下找不到 *.xctest/Contents/MacOS/* 测试二进制"
CORE_PROF=""
CODECOV_JSON="$(swift test --package-path Packages/CovaCore --show-codecov-path 2>/dev/null | tail -1)"
if [ -n "$CODECOV_JSON" ] && [ -f "$CODECOV_JSON" ]; then
  CORE_PROF="$(dirname "$CODECOV_JSON")/default.profdata"
fi
if [ -z "$CORE_PROF" ] || [ ! -f "$CORE_PROF" ]; then
  CORE_PROF="$(find Packages/CovaCore/.build -name 'default.profdata' -type f 2>/dev/null | head -1)"
fi
[ -n "$CORE_PROF" ] && [ -f "$CORE_PROF" ] \
  || fail "无法定位 profdata（--show-codecov-path 与 glob 均失败）"
echo "    产物发现：$(basename "$CORE_BIN_DIR")/$(basename "$CORE_BIN") + $(basename "$CORE_PROF")（零命名硬编码）"

# 覆盖率口径：CovaCore 下除 Tests/ 与生成物（.build/）之外的全部源码（含未来新增源目录）
LCOV_FILE="$LOG_DIR/core-coverage.lcov"
{ xcrun llvm-cov export "$CORE_BIN" -instr-profile="$CORE_PROF" --format=lcov 2>/dev/null || true; } > "$LCOV_FILE"
# 说明（第七轮结论）：不再断言「源文件必须出现在 lcov SF 中」。
#   llvm-cov 只为「含可执行区域」的文件产出 SF —— protocol/空枚举/仅 case 枚举/0 字节/仅注释文件天然无 SF；
#   「被编译」是编译事实，「进入覆盖率分母」是插桩事实，二者不是同一集合。
#   exclude:/sources: 收缩已由上面的「编译集合 == 源目录 .swift 全集」双向校验拦截（W1c/W1d 实测有效），
#   此处若再要求 SF 完备，只会在合法文件上误红（误红会反向迫使维护者放宽门禁，与漏检同等严重）。
COVERAGE="$(awk '
  /^SF:/ { in_pkg = (index($0, "Packages/CovaCore/") > 0) && (index($0, "/.build/") == 0)
           in_test = in_pkg && (index($0, "/Tests/") > 0)
           in_core = in_pkg && (index($0, "/Tests/") == 0) }
  /^DA:/ {
    if (in_core) { split(substr($0, 4), a, ","); total++; if ((a[2] + 0) > 0) covered++ }
    if (in_test) { split(substr($0, 4), b, ","); if ((b[2] + 0) > 0) testhit++ }
  }
  END { printf "%d %d %d", covered, total, testhit }
' "$LCOV_FILE")"
read -r COV_COVERED COV_TOTAL TEST_LINES_COVERED <<< "${COVERAGE:-0 0 0}" || true
[ "${COV_TOTAL:-0}" -gt 0 ] || fail "核心层可执行行数为 0 或覆盖率不可读，不可判定为通过"
[ "${TEST_LINES_COVERED:-0}" -gt 0 ] \
  || fail "覆盖率数据中测试代码零命中：该次运行未真正执行测试，拒绝出报告"
echo "    覆盖率运行有效：测试源码命中 ${TEST_LINES_COVERED} 行"
COV_PCT="$(awk -v c="$COV_COVERED" -v t="$COV_TOTAL" 'BEGIN { printf "%.2f", 100 * c / t }')"
echo "    CovaCore 行覆盖率：${COV_COVERED}/${COV_TOTAL} = ${COV_PCT}%"
awk -v p="$COV_PCT" -v m="$CORE_COVERAGE_MIN" 'BEGIN { exit !(p >= m) }' \
  || fail "核心层行覆盖率 ${COV_PCT}% < 阈值 ${CORE_COVERAGE_MIN}%"

echo "==> 8/10 播放器层包测试（CovaPlayerTests，iOS Simulator，同时产出 9/10 的插桩产物）"
# 与 6/10 同口径（xcresult 只认 passed、failed 必须为 0、下限读基线文件）。
# 刻意带 -enableCodeCoverage YES：9/10 复用**同一次真实运行**的覆盖率产物，
# 避免「测试跑一遍、覆盖率再跑一遍」造成的双份事实（也避免两次运行结果不一致时无从判断）。
# 先清空 ProfileData 并打时间戳：9/10 只能读到**本次运行**产出的 profdata（防陈旧产物冒充）。
rm -rf "$PLAYER_PACKAGE_DERIVED_DATA/Build/ProfileData"
touch "$PLAYER_PROF_MARKER"
rm -rf "$PLAYER_RESULT_BUNDLE"
if ! (cd Packages/CovaPlayer && xcodebuild -scheme CovaPlayer -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$PLAYER_PACKAGE_DERIVED_DATA" \
  -enableCodeCoverage YES \
  -resultBundlePath "$PLAYER_RESULT_BUNDLE" \
  test > "$LOG_DIR/test-player-ios.log" 2>&1); then
  echo "播放器层测试失败，日志尾部（完整日志 ${LOG_DIR}/test-player-ios.log）："
  tail -60 "$LOG_DIR/test-player-ios.log"
  exit 1
fi
{ grep -E "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/test-player-ios.log" || true; } | tail -1
PLAYER_IOS_COUNTS="$(xcresult_counts "$PLAYER_RESULT_BUNDLE" || true)"
assert_tests "CovaPlayerTests(iOS)" "$PLAYER_IOS_COUNTS" "$PLAYER_MIN"

echo "==> 9/10 播放器层行覆盖率（8/10 的 Coverage.profdata + llvm-cov lcov，阈值 ${PLAYER_COVERAGE_MIN}%）"
echo "    说明（G-9 / TD-1）：播放器层是 iOS-only（AVAudioSession / AVPlayer / MediaPlayer），无法沿用"
echo "          7/10 的 macOS 宿主 SwiftPM 插桩口径。原口径消费 xccov 文本，但**同一份产物**在干净 clone 上"
echo "          会把本地包目标折叠进测试 target（实测 CovaPlayer 0.00% (0/0)、CovaPlayerTests 95.90% (5221/5444)、"
echo "          报告 0 行点名 Packages/CovaPlayer/Sources ⇒ 门禁不可复现）。现改判据：8/10 带"
echo "          -enableCodeCoverage 的真实模拟器运行产出的 profdata + 该次运行的 .xctest 二进制，走"
echo "          llvm-cov lcov（与 7/10 同方法论）。域由「该包非测试 target 的编译文件集合」精确界定，"
echo "          不用 /Tests/ 名称启发式（防止把难覆盖文件塞进名为 Tests 的子目录来缩小分母，TD-10）。"
echo "          阈值不变（≥80%，只允许抬高），读不到数据一律 fail-closed。"

lcov_sf_in_domain() { # $1=lcov $2=域清单（逐行绝对路径） -> 域内被点名的 SF（去重排序）
  awk -v DOM="$2" '
    BEGIN { while ((getline l < DOM) > 0) { if (l != "") dom[l] = 1 } }
    /^SF:/ { f = substr($0, 4); if (f in dom) print f }
  ' "$1" | sort -u
}

# lcov 的 SF 路径是「工具链当时记录的词法路径」：同一份产物里可能混用 /tmp 与 /private/tmp
# （模拟器侧测试文件记 /tmp、包内源文件记 /private/tmp，干净副本实测），而编译集合是 realpath 过的。
# 不归一化就会让「测试代码命中」域恒空 ⇒ 合法工程误红（TD-9）。故统一 realpath 后再判定。
normalize_lcov() { # $1=输入 lcov $2=输出 lcov
  while IFS= read -r line; do
    case "$line" in
      'SF:'*)
        f="${line#SF:}"
        printf 'SF:%s\n' "$(realpath "$f" 2>/dev/null || printf '%s' "$f")" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$1" > "$2"
}

# ── G-15：编译器自己写出的 <Target>-OutputFileMap.json 是「源文件 ↔ .o」的权威产物。
# 形态（每键一行）：{ "" : {...}, "/abs/X.swift" : { "object" : "/abs/…/X.o", ... }, ... }
# 顶层 "" 键（pch / emit-module 产物）与嵌套的 secondary 结构都不参与归因，
# 只认「键以 .swift 结尾」的条目下的 "object" 值。同名不同目录的消歧形态由构建系统自己
# 记录在 map 里（SwiftPM 输出 X.o / X-1.o；Xcode 输出 X.o / X-<路径 md5>.o，后者实测），
# 故本函数不需要任何 basename 猜测 —— 猜测正是 F-10 的失守点。
objmap_pairs() { # $1 = OutputFileMap.json -> 每行「源文件<TAB>.o」（原样路径，未 realpath）
  awk '
    /^[[:space:]]*"[^"]*\.swift"[[:space:]]*:[[:space:]]*\{/ {
      cur = $0
      sub(/^[[:space:]]*"/, "", cur); sub(/"[[:space:]]*:.*$/, "", cur)
      next
    }
    cur != "" && /^[[:space:]]*"object"[[:space:]]*:[[:space:]]*"/ {
      o = $0
      sub(/^[[:space:]]*"object"[[:space:]]*:[[:space:]]*"/, "", o)
      sub(/",?[[:space:]]*$/, "", o)
      printf "%s\t%s\n", cur, o
    }
  ' "$1"
}

# map 里出现过的**全部** .o 路径（含 batch/secondary 变体）：用于「objdir 内不得出现无人认领的
# .o」判据。只按 "object" 认领会在多产物布局上误红（TD-9），故这里放宽认领口径、
# 但归因（谁有 covmap）仍旧只认 "object"。
objmap_all_objects() { # $1 = OutputFileMap.json
  { grep -oE '"[^"]*\.o"' "$1" || true; } | sed -e 's/^"//' -e 's/"$//'
}

# ── 9.1 编译集合 ↔ 源集合：覆盖包内**全部** target（G-11：只查 CovaPlayer 目标会让「第二 target」失明）
PLAYER_COMPILED_DIR="$LOG_DIR/player-compiled-files"
mkdir -p "$PLAYER_COMPILED_DIR"
rm -f "$PLAYER_COMPILED_DIR"/*.compiled "$PLAYER_COMPILED_DIR"/*.sources \
  "$PLAYER_COMPILED_DIR"/*.instrumented "$PLAYER_COMPILED_DIR"/*.objmap
PLAYER_OBJ_DIRS="$LOG_DIR/player-obj-dirs.txt"
: > "$PLAYER_OBJ_DIRS"
while IFS="$(printf '\t')" read -r m_pkg m_type m_dir m_name; do
  if [ "$m_pkg" != "$PLAYER_PKG" ]; then continue; fi
  [ -n "$m_name" ] || fail "目标清单缺 target 名（3/10 落盘异常）"
  # 该 target 的 .SwiftFileList（Xcode 为每个 target 各出一份；优先模拟器变体）。
  # 取首行用「落盘 + sed -n 1p」而不是 `| head -1`：head 提前退出会让上游 find/grep 收到 SIGPIPE，
  # 在 set -o pipefail 下命令替换返回 141 ⇒ 合法工程随机误红（本仓已踩过同类坑）。
  FL_CANDS="$LOG_DIR/player-fl-cands.txt"
  find "$PLAYER_PACKAGE_DERIVED_DATA" -name "${m_name}.SwiftFileList" 2>/dev/null > "$FL_CANDS" || true
  grep -- 'iphonesimulator' "$FL_CANDS" > "$FL_CANDS.sim" 2>/dev/null || true
  if [ -s "$FL_CANDS.sim" ]; then
    FL="$(sed -n '1p' "$FL_CANDS.sim")"
  else
    FL="$(sed -n '1p' "$FL_CANDS")"
  fi
  [ -n "$FL" ] || fail "未找到 ${m_name} 目标的编译文件清单（${m_name}.SwiftFileList）—— 9/10 的分母不可信"
  # G-17：objdir 集合纳入播放器包的**全部** target（含测试 target）。
  # 修复前只有 `m_type = "regular"` 会把 objdir 落盘 ⇒ 第 3 轮复审实测
  # player-obj-dirs.txt 只有 CovaPlayer-t.build/…/arm64，而
  # CovaPlayerTests-p.build/…/GateUIKitInTests.o 里明摆着 `_OBJC_CLASS_$_UIView`，符号层从未读到它。
  printf '%s\n' "$(dirname "$FL")" >> "$PLAYER_OBJ_DIRS"
  COMPILED_T="$PLAYER_COMPILED_DIR/$m_type-$m_name.compiled"
  { while IFS= read -r l; do
      [ -n "$l" ] || continue
      realpath "$(printf '%s' "$l" | sed 's/\\ / /g')" 2>/dev/null || true
    done < "$FL"; } | sort -u > "$COMPILED_T"
  [ -s "$COMPILED_T" ] || fail "${m_name} 编译集合为空（.SwiftFileList 无可读条目）"
  SOURCES_T="$PLAYER_COMPILED_DIR/$m_type-$m_name.sources"
  if [ -n "$m_dir" ] && [ -d "$m_dir" ]; then
    find "$m_dir" -name '*.swift' -type f -not -path '*/.*' 2>/dev/null \
      | while IFS= read -r f; do realpath "$f" 2>/dev/null || true; done | sort -u > "$SOURCES_T"
  else
    : > "$SOURCES_T"
  fi
  if [ "$m_type" = "regular" ]; then
    # 非测试目标：双向严格一致（修复前对 CovaPlayer 目标的判据，逐字保留；exclude/sources:/包外源文件均拦）
    if ! cmp -s "$COMPILED_T" "$SOURCES_T"; then
      echo "    目标 ${m_name} 仅被编译、不在源目录（realpath 后）："
      comm -23 "$COMPILED_T" "$SOURCES_T" | head -5 | sed 's/^/      /'
      echo "    目标 ${m_name} 仅在源目录、未被编译："
      comm -13 "$COMPILED_T" "$SOURCES_T" | head -5 | sed 's/^/      /'
      fail "CovaPlayer 目标 ${m_name} 的编译集合与源目录 .swift 全集不一致（exclude/包外源文件均不允许）"
    fi
    # G-12 / G-15（产物侧真分母，**无条件生效**）：逐源文件的 .o 是否带 __llvm_covmap ——
    # 有可执行行的文件才有该段（实测：协议 + 仅 case 枚举 + typealias 的文件、仅注释文件的 .o
    # 均无 __llvm_covmap）。于是「被编译且有可执行行」的文件集合可以**由产物证明**，
    # 并要求它等于映射侧点名的集合（9.3 的断言，现已无条件）。
    # 旧实现用「.o == <源文件 basename>.o」猜测归因，且**任一 .o 猜不到就整段跳过**
    # （只 echo 一行提示）⇒ 消歧形态一出现（实测：GateDupA/DupCase.swift + GateDupB/dupCase.swift
    # 让 Xcode 输出 DupCase-<md5>.o / dupCase-<md5>.o，两个 `<basename>.o` 都不存在），
    # 旧门禁就打印「跳过 __llvm_covmap 分母判定」并 **EXIT=0** —— 真分母守卫静默失效（F-10）。
    # 现改为消费 OutputFileMap.json 做三向全等，归因不可能一律 fail-closed。
    #
    # ⚠ 各子判据的**可达性**（第 3 轮复审实测，Minor-1；判据一条都不删，只是不再声称拦住）：
    #   (0) 归因唯一性 / map 存在性        —— **可达**：它拦的是「布局漂移」（工具链换形态、
    #       per-file 布局被 .unsafeFlags 改成单产物、target 目录被挪动），不是拦「篡改」。
    #   (1)(2) 编译集合 ↔ map 双向全等      —— **可达**（同上：布局与清单背离时红；.SwiftFileList
    #       与 map 都由同一次构建写出，二者不一致就是真实的不一致）。
    #   手工篡改 OutputFileMap.json        —— **本步不可达**：8/10 会重新生成 map（第 3 轮复审
    #       实测：改完仍 EXIT=0）。留作纵深防御（防「构建没重跑、读到陈旧 map」这种半状态）。
    #   手工替换 <X>.o                     —— **本步通常不可达**：第 3 轮复审实测红在 8/10 的
    #       链接期（xcodebuild 失败 ⇒ 根本走不到 9.1）。留作纵深防御：万一链接没触发（增量布局），
    #       covmap 缺失/区间数变化仍会在 9.3 的真分母比对上暴露。
    #   (4) objdir 内不得有 map 未认领的 .o —— **可达**（陈旧产物、手工夹带文件、消歧产物），
    #       但「用假 .o 冒充」这条攻击由链接期承担，不要按「已拦住替换攻击」理解。
    INSTR_T="$PLAYER_COMPILED_DIR/$m_type-$m_name.instrumented"
    OBJMAP_T="$PLAYER_COMPILED_DIR/$m_type-$m_name.objmap"
    : > "$INSTR_T"
    : > "$OBJMAP_T"
    OBJDIR_T="$(dirname "$FL")"
    OFM_CANDS="$LOG_DIR/player-ofm-cands-$m_name.txt"
    { find "$OBJDIR_T" -maxdepth 1 -name '*-OutputFileMap.json' -type f 2>/dev/null || true; } \
      | sort > "$OFM_CANDS"
    OFM_N="$( { grep -c . "$OFM_CANDS" || true; } | tail -1)"
    case "${OFM_N:-0}" in
      1) OFM_T="$(sed -n '1p' "$OFM_CANDS")" ;;
      0) fail "目标 ${m_name} 的 objdir 内没有 OutputFileMap.json（${OBJDIR_T}）：无法把 .o 归因到源文件，__llvm_covmap 真分母判定 fail-closed（G-15）。若为工具链布局变更，请改 9/10 口径并登记 HANDOVER，不要跳过本判定" ;;
      *) fail "目标 ${m_name} 的 objdir 内有多份 OutputFileMap.json，.o 归因不唯一：$(tr '\n' ' ' < "$OFM_CANDS")（G-15）" ;;
    esac
    # 路径两侧都 realpath 归一化：map 里可能写 /tmp 而编译集合是 /private/tmp（与 lcov SF 同一坑）
    objmap_pairs "$OFM_T" | while IFS="$(printf '\t')" read -r p_src p_obj; do
      { [ -n "$p_src" ] && [ -n "$p_obj" ]; } || continue
      printf '%s\t%s\n' \
        "$(realpath "$p_src" 2>/dev/null || printf '%s' "$p_src")" \
        "$(realpath "$p_obj" 2>/dev/null || printf '%s' "$p_obj")"
    done > "$OBJMAP_T"
    # (1) 正向：每个被编译源文件都必须被 map 归因到一个 .o
    MAP_SRC_T="$LOG_DIR/player-map-src-$m_name.txt"
    { { cut -f1 "$OBJMAP_T" || true; } | sed '/^$/d' | sort -u; } > "$MAP_SRC_T"
    NO_OBJ="$(comm -23 "$COMPILED_T" "$MAP_SRC_T")"
    if [ -n "$NO_OBJ" ]; then
      { printf '%s\n' "$NO_OBJ" | head -5 | sed 's/^/      /'; } || true
      fail "目标 ${m_name} 有源文件在 $(basename "$OFM_T") 里没有 .o 归因（per-file 编译布局漂移，G-15）：$(tr '\n' ' ' <<< "$NO_OBJ" | cut -c1-200)"
    fi
    # (2) 反向：map 点名的源文件也必须在编译集合内（否则产物里有无人编译的 .o）
    MAP_EXTRA="$(comm -13 "$COMPILED_T" "$MAP_SRC_T")"
    if [ -n "$MAP_EXTRA" ]; then
      { printf '%s\n' "$MAP_EXTRA" | head -5 | sed 's/^/      /'; } || true
      fail "目标 ${m_name} 的 OutputFileMap 点名了不在 .SwiftFileList 里的源文件（清单 ↔ 产物背离，G-15）"
    fi
    # (3) 一个 .o 不得同时归因给两个源文件（否则 covmap 证据无法逐文件归属）
    DUP_OBJ="$( { { cut -f2 "$OBJMAP_T" || true; } | sed '/^$/d' | sort | uniq -d; } )"
    if [ -n "$DUP_OBJ" ]; then
      { printf '%s\n' "$DUP_OBJ" | head -5 | sed 's/^/      /'; } || true
      fail "目标 ${m_name} 的 map 把同一个 .o 归因给了多个源文件：逐文件分母不可判定（G-15）"
    fi
    # (4) objdir 内不得出现 map 未认领的 .o（陈旧产物 / 夹带产物）。按 basename 比对：
    #     同一目录内 basename 即身份，且免受 /tmp ↔ /private/tmp 词法差异影响（TD-9）。
    DISK_OBJ_F="$LOG_DIR/player-disk-objs-$m_name.txt"
    MAP_OBJ_F="$LOG_DIR/player-map-objs-$m_name.txt"
    { { find "$OBJDIR_T" -maxdepth 1 -name '*.o' -type f 2>/dev/null || true; } \
        | while IFS= read -r p; do basename "$p"; done | sed '/^$/d' | sort -u; } > "$DISK_OBJ_F"
    { { objmap_pairs "$OFM_T" | cut -f2 || true; objmap_all_objects "$OFM_T" || true; } \
        | while IFS= read -r p; do if [ -n "$p" ]; then basename "$p"; fi; done \
        | sed '/^$/d' | sort -u; } > "$MAP_OBJ_F"
    GHOST_OBJ="$(comm -23 "$DISK_OBJ_F" "$MAP_OBJ_F")"
    if [ -n "$GHOST_OBJ" ]; then
      { printf '%s\n' "$GHOST_OBJ" | head -5 | sed 's/^/      /'; } || true
      fail "目标 ${m_name} 的 objdir 内出现 OutputFileMap 未认领的 .o（陈旧/夹带产物，分母不可判定，G-15）：${OBJDIR_T}"
    fi
    # (5) 逐文件读 __llvm_covmap（区间判据与修复前逐字一致：段存在且 size 非 0）
    while IFS="$(printf '\t')" read -r f o; do
      { [ -n "$f" ] && [ -n "$o" ]; } || continue
      [ -f "$o" ] || fail "目标 ${m_name} 的 .o 归因指向不存在的文件：${o}（← ${f}，G-15）"
      cov_size="$( { otool -l "$o" 2>/dev/null || true; } \
        | awk '/sectname __llvm_covmap/{have=1} have && $1 == "size" { print $2; exit }')"
      if [ -n "$cov_size" ] && [ "$cov_size" != "0x0000000000000000" ]; then
        printf '%s\n' "$f" >> "$INSTR_T"
      fi
    done < "$OBJMAP_T"
    echo "    目标 ${m_name}：编译 $(wc -l < "$COMPILED_T" | tr -d ' ') 个源文件 ↔ map 归因 $(wc -l < "$OBJMAP_T" | tr -d ' ') 个 .o，其中 $(wc -l < "$INSTR_T" | tr -d ' ') 个带 __llvm_covmap（分母候选，无条件判定）"

  else
    # 测试目标：源文件必须全部被编译（防 exclude 收缩）；被编译者必须落在包内或工具链生成目录内
    if [ -n "$(comm -23 "$SOURCES_T" "$COMPILED_T")" ]; then
      echo "    测试目标 ${m_name} 的源文件未被编译（exclude/sources: 收缩）："
      comm -23 "$SOURCES_T" "$COMPILED_T" | head -5 | sed 's/^/      /'
      fail "CovaPlayer 测试目标 ${m_name} 存在未编译的源文件"
    fi
    TEST_OUTSIDE="$(comm -13 "$SOURCES_T" "$COMPILED_T")"
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      case "$o" in
        "$ROOT"/Packages/CovaPlayer/*|"$PLAYER_PACKAGE_DERIVED_DATA"/*) ;;
        *) fail "CovaPlayer 测试目标 ${m_name} 编译了域外文件：${o}" ;;
      esac
    done <<< "${TEST_OUTSIDE:-}"
  fi
done < "$TARGET_MANIFEST"

# 包级视图：非测试 / 测试 target 的编译并集
PLAYER_COMPILED_NONTTEST="$LOG_DIR/player-compiled-nontest.txt"
PLAYER_COMPILED_TEST="$LOG_DIR/player-compiled-test.txt"
{ cat "$PLAYER_COMPILED_DIR"/regular-*.compiled 2>/dev/null || true; } | sort -u > "$PLAYER_COMPILED_NONTTEST"
{ cat "$PLAYER_COMPILED_DIR"/test-*.compiled 2>/dev/null || true; } | sort -u > "$PLAYER_COMPILED_TEST"
[ -s "$PLAYER_COMPILED_NONTTEST" ] || fail "CovaPlayer 非测试 target 的编译并集为空"
# 旧判据保留（防止在 Sources/ 下放置「没有任何 target 声明」的源文件）：Sources 全集必须被非测试 target 编译
PLAYER_LEGACY_SOURCES="$LOG_DIR/player-sources-legacy.txt"
PLAYER_LEGACY_MERGED="$LOG_DIR/player-sources-legacy-merged.txt"
find "$PLAYER_PKG_DIR/Sources" -name '*.swift' -type f -not -path '*/.*' 2>/dev/null \
  | while IFS= read -r f; do realpath "$f" 2>/dev/null || true; done | sort -u > "$PLAYER_LEGACY_SOURCES"
PLAYER_UNCOMPILED="$(comm -23 "$PLAYER_LEGACY_SOURCES" "$PLAYER_COMPILED_NONTTEST")"
if [ -n "$PLAYER_UNCOMPILED" ]; then
  printf '%s\n' "$PLAYER_UNCOMPILED" | head -5 | sed 's/^/      /'
  fail "Packages/CovaPlayer/Sources 下存在未被任何非测试 target 编译的源文件（缩小分母的前置动作）"
fi
# 反向：被编译的非测试文件必须落在「Sources 全集 ∪ 已声明非测试 target 源目录」内
PLAYER_DECLARED_NONTEST="$LOG_DIR/player-declared-nontest.txt"
{ cat "$PLAYER_COMPILED_DIR"/regular-*.sources 2>/dev/null || true; } | sort -u > "$PLAYER_DECLARED_NONTEST"
{ cat "$PLAYER_LEGACY_SOURCES" "$PLAYER_DECLARED_NONTEST" 2>/dev/null || true; } | sort -u > "$PLAYER_LEGACY_MERGED"
PLAYER_PHANTOM="$(comm -23 "$PLAYER_COMPILED_NONTTEST" "$PLAYER_LEGACY_MERGED")"
if [ -n "$PLAYER_PHANTOM" ]; then
  printf '%s\n' "$PLAYER_PHANTOM" | head -5 | sed 's/^/      /'
  fail "CovaPlayer 非测试 target 编译了未登记的文件（符号链接/exclude/包外源文件均不允许）"
fi
echo "    编译集合与源集合一致（全部 target）：非测试 $(wc -l < "$PLAYER_COMPILED_NONTTEST" | tr -d ' ') 个文件 / 测试 $(wc -l < "$PLAYER_COMPILED_TEST" | tr -d ' ') 个文件"
# L1 附加防线：对**实际被编译**的非测试文件再跑一次字面扫描（目录扫描之外的兜底）
# NUL 分隔 + xargs -0：仓路径可能含空格（本仓目录名「ios app」），按空白切分会把路径拆坏。
PLAYER_UI_COMPILED_HITS="$( { tr '\n' '\0' < "$PLAYER_COMPILED_NONTTEST" \
    | xargs -0 -n 20 grep -HnE "$PLAYER_IMPORT_LINE_RE" 2>/dev/null || true; } \
  | grep -wE "$PLAYER_UI_WORD_RE" || true)"
if [ -n "$PLAYER_UI_COMPILED_HITS" ]; then
  { printf '%s\n' "$PLAYER_UI_COMPILED_HITS" | head -10 | sed 's/^/    /' || true; }
  fail "被编译的 CovaPlayer 源文件引入 UI 框架（编译集合逐文件扫描）"
fi
# G-17：同一条 L1 兜底也跑在**测试 target 的编译集合**上（修复前只跑非测试集合）。
PLAYER_UI_COMPILED_HITS_TEST="$( { tr '\n' '\0' < "$PLAYER_COMPILED_TEST" \
    | xargs -0 -n 20 grep -HnE "$PLAYER_IMPORT_LINE_RE" 2>/dev/null || true; } \
  | grep -wE "$PLAYER_UI_WORD_RE" || true)"
if [ -n "$PLAYER_UI_COMPILED_HITS_TEST" ]; then
  { printf '%s\n' "$PLAYER_UI_COMPILED_HITS_TEST" | head -10 | sed 's/^/    /' || true; }
  fail "被编译的 CovaPlayer 测试源文件引入 UI 框架（编译集合逐文件扫描，G-17）"
fi
# G-16 主判据（编译集合口径）：3/10 的白名单扫的是「声明源目录」，这里扫**实际被编译的文件集合**
# —— 后者才是产物事实：exclude/包外文件/生成文件都只能从这里露出来。两类 target 都扫。
player_whitelist_scan_list() { # $1=清单文件 $2=允许清单 $3=同包 target 名集合
  local listf="$1" allowed="$2" ownames="$3" f
  set --
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    set -- "$@" "$f"
  done < "$listf"
  [ "$#" -gt 0 ] || return 0
  player_import_whitelist_scan "$allowed" "$ownames" "$@"
  return 0
}
PLAYER_WHITELIST_COMPILED="$( { player_whitelist_scan_list "$PLAYER_COMPILED_NONTTEST" \
      "$PLAYER_ALLOWED_NONTEST_MODULES" "$PLAYER_PKG_TARGET_NAMES"
    player_whitelist_scan_list "$PLAYER_COMPILED_TEST" \
      "$PLAYER_ALLOWED_TEST_MODULES" "$PLAYER_PKG_TARGET_NAMES"; } | sed '/^$/d' | sort -u)"
if [ -n "$PLAYER_WHITELIST_COMPILED" ]; then
  { printf '%s\n' "$PLAYER_WHITELIST_COMPILED" | head -10 | sed 's/^/      /' || true; }
  fail "被编译的 CovaPlayer 文件（含测试 target）import 了 G-16 允许清单之外的模块：非测试 [${PLAYER_ALLOWED_NONTEST_MODULES}] / 测试 [${PLAYER_ALLOWED_TEST_MODULES}]"
fi
echo "    G-16 白名单（编译集合口径）：非测试 $(wc -l < "$PLAYER_COMPILED_NONTTEST" | tr -d ' ') + 测试 $(wc -l < "$PLAYER_COMPILED_TEST" | tr -d ' ') 个文件，import 全部落在允许清单内"

# ── 9.2 覆盖率产物发现（零路径硬编码；必须是 8/10 本次运行产出的 profdata）
PLAYER_PROFS="$LOG_DIR/player-profdata.txt"
find "$PLAYER_PACKAGE_DERIVED_DATA" -name '*.profdata' -type f -newer "$PLAYER_PROF_MARKER" 2>/dev/null \
  | sort > "$PLAYER_PROFS"
[ -s "$PLAYER_PROFS" ] \
  || fail "8/10 未产出 profdata（-enableCodeCoverage 未生效，或读到的是陈旧产物）—— 覆盖率不可判定为通过"
PLAYER_PROF="$LOG_DIR/player-coverage.profdata"
if [ "$(wc -l < "$PLAYER_PROFS" | tr -d ' ')" -eq 1 ]; then
  cp "$(cat "$PLAYER_PROFS")" "$PLAYER_PROF"
else
  # 多份 profdata 需合并；同样用位置参数累积，避免路径空格被切分
  set --
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    set -- "$@" "$pf"
  done < "$PLAYER_PROFS"
  xcrun llvm-profdata merge -sparse "$@" -o "$PLAYER_PROF" \
    || fail "合并多份 profdata 失败（$(wc -l < "$PLAYER_PROFS" | tr -d ' ') 份）"
fi
# 承载 coverage mapping 的产物：模拟器侧 *.xctest 内的主二进制（不硬编码 bundle 名）
PLAYER_BINS="$LOG_DIR/player-cov-bins.txt"
: > "$PLAYER_BINS"
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  # 只有「含 coverage mapping 的 Mach-O」才会成功产出 SF；据此筛选，避免把资源文件当二进制。
  # 必须用 `grep -c`（读完全部输入）而不是 `grep -q`：-q 提前退出会让左侧收到 SIGPIPE，
  # 在 set -o pipefail 下管道状态为 141 ⇒ 合法二进制被判定为「无 mapping」（干净副本实测踩到）。
  SF_COUNT="$( { xcrun llvm-cov export "$cand" --empty-profile --format=lcov 2>/dev/null || true; } \
    | { grep -c '^SF:' || true; } )"
  if [ "${SF_COUNT:-0}" -gt 0 ]; then
    printf '%s\n' "$cand" >> "$PLAYER_BINS"
  fi
done < <(find "$PLAYER_PACKAGE_DERIVED_DATA/Build/Products" -type f -path '*.xctest/*' \
  -not -path '*dSYM*' -not -path '*_CodeSignature*' -not -name '*.plist' -not -name '*.json' \
  -not -name '*.nib' -not -name '*.h' 2>/dev/null | sort)
[ -s "$PLAYER_BINS" ] || fail "找不到承载 coverage mapping 的测试二进制（*.xctest 内 Mach-O）"
# 路径含空格也必须安全：用位置参数累积，不做词分割
set --
while IFS= read -r b; do
  [ -n "$b" ] || continue
  set -- "$@" -object "$b"
done < "$PLAYER_BINS"
xcrun llvm-cov export -instr-profile="$PLAYER_PROF" --format=lcov "$@" \
  > "$LOG_DIR/player-coverage.lcov" 2>/dev/null || fail "llvm-cov 导出运行侧 lcov 失败"
# 映射侧（与运行无关的 build 事实）：同一批二进制的 coverage mapping 文件全集
xcrun llvm-cov export --empty-profile --format=lcov "$@" \
  > "$LOG_DIR/player-baseline.lcov" 2>/dev/null || fail "llvm-cov 导出映射侧（--empty-profile）lcov 失败"
grep -q '^SF:' "$LOG_DIR/player-coverage.lcov" || fail "运行侧 lcov 无 SF 记录"
echo "    产物发现：$(wc -l < "$PLAYER_PROFS" | tr -d ' ') 份 profdata + $(wc -l < "$PLAYER_BINS" | tr -d ' ') 个测试二进制（零命名硬编码）"

# ── 9.3 域 = 非测试 target 的编译文件集合（分子/分母只由它决定）
LCOV_DOMAIN="$LOG_DIR/player-lcov-domain.txt"
TEST_DOMAIN="$LOG_DIR/player-lcov-testdomain.txt"
normalize_lcov "$LOG_DIR/player-coverage.lcov" "$LOG_DIR/player-coverage.norm.lcov"
normalize_lcov "$LOG_DIR/player-baseline.lcov" "$LOG_DIR/player-baseline.norm.lcov"
grep -q '^SF:' "$LOG_DIR/player-coverage.norm.lcov" || fail "归一化后 lcov 无 SF 记录"
lcov_sf_in_domain "$LOG_DIR/player-coverage.norm.lcov" "$PLAYER_COMPILED_NONTTEST" > "$LCOV_DOMAIN"
lcov_sf_in_domain "$LOG_DIR/player-coverage.norm.lcov" "$PLAYER_COMPILED_TEST" > "$TEST_DOMAIN"
# G-12：运行侧点名的文件集合必须等于「映射侧」集合（同一批二进制的 coverage mapping 全集）
PLAYER_BASELINE_DOMAIN="$LOG_DIR/player-lcov-baseline.txt"
lcov_sf_in_domain "$LOG_DIR/player-baseline.norm.lcov" "$PLAYER_COMPILED_NONTTEST" > "$PLAYER_BASELINE_DOMAIN"
[ -s "$LCOV_DOMAIN" ] \
  || fail "播放器层覆盖率报告未点名任何 CovaPlayer 非测试源文件（采集实际未生效）"
[ -s "$TEST_DOMAIN" ] \
  || fail "播放器层覆盖率报告未点名任何 CovaPlayer 测试源文件（该次运行未真正执行测试，拒绝出报告）"
if ! cmp -s "$LCOV_DOMAIN" "$PLAYER_BASELINE_DOMAIN"; then
  echo "    仅在映射侧（build 有 mapping、运行侧没数据）："
  comm -23 "$PLAYER_BASELINE_DOMAIN" "$LCOV_DOMAIN" | head -5 | sed 's/^/      /'
  echo "    仅在运行侧（报告点名了不存在 mapping 的文件）："
  comm -13 "$PLAYER_BASELINE_DOMAIN" "$LCOV_DOMAIN" | head -5 | sed 's/^/      /'
  fail "播放器层覆盖率报告的文件集合与产物 coverage mapping 全集不一致（局部报告/陈旧产物均不放行，G-12）"
fi
PLAYER_COV_FILES="$(wc -l < "$LCOV_DOMAIN" | tr -d ' ')"
# G-12 / G-15（真分母，**无条件生效**）：映射侧点名的文件集合必须等于「被编译且 .o 带
# __llvm_covmap」的文件集合。⇒「只报 1 个文件的局部报告」不再可能放行：漏掉任何一个有可执行行
# 的编译文件即红；而协议/仅 case 枚举/仅注释这类**无区间文件**两侧都不出现，故不会误红
# （TD-9 合法工程对照）。修复前的 `if ls regular-*.instrumented` 条件式让 9.1 一旦判不出归因
# 就整段静默跳过（F-10），现无该分支：清单缺失即 9.1 fail-closed，走到这里就必须比对。
PLAYER_INSTRUMENTED="$LOG_DIR/player-instrumented.txt"
{ cat "$PLAYER_COMPILED_DIR"/regular-*.instrumented 2>/dev/null || true; } | sed '/^$/d' \
  | sort -u > "$PLAYER_INSTRUMENTED"
[ -s "$PLAYER_INSTRUMENTED" ] \
  || fail "没有任何 .o 带 __llvm_covmap 区间：8/10 的 -enableCodeCoverage 未生效，覆盖率分母不可判定（G-15）"
if ! cmp -s "$PLAYER_BASELINE_DOMAIN" "$PLAYER_INSTRUMENTED"; then
  echo "    被编译且有可执行行、却没进入覆盖率分母的文件："
  { comm -23 "$PLAYER_INSTRUMENTED" "$PLAYER_BASELINE_DOMAIN" | head -5 | sed 's/^/      /'; } || true
  echo "    覆盖率分母里出现、但产物没有对应可执行行的文件："
  { comm -13 "$PLAYER_INSTRUMENTED" "$PLAYER_BASELINE_DOMAIN" | head -5 | sed 's/^/      /'; } || true
  fail "播放器层覆盖率分母与编译产物不一致：点名 $(wc -l < "$PLAYER_BASELINE_DOMAIN" | tr -d ' ') 个 / 应覆盖 $(wc -l < "$PLAYER_INSTRUMENTED" | tr -d ' ') 个（G-12/G-15）"
fi
echo "    分母与产物一致（无条件判定）：${PLAYER_COV_FILES} 个可执行行文件全部点名（.o ↔ OutputFileMap ↔ __llvm_covmap 交叉校验）"

# 分母不可重复计数：同一文件出现多条 SF 记录（多个二进制重叠 mapping）时，逐行 DA 会被累加两次。
LCOV_SF_RECORDS_IN_DOMAIN="$( { awk -v DOM="$LCOV_DOMAIN" '
    BEGIN { while ((getline l < DOM) > 0) { if (l != "") dom[l] = 1 } }
    /^SF:/ { if (substr($0, 4) in dom) c++ }
    END { print c + 0 }
  ' "$LOG_DIR/player-coverage.norm.lcov"; } | tail -1 )"
[ "${LCOV_SF_RECORDS_IN_DOMAIN:-0}" -eq "${PLAYER_COV_FILES:-0}" ] \
  || fail "域内 SF 记录数 ${LCOV_SF_RECORDS_IN_DOMAIN} ≠ 点名文件数 ${PLAYER_COV_FILES}：同一文件多条 coverage 记录，分母不可信"

# ── 9.4 行覆盖率聚合（逐行 DA 记录；分母域 = 非测试编译文件集合）
COVERAGE="$(awk -v DOM="$LCOV_DOMAIN" -v TDOM="$TEST_DOMAIN" '
  BEGIN {
    while ((getline l < DOM) > 0) { if (l != "") dom[l] = 1 }
    while ((getline l < TDOM) > 0) { if (l != "") tdom[l] = 1 }
  }
  /^SF:/ { f = substr($0, 4); indom = (f in dom); intdom = (f in tdom); next }
  /^DA:/ {
    split(substr($0, 4), a, ",")
    if (indom) { total++; if ((a[2] + 0) > 0) covered++ }
    if (intdom) { if ((a[2] + 0) > 0) testhit++ }
  }
  END { printf "%d %d %d", covered, total, testhit }
' "$LOG_DIR/player-coverage.norm.lcov")"
read -r PLAYER_COVERED PLAYER_TOTAL PLAYER_TESTHIT <<< "${COVERAGE:-0 0 0}" || true
case "${PLAYER_TOTAL:-}" in ''|*[!0-9]*) fail "播放器层覆盖率不可读（值='${COVERAGE:-}'）" ;; esac
[ "${PLAYER_TOTAL:-0}" -gt 0 ] \
  || fail "播放器层可执行行数为 0 —— 覆盖率实际未采集，不可判定为通过"
# 反向守卫：测试代码自身必须有命中行，否则该次运行并未真正执行测试（与 7/10 同判据）
[ "${PLAYER_TESTHIT:-0}" -gt 0 ] \
  || fail "播放器层覆盖率数据中测试代码零命中：该次运行未真正执行测试，拒绝出报告"
PLAYER_PCT="$(awk -v c="$PLAYER_COVERED" -v t="$PLAYER_TOTAL" 'BEGIN { printf "%.2f", 100 * c / t }')"
echo "    覆盖率运行有效：测试源码命中 ${PLAYER_TESTHIT} 行，逐文件行数据点名 ${PLAYER_COV_FILES} 个源文件（= 映射侧全集）"
echo "    CovaPlayer 行覆盖率：${PLAYER_COVERED}/${PLAYER_TOTAL} = ${PLAYER_PCT}%"
awk -v p="$PLAYER_PCT" -v m="$PLAYER_COVERAGE_MIN" 'BEGIN { exit !(p >= m) }' \
  || fail "播放器层行覆盖率 ${PLAYER_PCT}% < 阈值 ${PLAYER_COVERAGE_MIN}%"

# ── 9.5 无 UI 不变量的产物侧判据（L3，权威：编译/链接事实，不受注释与语法变体影响）
# 两处各自的词表都从 PLAYER_UI_MODULES 派生（G-14）：
#   符号层 PLAYER_UI_SYMBOL_RE = `$s<长度><模块名>` mangling alternation + ObjC 类名前缀
#     （UI*/WK*/SF*/MF* —— 实测 ObjC 类 UI 控制器在 .o 里**只有** `_OBJC_CLASS_$_…`、
#      没有 `$s<名>` mangling，所以两层必须同时存在）
#   依赖表层 PLAYER_UI_DYLIB_MODULES = 词源**全量**（G-17 起不再有整名豁免；
#     只在「名 ∈ PLAYER_UI_DYLIB_WEAK_OK **且** 该行带 weak 属性」时容忍）
# 两层互补：实测 `import AVKit` + AVPlayerViewController 的 .o 里**只有**
# `_OBJC_CLASS_$_AVPlayerViewController`（没有 `$s5AVKit`），靠依赖表层的
# `/System/Library/Frameworks/AVKit.framework/AVKit` 才抓得到；反之只用 Swift 层类型的框架
# （WidgetKit/RealityKit/RoomPlan…）由符号层负责。
# G-17：符号层遍历的 objdir 集合现在**包含测试 target 的 objdir**（修复前只非测试）。
PLAYER_OBJ_DIRS_UNIQ="$LOG_DIR/player-obj-dirs.uniq.txt"
{ sed '/^$/d' "$PLAYER_OBJ_DIRS" | sort -u > "$PLAYER_OBJ_DIRS_UNIQ"; } || true
[ -s "$PLAYER_OBJ_DIRS_UNIQ" ] || fail "播放器层没有任何 target 的 objdir 落盘：符号层判据空转（G-17）"
PLAYER_OBJ_DIR_N="$(wc -l < "$PLAYER_OBJ_DIRS_UNIQ" | tr -d ' ')"
[ "${PLAYER_OBJ_DIR_N:-0}" -ge "${PLAYER_WHITELIST_TARGETS:-1}" ] \
  || fail "播放器层 objdir 数 ${PLAYER_OBJ_DIR_N} < target 数 ${PLAYER_WHITELIST_TARGETS}：有 target 的产物未被符号层覆盖（G-17）"
while IFS= read -r objdir; do
  [ -n "$objdir" ] || continue
  UI_SYMS="$( { find "$objdir" -maxdepth 1 -name '*.o' -print0 2>/dev/null | xargs -0 xcrun llvm-nm -u 2>/dev/null || true; } \
    | grep -E "$PLAYER_UI_SYMBOL_RE" || true)"
  if [ -n "$UI_SYMS" ]; then
    echo "    objdir：${objdir}"
    { printf '%s\n' "$UI_SYMS" | head -10 | sed 's/^/    /'; } || true
    fail "CovaPlayer 目标的编译产物引用了 UI 框架符号（${objdir}）：设计闸门未验收前禁止编写 UI 代码"
  fi
done < "$PLAYER_OBJ_DIRS_UNIQ"
WEAK_TOLERATED=""
while IFS= read -r b; do
  [ -n "$b" ] || continue
  BIN_DEPS="$LOG_DIR/player-bin-deps.txt"
  { otool -L "$b" 2>/dev/null || true; } > "$BIN_DEPS"
  DYLIB_HITS=""
  for dy_m in $PLAYER_UI_DYLIB_MODULES; do
    # 字面匹配 `<名>.framework`（-F 不是正则；`Photos` 不在词表内，也不会误伤 `PhotosUI`）
    hit="$( { grep -F "$dy_m.framework" "$BIN_DEPS" || true; } | sed '/^$/d' )"
    [ -n "$hit" ] || continue
    case " $PLAYER_UI_DYLIB_WEAK_OK " in
      *" $dy_m "*)
        # G-17：豁免条件是「该框架 **且** weak」。第 3 轮实测：合法态测试二进制里 UIKit 只以
        # `(…, weak)` 出现（AVFoundation 的 Swift overlay 以 -weak_framework 拖入）；
        # 本层一旦直接引用 UIKit 即变**强依赖** ⇒ weak 承载信号（上一批「weak 不承载信号」的
        # 依据被实测否证，故本条从「整名豁免」收窄为「名 + weak 豁免」）。
        # 注：不能用「手工加 -weak_framework」造出合法豁免态 —— `.unsafeFlags(` 已被 2/10 整类禁止。
        strong="$(printf '%s\n' "$hit" | { grep -viE '(^|[^[:alnum:]])weak([^[:alnum:]]|$)' || true; })"
        if [ -z "$strong" ]; then
          WEAK_TOLERATED="${WEAK_TOLERATED} ${dy_m}"
          continue
        fi
        DYLIB_HITS="${DYLIB_HITS}    ${dy_m}（**强依赖**，G-17 起不再豁免）← $(printf '%s\n' "$strong" | head -1 | sed 's/^[[:space:]]*//')"$'\n'
        continue ;;
    esac
    DYLIB_HITS="${DYLIB_HITS}    ${dy_m} ← $(printf '%s\n' "$hit" | head -1 | sed 's/^[[:space:]]*//')"$'\n'
  done
  if [ -n "$DYLIB_HITS" ]; then
    printf '%s' "$DYLIB_HITS"
    fail "CovaPlayer 测试产物直接依赖 UI 框架（${b}）：播放器层禁 UI（判据词表：${PLAYER_UI_DYLIB_MODULES}；weak 容忍项：${PLAYER_UI_DYLIB_WEAK_OK}）"
  fi
done < "$PLAYER_BINS"
echo "    无 UI 不变量（产物侧）：${PLAYER_OBJ_DIR_N} 个 target objdir（含测试 target）的 .o 无 UI 符号引用（mangling ${PLAYER_UI_MANGLE} / ObjC 类前缀 ${PLAYER_UI_OBJC_PREFIXES}）；测试二进制无 UI 框架强依赖（词表 $(printf '%s' "$PLAYER_UI_DYLIB_MODULES" | wc -w | tr -d ' ') 项，仅容忍 weak 形态：[${WEAK_TOLERATED# }]）"

echo "✅ check.sh 全部通过"
