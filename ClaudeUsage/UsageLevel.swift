import SwiftUI

// Single source of truth for mapping a usage percentage to a warning level
// and its color. Both `UsagePopoverView` and `StatusItemController` derive
// their colors from this type so threshold/color changes only happen here.
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
}
