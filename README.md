# MyMy — Live Data / Internet Usage Tracker

A Flutter app (Android + Windows) that shows live mobile data and
internet usage per app in a live dashboard. See
[`docs/BUILD_PLAN.md`](docs/BUILD_PLAN.md) for the full phased plan,
including the honest platform limits.

**Phase 4 status (local only, NOT pushed to GitHub):**

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
- ✅ Android VPN live mode (opt-in, off by default): TUN + TCP/UDP
  proxy service, per-app attribution via
  `ConnectivityManager.getConnectionOwnerUid`, unmapped bytes shown
  as "Unattributed" (never guessed), prominent disclosure before
  start, reconciliation against `NetworkStatsManager` totals with a
  mismatch warning instead of a silently preferred source, and
  source-labelled history (polling / VPN / mixed). **NOT proven:**
  the entire VPN forwarding path needs a real phone — browsing,
  video, UDP/DNS apps, VPN-conflict behaviour, battery, and the
  `INTERNET`-permission question (the app still has no `INTERNET`
  permission; if relay sockets are denied on a real phone, adding it
  is the first fix to try). Exact device tests are in the plan doc.
- ❌ iOS: no per-app usage API exists for ordinary App Store apps, so
  iOS is out of scope. See the plan doc.
- ✅ Devices tab (Phase 4, opt-in local-LAN cross-device view): host
  on one device (LAN-only server, QR code + 6-digit PIN that expires
  in 2 minutes and is single-use), join from the other by pasting
  the pairing code or entering host + port + PIN manually (no camera
  scan — manual entry works on Windows too). Paired devices show
  live rate (5-second polls while the tab is open), totals, today
  recorded total, and top apps; a silent device shows Stale/Offline
  with last-seen, never a frozen rate as live. Remote totals are
  never written into this device's history. Either side can revoke
  at any time. **NOT proven:** real two-device pairing on a phone +
  laptop, Windows Firewall prompts, and token/PIN behaviour on a
  real network — exact two-device tests are in the plan doc.

**Privacy:** all data stays on the device, or — only while two of
your own devices are explicitly paired — on your local LAN between
them. No server, no account, no cloud. Shared over the LAN: totals +
per-app bytes only. Never shared: traffic content, URLs, hosts, DNS,
browsing history, or connection details.

**Phase 4 permission change, read this:** Phases 1–3 deliberately had
no `INTERNET` permission. Phase 4 adds it, **LAN-only**: Android
requires `INTERNET` for an app to open sockets at all, including a
LAN-only host/client pair between your own devices. It is used only
for the Devices tab's LAN host (bound to a LAN address) and guest
client on the same trusted Wi-Fi, token-gated. No usage data is ever
sent to the internet, and there is no remote server. If Phase 4 is
ever removed, this permission must be removed with it.

**Phase 4 security, stated plainly:** LAN + bearer token ONLY — there
is **no TLS / end-to-end encryption** in Phase 4. Treat the bearer
token like a LAN password, and **do not pair on untrusted or public
Wi-Fi**.

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
- **Android VPN live mode:** Live tab → VPN live → accept the
  disclosure, then accept Android's VPN consent dialog. Turning it
  off (Live tab or its notification) returns to polling. While it
  is active, any other VPN is disconnected — Android allows only
  one VPN at a time.
- **Devices (Phase 4):** Devices tab → Host this device on one device,
  Join a device on the other (paste the pairing code, or enter host +
  port + PIN). Both devices must be on the same trusted Wi-Fi.
  Stop hosting (or Forget on the guest) revokes the pairing at any
  time. On Windows, allow MyMy on **private** networks only when
  Firewall prompts — never on public networks.
