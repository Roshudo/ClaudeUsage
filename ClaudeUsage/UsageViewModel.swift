import Foundation
import Observation

// What number the menu bar (and, when selected, the popover bars) lead
// with. Lives on the view model rather than in `StatusItemController` since
// both it and `UsagePopoverView` need to read the current choice.
enum MenuBarMetric: String, CaseIterable {
    case percent
    case pace

    var title: LocalizedStringResource {
        switch self {
        case .percent:
            return "Percentage"
        case .pace:
            return "Pace"
        }
    }
}

@Observable
final class UsageViewModel {
    enum State {
        case loading
        case loaded(UsageSnapshot)
        case failed(String)
    }

    private static let normalInterval: Double = 2 * 60
    private static let rateLimitedInterval: Double = 5 * 60
    private static let menuBarMetricDefaultsKey = "MenuBarMetric"

    private(set) var state: State = .loading
    var menuBarMetric: MenuBarMetric = MenuBarMetric(
        rawValue: UserDefaults.standard.string(forKey: UsageViewModel.menuBarMetricDefaultsKey) ?? ""
    ) ?? .percent {
        didSet {
            UserDefaults.standard.set(menuBarMetric.rawValue, forKey: Self.menuBarMetricDefaultsKey)
        }
    }
    private let client = ClaudeUsageClient()
    private var pollTask: Task<Void, Never>?
    private var nextInterval: Double = UsageViewModel.normalInterval

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.nextInterval))
            }
        }
    }

    func refresh() async {
        do {
            state = .loaded(try await client.fetchUsage())
            nextInterval = Self.normalInterval
        } catch let error as ClaudeUsageError {
            state = .failed(error.errorDescription ?? String(localized: "Unknown error"))
            if case .rateLimited(let retryAfter) = error {
                nextInterval = max(retryAfter ?? Self.rateLimitedInterval, Self.rateLimitedInterval)
            } else {
                nextInterval = Self.normalInterval
            }
        } catch {
            state = .failed(error.localizedDescription)
            nextInterval = Self.normalInterval
        }
    }
}
