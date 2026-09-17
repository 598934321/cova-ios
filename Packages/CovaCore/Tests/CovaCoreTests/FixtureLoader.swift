import Foundation
import XCTest

/// 本地 JSON fixture 加载器。
///
/// fixture 仅用于单测（脱敏后的字段结构），**不得作为验收证据**，不得包含真实凭证或签名 URL。
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(
                domain: "CovaCoreTests.Fixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "缺少 fixture：\(name).json"]
            )
        }
        return try Data(contentsOf: url)
    }

    static func value(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}

/// 断言编码结果与 fixture 的结构完全一致（键序无关）——
/// 用于把写请求体的**字段名**（尤其 D8 幂等键 `idempotencyKey`）钉死。
func XCTAssertEncodedJSONEqual(
    _ data: Data,
    fixture name: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let lhs = try canonicalJSON(data)
    let rhs = try canonicalJSON(Fixture.data(name))
    XCTAssertEqual(lhs, rhs, "编码结果与 fixture 不一致：\(name)", file: file, line: line)
}

private func canonicalJSON(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data)
    let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: sorted, as: UTF8.self)
}
