import SwiftUI

// Single source of truth for mapping a usage percentage (or pace ratio) to a
// warning level and its color. Both `UsagePopoverView` and
// `StatusItemController` derive their colors from this type so
// threshold/color changes only happen here.
enum UsageLevel: Equatable {
    case normal
    case elevated
    case high
    case critical

    init(utilization: Double) {
        switch utilization {
        case ..<50:
            self = .normal
        case 50..<80:
            self = .elevated
        case 80..<90:
            self = .high
        default:
            self = .critical
        }
    }

    // Pace of 1.0 means usage is tracking exactly with the time elapsed in
    // the window (will land at ~100% right at reset) — that's the "on
    // schedule" baseline, not yet a concern, so the thresholds start above it.
    init(pace: Double) {
        switch pace {
        case ..<1.0:
            self = .normal
        case 1.0..<1.5:
            self = .elevated
        case 1.5..<2.0:
            self = .high
        default:
            self = .critical
        }
    }

    var color: Color {
        switch self {
        case .normal:
            return .green
        case .elevated:
            return .yellow
        case .high:
            return .orange
        case .critical:
            return .red
        }
    }

    // Below this, pace-derived colors aren't shown even if pace itself
    // reads as elevated/high/critical — right after a window resets, tiny
    // amounts of usage over tiny amounts of elapsed time produce wild pace
    // swings (e.g. 2% used in the first minute already reads as "way over
    // pace"), so a color needs at least some real usage behind it to be
    // trustworthy. Callers treat `nil` as "no color" per their own neutral
    // convention (no icon tint, `.primary` text in the popover).
    static let paceDisplayFloor: Double = 25

    static func forPace(_ pace: Double, utilization: Double) -> UsageLevel? {
        guard utilization >= paceDisplayFloor else { return nil }
        return UsageLevel(pace: pace)
    }
}
