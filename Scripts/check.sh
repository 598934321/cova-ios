#!/usr/bin/env bash
# 本地门禁（G0–G4 全程复用，fail-closed）：
#   预热模拟器 → 生成工程 → 结构与零第三方依赖 → 分层依赖边界（含各包 Tests/）
#   → 配置钉死 + Debug 构建（iOS 模拟器）+ 产物 Info.plist 保真
#   → 应用工程测试（xcresult 计数 + xccov 采集有效性）
#   → 核心层包测试（iOS 模拟器，xcresult 计数）
#   → 核心层平台中立性静态断言 → 核心层行覆盖率 ≥80%（SwiftPM 插桩 + llvm-cov）
# 任一步失败均非零退出；日志落在 .build/check/ 下（.build/ 不入 git）。
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
mkdir -p "$LOG_DIR"

PACKAGES="CovaCore CovaPlayer CovaUI CovaFeature"
CORE_SOURCES="Packages/CovaCore/Sources/"
MIN_TESTS_APP=2
MIN_TESTS_CORE=4

# 覆盖率阈值：常量基准，环境变量只允许抬高（防止把门禁调到 0 绕过）
COVERAGE_FLOOR=80
CORE_COVERAGE_MIN="$COVERAGE_FLOOR"

# 钉死的关键配置（D13 / AGENTS 版本规则）
REQUIRED_APP_BUNDLE_ID="cn.covalink.ios"
REQUIRED_TEST_BUNDLE_ID="cn.covalink.ios.tests"
REQUIRED_DEPLOYMENT_TARGET="26.0"
# 覆盖率在 macOS 宿主侧测量，故 CovaCore 必须平台中立（否则测量口径与 iOS 编译面不一致）
IOS_ONLY_MODULES="UIKit SwiftUI AVFoundation AVKit ARKit CoreMotion HealthKit WidgetKit Photos PhotosUI BackgroundTasks CallKit WatchKit SpriteKit MetalKit MapKit"

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

allowed_deps() {
  case "$1" in
    CovaCore)    echo "" ;;
    CovaPlayer)  echo "CovaCore" ;;
    CovaUI)      echo "CovaCore" ;;
    CovaFeature) echo "CovaCore CovaPlayer CovaUI" ;;
  esac
}

# 源码内测试函数计数（先剥行注释与单行块注释，避免注释虚增/虚减）
declared_test_count() {
  [ -d "$1" ] || { echo 0; return 0; }
  { find "$1" -name '*.swift' -exec awk '
      { line = $0
        sub(/\/\/.*/, "", line)
        gsub(/\/\*[^*]*\*\//, " ", line)
        print line }' {} + 2>/dev/null || true; } \
    | grep -oE 'func[[:space:]]+test[A-Za-z0-9_]*' | wc -l | tr -d ' '
}

# 可信计数源：xcresult 测试摘要（不受测试输出文本影响）
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

# SwiftPM 覆盖率运行未被测试执行时，测试源码的覆盖命中数为 0（结构化产物，不受测试输出文本影响）

assert_tests() {
  local label="$1" executed="$2" srcdir="$3" min="$4" declared
  declared="$(declared_test_count "$srcdir")"
  case "$executed" in ''|*[!0-9]*) fail "${label}：无法取得可信执行用例数（值='${executed}'）" ;; esac
  echo "    ${label}：executed(可信源)=${executed}，declared(源码，已剥注释)=${declared}，下限=${min}"
  [ "$executed" -ge "$min" ] || fail "${label}：执行用例数 ${executed} < 下限 ${min}（零测试/测试被清空一律失败）"
  [ "$declared" -ge "$min" ] || fail "${label}：源码内测试函数数 ${declared} < 下限 ${min}（不得删除/弱化既有测试）"
  [ "$executed" -ge "$declared" ] || fail "${label}：执行用例数 ${executed} < 声明测试函数数 ${declared}（存在未执行的测试）"
}

# 提取目录下所有 Swift 源码 import 的模块名。
# 关键：先按行剥注释，再把整个文件压平成一行后分词 —— 覆盖 @testable import、种类前缀、
# 以及 `import\nCovaPlayer` 这类换行拆分形态。
imported_modules() {
  [ -d "$1" ] || return 0
  find "$1" -name '*.swift' -exec awk '
    { line = $0
      sub(/\/\/.*/, "", line)
      gsub(/\/\*[^*]*\*\//, " ", line)
      buf = buf " " line }
    END {
      gsub(/[^A-Za-z0-9_]/, " ", buf)
      n = split(buf, t, " ")
      for (i = 1; i <= n; i++) {
        if (t[i] == "import" || t[i] == "canImport") {
          j = i + 1
          if (t[j] ~ /^(typealias|struct|class|enum|protocol|func|var|let)$/) j++
          if (t[j] != "") print t[j]
        }
      }
    }' {} + 2>/dev/null | sort -u
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

echo "==> 0/8 预热模拟器（${SIM_NAME}）"
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null

echo "==> 1/8 生成工程（XcodeGen $(xcodegen --version | awk '{print $NF}')）"
xcodegen generate --spec project.yml

echo "==> 2/8 校验工程结构与零第三方依赖"
test -f project.yml || fail "缺少 project.yml"
test -f Config/Info.plist || fail "缺少 Config/Info.plist"
test -f Cova/CovaApp.swift || fail "缺少 Cova/CovaApp.swift"
test -d design/assets/CovaAssets.xcassets/AppIcon.appiconset || fail "缺少官方 AppIcon 资产"
test -f design/assets/CovaAssets.xcassets/AppIcon.appiconset/Contents.json || fail "AppIcon 资产缺少 Contents.json"
for pkg in $PACKAGES; do
  test -f "Packages/$pkg/Package.swift" || fail "缺少本地包 Packages/$pkg/Package.swift"
  grep -q "path: Packages/$pkg" project.yml || fail "project.yml 未以本地 path 声明包 $pkg"
done
for tdir in CovaTests Packages/CovaCore/Tests; do
  [ "$(declared_test_count "$tdir")" -ge 1 ] \
    || fail "${tdir} 下没有任何测试函数（测试文件缺失或已清空）"
done

# 零第三方依赖：剥注释 + 跨行压平后，命中 url: 或 http(s):// 一律失败。
# 覆盖 .package(url:…)、.package(name:url:…)、.binaryTarget(url:…)、project.yml packages url:
for spec in $(find Packages -name Package.swift) project.yml; do
  flat="$(sed -E 's#//.*##' "$spec" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  case "$flat" in
    *"url:"*|*"url :"*|*"http://"*|*"https://"*)
      fail "$spec 含远程依赖/远程制品声明（url: 或 http(s)://），违反零第三方依赖白名单（AGENTS.md 硬边界 4）"
      ;;
  esac
done
echo "    结构校验通过（4 个本地包，无外部依赖/远程制品）"

echo "==> 3/8 校验分层依赖边界"
echo "    说明：Xcode 集成本地包时不拒绝未声明跨模块 import，故此处为唯一静态防线"
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
[ "$violations" -eq 0 ] || fail "分层依赖边界校验未通过"
echo "    分层边界校验通过（含各包 Tests/）"

echo "==> 4/8 配置钉死 + Debug 构建（iOS Simulator）+ 产物保真"
grep -qE "^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*cn\\.covalink\\.ios[[:space:]]*$" project.yml \
  || fail "project.yml 的 App bundle id 不是钉死值 ${REQUIRED_APP_BUNDLE_ID}（D13）"
grep -qE "^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*cn\\.covalink\\.ios\\.tests[[:space:]]*$" project.yml \
  || fail "project.yml 的测试 bundle id 不是钉死值 ${REQUIRED_TEST_BUNDLE_ID}"
grep -qE "^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET:[[:space:]]*\"?${REQUIRED_DEPLOYMENT_TARGET}\"?[[:space:]]*$" project.yml \
  || fail "project.yml 未声明 iOS ${REQUIRED_DEPLOYMENT_TARGET} 部署目标（D1）"
flat_proj="$(tr '\n' ' ' < project.yml)"
case "$flat_proj" in *"SWIFT_STRICT_CONCURRENCY: complete"*) ;; *) fail "project.yml 未开启 Swift 严格并发检查" ;; esac
EXPECT_VERSION="$(grep -E '^[[:space:]]+CFBundleShortVersionString:' project.yml | head -1 | sed -E 's/.*: *"?([^"]*)"?/\1/')"
EXPECT_BUILD="$(grep -E '^[[:space:]]+CFBundleVersion:' project.yml | head -1 | sed -E 's/.*: *"?([^"]*)"?/\1/')"
[ -n "$EXPECT_VERSION" ] && [ -n "$EXPECT_BUILD" ] || fail "无法从 project.yml 解析版本号"
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
[ "$ACT_VERSION" = "$EXPECT_VERSION" ] || fail "产物 CFBundleShortVersionString=${ACT_VERSION}，project.yml=${EXPECT_VERSION}"
[ "$ACT_BUILD" = "$EXPECT_BUILD" ] || fail "产物 CFBundleVersion=${ACT_BUILD}，project.yml=${EXPECT_BUILD}"
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
assert_tests "CovaTests" "$APP_EXEC" "CovaTests" "$MIN_TESTS_APP"
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
assert_tests "CovaCoreTests(iOS)" "$CORE_IOS_EXEC" "Packages/CovaCore/Tests" "$MIN_TESTS_CORE"

echo "==> 7/8 核心层平台中立性静态断言（覆盖率在宿主侧测量，须与 iOS 编译面一致）"
neutral_violations=0
CORE_IMPORTS="$(imported_modules Packages/CovaCore/Sources)"
for m in $IOS_ONLY_MODULES; do
  if echo "$CORE_IMPORTS" | grep -qx "$m"; then
    echo "    CovaCore 引用了 iOS-only 模块：${m} —— macOS 侧覆盖率会掩盖该代码"
    neutral_violations=1
  fi
done
if grep -rInE 'os\(iOS\)|canImport\((UIKit|SwiftUI|AVFoundation|AVKit|ARKit|CoreMotion|HealthKit|WidgetKit|Photos|PhotosUI|BackgroundTasks)\)|targetEnvironment\(' \
  Packages/CovaCore/Sources; then
  echo "    上方条件编译使 CovaCore 代码在 macOS 测量中被排除"
  neutral_violations=1
fi
[ "$neutral_violations" -eq 0 ] || fail "CovaCore 含 iOS-only 代码，宿主侧覆盖率口径无效（拒绝出报告）"
echo "    平台中立性校验通过（无 iOS-only import / 条件编译）"

echo "==> 8/8 核心层行覆盖率（SwiftPM 插桩 + llvm-cov，阈值 ${CORE_COVERAGE_MIN}%）"
echo "    说明：Xcode 不为本地 SwiftPM 包目标产出 xccov 覆盖率，故由 SwiftPM 插桩测量；"
echo "          被测源码与 iOS 运行同一份，平台中立性已由 7/8 静态强制。"
if [ -d Packages/CovaCore/.build ]; then
  find Packages/CovaCore/.build -type d -name codecov -exec rm -rf {} + >/dev/null 2>&1 || true
fi
if ! swift test --package-path Packages/CovaCore --enable-code-coverage \
  > "$LOG_DIR/test-core-coverage.log" 2>&1; then
  echo "覆盖率测试运行失败，日志尾部："
  tail -60 "$LOG_DIR/test-core-coverage.log"
  exit 1
fi
# 稳健发现产物：不硬编码二进制名/目录布局（Xcode 26 → .build/debug，Xcode 27 → .build/out/Products/Debug）
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

CORE_HOST_EXEC_NOTE="覆盖率运行自身不依赖日志文本：以「测试源码命中行数 > 0」证明测试确实执行"
echo "    ${CORE_HOST_EXEC_NOTE}"

COVERAGE="$(xcrun llvm-cov export "$CORE_BIN" -instr-profile="$CORE_PROF" --format=lcov 2>/dev/null | awk -v core="$CORE_SOURCES" -v tdir="Packages/CovaCore/Tests/" '
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
