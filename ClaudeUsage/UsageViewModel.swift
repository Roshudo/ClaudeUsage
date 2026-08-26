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
    // The last snapshot that was fetched successfully, kept around so that
    // a later failure — network, auth, keychain, anything — can still show
    // something useful instead of a blank state.
    struct LastKnownUsage {
        let snapshot: UsageSnapshot
        let fetchedAt: Date
    }

    enum State {
        case loading
        case loaded(UsageSnapshot)
        case failed(message: String, lastKnown: LastKnownUsage?)
    }

    private static let normalInterval: Double = 3 * 60
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
    private var lastKnownUsage: LastKnownUsage?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                // .suspending pauses while the system is asleep, so the
                // interval only counts awake time — the default clock keeps
                // ticking through sleep, which made the next fetch fire the
                // instant the Mac woke up, regardless of the actual interval.
                try? await Task.sleep(for: .seconds(self.nextInterval), clock: .suspending)
            }
        }
    }

    func refresh() async {
        do {
            let snapshot = try await client.fetchUsage()
            lastKnownUsage = LastKnownUsage(snapshot: snapshot, fetchedAt: Date())
            state = .loaded(snapshot)
            nextInterval = Self.normalInterval
        } catch let error as ClaudeUsageError {
            state = .failed(message: error.errorDescription ?? String(localized: "Unknown error"), lastKnown: lastKnownUsage)
            if case .rateLimited(let retryAfter) = error {
                nextInterval = max(retryAfter ?? Self.rateLimitedInterval, Self.rateLimitedInterval)
            } else {
                nextInterval = Self.normalInterval
            }
        } catch {
            state = .failed(message: error.localizedDescription, lastKnown: lastKnownUsage)
            nextInterval = Self.normalInterval
        }
    }
}
