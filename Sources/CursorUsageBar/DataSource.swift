import AppKit
import Foundation

/// Where usage numbers come from. Release builds always use live Cursor data.
/// Test builds start on stub data (no Keychain prompt, no network), and right-clicking the
/// menu bar item offers "Connect to and use live Cursor data". The choice resets on relaunch.
@MainActor
final class DataSource: NSObject {
    static let shared = DataSource()

    private(set) var useLiveData = !Updater.isTestBuild
    /// Called after the user switches sources, so views can clear and reload.
    var onChange: (() -> Void)?

    private var monitor: Any?

    func installTestMenu() {
        guard Updater.isTestBuild, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            // MenuBarExtra's status item lives in an NSStatusBarWindow; other right-clicks pass through.
            guard let self, let window = event.window,
                  NSStringFromClass(type(of: window)).contains("StatusBarWindow"),
                  let view = window.contentView
            else { return event }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: view)
            return nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: useLiveData ? "Test build: live Cursor data" : "Test build: stub data",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Connect to and use live Cursor data",
                              action: #selector(toggleLiveData), keyEquivalent: "")
        item.target = self
        item.state = useLiveData ? .on : .off
        menu.addItem(item)
        return menu
    }

    @objc private func toggleLiveData() {
        useLiveData.toggle()
        onChange?()
        HistoryWindowController.shared.reloadIfOpen()
    }
}

/// Deterministic fake usage for test builds: the same day always gets the same amount.
enum StubData {
    static func daily(days: Int, now: Date = Date()) -> [DailyUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<days).map { i in
            let day = cal.date(byAdding: .day, value: i - (days - 1), to: today)!
            return DailyUsage(date: day, dollars: amount(for: day, now: now))
        }
    }

    static func today(now: Date = Date()) -> Double {
        amount(for: Calendar.current.startOfDay(for: now), now: now)
    }

    /// Current calendar month (UTC) as the billing period, with a $1500 limit.
    static func snapshot(now: Date = Date()) -> UsageSnapshot {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = utc.date(from: utc.dateComponents([.year, .month], from: now))!
        let end = utc.date(byAdding: .month, value: 1, to: start)!
        let elapsedDays = (utc.dateComponents([.day], from: start, to: now).day ?? 0) + 1
        let used = daily(days: elapsedDays, now: now).reduce(0) { $0 + $1.dollars }

        let iso = ISO8601DateFormatter()
        let summary = UsageSummary(
            billingCycleStart: iso.string(from: start),
            billingCycleEnd: iso.string(from: end),
            membershipType: "pro",
            limitType: "user",
            isUnlimited: false,
            individualUsage: .init(
                overall: .init(enabled: true, used: used * 100, limit: 150_000, remaining: nil),
                plan: nil, onDemand: nil),
            teamUsage: nil
        )
        return UsageSnapshot(summary: summary, fetchedAt: now)
    }

    private static func amount(for day: Date, now: Date) -> Double {
        var x = UInt64(max(0, Int(day.timeIntervalSince1970 / 86_400)))
        x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        x ^= x >> 33
        let r = Double(x % 10_000) / 10_000

        let weekday = Calendar.current.component(.weekday, from: day)
        let weekend = weekday == 1 || weekday == 7
        var dollars = r < 0.15 ? 0 : (weekend ? r * 6 : 4 + r * 36)
        if Calendar.current.isDate(day, inSameDayAs: now) {
            let dayStart = Calendar.current.startOfDay(for: now)
            dollars *= now.timeIntervalSince(dayStart) / 86_400
        }
        return (dollars * 100).rounded() / 100
    }
}
