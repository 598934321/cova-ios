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

# 扫描面**从工程声明推导**，不写死目录名。
# 为什么（第 16 轮 R16-3）：原先这里写死 `Packages/CovaFeature/Sources Packages/CovaUI/Sources` 两项，
# ⇒ app target 的 `Cova/` 完全不在面内。评审把禁词种进 `Cova/CovaApp.swift` 跑门禁，**EXIT=0**，
# 而它自带的负例自检照印"抓到 2 处"——自检证明的是**扫描器能用**，不是**扫描面完整**。
# 一条有洞的合规判据比没有判据更糟：它会让人以为已经管住了。
collect_roots() {
  # ① 本地 SwiftPM 包的源码目录（以后新增包自动进面，不需要改这个脚本）
  for d in Packages/*/Sources; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
  # ② 工程目标里声明的源码目录 —— app target 的 `Cova/` 就靠这一步进面
  awk '/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {print $NF}' project.yml | while read -r p; do
    case "$p" in
      *.xcassets) continue ;;                 # 资源目录没有 Swift 字面量
      *Tests|*Tests/*) continue ;;            # 见下方"排除口径"
    esac
    [ -d "$p" ] || continue
    find "$p" -name '*.swift' -type f 2>/dev/null | grep -q . && printf '%s\n' "$p"
  done
}
# 排除口径（诚实写下它的边界）：路径里带 `Tests` 的目录不扫，因为测试夹具会**故意**出现禁词
# （断言"这句不许上屏"的用例必须能写出那句话）。这条排除是**人工判断**，下面的自检证明不了它
# 是对的 —— 它只证明扫描面里的东西会被扫到。新增的非测试源码目录会被 ①/② 自动纳面。
TARGETS=()
while IFS= read -r root; do
  [ -n "$root" ] && TARGETS+=("$root")
done < <(collect_roots | sort -u)

if [ "${#TARGETS[@]}" -eq 0 ]; then
  printf '❌ D12：扫描面为空 ⇒ 这条判据等于没有，按红处理\n'
  exit 1
fi
# 每个根目录必须真的能扫到东西：写错一个路径就静默少扫一片，是这个脚本最容易的自我欺骗。
for root in "${TARGETS[@]}"; do
  n="$(find "$root" -name '*.swift' -type f | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then
    printf '❌ D12：扫描面里的 %s 没有任何 .swift ⇒ 根路径失效，按红处理\n' "$root"
    exit 1
  fi
  printf 'D12 扫描面：%s（%s 个 .swift）\n' "$root" "$n"
done
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
# 两半：**扫描器**能抓（临时目录里植入禁词）+ **扫描面**里确有可扫内容（每个根都要出现
# 至少一条字符串字面量）。后者抓的是"根路径写对了但那片其实没进 grep"这类自我欺骗。
# 不在真实根目录里植入临时 .swift：编译中的实例会把多出来的文件当源码读（并行工作的教训）。
for root in "${TARGETS[@]}"; do
  literal_total=0
  while IFS= read -r file; do
    c="$(sed -E 's,^[[:space:]]*(//|///).*$,,' "$file" | grep -o '"[^"]*"' | wc -l | tr -d ' ' || true)"
    literal_total=$((literal_total + c))
  done < <(find "$root" -name '*.swift' -type f | sort)
  if [ "$literal_total" -eq 0 ]; then
    printf '❌ D12 自检失败：%s 里一条字符串字面量都取不到 ⇒ 这片面等于没扫，按红处理\n' "$root"
    exit 1
  fi
done
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
