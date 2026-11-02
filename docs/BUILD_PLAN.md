# MyMy — Live Data / Internet Usage Tracker — Build Plan

**What it is:** a Flutter app (Android first) plus a Flutter Windows app
that shows, on a live dashboard, how much mobile data / internet each app
is using right now and in total. One codebase, one dashboard UI, a
different native collector per platform. All data stays on the device.
There is no server, no account, and no data leaves the phone or laptop.

**Status: Phase 2 built locally, NOT pushed to GitHub** (this tree is
local-only by instruction; workflows are manual-only and pending a
separate web upload). `flutter analyze` + `flutter test` are the local
proof so far; a real device / real Windows machine is still required
before any "it works" claim (see § Testing).

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

## Phase 2 — Windows collector + history (BUILT, local only)

1. **Windows native collector — runner-direct, not a plugin package**
   (`windows/runner/mymy_usage.h/.cpp`, registered in
   `flutter_window.cpp`, linked against `iphlpapi.lib`, `ws2_32.lib`,
   `advapi32.lib`). A plugin package was considered and rejected:
   the collector is one MethodChannel on the app's own engine, and a
   plugin would add generated-registrant plumbing for no benefit.
   Same `mymy/usage` channel and same cumulative-counter contract as
   Android, so the Dart UI and rate maths did not change. The old
   `windows-phase2-pending` stub (`lib/src/windows_usage.dart`) is
   deleted; Windows now uses the generic `MethodChannelUsageDataSource`.
   Measured: adapter totals via `GetIfTable2Ex` (64-bit, up,
   non-loopback interfaces), per-process **TCP** bytes via
   `GetPerTcpConnectionEStats` (v4 + v6, deltas tracked per 5-tuple
   across polls, so closed connections keep their bytes; a
   connection's bytes before the collector starts are NOT counted —
   only future deltas are, so no burst is invented), connection list
   via `GetExtendedTcpTable`/`GetExtendedUdpTable`, process names via
   `QueryFullProcessImageName`, svchost service names best-effort via
   SCM (cached 30 s). PID reuse is handled: a changed process start
   time resets that PID's totals. Without administrator rights,
   EStats enable fails with access denied, the collector stops
   trying for the session, per-process lists stay empty, and the UI
   shows the run-as-administrator banner — never fabricated numbers.
   **ETW is NOT in Phase 2, deliberately.** A
   `Microsoft-Windows-Kernel-Network` consumer cannot be made
   compile-safe blind (provider GUID/event parsing unverifiable
   without a Windows machine), and a wrong ETW consumer would report
   wrong PIDs/bytes as if real. Consequence, stated plainly:
   **UDP per-process bytes are NOT measured in Phase 2.** UDP
   connections are listed (process + local endpoint) with no bytes,
   and device totals (adapter counters) still include UDP. ETW is
   the remaining Windows gap, for a build that is tested on Windows.
2. **Local history store (SQLite, on-device)** (`lib/src/history.dart`):
   schema v1 `daily_totals(date, total_rx, total_tx, mobile_rx,
   mobile_tx)` + `app_daily(date, app_id, app_name, rx, tx)` + an
   internal `meta` table holding the last recorded snapshot (so
   deltas survive restarts without double counting). Dependencies:
   `sqflite` (Android) + `sqflite_common_ffi` (Windows/Linux) +
   `path` + `path_provider`; an `InMemoryHistoryStore` with identical
   logic is used in tests and as the fallback if SQLite cannot open
   (the UI then says history is in-memory only this session).
   Meaning of a history number: **recorded while MyMy was sampling**
   (live tab open, or foreground service running). Samples are
   recorded at most once per minute plus a forced sample on app
   close; a skipped minute loses granularity, not traffic, because
   the next recorded delta covers the whole interval. A counter drop
   contributes zero; the first sample of a new local day is a
   baseline, never a delta. Dashboard: second tab (History) with
   today / yesterday / last 7 days (recorded), per-app today, and
   biggest user today.
3. **Android foreground service** (`BackgroundSamplingService.kt`,
   `UsageSnapshotProvider.kt` shared with `MainActivity.kt` so live
   and background samples can never disagree). One ongoing
   notification with a Stop action, one raw snapshot JSON line per
   minute into `filesDir/mymy_background_samples.jsonl`, no
   aggregation and no network in the service. On reopen, Dart
   (`lib/src/background.dart`) merges those lines into history in
   timestamp order, skipping anything at or before the last recorded
   timestamp, then clears the file — so UI and service samples for
   one interval can never double-count. DB sharing gap, stated
   plainly: the service does NOT write the SQLite history DB
   directly (two writers to one SQLite file from Dart + Kotlin was
   judged unsafe blind); it writes the JSONL file and Dart merges it.
   Until that merge, service traffic is pending, not lost, and not
   in history. Manifest: service declared with
   `foregroundServiceType="dataSync"` plus
   `FOREGROUND_SERVICE_DATA_SYNC`; if notifications are not granted,
   start fails visibly (the UI switch stays off) instead of running
   invisibly.
4. **Budgets/alerts, local only** (`lib/src/budget.dart`,
   SharedPreferences cap in MB, default unset): when today's
   recorded total reaches the cap, the Live tab shows a banner and
   the History tab keeps the setting. **No local-notification plugin
   was added**: the budget alert shows when the app is open or on
   reopen after a merge, which keeps the Android build surface small
   and the logic purely testable. The foreground service's ongoing
   notification is the only notification MyMy posts in Phase 2.
   MyMy never blocks or limits any app — visibility only.

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

### Windows laptop (Phase 2)
1. Run the Windows artifact **as administrator**. The dashboard must
   NOT show the Phase 1 stub card any more.
2. Download a large file in a browser for ~60 s. That browser process
   must lead the per-process list, its bytes must grow, and the live
   down rate must roughly match the adapter totals. Note: bytes
   transferred before MyMy started do not count (first-sight rule).
3. Run once WITHOUT administrator rights: per-process list must be
   empty with the run-as-administrator banner, while adapter totals
   and the connection list still show.
4. Check UDP honestly: start a UDP-heavy app (e.g. a game/voice
   call) and confirm its process appears in connections but with no
   UDP bytes attributed — that is the documented Phase 2 gap, not a
   bug to hide. ETW is still pending for UDP per-process bytes.

### Android phone (Phase 2 additions)
1. Turn on "Sample in background" on the History tab, close the app,
   use another app for a few minutes, reopen MyMy, and tap Merge now
   if history does not yet include it. History today must grow by
   roughly the background traffic, never by double the traffic.
2. Stop the service from its notification action and from the History
   tab switch; the notification must disappear in both cases.
3. Set a small daily cap (e.g. 1 MB) on the History tab and use data
   until the Live tab banner appears. Clear the cap afterwards.
4. Reboot, reopen: history from before the reboot must still be
   there (SQLite), while live totals restart from boot (expected).

### Honest limits of Phase 2 (read before claiming anything)
- `flutter analyze` clean + `flutter test` 20/20 pass locally (Linux
  VM). They prove Dart logic (history deltas, throttle, reboot
  clamping, merge dedupe, budget thresholds, Windows JSON parsing)
  and the UI shell — **not** the C++ collector (needs MSVC + Flutter
  Windows headers, absent here) and **not** the Kotlin service (needs
  an Android SDK + phone, absent here). GitHub Actions (manual-only
  workflows) is the first real compile for both, and a real laptop /
  phone is the first real behaviour proof.
- The C++ EStats signatures, `TCP_ESTATS_DATA_RD_v0` field names,
  and `FlutterEngine::messenger()` registration were written from
  the documented Win32/Flutter APIs without a Windows compiler to
  check them against. If the Windows CI build fails, the failure
  will be localised to `windows/runner/mymy_usage.cpp` or its
  registration — fix from the CI log, do not guess further.
- The Kotlin service was likewise written without an Android build;
  its first compile is the same Actions run.

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
lib/main.dart                          Live + History tabs, budget banner
lib/src/models.dart                    Counter contract (cumulative only)
lib/src/format.dart                    Decimal MB / rate formatting
lib/src/usage_service.dart             Channel source + rate maths +
                                       background-sampling channel methods
lib/src/history.dart                   SQLite history (v1) + in-memory twin
lib/src/budget.dart                    Daily cap checker + local store
lib/src/background.dart                Background-sample merge controller
windows/runner/mymy_usage.h/.cpp       Windows collector (IP Helper + EStats)
android/.../MainActivity.kt            mymy/usage channel (Android engine)
android/.../UsageSnapshotProvider.kt   Shared snapshot logic (UI + service)
android/.../BackgroundSamplingService.kt  Foreground service, 1 sample/min
android/.../AndroidManifest.xml        Permissions (no INTERNET, on purpose)
test/usage_service_test.dart           Rate/format/parsing tests
test/history_test.dart                 History, merge, budget, Windows JSON
test/widget_test.dart                  Dashboard smoke test (fake source)
.github/workflows/build-apk.yml        CI: analyze + test + release APK
.github/workflows/build-windows.yml    CI: analyze + test + Windows release
```
