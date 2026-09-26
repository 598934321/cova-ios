#!/usr/bin/env bash
# A14 补齐：tap-free 可达屏 × 深浅两档，同一批字节（HEAD = 0.2.78/96）。
# 只用 simctl + 预览键（不点击、零扣费）；口令只走 --setenv 进程环境，不落 UserDefaults。
set -u
UDID=0A371F98-3CF7-415A-A70D-F216CFC1B59E
BUNDLE=cn.covalink.ios
OUT=/tmp/a14
EMAIL=REPLACE_ME_TEST_EMAIL
PASS=REPLACE_ME_TEST_PASSWORD
rm -rf "$OUT"; mkdir -p "$OUT"

# 屏号=键串（TAB/SHEET/ROUTE/DRAWER 的组合）
screens=(
  "01-home|COVA_PREVIEW_TAB=home"
  "02-player|COVA_PREVIEW_SHEET=player"
  "03-library|COVA_PREVIEW_TAB=library"
  "04-drawer|COVA_PREVIEW_TAB=home COVA_PREVIEW_DRAWER=1"
  "05-plaza|COVA_PREVIEW_ROUTE=plaza"
  "08-aiSessions|COVA_PREVIEW_ROUTE=aiSessions"
  "11-mine|COVA_PREVIEW_TAB=mine"
  "12a-favorites|COVA_PREVIEW_ROUTE=favorites"
  "12b-myPlaylists|COVA_PREVIEW_ROUTE=myPlaylists"
  "13-membership|COVA_PREVIEW_ROUTE=membership"
  "14-enterprise|COVA_PREVIEW_ROUTE=enterprise"
  "15-settings|COVA_PREVIEW_ROUTE=settings"
)
guest=(
  "10-login|COVA_PREVIEW_SHEET=login"
)

shoot() { # $1=name $2=env-assignments $3=theme $4=login(1/0)
  local name="$1" envs="$2" theme="$3" logged="$4"
  xcrun simctl ui "$UDID" appearance "$theme" >/dev/null 2>&1
  args=()
  for kv in $envs; do args+=(--setenv "$kv"); done
  if [ "$logged" = "1" ]; then
    args+=(--setenv COVA_PREVIEW_LOGIN_EMAIL="$EMAIL" --setenv COVA_PREVIEW_LOGIN_PASSWORD="$PASS")
  fi
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
  sleep 1
  xcrun simctl launch --terminate-running-process "${args[@]}" "$UDID" "$BUNDLE" >/dev/null 2>&1
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
python3 -c "import PIL; print('PIL_OK')" 2>/dev/null || echo "NO_PIL"
