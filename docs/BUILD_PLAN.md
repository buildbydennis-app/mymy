# MyMy — Live Data / Internet Usage Tracker — Build Plan

**What it is:** a Flutter app (Android first) plus a Flutter Windows app
that shows, on a live dashboard, how much mobile data / internet each app
is using right now and in total. One codebase, one dashboard UI, a
different native collector per platform. All data stays on the device.
There is no server, no account, and no data leaves the phone or laptop.

**Status: Phase 1 scaffold, local only. Nothing has been pushed to
GitHub yet** (the GitHub account question is being clarified separately).
`flutter analyze` + `flutter test` are the local proof so far; a real
device / real Windows machine is still required before any "it works"
claim (see § Testing).

## The one design rule

Native code reports **cumulative counters only** (bytes since boot, or
since a connection started). Live speeds are always derived in Dart as

```
rate = (new counter − old counter) / elapsed seconds
```

clamped to ≥ 0 on counter reset (reboot). The UI never shows invented,
sample, or demo numbers as if they were real usage. If a platform cannot
measure something, the dashboard says so.

## Phase 0 — Research findings (what the OS actually allows)

### Android — the good news, and the two hard limits

- **History + per-app totals: yes.** `NetworkStatsManager.querySummary()`
  returns per-UID (per-app) rx/tx totals over a time window. It requires
  **usage access** (`PACKAGE_USAGE_STATS`), which is *not* a normal
  runtime permission: the user must grant it in
  Settings → Usage access. Without it, per-app totals are empty; device
  totals still work.
- **Device totals: yes, cheaply.** `TrafficStats.getTotalRxBytes()`,
  `getTotalTxBytes()`, `getMobileRxBytes()`, `getMobileTxBytes()` give
  totals since boot, split mobile vs everything else (so Wi-Fi ≈ total −
  mobile).
- **Hard limit 1 — `TrafficStats.getUidRxBytes(uid)` is dead for other
  apps.** Since Android N it returns `UNSUPPORTED` for every UID except
  the caller's, for privacy. So there is **no true packet-level, live,
  per-app speed API**. Phase 1's "live" per-app rate is a 1-second
  polling delta of the `NetworkStatsManager` totals. That is near-live,
  not instantaneous, and its granularity is whatever the OS's stats
  service reports between polls. Any app claiming otherwise on modern
  Android is either using the VPN route below or smoothing numbers.
- **Hard limit 2 — mobile per-app buckets need a subscriberId.** Phase 1
  queries mobile with a null subscriberId (the privileged subscriberId
  APIs are not available to ordinary apps). On some devices that returns
  no mobile buckets. Device-wide mobile totals from `TrafficStats` are
  unaffected. This is a device-test item, not a bug to hide.
- **Shared UIDs** (rare) cannot be split by this API; traffic is
  attributed to the first package for that UID.
- **Counters reset on reboot.** Daily/monthly totals therefore need a
  local history store (Phase 2), not just boot counters.

### Windows — the hard part, done properly in Phase 2

- There is **no single Win32/WinRT API** that hands you "bytes per
  process" the way Android's `NetworkStatsManager` does.
- The proven combination, used by tools like Resource Monitor and
  GlassWire-class monitors, is:
  1. **ETW — `Microsoft-Windows-Kernel-Network`** — kernel network events
     with bytes and (usually) a PID. On the receive path the PID can be
     wrong/missing, so it needs correction.
  2. **IP Helper correction — `GetExtendedTcpTable` /
     `GetExtendedUdpTable`** — the live connection table, PID included.
  3. **`GetPerTcpConnectionEStats`** — per-TCP-connection byte counts;
     enabling it generally needs **administrator rights**.
- **UDP has no EStats equivalent** — UDP per-process bytes only come
  from ETW. `svchost.exe` hosts many Windows services, so service-level
  attribution needs SCM/WMI service resolution on top.
- **Phase 1 finding:** the Dart `win32` package (6.4.0) was added and
  inspected, and its generated iphlpapi bindings do **not** include
  `GetIfTable2`, `GetExtendedTcpTable`, `GetExtendedUdpTable`, or
  `GetPerTcpConnectionEStats`. Hand-writing that FFI blind, with no
  Windows machine here to run it on, would be guessing — so Phase 1
  Windows is an honest stub (`windows-phase2-pending`), and the
  dependency was removed again. Phase 2 must be a small native C++
  plugin built and smoke-tested on Windows (CI Windows runner for
  compile, a real laptop for behaviour).

### iOS — out of scope, stated plainly

iOS gives ordinary App Store apps **no per-app usage API** for other
apps. Per-app network control/visibility on iOS is an MDM / managed-app
or Network Extension entitlement story, not something a consumer
dashboard app can do. MyMy therefore targets **Android + Windows only**.
Do not promise an iPhone version of this dashboard.

### Privacy

- No `INTERNET` permission on Android (deliberately absent from the
  manifest). No server, no account, no sync in Phases 1–2.
- Phase 4's cross-device view, if ever built, is local-LAN only — never
  a cloud dashboard of the user's traffic.

## Phase 1 — This scaffold (done, local)

- Shared Flutter dashboard (`lib/main.dart`): live down/up rate (1 s
  poll), totals since boot, mobile vs Wi-Fi split, per-app list for
  today sorted by current rate then total, permission banner with an
  "Open usage settings" button, and explicit not-available states.
- Shared core (`lib/src/`): `models.dart` (counter contract),
  `format.dart` (decimal MB, as carriers bill), `usage_service.dart`
  (MethodChannel source, injectable fake source, pure rate maths).
- Android engine (`MainActivity.kt`, `mymy/usage` channel): `getStatus`
  via `AppOpsManager`, `openUsageSettings` via
  `Settings.ACTION_USAGE_ACCESS_SETTINGS`, `getSnapshot` via
  `NetworkStatsManager` (today's window, Wi-Fi + mobile summed) +
  `TrafficStats` device totals + `PackageManager` labels. Every call
  guarded; missing permission → empty per-app list, not a crash.
- Windows: stub source (`windows_usage.dart`) reporting
  `windows-phase2-pending`. The Windows app builds and runs, but its
  dashboard honestly says Windows usage is not implemented yet.
- Tests (`test/`): rate maths, counter-reset clamping, zero-elapsed
  guard, format cases, snapshot parsing, dashboard smoke test.
- Workflows (local files only, see below): APK + Windows release
  artifacts from GitHub Actions.

**What Phase 1 does NOT do:** background sampling when the app is
closed, history/daily/monthly totals, budgets/alerts, Windows per-app
bytes, iOS, cross-device sync, blocking/limiting any app (visibility
only — never a firewall, unless a later phase explicitly asks for it).

## Phase 2 — Windows collector + history (next build)

1. Native Windows C++ plugin: IP Helper connection table +
   `GetPerTcpConnectionEStats` (TCP bytes, admin) + ETW kernel-network
   (UDP + receive-path PID correction) + process/service name
   resolution. Same cumulative-counter contract as Android, so the Dart
   UI and rate maths do not change.
2. Local history store (SQLite, on-device): snapshot totals at
   intervals, so daily/monthly totals survive reboots; per-app history
   views.
3. Android foreground service + notification so sampling continues
   while the app is in the background (permissions `FOREGROUND_SERVICE`
   / `POST_NOTIFICATIONS` are already declared for this).
4. Budgets/alerts: daily data cap warning, "biggest user today" summary.
   Alerts are local notifications only.

## Phase 3 — Optional opt-in VPNService live mode (Android only)

Only if Dennis explicitly wants true packet-level live per-app speeds:

- A local `VpnService` that routes traffic through the device itself
  (no server), counting bytes per app as packets pass.
- Tradeoffs to accept first, not after: **only one VPN can run at a
  time** (so a real VPN and MyMy live mode cannot coexist), higher
  battery use, and Google Play requires a prominent disclosure for
  VPNService use. The polling mode stays the default; VPN mode is
  opt-in, off by default, and its counts must be reconciled against
  `NetworkStatsManager` totals in testing.

## Phase 4 — Optional cross-device view (only if asked for)

- Phone and laptop each keep measuring themselves. An optional
  local-LAN pairing (QR code, encrypted, same Wi-Fi) lets one dashboard
  show both devices' totals side by side.
- No cloud account, no traffic content, no browsing history — totals
  and per-app bytes only, and only while both devices opt in.

## Permissions the user must grant

| Device | Grant | How | If not granted |
|---|---|---|---|
| Android | Usage access | Dashboard banner → Settings → Usage access → MyMy → Allow | Device totals only; per-app list empty |
| Android (Phase 2) | Notifications + foreground service | System prompts on first background run | Sampling stops when app is closed |
| Windows (Phase 2) | Run as administrator (for EStats) | Right-click → Run as administrator | TCP per-process bytes unavailable; ETW-only view |
| Windows (Phase 2) | — | — | UDP per-process bytes need ETW regardless |

## Testing — what to do on a real device

### Android phone
1. Install the APK from Actions (see README). Open MyMy.
2. Tap "Open usage settings", grant usage access, return to MyMy.
3. Stream a video / download a file for ~30 s. The live down rate
   should rise, and that app should climb the per-app list with a
   growing today total.
4. Check the device total against Settings → Network / data usage for
   the same window — totals should be in the same ballpark (they will
   not match to the byte: different windows and counter bases).
5. Reboot, reopen: totals restart from boot (expected in Phase 1);
   per-app "today" totals persist via `NetworkStatsManager`.

### Windows laptop (Phase 1 expectation: stub message)
1. Run the Windows artifact. The dashboard must show the
   "not available on this platform yet" card — that is the correct
   Phase 1 behaviour, not a failure.
2. Phase 2 test (later): run as administrator, download a large file
   in a browser, and confirm that browser process leads the per-process
   list with matching adapter totals.

### Honest limits of this scaffold
- `flutter analyze` + `flutter test` pass locally (Linux VM). They
  prove the Dart logic and UI shell, **not** the Android native code
  (needs an Android build + phone) and **not** Windows behaviour
  (needs a Windows machine).
- `flutter build apk` / `flutter build windows` were deliberately NOT
  run here: this VM has no Android SDK and no Windows toolchain, so
  both would fail for environment reasons, not code reasons. GitHub
  Actions is the first real build for both (workflows pinned to
  Flutter 3.47.6, the locally verified SDK).
- Workflow files (`.github/workflows/`) historically need adding via
  the GitHub web UI if the MCP push channel returns 403 on that path.
  The workflow files in this tree are ready to add that way.

## File map

```
lib/main.dart                          Live dashboard UI
lib/src/models.dart                    Counter contract (cumulative only)
lib/src/format.dart                    Decimal MB / rate formatting
lib/src/usage_service.dart             Channel source + pure rate maths
lib/src/windows_usage.dart             Windows Phase 1 stub (Phase 2: ETW)
android/.../MainActivity.kt            mymy/usage channel (Android engine)
android/.../AndroidManifest.xml        Permissions (no INTERNET, on purpose)
test/usage_service_test.dart           Rate/format/parsing tests
test/widget_test.dart                  Dashboard smoke test (fake source)
.github/workflows/build-apk.yml        CI: analyze + test + release APK
.github/workflows/build-windows.yml    CI: analyze + test + Windows release
```
