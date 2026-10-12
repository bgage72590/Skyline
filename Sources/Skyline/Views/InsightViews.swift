import SwiftUI
import SkylineCore

/// Formatting shared by the insight views (report's time zone, the user's units).
@MainActor
enum InsightFormat {
    static func confidence(_ report: WeatherReport, day: DailyForecast, units: DisplayUnits) -> ForecastInsight.Confidence {
        let tz = report.timeZone
        return ForecastInsight.confidence(day: day, hourly: report.hourly, timeZone: tz, now: report.current.time,
                                          hourLabel: { Fmt.hour($0, tz) },
                                          delta: { Int(units.temperatureDelta($0).rounded()) })
    }

    static func changes(_ report: WeatherReport, units: DisplayUnits) -> [String] {
        ForecastInsight.changes(report, now: report.current.time, delta: { Int(units.temperatureDelta($0).rounded()) })
    }
}

/// "How sure is this?" in words for today and tomorrow, plus what changed since ~12 h ago (T11).
struct OutlookCard: View {
    let report: WeatherReport
    let units: DisplayUnits

    var body: some View {
        let days = Array(report.daily.prefix(2))
        let changes = InsightFormat.changes(report, units: units)
        if !days.isEmpty {
            Card(title: "Forecast Confidence", systemImage: "gauge.with.dots.needle.50percent") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { offset, day in
                        let c = InsightFormat.confidence(report, day: day, units: units)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: Self.symbol(c.level))
                                .foregroundStyle(Self.tint(c.level))
                                .accessibilityHidden(true)
                            Text(offset == 0 ? "Today" : "Tomorrow").font(.callout.weight(.semibold))
                                .frame(width: 74, alignment: .leading)
                            Text(c.sentence).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if !changes.isEmpty {
                        Rectangle().fill(.white.opacity(0.2)).frame(height: 0.5)
                        ForEach(changes, id: \.self) { note in
                            Label {
                                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: note.contains(" up ") ? "arrow.up.right" : "arrow.down.right")
                            }
                        }
                    }
                }
            }
        }
    }

    static func symbol(_ l: ForecastInsight.Level) -> String {
        switch l {
        case .high: "checkmark.circle.fill"
        case .medium: "circle.lefthalf.filled"
        case .low: "questionmark.circle.fill"
        }
    }

    static func tint(_ l: ForecastInsight.Level) -> Color {
        switch l {
        case .high: Color(red: 0.55, green: 0.9, blue: 0.6)
        case .medium: Color(red: 1.0, green: 0.85, blue: 0.45)
        case .low: Color(red: 1.0, green: 0.6, blue: 0.5)
        }
    }
}

/// Key messages from the local NWS office's Area Forecast Discussion, with a link to the full text (T17).
/// Loaded only while this card is on screen (two small cached requests), never for the menu bar.
struct ForecasterNotesCard: View {
    let office: String
    let timeZone: TimeZone
    @Environment(WeatherStore.self) private var store

    var body: some View {
        // A VStack, not a Group: an empty Group has no view to hang `.task` on, so the notes never loaded.
        VStack(spacing: 0) {
            if let notes = store.forecasterNotes[office] {
                Card(title: "Forecaster’s Notes", systemImage: "person.text.rectangle",
                     subtitle: "NWS \(office) · issued \(Fmt.dayTime(notes.issued, timeZone))") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let changed = notes.whatChanged {
                            Text("What’s new: ").font(.callout.weight(.semibold)) + Text(changed).font(.callout)
                        }
                        ForEach(Array(notes.points.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").font(.callout.weight(.bold))
                                Text(point).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Link(destination: notes.fullTextURL) {
                            Label("Read the full discussion", systemImage: "arrow.up.right.square")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(Color(red: 0.6, green: 0.85, blue: 1.0))
                    }
                }
            }
        }
        .task(id: office) { await store.loadForecasterNotes(office: office) }
    }
}
