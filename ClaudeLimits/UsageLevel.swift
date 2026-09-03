import SwiftUI

// Single source of truth for mapping a usage percentage (or ratio metric) to a
// warning level and its color. Both `UsagePopoverView` and
// `StatusItemController` derive their colors from this type so
// threshold/color changes only happen here.
enum UsageLevel: Equatable {
    case normal
    case elevated
    case high
    case critical

    // Same "step up only past the edge" rule as the ratio bands: a window
    // sitting exactly at 50% is still normal, only exceeding the edge moves
    // it to the next, more alarming color.
    init(utilization: Double) {
        switch utilization {
        case ...50:
            self = .normal
        case ...80:
            self = .elevated
        case ...90:
            self = .high
        default:
            self = .critical
        }
    }

    // The overload factor's bands. 1.0 is the "on schedule" baseline, and a
    // band stays in effect while the ratio sits *at* its upper edge — only
    // strictly exceeding the edge steps up to the next, more alarming color.
    private static func level(forRatio ratio: Double) -> UsageLevel {
        switch ratio {
        case ...1.0:
            return .normal
        case ...1.5:
            return .elevated
        case ...2.0:
            return .high
        default:
            return .critical
        }
    }

    // Overload factor of 1.0 means consumption can keep running at the
    // window's nominal pace (budget spread evenly over the whole period)
    // and land at exactly 100% at reset — the "on schedule" baseline, not
    // yet a concern. Above it, the budget mathematically cannot last until
    // reset at that pace, so every step above 1.0 is strictly worse than
    // the one below. `Double.infinity` (exhausted budget) falls into
    // `.critical` on its own.
    init(overloadFactor: Double) {
        self = Self.level(forRatio: overloadFactor)
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

    // Beyond this, the number stops conveying information ("how much of the
    // budget you must cut to reach reset on time" is no longer a number you
    // can act on) — display shows ">10" instead, so both the menu bar and
    // the popover need to cap with this same limit.
    static let overloadFactorDisplayCap: Double = 10
}
