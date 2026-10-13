import SwiftUI
import WidgetKit
import SkylineCore

/// Dark sky gradient matching the app's look (day/night, rain darker).
struct WidgetSky: View {
    let snapshot: WidgetSnapshot?
    var body: some View {
        let night = !(snapshot?.isDay ?? true)
        let wet = snapshot?.condition.isPrecipitation ?? false
        LinearGradient(colors: night ? [Color(red: 0.05, green: 0.08, blue: 0.20), Color(red: 0.10, green: 0.14, blue: 0.30)]
                       : wet ? [Color(red: 0.25, green: 0.31, blue: 0.40), Color(red: 0.36, green: 0.43, blue: 0.52)]
                       : [Color(red: 0.16, green: 0.42, blue: 0.78), Color(red: 0.40, green: 0.64, blue: 0.92)],
                       startPoint: .top, endPoint: .bottom)
    }
}

struct SkylineWidgetView: View {
    let entry: SkylineEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            content(s).foregroundStyle(.white)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "cloud.sun").font(.title)
                Text("Open Skyline to load the forecast").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private func content(_ s: WidgetSnapshot) -> some View {
        switch family {
        case .systemSmall: small(s)
        case .systemMedium: medium(s)
        default: large(s)
        }
    }

    private func header(_ s: WidgetSnapshot, big: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(s.locationName).font(.headline).lineLimit(1)
            Text(s.units.temperatureString(s.temperature)).font(.system(size: big, weight: .light)).minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                Image(systemName: s.condition.symbolName(isDay: s.isDay)).symbolRenderingMode(.multicolor)
                Text(s.condition.description).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            if let hl = s.highLow(at: entry.date) {
                Text("H:\(s.units.temperatureString(hl.high)) L:\(s.units.temperatureString(hl.low))").font(.caption.weight(.medium))
            }
        }
    }

    /// Rain line, an alert, or how old the data is (in that order of importance).
    @ViewBuilder private func footer(_ s: WidgetSnapshot) -> some View {
        if let alert = s.alert {
            Label(alert, systemImage: "exclamationmark.triangle.fill").font(.caption2.weight(.bold)).foregroundStyle(.yellow).lineLimit(1)
        }
        let rain = s.rainLine(at: entry.date)
        if !rain.isEmpty { Text(rain).font(.caption2.weight(.semibold)).lineLimit(2) }
        if s.isStale(at: entry.date) {
            Text("Updated \(Self.age(s.dataTime, now: entry.date))").font(.caption2).opacity(0.75)
        }
    }

    static func age(_ t: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(t) / 60)
        return m < 120 ? "\(m) min ago" : "\(m / 60) h ago"
    }

    private func small(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(s, big: 38)
            Spacer(minLength: 0)
            footer(s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func hourStrip(_ s: WidgetSnapshot, count: Int) -> some View {
        let hours = s.hours(from: entry.date, count: count)
        if hours.isEmpty {
            // Data too old to have hours left (W2): say so instead of an empty row.
            Text("Open Skyline to update the hourly forecast").font(.caption2).opacity(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
        HStack(spacing: 0) {
            ForEach(Array(hours.enumerated()), id: \.offset) { i, h in
                VStack(spacing: 3) {
                    // Labelled like the app's strip: the hour under way is "Now", then each hour's own time (W1).
                    Text(i == 0 ? "Now" : Self.hourLabel(h.time, s.timeZone)).font(.caption2.weight(.semibold))
                    Image(systemName: WeatherCondition(wmoCode: h.weatherCode).symbolName(isDay: h.isDay))
                        .symbolRenderingMode(.multicolor).font(.caption)
                    Text(s.units.temperatureString(h.temperature)).font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity)
            }
        }
        }
    }

    private func medium(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                header(s, big: 34)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) { footer(s) }.multilineTextAlignment(.trailing).frame(maxWidth: 150)
            }
            Spacer(minLength: 0)
            hourStrip(s, count: 6)
        }
    }

    private func large(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                header(s, big: 40)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) { footer(s) }.multilineTextAlignment(.trailing).frame(maxWidth: 170)
            }
            hourStrip(s, count: 6)
            Divider().overlay(.white.opacity(0.3))
            ForEach(Array(s.days(from: entry.date).enumerated()), id: \.offset) { _, d in
                HStack {
                    Text(s.dayLabel(d, now: entry.date) == "Today" ? "Today" : Self.weekday(d.date, s.timeZone))
                        .frame(width: 48, alignment: .leading)
                    Image(systemName: WeatherCondition(wmoCode: d.weatherCode).symbolName(isDay: true))
                        .symbolRenderingMode(.multicolor).frame(width: 24)
                    if (d.snowfallSum ?? 0) >= 0.5 {
                        Text(s.units.snowString(d.snowfallSum)).font(.caption2.weight(.bold)).frame(width: 46, alignment: .leading)
                    } else if let p = d.precipitationProbability, p >= 20 {
                        Text("\(Int((p / 10).rounded() * 10))%").font(.caption2.weight(.bold))
                            .foregroundStyle(Color(red: 0.7, green: 0.88, blue: 1)).frame(width: 46, alignment: .leading)
                    } else { Spacer().frame(width: 46) }
                    Spacer()
                    Text(s.units.temperatureString(d.low)).opacity(0.75)
                    Text(s.units.temperatureString(d.high)).frame(width: 40, alignment: .trailing)
                }
                .font(.callout.weight(.medium)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    static func hourLabel(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.setLocalizedDateFormatFromTemplate("j"); return f.string(from: d)
    }
    static func weekday(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.setLocalizedDateFormatFromTemplate("EEE"); return f.string(from: d)
    }
}
