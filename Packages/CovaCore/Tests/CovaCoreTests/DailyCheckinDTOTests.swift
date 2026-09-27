import XCTest
@testable import CovaCore

/// §5 P3「每日签到」的契约面与那一格的判据。
/// 形状取自 `web/src/app/api/me/checkin/route.ts`（GET 两键、POST 四键，未登录 401）。
final class DailyCheckinDTOTests: XCTestCase {

    private func state(_ json: String) -> DailyCheckinStateDto {
        try! JSONDecoder().decode(DailyCheckinStateDto.self, from: Data(json.utf8))
    }

    private func result(_ json: String) -> DailyCheckinResultDto {
        try! JSONDecoder().decode(DailyCheckinResultDto.self, from: Data(json.utf8))
    }

    func testGetReadsTheTwoRealKeys() throws {
        let dto = state(#"{"checkedInToday":false,"dailyAmount":20}"#)
        XCTAssertEqual(dto.checkedInToday, false)
        XCTAssertEqual(dto.dailyAmount, 20)
        XCTAssertTrue(dto.isDecidable)
    }

    func testUncheckedInWithAPositiveAmountIsAnOffer() {
        XCTAssertEqual(
            DailyCheckinRule.board(from: state(#"{"checkedInToday":false,"dailyAmount":20}"#)),
            .available(amount: 20)
        )
        XCTAssertEqual(DailyCheckinRule.actionTitle(.available(amount: 20)), "签到领 20 co")
    }

    func testCheckedInTodayIsDoneNotAnOffer() {
        let board = DailyCheckinRule.board(from: state(#"{"checkedInToday":true,"dailyAmount":20}"#))
        XCTAssertEqual(board, .done)
        XCTAssertEqual(DailyCheckinRule.actionTitle(board), "今天已签到")
    }

    func testMissingKeysAreUnknownRatherThanAFalsyDefault() {
        // 缺键折成 false 的后果很具体：屏上会摆一枚"签到领 0 co"的钮，点了什么也不会发生。
        XCTAssertEqual(DailyCheckinRule.board(from: state("{}")), .unknown)
        XCTAssertEqual(DailyCheckinRule.board(from: state(#"{"dailyAmount":20}"#)), .unknown)
        XCTAssertEqual(DailyCheckinRule.board(from: state(#"{"checkedInToday":false}"#)), .unknown)
        XCTAssertNil(DailyCheckinRule.actionTitle(.unknown), "读不懂时这一格整枚不出现")
    }

    func testWrongTypedValuesStayUnknownInsteadOfBecomingFalseOrZero() {
        let dto = state(#"{"checkedInToday":"yes","dailyAmount":"20"}"#)
        XCTAssertNil(dto.checkedInToday)
        XCTAssertNil(dto.dailyAmount)
        XCTAssertFalse(dto.isDecidable)
        XCTAssertEqual(DailyCheckinRule.board(from: dto), .unknown)
    }

    func testZeroAmountIsNotAnOffer() {
        // 额度是服务端配的（"额度万能钥匙可配"）。配成 0 时画"签到领 0 co"
        // 等于把一个什么都没有的动作说成有奖励。
        XCTAssertEqual(
            DailyCheckinRule.board(from: state(#"{"checkedInToday":false,"dailyAmount":0}"#)),
            .unknown
        )
    }

    func testNilReadingIsUnknown() {
        XCTAssertEqual(DailyCheckinRule.board(from: nil), .unknown)
    }

    func testPostResultWithAGrantClosesTheOffer() {
        let dto = result(#"{"ok":true,"alreadyCheckedIn":false,"granted":20,"balance":19335}"#)
        XCTAssertTrue(dto.succeeded)
        XCTAssertEqual(dto.granted, 20)
        XCTAssertEqual(dto.balance, 19335)
        XCTAssertEqual(DailyCheckinRule.board(fromResult: dto), .done)
    }

    func testPostResultWithoutOkTrueIsNotASuccess() {
        for json in [#"{"alreadyCheckedIn":true,"granted":20,"balance":1}"#,
                     #"{"ok":false,"granted":20,"balance":1}"#] {
            let dto = result(json)
            XCTAssertFalse(dto.succeeded, "没有 ok:true 就不许说「这一签成了」：\(json)")
            XCTAssertEqual(DailyCheckinRule.board(fromResult: dto), .unknown)
        }
    }

    func testPostResultMissingTheGrantNumberStaysUnknown() {
        // 服务端说成了，却没回发放数 ⇒ 不能替它宣布"已签到"（那可能是一句假话）。
        let dto = result(#"{"ok":true,"alreadyCheckedIn":true,"balance":19315}"#)
        XCTAssertNil(dto.granted)
        XCTAssertEqual(DailyCheckinRule.board(fromResult: dto), .unknown)
    }

    func testPathIsTheOneTheServerServes() {
        XCTAssertEqual(DailyCheckinStateDto.path, "/api/me/checkin")
    }
}
