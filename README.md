# CursorUsageBar

A macOS menu bar app that shows your Cursor spend for the current billing cycle, e.g. `$96/$1500 · 19d`.

Click it for the details: exact spend, % of limit, billing period, days left, plan type, and settings.

## Install

1. Download `CursorUsageBar.dmg` from the [latest release](../../releases/latest).
2. Open it and drag **CursorUsageBar** into **Applications**.
3. Launch it from Applications. It only appears in the menu bar (no Dock icon).

The app is ad-hoc signed, not notarized, so macOS blocks it the first time you open a downloaded copy. To allow it, open **System Settings → Privacy & Security** and click **Open Anyway**. Or run:

```bash
xattr -dr com.apple.quarantine /Applications/CursorUsageBar.app
```

You must have Cursor installed and be signed in to it. The app reads Cursor's login from your Mac.

## Build from source

Requires macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/nigeltroy-gpt0/CursorUsageBar.git
cd CursorUsageBar
./build.sh             # builds build/CursorUsageBar.app
./build.sh --install   # builds, copies to /Applications, launches
./build.sh --dmg       # builds build/CursorUsageBar.dmg
```

Set `VERSION=1.2.3` to stamp a version into the app's Info.plist.

## Releases

GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml)) builds the DMG on every push and PR and uploads it as a workflow artifact. Pushing a `v*` tag also publishes a GitHub Release with the DMG attached:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

## Settings

- **Refresh every:** 5 minutes, 15 minutes, 1 hour, or 1 day. It also refreshes on wake from sleep and when you click ↻.
- **Show usage percentage in menu bar:** shows e.g. `7%` instead of `$96/$1500`.
- **Show days left in menu bar:** has a sub-option to add a "left" suffix (`19d left`).
- **Launch at login:** uses `SMAppService`. If macOS asks, approve it under System Settings → General → Login Items.

The menu bar rounds numbers up to keep the text short. The dropdown shows exact values.

## How it works

- **Token:** read-only from Cursor's local state DB
  (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, key `cursorAuth/accessToken`).
  It's re-read on every refresh, so it picks up the new token whenever Cursor rotates it. The token is never stored and is only sent to cursor.com.
- **API:** `GET https://cursor.com/api/usage-summary` with the `WorkosCursorSessionToken` cookie. It returns the billing cycle start and end plus used and limit amounts in cents.

Note: `usage-summary` is an undocumented endpoint used by Cursor's dashboard, so it may change without notice.
