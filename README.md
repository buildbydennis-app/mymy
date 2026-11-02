# MyMy — Live Data / Internet Usage Tracker

A Flutter app (Android + Windows) that shows live mobile data and
internet usage per app in a live dashboard. See
[`docs/BUILD_PLAN.md`](docs/BUILD_PLAN.md) for the full phased plan,
including the honest platform limits.

**Phase 2 status (local only, NOT pushed to GitHub):**

- ✅ Android: live dashboard, device totals, mobile vs Wi-Fi split,
  per-app totals for today, live rates from 1-second polling deltas of
  real system counters.
- ✅ Windows: native collector in the runner (adapter totals +
  per-process **TCP** bytes via EStats, run as administrator).
  UDP per-process bytes are NOT measured in Phase 2 — ETW is still
  pending, and the UI says so. Windows behaviour is NOT proven here;
  it needs a real laptop + the Actions Windows build.
- ✅ History tab: today / yesterday / last 7 days (recorded while
  sampling), per-app today, biggest user today, daily cap banner.
- ✅ Android background sampling: foreground service, 1 sample/min,
  merged into history on reopen (never double-counted).
- ❌ iOS: no per-app usage API exists for ordinary App Store apps, so
  iOS is out of scope. See the plan doc.

**Privacy:** all data stays on the device. No server, no account. The
Android app deliberately has **no `INTERNET` permission**.

## Run / test locally

```sh
~/flutter/bin/flutter pub get
~/flutter/bin/flutter analyze
~/flutter/bin/flutter test
```

`flutter build apk` / `flutter build windows` need an Android SDK /
Windows toolchain, which the Linux dev VM does not have — GitHub
Actions (below) is the first real build for both.

## Download (once the pending web upload lands)

GitHub Actions, **manual-only** — nothing runs on push (workflows are
pinned to Flutter 3.47.6). Run a workflow from Actions → Run workflow:

- **Android APK:** Actions → `Build APK` run → artifact
  `mymy-app-release-apk` → install `app-release.apk` (debug-key signed,
  so it installs without a release keystore).
- **Windows:** Actions → `Build Windows` run → artifact
  `mymy-windows-release` → the release folder with `mymy.exe`.
  Run it as administrator for per-process TCP bytes.

Note: if pushing via the API returns 403 for `.github/workflows/`,
add those two workflow files via the GitHub web UI instead
(Add file → Create new file) — that path has worked for other repos.

## Permissions to grant

- **Android:** open the app, tap "Open usage settings", grant usage
  access. Without it you get device totals only, no per-app list.
  For background sampling, also grant notifications (Android 13+),
  or the service switch will not stay on.
- **Windows:** run as administrator for per-process TCP byte
  counts. Without it you get adapter totals + connections only.
