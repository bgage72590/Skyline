import SwiftUI
import SkylineCore

struct AlertsCard: View {
    let alerts: [WeatherAlert]
    let timeZone: TimeZone
    @State private var selected: WeatherAlert?

    var body: some View {
        Card(title: "Severe Weather", systemImage: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(alerts) { alert in
                    Button {
                        selected = alert
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Self.color(alert.severity)).frame(width: 10, height: 10).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.event).font(.headline)
                                if let until = alert.ends ?? alert.expires {
                                    Text("Until \(Fmt.dayTime(until, timeZone))").font(.caption).opacity(0.85)
                                }
                                if let sender = alert.senderName {
                                    Text(sender).font(.caption2).opacity(0.7)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").opacity(0.6)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Self.color(alerts.map(\.severity).max() ?? .unknown).opacity(0.9), lineWidth: 1.5)
        )
        .sheet(item: $selected) { alert in
            AlertDetailView(alert: alert, timeZone: timeZone)
        }
    }

    static func color(_ severity: AlertSeverity) -> Color {
        switch severity {
        case .extreme: return .red
        case .severe: return .orange
        case .moderate: return .yellow
        case .minor, .unknown: return .white
        }
    }
}

struct AlertDetailView: View {
    let alert: WeatherAlert
    let timeZone: TimeZone
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(alert.event, systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AlertsCard.color(alert.severity))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let headline = alert.headline { Text(headline).font(.headline) }
                    HStack(spacing: 16) {
                        Text("Severity: \(alert.severity.rawValue)")
                        if let urgency = alert.urgency { Text("Urgency: \(urgency)") }
                        if let effective = alert.effective { Text("From \(Fmt.dayTime(effective, timeZone))") }
                        if let until = alert.ends ?? alert.expires { Text("Until \(Fmt.dayTime(until, timeZone))") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let description = alert.description {
                        Text(description).textSelection(.enabled)
                    }
                    if let instruction = alert.instruction {
                        Text("What to do").font(.headline)
                        Text(instruction).textSelection(.enabled)
                    }
                    if let area = alert.areaDescription {
                        Text("Areas: \(area)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let sender = alert.senderName {
                        Text("Issued by \(sender)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 560)
    }
}
