import SwiftUI

struct UsagePopoverView: View {
    @Environment(UsageViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Usage")
                .font(.headline)

            switch viewModel.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            case .loaded(let snapshot):
                UsageRow(title: "5-Hour Limit", window: snapshot.fiveHour, resetStyle: .duration)
                Divider()
                UsageRow(title: "Weekly Limit", window: snapshot.sevenDay, resetStyle: .weekdayTime)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct UsageRow: View {
    enum ResetStyle {
        case duration
        case weekdayTime
    }

    let title: LocalizedStringResource
    let window: UsageWindow
    let resetStyle: ResetStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(percentageText(for: window.utilization))
                    .font(.subheadline)
                    .foregroundStyle(color)
            }
            ProgressView(value: min(window.utilization, 100), total: 100)
                .progressViewStyle(ColoredBarProgressStyle(color: color))
            if let resetsAt = window.resetsAt {
                Text("Reset: \(resetText(for: resetsAt))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        UsageLevel(utilization: window.utilization).color
    }

    private func percentageText(for utilization: Double) -> String {
        (utilization / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private func resetText(for date: Date) -> String {
        switch resetStyle {
        case .duration:
            return durationText(until: date)
        case .weekdayTime:
            // Uses the system's current locale, so this reads correctly
            // regardless of the app's UI language.
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        }
    }

    private func durationText(until date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            return String(localized: "now")
        }
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return String(localized: "in \(hours) hr \(minutes) min")
        } else {
            return String(localized: "in \(minutes) min")
        }
    }
}

// macOS's default linear ProgressView style doesn't honor `.tint(_:)`, so
// the fill color is drawn explicitly instead.
private struct ColoredBarProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        let fraction = configuration.fractionCompleted ?? 0
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
    }
}
