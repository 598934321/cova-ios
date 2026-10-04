#!/usr/bin/env bash
# 2026-10-02 Apple Music 参照改版轮截图：0.3.1(102) × 深浅两档。
# 沿用 A14 口径：只用 simctl + 预览键（不点击、零扣费）。
# 不传 COVA_PREVIEW_LOGIN_* —— 保持模拟器里已登录态（占位口令会顶成游客）。
set -u
UDID=0A371F98-3CF7-415A-A70D-F216CFC1B59E
BUNDLE=cn.covalink.ios
OUT=/tmp/a15
rm -rf "$OUT"; mkdir -p "$OUT"

screens=(
  "01-home|COVA_PREVIEW_TAB=home"
  "03-library|COVA_PREVIEW_TAB=library"
  "03b-library-preset|COVA_PREVIEW_ROUTE=library COVA_PREVIEW_FILTER=scene:短视频/Vlog"
  "05-plaza|COVA_PREVIEW_ROUTE=plaza"
  "05b-plaza-search|COVA_PREVIEW_ROUTE=plazaSearch:轻音乐"
  "08-aiSessions|COVA_PREVIEW_TAB=studio"
  "11-mine|COVA_PREVIEW_TAB=mine"
  "25-search|COVA_PREVIEW_TAB=search"
  "12a-favorites|COVA_PREVIEW_ROUTE=favorites"
  "15-settings|COVA_PREVIEW_ROUTE=settings"
  "13-membership|COVA_PREVIEW_ROUTE=membership"
)
guest=(
  "10-login|COVA_PREVIEW_SHEET=login"
)

shoot() { # $1=name $2=env-assignments $3=theme $4=login(1/0)
  local name="$1" envs="$2" theme="$3"
  xcrun simctl ui "$UDID" appearance "$theme" >/dev/null 2>&1
  local envs2=()
  for kv in $envs; do envs2+=("SIMCTL_CHILD_$kv"); done
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
  sleep 1
  env "${envs2[@]}" xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" >/dev/null 2>&1
  sleep 11
  xcrun simctl io "$UDID" screenshot "$OUT/$name-$theme.png" >/dev/null 2>&1
  echo "$(ls -la "$OUT/$name-$theme.png" 2>/dev/null | awk '{print $5}') $name-$theme"
}

for theme in light dark; do
  for s in "${screens[@]}"; do shoot "${s%%|*}" "${s##*|}" "$theme" 1; done
  for s in "${guest[@]}"; do shoot "${s%%|*}" "${s##*|}" "$theme" 0; done
done
xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
echo "== files =="; ls "$OUT" | wc -l
