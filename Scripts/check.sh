#!/usr/bin/env bash
# 本地门禁（G0–G4 全程复用，fail-closed）：
#   0 预热模拟器 → 1 生成工程 → 2 结构/语言模式/工程依赖令牌 → 3 依赖图 + 平台中立性不变量
#   → 4 有效构建设置（配置×SDK）+ clean build + 实际编译语言版本 + 产物保真
#   → 5 应用测试（xcresult passed/failed）+ xccov 采集有效性 → 6 核心层 iOS 测试
#   → 7 核心层覆盖率（SwiftPM 插桩，含编译集合一致性与实际语言版本断言）
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
CORE_COVERAGE_MIN="$COVERAGE_FLOOR"

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
IOS_ONLY_MODULES="UIKit SwiftUI AVFoundation AVKit ARKit RealityKit CoreMotion HealthKit WidgetKit Photos PhotosUI BackgroundTasks CallKit WatchKit SpriteKit MetalKit MapKit RoomPlan"
# CovaCore 平台声明白名单（.macOS 仅用于宿主侧覆盖率测量，不得用于产品分支）
REQUIRED_CORE_PLATFORMS=".iOS(.v26),.macOS(.v14)"

fail() {
  echo "❌ $1"
  exit 1
}

# 阈值只允许抬高：任何低于基准的取值一律拒绝执行（fail-closed）
if [ -n "${COVA_CORE_COVERAGE_MIN:-}" ]; then
  case "$COVA_CORE_COVERAGE_MIN" in
    ''|*[!0-9]*) fail "COVA_CORE_COVERAGE_MIN 必须是整数，收到 '${COVA_CORE_COVERAGE_MIN}'" ;;
  esac
  [ "$COVA_CORE_COVERAGE_MIN" -ge "$COVERAGE_FLOOR" ] \
    || fail "COVA_CORE_COVERAGE_MIN=${COVA_CORE_COVERAGE_MIN} < 基准 ${COVERAGE_FLOOR}：阈值只允许抬高，拒绝执行"
  CORE_COVERAGE_MIN="$COVA_CORE_COVERAGE_MIN"
  echo "提示：覆盖率阈值被抬高到 ${CORE_COVERAGE_MIN}%（基准 ${COVERAGE_FLOOR}%）"
fi

# 测试数量下限来自入库基线文件（删测试必须显式改它，随 commit 进入审查）
[ -f "$BASELINE_FILE" ] || fail "缺少测试数量基线文件 ${BASELINE_FILE}"
# shellcheck disable=SC1090
. "$BASELINE_FILE"
case "${APP_MIN:-}" in ''|*[!0-9]*) fail "基线 APP_MIN 非法：'${APP_MIN:-}'" ;; esac
case "${CORE_MIN:-}" in ''|*[!0-9]*) fail "基线 CORE_MIN 非法：'${CORE_MIN:-}'" ;; esac
[ "$APP_MIN" -ge 1 ] || fail "基线 APP_MIN=${APP_MIN} 必须 >= 1（零测试不允许）"
[ "$CORE_MIN" -ge 1 ] || fail "基线 CORE_MIN=${CORE_MIN} 必须 >= 1（零测试不允许）"

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
  echo "    ${label}：passed=${p} failed=${f} skipped=${s}，基线=${baseline}（只认 passed）"
  [ "$f" -eq 0 ] || fail "${label}：failed=${f} 必须为 0"
  [ "$p" -ge "$baseline" ] \
    || fail "${label}：passed=${p} < 基线 ${baseline}（skipped 不计入，不得删除/弱化既有测试）"
}

echo "==> 0/8 预热模拟器（${SIM_NAME}）"
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null

echo "==> 1/8 生成工程（XcodeGen $(xcodegen --version | awk '{print $NF}')）"
xcodegen generate --spec project.yml

echo "==> 2/8 校验工程结构、语言模式与工程依赖令牌"
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
done
echo "    结构校验通过（4 个本地包、语言模式 6、无远程包/框架/二进制制品）"

echo "==> 3/8 依赖图（dump-package）+ 核心层平台中立性 + 播放器无 UI 不变量"
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
done

# 符号链接整类禁止（CovaCore 内）：SwiftPM 会跟随并编译，而 .SwiftFileList 记录词法路径，
# 二者差异正是「链接目录指向包外」的绕过机制；CovaCore 是纯逻辑层，不需要符号链接。
SYMLINKS="$(find Packages/CovaCore -type l -not -path '*/.*' 2>/dev/null || true)"
if [ -n "$SYMLINKS" ]; then
  printf '%s\n' "$SYMLINKS" | head -10 | sed 's/^/    /'
  fail "CovaCore 内存在符号链接（整类禁止，点号路径除外——SwiftPM 不编译点号目录；如需共享源文件请改为仓内真实文件）"
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

# 播放器层无 UI 不变量（AGENTS 硬边界 8「G1/G2 未验收不写 UI」+ D3/D4 分层的机械化为门禁）：
# CovaPlayer 只允许非 UI 播放能力（AVFoundation/MediaPlayer），出现 UI 框架 import 即失败。
# 判据取「行首 import 语句」而非全词扫描：UI 代码必然需要 import，且不会因注释/文档提到
# SwiftUI 而误红（TD-9：合法工程对照不得误红优先于 fail-closed 的字面令牌口径）。
# 两段式：先取 import 行（含属性前缀与 `import class UIKit.UIView` 选择式导入），再按词边界取 UI 模块。
PLAYER_UI_HITS="$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' \
  Packages/CovaPlayer/Sources 2>/dev/null | grep -wE 'SwiftUI|UIKit' || true)"
if [ -n "$PLAYER_UI_HITS" ]; then
  printf '%s\n' "$PLAYER_UI_HITS" | head -10 | sed 's/^/    /'
  echo "    ↑ CovaPlayer 引入了 UI 框架：设计闸门（G1/G2）未验收前禁止编写 UI 代码"
  violations=1
fi
# 反向防绕过：源集合为空时上面的扫描恒真通过（清空目录即免检），故要求播放器层非空。
PLAYER_SRC_COUNT="$(find Packages/CovaPlayer/Sources -name '*.swift' -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "${PLAYER_SRC_COUNT:-0}" -ge 1 ] \
  || { echo "    CovaPlayer/Sources 下无任何 .swift 源文件（清空源目录不得绕过无 UI 不变量）"; violations=1; }

[ "$violations" -eq 0 ] || fail "依赖方向 / 平台中立性 / 播放器无 UI 不变量校验未通过"
echo "    依赖图与不变量校验通过（CovaCore 无字面 #if 与 iOS-only 令牌；CovaPlayer ${PLAYER_SRC_COUNT} 个源文件且无 UI import）"

echo "==> 4/8 有效构建设置（配置×SDK）+ clean build + 实际编译语言版本 + 产物保真"
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

echo "==> 5/8 应用工程测试（CovaTests，iOS Simulator）"
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

echo "==> 6/8 核心层包测试（CovaCoreTests，iOS Simulator）"
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

echo "==> 7/8 核心层行覆盖率（SwiftPM 插桩 + llvm-cov，阈值 ${CORE_COVERAGE_MIN}%）"
echo "    说明：Xcode 不为本地 SwiftPM 包目标产出 xccov 覆盖率，故由 SwiftPM 插桩测量；"
echo "          被测源码与 iOS 运行同一份，平台中立性已由 3/8 不变量强制。"
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

echo "✅ check.sh 全部通过"
