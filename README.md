# MyMy — Live Data / Internet Usage Tracker

A Flutter app (Android + Windows) that shows live mobile data and
internet usage per app in a live dashboard. See
[`docs/BUILD_PLAN.md`](docs/BUILD_PLAN.md) for the full phased plan,
including the honest platform limits.

**Phase 1 status (local only, not pushed to GitHub yet):**

- ✅ Android: live dashboard, device totals, mobile vs Wi-Fi split,
  per-app totals for today, live rates from 1-second polling deltas of
  real system counters.
- ⏳ Windows: the app builds, but the dashboard honestly says Windows
  usage is not implemented yet. Per-process bytes are Phase 2 (native
  ETW / IP Helper collector, built and tested on Windows).
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

## Download (once the repo is connected)

GitHub Actions, on every push to `main` (workflows are pinned to
Flutter 3.47.6):

- **Android APK:** Actions → `Build APK` run → artifact
  `mymy-app-release-apk` → install `app-release.apk` (debug-key signed,
  so it installs without a release keystore).
- **Windows:** Actions → `Build Windows` run → artifact
  `mymy-windows-release` → the release folder with `mymy.exe`.
  Phase 1 Windows shows the not-implemented card (expected).

Note: if pushing via the API returns 403 for `.github/workflows/`,
add those two workflow files via the GitHub web UI instead
(Add file → Create new file) — that path has worked for other repos.

## Permissions to grant

- **Android:** open the app, tap "Open usage settings", grant usage
  access. Without it you get device totals only, no per-app list.
- **Windows (Phase 2):** run as administrator for per-process TCP byte
  counts.
