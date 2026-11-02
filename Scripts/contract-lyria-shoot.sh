#!/usr/bin/env bash
# COVA-20261024-003 R1 真实渲染截图（2026-10-30）。
# 沿用 A14/A15 口径：只用 simctl + 预览键（不点击、零扣费、不发写请求）。
#
# 拍的是什么：19 屏创作台的「生成引擎」卡片（R1 的三态）。
#   · A1 = 有模型清单（服务端 enabled=true 且 models 非空）⇒ chips 保序渲染
#   · A2 = enabled=false ⇒ 整张卡片不存在（不渲染空卡）
#   · A3 = 拉取失败或有缓存 ⇒ 「可能过期」标记 / 空+重试
#
# ⚠️ 客观限制（不掩饰）：A2/A3 需要服务端 `enabled=false` 或断网才可达，
# 而 simctl 无法注入网络故障、服务端开关也不由客户端控制。
# 所以本脚本能拍的是 **A1 的真实现网形态**（浅/深两档）；
# A2/A3 用 `COVA_PREVIEW_ROUTE` 到达同一屏后靠真实服务端状态决定，拍不到就如实记未覆盖。
set -u
UDID=0A371F98-3CF7-415A-A70D-F216CFC1B59E
BUNDLE=cn.covalink.ios
OUT="${1:-/tmp/lyria-shots}"
rm -rf "$OUT"; mkdir -p "$OUT"

shoot() { # $1=name $2=env-assignments $3=theme
  local name="$1" envs="$2" theme="$3"
  xcrun simctl ui "$UDID" appearance "$theme" >/dev/null 2>&1
  local envs2=()
  for kv in $envs; do envs2+=("SIMCTL_CHILD_$kv"); done
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
  sleep 1
  env "${envs2[@]}" xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" >/dev/null 2>&1
  sleep 10
  xcrun simctl io "$UDID" screenshot "$OUT/$name-$theme.png" >/dev/null 2>&1
  local sz
  sz=$(stat -f%z "$OUT/$name-$theme.png" 2>/dev/null || echo 0)
  echo "$sz $name-$theme"
}

xcrun simctl boot "$UDID" >/dev/null 2>&1
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1

for theme in light dark; do
  shoot "A1-engine-list" "COVA_PREVIEW_ROUTE=studioCreate" "$theme"
done

xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
echo "== files =="; ls -la "$OUT" 2>/dev/null | tail -5
