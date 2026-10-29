// Renders the app's views to PNGs (stub data, light + dark) without launching the app.
// Built and run by ../../snapshot.sh; output goes to build/snapshots/.
import AppKit
import SwiftUI

@main
struct Snapshot {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/snapshots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let store = UsageStore()
        let history = HistoryModel()
        history.load()

        store.customLimitDollars = nil
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(UsageMenuView(store: store), appearance: appearance, to: out.appendingPathComponent("menu-main-\(name).png"))
            render(UsageMenuView(store: store, showingSettings: true), appearance: appearance,
                   to: out.appendingPathComponent("menu-settings-\(name).png"))
            render(HistoryView(model: history).frame(width: 640, height: 400), appearance: appearance,
                   to: out.appendingPathComponent("history-\(name).png"))
        }

        // A plan without a spending limit: first with no custom limit, then with one set.
        DataSource.shared.stubPlanHasLimit = false
        store.refresh()
        render(UsageMenuView(store: store), appearance: .darkAqua, to: out.appendingPathComponent("nolimit-main-dark.png"))
        render(UsageMenuView(store: store, showingSettings: true), appearance: .darkAqua,
               to: out.appendingPathComponent("nolimit-settings-dark.png"))
        store.customLimitDollars = 500
        print("custom limit menu bar title:", store.menuBarTitle)
        render(UsageMenuView(store: store), appearance: .darkAqua, to: out.appendingPathComponent("customlimit-main-dark.png"))
        render(UsageMenuView(store: store, showingSettings: true), appearance: .darkAqua,
               to: out.appendingPathComponent("customlimit-settings-dark.png"))
        store.customLimitDollars = nil
    }

    @MainActor static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = size
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path) (\(Int(size.width))×\(Int(size.height)) pt)")
    }
}
