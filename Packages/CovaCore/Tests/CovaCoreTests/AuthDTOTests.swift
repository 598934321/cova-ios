import CovaCore
import XCTest

final class AuthDTOTests: XCTestCase {
    func testDecodesMeResponse() throws {
        let me = try Fixture.decode(CovaMeResponse.self, "auth-me")
        XCTAssertEqual(me.user.id, "user-0001")
        XCTAssertEqual(me.user.name, "测试用户")
        XCTAssertEqual(me.user.role, "user")
        XCTAssertEqual(me.user.email, "tester@example.invalid")
        XCTAssertNil(me.user.phone)
        XCTAssertEqual(me.user.covaId, "COVA-0001")
        XCTAssertFalse(me.user.isArtist)
        XCTAssertFalse(me.user.isPartner)

        XCTAssertEqual(me.entitlements.plan, .free)
        XCTAssertEqual(me.entitlements.creditsBalance, 120)
        XCTAssertEqual(me.entitlements.monthlyCredits, 100)
        XCTAssertTrue(me.entitlements.canDownload)
        XCTAssertTrue(me.entitlements.canUseCovaAI)
        XCTAssertFalse(me.entitlements.canRequestProjects)
        XCTAssertNil(me.entitlements.subscriptionId)
        XCTAssertNil(me.entitlements.activeUntil)
    }

    func testToleratesMissingOptionalIdentityFields() throws {
        let json = Data(
            #"{"user":{"id":"u1","name":"n","role":"admin","isArtist":true,"isPartner":true},"entitlements":{"plan":"pro","creditsBalance":0,"monthlyCredits":0,"canDownload":false,"canUseCovaAI":false,"canRequestProjects":false}}"#.utf8
        )
        let me = try JSONDecoder().decode(CovaMeResponse.self, from: json)
        XCTAssertNil(me.user.email)
        XCTAssertNil(me.user.covaId)
        XCTAssertNil(me.user.phone)
        XCTAssertTrue(me.user.isArtist)
        XCTAssertTrue(me.user.isPartner)
        XCTAssertEqual(me.entitlements.plan, .pro)
    }

    func testIgnoresUnknownFields() throws {
        let json = Data(
            #"{"user":{"id":"u1","name":"n","role":"user","isArtist":false,"isPartner":false,"unknownUserField":1},"entitlements":{"plan":"enterprise","creditsBalance":1,"monthlyCredits":1,"canDownload":true,"canUseCovaAI":true,"canRequestProjects":true,"futureField":"x"},"nameChange":{"canChange":true}}"#.utf8
        )
        let me = try JSONDecoder().decode(CovaMeResponse.self, from: json)
        XCTAssertEqual(me.entitlements.plan, .enterprise)
    }

    func testDecodesAllPlans() throws {
        for (raw, expected) in [
            ("free", CovaPlan.free),
            ("creator", CovaPlan.creator),
            ("pro", CovaPlan.pro),
            ("enterprise", CovaPlan.enterprise)
        ] {
            let plan = try JSONDecoder().decode(CovaPlan.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(plan, expected)
        }
    }

    func testUnknownPlanFailsDecoding() {
        XCTAssertThrowsError(try JSONDecoder().decode(CovaPlan.self, from: Data("\"platinum\"".utf8)))
    }

    func testMissingRequiredUserFieldFailsDecoding() {
        let json = Data(
            #"{"user":{"name":"n","role":"user","isArtist":false,"isPartner":false},"entitlements":{"plan":"free","creditsBalance":0,"monthlyCredits":0,"canDownload":false,"canUseCovaAI":false,"canRequestProjects":false}}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(CovaMeResponse.self, from: json))
    }

    // MARK: - 登录 / 刷新 / 登出（契约目标形态，NEEDS-1）

    func testDecodesLoginResponseContractTargetShape() throws {
        let response = try Fixture.decode(CovaLoginResponseDto.self, "auth-login")
        XCTAssertEqual(response.user.id, "user-0001")
        XCTAssertEqual(response.user.name, "测试用户")
        XCTAssertEqual(response.token.rawValue, "ACCESS_TOKEN_PLACEHOLDER")
        XCTAssertEqual(response.refreshToken.rawValue, "REFRESH_TOKEN_PLACEHOLDER")
        XCTAssertEqual(response.expiresIn, 7200)
    }

    /// M2：承载 token 的响应 DTO 任何时候都不得把明文渲染出来（描述/反射/Mirror 三面）。
    func testLoginResponseTokensNeverRenderPlaintext() throws {
        let response = try Fixture.decode(CovaLoginResponseDto.self, "auth-login")
        let access = response.token.rawValue
        let refresh = response.refreshToken.rawValue
        XCTAssertFalse(access.isEmpty)
        XCTAssertFalse(refresh.isEmpty)

        let surfaces = [
            String(reflecting: response),
            "\(response)",
            String(describing: response.token),
            String(reflecting: response.token),
            String(describing: [response.token, response.refreshToken])
        ]
        for surface in surfaces {
            XCTAssertFalse(surface.contains(access), "泄漏 access token：\(surface)")
            XCTAssertFalse(surface.contains(refresh), "泄漏 refresh token：\(surface)")
        }
        for child in Mirror(reflecting: response).children {
            XCTAssertFalse(String(describing: child.value).contains(access))
            XCTAssertFalse(String(describing: child.value).contains(refresh))
        }
    }

    func testLoginRequestEncodesContractKeys() throws {
        let request = CovaLoginRequestDto(email: "tester@example.invalid", password: SecretString("placeholder"))
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/login-request"
        )
    }

    func testDecodesRefreshAndLogoutResponses() throws {
        let refresh = try Fixture.decode(CovaRefreshResponseDto.self, "auth-refresh")
        XCTAssertEqual(refresh.token.rawValue.isEmpty, false)
        XCTAssertEqual(refresh.refreshToken.rawValue.isEmpty, false)
        XCTAssertEqual(refresh.expiresIn, 7200)
        XCTAssertFalse(String(reflecting: refresh).contains(refresh.token.rawValue))

        let logout = try Fixture.decode(CovaLogoutResponseDto.self, "auth-logout")
        XCTAssertEqual(logout.message, "已退出登录")

        let empty = try JSONDecoder().decode(CovaLogoutResponseDto.self, from: Data("{}".utf8))
        XCTAssertNil(empty.message)
    }

    /// NEEDS-1 的处置改写（2026-09-22，D20）：真实 `POST /api/auth/login` 的 `user` 当前只给
    /// `{id,email,name,role}`。旧口径把这一形态钉成「必须解码失败」⇒ 真机上**永远登不进来**，
    /// 登录后的播放/上报链路无从验收。新口径分两侧同时钉住：
    ///   · 容忍侧：身份标记（`isArtist`/`isPartner`）与可选标识（`covaId`/`phone`）缺席可读，
    ///     且布尔缺席一律读成 `false` —— **保守方向**，绝不因后端缺字段而放大权限；
    ///   · 严格侧：`id / name / role` 缺任一个照旧抛 `.decoding(field:)`，不许猜出用户身份。
    func testLoginToleratesRealBackendUserShapeButKeepsIdentityStrict() throws {
        let partial = Data(
            #"{"user":{"id":"u1","email":"a@b.c","name":"n","role":"user"},"token":"t","refreshToken":"r","expiresIn":1}"#.utf8
        )
        let response = try JSONDecoder().decode(CovaLoginResponseDto.self, from: partial)
        XCTAssertEqual(response.user.id, "u1")
        XCTAssertEqual(response.user.email, "a@b.c")
        XCTAssertEqual(response.token.rawValue, "t")
        XCTAssertFalse(response.user.isArtist, "缺席的身份标记必须读成 false（保守），不得读成 true")
        XCTAssertFalse(response.user.isPartner, "缺席的身份标记必须读成 false（保守），不得读成 true")
        XCTAssertNil(response.user.covaId)
        XCTAssertNil(response.user.phone)

        let noID = Data(
            #"{"user":{"email":"a@b.c","name":"n","role":"user"},"token":"t","refreshToken":"r","expiresIn":1}"#.utf8
        )
        let noName = Data(
            #"{"user":{"id":"u1","email":"a@b.c","role":"user"},"token":"t","refreshToken":"r","expiresIn":1}"#.utf8
        )
        let noRole = Data(
            #"{"user":{"id":"u1","email":"a@b.c","name":"n"},"token":"t","refreshToken":"r","expiresIn":1}"#.utf8
        )
        for (json, field) in [(noID, "id"), (noName, "name"), (noRole, "role")] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(CovaLoginResponseDto.self, from: json),
                "\(field) 缺席必须报错：身份不允许猜"
            ) { error in
                guard let decoding = error as? DecodingError else { return XCTFail("应为 DecodingError") }
                XCTAssertEqual(CovaAPIError.classify(decoding: decoding), .decoding(field: field))
            }
        }
    }
}
