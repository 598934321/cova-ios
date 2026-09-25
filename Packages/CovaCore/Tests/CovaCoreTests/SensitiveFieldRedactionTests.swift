import CovaCore
import Foundation
import XCTest

/// TD-23：敏感字段（密码 / 签名 URL / 候选音频 URL）在全部描述与反射面都不得出现明文。
final class SensitiveFieldRedactionTests: XCTestCase {
    func testLoginRequestPasswordNeverRendersPlaintext() {
        let password = "LEAK-LOGIN-PASSWORD-42"
        let request = CovaLoginRequestDto(email: "tester@example.invalid", password: SecretString(password))
        let rendered = renderAllSurfaces(request)
        XCTAssertFalse(rendered.contains(password), "登录请求描述泄漏密码：\(rendered)")
        XCTAssertEqual(request.password.description, "<redacted>")
    }

    func testLoginRequestStillEncodesPasswordIntoRequestBody() throws {
        let request = CovaLoginRequestDto(email: "tester@example.invalid", password: SecretString("wire-password"))
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertTrue(json.contains("\"password\":\"wire-password\""), "密码必须能写入请求体：\(json)")
    }

    func testLoginResponseTokensNeverRenderPlaintextThroughDump() throws {
        let response = try Fixture.decode(CovaLoginResponseDto.self, "auth-login")
        let access = response.token.rawValue
        let refresh = response.refreshToken.rawValue
        let rendered = renderAllSurfaces(response)
        XCTAssertFalse(rendered.contains(access), "登录响应描述泄漏 access token：\(rendered)")
        XCTAssertFalse(rendered.contains(refresh), "登录响应描述泄漏 refresh token：\(rendered)")
    }

    func testDownloadItemSignedURLNeverRendersPlaintext() throws {
        let signedURL = "https://covalink.cn/api/downloads/dl-1/file?signature=LEAK-SIGNED-URL"
        let json = Data(
            #"{"trackId":"t1","downloadId":"dl-1","url":"\#(signedURL)","filename":"a.mp3","owned":true}"#.utf8
        )
        let item = try JSONDecoder().decode(DownloadItemDto.self, from: json)
        XCTAssertEqual(item.url?.rawValue, signedURL)

        let rendered = renderAllSurfaces(item)
        XCTAssertFalse(rendered.contains(signedURL), "下载条目描述泄漏签名 URL：\(rendered)")
        XCTAssertFalse(rendered.contains("signature=LEAK-SIGNED-URL"), "下载条目描述泄漏签名：\(rendered)")
    }

    func testDownloadResponseSignedURLNeverRendersPlaintext() throws {
        let signedURL = "https://covalink.cn/api/downloads/dl-1/file?signature=LEAK-RESPONSE-URL"
        let json = Data(
            #"{"batchId":"b1","downloads":[{"trackId":"t1","downloadId":"dl-1","url":"\#(signedURL)","filename":"a.mp3","owned":false}]}"#.utf8
        )
        let response = try JSONDecoder().decode(DownloadCheckoutResponseDto.self, from: json)
        let rendered = renderAllSurfaces(response)
        XCTAssertFalse(rendered.contains(signedURL), "checkout 响应描述泄漏签名 URL：\(rendered)")
    }

    func testGenerationCandidateAudioURLsNeverRenderPlaintext() throws {
        let audio = "https://cdn.invalid/audio/LEAK-AUDIO.mp3"
        let download = "https://cdn.invalid/audio/LEAK-AUDIO-DOWNLOAD.mp3?signature=LEAK"
        let json = Data(
            #"{"id":"cand-1","title":"t","audioUrl":"\#(audio)","coverUrl":"https://cdn.invalid/cover.png","duration":1.0,"audioDownloadUrl":"\#(download)","audioDownloadStatus":"ready","mediaReferenceId":"ref-1","favorite":false}"#.utf8
        )
        let candidate = try JSONDecoder().decode(GenerationCandidateDto.self, from: json)
        XCTAssertEqual(candidate.audioUrl?.rawValue, audio)
        XCTAssertEqual(candidate.audioDownloadUrl?.rawValue, download)

        let rendered = renderAllSurfaces(candidate)
        XCTAssertFalse(rendered.contains(audio), "候选描述泄漏 audioUrl：\(rendered)")
        XCTAssertFalse(rendered.contains(download), "候选描述泄漏 audioDownloadUrl：\(rendered)")
        XCTAssertFalse(rendered.contains("LEAK-AUDIO"), "候选描述泄漏音频地址片段：\(rendered)")
    }

    func testGenerationCandidateArrayAndOptionalRedaction() throws {
        let audio = "https://cdn.invalid/audio/LEAK-ARRAY.mp3"
        let json = Data(
            #"{"id":"cand-2","audioUrl":"\#(audio)","audioDownloadStatus":"pending"}"#.utf8
        )
        let candidate = try JSONDecoder().decode(GenerationCandidateDto.self, from: json)
        let surfaces = [
            String(describing: [candidate]),
            String(describing: Optional(candidate)),
            String(reflecting: [candidate.audioUrl]),
            dumpString([candidate])
        ]
        for surface in surfaces {
            XCTAssertFalse(surface.contains(audio), "数组/Optional 描述泄漏：\(surface)")
        }
    }

    func testErrorAndKeyDescriptionsCarryNoSignedURL() throws {
        let signedURL = "https://cdn.invalid/audio/LEAK-ERROR.mp3?signature=SECRET"
        let errors: [CovaAPIError] = [
            .transport(code: -1),
            .httpStatus(code: 403, apiCode: "FORBIDDEN"),
            .decoding(field: "url"),
            .invalidRequestURL,
            // 第 30 批③：新分支带着**点名的 host**（D23③ 要的就是这个），但 host 是
            // `egressHostLabel` 的口径 —— 只有那一台主机，签名串与路径段一概不带。
            .egressRefused(
                CovaEgressRefusal(
                    host: CovaEnvironment.egressHostLabel(of: URL(string: signedURL)!),
                    rule: .publicMediaLeg
                )
            ),
        ]
        for error in errors {
            let rendered = renderAllSurfaces(error) + error.redactedDescription
            XCTAssertFalse(rendered.contains(signedURL))
            XCTAssertFalse(rendered.contains("SECRET"))
            XCTAssertFalse(rendered.contains("LEAK-ERROR"))
            XCTAssertFalse(rendered.contains("signature"))
            // 拒绝面上屏的那一句：只有 host（"cdn.invalid" 允许出现，路径 `/audio/` 不允许）。
            if let refusal = error.egressRefusal {
                XCTAssertEqual(refusal.host, "cdn.invalid")
                XCTAssertFalse(error.redactedDescription.contains("/audio"))
            }
        }
    }
}
