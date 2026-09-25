import CovaCore
import Foundation
import XCTest

/// `LoginFailureCopy.swift` 的口径（10 §4 错误表 / §8 文案清单 / §9 验收第 2 条）。
///
/// 钉的是**话术本身**，不是屏幕：`AppSession` 的调用点由协调者接线（本轮不许改那个文件），
/// 所以这里把「撤掉哪一行会红」写在注释里，让接线之后立刻有回归保护。
final class LoginFailureCopyTests: XCTestCase {

    /// 服务端可控字符串（`apiCode` / `field` / `localizedDescription` 都拿它当值）：
    /// 任何一条输出里出现它的任一 ASCII 字符 ⇒ 服务端原文上了屏。
    private let serverPayload = "ACCT_NOT_FOUND-5741"

    // MARK: - 凭证分支（防枚举）

    func testCredentialRejectionIsOneFixedWordingForEveryRelevantShape() {
        XCTAssertEqual(LoginFailureCopy.message(for: CovaAPIError.unauthorized(apiCode: serverPayload)), "邮箱或密码不正确")
        // 400 与 401 必须**同一句**：两句不同措辞 = 账号存在性预言机。
        XCTAssertEqual(
            LoginFailureCopy.message(for: CovaAPIError.httpStatus(code: 400, apiCode: serverPayload)), "邮箱或密码不正确")
        XCTAssertEqual(
            LoginFailureCopy.message(for: CovaAPIError.httpStatus(code: 401, apiCode: serverPayload)), "邮箱或密码不正确")
        // 归一前/归一后同一条错误的话术必须一致（`normalize` 对 `CovaAPIError` 是原样返回）。
        XCTAssertEqual(
            LoginFailureCopy.classify(.unauthorized(apiCode: nil)),
            LoginFailureCopy.message(for: CovaAPIError.unauthorized(apiCode: nil)))
    }

    func testFourOhOneWordingIsNeverTheUnreachableWordingAndViceVersa() {
        let credential = LoginFailureCopy.classify(.unauthorized(apiCode: nil))
        let unreachable = LoginFailureCopy.classify(.timeout)
        XCTAssertNotEqual(credential, unreachable)
        XCTAssertNotEqual(credential, LoginFailureCopy.offline)
        // 反向：服务器没答上来的时候，屏上不许出现「密码」二字。
        // `.egressRefused`（第 30 批③）是这条判据最容易被忘掉的一格：那一次出站**根本没发生**，
        // 服务器从没比较过凭证 ⇒ 说「邮箱或密码不正确」会让用户去改一个本来正确的密码。
        for error: CovaAPIError in [.offline, .timeout, .cancelled, .transport(code: 7), .invalidResponse,
                                    .decoding(field: serverPayload), .sessionChanged, .credentialReadFailed,
                                    .invalidRequestURL,
                                    .egressRefused(CovaEgressRefusal(host: "evil.invalid"))] {
            XCTAssertFalse(LoginFailureCopy.classify(error).contains("密码"), "\(error)")
            XCTAssertFalse(LoginFailureCopy.classify(error).contains("邮箱"), "\(error)")
        }
        // 一次真·出口拒绝（`normalize` 之后）也必须拿到那句中性话术。
        let refusal = CovaEgressRefusal(host: "evil.invalid", rule: .credentialLeg)
        XCTAssertEqual(LoginFailureCopy.message(for: refusal), "登录没成功，检查一下网络再试")
    }

    // MARK: - 离线 / 风控 / 其它状态码

    func testOfflineAndRiskControlGetTheirOwnSpecWording() {
        XCTAssertEqual(LoginFailureCopy.classify(.offline), "离线：登录需要联网")
        XCTAssertEqual(
            LoginFailureCopy.classify(.httpStatus(code: 403, apiCode: serverPayload)), "这个账号需要网页端继续验证")
        // §4 只为 401/403 钉了话术；其余状态码（含 429 限流、5xx）落那句中性的「检查网络」。
        for code in [404, 409, 418, 422, 429, 500, 503] {
            XCTAssertEqual(
                LoginFailureCopy.classify(.httpStatus(code: code, apiCode: serverPayload)),
                "登录没成功，检查一下网络再试", "code \(code)")
        }
    }

    // MARK: - 不泄漏服务端原文

    func testNoBranchEchoesAServerString() {
        let all: [CovaAPIError] = [
            .offline, .timeout, .cancelled, .transport(code: 12029), .invalidResponse,
            .invalidRequestURL, .sessionChanged, .credentialReadFailed,
            .egressRefused(CovaEgressRefusal(host: "covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com")),
            .unauthorized(apiCode: serverPayload),
            .httpStatus(code: 400, apiCode: serverPayload),
            .httpStatus(code: 401, apiCode: serverPayload),
            .httpStatus(code: 403, apiCode: serverPayload),
            .httpStatus(code: 500, apiCode: serverPayload),
            .decoding(field: serverPayload),
        ]
        for error in all {
            let text = LoginFailureCopy.message(for: error)
            XCTAssertFalse(text.contains(serverPayload), "\(error) → \(text)")
            // 本仓这一族的硬判据：**任何**分支的上屏串都不含 ASCII 字母（四句话术全是中文）。
            XCTAssertFalse(
                text.unicodeScalars.contains { CharacterSet.asciiLetters.contains($0) },
                "\(error) → \(text)")
            XCTAssertFalse(text.isEmpty)
        }
    }

    /// 表外/底层错误也必须被接住：`normalize` 把非 `CovaAPIError` 折进传输档，
    /// 话术**不得**来自 `localizedDescription`。
    func testForeignErrorsNeverSurfaceTheirOwnDescription() {
        struct ServerShapedError: Error, LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        let foreign = ServerShapedError(message: "HTTP 401 unauthorized: user ACCT_NOT_FOUND-5741 not found")
        let text = LoginFailureCopy.message(for: foreign)
        XCTAssertEqual(text, "登录没成功，检查一下网络再试")
        XCTAssertFalse(text.contains("401"))

        let cancelled = LoginFailureCopy.message(for: CancellationError())
        XCTAssertEqual(cancelled, "登录没成功，检查一下网络再试")

        // NSURLErrorDomain 的两条腿：断网 → 离线话术；超时 → 检查网络话术。
        let offline = URLError(.notConnectedToInternet) as NSError
        XCTAssertEqual(LoginFailureCopy.message(for: offline), "离线：登录需要联网")
        XCTAssertEqual(
            LoginFailureCopy.message(for: URLError(.timedOut) as NSError), "登录没成功，检查一下网络再试")
    }

    /// 四句话术本身：逐字对齐 §8 文案清单，且**互不相同**（两条重复会让上面的"可区分"判据空转）。
    func testTheFourFixedStringsAreDistinctAndVerbatim() {
        let words = [
            LoginFailureCopy.invalidCredentials, LoginFailureCopy.serverUnreachable,
            LoginFailureCopy.offline, LoginFailureCopy.webVerificationRequired,
        ]
        XCTAssertEqual(words, [
            "邮箱或密码不正确", "登录没成功，检查一下网络再试", "离线：登录需要联网", "这个账号需要网页端继续验证",
        ])
        XCTAssertEqual(Set(words).count, 4)
    }

    /// 当前 12 个分支逐个过一遍：话术只能来自 §8 那四句（新增 case 时**编译期**就会红 ——
    /// `classify` 刻意不写 `default`，所以这里只兜"新分支被随手挂到某句上"之外的语义）。
    /// 上面那些数组是**手写的**（`CovaAPIError` 不是 `CaseIterable`，为的是新增分支时
    /// 必须回来加一行 —— 又是一个"漏表态就红"的设计），所以这条数量断言也一起钉着。
    func testEveryErrorCaseResolvesToAWordingFromTheClosedList() {
        let all: [CovaAPIError] = [
            .offline, .timeout, .cancelled, .transport(code: 1), .invalidResponse,
            .invalidRequestURL, .sessionChanged, .credentialReadFailed,
            .egressRefused(CovaEgressRefusal(host: "evil.invalid", rule: .publicMediaLeg)),
            .unauthorized(apiCode: nil), .httpStatus(code: 401, apiCode: nil), .decoding(field: nil),
        ]
        let allowed: Set<String> = [
            LoginFailureCopy.invalidCredentials, LoginFailureCopy.serverUnreachable,
            LoginFailureCopy.offline, LoginFailureCopy.webVerificationRequired,
        ]
        for error in all { XCTAssertTrue(allowed.contains(LoginFailureCopy.classify(error)), "\(error)") }
        XCTAssertEqual(all.count, 12, "分支清单与 `CovaAPIError` 的 case 数必须同步（新增分支要回来表态）")
    }
}

private extension CharacterSet {
    static let asciiLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
}
