import AppKit
import Foundation
import ServiceManagement

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
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
    }

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = Self.refreshOptions.contains(saved) ? saved : 5
        showDaysLeftInMenuBar = defaults.object(forKey: Keys.showDaysLeft) as? Bool ?? true
        showLeftSuffix = defaults.bool(forKey: Keys.showLeftSuffix)
        showPercentageInMenuBar = defaults.bool(forKey: Keys.showPercentage)
        refreshLaunchAtLoginState()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        scheduleTimer()
        refresh()
    }

    // MARK: - Fetching

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let creds = try CursorAuth.loadCredentials()
                snapshot = try await UsageAPI.fetchSummary(credentials: creds)
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

    // MARK: - Formatting

    var menuBarTitle: String {
        guard let s = snapshot else { return errorMessage == nil ? "$…" : "$ –" }
        var title: String
        if showPercentageInMenuBar, let f = s.fraction, !s.isUnlimited {
            title = "\(Int((f * 100).rounded(.up)))%"
        } else if let limit = s.limitDollars, !s.isUnlimited {
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

    /// Rounded up to the nearest dollar, for the compact menu bar title.
    static func wholeMoney(_ value: Double) -> String {
        "$" + String(Int(value.rounded(.up)))
    }

    static func money(_ value: Double) -> String {
        "$" + String(format: "%.2f", value)
    }
}
