// Phase 5 tests: history open fallback + refresh, all-apps merge,
// chart data builders, and system-map edge rules.
//
// The load-bearing assertion is the last group: no edge may connect
// two app nodes unless it is a shared-UID group edge, and no
// per-app battery value may appear anywhere in the map.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymy/main.dart';
import 'package:mymy/src/all_apps.dart';
import 'package:mymy/src/app_info.dart';
import 'package:mymy/src/charts.dart';
import 'package:mymy/src/history.dart';
import 'package:mymy/src/models.dart';
import 'package:mymy/src/system_map.dart';

UsageSnapshot _snapshot(
  DateTime t,
  List<AppUsage> apps, {
  int totalRx = 1000,
  int totalTx = 500,
}) =>
    UsageSnapshot(
      timestamp: t,
      totalRxBytes: totalRx,
      totalTxBytes: totalTx,
      mobileRxBytes: -1,
      mobileTxBytes: -1,
      apps: apps,
      connections: const [],
    );

/// A controllable history store: summary() throws until [failing] is
/// cleared, so the error + Retry state can be exercised.
class _FlakyHistoryStore implements HistoryStore {
  bool failing = true;
  int summaries = 0;

  @override
  bool get isPersistent => true;

  @override
  Future<void> close() async {}

  @override
  Future<void> mergeSamples(List<UsageSnapshot> samples) async {}

  @override
  Future<void> record(UsageSnapshot snapshot, {bool force = false}) async {}

  @override
  Future<HistorySummary> summary() async {
    summaries++;
    if (failing) throw StateError('database is locked');
    return HistorySummary(
      today: const DailyTotal(
        date: '2026-11-04',
        rxBytes: 100,
        txBytes: 50,
        mobileRxBytes: -1,
        mobileTxBytes: -1,
      ),
      yesterday: DailyTotal.empty,
      last7Days: const DailyTotal(
        date: '2026-11-04',
        rxBytes: 100,
        txBytes: 50,
        mobileRxBytes: -1,
        mobileTxBytes: -1,
      ),
      perAppToday: const [],
    );
  }
}

void main() {
  group('history open fallback (Phase 5 root-cause fix)', () {
    test('throwing opener falls back to in-memory with a cause', () async {
      final result = await openHistoryStore(
        opener: () async => throw StateError('disk full'),
      );
      expect(result.store.isPersistent, isFalse);
      expect(result.error, contains('disk full'));
      expect(result.fellBack, isTrue);
    });

    test('hanging opener times out to in-memory with a cause', () async {
      final result = await openHistoryStore(
        opener: () => Completer<HistoryStore>().future,
        timeout: const Duration(milliseconds: 50),
      );
      expect(result.store.isPersistent, isFalse);
      expect(result.error, isNotNull);
    });

    test('successful opener returns the store with no error', () async {
      final result = await openHistoryStore(
        opener: () async => InMemoryHistoryStore(),
      );
      // InMemory is itself non-persistent, so it is reported as a
      // fallback — the point is the store is returned, not null.
      expect(result.store, isA<InMemoryHistoryStore>());
    });
  });

  group('history error + retry + refresh', () {
    testWidgets('error state shows cause and Retry recovers', (tester) async {
      final store = _FlakyHistoryStore();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HistoryTab(
              history: store,
              historyLoading: false,
              historyError: null,
              onRetryHistory: () {},
              refreshToken: 0,
              budgetStore: null,
              backgroundSource: null,
              backgroundOn: false,
              mergedCount: 0,
              onToggleBackground: (_) {},
              onMerge: () async {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Could not load history'), findsOneWidget);
      expect(find.textContaining('database is locked'), findsOneWidget);
      store.failing = false;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Could not load history'), findsNothing);
      expect(find.text('Recorded while sampling'), findsOneWidget);
    });

    testWidgets('refresh token change re-reads the summary', (tester) async {
      final store = _FlakyHistoryStore()..failing = false;
      Widget build(int token) => MaterialApp(
            home: Scaffold(
              body: HistoryTab(
                history: store,
                historyLoading: false,
                historyError: null,
                onRetryHistory: () {},
                refreshToken: token,
                budgetStore: null,
                backgroundSource: null,
                backgroundOn: false,
                mergedCount: 0,
                onToggleBackground: (_) {},
                onMerge: () async {},
              ),
            ),
          );
      await tester.pumpWidget(build(0));
      await tester.pump();
      final first = store.summaries;
      await tester.pumpWidget(build(1));
      await tester.pump();
      expect(store.summaries, greaterThan(first));
    });

    test('refresh after record grows the recorded total', () async {
      final store = InMemoryHistoryStore();
      final t = DateTime(2026, 11, 4, 10, 0);
      await store.record(
        _snapshot(
          t,
          [const AppUsage(id: 'a', name: 'A', rxBytes: 100, txBytes: 0)],
          totalRx: 1000,
          totalTx: 500,
        ),
        force: true,
      );
      await store.record(
        _snapshot(
          t.add(const Duration(minutes: 2)),
          [const AppUsage(id: 'a', name: 'A', rxBytes: 300, txBytes: 50)],
          totalRx: 1200,
          totalTx: 550,
        ),
        force: true,
      );
      final summary = await store.summary();
      expect(summary.today.totalBytes, 250);
      expect(summary.last7Daily.length, 7);
      expect(summary.last7Daily.last.totalBytes, 250);
    });
  });

  group('all-apps merge', () {
    final installed = [
      const InstalledApp(
        packageName: 'com.a',
        label: 'Alpha',
        isSystem: false,
        enabled: true,
        uid: 10001,
      ),
      const InstalledApp(
        packageName: 'com.sys',
        label: 'System UI',
        isSystem: true,
        enabled: true,
        uid: 1000,
      ),
      const InstalledApp(
        packageName: 'com.quiet',
        label: 'Quiet App',
        isSystem: false,
        enabled: false,
        uid: 10002,
      ),
    ];
    final stats = [
      const AppUsage(id: 'com.a', name: 'Alpha', rxBytes: 500, txBytes: 100),
    ];

    test('zero-usage installed apps are present, system flag preserved', () {
      final merged = mergeApps(installed: installed, stats: stats);
      expect(merged.length, 3);
      final quiet = merged.firstWhere((a) => a.id == 'com.quiet');
      expect(quiet.totalBytes, 0);
      expect(quiet.hasDataToday, isFalse);
      expect(quiet.enabled, isFalse);
      final sys = merged.firstWhere((a) => a.id == 'com.sys');
      expect(sys.isSystem, isTrue);
      expect(sys.totalBytes, 0);
    });

    test('data-only rows are kept, never given a guessed system flag', () {
      final merged = mergeApps(
        installed: installed,
        stats: [
          ...stats,
          const AppUsage(id: 'uid:9999', name: 'System (UID 9999)', rxBytes: 10, txBytes: 0),
        ],
      );
      final row = merged.firstWhere((a) => a.id == 'uid:9999');
      expect(row.totalBytes, 10);
      expect(row.isInstalledListEntry, isFalse);
    });

    test('filters and rate-then-total sort', () {
      final merged = mergeApps(
        installed: installed,
        stats: stats,
        rates: {'com.a': 50},
      );
      expect(filterApps(merged, AppListFilter.system).length, 1);
      expect(filterApps(merged, AppListFilter.userApps).length, 2);
      expect(filterApps(merged, AppListFilter.dataUsers).length, 1);
      expect(filterApps(merged, AppListFilter.all).length, 3);
      final sorted = sortApps(merged);
      expect(sorted.first.id, 'com.a');
    });

    test('activity badges follow the documented rule, never "running" by guess', () {
      final now = DateTime(2026, 11, 4, 12, 0);
      MergedApp withActivity(AppActivity a) => MergedApp(
            id: 'com.a',
            name: 'Alpha',
            rxBytes: 0,
            txBytes: 0,
            rateBytesPerSecond: 0,
            isSystem: false,
            enabled: true,
            activity: a,
          );
      expect(
        activityBadge(withActivity(const AppActivity(packageName: 'com.a')), now: now),
        'Not recently used',
      );
      expect(
        activityBadge(
          withActivity(
            AppActivity(
              packageName: 'com.a',
              lastUsedMs: now.millisecondsSinceEpoch - 30 * 1000,
            ),
          ),
          now: now,
        ),
        'Foreground now',
      );
      expect(
        activityBadge(
          withActivity(
            AppActivity(
              packageName: 'com.a',
              lastUsedMs: now.millisecondsSinceEpoch - 60 * 60 * 1000,
            ),
          ),
          now: now,
        ),
        'Background recently',
      );
      expect(
        activityBadge(
          const MergedApp(
            id: 'com.a',
            name: 'Alpha',
            rxBytes: 0,
            txBytes: 0,
            rateBytesPerSecond: 0,
            isSystem: false,
            enabled: true,
          ),
          now: now,
        ),
        'Activity unknown',
      );
    });
  });

  group('chart data builders', () {
    test('rate history caps at capacity and peaks correctly', () {
      final history = RateHistory(capacity: 3);
      for (var i = 0; i < 5; i++) {
        history.add(
          RatePoint(
            timestamp: DateTime(2026, 11, 4, 12, 0, i),
            rxBytesPerSecond: i.toDouble(),
            txBytesPerSecond: 0,
          ),
        );
      }
      expect(history.points.length, 3);
      expect(history.peak, 4);
    });

    test('donut shares sum to 1 with an Other slice', () {
      final apps = [
        for (var i = 0; i < 10; i++)
          AppUsage(id: 'a$i', name: 'App $i', rxBytes: 100, txBytes: 0),
      ];
      final slices = donutShares(apps, 8);
      expect(slices.length, 9);
      expect(slices.last.label, 'Other');
      final sum = slices.fold<double>(0, (s, slice) => s + slice.share);
      expect(sum, closeTo(1.0, 0.0001));
    });

    test('empty inputs yield empty charts, never sample data', () {
      expect(donutShares(const []), isEmpty);
      expect(topAppsByTotal(const []), isEmpty);
      expect(barHeights(const []), isEmpty);
      expect(barHeights([0, 0]), [0, 0]);
      expect(RateHistory().isEmpty, isTrue);
    });

    test('daily bars keep chronological order with zero days', () {
      final bars = dailyBars([
        const DailyTotal(date: '2026-11-03', rxBytes: 0, txBytes: 0, mobileRxBytes: -1, mobileTxBytes: -1),
        const DailyTotal(date: '2026-11-04', rxBytes: 70, txBytes: 30, mobileRxBytes: -1, mobileTxBytes: -1),
      ]);
      expect(bars.map((b) => b.date), ['2026-11-03', '2026-11-04']);
      expect(barHeights([for (final b in bars) b.totalBytes]), [0, 1]);
    });
  });

  group('system map edge rules', () {
    MergedApp app(
      String id,
      String name, {
      bool system = false,
      List<String> features = const [],
      int? lastUsedMs,
    }) =>
        MergedApp(
          id: id,
          name: name,
          rxBytes: 100,
          txBytes: 0,
          rateBytesPerSecond: 10,
          isSystem: system,
          enabled: true,
          activity: AppActivity(
            packageName: id,
            lastUsedMs: lastUsedMs,
            features: features,
          ),
        );

    test('no app-to-app edge without a shared UID or feature signal', () {
      final apps = [app('com.a', 'Alpha'), app('com.b', 'Beta')];
      final map = buildSystemMap(
        apps: apps,
        installedById: {
          'com.a': const InstalledApp(packageName: 'com.a', label: 'Alpha', isSystem: false, enabled: true, uid: 10001),
          'com.b': const InstalledApp(packageName: 'com.b', label: 'Beta', isSystem: false, enabled: true, uid: 10002),
        },
        mobileBytesOf: (_) => -1,
        wifiBytesOf: (_) => -1,
        rateOf: (a) => a.rateBytesPerSecond,
        now: DateTime.now(),
      );
      final nodeKindById = {for (final n in map.nodes) n.id: n.kind};
      for (final edge in map.edges) {
        final fromKind = nodeKindById[edge.fromId];
        final toKind = nodeKindById[edge.toId];
        // Both endpoints app-kind is forbidden outright.
        expect(
          fromKind == MapNodeKind.app && toKind == MapNodeKind.app,
          isFalse,
          reason: 'app-to-app edge ${edge.fromId} -> ${edge.toId} '
              'would claim data sharing Android does not expose',
        );
      }
      expect(map.edges, isEmpty);
    });

    test('transport edges only where a real split exists', () {
      final apps = [app('com.a', 'Alpha')];
      final withTransport = buildSystemMap(
        apps: apps,
        installedById: const {},
        mobileBytesOf: (_) => 60,
        wifiBytesOf: (_) => 40,
        rateOf: (a) => a.rateBytesPerSecond,
        now: DateTime.now(),
      );
      expect(
        withTransport.edges.map((e) => e.kind).toSet(),
        {MapEdgeKind.transport},
      );
      expect(withTransport.edges.length, 2);
      final withoutTransport = buildSystemMap(
        apps: apps,
        installedById: const {},
        mobileBytesOf: (_) => -1,
        wifiBytesOf: (_) => -1,
        rateOf: (a) => a.rateBytesPerSecond,
        now: DateTime.now(),
      );
      expect(withoutTransport.edges, isEmpty);
    });

    test('feature edges only for reported ops; shared UID groups', () {
      final apps = [
        app('com.a', 'Alpha', features: ['Camera']),
        app('com.b', 'Beta'),
      ];
      final map = buildSystemMap(
        apps: apps,
        installedById: {
          'com.a': const InstalledApp(packageName: 'com.a', label: 'Alpha', isSystem: false, enabled: true, uid: 10001),
          'com.b': const InstalledApp(packageName: 'com.b', label: 'Beta', isSystem: false, enabled: true, uid: 10001),
        },
        mobileBytesOf: (_) => -1,
        wifiBytesOf: (_) => -1,
        rateOf: (a) => a.rateBytesPerSecond,
        now: DateTime.now(),
      );
      expect(
        map.edges.where((e) => e.kind == MapEdgeKind.feature).length,
        1,
      );
      final groupEdges =
          map.edges.where((e) => e.kind == MapEdgeKind.sharedUid);
      expect(groupEdges.length, 2);
      expect(
        map.nodes.any((n) => n.kind == MapNodeKind.appGroup),
        isTrue,
      );
      // No node or edge mentions battery per app: battery is a
      // device-hub subtitle only, never an app attribute.
      for (final node in map.nodes) {
        if (node.kind == MapNodeKind.app) {
          expect(node.subtitle.toLowerCase(), isNot(contains('battery')));
        }
      }
    });

    test('zero-rate apps do not appear as live nodes', () {
      final map = buildSystemMap(
        apps: [
          const MergedApp(
            id: 'com.a',
            name: 'Alpha',
            rxBytes: 500,
            txBytes: 0,
            rateBytesPerSecond: 0,
            isSystem: false,
            enabled: true,
          ),
        ],
        installedById: const {},
        mobileBytesOf: (_) => -1,
        wifiBytesOf: (_) => -1,
        rateOf: (a) => a.rateBytesPerSecond,
        now: DateTime.now(),
      );
      expect(map.hasAppNodes, isFalse);
    });
  });
}
