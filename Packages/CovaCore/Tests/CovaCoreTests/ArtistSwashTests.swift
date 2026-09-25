import Foundation
import XCTest

@testable import CovaCore

/// 16 §3/§5/§7「头区主色铺底」的解析与强度档（对应 `ArtistSwash`）。
///
/// §7 那条待裁决（`colorPalette` 的字符串格式契约里**没定义**）在这个面上是这样收口的：
/// 只认 `#RGB` / `#RRGGBB`，别的形态一律"没有主色"，由视图侧回落 `color.surface`。
/// 所以这一组测试的大多数用例都是**否定式**的 —— 它们钉的是"什么不许被当成颜色"。
final class ArtistSwashTests: XCTestCase {

    /// 线上真实形态（2026-09-25 只读核对 `/api/tracks` 内嵌 `artist.colorPalette`）：
    /// 一个 **JSON 字符串数组**，如 `"[\"#1B1464\",\"#F4A259\"]"` ⇒ 取第一个合法的。
    func testParsesJSONArrayStringShape() {
        XCTAssertEqual(
            ArtistSwash.swatch(fromPalette: "[\"#1B1464\",\"#F4A259\"]"),
            ArtistSwash.Swatch(red: 0x1B / 255, green: 0x14 / 255, blue: 0x64 / 255)
        )
    }

    /// 裸 `#RRGGBB` / `#RGB`（3 位按 CSS 规则翻倍展开）。
    func testParsesBareSixAndThreeDigitForms() {
        XCTAssertEqual(
            ArtistSwash.swatch(fromPalette: "#FF6B00"),
            ArtistSwash.Swatch(red: 1, green: 0x6B / 255, blue: 0)
        )
        XCTAssertEqual(
            ArtistSwash.swatch(fromPalette: "#f60"),
            ArtistSwash.Swatch(red: 1, green: 0x66 / 255, blue: 0)
        )
    }

    /// 大小写都认（十六进制本身不分大小写）。
    func testHexDigitsAreCaseInsensitive() {
        XCTAssertEqual(
            ArtistSwash.swatch(fromPalette: "#0aB1cD"),
            ArtistSwash.Swatch(red: 0x0A / 255, green: 0xB1 / 255, blue: 0xCD / 255)
        )
    }

    /// **不许被当成颜色的**（§7 的"不得尝试任意字符串当色值"，16 §9 判据第 3 条）：
    /// 命名色、4/5/8 位这类没见过的长度、空串、纯空白、`null` 字面量、没有任何 `#` 的串。
    func testRejectsEverythingThatIsNotAWellFormedHex() {
        for raw in [
            "red", "blue", "transparent", "", "   ", "null", "#", "#GG0000",
            "#12", "#1234", "#12345", "#1234567", "#12345678",   // 8 位 ARGB 也不截前 6 位
        ] {
            XCTAssertNil(ArtistSwash.swatch(fromPalette: raw), "不该把 \(raw.debugDescription) 当色值")
        }
        XCTAssertNil(ArtistSwash.swatch(fromPalette: nil))
    }

    /// 前面的形态不对、后面出现一个合法段 ⇒ 取那个合法的（"整串不是颜色"与
    /// "串里没有一个颜色"是两件事：`#AABBCCDD` 之后跟的 `#123456` 是可用的事实）。
    func testSkipsMalformedRunAndTakesNextWellFormedOne() {
        XCTAssertEqual(
            ArtistSwash.swatch(fromPalette: "[\"#12345678\",\"#00FF00\"]"),
            ArtistSwash.Swatch(red: 0, green: 1, blue: 0)
        )
    }

    /// 分量必须落在 0…1：SwiftUI 拿到越界分量不会报错，只会画出别的东西。
    func testComponentsStayInUnitRange() {
        let swatch = ArtistSwash.swatch(fromPalette: "#000000")
        XCTAssertEqual(swatch, ArtistSwash.Swatch(red: 0, green: 0, blue: 0))
        for raw in ["#FFFFFF", "#fff"] {
            guard let parsed = ArtistSwash.swatch(fromPalette: raw) else {
                return XCTFail("\(raw) 应该能解")
            }
            XCTAssertEqual([parsed.red, parsed.green, parsed.blue].allSatisfy { (0...1).contains($0) }, true)
        }
    }

    // MARK: 强度与动效档

    /// §5 的 TG-40：**Light 12% / Dark 22%**，两档不同值是 spec 的原话
    /// （同一个透明度压在白底与黑底上观感不等价），不是随手调出来的。
    func testOverlayAlphasAreTheTwoSpecValues() {
        XCTAssertEqual(ArtistSwash.overlayLightAlpha, 0.12)
        XCTAssertEqual(ArtistSwash.overlayDarkAlpha, 0.22)
        XCTAssertGreaterThan(ArtistSwash.overlayDarkAlpha, ArtistSwash.overlayLightAlpha)
    }

    /// 铺底的交叉淡入 = `motion.duration.hero`（700ms）。tokens 里**没有** TG-40 这一档，
    /// 但 `hero` 是有的 ⇒ 复用既有的那一档，而不是新造一个数。
    func testCrossFadeReusesHeroMotionToken() {
        XCTAssertEqual(ArtistSwash.crossFadeDuration, 0.7)
    }
}
