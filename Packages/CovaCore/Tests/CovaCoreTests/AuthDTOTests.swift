@testable import CovaCore
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
}
