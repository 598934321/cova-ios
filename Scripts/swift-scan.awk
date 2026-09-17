# Swift 源码静态扫描器（供 Scripts/check.sh 使用）
# 用法：awk -f Scripts/swift-scan.awk -v mode=imports|declared|conditional <files...>
#
# 语义：先剥离「行注释 //」「块注释 /* ... */（可跨行）」「字符串字面量 "..."（含转义与 """ 多行串）」，
#       再按 mode 输出：
#         imports     → 每个被 import / canImport 的模块名（跨行拆分 import 也能识别）
#         declared    → 源码内 func test* 的计数
#         conditional → 条件编译指令（#if/#elseif/#else/#endif）的位置（门禁据此 fail-closed）
#
# 设计意图：注释与字符串里的 "import"/"func test"/"#if" 不得产生误报或虚假计数；
#           扫描以「类别」为单位（禁止条件编译），不做模式枚举。

function preprocess(line,   out, i, n, c, two, three) {
  out = ""
  n = length(line)
  i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    two = substr(line, i, 2)
    three = substr(line, i, 3)
    if (in_block) {
      if (two == "*/") { in_block = 0; i += 2 } else { i++ }
      continue
    }
    if (in_mstr) {
      if (three == "\"\"\"") { in_mstr = 0; i += 3 } else { i++ }
      continue
    }
    if (in_str) {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") { in_str = 0 }
      i++
      continue
    }
    if (two == "//") break
    if (two == "/*") { in_block = 1; i += 2; continue }
    if (three == "\"\"\"") { in_mstr = 1; i += 3; continue }
    if (c == "\"") { in_str = 1; i++; continue }
    out = out c
    i++
  }
  return out
}

function flushImports(   n, t, i, j) {
  gsub(/[^A-Za-z0-9_]/, " ", buf)
  n = split(buf, t, " ")
  for (i = 1; i <= n; i++) {
    if (t[i] == "import" || t[i] == "canImport") {
      j = i + 1
      if (t[j] ~ /^(typealias|struct|class|enum|protocol|func|var|let)$/) j++
      if (t[j] != "") print t[j]
    }
  }
  buf = ""
}

FNR == 1 {
  in_block = 0
  in_str = 0
  in_mstr = 0
  if (NR > 1 && mode == "imports") flushImports()
}

{
  code = preprocess($0)
  if (mode == "imports") {
    buf = buf " " code
  } else if (mode == "declared") {
    while (match(code, /func[ \t]+test[A-Za-z0-9_]*/)) {
      count++
      code = substr(code, RSTART + RLENGTH)
    }
  } else if (mode == "conditional") {
    if (code ~ /(^|[^A-Za-z0-9_])#(if|elseif|else|endif)([^A-Za-z0-9_]|$)/) {
      print FILENAME ":" FNR ": " $0
    }
  }
}

END {
  if (mode == "imports") flushImports()
  else if (mode == "declared") print count + 0
}
