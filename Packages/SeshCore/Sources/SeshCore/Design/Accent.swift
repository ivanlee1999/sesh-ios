import Foundation

/**
 The accent, derived from a single colour.

 A direct port of the web app's `lib/accent.ts`, kept faithful down to the
 rounding, because the two clients have to arrive at the same hex for the same
 category. If they did not, the same session would be one colour on the phone
 and a visibly different one on the laptop, and the person would be right to
 think something was broken.

 It decides the two things a palette cannot work out on its own: how far a
 colour has to move to stay legible on the ground behind it, and which ink to
 draw on top of it.
 */
public struct AccentTheme: Equatable, Sendable {
    /// The colour every accent step is mixed from.
    public let base: String
    /// The ink that stays legible on a surface filled with `base`.
    public let on: String
    /// The room a running session sits in: the same colour taken all the way down.
    public let ground: String

    public init(base: String, on: String, ground: String) {
        self.base = base
        self.on = on
        self.ground = ground
    }
}

public struct AccentPair: Equatable, Sendable {
    public let light: AccentTheme
    public let dark: AccentTheme
}

public enum Accent {
    /// The brick the interface falls back to when no category has been chosen.
    public static let defaultAccent = "#c0522d"

    /// Matches the light ground's text colour.
    public static let ink = "#1d1c1b"
    public static let paper = "#ffffff"

    /// The chrome on the two plain grounds, when no session is tinting one.
    public static let themeColorLight = "#f4f2ef"
    public static let themeColorDark = "#161514"

    /**
     A category colour dark enough to vanish into the focus ground is lightened
     until it clears this. Luminance, not lightness — a saturated yellow and a
     saturated blue of the same "lightness" do not read the same.
     */
    static let darkGroundMinLuminance = 0.28

    /// WCAG AA for large text, the bar a colour clears for white to be considered at all.
    static let largeTextContrast = 3.0
    /// WCAG AA for body text, which is what a label on an accent fill is.
    static let bodyTextContrast = 4.5

    /// The luminance under which white ink reaches `bodyTextContrast`.
    static let lightGroundMaxLuminance = 1.05 / bodyTextContrast - 0.05

    /**
     How dark the room is while a session runs. A luminance rather than a mix
     percentage, because the same percentage of black leaves a gold and a slate
     blue at visibly different darknesses — and the ground has to be one depth
     whatever category you are in.
     */
    static let sessionGroundLuminance = 0.02

    // ── Colour arithmetic ───────────────────────────────────────────────

    typealias RGB = (r: Int, g: Int, b: Int)

    static func parseHex(_ value: String) -> RGB? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.hasPrefix("#") else { return nil }
        let digits = String(hex.dropFirst())
        let allowed = Set("0123456789abcdef")
        guard digits.allSatisfy({ allowed.contains($0) }) else { return nil }

        func byte(_ s: Substring) -> Int { Int(s, radix: 16) ?? 0 }

        if digits.count == 3 {
            let c = Array(digits)
            return (byte("\(c[0])\(c[0])"), byte("\(c[1])\(c[1])"), byte("\(c[2])\(c[2])"))
        }
        if digits.count == 6 {
            let c = Array(digits)
            return (byte("\(c[0])\(c[1])"), byte("\(c[2])\(c[3])"), byte("\(c[4])\(c[5])"))
        }
        return nil
    }

    static func toHex(_ rgb: RGB) -> String {
        func channel(_ value: Int) -> String {
            String(format: "%02x", min(255, max(0, value)))
        }
        return "#\(channel(rgb.r))\(channel(rgb.g))\(channel(rgb.b))"
    }

    /**
     Rounded to whole channels, because that is what actually ships: the search
     below has to test the colour that will be written, not a float that clears
     the bar and then loses it to rounding.
     */
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        func channel(_ from: Int, _ to: Int) -> Int {
            Int((Double(from) + (Double(to) - Double(from)) * t).rounded())
        }
        return (channel(a.r, b.r), channel(a.g, b.g), channel(a.b, b.b))
    }

    /// WCAG relative luminance.
    static func luminance(_ rgb: RGB) -> Double {
        func component(_ value: Int) -> Double {
            let v = Double(value) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * component(rgb.r) + 0.7152 * component(rgb.g) + 0.0722 * component(rgb.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        let hi = max(la, lb)
        let lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /**
     The smallest move toward `target` that satisfies `ok`.

     Mixing toward white raises luminance and toward black lowers it, both
     monotonically, so a bisection finds the least correction that works — a
     colour already legible is returned untouched, and one that needs help is
     nudged rather than washed out.
     */
    static func nudge(_ rgb: RGB, toward target: RGB, until ok: (Double) -> Bool) -> RGB {
        if ok(luminance(rgb)) { return rgb }
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if ok(luminance(mix(rgb, target, mid))) { hi = mid } else { lo = mid }
        }
        return mix(rgb, target, hi)
    }

    // ── The public answers ──────────────────────────────────────────────

    /**
     The ink for type on any colour fill.

     White is the house style and stays unless it actually fails; only the pale
     end of the palette — a gold, a sand — falls through to dark ink.
     */
    public static func readableInk(_ color: String) -> String {
        let rgb = parseHex(color) ?? parseHex(defaultAccent)!
        return contrast(rgb, parseHex(paper)!) >= largeTextContrast ? paper : ink
    }

    /**
     The room a session runs in: the accent darkened until it is a ground.

     Toward black rather than toward more saturation — the palette is chalky and
     muted, and pushing chroma up on the way down turns a print colour into a
     gemstone, which is not what the rest of the interface is.
     */
    public static func ground(for color: String) -> String {
        let rgb = parseHex(color) ?? parseHex(defaultAccent)!
        return toHex(nudge(rgb, toward: (0, 0, 0)) { $0 <= sessionGroundLuminance })
    }

    /**
     The accent as it should be drawn on one ground.

     Light ground: the colour is taken down until white ink clears body-text
     contrast on it — a deep terracotta stays where it is, a gold becomes an
     ochre — and the ink is white for every category.

     Dark ground: the colour is lifted until it stands off the room, and at that
     brightness dark ink is the one that reads, so the ink is dark for every
     category in dark mode and in the session room.
     */
    public static func accent(for color: String, dark: Bool) -> AccentTheme {
        let rgb = parseHex(color) ?? parseHex(defaultAccent)!
        let adjusted = dark
            ? nudge(rgb, toward: parseHex(paper)!) { $0 >= darkGroundMinLuminance }
            : nudge(rgb, toward: (0, 0, 0)) { $0 <= lightGroundMaxLuminance }
        return AccentTheme(base: toHex(adjusted), on: dark ? ink : paper, ground: ground(for: color))
    }

    public static func pair(for color: String) -> AccentPair {
        AccentPair(light: accent(for: color, dark: false), dark: accent(for: color, dark: true))
    }
}
