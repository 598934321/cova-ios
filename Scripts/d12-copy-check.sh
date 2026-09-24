#!/usr/bin/env bash
# D12 合规文案门禁（v1.0 不含任何购买/充值入口，仅展示余额）
#
# 为什么要有这个脚本：design 13 §8 / 14 / 17 把「禁止出现的字样」写成了一张表，并规定
# **命中数必须为 0**（13 的脚注缺失按 Critical 计）。这种规则靠人自觉必然漂移，
# 所以和「播放器层禁 UI」一样机制化：命中即红，且自带一条**负例自检**
# （证明它真的能抓到，而不是一条永远绿的空规则）。
#
# 口径：只看**字符串字面量**（文案、VoiceOver 标签、alt 都来自字面量），
# 注释里的禁令清单是「说明规则」，不是「说给用户的话」⇒ 先剥掉整行注释。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

TARGETS=(Packages/CovaFeature/Sources Packages/CovaUI/Sources)
BANNED=(购买 充值 支付 立即开通 升级 订阅管理 付款 价格 元/月 限时 优惠 恢复购买 报价 下单 立即签约 免费试用申请)
# 13 §F：逐字脚注，缺失 = Critical
REQUIRED_FILE=Packages/CovaFeature/Sources/CovaFeature/MembershipAndEnterprise.swift
REQUIRED=("套餐说明以官网为准，App 内不售卖。" "下载与扣费入口目前未在 App 内开放，请在官网了解与使用。")

fail=0
hits=0
while IFS= read -r file; do
  # 剥掉整行注释与 doc 注释，只留代码行；再只取引号内的字面量片段
  literals="$(sed -E 's,^[[:space:]]*(//|///).*$,,' "$file" | grep -o '"[^"]*"' || true)"
  [ -z "$literals" ] && continue
  for word in "${BANNED[@]}"; do
    count="$(printf '%s\n' "$literals" | grep -c -- "$word" || true)"
    if [ "$count" -gt 0 ]; then
      printf '❌ D12 禁词命中：%s 出现在 %s（%s 次）\n' "$word" "${file#./}" "$count"
      printf '   %s\n' "$(printf '%s\n' "$literals" | grep -- "$word" | head -3)"
      hits=$((hits + count)); fail=1
    fi
  done
done < <(find "${TARGETS[@]}" -name '*.swift' -type f | sort)

# 逐字脚注必须存在（缺一条即 Critical）
for text in "${REQUIRED[@]}"; do
  if ! grep -qF -- "$text" "$REQUIRED_FILE"; then
    printf '❌ D12 合规脚注缺失（design 13 §F，缺失按 Critical）：%s\n' "$text"
    fail=1
  fi
done

# 「¥」单独查：它是符号而不是词，且必须出现在**非注释**代码里才算违规
if grep -rnE '"[^"]*¥[^"]*"' "${TARGETS[@]}" --include='*.swift' >/dev/null 2>&1; then
  printf '❌ D12：文案字面量里出现货币符号 ¥\n'
  grep -rnE '"[^"]*¥[^"]*"' "${TARGETS[@]}" --include='*.swift' | head -3
  fail=1
fi

# ---- 负例自检：证明这张表真的抓得住，而不是一条永绿的空规则 ----
probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT
printf 'struct Probe {\n  let a = "立即开通享优惠"\n}\n' > "$probe_dir/Probe.swift"
probe_hits=0
probe_literals="$(sed -E 's,^[[:space:]]*(//|///).*$,,' "$probe_dir/Probe.swift" | grep -o '"[^"]*"')"
for word in "${BANNED[@]}"; do
  n="$(printf '%s\n' "$probe_literals" | grep -c -- "$word" || true)"
  probe_hits=$((probe_hits + n))
done
if [ "$probe_hits" -eq 0 ]; then
  printf '❌ D12 自检失败：植入的禁词没有被抓到 ⇒ 本脚本判据已失效，按红处理\n'
  exit 1
fi
printf 'D12 自检：植入禁词抓到 %s 处 ⇒ 判据有效\n' "$probe_hits"

if [ "$fail" -ne 0 ]; then
  printf 'D12 文案门禁未通过（命中 %s 处）\n' "$hits"
  exit 1
fi
printf '✅ D12 文案门禁通过：禁词命中 0，逐字脚注在册\n'
