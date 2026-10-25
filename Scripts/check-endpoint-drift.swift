// 端点漂移守卫 —— 「iOS 调用面 ⊆ 生产路由」的一条命令版本。
//
// 为什么要有它：2026-10-26 的多端对齐盘点（归档/qa-evidence/多端对齐-20261026/iOS.md）
// 是一次性人工比对（iOS 36 条路径 × web 277 条路由）。web 一改路由，那份结论就过期，
// 而过期的方式是沉默的（客户端打到 404 才发现）。本脚本把那次比对固化成可重跑判据。
//
// 三条口径（每条都有明确的失败面，不靠“大概”）：
//  · iOS 路径只从源码字面量取：Packages/*/Sources/**/*.swift 里的 "/api/…" 字符串。
//    Swift 插值（反斜杠 + 括号那种）归一成 {p}；以 / 结尾的字面量是拼接式（如 "/api/media/objects/"），
//    按前缀匹配 —— 那种写法把参数拼在字符串外，脚本不猜它拼了什么。
//  · web 路由从 route.ts 的文件树取（不是从运行中的服务）：src/app/api/**/route.ts，
//    方括号段（[id] / [token] / [...rest]）一律归一成 {p}。
//  · 基线：iOS 侧路径集合必须逐行等于 Scripts/endpoint-drift-baseline.txt。
//    少一条、多一条都要显式改基线，否则“调用面悄悄少了一个接口”没人看得见。
//
// 用法：
//   swift Scripts/check-endpoint-drift.swift              # 检查（默认）
//   swift Scripts/check-endpoint-drift.swift --update     # 重写基线
//   COVA_WEB_ROOT=/path/to/web swift Scripts/...          # web 仓不在 ../web 时指定
//
// 退出码：0 = 零漂移；1 = 有漂移（缺路由 / 基线不一致）；2 = 环境不合格。
// 刻意不进 Scripts/check.sh：那条门禁要求“同一份代码在任何机器上都绿”，
// 而本脚本需要同机有 ../web 源码树 —— 环境依赖不该写进发版门禁（见 AGENTS.md v2.77.56 的教训）。

import Foundation

let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath().deletingLastPathComponent()
let root = scriptDir.deletingLastPathComponent()
let env = ProcessInfo.processInfo.environment
let webRoot = env["COVA_WEB_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? root.deletingLastPathComponent().appendingPathComponent("web")
// 必须解析符号链接：枚举器返回的是**真实**路径，而 apiDir 若含 /tmp 这类软链前缀，
// 下面按 prefix 截断就会失败（表现是 277 条路由一条都对不上，而不是报环境错）。
// 这条是 2026-10-26 用 `git archive` 出的临时树验证发布版时踩到的。
let apiDir = webRoot.appendingPathComponent("src/app/api").resolvingSymlinksInPath()
let baselineURL = root.appendingPathComponent("Scripts/endpoint-drift-baseline.txt")

func failEnv(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[endpoint-drift] 环境不合格：\(message)\n".utf8))
    exit(2)
}

var isDir: ObjCBool = false
guard fm.fileExists(atPath: apiDir.path, isDirectory: &isDir), isDir.boolValue else {
    failEnv("读不到 web 路由树：\(apiDir.path)（用 COVA_WEB_ROOT=… 指定）")
}

let backslash = Character(UnicodeScalar(92)!)

/// Swift 插值（反斜杠 + 左括号 … 右括号）折成 {p}。手写扫描而不是正则：
/// 这里只需要“跳过一段”，正则反而会把转义层级带进判据。
func normalize(_ raw: String) -> String {
    var out = ""
    var i = raw.startIndex
    while i < raw.endIndex {
        let c = raw[i]
        let n = raw.index(after: i)
        if c == backslash, n < raw.endIndex, raw[n] == "(" {
            var j = raw.index(after: n)
            while j < raw.endIndex, raw[j] != ")" { j = raw.index(after: j) }
            out.append("{p}")
            i = j < raw.endIndex ? raw.index(after: j) : raw.endIndex
            continue
        }
        out.append(c)
        i = n
    }
    return out
}

func swiftSources(under dir: URL) -> [URL] {
    guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    var out: [URL] = []
    for case let u as URL in e where u.pathExtension == "swift" { out.append(u) }
    return out
}

func iosCallPaths() -> [String] {
    var set = Set<String>()
    let packages = root.appendingPathComponent("Packages")
    var sourcesDirs: [URL] = []
    if let subs = try? fm.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil) {
        for sub in subs {
            let sources = sub.appendingPathComponent("Sources")
            if fm.fileExists(atPath: sources.path) { sourcesDirs.append(sources) }
        }
    }
    for dir in sourcesDirs {
        for file in swiftSources(under: dir) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // 路径一定写在双引号里 ⇒ 按引号切段，取以 /api/ 开头的段。
            for part in text.components(separatedBy: "\"")
            where part.hasPrefix("/api/") && !part.contains("\n") {
                set.insert(normalize(part))
            }
        }
    }
    return set.sorted()
}

func webRoutes() -> [String] {
    guard let e = fm.enumerator(at: apiDir, includingPropertiesForKeys: nil) else { return [] }
    var set = Set<String>()
    let prefix = apiDir.resolvingSymlinksInPath().path + "/"
    for case let u as URL in e where u.lastPathComponent == "route.ts" {
        // 两边都解析：枚举器可能回软链前的真实路径，apiDir 也可能带软链前缀。
        var rel = u.resolvingSymlinksInPath().path
        if rel.hasPrefix(prefix) { rel.removeFirst(prefix.count) }
        var comps = rel.components(separatedBy: "/")
        comps.removeLast() // 去掉 route.ts
        comps = comps.map { $0.hasPrefix("[") ? "{p}" : $0 }
        set.insert("/api/" + comps.joined(separator: "/"))
    }
    return set.sorted()
}

let ios = iosCallPaths()
let web = webRoutes()
let webSet = Set(web)

if CommandLine.arguments.contains("--update") {
    var lines = [
        "# iOS 调用面基线（生成：swift Scripts/check-endpoint-drift.swift --update）",
        "# 每行一条归一化路径：Swift 插值已折成 {p}；以 / 结尾的是拼接式前缀。",
        "# 改这一份 = 显式声明“调用面变了”，请在同一 commit 里说明原因。",
    ]
    lines.append(contentsOf: ios)
    try lines.joined(separator: "\n").appending("\n").write(to: baselineURL, atomically: true, encoding: .utf8)
    print("[endpoint-drift] 基线已重写：\(baselineURL.path)（\(ios.count) 条）")
    exit(0)
}

guard let baselineText = try? String(contentsOf: baselineURL, encoding: .utf8) else {
    failEnv("缺基线文件：\(baselineURL.path)（先跑 --update 生成并提交）")
}
let baseline = baselineText.components(separatedBy: "\n")
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    .sorted()

// 缺路由：iOS 在用、web 没有。
// 两类「前缀式」都算命中（都属“参数由调用方拼接”的写法）：
//  ① 字面量以 / 结尾（如 "/api/media/objects/"）；
//  ② 字面量只是个 base、调用方再拼 "/" + id（如 AgentRunResponseDto.pathPrefix）。
// 判据要求 web 侧**真有子路由** —— 拼错一个字母仍然会红，那正是它的价值。
var missing: [String] = []
var prefixMatched: [String] = []
for p in ios {
    if webSet.contains(p) { continue }
    if p.hasSuffix("/") {
        if web.contains(where: { $0.hasPrefix(p) }) { prefixMatched.append(p) } else { missing.append(p) }
        continue
    }
    if web.contains(where: { $0.hasPrefix(p + "/") }) { prefixMatched.append(p) } else { missing.append(p) }
}
let added = ios.filter { !baseline.contains($0) }
let removed = baseline.filter { !ios.contains($0) }

print("[endpoint-drift] iOS 调用面 \(ios.count) 条 / web 路由 \(web.count) 条（源：\(apiDir.path)）")

var bad = false
if !missing.isEmpty {
    print(""); print("❌ 缺路由（iOS 在用、web 没有）：")
    for p in missing { print("   - " + p) }
    bad = true
}
if !added.isEmpty {
    print(""); print("⚠️  基线里没有的新增路径（改调用面后请 --update 并说明）：")
    for p in added { print("   + " + p) }
    bad = true
}
if !removed.isEmpty {
    print(""); print("⚠️  基线里有、源码里已消失的路径（删了？还是拼错了？）：")
    for p in removed { print("   - " + p) }
    bad = true
}

if !prefixMatched.isEmpty {
    print(""); print("ℹ️  前缀式（参数由调用方拼接，按 web 子路由校验）：")
    for p in prefixMatched { print("   ~ " + p) }
}

if bad { exit(1) }
print("✅ 零漂移：iOS 用到的每一条路径都能在 web 路由树里找到，且与基线逐行一致")
