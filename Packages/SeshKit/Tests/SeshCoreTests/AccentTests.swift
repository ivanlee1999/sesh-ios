import XCTest
@testable import SeshCore

/**
 The web app's `accent.test.ts`, ported case for case.

 The point is not that the Swift works; it is that it agrees. Both clients
 colour the same category from the same rule, and the only way to know they
 still do is to hold them to the same expectations.
 */
final class AccentTests: XCTestCase {
    /// Written out again here so the tests do not trust the module's own maths.
    private func luminance(_ hex: String) -> Double {
        let digits = Array(hex.dropFirst())
        let channels = stride(from: 0, to: 6, by: 2).map { i -> Double in
            let v = Double(Int(String(digits[i...(i + 1)]), radix: 16) ?? 0) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let hi = max(luminance(a), luminance(b))
        let lo = min(luminance(a), luminance(b))
        return (hi + 0.05) / (lo + 0.05)
    }

    private func channels(_ hex: String) -> [Int] {
        let digits = Array(hex.dropFirst())
        return stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0...($0 + 1)]), radix: 16) ?? 0 }
    }

    func testLeavesAColourThatAlreadyReadsAlone() {
        XCTAssertEqual(Accent.accent(for: "#3B6FA8", dark: false).base, "#3b6fa8")
        XCTAssertEqual(Accent.accent(for: "#C8943A", dark: true).base, "#c8943a")
    }

    func testDarkensUntilWhiteClearsBodyText() {
        let light = Accent.accent(for: "#6E86B0", dark: false)
        XCTAssertEqual(light.on, "#ffffff")
        XCTAssertGreaterThanOrEqual(contrast(light.base, "#ffffff"), 4.5)
        // Nudged, not replaced: still the same slate blue.
        XCTAssertGreaterThan(luminance(light.base), 0.15)
    }

    func testLiftsANearBlackCategoryOffTheFocusGround() {
        let dark = Accent.accent(for: "#2d2b2b", dark: true)
        XCTAssertNotEqual(dark.base, "#2d2b2b")
        XCTAssertGreaterThanOrEqual(luminance(dark.base), 0.28)
    }

    func testDarkensAColourThatWouldVanishIntoThePaper() {
        XCTAssertLessThanOrEqual(luminance(Accent.accent(for: "#ffe600", dark: false).base), 0.5)
    }

    func testInkAlwaysClearsBodyTextOnItsAccent() {
        for color in ["#ec3013", "#C8943A", "#7E9476", "#2d2b2b", "#ffe600", "#9b9797", "#3b6fa8", "#c4552f"] {
            for dark in [false, true] {
                let theme = Accent.accent(for: color, dark: dark)
                XCTAssertGreaterThanOrEqual(
                    contrast(theme.base, theme.on), 4.5,
                    "\(color) dark=\(dark) produced unreadable ink"
                )
            }
        }
    }

    func testAccentStaysLegibleAsAMarkOnItsGround() {
        for color in ["#ec3013", "#C8943A", "#7E9476", "#2d2b2b", "#ffe600", "#9b9797"] {
            XCTAssertGreaterThanOrEqual(contrast(Accent.accent(for: color, dark: false).base, "#f4f2ef"), 3)
            XCTAssertGreaterThanOrEqual(contrast(Accent.accent(for: color, dark: true).base, "#161514"), 3)
        }
    }

    func testFallsBackRatherThanEmittingABrokenColour() {
        XCTAssertEqual(Accent.accent(for: "not a colour", dark: false).base, Accent.defaultAccent)
        XCTAssertEqual(Accent.accent(for: "", dark: false).base, Accent.defaultAccent)
    }

    func testReadsThreeDigitHex() {
        XCTAssertEqual(Accent.accent(for: "#05a", dark: false).base, "#0055aa")
    }

    func testReadableInk() {
        XCTAssertEqual(Accent.readableInk("#ec3013"), "#ffffff")
        XCTAssertEqual(Accent.readableInk("#C8943A"), "#1d1c1b")
    }

    func testGroundLandsEveryCategoryAtOneDepth() {
        // A gold and a slate blue are far apart in luminance to begin with; the
        // room they become must not be.
        for color in ["#BE6E45", "#C8943A", "#7E9476", "#6E86B0", "#5E9AA0"] {
            XCTAssertLessThanOrEqual(luminance(Accent.ground(for: color)), 0.02)
            XCTAssertGreaterThan(luminance(Accent.ground(for: color)), 0.012)
        }
    }

    func testGroundKeepsTheHueItCameFrom() {
        let warm = channels(Accent.ground(for: "#BE6E45"))
        let cool = channels(Accent.ground(for: "#6E86B0"))
        XCTAssertGreaterThan(warm[0], warm[2])
        XCTAssertGreaterThan(cool[2], cool[0])
    }

    func testAccentStaysLegibleOnItsOwnRoom() {
        for color in ["#BE6E45", "#C8943A", "#7E9476", "#6E86B0", "#2d2b2b"] {
            XCTAssertGreaterThanOrEqual(
                contrast(Accent.accent(for: color, dark: true).base, Accent.ground(for: color)), 3
            )
        }
    }

    func testPairCarriesTheRoomOnBothThemes() {
        let pair = Accent.pair(for: "#6E86B0")
        XCTAssertEqual(pair.dark.ground, Accent.ground(for: "#6E86B0"))
        XCTAssertEqual(pair.light.ground, pair.dark.ground)
        XCTAssertEqual(pair.light.on, "#ffffff")
        XCTAssertEqual(pair.dark.on, "#1d1c1b")
    }
}
