import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'src/all_apps.dart';
import 'src/app_info.dart';
import 'src/background.dart';
import 'src/budget.dart';
import 'src/chart_widgets.dart';
import 'src/charts.dart';
import 'src/devices.dart';
import 'src/format.dart';
import 'src/glass.dart';
import 'src/history.dart';
import 'src/models.dart';
import 'src/system_map.dart';
import 'src/system_map_widget.dart';
import 'src/usage_service.dart';
import 'src/vpn.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyMy — Live Data Usage',
      // Phase 5 glass corporate style: dark navy/indigo gradient,
      // indigo -> cyan accent, white text. See lib/src/glass.dart.
      theme: myMyGlassTheme(),
      home: const DashboardPage(),
    );
  }
}

/// Live + History dashboard.
///
/// Polls [UsageService] once per second on the Live tab. Every number
/// comes from a real snapshot counter or from a rate derived from two
/// real snapshots. If a snapshot fails, the dashboard stops polling
/// and says so — it never shows sample data as if it were real usage.
///
/// History totals mean "recorded while MyMy was sampling" (live tab
/// open, or the Android foreground service running), not full OS day
/// totals. See lib/src/history.dart.
class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    this.service,
    this.historyStore,
    this.backgroundSource,
    this.vpnSource,
    this.appInfoSource,
  });

  final UsageService? service;

  /// Injected in tests; otherwise SQLite is opened via
  /// [openHistoryStore] (in-memory fallback + visible cause + Retry
  /// on failure — never a silent spinner).
  final HistoryStore? historyStore;
  final BackgroundSamplingSource? backgroundSource;

  /// Injected in tests; otherwise the platform-channel source
  /// (Android installed list / activity / icons / battery).
  final AppInfoSource? appInfoSource;

  /// Injected in tests; otherwise derived from the channel source
  /// (Android only — the method channel implements it there).
  final VpnLiveSource? vpnSource;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin {
  late UsageService _service;
  late VpnPollingService _vpnPolling;
  late TabController _tabController;
  HistoryStore? _history;

  /// Phase 5 history-open state. [_historyError] is the cause when
  /// the open fell back to in-memory; [_historyLoading] is true only
  /// while the first open is in flight, and the History tab shows
  /// "Loading history…" (not a bare spinner) plus a Retry on error.
  String? _historyError;
  bool _historyLoading = true;

  /// Bumped whenever the History tab is opened, so HistoryTab
  /// re-reads its summary instead of serving the cached one.
  int _historyRefreshToken = 0;
  BudgetStore? _budgetStore;

  // Phase 5 live data: recent rate samples for the rate chart,
  // installed apps + activity for the all-apps list and system map.
  final RateHistory _rateHistory = RateHistory();
  AppInfoSource? _appInfoSource;
  List<InstalledApp> _installed = const [];
  Map<String, AppActivity> _activity = const {};
  DeviceBattery? _battery;
  final Map<String, Uint8List?> _iconCache = {};
  final Set<String> _iconLoading = {};
  BackgroundSamplingSource? _backgroundSource;
  VpnLiveSource? _vpnSource;
  UsageStatus? _status;
  LiveUsage? _live;
  UsageSnapshot? _lastSnapshot;
  String? _error;
  Timer? _timer;
  bool _polling = false;
  bool _budgetCrossed = false;
  DateTime? _lastBudgetCheck;
  bool _backgroundOn = false;
  bool _mergedOnce = false;
  int _mergedCount = 0;

  // Phase 3 VPN live mode. The mode always starts as polling; VPN is
  // only entered through the disclosure + system consent flow below.
  final VpnLiveState _vpnState = VpnLiveState();
  VpnDisclosureStore? _disclosureStore;
  UsageSnapshot? _vpnBaseline;
  ReconciliationResult? _reconciliation;
  int _pollsSinceReconciliation = 0;
  String _vpnError = '';

  bool get _vpnControlsVisible {
    // Production: Android only (network-stats engine). Tests: an
    // injected vpnSource forces the controls visible regardless.
    if (widget.vpnSource != null) return true;
    return _status?.engine == 'network-stats' && _vpnSource != null;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      // Refresh history whenever the tab is opened, not only on
      // manual Refresh — the old cached-future tab went stale.
      if (!_tabController.indexIsChanging && _tabController.index == 1) {
        setState(() => _historyRefreshToken++);
      }
    });
    _service = widget.service ?? UsageService();
    _appInfoSource =
        widget.appInfoSource ?? MethodChannelAppInfoSource();
    final source = _service.source;
    BackgroundSamplingSource? background = widget.backgroundSource;
    if (background == null && source is BackgroundSamplingSource) {
      background = source as BackgroundSamplingSource;
    }
    _backgroundSource = background;
    _vpnSource = widget.vpnSource ??
        (source is VpnLiveSource ? source as VpnLiveSource : null);
    _vpnPolling = VpnPollingService(
      _vpnSource ?? _NoopVpnLiveSource(),
    );
    _loadDisclosure();
    _checkRestoredVpn();
    if (widget.historyStore != null) {
      _history = widget.historyStore;
      _historyLoading = false;
    } else {
      _openHistory();
    }
    _loadBudget();
    _refreshStatusAndStart();
  }

  /// Phase 5: opens history through [openHistoryStore], which always
  /// resolves — fallback store + cause on failure, never a null
  /// store left spinning. Retry re-attempts SQLite; a successful
  /// retry replaces the in-memory store (session-only records made
  /// under the fallback are not migrated — they were never
  /// persisted, and the fallback banner says so).
  Future<void> _openHistory() async {
    setState(() => _historyLoading = true);
    final result = await openHistoryStore();
    if (!mounted) return;
    final previous = _history;
    setState(() {
      // Only swap in a persistent store, or the first store ever.
      // A failed retry keeps the working fallback instead of
      // swapping one fallback for another.
      if (result.store.isPersistent || previous == null) {
        _history = result.store;
      }
      _historyError = result.error;
      _historyLoading = false;
    });
    _maybeMergeBackground();
  }

  Future<void> _loadAppInfo() async {
    final source = _appInfoSource;
    if (source == null) return;
    try {
      final installed = await source.getInstalledApps();
      final activity = await source.getAppActivity();
      final battery = await source.getBattery();
      if (!mounted) return;
      setState(() {
        _installed = installed;
        _activity = activity;
        _battery = battery;
      });
    } catch (_) {
      // App info is best-effort: the dashboard still works from
      // snapshot data alone, labelled as such.
    }
  }

  /// Lazy icon load for one visible row. Icons are never fetched for
  /// the whole list up front: a phone with hundreds of apps would
  /// stall the dashboard on icon bytes. A failed load caches null
  /// (placeholder letter) and is not retried per frame.
  Future<Uint8List?> _loadIcon(String packageName) async {
    if (_iconCache.containsKey(packageName)) {
      return _iconCache[packageName];
    }
    if (_iconLoading.contains(packageName)) return null;
    _iconLoading.add(packageName);
    final bytes = await _appInfoSource?.getAppIcon(packageName);
    _iconLoading.remove(packageName);
    _iconCache[packageName] = bytes;
    if (mounted) setState(() {});
    return bytes;
  }

  Future<void> _loadDisclosure() async {
    try {
      final store = await VpnDisclosureStore.load();
      if (!mounted) return;
      setState(() {
        _disclosureStore = store;
        _vpnState.disclosureAccepted = store.accepted;
      });
    } catch (_) {
      // Disclosure state unavailable here (e.g. in tests); VPN mode
      // simply stays off, which is the safe default.
    }
  }

  /// If the VPN service is already running when the app reopens (the
  /// user started it earlier and never stopped it), restore the badge
  /// and VPN polling — but reconciliation stays unavailable, because
  /// the system baseline from the original start is gone.
  Future<void> _checkRestoredVpn() async {
    final vpnSource = _vpnSource;
    if (vpnSource == null) return;
    try {
      final active = await vpnSource.isVpnLive();
      if (!active || !mounted) return;
      setState(() {
        _vpnState.markStarted(
          DateTime.now().millisecondsSinceEpoch,
        );
        _reconciliation = const ReconciliationResult(
          status: 'unavailable',
          vpnTotalBytes: 0,
          systemDeltaBytes: 0,
          differenceBytes: 0,
          message: 'Reconciliation unavailable: VPN mode was already '
              'running when the app reopened, so no system baseline '
              'exists for this session.',
        );
      });
    } catch (_) {}
  }

  Future<void> _loadBudget() async {
    try {
      final store = await BudgetStore.load();
      if (!mounted) return;
      setState(() => _budgetStore = store);
    } catch (_) {
      // Budget settings unavailable here (e.g. in tests); the
      // dashboard still works, just without a cap.
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _timer?.cancel();
    final last = _lastSnapshot;
    if (last != null) {
      // Best-effort final sample; a killed app may skip this, which
      // only loses at most the last minute of granularity.
      _history?.record(last, force: true);
    }
    _history?.close();
    super.dispose();
  }

  Future<void> _maybeMergeBackground() async {
    if (_mergedOnce || _history == null || _backgroundSource == null) return;
    _mergedOnce = true;
    try {
      final controller = BackgroundSamplingController(
        source: _backgroundSource!,
        history: _history!,
      );
      final count = await controller.mergePendingSamples();
      final on = await _backgroundSource!.isBackgroundSampling();
      if (!mounted) return;
      setState(() {
        _mergedCount = count;
        _backgroundOn = on;
      });
    } catch (_) {
      // Background merge is best-effort; a failure here must not
      // break the live dashboard.
    }
  }

  Future<void> _refreshStatusAndStart() async {
    final status = await _service.getStatus();
    if (!mounted) return;
    setState(() {
      _status = status;
      _error = null;
    });
    _maybeMergeBackground();
    _loadAppInfo();
    if (status.engine != 'unimplemented') {
      _startPolling();
    }
  }

  void _startPolling() {
    if (_polling) return;
    _polling = true;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final live = _vpnState.mode == LiveMode.vpn
            ? await _vpnPolling.poll()
            : await _service.poll();
        if (!mounted) return;
        _lastSnapshot = live.snapshot;
        // Feed the live rate chart (last ~3 minutes at 1 Hz).
        _rateHistory.add(
          RatePoint(
            timestamp: live.snapshot.timestamp,
            rxBytesPerSecond: live.rxBytesPerSecond,
            txBytesPerSecond: live.txBytesPerSecond,
          ),
        );
        // History records only the active mode's snapshots. The
        // store keeps a separate baseline per source, so a mode
        // switch never invents a delta — but recording both modes
        // at once would double-count, so only the active one records.
        await _history?.record(live.snapshot);
        setState(() {
          _live = live;
          _error = null;
        });
        await _refreshBudgetCheck(live.snapshot);
        if (_vpnState.mode == LiveMode.vpn) {
          await _maybeReconcile();
        }
      } catch (e) {
        _timer?.cancel();
        _polling = false;
        if (!mounted) return;
        setState(() => _error = e.toString());
      }
    });
  }

  /// Reconciliation, at most once every 30 polls while VPN mode is
  /// active: compare VPN cumulative totals against the system delta
  /// since the baseline captured at VPN start.
  Future<void> _maybeReconcile() async {
    _pollsSinceReconciliation++;
    if (_pollsSinceReconciliation < 30) return;
    _pollsSinceReconciliation = 0;
    final vpnSource = _vpnSource;
    final baseline = _vpnBaseline;
    final latest = _lastSnapshot;
    if (vpnSource == null || baseline == null || latest == null) return;
    try {
      final now = await _service.source.getSnapshot();
      if (!mounted) return;
      setState(() {
        _reconciliation = Reconciliation.check(
          vpnRxBytes: latest.totalRxBytes,
          vpnTxBytes: latest.totalTxBytes,
          netBaseline: baseline,
          netNow: now,
        );
      });
    } catch (_) {
      // Reconciliation is advisory; a failure here must not break
      // the live dashboard.
    }
  }

  Future<void> _refreshBudgetCheck(UsageSnapshot snapshot) async {
    final store = _budgetStore;
    final history = _history;
    if (store == null || history == null) return;
    final capMb = store.capMb;
    if (capMb == null) {
      if (_budgetCrossed && mounted) setState(() => _budgetCrossed = false);
      return;
    }
    final now = DateTime.now();
    if (_lastBudgetCheck != null &&
        now.difference(_lastBudgetCheck!) < const Duration(seconds: 30)) {
      return;
    }
    _lastBudgetCheck = now;
    try {
      final summary = await history.summary();
      final capBytes = BudgetChecker.capBytesFromMb(capMb);
      final crossed =
          BudgetChecker.crossed(summary.today.totalBytes, capBytes);
      if (mounted && crossed != _budgetCrossed) {
        setState(() => _budgetCrossed = crossed);
      }
    } catch (_) {}
  }

  Future<void> _openSettings() async {
    await _service.openUsageSettings();
    await _refreshStatusAndStart();
  }

  Future<void> _toggleBackground(bool on) async {
    final source = _backgroundSource;
    if (source == null) return;
    final ok = on
        ? await source.startBackgroundSampling()
        : await source.stopBackgroundSampling();
    if (!mounted) return;
    setState(() {
      // Only adopt the requested state when the native side confirmed it
      // (e.g. a missing notification permission makes start fail).
      if (ok) _backgroundOn = on;
    });
  }

  Future<void> _onModeSelected(LiveMode mode) async {
    if (mode == LiveMode.polling) {
      await _stopVpn();
      return;
    }
    await _startVpnFlow();
  }

  /// Disclosure → system consent → service start, in that order.
  /// Any step failing or being declined leaves the mode as polling.
  Future<void> _startVpnFlow() async {
    final vpnSource = _vpnSource;
    if (vpnSource == null) return;
    if (!_vpnState.disclosureAccepted) {
      final accepted = await _showDisclosureDialog();
      if (!accepted || !mounted) {
        setState(() => _vpnState.mode = LiveMode.polling);
        return;
      }
      try {
        await _disclosureStore?.accept();
      } catch (_) {}
      setState(() => _vpnState.disclosureAccepted = true);
    }
    final prepared = await vpnSource.prepareVpn();
    if (!mounted) return;
    if (prepared != 'ready') {
      setState(() {
        _vpnError = prepared == 'denied'
            ? 'VPN consent was declined in the system dialog. '
                'MyMy stays in polling mode.'
            : 'Could not prepare VPN mode. MyMy stays in polling mode.';
        _vpnState.markStopped();
      });
      return;
    }
    final started = await vpnSource.startVpnLive();
    if (!mounted) return;
    if (!started) {
      final status = await vpnSource.getVpnStatus();
      setState(() {
        _vpnError = status.error.isNotEmpty
            ? status.error
            : 'VPN live mode could not be started. MyMy stays in '
                'polling mode.';
        _vpnState.markStopped();
      });
      return;
    }
    UsageSnapshot? baseline;
    try {
      baseline = await _service.source.getSnapshot();
    } catch (_) {
      baseline = null;
    }
    if (!mounted) return;
    // Fresh rate baselines for both modes: the first VPN poll must
    // not inherit polling counters (or vice versa) as a rate spike.
    _service = UsageService(source: _service.source);
    _vpnPolling.reset();
    setState(() {
      _vpnState.markStarted(DateTime.now().millisecondsSinceEpoch);
      _vpnBaseline = baseline;
      _reconciliation = null;
      _pollsSinceReconciliation = 0;
      _vpnError = '';
      _live = null;
    });
  }

  Future<void> _stopVpn() async {
    final vpnSource = _vpnSource;
    if (vpnSource != null && _vpnState.vpnActive) {
      await vpnSource.stopVpnLive();
    }
    if (!mounted) return;
    _service = UsageService(source: _service.source);
    _vpnPolling.reset();
    setState(() {
      _vpnState.markStopped();
      _reconciliation = null;
      _vpnBaseline = null;
      _vpnError = '';
      _live = null;
    });
  }

  Future<bool> _showDisclosureDialog() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('VPN live mode — please read first'),
        content: const SingleChildScrollView(
          child: Text(vpnDisclosureText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('I understand, turn on VPN live'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MyMy — Live Data Usage'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refreshStatusAndStart,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Live'),
            Tab(text: 'History'),
            Tab(text: 'Devices'),
          ],
        ),
      ),
      body: GradientBackground(
        child: SafeArea(
          child: status == null
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildLiveTab(status),
                    HistoryTab(
                      history: _history,
                      historyLoading: _historyLoading,
                      historyError: _historyError,
                      onRetryHistory: _openHistory,
                      refreshToken: _historyRefreshToken,
                      budgetStore: _budgetStore,
                      backgroundSource: _backgroundSource,
                      backgroundOn: _backgroundOn,
                      mergedCount: _mergedCount,
                      onToggleBackground: _toggleBackground,
                      onMerge: () async {
                        _mergedOnce = false;
                        await _maybeMergeBackground();
                        if (mounted) {
                          setState(() => _historyRefreshToken++);
                        }
                      },
                    ),
                    DevicesTab(
                    getLocalSnapshot: () => _service.source.getSnapshot(),
                    getTodayTotal: () async {
                      final history = _history;
                      if (history == null) return null;
                      final summary = await history.summary();
                      return (
                        rx: summary.today.rxBytes,
                        tx: summary.today.txBytes,
                      );
                    },
                  ),
                ],
              ),
        ),
      ),
    );
  }

  /// Builds the Live System Map from the current live snapshot.
  /// Transport bytes come from the snapshot's per-app mobile split;
  /// unknown splits (-1) yield no transport edge. See system_map.dart
  /// for the full honesty boundary.
  SystemMap _buildSystemMap(LiveUsage live) {
    final byId = {for (final a in live.snapshot.apps) a.id: a};
    final rates = <String, double>{};
    for (final entry in live.appRates.entries) {
      rates[entry.key] = entry.value.rxPerSecond + entry.value.txPerSecond;
    }
    final merged = attachActivity(
      mergeApps(
        installed: _installed,
        stats: live.snapshot.apps,
        rates: rates,
      ),
      _activity,
    );
    return buildSystemMap(
      apps: merged,
      installedById: {for (final a in _installed) a.packageName: a},
      mobileBytesOf: (app) => byId[app.id]?.mobileBytes ?? -1,
      wifiBytesOf: (app) => byId[app.id]?.wifiBytes ?? -1,
      rateOf: (app) => app.rateBytesPerSecond,
      now: DateTime.now(),
      battery: _battery,
    );
  }

  Widget _buildLiveTab(UsageStatus status) {
    final live = _live;
    final snapshot = live?.snapshot;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_vpnControlsVisible) ...[
          SegmentedButton<LiveMode>(
            segments: const [
              ButtonSegment(
                value: LiveMode.polling,
                label: Text('Polling'),
                icon: Icon(Icons.timer_outlined),
              ),
              ButtonSegment(
                value: LiveMode.vpn,
                label: Text('VPN live'),
                icon: Icon(Icons.vpn_lock_outlined),
              ),
            ],
            selected: {_vpnState.mode},
            onSelectionChanged: (modes) => _onModeSelected(modes.first),
          ),
          const SizedBox(height: 4),
          const Text(
            'Polling is the default. VPN live is opt-in, off by '
            'default, and Android only — it counts bytes as packets '
            'pass through MyMy on this device. See the disclosure '
            'before turning it on.',
          ),
          const SizedBox(height: 12),
        ],
        if (_vpnState.mode == LiveMode.vpn)
          GlassCard(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'VPN live — counting on this device only',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Traffic is routed through MyMy on this phone only. '
                    'No server, no content inspection. Any other VPN '
                    'is disconnected while this is active. Turn it off '
                    'above to return to polling mode.',
                  ),
                ],
              ),
            ),
          ),
        if (_vpnError.isNotEmpty)
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_vpnError),
            ),
          ),
        if (_vpnState.mode == LiveMode.vpn &&
            _reconciliation != null)
          _ReconciliationCard(result: _reconciliation!),
        if (status.engine == 'network-stats' && !status.hasPermission)
          _PermissionBanner(onOpenSettings: _openSettings),
        if (status.engine == 'windows-ip-helper' && !status.hasPermission)
          const GlassCard(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Run as administrator for per-process totals',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Windows per-process TCP bytes need administrator '
                    'rights (EStats). Without them you still get adapter '
                    'totals and the active connection list. UDP bytes '
                    'are not measured in Phase 2 (ETW is still pending).',
                  ),
                ],
              ),
            ),
          ),
        if (status.engine == 'unimplemented')
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Not available on this platform yet',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(status.note),
                ],
              ),
            ),
          ),
        if (_budgetCrossed)
          GlassCard(
            color: Theme.of(context).colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Daily cap reached',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Today\'s recorded total has reached your daily cap. '
                    'MyMy only shows this — it never blocks or limits '
                    'any app.',
                  ),
                ],
              ),
            ),
          ),
        if (_error != null)
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Could not read usage',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(_error!),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _refreshStatusAndStart,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        if (snapshot != null) ...[
          _LiveRateCard(live: live!),
          const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ChartCaption(
                    question: 'When did usage spike?',
                    note: 'Live down/up rate over the last few minutes '
                        '(1-second polls, real counters only).',
                  ),
                  const SizedBox(height: 12),
                  RateAreaChart(history: _rateHistory),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _TotalsCard(snapshot: snapshot),
          const SizedBox(height: 12),
          if (snapshot.mobileRxBytes >= 0) _NetworkSplitCard(snapshot: snapshot),
          if (snapshot.mobileRxBytes >= 0) const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ChartCaption(
                    question: 'Which app used the most?',
                    note: 'Top 10 by total in this snapshot window. '
                        'Android: today; Windows: since collector start.',
                  ),
                  const SizedBox(height: 12),
                  TopAppsBarList(
                    apps: topAppsByTotal(snapshot.apps),
                  ),
                  const SizedBox(height: 16),
                  const ChartCaption(
                    question: 'How is usage shared between apps?',
                    note: 'Share of total data by app, top apps + Other.',
                  ),
                  const SizedBox(height: 12),
                  ShareDonutChart(slices: donutShares(snapshot.apps)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _AllAppsCard(
            live: live,
            installed: _installed,
            activity: _activity,
            isAndroidEngine: status.engine == 'network-stats',
            loadIcon: _loadIcon,
            iconCache: _iconCache,
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Live System Map',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'What is measurably connected right now — not a '
                    'claim that apps share data with each other.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  SystemMapWidget(map: _buildSystemMap(live)),
                ],
              ),
            ),
          ),
          if (snapshot.connections.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ConnectionsCard(snapshot: snapshot),
          ],
        ] else if (_error == null && status.engine != 'unimplemented')
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator()),
          ),
        const SizedBox(height: 16),
        Text(
          'All data stays on this device. MyMy sends usage data '
          'nowhere. Rates are measured over 1-second polls of real '
          'system counters (see docs/BUILD_PLAN.md).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class HistoryTab extends StatefulWidget {
  const HistoryTab({
    super.key,
    required this.history,
    required this.historyLoading,
    required this.historyError,
    required this.onRetryHistory,
    required this.refreshToken,
    required this.budgetStore,
    required this.backgroundSource,
    required this.backgroundOn,
    required this.mergedCount,
    required this.onToggleBackground,
    required this.onMerge,
  });

  final HistoryStore? history;

  /// True while the first history open is in flight.
  final bool historyLoading;

  /// Cause when the open fell back to in-memory, else null.
  final String? historyError;

  /// Re-attempts the SQLite open.
  final VoidCallback onRetryHistory;

  /// Bumped by the dashboard whenever the History tab is opened, so
  /// the summary is re-read instead of serving a stale cached future.
  final int refreshToken;
  final BudgetStore? budgetStore;
  final BackgroundSamplingSource? backgroundSource;
  final bool backgroundOn;
  final int mergedCount;
  final ValueChanged<bool> onToggleBackground;
  final Future<void> Function() onMerge;

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  Future<HistorySummary>? _summaryFuture;
  final _capController = TextEditingController();
  bool _merging = false;

  @override
  void initState() {
    super.initState();
    _capController.text =
        widget.budgetStore?.capMb?.toStringAsFixed(0) ?? '';
  }

  @override
  void didUpdateWidget(covariant HistoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new store, or the tab being reopened, invalidates the cache.
    // The old code cached one future forever, so the tab went stale
    // while live polling kept recording.
    if (widget.history != oldWidget.history ||
        widget.refreshToken != oldWidget.refreshToken) {
      _summaryFuture = null;
    }
  }

  @override
  void dispose() {
    _capController.dispose();
    super.dispose();
  }

  Future<HistorySummary>? get _future {
    final history = widget.history;
    if (history == null) return null;
    return _summaryFuture ??= history.summary();
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.history;
    if (history == null) {
      // Phase 5: never a silent infinite spinner. Loading shows a
      // label; a failed open shows its cause with a Retry.
      if (widget.historyError != null) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Could not load history',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.historyError!,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: widget.onRetryHistory,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text(
              'Loading history…',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.historyError != null)
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.historyError!,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: widget.onRetryHistory,
                    child: const Text('Retry opening SQLite'),
                  ),
                ],
              ),
            ),
          ),
        if (!history.isPersistent)
          const GlassCard(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'History is in-memory only this session: SQLite could '
                'not be opened on this device.',
              ),
            ),
          ),
        FutureBuilder<HistorySummary>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.only(top: 32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Could not load history',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      if (snapshot.error != null)
                        Text(
                          snapshot.error.toString(),
                          style: const TextStyle(color: Colors.white70),
                        ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: () => setState(
                          () {
                            _summaryFuture = history.summary();
                          },
                        ),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final summary = snapshot.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Recorded while sampling',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () {
                          _summaryFuture = history.summary();
                        },
                      ),
                      child: const Text('Refresh'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Totals below cover only periods when MyMy was '
                  'sampling (live tab open, or background sampling on). '
                  'Traffic before the first sample of a day is not '
                  'invented.',
                ),
                const SizedBox(height: 12),
                _HistoryTotalsCard(summary: summary),
                const SizedBox(height: 12),
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const ChartCaption(
                          question: 'How much was recorded each day?',
                          note: 'Last 7 days, recorded while sampling '
                              'only. A zero day means nothing was '
                              'recorded, not that nothing was used.',
                        ),
                        const SizedBox(height: 12),
                        DailyBarChart(
                          bars: dailyBars(summary.last7Daily),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _HistoryPerAppCard(summary: summary),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        _BudgetCard(
          budgetStore: widget.budgetStore,
          capController: _capController,
        ),
        const SizedBox(height: 12),
        _BackgroundCard(
          backgroundSource: widget.backgroundSource,
          backgroundOn: widget.backgroundOn,
          mergedCount: widget.mergedCount,
          merging: _merging,
          onToggle: widget.onToggleBackground,
          onMerge: () async {
            setState(() => _merging = true);
            await widget.onMerge();
            setState(() {
              _merging = false;
              _summaryFuture = history.summary();
            });
          },
        ),
      ],
    );
  }
}

/// Phase 4 — Devices tab: optional local-LAN cross-device view.
///
/// This device keeps measuring itself exactly as before. A remote
/// device is only shown after explicit pairing on both sides, and
/// only while its host is running. Remote totals are NEVER written
/// into this device's history — they are displayed only, from live
/// polls every 5 seconds while this tab is open (not in the
/// background). A remote device that stops answering is Stale or
/// Offline with its last-seen time; its rates are forced to 0, never
/// a frozen rate presented as live.
class DevicesTab extends StatefulWidget {
  const DevicesTab({
    super.key,
    required this.getLocalSnapshot,
    required this.getTodayTotal,
    this.store,
    this.fetcher,
  });

  final Future<UsageSnapshot> Function() getLocalSnapshot;
  final Future<({int rx, int tx})?> Function() getTodayTotal;

  /// Injected in tests; otherwise SharedPreferences-backed.
  final DevicesStore? store;
  final RemoteFetcher? fetcher;

  @override
  State<DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<DevicesTab> {
  DevicesStore? _store;
  List<PairedDevice> _paired = [];
  String _ownLabel = defaultDeviceLabel();
  final _ownLabelController = TextEditingController();
  LanHostServer? _host;
  String? _hostError;
  bool _hostStarting = false;
  final Map<String, RemoteDevicePoller> _pollers = {};
  final Map<String, LiveUsage> _views = {};
  Timer? _pollTimer;

  bool _showJoin = false;
  String _joinError = '';
  final _payloadController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _pinController = TextEditingController();
  final _joinLabelController = TextEditingController();

  RemoteFetcher get _fetcher => widget.fetcher ?? HttpRemoteFetcher();

  @override
  void initState() {
    super.initState();
    if (widget.store != null) {
      _store = widget.store;
      _loadPaired();
    } else {
      PrefsDevicesStore.load().then((store) {
        if (!mounted) return;
        setState(() => _store = store);
        _loadPaired();
      });
    }
  }

  Future<void> _loadPaired() async {
    final store = _store;
    if (store == null) return;
    final label = await store.getDeviceLabel();
    final paired = await store.getPairedDevices();
    if (!mounted) return;
    setState(() {
      if (label != null && label.isNotEmpty) _ownLabel = label;
      _ownLabelController.text = _ownLabel;
      _paired = paired;
      for (final device in paired) {
        _pollers.putIfAbsent(device.id, () => RemoteDevicePoller(device));
      }
    });
    await _pollAll();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollAll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    final host = _host;
    if (host != null) unawaited(host.stop());
    _ownLabelController.dispose();
    _payloadController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _pinController.dispose();
    _joinLabelController.dispose();
    super.dispose();
  }

  Future<void> _pollAll() async {
    for (final device in _paired) {
      final poller = _pollers.putIfAbsent(
        device.id,
        () => RemoteDevicePoller(device),
      );
      final view = await poller.poll(_fetcher, DateTime.now());
      if (!mounted) return;
      setState(() => _views[device.id] = view);
    }
  }

  Future<void> _startHosting() async {
    setState(() {
      _hostStarting = true;
      _hostError = null;
    });
    try {
      final server = LanHostServer(
        snapshotProvider: widget.getLocalSnapshot,
        todayProvider: widget.getTodayTotal,
        deviceLabel: _ownLabel,
      );
      await server.start();
      if (!mounted) {
        await server.stop();
        return;
      }
      setState(() {
        _host = server;
        _hostStarting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hostError = e.toString();
        _hostStarting = false;
      });
    }
  }

  Future<void> _stopHosting() async {
    final server = _host;
    setState(() => _host = null);
    await server?.stop();
  }

  Future<void> _saveOwnLabel() async {
    final store = _store;
    if (store == null) return;
    final label = _ownLabelController.text.trim();
    if (label.isEmpty) return;
    await store.setDeviceLabel(label);
    if (!mounted) return;
    setState(() => _ownLabel = label);
  }

  Future<void> _join() async {
    final store = _store;
    if (store == null) {
      setState(() => _joinError = 'Devices storage is still loading. Try again in a moment.');
      return;
    }
    var host = _hostController.text.trim();
    var port = int.tryParse(_portController.text.trim());
    var pin = _pinController.text.trim();
    var label = _joinLabelController.text.trim();
    final payloadText = _payloadController.text.trim();
    if (payloadText.isNotEmpty) {
      try {
        final payload = PairingPayload.parse(payloadText);
        host = payload.host;
        port = payload.port;
        pin = payload.pin;
        if (label.isEmpty) label = payload.label;
      } catch (e) {
        setState(() => _joinError = e.toString());
        return;
      }
    }
    if (host.isEmpty || port == null || pin.isEmpty) {
      setState(() => _joinError = 'Enter host, port, and PIN — or paste a full pairing code.');
      return;
    }
    setState(() => _joinError = '');
    try {
      final token = await _fetcher.pair(host: host, port: port, pin: pin);
      final device = PairedDevice(
        id: '$host:$port',
        label: label.isEmpty ? host : label,
        host: host,
        port: port,
        token: token,
      );
      await store.savePairedDevice(device);
      if (!mounted) return;
      setState(() {
        _paired = [
          for (final d in _paired)
            if (d.id != device.id) d,
          device,
        ];
        _pollers[device.id] = RemoteDevicePoller(device);
        _showJoin = false;
        _joinError = '';
      });
      await _pollAll();
    } catch (e) {
      if (mounted) setState(() => _joinError = e.toString());
    }
  }

  Future<void> _forget(PairedDevice device) async {
    await _store?.removePairedDevice(device.id);
    if (!mounted) return;
    setState(() {
      _paired = [for (final d in _paired) if (d.id != device.id) d];
      _pollers.remove(device.id);
      _views.remove(device.id);
    });
  }

  Future<void> _rename(PairedDevice device) async {
    final controller = TextEditingController(text: device.label);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Device name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    final renamed = device.renamed(result);
    await _store?.savePairedDevice(renamed);
    if (!mounted) return;
    setState(() {
      _paired = [
        for (final d in _paired) d.id == device.id ? renamed : d,
      ];
    });
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (_store == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final host = _host;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This device',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Your own name for this device, shown to devices you '
                  'pair with. It is just a label — change it freely.',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ownLabelController,
                        decoration: const InputDecoration(
                          labelText: 'Device name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saveOwnLabel,
                      child: const Text('Save'),
                    ),
                  ],
                ),
                if (host != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Restart hosting after renaming for guests to see '
                      'the new name.',
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (host != null) ...[
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Hosting — other devices can pair',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  Text('Endpoint: ${host.endpoint}'),
                  const SizedBox(height: 12),
                  Center(
                    // White backing: the QR code must stay scannable
                    // on the dark glass card (Phase 5 theme change).
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(
                        data: host.pairingPayload,
                        version: QrVersions.auto,
                        size: 200,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'PIN: ${host.pin}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 24,
                    ),
                  ),
                  Text(
                    'PIN expires around ${_formatTime(host.pinExpiresAt)} '
                    '(2 minutes, single use). Show this screen to the '
                    'other device, or copy the code below.',
                  ),
                  const SizedBox(height: 8),
                  SelectableText(host.pairingPayload),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: host.pairingPayload),
                        ),
                        child: const Text('Copy pairing code'),
                      ),
                      OutlinedButton(
                        onPressed: () => setState(host.regeneratePin),
                        child: const Text('New PIN'),
                      ),
                      TextButton(
                        onPressed: _stopHosting,
                        child: const Text('Stop hosting & revoke'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Stopping hosting revokes every guest token at once. '
                    'Sharing is LAN + token only — there is no TLS in '
                    'Phase 4, so do not pair on untrusted or public '
                    'Wi-Fi. Shared: totals + per-app bytes only. Never '
                    'shared: traffic content, URLs, hosts, DNS, '
                    'browsing history, or connection details.',
                  ),
                ],
              ),
            ),
          ),
        ] else ...[
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Share this device on your LAN',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Start hosting and the other device can pair with '
                    'the PIN above. Hosting runs only while this app '
                    'stays open on this tab.',
                  ),
                  if (_hostError != null) ...[
                    const SizedBox(height: 8),
                    Text(_hostError!),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _hostStarting ? null : _startHosting,
                    child: Text(_hostStarting ? 'Starting…' : 'Host this device'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (_paired.isEmpty && host == null)
          const GlassCard(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No paired devices yet',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Pair a phone and a laptop on the same trusted Wi-Fi '
                    'to see both totals side by side. Host on one '
                    'device, join from the other. Nothing is shared '
                    'with any cloud, and either side can stop at any '
                    'time.',
                  ),
                ],
              ),
            ),
          ),
        for (final device in _paired) _RemoteDeviceCard(
          device: device,
          view: _views[device.id],
          poller: _pollers[device.id],
          formatTime: _formatTime,
          onForget: () => _forget(device),
          onRename: () => _rename(device),
        ),
        const SizedBox(height: 12),
        if (!_showJoin)
          OutlinedButton(
            onPressed: () => setState(() => _showJoin = true),
            child: const Text('Join a device'),
          )
        else
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Join a device',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Phase 4 has no camera scan: paste the host\'s full '
                    'pairing code, or enter host, port, and PIN '
                    'manually. This works on Windows too, with no '
                    'camera needed.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _payloadController,
                    decoration: const InputDecoration(
                      labelText: 'Pairing code (paste, optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: 'Host IP (e.g. 192.168.1.10)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _pinController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'PIN',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _joinLabelController,
                    decoration: const InputDecoration(
                      labelText: 'Name for this device (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_joinError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_joinError),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _join,
                        child: const Text('Pair'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => setState(() {
                          _showJoin = false;
                          _joinError = '';
                        }),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _RemoteDeviceCard extends StatelessWidget {
  const _RemoteDeviceCard({
    required this.device,
    required this.view,
    required this.poller,
    required this.formatTime,
    required this.onForget,
    required this.onRename,
  });

  final PairedDevice device;
  final LiveUsage? view;
  final RemoteDevicePoller? poller;
  final String Function(DateTime) formatTime;
  final VoidCallback onForget;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final status = poller?.statusAt(DateTime.now()) ?? 'Offline';
    final snapshot = view?.snapshot;
    final latest = poller?.latest;
    final topApps = snapshot == null
        ? const <AppUsage>[]
        : ([...snapshot.apps]
          ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes))).take(5).toList();
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    device.label,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                Text(status),
              ],
            ),
            if (status != 'Online') ...[
              const SizedBox(height: 4),
              Text(
                poller?.lastSeen == null
                    ? 'Never reached. Check the host is open and on the same Wi-Fi.'
                    : 'Last seen ${_formatTimeSafe(poller!.lastSeen!)}. Rates are paused, not live.',
              ),
            ],
            if (snapshot != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _Stat(
                      label: 'Download rate',
                      value: formatRate(view?.rxBytesPerSecond ?? 0),
                    ),
                  ),
                  Expanded(
                    child: _Stat(
                      label: 'Upload rate',
                      value: formatRate(view?.txBytesPerSecond ?? 0),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _StatRow(
                label: 'Device totals (since boot / collector start)',
                value: formatBytes(snapshot.totalBytes),
              ),
              _StatRow(
                label: 'Today (recorded on that device)',
                value: latest?.todayRxBytes == null || latest?.todayTxBytes == null
                    ? '—'
                    : formatBytes(latest!.todayRxBytes! + latest.todayTxBytes!),
              ),
              const SizedBox(height: 8),
              const Text('Top apps', style: TextStyle(fontWeight: FontWeight.bold)),
              if (topApps.isEmpty)
                const Text('No per-app data from this device yet.')
              else
                for (final app in topApps)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(app.name.isEmpty ? app.id : app.name),
                    trailing: Text(formatBytes(app.totalBytes)),
                  ),
            ] else ...[
              const SizedBox(height: 8),
              const Text('Waiting for the first poll from this device…'),
            ],
            if (poller?.lastError != null && status != 'Online') ...[
              const SizedBox(height: 4),
              Text(poller!.lastError!),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(onPressed: onRename, child: const Text('Rename')),
                TextButton(onPressed: onForget, child: const Text('Forget')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimeSafe(DateTime t) => formatTime(t);
}

class _HistoryTotalsCard extends StatelessWidget {
  const _HistoryTotalsCard({required this.summary});

  final HistorySummary summary;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatRow(
              label: 'Today (recorded)',
              value: formatBytes(summary.today.totalBytes),
            ),
            _StatRow(
              label: 'Yesterday (recorded)',
              value: formatBytes(summary.yesterday.totalBytes),
            ),
            _StatRow(
              label: 'Last 7 days (recorded)',
              value: formatBytes(summary.last7Days.totalBytes),
            ),
            _StatRow(
              label: 'Recorded by',
              value: switch (summary.today.source) {
                'vpn' => 'VPN live mode',
                'mixed' => 'Polling + VPN live (mixed day)',
                _ => 'Polling',
              },
            ),
            if (summary.biggestUserToday != null)
              _StatRow(
                label: 'Biggest user today',
                value:
                    '${summary.biggestUserToday!.appName} — '
                    '${formatBytes(summary.biggestUserToday!.totalBytes)}',
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryPerAppCard extends StatelessWidget {
  const _HistoryPerAppCard({required this.summary});

  final HistorySummary summary;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Per app — today (recorded)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            if (summary.perAppToday.isEmpty)
              const Text('No recorded per-app usage today yet.')
            else
              for (final app in summary.perAppToday)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(app.appName.isEmpty ? app.appId : app.appName),
                  subtitle: Text(
                    '↓ ${formatBytes(app.rxBytes)}  '
                    '↑ ${formatBytes(app.txBytes)}',
                  ),
                  trailing: Text(formatBytes(app.totalBytes)),
                ),
          ],
        ),
      ),
    );
  }
}

class _BudgetCard extends StatefulWidget {
  const _BudgetCard({
    required this.budgetStore,
    required this.capController,
  });

  final BudgetStore? budgetStore;
  final TextEditingController capController;

  @override
  State<_BudgetCard> createState() => _BudgetCardState();
}

class _BudgetCardState extends State<_BudgetCard> {
  @override
  Widget build(BuildContext context) {
    final store = widget.budgetStore;
    if (store == null) {
      return const GlassCard(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Daily cap settings are unavailable here.'),
        ),
      );
    }
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Daily data cap',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              'Local only. When today\'s recorded total reaches the cap, '
              'the Live tab shows a banner. MyMy never blocks or limits '
              'any app.',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.capController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Cap (MB per day)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final mb =
                        double.tryParse(widget.capController.text.trim());
                    await store.setCapMb(mb);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            mb == null
                                ? 'Daily cap cleared.'
                                : 'Daily cap set to ${mb.toStringAsFixed(0)} MB.',
                          ),
                        ),
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    await store.setCapMb(null);
                    widget.capController.clear();
                  },
                  child: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BackgroundCard extends StatelessWidget {
  const _BackgroundCard({
    required this.backgroundSource,
    required this.backgroundOn,
    required this.mergedCount,
    required this.merging,
    required this.onToggle,
    required this.onMerge,
  });

  final BackgroundSamplingSource? backgroundSource;
  final bool backgroundOn;
  final int mergedCount;
  final bool merging;
  final ValueChanged<bool> onToggle;
  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context) {
    if (backgroundSource == null) {
      return const GlassCard(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Background sampling is Android only (foreground service). '
            'On other platforms, history records only while the app '
            'is open.',
          ),
        ),
      );
    }
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Background sampling (Android)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              'While on, a foreground service with an ongoing '
              'notification samples once per minute and stores raw '
              'samples. They merge into history when you reopen the '
              'app (or tap Merge now) — never twice for one interval. '
              'If the switch does not stay on, grant notifications in '
              'system settings and try again.',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sample in background'),
              value: backgroundOn,
              onChanged: onToggle,
            ),
            Row(
              children: [
                TextButton(
                  onPressed: merging ? null : onMerge,
                  child: Text(merging ? 'Merging…' : 'Merge now'),
                ),
                const SizedBox(width: 8),
                if (mergedCount > 0)
                  Text('Last merge: $mergedCount samples'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Usage access needed for per-app totals',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Device totals still show below, but per-app breakdowns need '
              'usage access. Grant it in Settings, then come back here.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onOpenSettings,
              child: const Text('Open usage settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveRateCard extends StatelessWidget {
  const _LiveRateCard({required this.live});

  final LiveUsage live;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Live now',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Stat(
                    label: 'Download',
                    value: formatRate(live.rxBytesPerSecond),
                  ),
                ),
                Expanded(
                  child: _Stat(
                    label: 'Upload',
                    value: formatRate(live.txBytesPerSecond),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.snapshot});

  final UsageSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Totals (device counters)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              'Counters reset on reboot (Android) or adapter restart '
              '(Windows). Recorded history lives on the History tab.',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Stat(
                    label: 'Downloaded',
                    value: formatBytes(snapshot.totalRxBytes),
                  ),
                ),
                Expanded(
                  child: _Stat(
                    label: 'Uploaded',
                    value: formatBytes(snapshot.totalTxBytes),
                  ),
                ),
                Expanded(
                  child: _Stat(
                    label: 'Total',
                    value: formatBytes(snapshot.totalBytes),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NetworkSplitCard extends StatelessWidget {
  const _NetworkSplitCard({required this.snapshot});

  final UsageSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final mobile = snapshot.mobileRxBytes + snapshot.mobileTxBytes;
    final wifi = snapshot.totalBytes - mobile;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Mobile vs Wi-Fi (since boot)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Stat(label: 'Mobile data', value: formatBytes(mobile)),
                ),
                Expanded(
                  child: _Stat(
                    label: 'Wi-Fi / other',
                    value: formatBytes(wifi < 0 ? 0 : wifi),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AllAppsCard extends StatefulWidget {
  const _AllAppsCard({
    required this.live,
    required this.installed,
    required this.activity,
    required this.isAndroidEngine,
    required this.loadIcon,
    required this.iconCache,
  });

  final LiveUsage live;
  final List<InstalledApp> installed;
  final Map<String, AppActivity> activity;
  final bool isAndroidEngine;
  final Future<Uint8List?> Function(String packageName) loadIcon;
  final Map<String, Uint8List?> iconCache;

  @override
  State<_AllAppsCard> createState() => _AllAppsCardState();
}

class _AllAppsCardState extends State<_AllAppsCard> {
  AppListFilter _filter = AppListFilter.all;

  @override
  Widget build(BuildContext context) {
    final rates = <String, double>{};
    for (final entry in widget.live.appRates.entries) {
      rates[entry.key] =
          entry.value.rxPerSecond + entry.value.txPerSecond;
    }
    final merged = sortApps(
      filterApps(
        attachActivity(
          mergeApps(
            installed: widget.installed,
            stats: widget.live.snapshot.apps,
            rates: rates,
          ),
          widget.activity,
        ),
        _filter,
      ),
    );
    final hasInstalledList = widget.installed.isNotEmpty;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'All apps',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.isAndroidEngine
                  ? (hasInstalledList
                      ? 'Every installed app, including system apps. '
                          'Apps with no data today show 0 / "No data '
                          'today" — never hidden, never given fake '
                          'bytes. Sorted by current rate, then total.'
                      : 'Installed-apps list unavailable here — '
                          'showing data users only. Grant usage '
                          'access and reopen to load the full list.')
                  : 'Processes seen by the collector (Windows) — '
                      'not an installed-apps list, and no icons. '
                      'Totals cover tracked TCP connections since '
                      'the collector started.',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in const [
                  (AppListFilter.all, 'All'),
                  (AppListFilter.dataUsers, 'Data users only'),
                  (AppListFilter.system, 'System'),
                  (AppListFilter.userApps, 'User apps'),
                ])
                  ChoiceChip(
                    label: Text(entry.$2),
                    selected: _filter == entry.$1,
                    onSelected: (_) =>
                        setState(() => _filter = entry.$1),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (merged.isEmpty)
              const Text(
                'Nothing matches this filter yet.',
                style: TextStyle(color: Colors.white70),
              )
            else
              for (final app in merged)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: widget.isAndroidEngine
                      ? _AppIcon(
                          packageName: app.id,
                          fallbackLetter: app.name.isEmpty
                              ? '?'
                              : app.name[0].toUpperCase(),
                          loadIcon: widget.loadIcon,
                          iconCache: widget.iconCache,
                        )
                      : null,
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          app.name,
                          style: const TextStyle(color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (app.isSystem)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: _Badge(text: 'SYSTEM'),
                        ),
                      if (!app.enabled)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: _Badge(text: 'DISABLED'),
                        ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.hasDataToday
                            ? '↓ ${formatBytes(app.rxBytes)}  '
                                '↑ ${formatBytes(app.txBytes)}'
                            : 'No data today',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      Text(
                        '${activityBadge(app, now: DateTime.now())}'
                        '${app.activity != null && app.activity!.foregroundSeconds > 0 ? ' · ${(app.activity!.foregroundSeconds / 60).toStringAsFixed(0)} min foreground today' : ''}'
                        '${app.activity != null && app.activity!.features.isNotEmpty ? ' · ${app.activity!.features.join(', ')}' : ''}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                  trailing: Text(
                    formatRate(app.rateBytesPerSecond),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: glassGold.withOpacity(0.25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: glassGold.withOpacity(0.5)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// One app icon, loaded lazily for visible rows only. While loading
/// (or when the native side has no icon) a letter placeholder shows,
/// so the list never blocks on hundreds of icons.
class _AppIcon extends StatefulWidget {
  const _AppIcon({
    required this.packageName,
    required this.fallbackLetter,
    required this.loadIcon,
    required this.iconCache,
  });

  final String packageName;
  final String fallbackLetter;
  final Future<Uint8List?> Function(String packageName) loadIcon;
  final Map<String, Uint8List?> iconCache;

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  @override
  void initState() {
    super.initState();
    if (!widget.iconCache.containsKey(widget.packageName)) {
      widget.loadIcon(widget.packageName);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.iconCache[widget.packageName];
    if (bytes != null && bytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(bytes, width: 40, height: 40),
      );
    }
    return CircleAvatar(
      radius: 20,
      backgroundColor: glassIndigo,
      foregroundColor: Colors.white,
      child: Text(widget.fallbackLetter),
    );
  }
}

class _ConnectionsCard extends StatelessWidget {
  const _ConnectionsCard({required this.snapshot});

  final UsageSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Active connections',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            for (final c in snapshot.connections)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.processName),
                subtitle: Text(c.remote),
                trailing: Text('PID ${c.pid}'),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ],
    );
  }
}

/// No-op VPN source used when the platform channel has no VPN
/// handler (Windows, tests without injection). Every call degrades
/// to inactive/error, so VPN mode can never silently claim to run.
class _NoopVpnLiveSource implements VpnLiveSource {
  @override
  Future<String> prepareVpn() async => 'error';
  @override
  Future<bool> startVpnLive() async => false;
  @override
  Future<bool> stopVpnLive() async => false;
  @override
  Future<bool> isVpnLive() async => false;
  @override
  Future<VpnStatus> getVpnStatus() async => VpnStatus.inactive;
  @override
  Future<UsageSnapshot> getVpnSnapshot() async {
    throw StateError('VPN live mode is not available on this platform');
  }
}

class _ReconciliationCard extends StatelessWidget {
  const _ReconciliationCard({required this.result});

  final ReconciliationResult result;

  @override
  Widget build(BuildContext context) {
    final isMismatch = result.status == 'mismatch';
    return GlassCard(
      color: isMismatch
          ? Theme.of(context).colorScheme.errorContainer
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.status == 'match'
                  ? 'Reconciled with system totals'
                  : result.status == 'mismatch'
                      ? 'VPN totals differ from system totals'
                      : 'Reconciliation unavailable',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (result.status != 'unavailable') ...[
              Text('VPN counted: ${formatBytes(result.vpnTotalBytes)}'),
              Text(
                'System delta this session: '
                '${formatBytes(result.systemDeltaBytes)}',
              ),
              Text('Difference: ${formatBytes(result.differenceBytes)}'),
              const SizedBox(height: 8),
            ],
            Text(result.message),
          ],
        ),
      ),
    );
  }
}
