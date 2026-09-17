#!/usr/bin/env bash
# 本地门禁（G0–G4 全程复用，fail-closed）：
#   预热模拟器 → 生成工程 → 结构与零第三方依赖（含本地制品/框架/语言模式）
#   → 分层依赖边界 + 核心层平台中立性不变量（静态，构建前）
#   → 有效构建设置钉死（Debug 与 Release）+ Debug 构建 + 产物保真
#   → 应用工程测试（xcresult 计数 + xccov 采集有效性）
#   → 核心层包测试（iOS 模拟器，xcresult 计数）
#   → 核心层行覆盖率 ≥80%（SwiftPM 插桩 + llvm-cov）
#
# 静态判定的设计原则（第四轮评审裁决）：
#   1) 不使用任何逐字符词法/状态机（raw string、插值、转义等形态会让状态机失步并静默 fail-open）；
#   2) 一律用「固定字符串 / 单条正则」匹配，无跨行状态，任何字符序列都不会让它翻转后失效；
#   3) 注释与字符串里的命中同样判失败（fail-closed）。误报按下列方式处理：
#      - 源码里出现字面 `#if`：视为违反平台中立性不变量（CovaCore 是纯逻辑层，不需要条件编译）；
#        若确需使用，走 docs/NEEDS.md / decisions.md 登记，不得静默放宽。
#      - 依赖/框架声明扫描：命中 url:/id:/.binaryTarget(/frameworks: 等即失败（含注释中的同形文本）。
#   任一步失败均非零退出；日志落在 .build/check/ 下（.build/ 不入 git）。
# 用法：./Scripts/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="Cova"
PROJECT="Cova.xcodeproj"
SIM_NAME="${COVA_SIM_NAME:-iPhone 17 Pro}"
DESTINATION="platform=iOS Simulator,name=$SIM_NAME"
LOG_DIR="$ROOT/.build/check"
DERIVED_DATA="$LOG_DIR/DerivedData"
PACKAGE_DERIVED_DATA="$LOG_DIR/DerivedData-CovaCore"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Cova.app"
RESULT_BUNDLE="$LOG_DIR/Cova.xcresult"
CORE_RESULT_BUNDLE="$LOG_DIR/CovaCoreTests.xcresult"
BASELINE_FILE="$ROOT/Scripts/test-count-baseline.env"
mkdir -p "$LOG_DIR"

PACKAGES="CovaCore CovaPlayer CovaUI CovaFeature"
CORE_SOURCES="Packages/CovaCore/Sources/"
CORE_TESTS="Packages/CovaCore/Tests/"
CORE_PACKAGE_SWIFT="Packages/CovaCore/Package.swift"
CONFIGURATIONS="Debug Release"

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
# CovaCore 是纯逻辑层（D3/D9），覆盖率在宿主侧测量 → 模块面必须完全平台中立
IOS_ONLY_MODULES="UIKit SwiftUI AVFoundation AVKit ARKit CoreMotion HealthKit WidgetKit Photos PhotosUI BackgroundTasks CallKit WatchKit SpriteKit MetalKit MapKit"
# CovaCore 平台声明白名单（.macOS 仅用于宿主侧覆盖率测量，不得用于产品分支）
REQUIRED_CORE_PLATFORMS=".iOS(.v26),.macOS(.v14)"
# 包语言模式（Swift 6 严格并发的前提）
REQUIRED_LANGUAGE_MODE="swiftLanguageModes:[.v6]"

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

# 取一个目录下所有 Swift 源码 import 的模块名。
# 实现：把每个文件的行拼成一段文本后用单条正则匹配（无词法状态机，不可能失步）；
#       因此「import\nCovaModule」这类换行拆分同样被识别；注释/字符串中的 import 也会命中（fail-closed）。
imported_modules() {
  local dir="$1" f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    tr '\n' ' ' < "$f"
    echo
  done < <(find "$dir" -name '*.swift' 2>/dev/null) \
    | grep -oE '(^|[^A-Za-z0-9_])(import|canImport)[[:space:]]+((typealias|struct|class|enum|protocol|func|var|let)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*' \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*$' | sort -u
}

check_imports() {
  local label="$1" dir="$2" allowed="$3" module violations=0
  for module in $(imported_modules "$dir"); do
    case "$module" in
      Cova*) ;;
      *) continue ;;
    esac
    case " $PACKAGES " in
      *" $module "*) ;;
      *) echo "    依赖方向违规：${label} 引用了未登记的 Cova 模块 ${module}"; violations=1; continue ;;
    esac
    case " $allowed " in
      *" $module "*) ;;
      *) echo "    依赖方向违规：${label} 不允许引用 ${module}"; violations=1 ;;
    esac
  done
  return "$violations"
}

# 可信计数源：xcresult 测试摘要（不受测试输出文本、源码文本影响）
xcresult_test_count() {
  local bundle="$1" json="$LOG_DIR/xcresult-summary.json" p f s
  xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$json" 2>/dev/null || return 1
  p="$(plutil -extract passedTests raw -o - "$json" 2>/dev/null || true)"
  f="$(plutil -extract failedTests raw -o - "$json" 2>/dev/null || true)"
  s="$(plutil -extract skippedTests raw -o - "$json" 2>/dev/null || true)"
  for v in "$p" "$f" "$s"; do
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  echo $(( p + f + s ))
}

assert_tests() { # label executed baseline
  local label="$1" executed="$2" baseline="$3"
  case "$executed" in ''|*[!0-9]*) fail "${label}：无法取得可信执行用例数（值='${executed}'）" ;; esac
  echo "    ${label}：executed(可信源 xcresult)=${executed}，基线=${baseline}"
  [ "$executed" -ge "$baseline" ] \
    || fail "${label}：执行用例数 ${executed} < 基线 ${baseline}（不得删除/弱化既有测试）"
}

echo "==> 0/8 预热模拟器（${SIM_NAME}）"
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null

echo "==> 1/8 生成工程（XcodeGen $(xcodegen --version | awk '{print $NF}')）"
xcodegen generate --spec project.yml

echo "==> 2/8 校验工程结构、包语言模式与零第三方依赖"
test -f project.yml || fail "缺少 project.yml"
test -f Config/Info.plist || fail "缺少 Config/Info.plist"
test -f Cova/CovaApp.swift || fail "缺少 Cova/CovaApp.swift"
test -d design/assets/CovaAssets.xcassets/AppIcon.appiconset || fail "缺少官方 AppIcon 资产"
test -f design/assets/CovaAssets.xcassets/AppIcon.appiconset/Contents.json || fail "AppIcon 资产缺少 Contents.json"
for pkg in $PACKAGES; do
  test -f "Packages/$pkg/Package.swift" || fail "缺少本地包 Packages/$pkg/Package.swift"
  grep -q "path: Packages/$pkg" project.yml || fail "project.yml 未以本地 path 声明包 $pkg"
done
test -d CovaTests || fail "缺少 CovaTests 目录"
test -d "$CORE_TESTS" || fail "缺少核心层测试目录 ${CORE_TESTS}"

# 包语言模式：必须 Swift 6（F5）
for pkg in $PACKAGES; do
  norm="$(tr -d '[:space:]' < "Packages/$pkg/Package.swift")"
  case "$norm" in
    *"swift-tools-version:6."*) ;;
    *) fail "Packages/$pkg/Package.swift 的 swift-tools-version 必须 >= 6.0" ;;
  esac
  case "$norm" in
    *"$REQUIRED_LANGUAGE_MODE"*) ;;
    *) fail "Packages/$pkg/Package.swift 必须声明 swiftLanguageModes: [.v6]（Swift 6 语言模式）" ;;
  esac
  case "$norm" in
    *"swiftLanguageModes:[.v5]"*|*"swiftLanguageModes:[.v4]"*)
      fail "Packages/$pkg/Package.swift 语言模式被降级（禁止 v5/v4）" ;;
  esac
done

# 零第三方依赖：整文件压平后用单条正则匹配（跨行有效；不做词法剥离 → 注释命中亦拦，fail-closed）。
# 覆盖 .package(url:…)、.package(name:…url:…)、.package(id:…)、.binaryTarget(…)、裸 http(s)://、
# project.yml 的 frameworks:/framework:。
for spec in $(find Packages -name Package.swift) project.yml; do
  flat="$(tr '\n' ' ' < "$spec")"
  if echo "$flat" | grep -Eq '\.package[[:space:]]*\([^)]*(url|id)[[:space:]]*:|\.binaryTarget[[:space:]]*\(|http://|https://|frameworks[[:space:]]*:|framework[[:space:]]*:'; then
    fail "$spec 含远程依赖/远程制品/本地二进制制品/框架声明，违反零第三方依赖白名单（AGENTS.md 硬边界 4）"
  fi
done
echo "    结构校验通过（4 个本地包、Swift 6 语言模式、无外部依赖/制品/框架）"

echo "==> 3/8 校验分层依赖边界 + 核心层平台中立性不变量"
violations=0
for pkg in $PACKAGES; do
  allowed="$(allowed_deps "$pkg")"
  declared="$( { tr '\n' ' ' < "Packages/$pkg/Package.swift" \
      | grep -oE '\.package\([^)]*path:[[:space:]]*"\.\./[A-Za-z]+"' \
      | sed -E 's#.*\.\./##; s#".*##'; } || true )"
  for sibling in $declared; do
    case " $allowed " in
      *" $sibling "*) ;;
      *) echo "    依赖方向违规：$pkg 声明了不允许的依赖 $sibling"; violations=1 ;;
    esac
  done
  check_imports "$pkg(Sources)" "Packages/$pkg/Sources" "$allowed" || violations=1
  check_imports "$pkg(Tests)" "Packages/$pkg/Tests" "${pkg} ${allowed}" || violations=1
done
check_imports "Cova(应用)" "Cova" "$PACKAGES" || violations=1
check_imports "CovaTests(测试)" "CovaTests" "$PACKAGES" || violations=1

# 平台中立性不变量（第四轮裁决：字面 #if 即失败，不做词法剥离）
# 依据：D3/D9 —— CovaCore 是纯逻辑层（Codable + 沙盒文件），不需要任何条件编译；
#       覆盖率在宿主侧测得，若存在条件编译则测量口径与 iOS 编译面不一致。注释里的 #if 也拦（fail-closed）。
CC_HITS="$(grep -rn --fixed-strings '#if' "$CORE_SOURCES" "$CORE_TESTS" 2>/dev/null || true)"
if [ -n "$CC_HITS" ]; then
  echo "$CC_HITS" | head -20 | sed 's/^/    /'
  echo "    ↑ CovaCore 出现字面 #if：违反平台中立性不变量（条件编译整类禁止，含注释/字符串中的命中）"
  violations=1
fi
CORE_IMPORTS="$(imported_modules "$CORE_SOURCES")"
for m in $IOS_ONLY_MODULES; do
  if echo "$CORE_IMPORTS" | grep -qx "$m"; then
    echo "    CovaCore 引用了 iOS-only 模块：${m}"
    violations=1
  fi
done
FLAT_PKG="$(tr '\n' ' ' < "$CORE_PACKAGE_SWIFT")"
if echo "$FLAT_PKG" | grep -Eq '\.when[[:space:]]*\([[:space:]]*platforms|\.define[[:space:]]*\(|\.unsafeFlags[[:space:]]*\('; then
  echo "    CovaCore/Package.swift 含平台条件构建设置（.when(platforms:) / .define( / .unsafeFlags(）"
  violations=1
fi
CORE_PLATFORMS="$(grep -E '^[[:space:]]*platforms:' "$CORE_PACKAGE_SWIFT" | head -1 \
  | sed -E 's/.*\[(.*)\].*/\1/' | tr -d ' ')"
[ "$CORE_PLATFORMS" = "$REQUIRED_CORE_PLATFORMS" ] \
  || { echo "    CovaCore 平台声明为 [${CORE_PLATFORMS}]，必须恰为 [${REQUIRED_CORE_PLATFORMS}]（.macOS 仅供宿主侧覆盖率测量）"; violations=1; }

[ "$violations" -eq 0 ] || fail "分层依赖边界 / 平台中立性不变量校验未通过"
echo "    分层边界校验通过（含各包 Tests/）"
echo "    平台中立性不变量成立：无字面 #if、无 iOS-only import、平台声明受控"

echo "==> 4/8 有效构建设置钉死（Debug 与 Release）+ Debug 构建 + 产物保真"
eff() {
  grep -E "^[[:space:]]+$2 = " "$1" | head -1 | sed -E "s/^[[:space:]]+$2 = //"
}
assert_eff() { # file key expected label
  local got
  got="$(eff "$1" "$2")"
  [ "$got" = "$3" ] || fail "$4：有效构建设置 $2='${got}'，应为 '$3'（不得被 target/config 级覆盖）"
}
for cfg in $CONFIGURATIONS; do
  APPSET="$LOG_DIR/build-settings-app-$cfg.log"
  TESTSET="$LOG_DIR/build-settings-tests-$cfg.log"
  xcodebuild -project "$PROJECT" -target Cova -configuration "$cfg" -showBuildSettings \
    > "$APPSET" 2>&1 || fail "无法读取 Cova target 的 ${cfg} 有效构建设置"
  xcodebuild -project "$PROJECT" -target CovaTests -configuration "$cfg" -showBuildSettings \
    > "$TESTSET" 2>&1 || fail "无法读取 CovaTests target 的 ${cfg} 有效构建设置"
  assert_eff "$APPSET" EFFECTIVE_SWIFT_VERSION "$REQUIRED_EFFECTIVE_SWIFT" "Cova[${cfg}] Swift 语言版本"
  assert_eff "$APPSET" SWIFT_VERSION "$REQUIRED_SWIFT_VERSION" "Cova[${cfg}] SWIFT_VERSION"
  assert_eff "$APPSET" SWIFT_STRICT_CONCURRENCY "$REQUIRED_STRICT_CONCURRENCY" "Cova[${cfg}] 严格并发"
  assert_eff "$APPSET" IPHONEOS_DEPLOYMENT_TARGET "$REQUIRED_DEPLOYMENT_TARGET" "Cova[${cfg}] 部署目标（D1）"
  assert_eff "$APPSET" PRODUCT_BUNDLE_IDENTIFIER "$REQUIRED_APP_BUNDLE_ID" "Cova[${cfg}] bundle id（D13）"
  assert_eff "$TESTSET" SWIFT_VERSION "$REQUIRED_SWIFT_VERSION" "CovaTests[${cfg}] SWIFT_VERSION"
  assert_eff "$TESTSET" SWIFT_STRICT_CONCURRENCY "$REQUIRED_STRICT_CONCURRENCY" "CovaTests[${cfg}] 严格并发"
  assert_eff "$TESTSET" PRODUCT_BUNDLE_IDENTIFIER "$REQUIRED_TEST_BUNDLE_ID" "CovaTests[${cfg}] bundle id"
done
APPSET_DEBUG="$LOG_DIR/build-settings-app-Debug.log"
EXPECT_VERSION="$(eff "$APPSET_DEBUG" CFBundleShortVersionString)"
EXPECT_BUILD="$(eff "$APPSET_DEBUG" CFBundleVersion)"
[ -n "$EXPECT_VERSION" ] && [ -n "$EXPECT_BUILD" ] || fail "无法从有效构建设置取版本号"
echo "$EXPECT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "CFBundleShortVersionString='${EXPECT_VERSION}' 不符合 X.Y.Z（AGENTS 版本规则）"
echo "$EXPECT_BUILD" | grep -qE '^[1-9][0-9]*$' \
  || fail "CFBundleVersion='${EXPECT_BUILD}' 必须为正整数"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" build > "$LOG_DIR/build.log" 2>&1; then
  echo "构建失败，日志尾部（完整日志 ${LOG_DIR}/build.log）："
  tail -60 "$LOG_DIR/build.log"
  exit 1
fi
grep -E "^\*\* BUILD (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/build.log" | tail -1
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
grep -E "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/test-app.log" | tail -1
APP_EXEC="$(xcresult_test_count "$RESULT_BUNDLE" || true)"
assert_tests "CovaTests" "$APP_EXEC" "$APP_MIN"
xcrun xccov view --report "$RESULT_BUNDLE" > "$LOG_DIR/xccov.txt" 2>/dev/null \
  || fail "无法读取覆盖率报告（gatherCoverageData 未生效？）"
MAX_EXEC_LINES="$(grep -oE '\([0-9]+/[0-9]+\)' "$LOG_DIR/xccov.txt" | tr -d '()' \
  | awk -F/ '{ if ($2 + 0 > max) max = $2 + 0 } END { print max + 0 }')"
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
grep -E "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/test-core-ios.log" | tail -1
CORE_IOS_EXEC="$(xcresult_test_count "$CORE_RESULT_BUNDLE" || true)"
assert_tests "CovaCoreTests(iOS)" "$CORE_IOS_EXEC" "$CORE_MIN"

echo "==> 7/8 核心层行覆盖率（SwiftPM 插桩 + llvm-cov，阈值 ${CORE_COVERAGE_MIN}%）"
echo "    说明：Xcode 不为本地 SwiftPM 包目标产出 xccov 覆盖率，故由 SwiftPM 插桩测量；"
echo "          被测源码与 iOS 运行同一份，平台中立性已由 3/8 不变量强制。"
if [ -d Packages/CovaCore/.build ]; then
  find Packages/CovaCore/.build -type d -name codecov -exec rm -rf {} + >/dev/null 2>&1 || true
fi
if ! swift test --package-path Packages/CovaCore --enable-code-coverage \
  > "$LOG_DIR/test-core-coverage.log" 2>&1; then
  echo "覆盖率测试运行失败，日志尾部："
  tail -60 "$LOG_DIR/test-core-coverage.log"
  exit 1
fi
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

COVERAGE="$(xcrun llvm-cov export "$CORE_BIN" -instr-profile="$CORE_PROF" --format=lcov 2>/dev/null | awk -v core="$CORE_SOURCES" -v tdir="$CORE_TESTS" '
  /^SF:/ { in_core = (index($0, core) > 0); in_test = (index($0, tdir) > 0) }
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
