import Foundation

// The last snapshot that was fetched successfully, kept around so a later
// failure — network, auth, Keychain, anything — can still show something
// useful instead of a blank state.
struct LastKnownUsage {
    let snapshot: UsageSnapshot
    let fetchedAt: Date

    var age: TimeInterval {
        Date().timeIntervalSince(fetchedAt)
    }
}

// Persistence for `LastKnownUsage`, so a relaunch shows real numbers right
// away instead of an empty popover — and can skip the initial fetch
// entirely while what was stored is still fresh.
enum UsageCache {
    private static let defaultsKey = "LastKnownUsage"
    // Past this, the stored windows have almost certainly reset and their
    // numbers would be actively misleading rather than merely stale.
    private static let maximumAge: TimeInterval = 24 * 60 * 60

    static func save(_ usage: LastKnownUsage) {
        guard let data = try? JSONEncoder().encode(Payload(usage)) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func load() -> LastKnownUsage? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let usage = payload.lastKnownUsage
        guard usage.age < maximumAge else { return nil }
        return usage
    }

    // A storage shape of its own rather than making `UsageSnapshot`
    // `Codable`: the snapshot's decoding is tailored to the API's JSON
    // (snake_case keys, microsecond timestamps) and shouldn't have to
    // double as a file format.
    private struct Payload: Codable {
        struct Window: Codable {
            let utilization: Double
            let resetsAt: Date?

            init(_ window: UsageWindow) {
                utilization = window.utilization
                resetsAt = window.resetsAt
            }

            var usageWindow: UsageWindow {
                UsageWindow(utilization: utilization, resetsAt: resetsAt)
            }
        }

        let fiveHour: Window
        let sevenDay: Window
        let fetchedAt: Date

        init(_ usage: LastKnownUsage) {
            fiveHour = Window(usage.snapshot.fiveHour)
            sevenDay = Window(usage.snapshot.sevenDay)
            fetchedAt = usage.fetchedAt
        }

        var lastKnownUsage: LastKnownUsage {
            LastKnownUsage(
                snapshot: UsageSnapshot(fiveHour: fiveHour.usageWindow, sevenDay: sevenDay.usageWindow),
                fetchedAt: fetchedAt
            )
        }
    }
}
