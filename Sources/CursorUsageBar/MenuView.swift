import SwiftUI

struct UsageMenuView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var updater = Updater.shared

    private static let periodFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    @State private var showingSettings: Bool

    init(store: UsageStore, showingSettings: Bool = false) {
        self.store = store
        _showingSettings = State(initialValue: showingSettings)
    }

    var body: some View {
        // Both pages are always laid out in one ZStack, so they share the same (larger) size
        // and the window doesn't resize when switching between them.
        ZStack(alignment: .topLeading) {
            mainPage
                .opacity(showingSettings ? 0 : 1)
                .allowsHitTesting(!showingSettings)
                .accessibilityHidden(showingSettings)
            settingsPage
                .opacity(showingSettings ? 1 : 0)
                .allowsHitTesting(showingSettings)
                .accessibilityHidden(!showingSettings)
        }
        .padding(Theme.panelPadding)
        .frame(width: Theme.panelWidth)
        // One font size for all body text and controls (buttons, pickers, checkboxes).
        .font(.appBody)
        .controlSize(.regular)
        .onAppear { store.refreshLaunchAtLoginState() }
        .onDisappear { showingSettings = false }
    }

    private func setShowingSettings(_ value: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) { showingSettings = value }
    }

    // MARK: - Main page

    private var mainPage: some View {
        // 12pt between sections, as in production v1.4.0.
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if let s = store.snapshot { usageSection(s) }
            if let err = store.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Fills the leftover height and pins the actions and footer to the bottom,
            // without the doubled stack spacing a Spacer would add.
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                actions
                Divider()
                footer
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Updater.productName).font(.appTitle)
                Text("v\(Updater.currentVersion)").font(.appVersion).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                iconButton("arrow.clockwise", help: "Refresh now") { store.refresh() }
            }
            iconButton("gearshape", help: "Settings") { setShowingSettings(true) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.appHeroDetail)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder
    private func usageSection(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageStore.money(s.usedDollars))
                    .font(.appHero)
                    .monospacedDigit()
                if let limit = s.limitDollars, !s.isUnlimited {
                    Text("of \(UsageStore.money(limit))").font(.appHeroDetail).foregroundStyle(.secondary)
                }
                Spacer()
                if let f = s.fraction {
                    Text(String(format: "%.2f%%", f * 100))
                        .font(.appHeroDetail)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let f = s.fraction {
                ProgressView(value: min(f, 1))
                    .tint(f >= 0.9 ? .red : f >= 0.7 ? .orange : .accentColor)
            }
        }

        // Label / value rows: labels share one column, values line up, extras sit on the right.
        // Equal row heights and no extra vertical spacing keep an even rhythm.
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
            GridRow {
                rowLabel("Today")
                Text(store.todayDollars.map { UsageStore.money($0) } ?? "–").monospacedDigit()
            }
            if let avg = s.periodDailyAverage {
                GridRow {
                    rowLabel("Daily average")
                    Text(UsageStore.money(avg)).monospacedDigit()
                }
            }
            if let projected = s.projectedDollars, !s.isUnlimited {
                GridRow {
                    rowLabel("Projected")
                    HStack(spacing: Theme.Space.s) {
                        Text(UsageStore.money(projected))
                            .monospacedDigit()
                            .foregroundStyle((s.limitDollars.map { projected > $0 } ?? false) ? .orange : .primary)
                        Spacer(minLength: 0)
                        Text("at current pace").foregroundStyle(.secondary)
                    }
                }
            }
            if let start = s.periodStart, let end = s.periodEnd {
                GridRow {
                    rowLabel("Billing period")
                    HStack(spacing: Theme.Space.s) {
                        Text("\(Self.periodFormatter.string(from: start)) – \(Self.periodFormatter.string(from: end))")
                        Spacer(minLength: 0)
                        if let days = s.daysLeft {
                            Text(days == 1 ? "1 day left" : "\(days) days left").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let plan = s.membershipType {
                GridRow {
                    rowLabel("Plan type")
                    Text(plan.capitalized)
                }
            }
            if let odUsed = s.onDemandUsedDollars {
                GridRow {
                    rowLabel("On-demand")
                    Text(UsageStore.money(odUsed) + (s.onDemandLimitDollars.map { " of \(UsageStore.money($0))" } ?? ""))
                        .monospacedDigit()
                }
            }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(minHeight: Theme.rowHeight)
    }

    /// Primary actions, side by side at equal widths.
    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            wideButton("See usage history") { HistoryWindowController.shared.show() }
            wideButton("Dashboard") {
                NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard?tab=usage")!)
            }
        }
    }

    private func wideButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if let s = store.snapshot {
                Text("Updated \(s.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    // MARK: - Settings page

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ZStack {
                Text("Settings").font(.appTitle)
                HStack {
                    Button { setShowingSettings(false) } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
            settingsGroup("General") {
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach(UsageStore.refreshOptions, id: \.self) { m in
                        Text(UsageStore.refreshLabel(minutes: m)).tag(m)
                    }
                }
                .fixedSize()
                Toggle("Launch at login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                if let note = store.launchAtLoginNote {
                    hint(note)
                }
            }
            settingsGroup("Menu bar") {
                Toggle("Show percentage instead of dollars", isOn: $store.showPercentageInMenuBar)
                Toggle("Show days left", isOn: $store.showDaysLeftInMenuBar)
                if store.showDaysLeftInMenuBar {
                    Toggle("Show \u{201C}left\u{201D} suffix", isOn: $store.showLeftSuffix)
                        .padding(.leading, Theme.Space.l + Theme.Space.xs)
                }
            }
            settingsGroup("Updates") {
                Toggle("Automatically check for updates daily", isOn: $updater.autoUpdateEnabled)
                if let text = updater.status ?? updatesHint {
                    hint(text)
                }
                HStack(spacing: Theme.Space.s) {
                    Button("Check for updates") { updater.checkNow(manual: true) }
                        .disabled(updater.isChecking)
                    Spacer()
                    Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(.appBodyEmphasis).foregroundStyle(.secondary)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// Only shown when it adds something the checkbox label doesn't already say.
    private var updatesHint: String? {
        updater.autoUpdateEnabled ? nil : "Updates install only when you click Check for updates."
    }
}
