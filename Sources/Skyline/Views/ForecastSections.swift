import Charts
import SwiftUI
import SkylineCore

/// Pinned plain-English summary at the top of the forecast column: stays put while the hero
/// above it shrinks away, so "what's happening" is always one glance away.
struct BriefingBar: View {
    let report: WeatherReport
    let units: DisplayUnits

    var body: some View {
        let tz = report.timeZone
        let text = Briefing.headline(report, now: Date(),
                                     hourLabel: { Fmt.hour($0, tz) },
                                     delta: { Int(units.temperatureDelta($0).rounded()) })
        HStack(alignment: .center, spacing: 10) {
            WeatherSymbol(condition: report.current.condition, isDay: report.current.isDay, size: 18)
            Text(units.temperatureString(report.current.temperature, withUnit: true))
                .font(.title3.weight(.semibold)).monospacedDigit()
            Text(text)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Severity-coloured alert banner in the main view (not just the sidebar). Links to the outline on
/// the radar map and to the full NWS text.
struct AlertBanner: View {
    let alerts: [WeatherAlert]
    let timeZone: TimeZone
    @Environment(WeatherStore.self) private var store
    @Environment(\.isWideLayout) private var isWide
    @State private var detail: WeatherAlert?

    var body: some View {
        let top = alerts[0]
        let color = AlertsCard.color(top.severity)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.event + (alerts.count > 1 ? "  +\(alerts.count - 1) more" : ""))
                        .font(.headline)
                    if let until = top.ends ?? top.expires {
                        Text("Until \(Fmt.dayTime(until, timeZone))\(top.senderName.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(Glass.secondaryText)
                    }
                    // Not the NWS headline when it just restates the event, time and office (UI/UX #8).
                    if let line = TextTidy.alertSubtitle(event: top.event, headline: top.headline, description: top.description) {
                        Text(line).font(.caption).lineLimit(2).foregroundStyle(.white)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if !top.polygons.isEmpty {
                    Button { store.showAlertOnMap(top, wideLayout: isWide) } label: {
                        Label("Show on Map", systemImage: "map")
                    }
                }
                Button { detail = top } label: { Label("Full Alert", systemImage: "doc.text") }
                if alerts.count > 1 {
                    Menu("Others") {
                        ForEach(alerts.dropFirst()) { a in
                            Button(a.event) { detail = a }
                        }
                    }
                    .fixedSize()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack {
                shape.fill(Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.85))
                shape.fill(color.opacity(0.22))
            }
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, style: .continuous)
                .fill(color).frame(width: 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.7), lineWidth: 1))
        .sheet(item: $detail) { alert in
            AlertDetailView(alert: alert, timeZone: timeZone) {
                store.showAlertOnMap(alert, wideLayout: isWide)
            }
        }
        // The dropdown's alert line asks for this alert's full text (UI/UX #19). Deferred a turn so no
        // observed state is written during the view update.
        .onChange(of: store.pendingAlertID, initial: true) { _, id in
            guard let id, let alert = alerts.first(where: { $0.id == id }) else { return }
            DispatchQueue.main.async {
                detail = alert
                store.pendingAlertID = nil
            }
        }
    }
}

/// Next-two-hours precipitation: a dense, continuous rain-intensity curve built from the 15-minute
/// nowcast (monotone-cubic interpolated to one sample per minute, see `NowcastCurve`), on a perceptual
/// Light / Moderate / Heavy scale with guide lines, time labels and a hover/drag/←→ scrubber.
/// Shown only when rain is actually due.
struct NowcastCard: View {
    let report: WeatherReport
    let units: DisplayUnits
    /// QA hook: `-SkylineNowcastScrub <minutes>` pre-selects a point so the callout can be screenshotted.
    @State private var scrub: Date? = {
        let m = UserDefaults.standard.integer(forKey: "SkylineNowcastScrub")
        guard m > 0 else { return nil }
        return Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + Double(m) * 60)
    }()

    private static let rain = Color(red: 0.36, green: 0.72, blue: 1.0)

    var body: some View {
        // Start at the current minute (not the report's fetch time) so "Now" is honest for cached data.
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let samples = NowcastCurve.samples(report.minutely, from: start, minutes: 120)
        let end = start.addingTimeInterval(120 * 60)
        let selected = scrub.flatMap { s in samples.min { abs($0.time.timeIntervalSince(s)) < abs($1.time.timeIntervalSince(s)) } }
        let tz = report.timeZone
        Card(title: "Next 2 Hours", systemImage: "cloud.rain.fill", subtitle: subtitle(samples, tz: tz)) {
            Chart {
                // Guide lines first so the rain draws over them.
                ForEach([1.0, 2.0, 3.0], id: \.self) { level in
                    RuleMark(y: .value("Guide", level))
                        .foregroundStyle(.white.opacity(0.16))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
                ForEach(samples, id: \.time) { s in
                    AreaMark(x: .value("Time", s.time), y: .value("Intensity", NowcastCurve.level(s.rate)))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(
                            stops: [.init(color: Self.rain.opacity(0.95), location: 0),
                                    .init(color: Self.rain.opacity(0.55), location: 0.55),
                                    .init(color: Self.rain.opacity(0.12), location: 1)],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", s.time), y: .value("Intensity", NowcastCurve.level(s.rate)))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color(red: 0.62, green: 0.86, blue: 1.0))
                }
                if let selected {
                    RuleMark(x: .value("Selected", selected.time))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            ScrubCallout(title: Fmt.time(selected.time, tz) + "  ·  " + relative(selected.time, from: start),
                                         value: intensity(selected.rate))
                        }
                    PointMark(x: .value("Selected", selected.time), y: .value("Intensity", NowcastCurve.level(selected.rate)))
                        .symbolSize(48)
                        .foregroundStyle(.white)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...3.9) // headroom above "Heavy" for the callout
            .chartYAxis {
                AxisMarks(position: .leading, values: [1.0, 2.0, 3.0]) { v in
                    AxisValueLabel(horizontalSpacing: 6) {
                        Text(["", "Light", "Moderate", "Heavy"][min(max(v.index + 1, 0), 3)])
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Glass.secondaryText)
                }
            }
            .chartXAxis {
                AxisMarks(values: Self.ticks(start: start, end: end)) { v in
                    AxisTick(length: 3).foregroundStyle(.white.opacity(0.3))
                    AxisValueLabel(anchor: v.index == 0 ? .topLeading : .top) {
                        if let d = v.as(Date.self) {
                            Text(v.index == 0 ? "Now" : Fmt.time(d, tz))
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Glass.secondaryText)
                }
            }
            .chartPlotStyle { $0.clipped() }
            .chartScrubber(times: samples.map(\.time), selection: $scrub)
            .environment(\.timeZone, tz)
            .frame(height: 130)
            .accessibilityLabel("Rain intensity over the next two hours")
            .accessibilityValue(report.nowcastSummary(at: Date()) ?? "")
        }
    }

    /// "Now" plus round clock times (:00 / :30), skipping any that would crowd "Now" or the right edge.
    static func ticks(start: Date, end: Date) -> [Date] {
        let first = (start.timeIntervalSince1970 / 1800).rounded(.up) * 1800
        let rounds = stride(from: first, to: end.timeIntervalSince1970 - 8 * 60, by: 1800)
            .filter { $0 - start.timeIntervalSince1970 >= 20 * 60 }
            .map { Date(timeIntervalSince1970: $0) }
        return [start] + rounds
    }

    /// The nowcast sentence, unless the pinned briefing above already says it (UI/UX #8); then the
    /// peak instead ("Heaviest around 5:15 PM").
    private func subtitle(_ samples: [NowcastCurve.Sample], tz: TimeZone) -> String? {
        let briefing = Briefing.headline(report, now: Date(), hourLabel: { Fmt.hour($0, tz) },
                                         delta: { Int(units.temperatureDelta($0).rounded()) })
        guard TextTidy.isRepeated(report.nowcastSummary(at: Date()), in: briefing) else {
            return report.nowcastSummary(at: Date()).map { $0 + "." }
        }
        guard let peak = samples.max(by: { $0.rate < $1.rate }), peak.rate >= 0.1 else { return nil }
        return "Heaviest around \(Fmt.time(peak.time, tz)) (\(NowcastCurve.intensityName(peak.rate).lowercased()))."
    }

    private func relative(_ t: Date, from start: Date) -> String {
        let m = Int((t.timeIntervalSince(start) / 60).rounded())
        return m <= 0 ? "now" : "in \(m) min"
    }

    private func intensity(_ perHour: Double) -> String {
        let name = NowcastCurve.intensityName(perHour)
        return perHour < 0.1 ? "No rain" : "\(name) · \(units.precipitationString(perHour))/h"
    }
}
