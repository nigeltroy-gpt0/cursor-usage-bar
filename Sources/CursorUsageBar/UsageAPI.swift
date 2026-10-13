import Foundation

/// Response of GET https://cursor.com/api/usage-summary. Amounts are in cents.
struct UsageSummary: Decodable {
    struct Bucket: Decodable {
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let remaining: Double?
    }

    struct Usage: Decodable {
        let overall: Bucket?
        let plan: Bucket?
        let onDemand: Bucket?
    }

    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let isUnlimited: Bool?
    let individualUsage: Usage?
    let teamUsage: Usage?
}

/// Normalized view of the summary for display.
struct UsageSnapshot {
    let usedDollars: Double
    let limitDollars: Double?
    let onDemandUsedDollars: Double?
    let onDemandLimitDollars: Double?
    let periodStart: Date?
    let periodEnd: Date?
    let membershipType: String?
    let isUnlimited: Bool
    let fetchedAt: Date

    var fraction: Double? {
        guard let limit = limitDollars, limit > 0 else { return nil }
        return usedDollars / limit
    }

    var daysLeft: Int? {
        guard let end = periodEnd else { return nil }
        let secs = end.timeIntervalSinceNow
        return secs > 0 ? Int((secs / 86_400).rounded(.up)) : 0
    }

    init(summary s: UsageSummary, fetchedAt: Date = Date()) {
        let main = s.individualUsage?.overall ?? s.individualUsage?.plan
        usedDollars = (main?.used ?? 0) / 100
        limitDollars = main?.limit.map { $0 / 100 }

        let onDemand = s.individualUsage?.onDemand ?? s.teamUsage?.onDemand
        if let od = onDemand, od.enabled ?? true, let used = od.used, used > 0 {
            onDemandUsedDollars = used / 100
            onDemandLimitDollars = od.limit.map { $0 / 100 }
        } else {
            onDemandUsedDollars = nil
            onDemandLimitDollars = nil
        }

        periodStart = s.billingCycleStart.flatMap(Self.parseDate)
        periodEnd = s.billingCycleEnd.flatMap(Self.parseDate)
        membershipType = s.membershipType
        isUnlimited = s.isUnlimited ?? false
        self.fetchedAt = fetchedAt
    }

    private static func parseDate(_ str: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: str) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: str)
    }
}

enum UsageAPIError: LocalizedError {
    case http(Int)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Cursor API returned HTTP \(code)."
        case .unauthorized: return "Cursor session expired. Open Cursor to refresh your login."
        }
    }
}

enum UsageAPI {
    static func fetchSummary(credentials: CursorCredentials) async throws -> UsageSnapshot {
        var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        req.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw UsageAPIError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw UsageAPIError.http(http.statusCode) }
        }
        return UsageSnapshot(summary: try JSONDecoder().decode(UsageSummary.self, from: data))
    }
}
