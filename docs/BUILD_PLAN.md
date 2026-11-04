# MyMy — Live Data / Internet Usage Tracker — Build Plan

**What it is:** a Flutter app (Android first) plus a Flutter Windows app
that shows, on a live dashboard, how much mobile data / internet each app
is using right now and in total. One codebase, one dashboard UI, a
different native collector per platform. All data stays on the device.
There is no server, no account, and no data leaves the phone or laptop.

**Status: Phase 5 built locally, NOT pushed to GitHub** (this tree is
local-only by instruction; workflows are manual-only and pending a
separate web upload). `flutter analyze` + `flutter test` are the local
proof so far; a real device / real Windows machine is still required
before any "it works" claim (see § Testing). Phase 3's VPN forwarding
path, Phase 4's two-device pairing, and all of Phase 5 are
**unproven on real devices** — see § Phase 3 honest limits, § Phase 4
honest limits, and § Phase 5 honest limits.

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

- Phases 1–3 had no `INTERNET` permission on Android (deliberately
  absent from the manifest). Phase 4 adds it LAN-only — see the
  flagged Phase 4 decision. No server, no account, no cloud sync in
  any phase.
- Phase 4's cross-device view is local-LAN only — never a cloud
  dashboard of the user's traffic.

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

## Phase 3 — Opt-in VPNService live mode (Android only) — BUILT locally

Dennis explicitly approved this phase after the tradeoffs were stated.
Polling stays the default; VPN live mode is **off by default and
opt-in only**. It exists to give true packet-level live per-app speeds
on Android: polling can only show per-app *totals*, never a live
per-app rate, because `NetworkStatsManager` windows are too coarse.

### What was built

- **VPN service** (`android/.../VpnLiveService.kt` + `VpnPacket.kt`):
  a `VpnService` with a TUN interface (private address `10.0.0.2/32`,
  MTU 1500, route `0.0.0.0/0`, session name "MyMy Live"). Because
  Android cannot send raw IP packets without root, it uses the
  standard NetGuard-class design: transport-layer proxying. IPv4
  packets are parsed, TCP gets a protected `Socket` to the destination
  with a synthesised SYN-ACK and sequence/ack tracking both ways, UDP
  gets a protected `DatagramSocket` relay, payloads are relayed
  opaquely (only headers are read, to route and count — no content
  inspection, no logging, nothing sent anywhere). MyMy's own package
  is disallowed from the tunnel so the service never captures itself.
- **Attribution** (the method that was verified, not guessed):
  `ConnectivityManager.getConnectionOwnerUid(protocol, local, remote)`
  — available from API 29, returns the UID for a connection on the
  calling VPN's tunnel, throws `SecurityException` if the caller is
  not the active VPN, and returns `INVALID_UID` when a connection is
  not found. Only `IPPROTO_TCP` and `IPPROTO_UDP` are supported. The
  service guards the call to API 29+, catches `SecurityException`,
  and sends every unmapped byte to an explicit **"Unattributed"**
  bucket in the UI — never to a guessed app.
- **Counting rule:** tx = IP total length of packets received from
  TUN (app → internet), rx = IP total length of packets written back
  to TUN. Headers are included, closest to `NetworkStatsManager`'s
  IP-layer accounting. Counters are cumulative since VPN start; live
  rates are still derived in Dart as `(new − old) / elapsed`.
- **DNS:** the service adds the active network's DNS server (from
  `LinkProperties`) to the tunnel builder — never a hardcoded
  third-party resolver. DNS then flows as ordinary UDP port-53 relay.
  If no DNS server is available, none is added: DNS bypasses the VPN
  (still works, simply not VPN-counted).
- **Consent flow** (`MainActivity.kt`, request code 1001):
  `VpnService.prepare()` returns null when consent is already held
  (Dart gets `'ready'` at once) or a system dialog Intent otherwise.
  The pending channel result is held and answered from
  `onActivityResult` — `'ready'` on approval, `'denied'` on cancel —
  so Dart never has to guess whether the system dialog was accepted.
  If `establish()` returns null (another VPN is active), the service
  surfaces "Could not establish the VPN tunnel. Another VPN may be
  active." and stops — it never runs silently degraded.
- **Dart UI + state** (`lib/src/vpn.dart`, `lib/main.dart`): a
  Polling / VPN live `SegmentedButton` on the Live tab (Polling is
  the default, always, including on reopen). Switching to VPN live
  first shows a non-dismissible disclosure dialog with the exact text
  in `vpnDisclosureText` (device-only routing, no server, bytes per
  app only, no content inspection, never blocks/limits, disconnects
  any other VPN, higher battery, off anytime from the Live tab or
  the notification). Acceptance is persisted in SharedPreferences
  (`vpn_disclosure_accepted`) and records disclosure only — it does
  not start the VPN. Only after acceptance AND system consent does
  the service start. While active the dashboard shows a "VPN live"
  badge; turning it off (Live tab, notification Stop action, or
  system revocation via `onRevoke`) returns to polling and clears
  the VPN rate baseline, so mode switches never create rate spikes
  (`VpnPollingService` keeps its own previous snapshot).
- **Reconciliation** (`lib/src/vpn.dart`, testable Dart): at VPN
  start Dart captures a polling baseline snapshot; at most once
  every 30 polls it compares the VPN total for that window against
  the `NetworkStatsManager` delta for the same window. Tolerance =
  max(1 MB, 25% of the system delta). Result is `match`, `mismatch`
  (warning card with VPN total, system delta, difference, and the
  reasons — IPv6 bypass, pre-VPN connections, unattributed bytes),
  or `unavailable` (no baseline, or a counter reset). Neither source
  is silently preferred. On reopen with the VPN already running,
  reconciliation is `unavailable` (no baseline from the original
  start) — stated, not faked.
- **History, source-aware** (`lib/src/history.dart`, schema v2):
  `DailyTotal`/`AppDaily` carry a `source` (`'polling'`, `'vpn'`, or
  `'mixed'` when both fed that day/row). In-memory and SQLite stores
  keep one baseline per source, so the first sample of a mode is
  that mode's baseline and switching modes never invents a delta.
  Only the active mode's snapshots are recorded — recording both at
  once would double-count. SQLite v1 databases upgrade by adding
  `source TEXT NOT NULL DEFAULT 'polling'`; new databases are
  created at v2. The History tab shows "Recorded by" per day.
- **Manifest** (`AndroidManifest.xml`): `BIND_VPN_SERVICE` permission
  + the `VpnService` entry (intent filter `android.net.VpnService`,
  permission `BIND_VPN_SERVICE`, `exported="false"`,
  `foregroundServiceType="specialUse"` + special-use subtype
  property, so `startForeground` is legal on Android 14+).
  `startForeground` is wrapped in try/catch: if it throws on some OS
  version, the service still runs and the system VPN notification
  shows — this is tentative and must be device-tested, not claimed
  as settled.

### Phase 3 honest limits (read before claiming anything)

- **Nothing about the VPN forwarding path is proven.** The Kotlin
  service, the packet parser, TCP state handling, UDP relay, DNS
  relay, attribution on a real device, and the consent flow were all
  written without an Android SDK or a phone to build or run them
  against. `flutter analyze` + `flutter test` prove only the Dart
  side (mode defaults, disclosure persistence, reconciliation maths,
  VPN snapshot parsing, stop/teardown state, history source
  separation). The first compile of the Kotlin code is the Actions
  build; the first behaviour proof is a real phone — see the Phase 3
  device tests below. **Do not claim VPN live mode works until a
  real phone proves it.**
- **IPv6 bypass:** no IPv6 route is added, so IPv6 traffic still
  works but is not VPN-counted. Reconciliation will show this as a
  gap on IPv6-heavy traffic, which is the honest signal, not a bug
  to paper over.
- **ICMP dropped:** ping does not work while VPN live mode is on
  (no ICMP forwarding). TCP/UDP only.
- **TCP out-of-order segments:** dropped (no reordering buffer);
  TCP retransmission recovers. Retransmitted already-acked data is
  re-acked, never re-written to the remote socket.
- **Pre-VPN connections:** connections established before VPN start
  are not VPN-counted (their packets arrive on sockets the tunnel
  never saw). Restarting an app after enabling VPN live mode is the
  honest workaround, and the device test checks this.
- **UDP attribution is weaker than TCP:** `getConnectionOwnerUid`
  may return `INVALID_UID` for short-lived UDP flows; those bytes
  land in "Unattributed". If UDP attribution is mostly unattributed
  on a real phone, that is a finding to report, not a reason to
  guess.
- **INTERNET permission — the top device-test risk:** the app still
  has **no** `INTERNET` permission, by design. The reasoning: relay
  sockets are created with `VpnService.protect()` so they bypass
  the tunnel instead of looping into it; they carry other apps'
  traffic to its original destination and are not the app's own
  network calls, and no usage data is ever transmitted. Whether
  Android permits those protected relay sockets without `INTERNET`
  is **not proven** — if relay sockets are denied on a real phone
  (browsing fails in VPN mode, or the service errors), adding
  `INTERNET` with a written justification here is the first fix to
  try, and VPN mode must stay visibly failed until then, never
  silently degraded.
- **Battery:** relaying every packet through the app costs more
  battery than polling. The disclosure says so; the device test
  observes it qualitatively (no number is promised).
- **Play disclosure:** the in-app disclosure text exists, but Play
  review of the VPNService declaration has not happened — that is a
  store-submission step, not a local proof.
- **Foreground special-use handling** (`specialUse` type + subtype
  property + try/catch around `startForeground`) is the most
  tentative manifest choice in this phase; if the Actions build or
  a real phone rejects it, the fallback is the plain foreground
  service declaration used by the background sampler, adjusted from
  the actual error.

## Phase 4 — Optional cross-device view (BUILT, local only)

Dennis approved this phase after Phase 3 was pushed. It does NOT
change how either device measures itself: phone and laptop keep
measuring themselves exactly as before. It only adds an optional
view of the other device's totals, on the same trusted LAN.

### What was built

- **Devices tab** (`lib/main.dart`, `lib/src/devices.dart`): a third
  tab next to Live and History. This device's own label (generic by
  default — "Android phone" / "Windows laptop" — user-editable, never
  a personal identifier or hostname), a Host section, a Join section,
  and one card per paired remote device with live rate, device
  totals, today-recorded total from that device, and its top 5 apps.
  With nothing paired, the tab explains pairing and offers Host /
  Join — it never looks broken, and remote totals are never written
  into this device's history (remote snapshots carry
  `source == 'remote'` and are display-only).
- **Host** (`LanHostServer`, `dart:io` `HttpServer`): binds to a LAN
  IPv4 address only (private ranges preferred; no LAN address means
  hosting fails visibly, never a loopback server pretending to be
  reachable). Exactly two endpoints, nothing else: POST `/pair`
  and GET `/snapshot`. Hosting runs only while the app stays open
  on the Devices tab. The host's live snapshot comes from the same
  local collector as the Live tab; its today total comes from its
  own history store (recorded totals only, or omitted when
  unavailable).
- **Pairing, both sides must opt in**: the host shows a QR code
  (`qr_flutter`, display only) and a copyable pairing code
  `MYMY|v1|<host>|<port>|<pin>|<label>`, plus a 6-digit PIN. The PIN
  is generated with `Random.secure`, expires after 2 minutes, is
  single-use, and locks after 5 failed attempts (one 403 status
  covers wrong / expired / used / locked, so there is no PIN
  oracle). The QR code and pairing code contain NO bearer token —
  a photographed code alone never grants access. On PIN acceptance
  the host issues a random 256-bit bearer token (43 base64url
  chars) to that guest over the LAN; the guest stores it in
  app-private preferences. Guest entry is manual by design: paste
  the full pairing code, or enter host + port + PIN. There is NO
  camera scan in Phase 4 — a scanner plugin would add a native
  surface and a CAMERA permission for a flow that manual entry
  covers fully, including on Windows, which has no camera
  assumption. Pasting the code is the QR equivalent on the guest
  side.
- **Guest polling**: remote snapshots are polled every 5 seconds
  while the Devices tab is open (not in the background). Rates use
  the shared `UsageService.calculate` maths over successive remote
  snapshots (both timestamps come from the host, so guest clock
  skew cannot invent a rate). A device that has not answered
  within 15 seconds is Stale: rates forced to 0 with its last-seen
  time, never a frozen rate presented as live. A device that has
  never answered is Offline. A 401 from the host means the pairing
  was revoked — the UI says so and the guest must re-pair.
- **Revocation, either side, any time**: host "Stop hosting &
  revoke" stops the server AND regenerates the bearer token, so
  every previously issued guest token stops working at once.
  Guest "Forget" removes the device and stops polling it. A
  restarted host requires fresh pairing; old guests do not
  silently reconnect.
- **Payload allowlist** (`RemoteDeviceSnapshot.toShareJson`):
  device label, timestamps, totals, mobile split, today-recorded
  totals, and per-app id/name/rx/tx only. Connections are dropped
  before sending even when the local snapshot has them, and any
  `connections` key in an incoming payload is ignored on parse.
  What is NEVER shared, by construction: traffic content, URLs,
  hostnames, DNS names, browsing history, or connection remotes.

### INTERNET permission — the flagged Phase 4 decision

Phases 1–3 deliberately had **no** `INTERNET` permission. Phase 4
ADDS it, LAN-only, with a written justification in
`AndroidManifest.xml` (and here, and in the README):

> Android requires `INTERNET` for an app to open sockets at all,
> including a LAN-only `HttpServer`/`HttpClient` pair between the
> user's own devices. In MyMy it is used ONLY for the Devices
> tab's LAN host (bound to a LAN address) and guest client, talking
> only to a paired device on the same trusted Wi-Fi, token-gated,
> totals + per-app bytes only. It is NOT used to contact any remote
> server, and no usage data is ever sent to the internet. If Phase 4
> is ever removed, this permission must be removed with it.

Two things this does NOT do: it does not prove or change the
Phase 3 question of whether protected VPN relay sockets need
`INTERNET` on a real phone (that device test still stands on its
own), and it does not make Phase 4 encrypted — see the next
section.

### Phase 4 honest limits (read before claiming anything)

- **No TLS, stated plainly.** Phase 4 security is LAN + bearer
  token ONLY. There is no TLS layer, no certificate pinning, and no
  end-to-end encryption claim anywhere in code or docs. A bearer
  token sent over plain HTTP on a LAN can be observed by anyone
  else on that LAN. **Do not pair on untrusted or public Wi-Fi.**
  A self-signed TLS layer with fingerprint checking was
  considered and NOT shipped blind: its certificate handling cannot
  be verified without two real devices, and a wrong TLS layer
  would be worse than an honest LAN + token statement.
- **Token storage is not encrypted at rest.** The guest token
  lives in app-private SharedPreferences. That is acceptable only
  because the token is LAN-scoped and revocable (host
  regenerates it) — it is never a cloud credential, and a leaked
  token alone grants only totals + per-app bytes from that host,
  while it is hosting, on that LAN.
- **Nothing about real two-device pairing is proven.** The host
  server, PIN exchange, token fetch, and sanitised payload are
  proven at Dart level over loopback in `test/devices_test.dart`
  (pair once, 401 without a token, 403 on a reused PIN, payload
  allowlist). They have NEVER run between a real phone and a real
  laptop: LAN discovery on real Wi-Fi, Windows Firewall prompts
  for the local server, QR display on a real phone screen, manual
  entry on Windows, token/PIN behaviour on a real network, and
  guest clock / host clock behaviour are all unproven. **Do not
  claim cross-device view works until two real devices prove it.**
- **Windows Firewall is an expected first-run hurdle.** The first
  time the Windows host starts, Windows Firewall will almost
  certainly prompt to allow MyMy on private networks. Allowing it
  on private networks only (not public) is the correct answer;
  declining it means guests cannot reach the host, and the guest
  will show Offline — that is the honest signal, not a bug.
- **Remote "today" is the remote device's recorded total**, from
  its own history store while it was sampling. It is not a full OS
  day total, and it is not this device's history. If the remote
  device has no history to report, the card shows "—" for today
  instead of inventing a number.
- **Hosting stops when the app closes.** There is no background
  LAN server in Phase 4. A guest polling a closed host correctly
  shows Stale, then Offline.
- **No remote history sync, no remote control.** The guest sees
  live totals + top apps + today-recorded totals only. It cannot
  read the remote device's full history, change its settings, or
  start/stop anything on it. Pairing is view-only, by design.

## Phase 5 — History fix, all-apps list, graphs, Live System Map, glass style (BUILT, local only)

Dennis reported 2026-11-04 "could not load history" and asked for:
(1) all apps using mobile data including installed apps with
icons/names, system apps, and background-running apps; (2) a
dashboard in graph format with different graph types and their uses;
(3) a "neural link" graph of how phone apps connect in real time;
(4) a professional clean glass corporate dashboard style. All four
are built here, inside the existing honesty rules: nothing is
invented, derived values are never presented as measured, and
anything unproven on a real phone is labelled as such below.

### 5.1 History loading — root cause found and fixed

The bug was in the dashboard, not in SQLite. The old code did
`SqliteHistoryStore.open().then(...)` with **no error handler, no
timeout, and no loading/error state**: if the open future hung
(e.g. a slow or stuck platform channel) or threw outside the
store's own catch, `_history` stayed null forever and the History
tab showed a bare spinner forever — no error, no Retry, nothing to
tap. (The store's own catch already substituted an in-memory
fallback on a clean throw, so the spinner case was the hung /
never-resolving open, which the widget test reproduced: the old
smoke test's real open never resolved under flutter_test, and only
the absence of a timer exposed it.)

Fix (`lib/src/history.dart`, `lib/main.dart`):
- `SqliteHistoryStore.openStrict()` throws instead of silently
  substituting the fallback, so the cause is preserved;
  `openHistoryStore()` wraps it with a 15-second timeout and
  always resolves: persistent store + no error, or in-memory store
  + the cause as a visible string.
- The History tab now has three states, never one spinner: loading
  shows "Loading history…", a failed open shows its cause with a
  Retry button (Retry re-attempts SQLite; a successful retry swaps
  the store in, but session-only records made under the fallback
  are not migrated — they were never persisted), and a fallback
  store shows the existing in-memory warning plus the cause.
- Summary staleness fixed: the old `_summaryFuture` was cached once
  forever. HistoryTab now re-reads its summary when the dashboard
  reports the tab was opened (TabController listener bumps a
  refresh token) and after a background merge, not only on manual
  Refresh. A pre-existing `setState` bug surfaced by the new Retry
  test was also fixed: Retry/Refresh passed a Future-returning
  closure to `setState`, which Flutter rejects.
- The honest definition is unchanged: recorded-while-sampling only,
  never invented full-day totals.

### 5.2 All-apps list (Android primary)

Native (`UsageSnapshotProvider.kt`): `getInstalledApps` enumerates
via `PackageManager.getInstalledApplications`, including system
apps (flagged `isSystem`, with enabled/disabled state and UID),
and the per-UID totals now keep the mobile split separate
(`mobileRx`/`mobileTx`, -1 = unknown) instead of summing blindly.
Dart (`lib/src/all_apps.dart`) merges installed + stats: every
installed app appears, zero-usage apps shown as 0 / "No data
today", never hidden and never given fake bytes; data rows with no
installed entry are still shown (labelled as not from the installed
list). Filter chips: All / Data users only / System / User apps.
Sort is unchanged: current rate, then total.
Icons: native `getAppIcon` encodes one icon to a PNG of at most
96 px; Dart loads icons lazily for visible rows only (`_AppIcon`,
placeholder letter until loaded) and caches results in memory —
the dashboard is never blocked on hundreds of icons, and a failed
icon load caches as placeholder, not retried per frame.
Windows: unchanged collector processes, labelled in the UI as
"processes seen by the collector" — no installed-apps list and no
icons are claimed there.

### 5.3 Background / running state — honestly

Android does not let an ordinary app list other apps' live
processes completely, and per-app battery drain is not available.
So badges derive only from observable signals
(`UsageSnapshotProvider.getAppActivity` + `lib/src/all_apps.dart`
`activityBadge`):
- UsageStatsManager (usage access already required): foreground
  time today and last-used time.
- ActivityManager running-process list, where the OS actually
  returns it — a package absent from it is "not reported running",
  never "proven not running".
Badge rule: "Foreground now" = OS-reported running, or last used
within 2 minutes; "Background recently" = used within 24 hours;
"Not recently used" = older or no record; "Activity unknown" = no
activity signal reached Dart at all. The badge means recent
usage-stats activity, NOT a claimed live process list, and the
code + UI say so. Foreground minutes are labelled "foreground
time", never "battery use".

### 5.4 Graphs (CustomPaint, no new chart dependency)

`fl_chart` was deliberately NOT added: it would be a new
dependency whose integration could only be proven by a build, and
the lightweight CustomPaint widgets below are fully testable in
pure Dart. `lib/src/charts.dart` holds the pure builders;
`lib/src/chart_widgets.dart` the widgets. Every chart carries a
one-line caption stating the question it answers, and an empty
state says "No data yet" — never a sample curve.
- Live rate line/area chart: session ring buffer of 1-second
  snapshots (default last 180 samples ≈ 3 minutes), down cyan /
  up indigo, peak labelled. Answers "When did usage spike?"
- Per-app bar chart: top 10 by total. Answers "Which app used the
  most?"
- Donut/share chart: share of total by app, top apps + Other,
  shares summing to 1. Answers "How is usage shared between apps?"
- History daily bar chart: last 7 days from
  `HistorySummary.last7Daily` (new optional field, zero-filled for
  unrecorded days). Answers "How much was recorded each day?"
All charts are built from real snapshots / recorded history only.

### 5.5 Live System Map — the "neural link" graph, honestly labelled

The UI calls it "Live System Map", NOT proof that apps share data
with each other, and its legend states the boundary in full.
`lib/src/system_map.dart` builds it; `lib/src/system_map_widget.dart`
draws it (device hub centre, live-rate apps on a ring, transport /
feature / group nodes outer, node size by live rate, colour by
state). It updates with the live poll.

Edges exist ONLY where a real signal exists:
- App → Mobile / Wi-Fi: the app's own per-transport totals
  (mobile split measured and > 0, or derived Wi-Fi bytes > 0).
  Unknown split (-1, e.g. Windows or VPN snapshots) means no edge.
- App → phone feature: AppOpsManager actually reported that op as
  allowed for that package (Camera, Microphone, Fine location).
  No signal means no badge and no edge.
- App → "same app group" node: two or more installed packages share
  one Linux UID (verifiable from PackageManager). A packaging fact,
  not a data-sharing claim.
NO app-to-app "data sharing" edges, NO per-app battery numbers:
battery is device-level only (BatteryManager level + charging,
shown on the hub node), and the tests assert both rules — no edge
with two app endpoints, and no app node mentioning battery.
Android does not expose real-time inter-app data sharing, so the
map shows what is measurable, not an invented network. This
boundary is also stated in the README in plain language.

### 5.6 Glass corporate style

`lib/src/glass.dart`: the existing logo palette, not a rebrand —
deep navy/indigo gradient background, indigo → cyan accent, white
text. Cards are frosted glass (translucent white fill, thin white
border, blur over the gradient) with generous spacing; body text
is always white / white70+ on the dark gradient, never grey-on-
gradient. All three tabs use it (Live, History, Devices). The
Devices QR code keeps a white backing so it stays scannable on the
dark card. `withOpacity` is kept deliberately (not `withValues`)
because the CI workflows pin Flutter 3.24.5, which predates
`withValues` — the local 3.47 SDK flags it as a deprecation info
only; see the verification note below.

### Phase 5 honest limits (read before claiming anything)

- **Nothing in Phase 5 is proven on a real phone.** `flutter
  analyze` (5 infos, all the intentional `withOpacity` notes) +
  `flutter test` 65/65 pass locally (Linux VM). They prove Dart
  logic (open fallback, error + Retry, refresh, merge, chart
  builders, map edge rules) and the UI shell — NOT the Kotlin
  (needs an Android SDK + phone, absent here) and NOT the glass
  rendering, icon cost, or map readability on a real screen.
  Do not claim history is fixed or the map is real-time until a
  real phone proves it.
- **Installed-list completeness is unverified.** Phase 5 does NOT
  add `QUERY_ALL_PACKAGES` (Play policy risk: it is a restricted
  permission needing a declaration). On Android 11+,
  `getInstalledApplications` is subject to package-visibility
  filtering, so the list may be incomplete on a real phone. Device
  test: compare the All-apps count against Settings → Apps before
  any completeness claim; if it is short, `QUERY_ALL_PACKAGES`
  with a Play declaration is the flagged follow-up, not a silent
  addition.
- **AppOps feature badges are unverified.** Cross-package
  `AppOpsManager.checkOpNoThrow` may return nothing on some
  devices / OS versions. The code treats that as "no signal" (no
  badges), which is safe but means badges may simply be absent on
  a real phone — a finding to report, not a reason to guess.
  The same applies to the ActivityManager running-process list,
  which modern Android deliberately limits.
- **Icon loading cost on a phone with hundreds of apps is
  unmeasured.** Icons load lazily per visible row and are capped
  at 96 px, but total channel traffic and scroll jank on a
  low-end phone are device-test items.
- **Windows scope is unchanged.** No Windows installed-apps list,
  no Windows icons, no Windows transport edges (no per-process
  mobile split from the collector). The Windows list is labelled
  as collector processes wherever it appears.
- **Map layout is a ring layout, not a physics graph.** With many
  live apps the ring crowds; node labels truncate. Readability at
  high app counts is a device-test item, and the map only shows
  apps with a live rate — a zero-rate app with data today is not
  a "live" node by design.
- **Chart history is session-only.** The rate chart covers the
  current app session's last ~3 minutes; closing the app clears
  it. It is not a day chart, and must never be described as one.

### Phase 5 device tests (in addition to the earlier lists)

1. History: with the app open, confirm the History tab loads
   (never a bare spinner); kill and reopen repeatedly; if SQLite
   ever fails, confirm the in-memory warning + cause + Retry
   appear and Retry recovers.
2. All apps: compare the All-apps count and system badges against
   Settings → Apps; confirm zero-data apps show "No data today"
   with 0 bytes; scroll a phone with 200+ apps and note icon load
   behaviour and any jank.
3. Badges: use an app, return within 2 minutes (expect "Foreground
   now"), then after a day of non-use (expect "Not recently
   used"); confirm no badge ever claims an app is "running" from
   the OS list alone.
4. Graphs: stream for a minute and confirm the rate chart spikes,
   the top-10 bars and donut match the per-app list, and the
   History daily bars match recorded totals (including a zero day).
5. Map: with 2–3 apps actively using data, confirm transport edges
   match the actual connection (mobile vs Wi-Fi), feature badges
   appear only where the app genuinely holds the permission, no
   line ever claims two apps share data, and battery appears only
   at device level.
6. Glass: check every card in sunlight / low brightness for
   readable contrast, and scan the Devices QR code off the dark
   card.

## Permissions the user must grant

| Device | Grant | How | If not granted |
|---|---|---|---|
| Android | Usage access | Dashboard banner → Settings → Usage access → MyMy → Allow | Device totals only; per-app list empty |
| Android (Phase 2) | Notifications + foreground service | System prompts on first background run | Sampling stops when app is closed |
| Android (Phase 3) | In-app VPN disclosure | Accept in the disclosure dialog on the Live tab | VPN mode cannot start (Polling stays) |
| Android (Phase 3) | System VPN consent | Android VPN dialog → OK | `'denied'`; mode stays Polling with an error message |
| Android (Phase 3) | `BIND_VPN_SERVICE` (manifest) | Granted to the app's own service at install | VPN service cannot be bound |
| Android (Phase 4) | `INTERNET` (manifest, LAN-only) | Granted at install | Devices tab cannot host or join; everything else works as before |
| Android + Windows (Phase 4) | Pairing opt-in on both sides | Host shows PIN + code; guest pastes code or enters host/port/PIN | No remote device is shown; no data is shared |
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

### Android phone (Phase 3 — VPN live mode)
Run these only after the Actions APK build is green. Do them in
order; stop at the first failure and report it — do not skip ahead
and claim the mode works.
1. With no other VPN running, open MyMy → Live tab. Confirm the
   mode control defaults to Polling (never VPN) on a fresh install
   and on reopen.
2. Switch to VPN live. A disclosure dialog must appear first, with
   the device-only / no-server / bytes-only / disconnects-other-VPN /
   higher-battery wording. Decline it: mode must stay Polling.
3. Accept the disclosure, then accept the Android VPN consent
   dialog. The "VPN live" badge must appear, and the VPN
   notification must show with a working Stop action.
4. Browse a website and stream a video for ~30 s in VPN mode. Pages
   must load normally; the live rate must rise; the per-app list
   must show the browser / video app climbing. **If browsing fails
   in VPN mode, that is the INTERNET-permission hypothesis failing
   (see Phase 3 honest limits) — report it as the first fix to try,
   do not work around it silently.**
5. Open a UDP/DNS-heavy app (a game or voice call, and a fresh
   browser tab so DNS runs inside the tunnel). Confirm the app
   works, DNS resolves, and its bytes appear — or, honestly, that
   some of them land in "Unattributed". Record which.
6. Start an app's download *before* enabling VPN mode, then enable
   it mid-download: confirm the pre-VPN connection is not
   VPN-counted, and that restarting the download after enabling
   counts it.
7. VPN-conflict behaviour: with a real VPN (any provider) connected,
   try enabling MyMy VPN live — it must fail visibly (tunnel error),
   never silently. Then disconnect the real VPN, enable MyMy VPN
   live, and confirm the real VPN is disconnected while MyMy is
   active (Android allows one VPN at a time).
8. Reconciliation: after a few minutes in VPN mode, check the
   reconciliation card. A match within tolerance is the pass; a
   mismatch warning is a finding to report with its numbers, not a
   failure to hide — note whether the gap looks like IPv6 traffic
   (compare against Settings data usage for the same window).
9. Stop from the Live tab, then again from the notification action:
   badge and notification must disappear, mode returns to Polling,
   and the live rate must not spike on the switch back.
10. Battery: use the phone normally in VPN mode for an hour and
    note qualitatively whether battery drain is noticeably higher
    than polling. No number is promised; a qualitative note is the
    honest result.
11. Play disclosure: before any store submission, re-read the
    disclosure text against Play's VPNService policy and confirm it
    still matches what the service actually does.

### Two devices (Phase 4 — phone + laptop, real hardware)
Run these only after the Actions APK + Windows builds are green and
installed. Do them on a trusted home Wi-Fi only — Phase 4 has no TLS
(LAN + token only), so never test pairing on public Wi-Fi.
1. Phone hosts, laptop joins: phone Devices tab → Host this device
   → QR + PIN shown; laptop Devices tab → Join a device → paste the
   pairing code (or enter host + port + PIN). Within ~5 seconds the
   laptop card must show the phone's totals + top apps, with a live
   rate that rises when the phone streams.
2. Reverse: laptop hosts, phone joins. Windows Firewall will prompt
   on the laptop — allow on **private** networks only, not public.
   Declining must show the guest as Offline, not crash.
3. PIN rules on a real network: a PIN older than 2 minutes must fail;
   a used PIN must fail on second use; 5 wrong PINs must lock the
   PIN. The guest must see a plain failure, never a partial pairing.
4. Revoke both ways: host "Stop hosting & revoke" must make the guest
   show revoked/Offline; guest "Forget" must remove the card and stop
   polling. A restarted host must require fresh pairing.
5. Stale signal: close the host app mid-view — the guest card must go
   Stale (rates zeroed, last-seen shown), never a frozen rate
   presented as live, and never zeros presented as usage.
6. No mixing: remote totals must NOT appear in the guest's History
   tab, and must NOT change its budget or today total.
7. Never-shared check: no screen anywhere may show a remote device's
   URLs, hosts, DNS, browsing history, or connections — totals +
   per-app bytes only.
8. Rename: changing a device's label updates only that side's display
   (restart hosting for guests to see a host's new label).
9. QR check: the host QR code displays on a real phone screen. It is
   display-only; the guest pastes the code or enters host/port/PIN
   manually — there is no camera scan to test.

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
- `flutter analyze` clean + `flutter test` 31/31 pass locally (Linux
  VM). They prove Dart logic (history deltas, throttle, reboot
  clamping, merge dedupe, budget thresholds, Windows JSON parsing,
  plus Phase 3 mode defaults, disclosure persistence, reconciliation
  maths, VPN snapshot parsing, stop/teardown state, and history
  source separation) and the UI shell — **not** the C++ collector
  (needs MSVC + Flutter Windows headers, absent here) and **not**
  the Kotlin services (needs an Android SDK + phone, absent here).
  GitHub Actions (manual-only workflows) is the first real compile
  for both, and a real laptop / phone is the first real behaviour
  proof. Phase 3's VPN forwarding path is additionally unproven even
  in code review terms beyond the documented APIs — see § Phase 3
  honest limits.
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
lib/main.dart                          Live + History + Devices tabs, budget banner,
                                       Phase 5 glass theme, charts, all-apps card,
                                       Live System Map, history open/retry/refresh
lib/src/models.dart                    Counter contract (cumulative only) +
                                       Phase 5 per-app mobile split
lib/src/format.dart                    Decimal MB / rate formatting
lib/src/usage_service.dart             Channel source + rate maths +
                                       background-sampling channel methods
lib/src/history.dart                   SQLite history (v2, per-source) + in-memory twin +
                                       Phase 5 openHistoryStore (fallback + cause +
                                       timeout) + last7Daily for the daily chart
lib/src/budget.dart                    Daily cap checker + local store
lib/src/background.dart                Background-sample merge controller
lib/src/vpn.dart                       VPN mode state, disclosure store,
                                       reconciliation, VPN polling service
lib/src/devices.dart                   LAN host server, pairing payload,
                                       PIN + token, guest poller, store
lib/src/app_info.dart                  Phase 5: installed apps, activity,
                                       icons, device battery (channel source)
lib/src/all_apps.dart                  Phase 5: installed+stats merge, filters,
                                       sort, honest activity badges
lib/src/charts.dart                    Phase 5: pure chart-data builders
                                       (rate ring buffer, top 10, donut, daily)
lib/src/chart_widgets.dart             Phase 5: CustomPaint rate/donut charts,
                                       bar lists, daily bars, captions
lib/src/system_map.dart                Phase 5: Live System Map model + edge
                                       rules (no app-to-app sharing edges)
lib/src/system_map_widget.dart         Phase 5: map canvas + legend
lib/src/glass.dart                     Phase 5: navy/indigo gradient theme +
                                       frosted-glass card
windows/runner/mymy_usage.h/.cpp       Windows collector (IP Helper + EStats)
android/.../MainActivity.kt            mymy/usage channel (Android engine +
                                       VPN consent flow, request code 1001 +
                                       Phase 5 installed/activity/icon/battery)
android/.../UsageSnapshotProvider.kt   Shared snapshot logic (UI + service) +
                                       Phase 5 installed list, per-transport
                                       splits, UsageStats/AppOps, icons, battery
android/.../BackgroundSamplingService.kt  Foreground service, 1 sample/min
android/.../VpnLiveService.kt          VPN service: TUN loop, TCP/UDP proxy,
                                       attribution, counters, teardown
android/.../VpnPacket.kt               IPv4/TCP/UDP parse + build, checksums
android/.../AndroidManifest.xml        Permissions (INTERNET LAN-only, Phase 4;
                                       BIND_VPN_SERVICE + special-use FGS;
                                       QUERY_ALL_PACKAGES deliberately NOT
                                       added — see Phase 5 honest limits)
test/usage_service_test.dart           Rate/format/parsing tests
test/history_test.dart                 History, merge, budget, Windows JSON
test/vpn_test.dart                     Mode defaults, disclosure, reconciliation,
                                       VPN snapshot JSON, source separation
test/devices_test.dart                 Payload allowlist, PIN/token rules,
                                       rates, stale/offline, host loopback
test/widget_test.dart                  Dashboard smoke test (fake source,
                                       history store injected)
test/phase5_test.dart                  History fallback/retry/refresh, all-apps
                                       merge, chart builders, system-map edges
.github/workflows/build-apk.yml        CI: analyze + test + release APK
.github/workflows/build-windows.yml    CI: analyze + test + Windows release
```
