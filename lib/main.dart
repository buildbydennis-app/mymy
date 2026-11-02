import 'dart:async';

import 'package:flutter/material.dart';

import 'src/background.dart';
import 'src/budget.dart';
import 'src/format.dart';
import 'src/history.dart';
import 'src/models.dart';
import 'src/usage_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyMy — Live Data Usage',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
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
  });

  final UsageService? service;

  /// Injected in tests; otherwise SQLite is opened (with an in-memory
  /// fallback if SQLite is unavailable).
  final HistoryStore? historyStore;
  final BackgroundSamplingSource? backgroundSource;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final UsageService _service;
  HistoryStore? _history;
  BudgetStore? _budgetStore;
  BackgroundSamplingSource? _backgroundSource;
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

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? UsageService();
    final source = _service.source;
    BackgroundSamplingSource? background = widget.backgroundSource;
    if (background == null && source is BackgroundSamplingSource) {
      background = source as BackgroundSamplingSource;
    }
    _backgroundSource = background;
    if (widget.historyStore != null) {
      _history = widget.historyStore;
    } else {
      SqliteHistoryStore.open().then((store) {
        if (!mounted) return;
        setState(() => _history = store);
        _maybeMergeBackground();
      });
    }
    _loadBudget();
    _refreshStatusAndStart();
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
        final live = await _service.poll();
        if (!mounted) return;
        _lastSnapshot = live.snapshot;
        await _history?.record(live.snapshot);
        setState(() {
          _live = live;
          _error = null;
        });
        await _refreshBudgetCheck(live.snapshot);
      } catch (e) {
        _timer?.cancel();
        _polling = false;
        if (!mounted) return;
        setState(() => _error = e.toString());
      }
    });
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

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('MyMy — Live Data Usage'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _refreshStatusAndStart,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Live'),
              Tab(text: 'History'),
            ],
          ),
        ),
        body: status == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _buildLiveTab(status),
                  HistoryTab(
                    history: _history,
                    budgetStore: _budgetStore,
                    backgroundSource: _backgroundSource,
                    backgroundOn: _backgroundOn,
                    mergedCount: _mergedCount,
                    onToggleBackground: _toggleBackground,
                    onMerge: () async {
                      _mergedOnce = false;
                      await _maybeMergeBackground();
                    },
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildLiveTab(UsageStatus status) {
    final live = _live;
    final snapshot = live?.snapshot;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (status.engine == 'network-stats' && !status.hasPermission)
          _PermissionBanner(onOpenSettings: _openSettings),
        if (status.engine == 'windows-ip-helper' && !status.hasPermission)
          const Card(
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
          Card(
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
          Card(
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
          Card(
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
          _TotalsCard(snapshot: snapshot),
          const SizedBox(height: 12),
          if (snapshot.mobileRxBytes >= 0) _NetworkSplitCard(snapshot: snapshot),
          if (snapshot.mobileRxBytes >= 0) const SizedBox(height: 12),
          _PerAppCard(live: live),
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
    required this.budgetStore,
    required this.backgroundSource,
    required this.backgroundOn,
    required this.mergedCount,
    required this.onToggleBackground,
    required this.onMerge,
  });

  final HistoryStore? history;
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
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!history.isPersistent)
          const Card(
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
              return Card(
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
                      FilledButton(
                        onPressed: () => setState(
                          () => _summaryFuture = history.summary(),
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
                        () => _summaryFuture = history.summary(),
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

class _HistoryTotalsCard extends StatelessWidget {
  const _HistoryTotalsCard({required this.summary});

  final HistorySummary summary;

  @override
  Widget build(BuildContext context) {
    return Card(
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
    return Card(
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
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Daily cap settings are unavailable here.'),
        ),
      );
    }
    return Card(
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
      return const Card(
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
    return Card(
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
    return Card(
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
    return Card(
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
    return Card(
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
    return Card(
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

class _PerAppCard extends StatelessWidget {
  const _PerAppCard({required this.live});

  final LiveUsage live;

  @override
  Widget build(BuildContext context) {
    final apps = [...live.snapshot.apps];
    apps.sort((a, b) {
      final rateA = _rateOf(a.id);
      final rateB = _rateOf(b.id);
      if (rateB != rateA) return rateB.compareTo(rateA);
      return b.totalBytes.compareTo(a.totalBytes);
    });
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Per app',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              'Sorted by current rate, then by total. On Android the '
              'totals cover today (NetworkStatsManager window); on '
              'Windows they cover tracked TCP connections since the '
              'collector started.',
            ),
            const SizedBox(height: 8),
            if (apps.isEmpty)
              const Text(
                'No per-app data yet. On Android, grant usage access '
                'above and keep the app open for a poll cycle. On '
                'Windows, run as administrator for per-process bytes.',
              )
            else
              for (final app in apps)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(app.name.isEmpty ? app.id : app.name),
                  subtitle: Text(
                    '↓ ${formatBytes(app.rxBytes)}  '
                    '↑ ${formatBytes(app.txBytes)}',
                  ),
                  trailing: Text(
                    formatRate(
                      _rateOf(app.id) +
                          (live.appRates[app.id]?.txPerSecond ?? 0),
                    ),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  double _rateOf(String id) {
    final r = live.appRates[id];
    if (r == null) return 0;
    return r.rxPerSecond + r.txPerSecond;
  }
}

class _ConnectionsCard extends StatelessWidget {
  const _ConnectionsCard({required this.snapshot});

  final UsageSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Card(
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
