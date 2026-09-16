#!/usr/bin/env bash
# 本地门禁（G0–G4 全程复用）：XcodeGen 重新生成工程 → 结构与分层校验 → Debug 构建 → 全量 XCTest。
# 目标为 iOS 模拟器（CovaUI 将使用 iOS-only API，不用 macOS destination）。
# 任一步失败即以非零退出（fail-fast）；日志落在 .build/check/ 下（.build/ 不入 git）。
# 用法：./Scripts/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="Cova"
PROJECT="Cova.xcodeproj"
SIM_NAME="${COVA_SIM_NAME:-iPhone 17 Pro}"
DESTINATION="platform=iOS Simulator,name=$SIM_NAME"
LOG_DIR="$ROOT/.build/check"
BUILD_LOG="$LOG_DIR/build.log"
TEST_LOG="$LOG_DIR/test.log"
mkdir -p "$LOG_DIR"

PACKAGES="CovaCore CovaPlayer CovaUI CovaFeature"

allowed_deps() {
  case "$1" in
    CovaCore)    echo "" ;;
    CovaPlayer)  echo "CovaCore" ;;
    CovaUI)      echo "CovaCore" ;;
    CovaFeature) echo "CovaCore CovaPlayer CovaUI" ;;
  esac
}

echo "==> 0/5 预热模拟器（${SIM_NAME}）"
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null

echo "==> 1/5 生成工程（XcodeGen $(xcodegen --version | awk '{print $NF}')）"
xcodegen generate --spec project.yml

echo "==> 2/5 校验工程结构与零第三方依赖"
test -f project.yml
test -f Config/Info.plist
test -f Cova/CovaApp.swift
test -d design/assets/CovaAssets.xcassets/AppIcon.appiconset
test -f design/assets/CovaAssets.xcassets/AppIcon.appiconset/Contents.json
for pkg in $PACKAGES; do
  test -f "Packages/$pkg/Package.swift" || { echo "缺少本地包 Packages/$pkg/Package.swift"; exit 1; }
done
if grep -R -n -E '\.package\(\s*url:' Packages --include=Package.swift; then
  echo "发现外部 SwiftPM 依赖，违反零第三方依赖白名单（AGENTS.md 硬边界 4）"
  exit 1
fi
echo "    结构校验通过（4 个本地包，无外部依赖）"

echo "==> 3/5 校验分层依赖边界"
# 说明：Xcode 集成本地 SwiftPM 包时不会拒绝未声明的跨模块 import（实测 BUILD SUCCEEDED），
# 因此这里对声明与源码两侧做静态门禁；SPM 自身（swift build --package-path）会拒绝。
violations=0
for pkg in $PACKAGES; do
  allowed="$(allowed_deps "$pkg")"
  declared="$( { grep -oE '\.package\(path: "\.\./[A-Za-z]+"' "Packages/$pkg/Package.swift" || true; } | sed -E 's#.*\.\./##; s#".*##')"
  imported="$( { grep -rhoE '^import [A-Za-z_][A-Za-z0-9_]*' "Packages/$pkg/Sources" || true; } | awk '{print $2}' | sort -u)"
  for sibling in $PACKAGES; do
    [ "$sibling" = "$pkg" ] && continue
    if echo "$declared" | grep -qx "$sibling"; then
      case " $allowed " in
        *" $sibling "*) ;;
        *) echo "    依赖方向违规：$pkg 声明了不允许的依赖 $sibling"; violations=1 ;;
      esac
    fi
    if echo "$imported" | grep -qx "$sibling"; then
      case " $allowed " in
        *" $sibling "*) ;;
        *) echo "    依赖方向违规：$pkg 源码 import 了不允许的模块 $sibling"; violations=1 ;;
      esac
    fi
  done
done
[ "$violations" -eq 0 ] || exit 1
echo "    分层边界校验通过"

echo "==> 4/5 Debug 构建（iOS Simulator）"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DESTINATION" build > "$BUILD_LOG" 2>&1; then
  echo "构建失败，日志尾部（完整日志 ${BUILD_LOG}）："
  tail -60 "$BUILD_LOG"
  exit 1
fi
grep -E "^\*\* BUILD (SUCCEEDED|FAILED) \*\*" "$BUILD_LOG" | tail -1

echo "==> 5/5 全量单元测试（CovaTests，iOS Simulator）"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DESTINATION" -only-testing:CovaTests test > "$TEST_LOG" 2>&1; then
  echo "测试失败，日志尾部（完整日志 ${TEST_LOG}）："
  tail -80 "$TEST_LOG"
  exit 1
fi
grep -E "Test Suite 'CovaTests'|Executed [0-9]+ test" "$TEST_LOG" | tail -3
grep -E "^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$TEST_LOG" | tail -1

echo "✅ check.sh 全部通过"
