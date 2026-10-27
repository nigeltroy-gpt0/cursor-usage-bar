import AppKit
import Charts
import SwiftUI

@MainActor
final class HistoryModel: ObservableObject {
    static let days = 30

    @Published private(set) var days: [DailyUsage] = []
    @Published private(set) var summary: UsageSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadedAt: Date?

    func reset() {
        days = []
        summary = nil
    }

    func load() {
        guard !isLoading else { return }
        if !DataSource.shared.useLiveData {
            days = StubData.daily(days: Self.days)
            summary = StubData.snapshot()
            loadedAt = Date()
            errorMessage = nil
            return
        }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let creds = try CursorAuth.loadCredentials()
                async let daily = UsageAPI.fetchDailyUsage(credentials: creds, days: Self.days)
                async let snap = UsageAPI.fetchSummary(credentials: creds)
                days = try await daily
                if let s = try? await snap { summary = s }
                loadedAt = Date()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private let model = HistoryModel()
    private var window: NSWindow?

    func reloadIfOpen() {
        guard window?.isVisible == true else { return }
        model.reset()
        model.load()
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "\(Updater.productName) — Last \(HistoryModel.days) Days"
            w.contentViewController = NSHostingController(rootView: HistoryView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model.load()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var hovered: DailyUsage?

    private var total: Double { model.days.reduce(0) { $0 + $1.dollars } }
    private var peak: DailyUsage? { model.days.max { $0.dollars < $1.dollars } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            if model.days.isEmpty {
                Group {
                    if let err = model.errorMessage {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    hoverReadout
                    chart
                }
            }
        }
        .padding(Theme.Space.l)
        .font(.appBody)
        .controlSize(.regular)
        .frame(minWidth: 520, minHeight: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l + Theme.Space.s) {
            stat("Total", UsageStore.money(total))
            stat("Daily avg (30d)", UsageStore.money(model.days.isEmpty ? 0 : total / Double(model.days.count)))
            if let avg = model.summary?.periodDailyAverage {
                stat("Daily avg (billing period)", UsageStore.money(avg))
            }
            if let p = peak, p.dollars > 0 {
                stat("Peak", "\(UsageStore.money(p.dollars)) · \(p.date.formatted(.dateTime.month(.abbreviated).day()))")
            }
            Spacer()
        }
    }

    /// Always laid out (blank when not hovering) so nothing moves as the pointer enters or leaves the chart.
    private var hoverReadout: some View {
        Text(hovered.map {
            "\($0.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())): \(UsageStore.money($0.dollars))"
        } ?? " ")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.appHeading).monospacedDigit()
        }
    }

    private var chart: some View {
        let axis = YAxisScale(maxValue: peak?.dollars ?? 0)
        return Chart(model.days) { d in
            BarMark(
                x: .value("Day", d.date, unit: .day),
                y: .value("Spend", d.dollars)
            )
            .foregroundStyle(hovered?.id == d.id ? Color.accentColor : Color.accentColor.opacity(0.65))
            .cornerRadius(2)
        }
        .chartYScale(domain: 0...axis.top)
        .chartYAxis {
            AxisMarks(position: .leading, values: axis.ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(axis.label(v)).font(.appBody) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.appBody)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let x = location.x - geo[proxy.plotAreaFrame].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                hovered = model.days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
                            } else {
                                hovered = nil
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }
}

/// Picks a "nice" y-axis top and tick step (1/2/2.5/5 × 10ⁿ) from the highest daily spend,
/// so a $3 peak and a $300 peak both get a readable axis.
struct YAxisScale {
    let top: Double
    let step: Double

    init(maxValue: Double, targetTicks: Double = 4) {
        guard maxValue > 0 else {
            top = 1; step = 0.25
            return
        }
        let raw = maxValue / targetTicks
        let magnitude = pow(10, floor(log10(raw)))
        let s = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
        step = s
        top = max(s, ceil(maxValue / s) * s)
    }

    var ticks: [Double] {
        Array(stride(from: 0, through: top + step / 2, by: step))
    }

    func label(_ v: Double) -> String {
        step < 1 ? String(format: "$%.2f", v) : String(format: "$%.0f", v)
    }
}
