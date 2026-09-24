#!/usr/bin/env bash
# D12 合规文案门禁（v1.0 不含任何购买/充值入口，仅展示余额）
#
# 为什么要有这个脚本：design 13 §8 / 14 / 17 把「禁止出现的字样」写成了一张表，并规定
# **命中数必须为 0**（13 的脚注缺失按 Critical 计）。这种规则靠人自觉必然漂移，
# 所以和「播放器层无 UI」一样机制化：命中即红，且自带**负例自检**。
#
# ===========================================================================
# 本判据的口径（第 17 轮 R17-1 之后重写。它只声明自己真做到的事。）
#
# (1) 扫描面来自 project.yml 的**结构解析**，不是 `awk '/- path:/ {print $NF}'`。
#     R17-1 实测：原先那一行在 XcodeGen **合法**的两种写法下都会失效 ——
#       `- Cova`（裸标量条目）      ⇒ app target 整个从面里消失；
#       `- path: Cova  # 注释`      ⇒ 取到的「路径」是注释里的词。
#     两种都 EXIT=0，禁词照样编进 App。现在认得的写法（裸标量 / `path:` /
#     带 `buildPhase:` / 带行尾注释 / 序列项与 `sources:` 同级 / 键序反转 /
#     `excludes:` 子列表 / 带引号的值）全部正确纳面；
#     **认不出的写法一律 BAD ⇒ 红**（flow `{}`/`[]`、值写在下一行、制表符缩进、
#     内联 `sources:`、合并键 `<<:`、`templates:` 注入、层级无法确定…）。
#     「静默少一片面」正是本判据的死因，所以默认值反转：不确定 = 红。
# (2) 反向防绕过（**失败关闭**）：仓里每一个 .swift 必须落在「已纳面 ∪ 具名排除」
#     之内，否则红并列出文件名 ⇒ 即使解析器漏了一整个根，漏掉的文件自己染红。
#     同样红：声明了却不存在的源路径、空的面、面里的目录级符号链接。
# (3) 语法覆盖面：**注释一律剥掉**（整行 / 行尾 / 可嵌套块注释），只统计字符串字面量
#     ⇒ 本文件这份禁词清单不会自触发。已实现的字面量形态：
#       · 普通单行 `"…"`（含 `\"` 转义、含 `\(…)` 插值里嵌套的字符串与注释）
#       · **多行字面量 `"""…"""`**（R17-1(b) 的缺口）
#       · 原始字面量 `#"…"#` / `##"…"##`（任意 # 数）
#     **未覆盖 —— 别把它当成覆盖了**：
#       · `"\u{8d2d}\u{4e70}"` 这类码点转义：不解码。改为**见到 `\u{` 就红**
#         （正常文案不需要它），交给人确认。plist 侧同理：`&#…;` 数字实体直接红。
#       · 运行时拼出来的文案（变量拼接、后端下发字符串、String(format:) 的参数）
#         —— 任何静态判据都看不到。
#       · 原始字面量里的插值 `\#(…)`：按普通文本处理，不递归。
#       · 未闭合的字面量/注释：按「跨行继续」处理（宁可多吞，不误放行）并额外红一次。
# (4) 非 Swift 载体：project.yml 声明的 Info.plist（`INFOPLIST_FILE` / `info: path:`）
#     与扫描面里出现的 `.plist`，解析其 XML `<string>` 值（跨行的 `<string>`、
#     非 XML 形态、CDATA ⇒ 红）；`project.yml` 里 `INFOPLIST_KEY_*` 标量（会写进
#     生成的 Info.plist）也在判据内。其余**能承载用户文案而本脚本不解析**的形态
#     （`.strings` `.stringsdict` `.xcstrings` `.storyboard` `.xib` `.nib` `.json`
#     `.js` `.html` `.txt` `.md` `.csv` `.xml` `.rtf` `.lproj`，以及任何未知扩展名）
#     ⇒ **一律红并打印文件名**：宁可得罪人，不可静默放过。
#     asset catalog 内的本地化字符串文件由该规则覆盖；catalog 的 `Contents.json`
#     只有元数据 ⇒ 唯一登记的豁免。
#     **已知不判**：图片/音视频里烤进来的文字（不可判）。
# (5) 自检（诱饵文本在 Scripts/d12-gate-selftest-copy.txt）沿**真实违规会走的同一条
#     路**植入：app target 源文件、包源码、多行字面量、Info.plist 的显示名、未被解析
#     的载体、以及 project.yml 的三种写法（裸标量 / 行尾注释 / flow）。每段诱饵带唯一
#     记号，断言「红的那条正是这次种下的那条」；植入后用**反向社会操作**复原并逐字节
#     比对 md5，复原后再跑一次判据必须回到基线。不用 `git checkout --`/`git restore`
#     （本仓有它毁掉工作的前科）。检测到植入期间被并发改动 ⇒ 备份复原 + 整轮判红。
#     兜底：任何没销账的植入点都由 EXIT/INT/TERM 陷阱按备份复原 / 删探针（Ctrl-C 也不留
#     诱饵）。被 SIGKILL 打断时没有兜底 ⇒ 复核 `git status --porcelain`。
#
# 排除口径（诚实写下边界）：路径含 `Tests`/`tests`/`Fixtures` 组件、末级目录名以
# `Tests`/`Test` 结尾、以及 SwiftPM 清单 `Package.swift` 不扫 —— 测试夹具会**故意**
# 写出那句「不许上屏」的话。这条排除是人工判断，自检证明不了它对，只证明面内会被扫到。
#
# 跑法：`bash Scripts/d12-copy-check.sh`（本机 bash 3.2 + BSD 工具链，不用 GNU 扩展）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
TAB="$(printf '\t')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/d12copy.XXXXXX")"
REP="$WORK/report.txt"
PEND="$WORK/pending"
mkdir -p "$WORK/bak" "$PEND"
SELFTEST_COPY="Scripts/d12-gate-selftest-copy.txt"

BANNED="购买 充值 支付 立即开通 升级 订阅管理 付款 价格 元/月 限时 优惠 恢复购买 报价 下单 立即签约 免费试用申请 ¥"
# 13 §F：逐字脚注，缺失 = Critical
REQUIRED_FILE="Packages/CovaFeature/Sources/CovaFeature/MembershipAndEnterprise.swift"
REQUIRED="套餐说明以官网为准，App 内不售卖。
下载与扣费入口目前未在 App 内开放，请在官网了解与使用。"

# ---------------------------------------------------------------- awk 程序 --
cat > "$WORK/yml.awk" <<'AWK_YML'
# project.yml 结构解析（只为 D12 的扫描面服务，不是通用 YAML 解析器）。
# 输出 TSV：
#   SRC<TAB>行号<TAB>target<TAB>path<TAB>buildPhase   目标声明的源码/资源路径
#   PKG<TAB>行号<TAB>path                            本地 SwiftPM 包目录
#   PLIST<TAB>行号<TAB>target<TAB>path               会进 App 包的 Info.plist
#   KEY<TAB>行号<TAB>key<TAB>value                   INFOPLIST_KEY_* 标量（进生成的 Info.plist）
#   BAD<TAB>行号<TAB>原文<TAB>原因                    认不出的写法 ⇒ 调用方必须按红处理
function lead(s,   t, c) {            # 前导空格数；-1 = 缩进里出现制表符
  for (t = 1; t <= length(s); t++) {
    c = substr(s, t, 1)
    if (c == " ") continue
    if (c == "\t") return -1
    return t - 1
  }
  return 0
}
function scalar(s,   t) {             # 去首尾空白与成对引号
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  if (length(s) >= 2 && ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") || (substr(s, 1, 1) == "'" && substr(s, length(s), 1) == "'")))
    s = substr(s, 2, length(s) - 2)
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  return s
}
function strip_comment(s,   t, c, inq, q) {   # 去行尾 # 注释；引号内的 # 不算注释
  inq = 0; q = ""
  for (t = 1; t <= length(s); t++) {
    c = substr(s, t, 1)
    if (inq) { if (c == q) inq = 0; continue }
    if (c == "\"" || c == "'") { inq = 1; q = c; continue }
    if (c == "#" && substr(s, t - 1, 1) ~ /[ \t]/) return substr(s, 1, t - 1)
  }
  return s
}
function key_of(s,   p) { p = index(s, ":"); if (p == 0) return ""; return scalar(substr(s, 1, p - 1)) }
function val_of(s,   p) { p = index(s, ":"); if (p == 0) return ""; return scalar(substr(s, p + 1)) }
function bad(no, why) { printf "BAD\t%s\t%s\t%s\n", no, raw, why }
function setpath(v, no) {
  if (v == "") { bad(no, "path: 的值不在同一行（跨行标量本脚本不解析）"); return }
  sub(/^\.\//, "", v); sub(/\/$/, "", v)
  item_path = v; item_haspath = 1
}
function flush_item(   ) {
  if (item_ind < 0) return
  if (!item_haspath) bad(item_line, "sources 条目里没有可识别的 path")
  else printf "SRC\t%s\t%s\t%s\t%s\n", item_line, tname, item_path, item_phase
  item_ind = -1; item_haspath = 0; item_path = ""; item_phase = ""; item_line = 0
}
function start_item(no, content,   body, c, k) {
  flush_item()
  item_ind = ind; item_line = no
  body = strip_comment(content)
  sub(/^-[ \t]*/, "", body)
  gsub(/^[ \t]+/, "", body)
  if (body == "") { item_ind = -1; bad(no, "sources 条目为空（值写在下一行的形态本脚本不解析）"); return }
  c = substr(body, 1, 1)
  if (c == "{" || c == "[") { item_ind = -1; bad(no, "sources 条目是 flow（单行 {} / []）写法，本脚本不解析"); return }
  k = key_of(body)
  if (k == "") { setpath(scalar(body), no); return }        # 裸标量：- Cova
  if (k == "path") { setpath(val_of(body), no); return }
  item_haspath = 0                                          # 键序反转：- buildPhase: … / path: …
  if (k == "buildPhase") item_phase = val_of(body)
}
BEGIN {
  sec = ""; tname = ""; ind_t = -1; prop_ind = -1
  in_src = 0; src_ind = -1; in_info = 0; in_nest = 0; nest_ind = -1
  item_ind = -1; item_haspath = 0; item_path = ""; item_phase = ""; item_line = 0
}
{
  raw = $0; line = $0
  sub(/\r$/, "", line)
  no = FNR
  if (line ~ /^[ \t]*$/) next
  if (line ~ /^[ \t]*#/) next
  if (line ~ /^---/) next
  ind = lead(line)
  if (ind < 0) { bad(no, "缩进里出现制表符（不是合法 YAML），本脚本不猜它属于谁"); next }
  content = substr(line, ind + 1)

  if (ind == 0) {                                  # 顶层键：切 section，状态归零
    flush_item()
    in_src = 0; in_info = 0; in_nest = 0; ind_t = -1; prop_ind = -1
    if (content ~ /^-([ \t]|$)/) { bad(no, "顶层序列不在本脚本的理解范围内"); next }
    sec = key_of(strip_comment(content))
    if (sec == "") bad(no, "顶层结构既不是 key: 也不是本脚本登记的 section")
    next
  }

  # 任意位置的 Info.plist 相关键（顶层 settings / targets 之内都要收）
  if (content ~ /(^|[ \t])INFOPLIST_FILE[ \t]*:/) {
    v = val_of(strip_comment(content)); if (v != "") printf "PLIST\t%s\t%s\t%s\n", no, tname, v
  }
  if (content ~ /(^|[ \t])INFOPLIST_KEY_[A-Za-z0-9_]*[ \t]*:/)
    printf "KEY\t%s\t%s\t%s\n", no, key_of(strip_comment(content)), val_of(strip_comment(content))

  if (sec == "packages") {
    if (content ~ /^[ \t]*path[ \t]*:/) { v = val_of(strip_comment(content)); if (v != "") printf "PKG\t%s\t%s\n", no, v }
    next
  }
  if (sec != "targets") next

  if (ind_t < 0) ind_t = ind                       # targets 下第一层 = 目标名
  if (ind == ind_t) {
    flush_item(); in_src = 0; in_info = 0; in_nest = 0; prop_ind = -1
    c = strip_comment(content)
    if (c ~ /^[^:]+:[ \t]*$/) { tname = scalar(substr(c, 1, index(c, ":") - 1)) }
    else if (c ~ /^[^:]+:[ \t]/) { tname = ""; bad(no, "目标写成内联一行（flow mapping），本脚本不解析") }
    else { tname = ""; bad(no, "targets 下这一行既不是「名字:」也不是可忽略的行") }
    next
  }
  if (ind < ind_t) { bad(no, "targets 下缩进比目标名还浅，层级关系无法确定"); next }

  k = key_of(strip_comment(content))
  if (k == "<<") { bad(no, "合并键 <<: 会注入本脚本看不到的 sources"); next }
  if (k == "templates") { bad(no, "templates: 注入的 sources 本脚本不解析"); next }
  if (k == "sources" && prop_ind >= 0 && ind != prop_ind && !(in_src && ind >= src_ind)) {
    bad(no, "sources 出现在无法确定的层级"); next
  }

  if (in_src && item_ind >= 0 && ind > item_ind && !in_nest) {   # 条目续行
    c = strip_comment(content); nk = key_of(c)
    if ((nk == "excludes" || nk == "includes") && val_of(c) == "") { in_nest = 1; nest_ind = ind }
    else if (nk == "path") setpath(val_of(c), no)
    else if (nk == "buildPhase") { v = val_of(c); if (v != "") item_phase = v }
    next
  }
  if (in_nest) { if (ind > nest_ind) next; in_nest = 0 }
  if (in_src && (content ~ /^-([ \t]|$)/)) {                      # 下一个条目
    if (item_ind >= 0 && ind != item_ind) bad(no, "同一 sources 下条目缩进不一致，无法确定归属")
    start_item(no, content); next
  }
  if (in_src && ind > src_ind) { bad(no, "sources 块里出现非序列项的行"); next }

  if (prop_ind < 0 || ind == prop_ind) {                          # 目标属性层
    prop_ind = ind
    flush_item(); in_src = 0; in_nest = 0
    c = strip_comment(content); v = val_of(c)
    if (k == "sources") {
      if (v != "") bad(no, "sources 写成内联一行（标量或数组），本脚本不解析")
      else { in_src = 1; src_ind = ind; item_ind = -1 }
    } else if (k == "info") {
      if (v != "") printf "PLIST\t%s\t%s\t%s\n", no, tname, v
      else in_info = 1
    } else in_info = 0
    next
  }
  if (in_info && ind > prop_ind) {
    c = strip_comment(content)
    if (key_of(c) == "path") { v = val_of(c); if (v != "") printf "PLIST\t%s\t%s\t%s\n", no, tname, v }
    next
  }
  next
}
END { flush_item() }
AWK_YML

cat > "$WORK/swift.awk" <<'AWK_SWIFT'
# Swift 字符串字面量抽取：注释（整行 / 行尾 / 可嵌套块注释）一律剥掉，只有字面量出记录。
# 输出 TSV：
#   LIT<TAB>file<TAB>起行<TAB>字面量内容（跨行折叠为空格，制表符换空格）
#   ESC<TAB>file<TAB>起行<TAB>内容      字面量里有 \u{…} 码点转义（本脚本不解码 ⇒ 上报）
#   UNCLOSED<TAB>file<TAB>行<TAB>说明   扫描结束时仍有未闭合帧
# 状态机按字节推进：UTF-8 续字节 >= 0x80，永不与 ASCII 的引号/反斜杠/# 撞车。
# 覆盖：单行、多行 """、原始 #"…"#（任意 # 数）、转义引号、\(…) 插值里嵌套的字符串与注释。
# 不覆盖（诚实边界）：\u{…} 解码、原始字面量里的 \#(…) 插值递归、运行时拼接的文案。
function push(md,   t) {
  t = top + 1
  fm[t] = md; fp[t] = 0; fh[t] = 0; fl[t] = FNR; fb[t] = ""
  top = t
}
function pop(   ) {
  if (top <= 0) return
  delete fm[top]; delete fp[top]; delete fh[top]; delete fl[top]; delete fb[top]
  top--
}
function hashes(k,   s, t) { s = ""; for (t = 1; t <= k; t++) s = s "#"; return s }
function rest_blank(s, from,   t, c) {
  for (t = from; t <= length(s); t++) {
    c = substr(s, t, 1)
    if (c != " " && c != "\t") return 0
  }
  return 1
}
function emit(   txt) {
  txt = fb[top]
  gsub(/\t/, " ", txt); gsub(/\n/, " ", txt)
  printf "LIT\t%s\t%s\t%s\n", FILENAME, fl[top], txt
  if (index(txt, "\\u{") > 0) printf "ESC\t%s\t%s\t%s\n", FILENAME, fl[top], txt
}
function openquote(j,   k, prev) {            # 返回值 = 继续扫描的位置
  k = 0; prev = j - 1
  while (prev >= 1 && substr(line, prev, 1) == "#") { k++; prev-- }
  if (k > 0) { push("RAW"); fh[top] = k; return j + 1 }
  if (substr(line, j, 3) == "\"\"\"" && rest_blank(line, j + 3)) { push("DQ"); return j + 3 }
  if (substr(line, j, 2) == "\"\"") return j + 2          # 空字面量
  push("SQ"); return j + 1
}
BEGIN { top = 0; fm[0] = "CODE"; fp[0] = 0; fh[0] = 0; fl[0] = 0; fb[0] = "" }
FNR == 1 {
  top = 0; fm[0] = "CODE"; fp[0] = 0; fh[0] = 0; fb[0] = ""
}
{
  line = $0; L = length(line); i = 1
  if (fm[top] == "SQ" || fm[top] == "DQ" || fm[top] == "RAW") fb[top] = fb[top] "\n"
  while (i <= L) {
    md = fm[top]
    if (md == "CODE") {
      c = substr(line, i, 1); c2 = substr(line, i, 2)
      if (c2 == "//") { i = L + 1; continue }
      if (c2 == "/*") { push("BC"); fp[top] = 1; i += 2; continue }
      if (c == "(") { fp[top]++; i++; continue }
      if (c == ")") {
        if (fp[top] > 0) fp[top]--
        else if (top > 0) pop()
        i++; continue
      }
      if (c == "\"") { i = openquote(i); continue }
      i++; continue
    }
    if (md == "BC") {
      c2 = substr(line, i, 2)
      if (c2 == "/*") { fp[top]++; i += 2; continue }
      if (c2 == "*/") { fp[top]--; if (fp[top] <= 0) pop(); i += 2; continue }
      i++; continue
    }
    c = substr(line, i, 1)
    if (md == "RAW") {
      k = fh[top]
      if (c == "\"" && substr(line, i + 1, k) == hashes(k) && substr(line, i + 1 + k, 1) != "#") {
        emit(); pop(); i += 1 + k; continue
      }
      fb[top] = fb[top] c; i++; continue
    }
    if (c == "\\") {
      nx = substr(line, i + 1, 1)
      if (nx == "(") { push("CODE"); fp[top] = 0; i += 2; continue }
      # 保留反斜杠本身：\u{…} 这类码点转义要靠它在 emit 里被认出来
      fb[top] = fb[top] "\\" nx; i += 2; continue
    }
    if (md == "SQ") {
      if (c == "\"") { emit(); pop(); i++; continue }
      fb[top] = fb[top] c; i++; continue
    }
    if (md == "DQ") {
      if (substr(line, i, 3) == "\"\"\"" && rest_blank(line, i + 3)) { emit(); pop(); i += 3; continue }
      fb[top] = fb[top] c; i++; continue
    }
    i++
  }
  # 行尾：未闭合的单行字面量按跨行继续（宁可多吞，不误放行）
}
END {
  if (top != 0) printf "UNCLOSED\t%s\t%s\t扫描结束时仍有未闭合的字面量/注释帧\n", FILENAME, FNR
}
AWK_SWIFT

cat > "$WORK/plist.awk" <<'AWK_PLIST'
# XML plist 的 <string> 值抽取（与 Swift 侧共用同一条判据流：LIT 记录）。
#   LIT<TAB>file<TAB>行<TAB>值
#   BADP<TAB>file<TAB>行<TAB>原因   本脚本不解析的 plist 形态（⇒ 调用方按红处理）
function strip_comments(s,   p, q) {
  while ((p = index(s, "<!--")) > 0) {
    q = index(substr(s, p + 4), "-->")
    if (q == 0) { incmt = 1; return substr(s, 1, p - 1) }
    s = substr(s, 1, p - 1) substr(s, p + 3 + q + 2)
  }
  return s
}
BEGIN { incmt = 0 }
FNR == 1 { incmt = 0; hdr = 1 }
{
  s = $0
  if (hdr) {
    hdr = 0
    if (s !~ /(<\?xml|<!DOCTYPE[ \t]+plist|<plist)/)
      printf "BADP\t%s\t%s\t非 XML 形态的 plist（本脚本只解析 XML plist 的 <string> 值）\n", FILENAME, FNR
  }
  if (incmt) {
    if (index(s, "-->") > 0) { s = substr(s, index(s, "-->") + 3); incmt = 0 } else next
  }
  if (index(s, "<!--") > 0) s = strip_comments(s)
  if (index(s, "<![CDATA[") > 0) printf "BADP\t%s\t%s\tCDATA 形态本脚本不解析\n", FILENAME, FNR
  while (match(s, /<string>[^<]*<\/string>/)) {
    v = substr(s, RSTART + 8, RLENGTH - 17)
    printf "LIT\t%s\t%s\t%s\n", FILENAME, FNR, v
    if (index(v, "&#") > 0) printf "BADP\t%s\t%s\t数字字符实体 &#…; 本脚本不解码\n", FILENAME, FNR
    s = substr(s, RSTART + RLENGTH)
  }
  if (index(s, "<string>") > 0)
    printf "BADP\t%s\t%s\t<string> 的值跨行，本脚本不解析\n", FILENAME, FNR
  if (match(s, /<string[ \t][^>]*>/))
    printf "BADP\t%s\t%s\t带属性的 <string> 标签形态本脚本不解析\n", FILENAME, FNR
}
AWK_PLIST

cat > "$WORK/match.awk" <<'AWK_MATCH'
# 输入 LIT/ESC/UNCLOSED/BADP 记录（TSV）⇒ 输出 HIT 记录，并原样透传形态问题记录。
BEGIN { FS = "\t"; OFS = "\t"; n = split(banned, bw, " ") }
$1 == "LIT" {
  txt = $4
  for (j = 1; j <= n; j++)
    if (bw[j] != "" && index(txt, bw[j]) > 0) print "HIT", bw[j], $2, $3, txt
  next
}
$1 == "ESC" || $1 == "UNCLOSED" || $1 == "BADP" { print }
AWK_MATCH

# ------------------------------------------------------------------- 工具 --
md5_of() { md5 -q "$1" 2>/dev/null || printf 'MISSING'; }
size_of() { wc -c < "$1" | tr -d ' '; }
key_of_path() { printf '%s' "$1" | tr '/ ' '__'; }
count_lines() { awk 'NF { c++ } END { print c + 0 }' "$1" 2>/dev/null || printf '0'; }
count_viol()  { awk '/^❌/ { c++ } END { print c + 0 }' "$1" 2>/dev/null || printf '0'; }
count_prefixed() {             # 文件里第 2 列以 prefix/ 开头的 LIT 记录数
  awk -F'\t' -v p="$2" '$1 == "LIT" && index($2, p) == 1 { c++ } END { print c + 0 }' "$1" 2>/dev/null || printf '0'; }
pend_file() { printf '%s/%s' "$PEND" "$(key_of_path "$1")"; }
bak_file()  { printf '%s/bak.%s' "$WORK" "$(key_of_path "$1")"; }

vline() { printf '%s\n' "$1" >> "$REP"; }        # 一条违规（报告里以 ❌ 开头 = 计数单位）
info()  { printf '%s\n' "$1" >> "$REP"; }

# 具名排除（见文件头「排除口径」）。**只看目录成分**：文件名以 Tests 结尾不算排除，
# 否则往 app target 里扔一个 `D12Tests.swift` 就能免检 —— 那是判据的洞，不是豁免。
is_test_component() {
  case "$1" in
    Tests|tests|Fixtures|fixtures|*Tests|*Test) return 0 ;;
  esac
  return 1
}
is_excluded_path() {
  local p="$1" dir comp
  if [ -d "$p" ]; then
    comp="$(basename "$p")"
    if is_test_component "$comp"; then return 0; fi
  fi
  dir="$(dirname "$p")"
  while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
    comp="$(basename "$dir")"
    if is_test_component "$comp"; then return 0; fi
    case "$dir" in
      */*) dir="${dir%/*}" ;;
      *) break ;;
    esac
  done
  case "$p" in
    Package.swift|*/Package.swift) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------- 扫描面（project.yml） --
surface_add_source() {         # 行号 target path buildPhase
  local ln="$1" tg="$2" p="$3" bp="$4" b
  p="$(printf '%s' "$p" | sed -E 's,/$,,')"
  [ -n "$p" ] || { vline "❌ D12：project.yml:$ln 目标 $tg 的 sources 路径为空"; return; }
  if [ ! -e "$p" ]; then
    vline "❌ D12：project.yml:$ln 目标 $tg 声明的源路径 $p 不存在 ⇒ 无法确认它在不在扫描面内"
    return
  fi
  if [ -f "$p" ]; then
    case "$p" in
      *.swift)
        if is_excluded_path "$p"; then printf '%s\n' "$p" >> "$WORK/excl"
        else printf '%s\n' "$p" >> "$WORK/single"; fi ;;
      *) printf '%s\n' "$p" >> "$WORK/carriers" ;;
    esac
    return
  fi
  b="$(basename "$p")"
  case "$b" in
    *.xcassets) printf '%s\n' "$p" >> "$WORK/res"; return ;;
  esac
  case "$bp" in
    resources) printf '%s\n' "$p" >> "$WORK/res"; return ;;
  esac
  if is_excluded_path "$p"; then printf '%s\n' "$p" >> "$WORK/excl"; return; fi
  printf '%s\n' "$p" >> "$WORK/roots"
}

derive_surface() {
  local kind f1 f2 f3 f4 p
  : > "$WORK/roots"; : > "$WORK/res"; : > "$WORK/plists"; : > "$WORK/single"
  : > "$WORK/excl"; : > "$WORK/keys"; : > "$WORK/carriers"
  if ! awk -f "$WORK/yml.awk" project.yml > "$WORK/yml.tsv" 2>"$WORK/yml.err"; then
    vline "❌ D12：project.yml 解析器自身退出非零 ⇒ 扫描面无法确定，按红处理"
    info "   $(head -3 "$WORK/yml.err")"
    return
  fi
  while IFS="$TAB" read -r kind f1 f2 f3 f4; do
    case "$kind" in
      BAD)
        vline "❌ D12：project.yml:$f1 的写法本脚本无法识别 ⇒「静默少扫一片面」不可接受，按红处理"
        info  "   原文：$f2"
        info  "   原因：$f3"
        ;;
      SRC)  surface_add_source "$f1" "$f2" "$f3" "$f4" ;;
      PKG)
        p="$f2"
        if [ ! -d "$p" ]; then
          vline "❌ D12：project.yml:$f1 声明的本地包 $p 不存在 ⇒ 无法确定它的源码面"
        elif [ -d "$p/Sources" ]; then
          printf '%s\n' "$p/Sources" >> "$WORK/roots"
        else
          printf '%s\n' "$p" >> "$WORK/roots"     # 非默认布局：整包纳面，Tests 仍按具名排除
        fi
        ;;
      PLIST) printf '%s\n' "$f3" >> "$WORK/plists" ;;
      KEY)   printf '%s\n' "$f3" >> "$WORK/keys" ;;
      "") ;;
      *) vline "❌ D12：解析器输出了未知记录类型「$kind」⇒ 判据自身失真，按红处理" ;;
    esac
  done < "$WORK/yml.tsv"
  sort -u "$WORK/roots" -o "$WORK/roots"
  sort -u "$WORK/res" -o "$WORK/res"
  sort -u "$WORK/plists" -o "$WORK/plists"
  sort -u "$WORK/single" -o "$WORK/single"
  sort -u "$WORK/excl" -o "$WORK/excl"
  sort -u "$WORK/carriers" -o "$WORK/carriers"
}

# 反向防绕过：仓库里每个 .swift 必须在面内，或命中具名排除
check_swift_coverage() {
  local unc abs links cnt
  find . \( -name .git -o -name .build -o -name DerivedData -o -name build \
        -o -name '*.xcodeproj' -o -name '*.xcworkspace' -o -name xcuserdata -o -name .swiftpm \) \
      -prune -o -name '*.swift' \( -type f -o -type l \) -print \
    | sed 's|^\./||' | sort -u > "$WORK/all_swift"
  : > "$WORK/cov_swift"
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    [ -d "$abs" ] || continue
    find "$abs" -name '*.swift' \( -type f -o -type l \) -print >> "$WORK/cov_swift" 2>/dev/null || true
  done < "$WORK/roots"
  cat "$WORK/single" >> "$WORK/cov_swift"
  sort -u "$WORK/cov_swift" -o "$WORK/cov_swift"
  comm -23 "$WORK/all_swift" "$WORK/cov_swift" > "$WORK/outside"
  : > "$WORK/uncov"
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    is_excluded_path "$abs" || printf '%s\n' "$abs" >> "$WORK/uncov"
  done < "$WORK/outside"
  unc="$(count_lines "$WORK/uncov")"
  if [ "$unc" -gt 0 ]; then
    vline "❌ D12：$unc 个 .swift 既不在扫描面内、也不命中任何具名排除 ⇒ project.yml 的源声明与磁盘不一致（面被静默缩小），按红处理"
    while IFS= read -r abs; do info "   $abs"; done < "$WORK/uncov"
  fi
  # 面内的目录级符号链接：find 不会进去 ⇒ 它指向的内容可能在面外
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    links="$( { find "$abs" -type l 2>/dev/null || true; } | wc -l | tr -d ' ')"
    if [ "$links" -gt 0 ]; then
      vline "❌ D12：扫描面 $abs 内有 $links 个符号链接 ⇒ 链接目标不在面内，按红处理"
      { find "$abs" -type l 2>/dev/null || true; } | head -5 | while IFS= read -r l; do info "   $l"; done
    fi
  done < "$WORK/roots"
  cnt="$(count_lines "$WORK/all_swift")"
  info "D12 面覆盖核验：仓库内 .swift 共 $cnt 个（面内 $(count_lines "$WORK/cov_swift")，具名排除 $(count_lines "$WORK/outside")）"
}

# 载体面：能装用户文案、本脚本不解析的东西 ⇒ 必须红
check_carriers() {
  local f ext n_parsed n_bin n_red root
  : > "$WORK/plist_extra"; : > "$WORK/carrier_bad"; n_parsed=0; n_bin=0; n_red=0
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    { find "$root" \( -type f -o -name '*.lproj' \) -print 2>/dev/null || true; } >> "$WORK/carriers"
  done < "$WORK/roots"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    { find "$root" \( -type f -o -name '*.lproj' \) -print 2>/dev/null || true; } >> "$WORK/carriers"
  done < "$WORK/res"
  sort -u "$WORK/carriers" -o "$WORK/carriers"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      *.swift) n_parsed=$((n_parsed + 1)); continue ;;
      *.plist) n_parsed=$((n_parsed + 1)); printf '%s\n' "$f" >> "$WORK/plist_extra"; continue ;;
      *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.svg|*.icns|*.caf|*.mp3|*.m4a|*.wav|*.mp4|*.metal|*.h|*.c)
        n_bin=$((n_bin + 1)); continue ;;
      *.lproj)
        n_red=$((n_red + 1))
        printf '%s%s本地化目录：里面的文案本脚本不解析\n' "$f" "$TAB" >> "$WORK/carrier_bad"; continue ;;
      */Contents.json) continue ;;                  # asset catalog 元数据清单（唯一登记的豁免）
    esac
    ext="$(printf '%s\n' "${f##*.}" | tr 'A-Z' 'a-z')"
    case "$ext" in
      strings|stringsdict|xcstrings|storyboard|xib|nib|json|js|html|css|txt|md|csv|xml|rtf)
        n_red=$((n_red + 1))
        printf '%s%s.%s 可承载用户文案，本脚本不解析该格式\n' "$f" "$TAB" "$ext" >> "$WORK/carrier_bad" ;;
      *)
        n_red=$((n_red + 1))
        printf '%s%s未知扩展名 .%s：无法排除它承载用户文案 ⇒ 按红处理\n' "$f" "$TAB" "$ext" >> "$WORK/carrier_bad" ;;
    esac
  done < "$WORK/carriers"
  if [ "$n_red" -gt 0 ]; then
    vline "❌ D12：扫描面里有 $n_red 个「能承载用户文案而本脚本不解析」的文件 ⇒ 禁词可以从资源侧溜进 App，按红处理"
    while IFS="$TAB" read -r f ext; do info "   $f —— $ext"; done < "$WORK/carrier_bad"
  fi
  info "D12 载体面：已解析（.swift/.plist）$n_parsed；图片/音视频等不可判定 $n_bin；未解析载体红 $n_red"
  sort -u "$WORK/plist_extra" -o "$WORK/plist_extra"
}

# 主判据：字面量 → 禁词
scan_literals() {
  local f root n
  : > "$WORK/lit.tsv"; : > "$WORK/swift_files"; : > "$WORK/plist_all"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    { find "$root" -name '*.swift' \( -type f -o -type l \) -print 2>/dev/null || true; } >> "$WORK/swift_files"
  done < "$WORK/roots"
  cat "$WORK/single" >> "$WORK/swift_files"
  sort -u "$WORK/swift_files" -o "$WORK/swift_files"
  n="$(count_lines "$WORK/swift_files")"
  if [ "$n" -gt 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      set -- "$@" "$f"
    done < "$WORK/swift_files"
    awk -f "$WORK/swift.awk" "$@" >> "$WORK/lit.tsv"
  fi
  { cat "$WORK/plists" 2>/dev/null || true; cat "$WORK/plist_extra" 2>/dev/null || true; } \
    | sed '/^$/d' | sort -u > "$WORK/plist_all"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$f" ]; then vline "❌ D12：声明的 Info.plist $f 不存在 ⇒ 无法校验"; continue; fi
    awk -f "$WORK/plist.awk" "$f" >> "$WORK/lit.tsv" || true
  done < "$WORK/plist_all"
  # project.yml 的 INFOPLIST_KEY_* 标量会写进生成的 Info.plist ⇒ 同一条判据
  if [ -s "$WORK/keys" ]; then
    awk '{ printf "LIT\tproject.yml(INFOPLIST_KEY_)\t%s\t%s\n", NR, $0 }' "$WORK/keys" >> "$WORK/lit.tsv"
  fi
  awk -F'\t' -v banned="$BANNED" -f "$WORK/match.awk" < "$WORK/lit.tsv" > "$WORK/viol.tsv"
  while IFS="$TAB" read -r kind f2 f3 f4 f5; do
    case "$kind" in
      HIT)
        vline "❌ D12 禁词命中：「$f2」出现在 $f3:$f4"
        info "   字面量：$f5"
        ;;
      ESC)
        vline "❌ D12：$f2:$f3 的字面量里出现 \\u{…} 码点转义 —— 禁词可以按码点写进来，本脚本不解码 ⇒ 按红处理"
        info "   字面量：$f4"
        ;;
      UNCLOSED)
        vline "❌ D12：$f2 有未闭合的字面量/注释帧 ⇒ 抽取器无法确定面内内容，按红处理"
        info "   $f4"
        ;;
      BADP)
        vline "❌ D12：$f2:$f3 的 plist 形态本脚本不解析 ⇒ 资源侧文案不可判，按红处理"
        info "   原因：$f4"
        ;;
    esac
  done < "$WORK/viol.tsv"
}

# 判据不得空转：面非空、每个根非空、每个根至少取到一条字面量
check_surface_alive() {
  local root n cnt
  n="$(count_lines "$WORK/roots")"
  if [ "$n" -eq 0 ]; then
    vline "❌ D12：扫描面为空 ⇒ 这条判据等于没有，按红处理"
    return
  fi
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    cnt="$( { find "$root" -name '*.swift' \( -type f -o -type l \) -print 2>/dev/null || true; } | wc -l | tr -d ' ')"
    if [ "$cnt" -eq 0 ]; then
      vline "❌ D12：扫描面里的 $root 没有任何 .swift ⇒ 根路径失效，按红处理"
      continue
    fi
    if [ "$(count_prefixed "$WORK/lit.tsv" "$root/")" -eq 0 ]; then
      vline "❌ D12 自检失败：$root 里一条字符串字面量都取不到 ⇒ 这片面等于没扫，按红处理"
      continue
    fi
    info "D12 扫描面：$root（$cnt 个 .swift）"
  done < "$WORK/roots"
  while IFS= read -r root; do
    [ -n "$root" ] && info "D12 资源面（只查载体、不解析内容）：$root"
  done < "$WORK/res"
  while IFS= read -r root; do
    [ -n "$root" ] && info "D12 具名排除（测试夹具/清单，边界见文件头）：$root"
  done < "$WORK/excl"
}

# 逐字脚注必须以**字面量**形式存在（design 13 §F，缺失 = Critical）
check_footnotes() {
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! awk -F'\t' -v want="$t" -v f="$REQUIRED_FILE" \
        '$1 == "LIT" && $2 == f && index($4, want) > 0 { found = 1 } END { exit(found ? 0 : 1) }' "$WORK/lit.tsv"; then
      vline "❌ D12 合规脚注缺失、或已不在字符串字面量里（design 13 §F，缺失按 Critical）：$t"
      info "   应在：$REQUIRED_FILE"
    fi
  done <<EOF
$REQUIRED
EOF
}

run_gate() {
  : > "$REP"
  derive_surface
  check_swift_coverage
  check_carriers
  scan_literals
  check_surface_alive
  check_footnotes
}

# ------------------------------------------------ 植入 / 反向复原（自检用） --
# 约定：备份 + 反向操作 + md5 逐字节校验；不用 git checkout --/git restore（本仓有前科）。
# 每个植入点在 $PEND 下留一条记账（md5<TAB>植入前字节数<TAB>方式<TAB>路径），复原成功后
# 销账；没销账的记账由 EXIT 陷阱兜底（append/subst ⇒ 用备份原样覆回，probe ⇒ 删掉），
# 所以判据被打断也不会在树里留下诱饵。
plant_take() {                          # 文件, 方式
  local f="$1" kind="$2"
  cp -p "$f" "$(bak_file "$f")"
  printf '%s\t%s\t%s\t%s\n' "$(md5_of "$f")" "$(size_of "$f")" "$kind" "$f" > "$(pend_file "$f")"
}
plant_release() { rm -f "$(pend_file "$1")"; }
note_restore() { printf '   ✅ 复原校验：%s md5 与植入前逐字节一致（%s）\n' "$1" "$2"; }

snippet_of() {                          # CASE 名 → 诱饵原文（按字节）
  local name="$1" out="$2"
  awk -v want="$name" '
    /^CASE[ \t]/ { if (on) exit; on = ($2 == want); next }
    on { printf "%s\n", $0 }
  ' "$SELFTEST_COPY" > "$out"
  if [ ! -s "$out" ]; then
    printf '❌ 自检数据 %s 里没有 CASE %s ⇒ 自检本身不可信\n' "$SELFTEST_COPY" "$name" >&2
    exit 1
  fi
}

plant_append() {                        # 目标文件, 诱饵文件
  local f="$1" snip="$2"
  plant_take "$f" append
  cat "$snip" >> "$f"
}
unplant_append() {                      # 目标文件, 诱饵文件（诱饵记号取全局 CUR_MARKER）
  local f="$1" snip="$2" st md5b sizeb size
  st="$(pend_file "$f")"
  if [ ! -f "$st" ]; then
    printf '   ❌ 自检协议失败：%s 没有植入记账\n' "$f" >&2; SELFTEST_BROKEN=1; return
  fi
  md5b="$(cut -f1 < "$st")"; sizeb="$(cut -f2 < "$st")"
  size="$(size_of "$f")"
  if [ "$size" -eq "$((sizeb + $(size_of "$snip")))" ]; then
    head -c "$sizeb" "$f" > "$WORK/trunc.tmp"        # 反向操作：截掉追加的那段
    cat "$WORK/trunc.tmp" > "$f"
  else
    printf '   ❌ 自检协议失败：%s 在植入期间被并发改动（字节数不等于「植入前 + 诱饵」）⇒ 用备份复原，请人工复核 git diff\n' "$f" >&2
    cat "$(bak_file "$f")" > "$f"
    SELFTEST_BROKEN=1
  fi
  plant_release "$f"
  if [ -n "$CUR_MARKER" ] && grep -qF -- "$CUR_MARKER" "$f"; then
    printf '   ❌ 自检协议失败：%s 反向复原后诱饵仍在 ⇒ 用备份强制复原\n' "$f" >&2
    cat "$(bak_file "$f")" > "$f"
    SELFTEST_BROKEN=1
    return
  fi
  if [ "$(md5_of "$f")" != "$md5b" ]; then
    printf '   ❌ 自检协议失败：%s 复原后 md5 与植入前不一致（植入期间被人改过？）⇒ 诱饵已清除但不覆写，请人工复核 git diff\n' "$f" >&2
    SELFTEST_BROKEN=1
    return
  fi
  note_restore "$f" "$md5b"
}

mutate_nth_line() {                     # 文件, 行号, 新行文本 —— 只改这一行
  local f="$1" n="$2" new="$3" k
  k="$(key_of_path "$f")"
  plant_take "$f" subst
  printf '%s\n' "$n" > "$PEND/$k.line"
  printf '%s\n' "$new" > "$PEND/$k.new"
  awk -v want="$n" -v txt="$new" '{ if (FNR == want) print txt; else print }' "$f" > "$WORK/subst.tmp"
  cat "$WORK/subst.tmp" > "$f"
}
# 反向复原 = 把记账里那一行换回**备份文件的同一行**。
# 校验分两层：① 诱饵内容必须已经不在文件里（绝不允许把禁词留在树里）；
# ② md5 必须与植入前逐字节一致 —— 不一致说明文件在植入期间被人并发改过，
#    此时**不覆写**（覆写会吃掉别人的改动），只判红并要求人工复核 git diff。
restore_subst() {                       # 文件, 诱饵内容（用来确认已清除）
  local f="$1" bait="$2" st k n old md5b
  st="$(pend_file "$f")"; k="$(key_of_path "$f")"
  if [ ! -f "$st" ]; then
    printf '   ❌ 自检协议失败：%s 没有植入记账\n' "$f" >&2; SELFTEST_BROKEN=1; return
  fi
  md5b="$(cut -f1 < "$st")"; n="$(cat "$PEND/$k.line")"
  old="$(awk -v want="$n" 'FNR == want { print; exit }' "$(bak_file "$f")")"
  awk -v want="$n" -v txt="$old" '{ if (FNR == want) print txt; else print }' "$f" > "$WORK/subst.tmp"
  cat "$WORK/subst.tmp" > "$f"
  rm -f "$st" "$PEND/$k.line" "$PEND/$k.new"
  if [ -n "$bait" ] && grep -qF -- "$bait" "$f"; then
    printf '   ❌ 自检协议失败：%s 反向复原后诱饵仍在 ⇒ 用备份强制复原\n' "$f" >&2
    cat "$(bak_file "$f")" > "$f"
    SELFTEST_BROKEN=1
    return
  fi
  if [ "$(md5_of "$f")" != "$md5b" ]; then
    printf '   ❌ 自检协议失败：%s 复原后 md5 与植入前不一致（植入期间被人改过？）⇒ 诱饵已清除但不覆写，请人工复核 git diff\n' "$f" >&2
    SELFTEST_BROKEN=1
    return
  fi
  note_restore "$f" "$md5b"
}

create_probe() {                        # 新建探针文件（收尾必须删掉）
  local f="$1" src="$2"
  printf -- '-\t0\tprobe\t%s\n' "$f" > "$(pend_file "$f")"
  cat "$src" > "$f"
}
remove_probe() {
  local f="$1"
  rm -f "$f"
  if [ -e "$f" ]; then
    printf '   ❌ 复原校验：探针 %s 没有被删掉 ⇒ 工作树被污染\n' "$f" >&2
    SELFTEST_BROKEN=1
    return
  fi
  plant_release "$f"
  printf '   ✅ 复原校验：探针 %s 已删除\n' "$f"
}

cleanup_pending() {                     # EXIT 兜底：任何没销账的植入都不许留在树里
  local st kind f
  for st in "$PEND"/*; do
    [ -f "$st" ] || continue
    case "$st" in *.line|*.new) rm -f "$st"; continue ;; esac
    kind="$(cut -f3 < "$st" 2>/dev/null || printf '')"
    f="$(cut -f4 < "$st" 2>/dev/null || printf '')"
    [ -n "$f" ] || continue
    printf '❌ D12 自检兜底复原：%s（用例没有正常收尾）\n' "$f" >&2
    case "$kind" in
      probe) rm -f "$f" ;;
      *) if [ -f "$(bak_file "$f")" ]; then cat "$(bak_file "$f")" > "$f"; fi ;;
    esac
    rm -f "$st"
    SELFTEST_BROKEN=1
  done
}
SELFTEST_BROKEN=0
d12_leave() { cleanup_pending; rm -rf "$WORK"; }
trap 'd12_leave' EXIT
trap 'd12_leave; exit 130' INT TERM      # Ctrl-C / kill -TERM 也不许把诱饵留在树里（kill -9 之后请靠 git status 复核）

# ------------------------------------------------------------------ 动作 --
# 植入点一律从**已经推出来的面**里取（写死文件名 = 面变了、自检还在自嗨）：
#   APP_*   ← 第一个非包根（app target 自己的源码目录；R16-3 漏的正是这一片）
#   PKG_*   ← 第一个包根（Packages/*/Sources）
#   PLIST_* ← project.yml 声明的第一个 Info.plist
APP_ROOT=''; APP_FILE=''; APP_ROOT_LINE=''; APP_ROOT_TEXT=''; APP_ROOT_INDENT=''
PKG_ROOT=''; PKG_FILE=''; PLIST_FILE=''; PLIST_LINE=''; CARRIER_PROBE=''
CUR_MARKER=''

act_app_line()   { snippet_of app_line "$WORK/s"; plant_append "$APP_FILE" "$WORK/s"; }
undo_app_line()  { unplant_append "$APP_FILE" "$WORK/s"; }

act_pkg_line()   { snippet_of package_line "$WORK/s"; plant_append "$PKG_FILE" "$WORK/s"; }
undo_pkg_line()  { unplant_append "$PKG_FILE" "$WORK/s"; }

act_pkg_block()  { snippet_of block_literal "$WORK/s"; plant_append "$PKG_FILE" "$WORK/s"; }
undo_pkg_block() { unplant_append "$PKG_FILE" "$WORK/s"; }

act_plist_copy() {
  snippet_of plist_copy "$WORK/s"
  if [ "$(count_lines "$WORK/s")" != "1" ]; then
    printf '   ❌ plist 诱饵必须是单行（本用例按整行替换实现）\n' >&2; return 1
  fi
  mutate_nth_line "$PLIST_FILE" "$PLIST_LINE" "$(cat "$WORK/s")"
}
undo_plist_copy() { restore_subst "$PLIST_FILE" '[d12selftest:plist_copy]'; }

act_carrier()    { snippet_of carrier_strings "$WORK/s"; create_probe "$CARRIER_PROBE" "$WORK/s"; }
undo_carrier()   { remove_probe "$CARRIER_PROBE"; }

# project.yml 里 app target 那条 sources 声明的三种写法：两种 XcodeGen **合法**（裸标量、
# 带行尾注释），一种本脚本**不认识**（flow）—— 前两种必须照样纳面、第三种必须染红。
yml_variant() {
  case "$1" in
    bare)    printf '%s- %s' "$APP_ROOT_INDENT" "$APP_ROOT" ;;
    comment) printf '%s  # app target sources' "$APP_ROOT_TEXT" ;;
    flow)    printf '%s- {path: %s}' "$APP_ROOT_INDENT" "$APP_ROOT" ;;
  esac
}
act_yml_spelling() {                    # bare | comment
  if [ -z "$APP_ROOT_LINE" ]; then
    printf '   ❌ 面里没有 app target 的 sources 声明行可改（面已破损，见上方 ❌）\n' >&2; return 1
  fi
  mutate_nth_line project.yml "$APP_ROOT_LINE" "$(yml_variant "$1")" || return 1
  snippet_of app_line "$WORK/s"
  plant_append "$APP_FILE" "$WORK/s"
}
undo_yml_spelling() {
  unplant_append "$APP_FILE" "$WORK/s"
  restore_subst project.yml '[d12selftest:app_line]'
}
act_yml_bare()    { act_yml_spelling bare; }
undo_yml_bare()   { undo_yml_spelling; }
act_yml_comment() { act_yml_spelling comment; }
undo_yml_comment() { undo_yml_spelling; }
act_yml_unknown() {
  [ -n "$APP_ROOT_LINE" ] || { printf '   ❌ 面里没有 app target 的 sources 声明行可改\n' >&2; return 1; }
  mutate_nth_line project.yml "$APP_ROOT_LINE" "$(yml_variant flow)"
}
undo_yml_unknown() { restore_subst project.yml ''; }

# ------------------------------------------------------------------ 开跑 --
run_gate
APP_ROOT="$(awk '!/^Packages\// { print; exit }' "$WORK/roots")"
[ -n "$APP_ROOT" ] || APP_ROOT="$(head -1 "$WORK/roots")"
PKG_ROOT="$(awk '/^Packages\// { print; exit }' "$WORK/roots")"
APP_FILE="$( { find "$APP_ROOT" -name '*.swift' -type f 2>/dev/null || true; } | sort | head -1)"
PKG_FILE="$( { find "$PKG_ROOT" -name '*.swift' -type f 2>/dev/null || true; } | sort | head -1)"
PLIST_FILE="$(head -1 "$WORK/plists")"
# app target 的 sources 声明在 project.yml 里的行号/原文（自检要改的就是这一行）
APP_ROOT_LINE="$(awk -F'\t' -v r="$APP_ROOT" '$1 == "SRC" && $4 == r { print $2; exit }' "$WORK/yml.tsv")"
if [ -n "$APP_ROOT_LINE" ]; then
  APP_ROOT_TEXT="$(awk -v n="$APP_ROOT_LINE" 'FNR == n { print; exit }' project.yml)"
  APP_ROOT_INDENT="$(printf '%s\n' "$APP_ROOT_TEXT" | awk '{ match($0, /^ */); print substr($0, 1, RLENGTH) }')"
fi
PLIST_LINE="$(awk '/<key>CFBundleDisplayName<\/key>/ { print NR + 1; exit }' "$PLIST_FILE" 2>/dev/null || true)"
CARRIER_PROBE="$APP_ROOT/__d12_selftest.strings"
if [ -z "$APP_FILE" ] || [ -z "$PKG_FILE" ] || [ -z "$PLIST_FILE" ] || [ ! -f "$PLIST_FILE" ] || [ -z "$PLIST_LINE" ]; then
  cat "$REP"
  printf '❌ D12 自检失败：植入点凑不齐（app=%s pkg=%s plist=%s:%s）⇒ 扫描面已破损，自检无法自证\n' \
    "$APP_FILE" "$PKG_FILE" "$PLIST_FILE" "$PLIST_LINE"
  exit 1
fi
printf 'D12 自检植入点：app=%s｜包=%s｜Info.plist=%s:%s\n' "$APP_FILE" "$PKG_FILE" "$PLIST_FILE" "$PLIST_LINE"

cat "$REP"
BASE="$(count_viol "$REP")"

printf '\nD12 自检（沿真实违规路径植入；诱饵文本见 %s）：\n' "$SELFTEST_COPY"
CASES_RUN=0
for spec in \
  "app_target_literal|d12selftest:app_line|act_app_line|undo_app_line" \
  "package_literal|d12selftest:package_line|act_pkg_line|undo_pkg_line" \
  "block_literal_三引号|d12selftest:block_literal|act_pkg_block|undo_pkg_block" \
  "info_plist_显示名|d12selftest:plist_copy|act_plist_copy|undo_plist_copy" \
  "未解析载体_strings|__d12_selftest.strings|act_carrier|undo_carrier" \
  "yml_裸标量条目|d12selftest:app_line|act_yml_bare|undo_yml_bare" \
  "yml_行尾注释|d12selftest:app_line|act_yml_comment|undo_yml_comment" \
  "yml_不认识的写法|无法识别|act_yml_unknown|undo_yml_unknown"; do
  name="$(printf '%s' "$spec" | cut -d'|' -f1)"
  marker="$(printf '%s' "$spec" | cut -d'|' -f2)"
  act="$(printf '%s' "$spec" | cut -d'|' -f3)"
  undo="$(printf '%s' "$spec" | cut -d'|' -f4)"
  CUR_MARKER="$marker"                # 反向复原后靠它确认「诱饵真的不在文件里」
  CASES_RUN=$((CASES_RUN + 1))
  if ! "$act"; then
    printf '  %-22s ⇒ ❌ 植入失败（自检协议问题）\n' "$name"
    SELFTEST_BROKEN=1
    continue
  fi
  run_gate
  n="$(count_viol "$REP")"
  if grep -qF -- "$marker" "$REP" && [ "$n" -gt "$BASE" ]; then
    printf '  %-22s ⇒ 抓到（违规 %s → %s，记号 %s）\n' "$name" "$BASE" "$n" "$marker"
  else
    where="$( { grep -qF -- "$marker" "$REP" && printf '在报告里'; } || printf '不在报告里'; )"
    printf '  %-22s ⇒ ❌ 判据失效：记号 %s %s，违规 %s（基线 %s）\n' "$name" "$marker" "$where" "$n" "$BASE"
    { grep '^❌' "$REP" || true; } | head -5 | sed 's/^/      /'
    SELFTEST_BROKEN=1
  fi
  "$undo" || printf '  %-22s ⇒ ❌ 复原失败\n' "$name"
  run_gate
  n2="$(count_viol "$REP")"
  if [ "$n2" != "$BASE" ] || grep -qF -- "$marker" "$REP"; then
    printf '  %-22s ⇒ ❌ 复原后没回到基线（违规 %s vs 基线 %s）\n' "$name" "$n2" "$BASE"
    { grep -F -- "$marker" "$REP" || true; } | head -3 | sed 's/^/      /'
    SELFTEST_BROKEN=1
  fi
done

if [ -e "$CARRIER_PROBE" ]; then
  printf '❌ D12 自检失败：探针 %s 仍在树里 ⇒ 工作树被污染\n' "$CARRIER_PROBE"
  exit 1
fi
if [ "$SELFTEST_BROKEN" -ne 0 ]; then
  printf '❌ D12 自检失败（植入/复原协议本身出问题）⇒ 这条判据不可信，按红处理\n'
  exit 1
fi
run_gate
FINAL="$(count_viol "$REP")"
if [ "$FINAL" != "$BASE" ]; then
  printf '❌ D12 自检失败：自检结束后判据没回到基线（%s vs %s）\n' "$FINAL" "$BASE"
  exit 1
fi
printf 'D12 自检：%s 段诱饵全部被抓、全部复原（md5 逐字节一致）\n' "$CASES_RUN"

if [ "$BASE" -gt 0 ]; then
  printf 'D12 文案门禁未通过（%s 条违规）\n' "$BASE"
  exit 1
fi
printf '✅ D12 文案门禁通过：禁词命中 0；扫描面覆盖全仓 .swift；载体面无未解析文件；逐字脚注在册\n'
