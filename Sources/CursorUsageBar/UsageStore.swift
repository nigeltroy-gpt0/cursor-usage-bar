import AppKit
import Foundation
import ServiceManagement

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var todayDollars: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    @Published var refreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: Keys.refreshMinutes)
            scheduleTimer()
        }
    }

    @Published var showDaysLeftInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showDaysLeftInMenuBar, forKey: Keys.showDaysLeft) }
    }

    @Published var showLeftSuffix: Bool {
        didSet { UserDefaults.standard.set(showLeftSuffix, forKey: Keys.showLeftSuffix) }
    }

    @Published var showPercentageInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showPercentageInMenuBar, forKey: Keys.showPercentage) }
    }

    /// User-defined limit per billing period, used only when the plan has no limit of its own.
    @Published var customLimitDollars: Double? {
        didSet {
            if let v = customLimitDollars, v <= 0 { customLimitDollars = nil; return }
            UserDefaults.standard.set(customLimitDollars, forKey: Keys.customLimit)
        }
    }

    /// Refresh interval choices, in minutes.
    static let refreshOptions = [5, 15, 60, 1440]

    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginNote: String?

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private enum Keys {
        static let refreshMinutes = "refreshMinutes"
        static let showDaysLeft = "showDaysLeftInMenuBar"
        static let showLeftSuffix = "showLeftSuffix"
        static let showPercentage = "showPercentageInMenuBar"
        static let customLimit = "customLimitDollars"
    }

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = Self.refreshOptions.contains(saved) ? saved : 5
        showDaysLeftInMenuBar = defaults.object(forKey: Keys.showDaysLeft) as? Bool ?? true
        showLeftSuffix = defaults.bool(forKey: Keys.showLeftSuffix)
        showPercentageInMenuBar = defaults.bool(forKey: Keys.showPercentage)
        customLimitDollars = (defaults.object(forKey: Keys.customLimit) as? Double).flatMap { $0 > 0 ? $0 : nil }
        refreshLaunchAtLoginState()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        DataSource.shared.onChange = { [weak self] in
            self?.snapshot = nil
            self?.todayDollars = nil
            self?.refresh()
        }
        DataSource.shared.installTestMenu()

        scheduleTimer()
        refresh()
        Updater.shared.start()
    }

    // MARK: - Fetching

    func refresh() {
        guard !isLoading else { return }
        if !DataSource.shared.useLiveData {
            snapshot = StubData.snapshot()
            todayDollars = StubData.today()
            errorMessage = nil
            return
        }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let creds = try CursorAuth.loadCredentials()
                async let summary = UsageAPI.fetchSummary(credentials: creds)
                async let today = UsageAPI.fetchDailyUsage(credentials: creds, days: 1)
                snapshot = try await summary
                if let t = (try? await today)?.first?.dollars { todayDollars = t }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, refreshMinutes) * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginNote = error.localizedDescription
        }
        refreshLaunchAtLoginState()
    }

    func refreshLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginNote = nil
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginNote = "Approve in System Settings → General → Login Items."
        default:
            launchAtLogin = false
        }
    }

    // MARK: - Limit

    /// True once usage has loaded and the plan turns out to have no limit of its own.
    var planHasNoLimit: Bool {
        snapshot.map { $0.planLimitDollars == nil } ?? false
    }

    /// The plan's limit if it has one, otherwise the user's own limit (if set).
    var effectiveLimitDollars: Double? {
        snapshot?.planLimitDollars ?? customLimitDollars
    }

    /// False only when the plan has no limit and the user hasn't set one, so no percentage exists.
    /// (Also true before usage has loaded, so Settings doesn't flicker on launch.)
    var hasAnyLimit: Bool {
        snapshot == nil || effectiveLimitDollars != nil
    }

    var isUsingCustomLimit: Bool {
        snapshot?.planLimitDollars == nil && customLimitDollars != nil
    }

    /// Fraction of the effective limit used, or nil when there's no limit at all.
    var fraction: Double? {
        guard let s = snapshot, let limit = effectiveLimitDollars, limit > 0 else { return nil }
        return s.usedDollars / limit
    }

    // MARK: - Formatting

    var menuBarTitle: String {
        guard let s = snapshot else { return errorMessage == nil ? "$…" : "$ –" }
        var title: String
        if showPercentageInMenuBar, let f = fraction {
            title = "\(Int((f * 100).rounded(.up)))%"
        } else if let limit = effectiveLimitDollars {
            title = "\(Self.wholeMoney(s.usedDollars))/\(Self.wholeMoney(limit))"
        } else {
            title = Self.wholeMoney(s.usedDollars)
        }
        if showDaysLeftInMenuBar, let days = s.daysLeft {
            title += " · \(days)d" + (showLeftSuffix ? " left" : "")
        }
        return title
    }

    static func refreshLabel(minutes: Int) -> String {
        switch minutes {
        case 1440: return "1 day"
        case 60: return "1 hour"
        default: return "\(minutes) minutes"
        }
    }

    private static func currencyFormatter(fractionDigits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f
    }
    private static let centsFormatter = currencyFormatter(fractionDigits: 2)
    private static let dollarsFormatter = currencyFormatter(fractionDigits: 0)

    /// Rounded up to the nearest dollar, for the compact menu bar title, e.g. "$1,500".
    static func wholeMoney(_ value: Double) -> String {
        dollarsFormatter.string(from: NSNumber(value: value.rounded(.up))) ?? "$\(Int(value.rounded(.up)))"
    }

    /// Exact amount with cents and thousands separators, e.g. "$1,500.00".
    static func money(_ value: Double) -> String {
        centsFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}
