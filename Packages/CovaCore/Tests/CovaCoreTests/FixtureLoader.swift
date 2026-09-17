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
