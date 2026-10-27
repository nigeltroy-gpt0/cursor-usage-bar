import AppKit
import Foundation

/// Checks GitHub Releases once a day; if a newer version exists, downloads the DMG,
/// swaps the installed app bundle in place, and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "nigeltroy-gpt0/cursor-usage-bar"
    static let assetName = "cursor-usage-bar.dmg"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"
    private static let autoUpdateKey = "autoUpdateEnabled"

    /// Shown in the dropdown while updating or after a failure; nil when idle.
    @Published private(set) var status: String?

    /// When off, only "Check for updates" checks and installs; the daily check is skipped.
    @Published var autoUpdateEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUpdateEnabled, forKey: Self.autoUpdateKey) }
    }

    private var timer: Timer?
    @Published private var isRunning = false

    private init() {
        autoUpdateEnabled = UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true
    }

    /// Local test builds ("(Test) Cursor Usage Bar") never auto-update; that would replace them with the release.
    static var isTestBuild: Bool {
        Bundle.main.infoDictionary?["CUBTestBuild"] as? Bool ?? false
    }

    static var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Cursor Usage Bar"
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func start() {
        guard !Self.isTestBuild else { return }
        // Hourly tick; actually hits GitHub only when 24h have passed since the last check.
        let t = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard autoUpdateEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        checkNow()
    }

    /// `manual` = triggered from the "Check for updates" button, so report "up to date" too.
    func checkNow(manual: Bool = false) {
        guard !isRunning else { return }
        if Self.isTestBuild {
            if manual { status = "Updates are disabled in test builds." }
            return
        }
        isRunning = true
        if manual { status = "Checking for updates…" }
        Task {
            defer { isRunning = false }
            do {
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard let release = try await Self.fetchLatestRelease(),
                      Self.isVersion(release.version, newerThan: Self.currentVersion),
                      let asset = release.assets.first(where: { $0.name == Self.assetName })
                else {
                    if manual { status = "You're up to date (v\(Self.currentVersion))." }
                    return
                }
                status = "Updating to v\(release.version)…"
                try await install(from: asset.browserDownloadURL)
            } catch {
                status = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    var isChecking: Bool { isRunning }

    // MARK: - GitHub

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
        }
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease, assets }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    private static func fetchLatestRelease() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.draft || release.prerelease ? nil : release
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    enum UpdateError: LocalizedError {
        case notWritable(String), mountFailed, appNotFound, wrongBundle

        var errorDescription: String? {
            switch self {
            case .notWritable(let path): return "no permission to replace \(path)."
            case .mountFailed: return "couldn't open the downloaded DMG."
            case .appNotFound: return "the DMG didn't contain the app."
            case .wrongBundle: return "the downloaded app has an unexpected bundle ID."
            }
        }
    }

    private func install(from url: URL) async throws {
        let dest = Bundle.main.bundleURL
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: dest.path)
        else { throw UpdateError.notWritable(dest.path) }

        let (work, staged) = try await Self.stage(from: url, appName: dest.lastPathComponent,
                                                  expectedBundleID: Bundle.main.bundleIdentifier)
        try Self.launchSwap(staged: staged, dest: dest, work: work,
                            waitForPID: ProcessInfo.processInfo.processIdentifier, relaunch: true)
        NSApp.terminate(nil)
    }

    /// Downloads the DMG and copies the app out of it into a temp dir. Returns (work dir, staged .app).
    static func stage(from url: URL, appName: String, expectedBundleID: String?) async throws -> (URL, URL) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cursor-usage-bar-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            return try await stage(into: work, from: url, appName: appName, expectedBundleID: expectedBundleID)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private static func stage(into work: URL, from url: URL, appName: String,
                              expectedBundleID: String?) async throws -> (URL, URL) {
        let fm = FileManager.default
        let (downloaded, _) = try await URLSession.shared.download(from: url)
        let dmg = work.appendingPathComponent(assetName)
        try fm.moveItem(at: downloaded, to: dmg)

        let mount = work.appendingPathComponent("mnt")
        guard try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                                  "-mountpoint", mount.path]) == 0
        else { throw UpdateError.mountFailed }

        let staged = work.appendingPathComponent(appName)
        do {
            guard let found = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
                  try await run("/usr/bin/ditto", [found.path, staged.path]) == 0
            else { throw UpdateError.appNotFound }
        } catch {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        _ = try await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        guard Bundle(url: staged)?.bundleIdentifier == expectedBundleID else { throw UpdateError.wrongBundle }
        return (work, staged)
    }

    /// A detached shell waits for `waitForPID` to exit, swaps the bundle (rolling back on failure), and relaunches.
    static func launchSwap(staged: URL, dest: URL, work: URL, waitForPID pid: Int32, relaunch: Bool) throws {
        let script = work.appendingPathComponent("swap.sh")
        try """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        DEST="\(dest.path)"
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && /usr/bin/ditto "\(staged.path)" "$DEST"; then
            rm -rf "$DEST.old"
        else
            rm -rf "$DEST"; mv "$DEST.old" "$DEST"
        fi
        \(relaunch ? "/usr/bin/open \"$DEST\"" : "")
        rm -rf "\(work.path)"
        """.write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
    }

    static func run(_ tool: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
