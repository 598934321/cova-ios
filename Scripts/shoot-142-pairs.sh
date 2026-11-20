#!/usr/bin/env bash
# COVA-142 · iOS 成对截图（改前 / 改后，同一入口、同一视口、同一账号状态）
#
# 用法：bash Scripts/shoot-142-pairs.sh <tag>      tag = before | after
# 输出：/tmp/cova142-shots/<tag>-<形态>.png
#
# 形态按「渲染方式」取，不逐界面拍（面面 11-20 派单口径）：
#   list      列表卡      → 曲库（CovaListRow，7 处列表界面的共同承载点）
#   grid      网格/卡带   → 首页（封面角标，3 张自绘卡同形态）
#   playlist  歌单详情    → 歌单详情（曲目行 + 头部）
#   player    播放器      → 全屏播放器（L2 整句）
#   detail    详情 sheet  → 曲目详情（L2 整句）
#
# 只用 simctl + COVA_PREVIEW_* 预览键，不点击、零扣费；口令不走。
set -u
UDID=0A371F98-3CF7-415A-A70D-F216CFC1B59E
BUNDLE=cn.covalink.ios
OUT=/tmp/cova142-shots
TAG="${1:?用法: shoot-142-pairs.sh <before|after>}"
mkdir -p "$OUT"

# 真实生产数据 id（2026-11-20 从 /api/tracks 与 /api/playlists 取，非编造）：
#   曲目：library-b6e21e004d106540d0e116e1（贝壳晒太阳 / 77.88s）
#   歌单：PL-20261016-09（安心感爆棚，10 首）
TRACK=library-b6e21e004d106540d0e116e1
PLAYLIST=PL-20261016-09
# 同一个「游客」状态：不带 COVA_PREVIEW_LOGIN_* ⇒ 未登录，两次都一致。

shoot() { # $1=形态 $2=env 赋值串 $3=等待秒数
  local name="$1" envs="$2" wait_s="${3:-10}"
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
  sleep 1
  local env2=()
  for kv in $envs; do env2+=("SIMCTL_CHILD_$kv"); done
  env "${env2[@]}" xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" >/dev/null 2>&1
  sleep "$wait_s"
  xcrun simctl io "$UDID" screenshot "$OUT/$TAG-$name.png" >/dev/null 2>&1
  printf '  %-10s %8s bytes  %s\n' "$name" "$(stat -f%z "$OUT/$TAG-$name.png" 2>/dev/null)" "$OUT/$TAG-$name.png"
}

echo "== 拍 $TAG =="
shoot list     "COVA_PREVIEW_ROUTE=library"                     9
shoot grid     "COVA_PREVIEW_TAB=home"                         10
shoot playlist "COVA_PREVIEW_ROUTE=playlist:$PLAYLIST"         16
shoot player   "COVA_PREVIEW_PLAY=$TRACK"                      14
shoot detail   "COVA_PREVIEW_ROUTE=track:$TRACK"               10

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
echo "== 完成：$(ls "$OUT"/$TAG-*.png 2>/dev/null | wc -l | tr -d ' ') 张 =="
