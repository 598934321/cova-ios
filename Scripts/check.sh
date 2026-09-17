#!/usr/bin/env bash
# 本地门禁（G0–G4 全程复用，fail-closed）：
#   生成工程 → 结构/零第三方依赖/配置保真 → 分层依赖边界 → Debug 构建（iOS 模拟器）
#   → 产物 Info.plist 保真 → 应用工程测试（计数断言 + 覆盖率采集校验）
#   → 核心层包测试（iOS 模拟器，计数断言）→ 核心层行覆盖率 ≥80%
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
CORE_COVERAGE_MIN="${COVA_CORE_COVERAGE_MIN:-80}"
mkdir -p "$LOG_DIR"

PACKAGES="CovaCore CovaPlayer CovaUI CovaFeature"
CORE_SOURCES="Packages/CovaCore/Sources/"
MIN_TESTS_APP=2
MIN_TESTS_CORE=4

fail() {
  echo "❌ $1"
  exit 1
}

allowed_deps() {
  case "$1" in
    CovaCore)    echo "" ;;
    CovaPlayer)  echo "CovaCore" ;;
    CovaUI)      echo "CovaCore" ;;
    CovaFeature) echo "CovaCore CovaPlayer CovaUI" ;;
  esac
}

declared_test_count() {
  { grep -rhoE 'func[[:space:]]+test[A-Za-z0-9_]*' "$1" 2>/dev/null || true; } | wc -l | tr -d ' '
}

executed_test_count() {
  { grep -oE 'Executed [0-9]+ tests?' "$1" 2>/dev/null || true; } | grep -oE '[0-9]+' | sort -n | tail -1
}

assert_tests() {
  local label="$1" log="$2" srcdir="$3" min="$4" executed declared
  executed="$(executed_test_count "$log")"
  [ -n "$executed" ] || executed=0
  declared="$(declared_test_count "$srcdir")"
  echo "    ${label}：executed=${executed}，declared=${declared}，下限=${min}"
  [ "$executed" -ge "$min" ] || fail "${label}：执行用例数 ${executed} < 下限 ${min}（零测试/测试被清空一律失败）"
  [ "$declared" -ge "$min" ] || fail "${label}：源码内测试函数数 ${declared} < 下限 ${min}（不得删除/弱化既有测试）"
  [ "$executed" -ge "$declared" ] || fail "${label}：执行用例数 ${executed} < 声明测试函数数 ${declared}（存在未执行的测试）"
}

# 提取一个目录下所有 Swift 源码 import 的模块名（覆盖 @testable import、import enum Foo.Bar 等全部形态）
imported_modules() {
  find "$1" -name '*.swift' -exec awk '
    {
      line = $0
      sub(/\/\/.*/, "", line)
      gsub(/\/\*[^*]*\*\//, " ", line)
      gsub(/[^A-Za-z0-9_]/, " ", line)
      n = split(line, t, " ")
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

echo "==> 0/7 预热模拟器（${SIM_NAME}）"
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null

echo "==> 1/7 生成工程（XcodeGen $(xcodegen --version | awk '{print $NF}')）"
xcodegen generate --spec project.yml

echo "==> 2/7 校验工程结构与零第三方依赖"
test -f project.yml || fail "缺少 project.yml"
test -f Config/Info.plist || fail "缺少 Config/Info.plist"
test -f Cova/CovaApp.swift || fail "缺少 Cova/CovaApp.swift"
test -d design/assets/CovaAssets.xcassets/AppIcon.appiconset || fail "缺少官方 AppIcon 资产"
test -f design/assets/CovaAssets.xcassets/AppIcon.appiconset/Contents.json || fail "AppIcon 资产缺少 Contents.json"
for pkg in $PACKAGES; do
  test -f "Packages/$pkg/Package.swift" || fail "缺少本地包 Packages/$pkg/Package.swift"
  grep -q "path: Packages/$pkg" project.yml || fail "project.yml 未以本地 path 声明包 $pkg"
done
{ grep -rhoE 'func[[:space:]]+test[A-Za-z0-9_]*' CovaTests 2>/dev/null || true; } | grep -q . \
  || fail "CovaTests/ 下没有任何测试函数（测试文件缺失或已清空）"

# 零第三方依赖：跨行匹配远程依赖声明，同时扫描所有 Package.swift 与 project.yml（XcodeGen packages:）
for spec in $(find Packages -name Package.swift) project.yml; do
  if tr '\n' ' ' < "$spec" | grep -Eq '\.package[[:space:]]*\([^)]*url[[:space:]]*:'; then
    fail "$spec 声明了远程 SwiftPM 依赖（违反零第三方依赖白名单，AGENTS.md 硬边界 4）"
  fi
done
if tr '\n' ' ' < project.yml | grep -Eq '(^|[[:space:]])url[[:space:]]*:'; then
  fail "project.yml 声明了远程包（url:）——只允许本地 path 包"
fi
echo "    结构校验通过（4 个本地包，无外部依赖）"

echo "==> 3/7 校验分层依赖边界"
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
  check_imports "$pkg" "Packages/$pkg/Sources" "$allowed" || violations=1
done
check_imports "Cova(应用)" "Cova" "$PACKAGES" || violations=1
check_imports "CovaTests(测试)" "CovaTests" "$PACKAGES" || violations=1
[ "$violations" -eq 0 ] || fail "分层依赖边界校验未通过"
echo "    分层边界校验通过"

echo "==> 4/7 Debug 构建（iOS Simulator）+ 产物配置保真"
EXPECT_VERSION="$(grep -E '^[[:space:]]+CFBundleShortVersionString:' project.yml | head -1 | sed -E 's/.*: *"?([^"]*)"?/\1/')"
EXPECT_BUILD="$(grep -E '^[[:space:]]+CFBundleVersion:' project.yml | head -1 | sed -E 's/.*: *"?([^"]*)"?/\1/')"
EXPECT_BUNDLE_ID="$(grep -E '^[[:space:]]+PRODUCT_BUNDLE_IDENTIFIER:' project.yml | head -1 | sed -E 's/.*: *//' | tr -d '"')"
if ! tr '\n' ' ' < project.yml | grep -q 'IPHONEOS_DEPLOYMENT_TARGET: "26.0"'; then
  fail "project.yml 未声明 iOS 26 部署目标（D1）"
fi
tr '\n' ' ' < project.yml | grep -q 'SWIFT_STRICT_CONCURRENCY: complete' \
  || fail "project.yml 未开启 Swift 严格并发检查"
[ -n "$EXPECT_VERSION" ] && [ -n "$EXPECT_BUILD" ] || fail "无法从 project.yml 解析版本号"
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
[ "$ACT_BUNDLE_ID" = "$EXPECT_BUNDLE_ID" ] || fail "产物 bundle id=${ACT_BUNDLE_ID}，project.yml=${EXPECT_BUNDLE_ID}"
[ "$ACT_MIN_OS" = "26.0" ] || fail "产物 MinimumOSVersion=${ACT_MIN_OS}，应为 26.0（D1）"
[ "$ACT_BG_MODE" = "audio" ] || fail "产物 UIBackgroundModes[0]=${ACT_BG_MODE}，应为 audio（D4）"
echo "    产物保真：${ACT_BUNDLE_ID} ${ACT_VERSION}(${ACT_BUILD}) minOS=${ACT_MIN_OS} bg=${ACT_BG_MODE}"

echo "==> 5/7 应用工程测试（CovaTests，iOS Simulator）"
rm -rf "$RESULT_BUNDLE"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:CovaTests test > "$LOG_DIR/test-app.log" 2>&1; then
  echo "测试失败，日志尾部（完整日志 ${LOG_DIR}/test-app.log）："
  tail -80 "$LOG_DIR/test-app.log"
  exit 1
fi
grep -E "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/test-app.log" | tail -1
assert_tests "CovaTests" "$LOG_DIR/test-app.log" "CovaTests" "$MIN_TESTS_APP"
xcrun xccov view --report "$RESULT_BUNDLE" > "$LOG_DIR/xccov.txt" 2>/dev/null \
  || fail "无法读取覆盖率报告（gatherCoverageData 未生效？）"
grep -qE '^Cova' "$LOG_DIR/xccov.txt" || fail "覆盖率报告为空（未采集到任何 target）"
echo "    xccov 采集正常（$(grep -cE '^Cova' "$LOG_DIR/xccov.txt") 个 target）"

echo "==> 6/7 核心层包测试（CovaCoreTests，iOS Simulator）"
if ! (cd Packages/CovaCore && xcodebuild -scheme CovaCore -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$PACKAGE_DERIVED_DATA" \
  test > "$LOG_DIR/test-core-ios.log" 2>&1); then
  echo "核心层测试失败，日志尾部（完整日志 ${LOG_DIR}/test-core-ios.log）："
  tail -60 "$LOG_DIR/test-core-ios.log"
  exit 1
fi
grep -E "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG_DIR/test-core-ios.log" | tail -1
assert_tests "CovaCoreTests(iOS)" "$LOG_DIR/test-core-ios.log" "Packages/CovaCore/Tests" "$MIN_TESTS_CORE"

echo "==> 7/7 核心层行覆盖率（SwiftPM 插桩 + llvm-cov，阈值 ${CORE_COVERAGE_MIN}%）"
echo "    说明：Xcode 26.6 不为本地 SwiftPM 包目标产出 xccov 覆盖率（xccov 报告内无包源码），"
echo "          故覆盖率由 SwiftPM 插桩测量；被测源码与 iOS 运行完全相同。"
rm -rf Packages/CovaCore/.build/debug/codecov
if ! swift test --package-path Packages/CovaCore --enable-code-coverage \
  > "$LOG_DIR/test-core-coverage.log" 2>&1; then
  echo "覆盖率测试运行失败，日志尾部："
  tail -60 "$LOG_DIR/test-core-coverage.log"
  exit 1
fi
CORE_BIN="$(find Packages/CovaCore/.build -name 'CovaCorePackageTests' -type f -not -path '*.dSYM*' 2>/dev/null | head -1)"
CORE_PROF="$(find Packages/CovaCore/.build -name 'default.profdata' -type f 2>/dev/null | head -1)"
[ -n "$CORE_BIN" ] || fail "找不到核心层测试二进制，覆盖率无法测量"
[ -n "$CORE_PROF" ] || fail "找不到核心层 profdata，覆盖率无法测量"
COVERAGE="$(xcrun llvm-cov export "$CORE_BIN" -instr-profile="$CORE_PROF" --format=lcov 2>/dev/null | awk -v core="$CORE_SOURCES" '
  /^SF:/ { inside = (index($0, core) > 0) }
  inside && /^DA:/ { split(substr($0, 4), a, ","); total++; if ((a[2] + 0) > 0) covered++ }
  END { if (total == 0) { print "0 0" } else { printf "%d %d", covered, total } }
')"
read -r COV_COVERED COV_TOTAL <<< "${COVERAGE:-0 0}" || true
[ "${COV_TOTAL:-0}" -gt 0 ] || fail "核心层可执行行数为 0 或覆盖率不可读，不可判定为通过"
COV_PCT="$(awk -v c="$COV_COVERED" -v t="$COV_TOTAL" 'BEGIN { printf "%.2f", 100 * c / t }')"
echo "    CovaCore 行覆盖率：${COV_COVERED}/${COV_TOTAL} = ${COV_PCT}%"
awk -v p="$COV_PCT" -v m="$CORE_COVERAGE_MIN" 'BEGIN { exit !(p >= m) }' \
  || fail "核心层行覆盖率 ${COV_PCT}% < 阈值 ${CORE_COVERAGE_MIN}%"

echo "✅ check.sh 全部通过"
