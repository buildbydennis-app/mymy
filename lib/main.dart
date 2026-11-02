import 'dart:async';

import 'package:flutter/material.dart';

import 'src/format.dart';
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

/// Live dashboard.
///
/// Polls [UsageService] once per second. Every number on screen comes from
/// a real snapshot counter or from a rate derived from two real snapshots.
/// If a snapshot fails (platform not implemented, permission missing), the
/// dashboard stops polling and says so — it never shows sample data as if
/// it were real usage.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, this.service});

  final UsageService? service;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final UsageService _service;
  UsageStatus? _status;
  LiveUsage? _live;
  String? _error;
  Timer? _timer;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? UsageService();
    _refreshStatusAndStart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatusAndStart() async {
    final status = await _service.getStatus();
    if (!mounted) return;
    setState(() {
      _status = status;
      _error = null;
    });
    // Only poll when a real engine is behind the source. The Android
    // permission case still polls: the native side returns device totals
    // via TrafficStats even without usage access, and per-app totals stay
    // empty until access is granted — the banner explains that.
    if (status.engine != 'unimplemented' &&
        status.engine != 'windows-phase2-pending') {
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
        setState(() {
          _live = live;
          _error = null;
        });
      } catch (e) {
        // A failed snapshot is a state to show, not a crash and not a
        // reason to keep hammering a broken source every second.
        _timer?.cancel();
        _polling = false;
        if (!mounted) return;
        setState(() => _error = e.toString());
      }
    });
  }

  Future<void> _openSettings() async {
    await _service.openUsageSettings();
    // The user may have just granted access; re-check on return.
    await _refreshStatusAndStart();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final live = _live;
    final snapshot = live?.snapshot;

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
      ),
      body: status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (status.engine == 'network-stats' &&
                    !status.hasPermission)
                  _PermissionBanner(onOpenSettings: _openSettings),
                if (status.engine == 'unimplemented' ||
                    status.engine == 'windows-phase2-pending')
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
                  if (snapshot.mobileRxBytes >= 0)
                    _NetworkSplitCard(snapshot: snapshot),
                  if (snapshot.mobileRxBytes >= 0)
                    const SizedBox(height: 12),
                  _PerAppCard(live: live),
                  if (snapshot.connections.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _ConnectionsCard(snapshot: snapshot),
                  ],
                ] else if (_error == null &&
                    status.engine != 'unimplemented' &&
                    status.engine != 'windows-phase2-pending')
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
              'Totals since device boot',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              'Counters reset on reboot. Daily / monthly history is Phase 2.',
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
              'Per app — today',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              'Sorted by current rate, then by total. Totals cover today '
              '(Android NetworkStatsManager window).',
            ),
            const SizedBox(height: 8),
            if (apps.isEmpty)
              const Text(
                'No per-app data yet. On Android, grant usage access above '
                'and keep the app open for a poll cycle.',
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
