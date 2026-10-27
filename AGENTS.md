# Agent notes for cursor-usage-bar

A macOS menu bar app (SwiftPM, SwiftUI, macOS 13+) that shows Cursor usage. See README.md for features and how it works.

## Local builds: always use the test variant

The main-line **Cursor Usage Bar** app may be installed and running on this machine. Local development must never quit, replace, or uninstall it.

- Build and run local changes with `./build.sh --run`. Use `./build.sh --install` only if the test app needs to live in /Applications.
- Both produce **(Test) Cursor Usage Bar**. It differs from the main-line app in four ways:

  | | Main-line (release) | Test (local default) |
  |---|---|---|
  | App name | `Cursor Usage Bar.app` | `(Test) Cursor Usage Bar.app` |
  | Bundle ID | `com.local.cursorusagebar` | `com.local.cursorusagebar.test` |
  | Process / executable | `CursorUsageBar` | `CursorUsageBarTest` |
  | Auto-update | on | off (`CUBTestBuild` = true in Info.plist) |

  Settings (UserDefaults), the login item and Keychain access are all tracked per bundle ID, so the two variants don't interfere.
- **Do not** run `./build.sh --release` locally. It writes `build/Cursor Usage Bar.app`, which may be the running main-line copy. It also exists for CI, which runs `./build.sh --release --dmg`.
- **Do not** `pkill CursorUsageBar`, or delete or overwrite `Cursor Usage Bar.app` in `/Applications` or `build/`. To restart the test app, use `./build.sh --run`, which only kills `CursorUsageBarTest`.
- Don't hardcode the app name in UI. Use `Updater.appName`, which reads `CFBundleDisplayName`.

## Releasing

- Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the release variant and attaches `cursor-usage-bar.dmg` to a GitHub Release. Installed main-line apps pick it up through the daily auto-update (`Updater.swift`).
- The release asset name (`cursor-usage-bar.dmg`) and bundle ID are what the updater looks for. Don't rename them without updating `Updater.swift`.
- The user reviews changes before they're pushed. Don't push or tag without being asked.

## Testing without side effects

- The app reads Cursor's encrypted token using the "Cursor Safe Storage" Keychain key, so every new build triggers a Keychain prompt when launched. Prefer headless checks: compile the relevant sources with a small `swiftc` driver in a scratch dir. Launch the app only when the user wants to see it.
- Never print or log the Cursor access token or the Keychain key.
