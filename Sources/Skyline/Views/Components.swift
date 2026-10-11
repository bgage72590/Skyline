import SwiftUI
import SkylineCore

/// Rounded "readable glass" card with a small-caps header.
struct Card<Content: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Label(title.uppercased(), systemImage: systemImage ?? "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Glass.secondaryText)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if title != nil || subtitle != nil {
                Rectangle().fill(.white.opacity(0.2)).frame(height: 0.5)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// Fixed-height detail tile used in the conditions grid.
struct Tile<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        Card(title: title, systemImage: systemImage) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 172)
    }
}

/// Big value + caption, the standard tile body.
struct TileValue: View {
    let value: String
    var label: String? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 30, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
            if let label { Text(label).font(.headline) }
            Spacer(minLength: 0)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(Glass.secondaryText)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Horizontal low…high bar on a shared scale, with an optional "now" dot.
struct TemperatureRangeBar: View {
    let rangeLow: Double
    let rangeHigh: Double
    let low: Double
    let high: Double
    var current: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let span = max(rangeHigh - rangeLow, 0.1)
            let width = geo.size.width
            let x0 = CGFloat((low - rangeLow) / span) * width
            let x1 = CGFloat((high - rangeLow) / span) * width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [TemperatureColors.color(low), TemperatureColors.color(high)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(x1 - x0, 6))
                    .offset(x: x0)
                if let current {
                    let cx = CGFloat((current - rangeLow) / span) * width
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .offset(x: min(max(cx, x0), x1) - 4)
                }
            }
        }
        .frame(height: 6)
    }
}

/// Gradient scale with a dot at `fraction` (UV, AQI).
struct ScaleBar: View {
    let fraction: Double
    let colors: [Color]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                    .offset(x: CGFloat(min(max(fraction, 0), 1)) * (geo.size.width - 8))
            }
        }
        .frame(height: 6)
    }
}

/// Wind compass: arrow points where the wind is blowing *to*.
struct CompassView: View {
    let degrees: Double?
    var centerText: String? = nil
    var centerUnit: String? = nil

    private struct Cardinal { let label: String; let x: CGFloat; let y: CGFloat }
    private static let cardinals = [Cardinal(label: "N", x: 0, y: -33), Cardinal(label: "E", x: 33, y: 0),
                                    Cardinal(label: "S", x: 0, y: 33), Cardinal(label: "W", x: -33, y: 0)]

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: 1.5)
            ForEach(Self.cardinals, id: \.label) { point in
                Text(point.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .offset(x: point.x, y: point.y)
            }
            if let degrees {
                // Arrow shaft across the dial, pointing where the wind blows to.
                VStack(spacing: 0) {
                    Image(systemName: "arrowtriangle.up.fill").font(.system(size: 10))
                    Rectangle().frame(width: 2, height: 22)
                    Spacer().frame(height: 26)
                    Rectangle().frame(width: 2, height: 14)
                    Circle().frame(width: 6, height: 6)
                }
                .rotationEffect(.degrees(degrees + 180))
            }
            if let centerText {
                VStack(spacing: -2) {
                    Text(centerText).font(.system(size: 17, weight: .semibold))
                    if let centerUnit { Text(centerUnit).font(.system(size: 9, weight: .medium)).opacity(0.8) }
                }
            }
        }
        .frame(width: 84, height: 84)
    }
}

struct WeatherSymbol: View {
    let condition: WeatherCondition
    let isDay: Bool
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: condition.symbolName(isDay: isDay))
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size))
            .frame(height: size * 1.25)
            .accessibilityLabel(condition.description)
    }
}
