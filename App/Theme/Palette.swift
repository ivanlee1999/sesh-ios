import Foundation
import SwiftUI
import SeshCore

extension Color {
    /**
     `#rgb` and `#rrggbb`, the two forms the palette is written in.

     A string that is neither falls back to the house accent rather than to
     black. Category colours come from the database, and a malformed one should
     look like a colour somebody chose, not like a hole in the interface.
     */
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        let parsed = Scanner(string: digits).scanHexInt64(&value)

        guard parsed, digits.count == 3 || digits.count == 6 else {
            // The house brick, written out rather than looked up, so this can
            // never end up asking itself the same question again.
            self.init(.sRGB, red: 0xc0 / 255, green: 0x52 / 255, blue: 0x2d / 255, opacity: 1)
            return
        }

        let r, g, b: Double
        if digits.count == 3 {
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/**
 The quiet-paper palette, carried over from the web app's tokens.

 Three grounds, not two. Light and dark are the usual pair; the third is the
 room a session runs in, which is not "dark mode" but the category's own colour
 taken down to a luminance of 0.02 — dark enough to sit in unlit, light enough
 that the hue still reads as a hue.
 */
struct Palette: Equatable {
    var background: Color
    var surface: Color
    var surfaceAlt: Color
    var text: Color
    var textSecondary: Color
    var textTertiary: Color
    var line: Color
    var lineStrong: Color
    var fill1: Color
    var fill2: Color
    var fill3: Color
    var warn: Color
    var good: Color

    static let light = Palette(
        background: Color(hex: "#f4f2ef"),
        surface: Color(hex: "#ffffff"),
        surfaceAlt: Color(hex: "#ebe8e4"),
        text: Color(hex: "#1d1c1b"),
        textSecondary: Color(hex: "#5d5955"),
        textTertiary: Color(hex: "#6f6a65"),
        line: Color(hex: "#1d1c1b").opacity(0.10),
        lineStrong: Color(hex: "#1d1c1b").opacity(0.18),
        fill1: Color(hex: "#1d1c1b").opacity(0.05),
        fill2: Color(hex: "#1d1c1b").opacity(0.08),
        fill3: Color(hex: "#1d1c1b").opacity(0.12),
        warn: Color(hex: "#b0260a"),
        good: Color(hex: "#3b8a68")
    )

    static let dark = Palette(
        background: Color(hex: "#161514"),
        surface: Color(hex: "#1f1e1c"),
        surfaceAlt: Color(hex: "#2a2826"),
        text: Color(hex: "#f2efeb"),
        textSecondary: Color(hex: "#a9a49e"),
        textTertiary: Color(hex: "#8f8a84"),
        line: Color(hex: "#f2efeb").opacity(0.10),
        lineStrong: Color(hex: "#f2efeb").opacity(0.20),
        fill1: Color(hex: "#f2efeb").opacity(0.06),
        fill2: Color(hex: "#f2efeb").opacity(0.10),
        fill3: Color(hex: "#f2efeb").opacity(0.15),
        warn: Color(hex: "#ff9a86"),
        good: Color(hex: "#6fbf98")
    )

    /// The session room: the dark palette, standing on the category's own ground.
    static func session(ground: String) -> Palette {
        var palette = Palette.dark
        palette.background = Color(hex: ground)
        // Lifted, because the tertiary text has to clear a ground that is no
        // longer neutral.
        palette.textTertiary = Color(hex: "#9b968f")
        return palette
    }
}

/// The accent, and the ink that stays legible on it. Computed by `SeshCore.Accent`.
struct Theme: Equatable {
    var palette: Palette
    var accent: Color
    var accentInk: Color
    var ground: Color
    var isDark: Bool

    static func make(categoryColor: String, dark: Bool, inSession: Bool) -> Theme {
        let accent = Accent.accent(for: categoryColor, dark: dark || inSession)
        return Theme(
            palette: inSession ? .session(ground: accent.ground) : (dark ? .dark : .light),
            accent: Color(hex: accent.base),
            accentInk: Color(hex: accent.on),
            ground: Color(hex: accent.ground),
            isDark: dark || inSession
        )
    }

    static let fallback = Theme.make(categoryColor: Accent.defaultAccent, dark: false, inSession: false)
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.fallback
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// The eight swatches a category can be given, matching the web app's set.
enum Swatches {
    static let all = [
        "#c0522d", "#c98a1e", "#4f8f6e", "#3b6fa8",
        "#7a5ea8", "#b8465c", "#2b2927", "#8a857f",
    ]
}

enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 16
}

enum Motion {
    /// The house easing — everything that moves uses one of these two.
    static let standard = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.32)
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.72)
    static let quick = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.2)
}
