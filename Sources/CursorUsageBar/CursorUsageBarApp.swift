import SwiftUI

@main
struct CursorUsageBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(store: store)
        } label: {
            Text(store.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

struct UsageMenuView: View {
    @ObservedObject var store: UsageStore

    private static let periodFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let s = store.snapshot { usageSection(s) }
            if let err = store.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            settingsSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { store.refreshLaunchAtLoginState() }
    }

    private var header: some View {
        HStack {
            Text("Cursor Usage").font(.headline)
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
            }
        }
    }

    @ViewBuilder
    private func usageSection(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageStore.money(s.usedDollars))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if let limit = s.limitDollars, !s.isUnlimited {
                    Text("of \(UsageStore.money(limit))").foregroundStyle(.secondary)
                }
                Spacer()
                if let f = s.fraction {
                    Text(String(format: "%.2f%%", f * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let f = s.fraction {
                ProgressView(value: min(f, 1))
                    .tint(f >= 0.9 ? .red : f >= 0.7 ? .orange : .accentColor)
            }
            if let odUsed = s.onDemandUsedDollars {
                let limitText = s.onDemandLimitDollars.map { " of \(UsageStore.money($0))" } ?? ""
                Text("On-demand: \(UsageStore.money(odUsed))\(limitText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        if let start = s.periodStart, let end = s.periodEnd {
            HStack {
                Label {
                    Text("\(Self.periodFormatter.string(from: start)) – \(Self.periodFormatter.string(from: end))")
                } icon: { Image(systemName: "calendar") }
                Spacer()
                if let days = s.daysLeft {
                    Text(days == 1 ? "1 day left" : "\(days) days left").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }

        if let plan = s.membershipType {
            Text("Plan type: \(plan.capitalized)").font(.callout)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Refresh every", selection: $store.refreshMinutes) {
                ForEach(UsageStore.refreshOptions, id: \.self) { m in
                    Text(UsageStore.refreshLabel(minutes: m)).tag(m)
                }
            }
            Toggle("Show usage percentage in menu bar", isOn: $store.showPercentageInMenuBar)
            Toggle("Show days left in menu bar", isOn: $store.showDaysLeftInMenuBar)
            if store.showDaysLeftInMenuBar {
                Toggle("Show \"left\" suffix", isOn: $store.showLeftSuffix)
                    .padding(.leading, 20)
            }
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            if let note = store.launchAtLoginNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var footer: some View {
        HStack {
            if let s = store.snapshot {
                Text("Updated \(s.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dashboard") {
                NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard?tab=usage")!)
            }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}
