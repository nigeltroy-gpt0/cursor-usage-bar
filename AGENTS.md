# Agent notes for cursor-usage-bar

A macOS menu bar app (SwiftPM, SwiftUI, macOS 13+) that shows Cursor usage. See README.md for features and how it works.

## Local builds: always use the test variant

The main-line **Cursor Usage Bar** app may be installed and running on this machine. Local development must never quit, replace, or uninstall it.

- Build and run local changes with `./build.sh --run`. Use `./build.sh --install` only if the test app needs to live in /Applications.
- Both produce **(Test) Cursor Usage Bar**. It differs from the main-line app only in these ways:

  | | Main-line (release) | Test (local default) |
  |---|---|---|
  | App name | `Cursor Usage Bar.app` | `(Test) Cursor Usage Bar.app` |
  | Bundle ID | `com.local.cursorusagebar` | `com.local.cursorusagebar.test` |
  | Process / executable | `CursorUsageBar` | `CursorUsageBarTest` |
  | Auto-update | on | off (`CUBTestBuild` = true in Info.plist) |
  | Data source | live Cursor data | stub data (right-click → live) |

  Settings (UserDefaults), the login item and Keychain access are all tracked per bundle ID, so the two variants don't interfere.
- **Do not** run `./build.sh --release` locally. It writes `build/Cursor Usage Bar.app`, which may be the running main-line copy. It also exists for CI, which runs `./build.sh --release --dmg`.
- **Do not** `pkill CursorUsageBar`, or delete or overwrite `Cursor Usage Bar.app` in `/Applications` or `build/`. To restart the test app, use `./build.sh --run`, which only kills `CursorUsageBarTest`.
- **The test UI must mirror production exactly.** The menu bar text, dropdown, Settings, and history window look the same in both variants: no "(Test)" or "(T)" labels, no test-only banners or notes, and the same Updates section. Use `Updater.productName` ("Cursor Usage Bar") for any app name shown in the UI. Only the bundle name, ID, and executable differ, so both apps can be installed side by side.
- **Test builds default to stub data.** `DataSource` serves deterministic fake usage (`StubData`), so test builds never read Cursor's token or trigger a Keychain prompt, and UI-only changes need no re-authentication. To use real data, right-click the menu bar item and choose **Connect to and use live Cursor data**. That right-click menu is the only test-only UI, and the choice resets to stub on every launch. Release builds always use live data.

## UI conventions

- All sizes come from `Theme.swift`. Don't use literal font sizes or spacing in views, and don't use semantic fonts like `.caption` or `.headline`.
  - Font sizes:
    - 12pt (`.appBody`) for all text and every control (buttons, pickers, checkboxes).
    - 16pt (`.appHeading`) for key stats in the history window.
    - **Exception:** the header and amount section (title, version, ↻ and ⚙ icons, the main $ amount, "of $X", and the percentage) keeps production v1.4.0's system styles, because the user prefers them. That means `.appTitle` (13pt bold), `.appVersion` (10pt), `.appHero` (17pt rounded semibold) and `.appHeroDetail` (13pt), with 5pt and 6pt spacing there. The panel likewise keeps production's 300pt width and 14pt padding. Don't "normalize" these to the 4-pt scale.
  - Spacing: 4, 8, 12 or 16pt (`Theme.Space`).
  - Show hierarchy with weight and `.secondary` colour, not extra sizes.
- Every control uses `.controlSize(.regular)`, set once at the root.
- Money uses `UsageStore.money` ("$1,500.00", always with cents) or, in the menu bar only, `UsageStore.wholeMoney` ("$1,500", rounded up).
- Detail rows are label/value `Grid` rows of equal height (`Theme.rowHeight`). Secondary info goes right-aligned in the same row. Keep buttons out of detail rows.
- Actions go at the bottom of their section: on the main page, the equal-width "See usage history" and "Dashboard" buttons sit above the footer; in Settings, "Check for updates" is at the bottom of the Updates group.
- Use proper typography: curly quotes (“ ”), en dashes for ranges (Oct 1 – Nov 1).
- **Check UI changes visually:** run `./snapshot.sh`, which renders the dropdown (main and Settings) and the history window with stub data to `build/snapshots/*.png` in light and dark mode. It doesn't launch the app or touch the Keychain. Look at the PNGs before reporting a UI change as done.

## Releasing

- Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the release variant and attaches `cursor-usage-bar.dmg` to a GitHub Release. Installed main-line apps pick it up through the daily auto-update (`Updater.swift`).
- The release asset name (`cursor-usage-bar.dmg`) and bundle ID are what the updater looks for. Don't rename them without updating `Updater.swift`.
- The user reviews changes before they're pushed. Don't push or tag without being asked.

## Testing without side effects

- Test builds launched with `./build.sh --run` use stub data, so they're safe to launch for UI checks: no Keychain prompt and no network. Live data reads Cursor's encrypted token via the "Cursor Safe Storage" Keychain key, and each new build triggers a Keychain prompt. For live-data logic, prefer headless checks: compile the relevant sources with a small `swiftc` driver in a scratch dir.
- Never print or log the Cursor access token or the Keychain key.
