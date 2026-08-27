import Foundation
import Observation

// What number the menu bar (and, when selected, the popover bars) lead
// with. Lives on the view model rather than in `StatusItemController` since
// both it and `UsagePopoverView` need to read the current choice.
enum MenuBarMetric: String {
    case percent
    case overloadFactor

    var title: LocalizedStringResource {
        switch self {
        case .percent:
            return "Percentage"
        case .overloadFactor:
            return "Overload Factor"
        }
    }
}

@Observable
final class UsageViewModel {
    // A failure split into the three things that keep a gray menu bar icon
    // from turning into guesswork: what went wrong, what the user can do
    // about it, and when the app will try again on its own.
    struct Failure {
        let message: String
        let hint: String?
        let retryAt: Date?
    }

    enum State {
        case loading
        case loaded(UsageSnapshot)
        case failed(Failure)
    }

    private static let normalInterval: Double = 3 * 60
    private static let rateLimitedInterval: Double = 5 * 60
    // Non-rate-limit failures (e.g. a transient network hiccup right after
    // launch) back off quickly instead of waiting the full normal interval,
    // so the app recovers on its own within seconds rather than minutes.
    private static let initialRetryInterval: Double = 15
    // Credential problems are re-checked against the Keychain instead of
    // the API, so polling this often costs nothing but a local read.
    private static let credentialsWatchInterval: Double = 20
    private static let menuBarMetricDefaultsKey = "MenuBarMetric"
    private static let rateLimitedUntilDefaultsKey = "RateLimitedUntil"

    private(set) var state: State = .loading
    // Kept next to `state` rather than inside it, because both the failure
    // case and the first fetch after launch fall back to it — see
    // `restoreCachedUsage()`.
    private(set) var lastKnownUsage: LastKnownUsage?
    var menuBarMetric: MenuBarMetric = MenuBarMetric(
        rawValue: UserDefaults.standard.string(forKey: UsageViewModel.menuBarMetricDefaultsKey) ?? ""
    ) ?? .percent {
        didSet {
            UserDefaults.standard.set(menuBarMetric.rawValue, forKey: Self.menuBarMetricDefaultsKey)
        }
    }
    private let client = ClaudeUsageClient()
    private var pollTask: Task<Void, Never>?
    private var nextInterval: Double = 0
    private var consecutiveFailures = 0
    // Set while the app is waiting for Claude Code to store a session other
    // than the one that just failed to authenticate. See `refresh(force:)`.
    private var awaitedCredentials: CredentialsWait?

    // The inner fingerprint is optional because "no readable credentials at
    // all" is a state worth waiting on too, and one that's distinguishable
    // from any particular stored session.
    private struct CredentialsWait {
        let fingerprint: String?
    }

    // Outlives the process on purpose: the cooldown belongs to the server,
    // not to this run of the app.
    private var rateLimitedUntil: Date? {
        get { UserDefaults.standard.object(forKey: Self.rateLimitedUntilDefaultsKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.rateLimitedUntilDefaultsKey) }
    }

    func start() {
        guard pollTask == nil else { return }
        restoreCachedUsage()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Sleeping first lets `restoreCachedUsage()` push the initial
                // fetch out when persisted data is still fresh enough.
                let delay = self.nextInterval
                if delay > 0 {
                    // .suspending pauses while the system is asleep, so the
                    // interval only counts awake time — the default clock keeps
                    // ticking through sleep, which made the next fetch fire the
                    // instant the Mac woke up, regardless of the actual interval.
                    try? await Task.sleep(for: .seconds(delay), clock: .suspending)
                }
                await self.refresh()
            }
        }
    }

    // After waking, the poll loop still has whatever was left of its
    // interval to go, so a lid opened after hours would keep showing
    // pre-sleep numbers for minutes. Restarting fetches now and realigns
    // the schedule with the wake.
    func restartPolling() {
        pollTask?.cancel()
        pollTask = nil
        nextInterval = 0
        start()
    }

    // `force` is for the Refresh menu item: an explicit user action may skip
    // the credentials wait below, since the user might have just signed in
    // and the app shouldn't insist on noticing that by itself first.
    func refresh(force: Bool = false) async {
        // A rate-limit cooldown survives a relaunch. Without that, restarting
        // fired a request straight back into the limit and returned "too many
        // requests", which looks like the restart caused it.
        if let until = rateLimitedUntil, until > Date() {
            enterRateLimitCooldown(until: until)
            return
        }

        // Auth failures never fix themselves through retrying: the widget can
        // only read the session Claude Code stores, it can't renew it.
        // Retrying on the network anyway is what tripped the rate limit in the
        // first place, so as long as the stored session is still the one that
        // failed, only the (local, free) Keychain entry is re-read.
        if !force, let awaited = awaitedCredentials,
           KeychainCredentialReader.currentFingerprint() == awaited.fingerprint {
            nextInterval = Self.credentialsWatchInterval
            return
        }

        do {
            let snapshot = try await client.fetchUsage()
            let usage = LastKnownUsage(snapshot: snapshot, fetchedAt: Date())
            lastKnownUsage = usage
            UsageCache.save(usage)
            state = .loaded(snapshot)
            awaitedCredentials = nil
            rateLimitedUntil = nil
            consecutiveFailures = 0
            nextInterval = Self.normalInterval
        } catch let error as ClaudeUsageError {
            switch error {
            case .notAuthenticated:
                enterCredentialsWait(for: error)
            case .rateLimited(let retryAfter):
                let cooldown = max(retryAfter ?? Self.rateLimitedInterval, Self.rateLimitedInterval)
                enterRateLimitCooldown(until: Date().addingTimeInterval(cooldown))
            case .server, .decoding:
                state = .failed(failure(for: error, retryAt: scheduleBackoff()))
            }
        } catch let error as KeychainCredentialError {
            // Nothing was sent over the network here either, and the fix is
            // the same as for an expired session: wait for usable credentials.
            enterCredentialsWait(for: error)
        } catch {
            let retryAt = scheduleBackoff()
            state = .failed(Failure(message: error.localizedDescription, hint: nil, retryAt: retryAt))
        }
    }

    // Persisted usage is shown immediately so a relaunch isn't a blank
    // popover, and counts as current until it's older than the polling
    // interval — a quick quit-and-relaunch shouldn't cost a request.
    private func restoreCachedUsage() {
        guard lastKnownUsage == nil, let cached = UsageCache.load() else { return }
        lastKnownUsage = cached
        guard cached.age < Self.normalInterval else { return }
        state = .loaded(cached.snapshot)
        nextInterval = min(Self.normalInterval - cached.age, Self.normalInterval)
    }

    // Both a fresh 429 and a cooldown inherited from a previous launch
    // present the same way; only the retry time differs.
    private func enterRateLimitCooldown(until: Date) {
        rateLimitedUntil = until
        consecutiveFailures = 0
        nextInterval = max(until.timeIntervalSinceNow, 1)
        state = .failed(failure(for: ClaudeUsageError.rateLimited(retryAfter: nil), retryAt: until))
    }

    // Records the fingerprint of the session that failed so `refresh(force:)`
    // can watch the Keychain rather than the API. No retry time is shown:
    // the app isn't counting down to anything, it's waiting for a new
    // session to appear — and will pick it up within seconds of that.
    private func enterCredentialsWait(for error: some LocalizedError) {
        awaitedCredentials = CredentialsWait(fingerprint: KeychainCredentialReader.currentFingerprint())
        consecutiveFailures = 0
        nextInterval = Self.credentialsWatchInterval
        state = .failed(failure(for: error, retryAt: nil))
    }

    private func failure(for error: some LocalizedError, retryAt: Date?) -> Failure {
        Failure(
            message: error.errorDescription ?? String(localized: "Unknown error"),
            hint: error.recoverySuggestion,
            retryAt: retryAt
        )
    }

    // Exponential backoff starting at `initialRetryInterval`, capped at
    // `normalInterval` so a persistent failure still settles into the same
    // polling cadence as the happy path rather than backing off forever.
    private func scheduleBackoff() -> Date {
        consecutiveFailures += 1
        let backoff = Self.initialRetryInterval * pow(2, Double(consecutiveFailures - 1))
        nextInterval = min(backoff, Self.normalInterval)
        return Date().addingTimeInterval(nextInterval)
    }
}
