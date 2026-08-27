import Foundation

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    // Declaring `init(from:)` below suppresses the memberwise initializer,
    // which `UsageCache` needs to rebuild a persisted snapshot.
    init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization) ?? 0
        let raw = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        resetsAt = Self.parseDate(raw)
    }

    // The API returns microsecond precision (6 fractional digits), which
    // ISO8601DateFormatter's fractional-seconds mode doesn't accept directly.
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        guard let dotRange = raw.range(of: ".") else {
            return ISO8601DateFormatter().date(from: raw)
        }
        let afterDot = raw[dotRange.upperBound...]
        guard let tzIndex = afterDot.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else {
            return nil
        }
        let millis = String(afterDot[..<tzIndex].prefix(3))
        let rebuilt = raw[..<dotRange.upperBound] + millis + afterDot[tzIndex...]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: String(rebuilt))
    }

    // Ratio of allowance consumed to time elapsed in the window: 1.0 means
    // usage is tracking exactly with time, >1 means it'll likely run out
    // before reset, <1 means there's a buffer. Nil right at the start of a
    // window (elapsed ≈ 0) since the ratio would blow up to a meaningless
    // number, and nil once there's no reset date to measure elapsed time against.
    func pace(windowDuration: TimeInterval) -> Double? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0, remaining < windowDuration else { return nil }
        let elapsedFraction = 1 - remaining / windowDuration
        guard elapsedFraction > 0.001 else { return nil }
        return (utilization / 100) / elapsedFraction
    }
}

struct UsageSnapshot: Decodable {
    // The API doesn't report these, but the window names ("five_hour",
    // "seven_day") are exactly their fixed durations.
    static let fiveHourDuration: TimeInterval = 5 * 60 * 60
    static let sevenDayDuration: TimeInterval = 7 * 24 * 60 * 60

    let fiveHour: UsageWindow
    let sevenDay: UsageWindow

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

enum ClaudeUsageError: Error, LocalizedError {
    case notAuthenticated
    case rateLimited(retryAfter: TimeInterval?)
    case server(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String(localized: "Session expired.")
        case .rateLimited:
            return String(localized: "Too many requests.")
        case .server(let code):
            return String(localized: "Server error (\(code)).")
        case .decoding:
            return String(localized: "Unknown response format.")
        }
    }

    // Only failures the user can actually act on get a suggestion; for the
    // rest the popover shows when the app retries by itself instead.
    var recoverySuggestion: String? {
        switch self {
        case .notAuthenticated:
            return KeychainCredentialError.signInHint
        case .rateLimited, .server, .decoding:
            return nil
        }
    }
}

struct ClaudeUsageClient {
    private let session = URLSession(configuration: .ephemeral)
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetchUsage() async throws -> UsageSnapshot {
        let credentials = try KeychainCredentialReader.loadCredentials()
        // Failing here rather than on the wire keeps an expired session from
        // spending a request — and a slot in the server's rate limit — on a
        // call that can only come back 401.
        guard !credentials.isExpired else {
            throw ClaudeUsageError.notAuthenticated
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.server(-1)
        }
        if http.statusCode == 401 {
            throw ClaudeUsageError.notAuthenticated
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw ClaudeUsageError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeUsageError.server(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            throw ClaudeUsageError.decoding
        }
    }
}
