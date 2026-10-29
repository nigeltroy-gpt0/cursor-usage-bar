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

    /// The plan's own spending limit, or nil if the plan has none (unlimited, or no limit reported).
    var planLimitDollars: Double? {
        guard !isUnlimited, let limit = limitDollars, limit > 0 else { return nil }
        return limit
    }

    var daysLeft: Int? {
        guard let end = periodEnd else { return nil }
        let secs = end.timeIntervalSinceNow
        return secs > 0 ? Int((secs / 86_400).rounded(.up)) : 0
    }

    /// Spend so far divided by the days elapsed in the billing period (today counts as a day).
    var periodDailyAverage: Double? {
        guard let start = periodStart else { return nil }
        var elapsed = max(1, (fetchedAt.timeIntervalSince(start) / 86_400).rounded(.up))
        if let end = periodEnd { elapsed = min(elapsed, max(1, (end.timeIntervalSince(start) / 86_400).rounded())) }
        return usedDollars / elapsed
    }

    /// Spend by the end of the billing period if the current daily average holds.
    var projectedDollars: Double? {
        guard let avg = periodDailyAverage, let start = periodStart, let end = periodEnd else { return nil }
        return avg * max(1, (end.timeIntervalSince(start) / 86_400).rounded())
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

/// One row of POST https://cursor.com/api/dashboard/get-filtered-usage-events.
/// `chargedCents` is what counts toward the usage-summary total.
struct UsageEvent: Decodable {
    let timestamp: String
    let chargedCents: Double?

    var date: Date? {
        Double(timestamp).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

private struct UsageEventsPage: Decodable {
    let totalUsageEventsCount: Int?
    let usageEventsDisplay: [UsageEvent]?
}

struct DailyUsage: Identifiable {
    let date: Date  // local start of day
    let dollars: Double
    var id: Date { date }
}

enum UsageAPI {
    static func fetchSummary(credentials: CursorCredentials) async throws -> UsageSnapshot {
        var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        req.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
        let data = try await perform(req)
        return UsageSnapshot(summary: try JSONDecoder().decode(UsageSummary.self, from: data))
    }

    /// All usage events in [start, end], following pagination.
    static func fetchEvents(credentials: CursorCredentials, from start: Date, to end: Date) async throws -> [UsageEvent] {
        let pageSize = 500
        var events: [UsageEvent] = []
        for page in 1...100 {
            var req = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!)
            req.httpMethod = "POST"
            req.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "startDate": String(Int64(start.timeIntervalSince1970 * 1000)),
                "endDate": String(Int64(end.timeIntervalSince1970 * 1000)),
                "page": page,
                "pageSize": pageSize,
            ])
            let result = try JSONDecoder().decode(UsageEventsPage.self, from: try await perform(req))
            let batch = result.usageEventsDisplay ?? []
            events += batch
            if batch.count < pageSize { break }
            if let total = result.totalUsageEventsCount, events.count >= total { break }
        }
        return events
    }

    /// Spend per local calendar day for the `days` days ending today (zero-filled).
    static func fetchDailyUsage(credentials: CursorCredentials, days: Int) async throws -> [DailyUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let events = try await fetchEvents(credentials: credentials, from: start, to: Date())

        var totals: [Date: Double] = [:]
        for e in events {
            guard let d = e.date else { continue }
            totals[cal.startOfDay(for: d), default: 0] += (e.chargedCents ?? 0) / 100
        }
        return (0..<days).map { i in
            let day = cal.date(byAdding: .day, value: i, to: start)!
            return DailyUsage(date: day, dollars: totals[day] ?? 0)
        }
    }

    private static func perform(_ request: URLRequest) async throws -> Data {
        var req = request
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw UsageAPIError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw UsageAPIError.http(http.statusCode) }
        }
        return data
    }
}
