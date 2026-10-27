# Cursor Usage Bar

A macOS menu bar app that shows your Cursor spend for the current billing cycle, e.g. `$96/$1500 · 19d`.

Click it for the details: exact spend, % of limit, today's spend, billing period, days left, and plan type. The gear icon opens Settings.

**See usage history** opens a 30-day bar chart of daily spend. It shows the total, the 30-day and billing-period daily averages, and the peak day. Hover a bar to see that day's amount.

## Install

1. Download `cursor-usage-bar.dmg` from the [latest release](../../releases/latest).
2. Open it and drag **Cursor Usage Bar** into **Applications**.
3. Launch it from Applications. It only appears in the menu bar (no Dock icon).

The app is ad-hoc signed, not notarized, so macOS blocks it the first time you open a downloaded copy. To allow it, open **System Settings → Privacy & Security** and click **Open Anyway**. Or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Cursor Usage Bar.app"
```

You must have Cursor installed and be signed in to it. The app reads Cursor's login from your Mac. On Cursor 3.27+, macOS asks once for access to the "Cursor Safe Storage" Keychain item: click **Always Allow**.

### Updates

The app checks this repo's [releases](../../releases) once a day. If there's a newer version, it downloads the DMG, replaces the installed app, and relaunches. To check right away, click **Check for updates** in Settings (gear icon). The installed version appears next to the title.

Updates need write access to the app's location (e.g. `/Applications`). After an update, macOS asks again for "Cursor Safe Storage" Keychain access (see below).

## Build from source

Requires macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/nigeltroy-gpt0/cursor-usage-bar.git
cd cursor-usage-bar
./build.sh                       # test build: "build/(Test) Cursor Usage Bar.app"
./build.sh --run                 # test build, launched from build/
./build.sh --install             # test build, copied to /Applications and launched
./build.sh --release --dmg       # real app + build/cursor-usage-bar.dmg (what CI ships)
```

Local builds are test builds by default: **(Test) Cursor Usage Bar**, with bundle ID `com.local.cursorusagebar.test` and a separate process and settings. They never quit or replace an installed main-line copy, and they don't auto-update. Pass `--release` to build the real app.

The version defaults to the latest git tag. Set `VERSION=1.2.3` to override it.

## Releases

GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml)) builds the DMG on every push and PR and uploads it as a workflow artifact. Pushing a `v*` tag also publishes a GitHub Release with the DMG attached:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

## Settings

Open Settings with the gear icon in the dropdown, and use **‹ Back** to return.

- **Refresh every:** 5 minutes, 15 minutes, 1 hour, or 1 day. It also refreshes on wake from sleep and when you click ↻.
- **Show usage percentage in menu bar:** shows e.g. `7%` instead of `$96/$1500`.
- **Show days left in menu bar:** has a sub-option to add a "left" suffix (`19d left`).
- **Launch at login:** uses `SMAppService`. If macOS asks, approve it under System Settings → General → Login Items.

The menu bar rounds numbers up to keep the text short. The dropdown shows exact values.

## How it works

- **Token:** read-only from Cursor's local state DB
  (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, key `cursorAuth/accessToken`).
  It's re-read on every refresh, so it picks up the new token whenever Cursor rotates it. The token is never stored and is only sent to cursor.com.
  Since Cursor 3.27, the token is encrypted at rest (`cursor-safe-storage:v1:` prefix, Electron `safeStorage`). The app decrypts it with the key in your Keychain under **Cursor Safe Storage**. The first time, macOS asks to allow this: enter your password and click **Always Allow**. Because the app isn't Developer ID–signed, macOS asks again after each update.
- **API:** `GET https://cursor.com/api/usage-summary` with the `WorkosCursorSessionToken` cookie. It returns the billing cycle start and end plus used and limit amounts in cents.
- **Daily spend:** `POST https://cursor.com/api/dashboard/get-filtered-usage-events` returns individual usage events. The app sums `chargedCents` by local calendar day, which matches the `usage-summary` total.

Note: these are undocumented endpoints used by Cursor's dashboard, so they may change without notice.
