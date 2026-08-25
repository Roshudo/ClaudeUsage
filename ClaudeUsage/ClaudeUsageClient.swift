import Foundation

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
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
}

struct UsageSnapshot: Decodable {
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
            return String(localized: "Session expired – open Xcode's Claude assistant once.")
        case .rateLimited:
            return String(localized: "Too many requests – please wait a moment before refreshing again.")
        case .server(let code):
            return String(localized: "Server error (\(code)).")
        case .decoding:
            return String(localized: "Unknown response format.")
        }
    }
}

struct ClaudeUsageClient {
    private let session = URLSession(configuration: .ephemeral)
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetchUsage() async throws -> UsageSnapshot {
        let accessToken = try KeychainCredentialReader.loadAccessToken()

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
