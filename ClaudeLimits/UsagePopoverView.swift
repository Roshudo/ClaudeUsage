import SwiftUI

struct UsagePopoverView: View {
    @Environment(UsageViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Usage")
                .font(.headline)

            if let failure = currentFailure {
                FailureNotice(failure: failure, lastUpdated: staleTimestamp)
            } else if let staleTimestamp {
                // Data restored from the previous launch, standing in until
                // this session's first fetch comes back.
                LastUpdatedText(date: staleTimestamp)
            }

            if let snapshot = displayedSnapshot {
                if currentFailure != nil || staleTimestamp != nil {
                    Divider()
                }
                // The reset countdowns below are computed from fixed dates,
                // so they only change when the view re-evaluates. Fresh data
                // arrives every few minutes either way, but in the failure
                // case no new data ever arrives — the timeline keeps the
                // (estimated) countdowns ticking while the popover is open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    UsageRow(
                        title: "5-Hour Limit",
                        window: snapshot.fiveHour,
                        resetStyle: .duration,
                        windowDuration: UsageSnapshot.fiveHourDuration,
                        metric: viewModel.menuBarMetric,
                        now: context.date,
                        isEstimate: currentFailure != nil,
                        staleDataFetchedAt: viewModel.lastKnownUsage?.fetchedAt
                    )
                    Divider()
                    UsageRow(
                        title: "Weekly Limit",
                        window: snapshot.sevenDay,
                        resetStyle: .weekdayTime,
                        windowDuration: UsageSnapshot.sevenDayDuration,
                        metric: viewModel.menuBarMetric,
                        now: context.date,
                        isEstimate: currentFailure != nil,
                        staleDataFetchedAt: viewModel.lastKnownUsage?.fetchedAt
                    )
                }
            } else if currentFailure == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var currentFailure: UsageViewModel.Failure? {
        guard case .failed(let failure) = viewModel.state else { return nil }
        return failure
    }

    // The snapshot on screen: the current one, or the last one that could be
    // fetched — possibly during a previous launch — when the latest attempt
    // failed or hasn't come back yet.
    private var displayedSnapshot: UsageSnapshot? {
        if case .loaded(let snapshot) = viewModel.state {
            return snapshot
        }
        return viewModel.lastKnownUsage?.snapshot
    }

    // Only set when what's on screen isn't current: data that loaded
    // successfully is current by definition and doesn't need an age
    // attached to it.
    private var staleTimestamp: Date? {
        if case .loaded = viewModel.state {
            return nil
        }
        return viewModel.lastKnownUsage?.fetchedAt
    }
}

// What went wrong, what to do about it, and when the app will try again.
// The last part matters because most failures here need no user action at
// all — without it, a gray icon looks like something the user has to fix.
private struct FailureNotice: View {
    let failure: UsageViewModel.Failure
    let lastUpdated: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(failure.message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                if let hint = failure.hint {
                    Text(hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let retryAt = failure.retryAt {
                    Text("Retrying in \(retryAt, style: .relative)")
                }
                if let lastUpdated {
                    LastUpdatedText(date: lastUpdated)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct LastUpdatedText: View {
    let date: Date

    var body: some View {
        Text("Last updated \(date, style: .relative) ago")
            .font(.footnote)
            .foregroundStyle(.secondary)
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
    let windowDuration: TimeInterval
    let metric: MenuBarMetric
    /// Reference time the countdown is computed from. Normally `Date()`, but
    /// the timeline's date in the failure case, where the value must tick
    /// even though no fresh data is arriving.
    var now: Date = Date()
    /// True when the window's data is stale (last fetch failed or nothing was
    /// fetched this session yet). The reset countdown is then derived from
    /// the elapsed window duration instead of the reported reset time and
    /// gets an "(estimated)" annotation.
    var isEstimate: Bool = false
    /// When the stale data was fetched — the reference point the estimated
    /// countdown is anchored to (see `resetLabel`).
    var staleDataFetchedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(primaryText)
                    .font(.subheadline)
                    .foregroundStyle(color)
            }
            ProgressView(value: min(window.utilization, 100), total: 100)
                .progressViewStyle(ColoredBarProgressStyle(color: color, scheduleMarker: metric == .overloadFactor ? elapsedFraction : nil))
            HStack(spacing: 4) {
                // In overload mode the primary text is the ratio, so this row
                // is the only place the raw percent still shows up — and
                // utilization always decodes to a value (0 when missing), so
                // this part never has to drop out.
                if metric == .overloadFactor {
                    Text("\(percentageText(for: window.utilization)) used")
                    Text("·")
                }
                resetLabel
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // `resets_at` is legitimately `null` for windows the API reports as
    // empty (confirmed in the raw response: 0% utilization and no reset
    // date), and a snapshot captured in that state gets persisted by
    // `UsageCache`, so the popover has to handle it across relaunches too.
    // There's no countdown to render then — the row says the value is
    // currently unavailable rather than showing an empty line.
    private var resetLabel: AnyView {
        if let resetsAt = window.resetsAt {
            return AnyView(Text("Reset: \(resetText(for: resetsAt))"))
        }
        return AnyView(Text("Reset: \(String(localized: "unavailable"))"))
    }

    // The tick mark on the bar showing where usage "should" be if it were
    // tracking exactly with elapsed time — the gap between it and the fill
    // is the same information the overload-factor number distills to a
    // single ratio.
    private var elapsedFraction: Double? {
        guard let resetsAt = window.resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0, remaining < windowDuration else { return nil }
        return 1 - remaining / windowDuration
    }

    private var overloadFactor: Double? {
        window.overloadFactor(windowDuration: windowDuration)
    }

    private var color: Color {
        switch metric {
        case .percent:
            return UsageLevel(utilization: window.utilization).color
        case .overloadFactor:
            guard let overloadFactor else { return UsageLevel(utilization: window.utilization).color }
            return UsageLevel(overloadFactor: overloadFactor).color
        }
    }

    private var primaryText: String {
        switch metric {
        case .percent:
            return percentageText(for: window.utilization)
        case .overloadFactor:
            guard let overloadFactor else { return percentageText(for: window.utilization) }
            if overloadFactor >= UsageLevel.overloadFactorDisplayCap {
                // 100% gets its own exact reading; anything below it that
                // still exceeds the cap shows the capped ">10".
                return window.utilization >= 100
                    ? percentageText(for: window.utilization)
                    : overloadFactorDisplayText()
            }
            return ratioText(overloadFactor)
        }
    }

    private func percentageText(for utilization: Double) -> String {
        (utilization / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private func ratioText(_ ratio: Double) -> String {
        ratio.formatted(.number.precision(.fractionLength(1)))
    }

    // Capped values lose their decimals anyway, so ">10" (never ">10.3") —
    // mirrors the menu bar text, so both surfaces read identically.
    private func overloadFactorDisplayText() -> String {
        ">" + UsageLevel.overloadFactorDisplayCap
            .formatted(.number.precision(.fractionLength(0)))
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
        durationText(remaining: date.timeIntervalSinceNow)
    }

    private func durationText(remaining interval: TimeInterval) -> String {
        let text: String
        if interval > 0 {
            let totalMinutes = Int((interval / 60).rounded())
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours > 0 {
                text = String(localized: "in \(hours) hr \(minutes) min")
            } else {
                text = String(localized: "in \(minutes) min")
            }
        } else {
            text = String(localized: "now")
        }
        return isEstimate ? "\(text) \(String(localized: "(estimated)"))" : text
    }
}

// macOS's default linear ProgressView style doesn't honor `.tint(_:)`, so
// the fill color is drawn explicitly instead.
private struct ColoredBarProgressStyle: ProgressViewStyle {
    let color: Color
    var scheduleMarker: Double? = nil

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
            .overlay(alignment: .leading) {
                if let scheduleMarker, scheduleMarker > 0, scheduleMarker < 1 {
                    Capsule()
                        .fill(Color.primary.opacity(1))
                        .stroke(Color.black.opacity(0.75), lineWidth: 1)
                        .frame(width: 2.5, height: 9)
                        .offset(x: geometry.size.width * scheduleMarker - 1)
                }
            }
        }
        .frame(height: 6)
    }
}
