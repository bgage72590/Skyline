import Foundation

/// Sky gradient colours (sRGB, top → bottom) behind the dropdown, sidebar cards and main window, plus the
/// contrast maths used to keep white text readable on them (T6). The light daytime skies' lower stops
/// were darkened a little so text there reaches the 4.5 : 1 guideline with the scrims below.
public enum SkyColors {
    public typealias RGB = (r: Double, g: Double, b: Double)

    public static func stops(_ category: SkyCategory, isDay: Bool) -> [RGB] {
        switch (category, isDay) {
        case (.clear, true): return [(0.19, 0.46, 0.86), (0.40, 0.66, 0.92)]
        case (.clear, false): return [(0.03, 0.06, 0.19), (0.14, 0.20, 0.40)]
        case (.partlyCloudy, true): return [(0.27, 0.50, 0.80), (0.52, 0.66, 0.82)]
        case (.partlyCloudy, false): return [(0.07, 0.10, 0.22), (0.22, 0.27, 0.42)]
        case (.cloudy, true): return [(0.40, 0.48, 0.58), (0.59, 0.65, 0.73)]
        case (.cloudy, false): return [(0.12, 0.15, 0.21), (0.27, 0.31, 0.38)]
        case (.fog, true): return [(0.48, 0.51, 0.56), (0.62, 0.64, 0.67)]
        case (.fog, false): return [(0.18, 0.19, 0.22), (0.33, 0.35, 0.38)]
        case (.drizzle, true), (.rain, true): return [(0.25, 0.33, 0.45), (0.45, 0.53, 0.63)]
        case (.drizzle, false), (.rain, false): return [(0.07, 0.10, 0.16), (0.20, 0.25, 0.33)]
        case (.snow, true): return [(0.46, 0.53, 0.65), (0.60, 0.64, 0.70)]
        case (.snow, false): return [(0.16, 0.19, 0.27), (0.33, 0.37, 0.46)]
        case (.thunderstorm, _): return [(0.15, 0.15, 0.25), (0.32, 0.29, 0.41)]
        }
    }

    /// Black wash over the whole dropdown gradient.
    public static let dropdownScrim = 0.30
    /// Black wash on every sidebar card (selected cards no longer get a lighter one).
    public static let cardScrim = 0.26
    /// Extra black at the bottom edge of a sidebar card (linear from the centre).
    public static let cardBottomScrim = 0.35

    /// Liquid Glass dropdown (macOS 26+, build 57): the glass is tinted with the sky's top colour,
    /// darkened, at `glassTintOpacity`. Chosen so white text (and 0.75-alpha secondary text) stays at
    /// least 4.5 : 1 even with a pure white wallpaper behind the glass (tested), Brian's "readability
    /// wins over see-through".
    public static let glassTintDarken = 0.55
    public static let glassTintOpacity = 0.85
    public static func glassTint(_ category: SkyCategory, isDay: Bool) -> RGB {
        darkened(stops(category, isDay: isDay)[0], by: glassTintDarken)
    }
    /// The tinted glass over a backdrop colour (worst case: white).
    public static func glassComposite(_ category: SkyCategory, isDay: Bool, over backdrop: RGB = (1, 1, 1)) -> RGB {
        mix(backdrop, glassTint(category, isDay: isDay), glassTintOpacity)
    }

    /// `colour` with black at `opacity` composited over it (sRGB, as SwiftUI draws it).
    public static func darkened(_ c: RGB, by opacity: Double) -> RGB {
        (c.r * (1 - opacity), c.g * (1 - opacity), c.b * (1 - opacity))
    }

    public static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    /// WCAG relative luminance.
    public static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// Contrast ratio of white text (at `alpha`) over `background`.
    public static func whiteContrast(on background: RGB, alpha: Double = 1) -> Double {
        let text = mix(background, (1, 1, 1), alpha)
        return (luminance(text) + 0.05) / (luminance(background) + 0.05)
    }
}
