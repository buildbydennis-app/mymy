import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mymy/src/background.dart';
import 'package:mymy/src/budget.dart';
import 'package:mymy/src/history.dart';
import 'package:mymy/src/models.dart';
import 'package:mymy/src/usage_service.dart';

UsageSnapshot snap({
  required DateTime at,
  required int totalRx,
  required int totalTx,
  int mobileRx = -1,
  int mobileTx = -1,
  List<AppUsage> apps = const [],
}) =>
    UsageSnapshot(
      timestamp: at,
      totalRxBytes: totalRx,
      totalTxBytes: totalTx,
      mobileRxBytes: mobileRx,
      mobileTxBytes: mobileTx,
      apps: apps,
      connections: const [],
    );

DateTime todayAt(int hour, int minute) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

class FakeBackgroundSource implements BackgroundSamplingSource {
  FakeBackgroundSource(this.lines);

  final List<String> lines;
  bool cleared = false;

  @override
  Future<bool> startBackgroundSampling() async => true;
  @override
  Future<bool> stopBackgroundSampling() async => true;
  @override
  Future<bool> isBackgroundSampling() async => true;
  @override
  Future<List<String>> getBackgroundSamples() async => lines;
  @override
  Future<void> clearBackgroundSamples() async => cleared = true;
}

String snapJson(UsageSnapshot s) => jsonEncode({
      'timestampMs': s.timestamp.millisecondsSinceEpoch,
      'totalRx': s.totalRxBytes,
      'totalTx': s.totalTxBytes,
      'mobileRx': s.mobileRxBytes,
      'mobileTx': s.mobileTxBytes,
      'apps': [
        for (final a in s.apps)
          {'id': a.id, 'name': a.name, 'rx': a.rxBytes, 'tx': a.txBytes},
      ],
      'connections': const [],
    });

void main() {
  group('InMemoryHistoryStore', () {
    test('records only positive deltas, never first-sample traffic', () async {
      final store = InMemoryHistoryStore();
      await store.record(
        snap(at: todayAt(10, 0), totalRx: 5000, totalTx: 3000),
        force: true,
      );
      await store.record(
        snap(at: todayAt(10, 1), totalRx: 6000, totalTx: 3500),
        force: true,
      );
      await store.record(
        snap(at: todayAt(10, 2), totalRx: 7500, totalTx: 4000),
        force: true,
      );
      final summary = await store.summary();
      // (6000-5000)+(7500-6000) = 2500; tx = 500+500 = 1000.
      expect(summary.today.rxBytes, 2500);
      expect(summary.today.txBytes, 1000);
      expect(summary.today.totalBytes, 3500);
    });

    test('per-app deltas follow the same rule', () async {
      final store = InMemoryHistoryStore();
      await store.record(
        snap(
          at: todayAt(10, 0),
          totalRx: 0,
          totalTx: 0,
          apps: const [
            AppUsage(id: 'com.a', name: 'A', rxBytes: 100, txBytes: 0),
          ],
        ),
        force: true,
      );
      await store.record(
        snap(
          at: todayAt(10, 1),
          totalRx: 1000,
          totalTx: 0,
          apps: const [
            AppUsage(id: 'com.a', name: 'A', rxBytes: 600, txBytes: 200),
          ],
        ),
        force: true,
      );
      final summary = await store.summary();
      expect(summary.perAppToday.single.appId, 'com.a');
      expect(summary.perAppToday.single.rxBytes, 500);
      expect(summary.perAppToday.single.txBytes, 200);
      expect(summary.biggestUserToday!.appName, 'A');
    });

    test('counter drop (reboot) contributes zero, never negative', () async {
      final store = InMemoryHistoryStore();
      await store.record(
        snap(at: todayAt(10, 0), totalRx: 9000, totalTx: 9000),
        force: true,
      );
      await store.record(
        snap(at: todayAt(10, 1), totalRx: 100, totalTx: 50),
        force: true,
      );
      final summary = await store.summary();
      expect(summary.today.rxBytes, 0);
      expect(summary.today.txBytes, 0);
    });

    test('unforced record is throttled to once per minute', () async {
      final store = InMemoryHistoryStore();
      await store.record(
        snap(at: todayAt(10, 0), totalRx: 0, totalTx: 0),
        force: true,
      );
      // Second call within the same minute, unforced: skipped.
      await store.record(snap(at: todayAt(10, 1), totalRx: 9999, totalTx: 1));
      var summary = await store.summary();
      expect(summary.today.totalBytes, 0);
      // Forced (app close): applied.
      await store.record(
        snap(at: todayAt(10, 1), totalRx: 9999, totalTx: 1),
        force: true,
      );
      summary = await store.summary();
      expect(summary.today.totalBytes, 10000);
    });

    test('mobile unavailable stays unavailable, not zero', () async {
      final store = InMemoryHistoryStore();
      await store.record(
        snap(at: todayAt(10, 0), totalRx: 0, totalTx: 0),
        force: true,
      );
      await store.record(
        snap(at: todayAt(10, 1), totalRx: 100, totalTx: 100),
        force: true,
      );
      final summary = await store.summary();
      expect(summary.today.mobileRxBytes, -1);
      expect(summary.today.mobileTxBytes, -1);
    });

    test('yesterday and last-7-days group by local date', () async {
      final store = InMemoryHistoryStore();
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final yDay = DateTime(yesterday.year, yesterday.month, yesterday.day, 10, 0);
      final yDayLater = yDay.add(const Duration(minutes: 1));
      await store.record(
        snap(at: yDay, totalRx: 0, totalTx: 0),
        force: true,
      );
      await store.record(
        snap(at: yDayLater, totalRx: 400, totalTx: 100),
        force: true,
      );
      await store.record(
        snap(at: todayAt(10, 0), totalRx: 10000, totalTx: 10000),
        force: true,
      );
      // Counter jump across midnight contributes zero (reset rule),
      // so yesterday stays 500 and today stays 0 in this store.
      final summary = await store.summary();
      expect(summary.yesterday.totalBytes, 500);
      expect(summary.last7Days.totalBytes, 500);
    });
  });

  group('background merge', () {
    test('merges in timestamp order and never double-counts', () async {
      final store = InMemoryHistoryStore();
      final s1 = snap(at: todayAt(10, 0), totalRx: 0, totalTx: 0);
      final s2 = snap(at: todayAt(10, 1), totalRx: 1000, totalTx: 0);
      final s3 = snap(at: todayAt(10, 2), totalRx: 3000, totalTx: 0);
      await store.record(s1, force: true);
      await store.record(s2, force: true);
      // Out of order, with duplicates: only s3 is newer than last.
      await store.mergeSamples([s3, s2, s1]);
      var summary = await store.summary();
      expect(summary.today.rxBytes, 3000); // 1000 (live) + 2000 (merged)
      // Merging the same samples again changes nothing.
      await store.mergeSamples([s1, s2, s3]);
      summary = await store.summary();
      expect(summary.today.rxBytes, 3000);
    });

    test('controller parses lines, merges, then clears', () async {
      final store = InMemoryHistoryStore();
      final s1 = snap(at: todayAt(10, 0), totalRx: 0, totalTx: 0);
      final s2 = snap(at: todayAt(10, 1), totalRx: 700, totalTx: 300);
      await store.record(s1, force: true);
      final source = FakeBackgroundSource([snapJson(s1), snapJson(s2), 'junk']);
      final controller = BackgroundSamplingController(
        source: source,
        history: store,
      );
      final count = await controller.mergePendingSamples();
      expect(count, 2);
      expect(source.cleared, isTrue);
      final summary = await store.summary();
      expect(summary.today.totalBytes, 1000);
    });
  });

  group('BudgetChecker', () {
    test('crosses at exactly the cap, not below, never without a cap', () {
      expect(BudgetChecker.crossed(1000000, 1000000), isTrue);
      expect(BudgetChecker.crossed(999999, 1000000), isFalse);
      expect(BudgetChecker.crossed(999999999, null), isFalse);
      expect(BudgetChecker.crossed(999999999, 0), isFalse);
      expect(BudgetChecker.capBytesFromMb(25), 25000000);
      expect(BudgetChecker.capBytesFromMb(null), isNull);
    });
  });

  group('Windows snapshot JSON', () {
    test('parses per-process apps and connections, mobile unavailable', () {
      final parsed = UsageSnapshot.fromJson({
        'timestampMs': 0,
        'totalRx': 123456,
        'totalTx': 65432,
        'mobileRx': -1,
        'mobileTx': -1,
        'apps': [
          {'id': 'chrome.exe:1234', 'name': 'chrome.exe', 'rx': 1000, 'tx': 500},
        ],
        'connections': [
          {'process': 'chrome.exe', 'pid': 1234, 'remote': '1.2.3.4:443'},
        ],
      });
      expect(parsed.apps.single.id, 'chrome.exe:1234');
      expect(parsed.mobileRxBytes, -1);
      expect(parsed.connections.single.remote, '1.2.3.4:443');
    });
  });
}
