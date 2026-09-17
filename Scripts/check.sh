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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

echo "==> 3/8 依赖图（dump-package）+ 核心层平台中立性不变量"
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

[ "$violations" -eq 0 ] || fail "依赖方向 / 平台中立性不变量校验未通过"
echo "    依赖图与平台中立性校验通过（字面 #if 与 iOS-only 令牌均无命中）"

echo "==> 4/8 有效构建设置（配置×SDK）+ clean build + 实际编译语言版本 + 产物保真"
eff() {
  { grep -E "^[[:space:]]+$2 = " "$1" || true; } | head -1 | sed -E "s/^[[:space:]]+$2 = //"
}
assert_eff() { # file key expected label
  local got
  got="$(eff "$1" "$2")"
  [ "$got" = "$3" ] || fail "$4：有效构建设置 $2='${got}'，应为 '$3'（不得被 target/config/sdk 级覆盖）"
}
assert_no_swift_version_flag() { # file label
  local got
  got="$(eff "$1" OTHER_SWIFT_FLAGS)"
  case "$got" in
    *"-swift-version"*) fail "$2：OTHER_SWIFT_FLAGS 含 -swift-version（可绕过语言版本钉死）：'${got}'" ;;
  esac
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
    assert_no_swift_version_flag "$APPSET" "Cova[${cfg}/${sdk}]"
  done
done
for cfg in $CONFIGURATIONS; do
  TESTSET="$LOG_DIR/settings-tests-$cfg.log"
  xcodebuild -project "$PROJECT" -target CovaTests -configuration "$cfg" -sdk iphonesimulator -showBuildSettings \
    > "$TESTSET" 2>&1 || fail "无法读取 CovaTests target 的 ${cfg} 有效构建设置"
  assert_eff "$TESTSET" SWIFT_VERSION "$REQUIRED_SWIFT_VERSION" "CovaTests[${cfg}] SWIFT_VERSION"
  assert_eff "$TESTSET" SWIFT_STRICT_CONCURRENCY "$REQUIRED_STRICT_CONCURRENCY" "CovaTests[${cfg}] 严格并发"
  assert_eff "$TESTSET" PRODUCT_BUNDLE_IDENTIFIER "$REQUIRED_TEST_BUNDLE_ID" "CovaTests[${cfg}] bundle id"
  assert_no_swift_version_flag "$TESTSET" "CovaTests[${cfg}]"
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

# 实际编译语言版本：从构建日志（xcactivitylog）解析编译器调用（权威，不受构建设置清单影响）
APP_SWIFT_VERSIONS="$(
  find "$DERIVED_DATA/Logs/Build" -name '*.xcactivitylog' -newer "$BUILD_MARKER" 2>/dev/null \
    | while IFS= read -r l; do gunzip -c "$l" 2>/dev/null | strings | grep -oE -- '-swift-version [0-9]+' || true; done \
    | sort -u
)"
[ -n "$APP_SWIFT_VERSIONS" ] \
  || fail "构建日志（xcactivitylog）中未出现任何 -swift-version：无法证明实际编译语言版本"
[ "$APP_SWIFT_VERSIONS" = "-swift-version $REQUIRED_LANGUAGE_VERSION" ] \
  || fail "App 实际编译语言版本异常：$(echo "$APP_SWIFT_VERSIONS" | tr '\n' ' ')"
echo "    实际编译语言版本（App/构建日志）：$(echo "$APP_SWIFT_VERSIONS" | tr '\n' ' ')"

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

# 编译集合一致性：被编译进 CovaCore/CovaCoreTests 的源文件必须都在 Packages/CovaCore 内（即都在扫描范围内）
FILELISTS="$(find Packages/CovaCore/.build -name 'CovaCore*.SwiftFileList' 2>/dev/null || true)"
[ -n "$FILELISTS" ] || fail "未找到 SwiftPM 编译文件清单（*.SwiftFileList），无法校验编译集合"
BAD_FILES=0
for fl in $FILELISTS; do
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p="$(printf '%s' "$line" | sed 's/\\ / /g')"
    case "$p" in
      "$ROOT"/Packages/CovaCore/*) ;;
      *) echo "    编译集合越界（被编译但不在 Packages/CovaCore 内）：$p"; BAD_FILES=1 ;;
    esac
  done < "$fl"
done
[ "$BAD_FILES" -eq 0 ] || fail "存在被编译但未被静态扫描覆盖的 CovaCore 源文件"
echo "    编译集合一致：$(echo "$FILELISTS" | wc -l | tr -d ' ') 个清单内的源文件全部位于 Packages/CovaCore"

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
COVERAGE="$( { xcrun llvm-cov export "$CORE_BIN" -instr-profile="$CORE_PROF" --format=lcov 2>/dev/null || true; } | awk '
  /^SF:/ { in_pkg = (index($0, "Packages/CovaCore/") > 0) && (index($0, "/.build/") == 0)
           in_test = in_pkg && (index($0, "/Tests/") > 0)
           in_core = in_pkg && (index($0, "/Tests/") == 0) }
  /^DA:/ {
    if (in_core) { split(substr($0, 4), a, ","); total++; if ((a[2] + 0) > 0) covered++ }
    if (in_test) { split(substr($0, 4), b, ","); if ((b[2] + 0) > 0) testhit++ }
  }
  END { printf "%d %d %d", covered, total, testhit }
')"
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
