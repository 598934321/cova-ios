import Foundation
import CovaCore
import CovaUI
import XCTest

// R18-2 美术腿夹具的读取面与断言辅助。
//
// 夹具只做一件事：把「服务端可能交出来的字段形态」按**真实 DTO** 解码进来
// （`ArtistDto` / `TrackDto` / `PlaylistDto` / `SimilarTrackDto` / `RecentTrack`），
// 于是同一份夹具既钉住「腿读的是哪个字段名」，也钉住「那个字段进裁决面之后是什么结论」。
// 记号 `<covers>` 在加载时展开成 `CovaEnvironment.sanctionedStorageHosts.first` ——
// 名单的唯一事实源在 CovaCore（D23②），测试**不复制桶名**，桶名一改测试跟着走。
//
// 夹具里没有真实签名参数、没有线上原文、没有可路由的真实第三方主机（`.invalid` / `.evil.test`），
// 全程零网络请求。

enum ArtworkFixtureError: Error, CustomStringConvertible {
    case fixtureMissing
    case undecodable(String)
    case keyMissing(String)
    case emptySanctionedList

    var description: String {
        switch self {
        case .fixtureMissing: return "缺少夹具 Fixtures/artwork-legs.json"
        case .undecodable(let reason): return "夹具无法解析：\(reason)"
        case .keyMissing(let key): return "夹具缺少键 \(key)"
        case .emptySanctionedList: return "CovaEnvironment.sanctionedStorageHosts 为空"
        }
    }
}

enum ArtworkFixture {
    /// 名单内绝对地址的记号（避免把生产桶名抄进夹具）。
    private static let coversToken = "<covers>"

    /// 名单第一台存储主机（唯一事实源在 CovaCore）。
    static var coversHost: String {
        get throws {
            guard let host = CovaEnvironment.sanctionedStorageHosts.first else {
                throw ArtworkFixtureError.emptySanctionedList
            }
            return host
        }
    }

    /// 「名单内的绝对封面地址」（夹具里写成 `https://<covers>/…`）。
    static func sanctioned(_ path: String) throws -> String {
        "https://\(try coversHost)\(path)"
    }

    /// 生产 origin（站内相对路径补全后的前缀）。
    static func production(_ path: String) -> String {
        CovaEnvironment.apiBaseURL.absoluteString + path
    }

    static func decoded<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        let object = try JSONSerialization.jsonObject(with: rawJSON(), options: [])
        guard let dictionary = object as? [String: Any], let slice = dictionary[key] else {
            throw ArtworkFixtureError.keyMissing(key)
        }
        let data = try JSONSerialization.data(withJSONObject: slice, options: [])
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ArtworkFixtureError.undecodable("\(error)")
        }
    }

    private static func rawJSON() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "artwork-legs", withExtension: "json", subdirectory: "Fixtures"
        ) else {
            throw ArtworkFixtureError.fixtureMissing
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ArtworkFixtureError.undecodable("非 UTF-8")
        }
        let expanded = text.replacingOccurrences(of: coversToken, with: try coversHost)
        guard let data = expanded.data(using: .utf8) else {
            throw ArtworkFixtureError.undecodable("展开记号后无法编码")
        }
        return data
    }
}

// MARK: - 断言辅助（三种结论各一个，失败时必须把实际结论原样印出来）

/// `.resolved` 且地址逐字节等于预期（查询串差一个字符也算失败）。
func XCTAssertResolved(
    _ resolution: CovaArtworkResolution,
    equals expected: String,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .resolved(let url) = resolution else {
        XCTFail("期望 .resolved(\(expected))，实际 \(describe(resolution))。\(message)", file: file, line: line)
        return
    }
    XCTAssertEqual(url.absoluteString, expected, "解析后的地址不逐字节相等。\(message)", file: file, line: line)
}

func XCTAssertAbsent(
    _ resolution: CovaArtworkResolution,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .absent = resolution else {
        XCTFail("期望 .absent，实际 \(describe(resolution))。\(message)", file: file, line: line)
        return
    }
}

/// `.refused` 且点名的 host 等于预期。
@discardableResult
func XCTAssertRefused(
    _ resolution: CovaArtworkResolution,
    host expectedHost: String,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) -> String? {
    guard case .refused(let host) = resolution else {
        XCTFail("期望 .refused(host: \(expectedHost))，实际 \(describe(resolution))。\(message)", file: file, line: line)
        return nil
    }
    XCTAssertEqual(host, expectedHost, "拒绝点名的 host 不对。\(message)", file: file, line: line)
    return resolution.refusalMessage
}

/// 结论的可读形态（失败信息里要能看出是哪一档、哪个 host、哪个地址）。
private func describe(_ resolution: CovaArtworkResolution) -> String {
    switch resolution {
    case .absent: return ".absent"
    case .resolved(let url): return ".resolved(\(url.absoluteString))"
    case .refused(let host): return ".refused(host: \(host))"
    }
}
