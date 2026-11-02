import 'package:flutter_test/flutter_test.dart';
import 'package:mymy/src/format.dart';
import 'package:mymy/src/models.dart';
import 'package:mymy/src/usage_service.dart';

UsageSnapshot snapshot({
  required int atMs,
  required int totalRx,
  required int totalTx,
  List<AppUsage> apps = const [],
}) =>
    UsageSnapshot(
      timestamp: DateTime.fromMillisecondsSinceEpoch(atMs),
      totalRxBytes: totalRx,
      totalTxBytes: totalTx,
      mobileRxBytes: -1,
      mobileTxBytes: -1,
      apps: apps,
      connections: const [],
    );

void main() {
  group('UsageService.calculate', () {
    test('first snapshot has zero rates, never invented speeds', () {
      final current = snapshot(atMs: 1000, totalRx: 5000, totalTx: 3000);
      final live = UsageService.calculate(null, current);
      expect(live.rxBytesPerSecond, 0);
      expect(live.txBytesPerSecond, 0);
      expect(live.appRates, isEmpty);
    });

    test('rate is delta over elapsed seconds, per app too', () {
      final previous = snapshot(
        atMs: 0,
        totalRx: 1000,
        totalTx: 2000,
        apps: const [
          AppUsage(id: 'com.example.a', name: 'A', rxBytes: 100, txBytes: 0),
        ],
      );
      final current = snapshot(
        atMs: 2000,
        totalRx: 3000,
        totalTx: 4000,
        apps: const [
          AppUsage(id: 'com.example.a', name: 'A', rxBytes: 600, txBytes: 200),
        ],
      );
      final live = UsageService.calculate(previous, current);
      expect(live.rxBytesPerSecond, 1000); // (3000-1000)/2s
      expect(live.txBytesPerSecond, 1000); // (4000-2000)/2s
      expect(live.appRates['com.example.a']!.rxPerSecond, 250);
      expect(live.appRates['com.example.a']!.txPerSecond, 100);
    });

    test('counter reset (reboot) clamps to zero, never negative', () {
      final previous = snapshot(atMs: 0, totalRx: 9000, totalTx: 9000);
      final current = snapshot(atMs: 1000, totalRx: 100, totalTx: 50);
      final live = UsageService.calculate(previous, current);
      expect(live.rxBytesPerSecond, 0);
      expect(live.txBytesPerSecond, 0);
    });

    test('zero elapsed time gives zero rates, never infinity', () {
      final previous = snapshot(atMs: 1000, totalRx: 100, totalTx: 100);
      final current = snapshot(atMs: 1000, totalRx: 9999, totalTx: 9999);
      final live = UsageService.calculate(previous, current);
      expect(live.rxBytesPerSecond, 0);
      expect(live.txBytesPerSecond, 0);
    });

    test('apps that appear mid-stream get no rate until next poll', () {
      final previous = snapshot(atMs: 0, totalRx: 0, totalTx: 0);
      final current = snapshot(
        atMs: 1000,
        totalRx: 500,
        totalTx: 500,
        apps: const [
          AppUsage(id: 'com.example.new', name: 'New', rxBytes: 500, txBytes: 0),
        ],
      );
      final live = UsageService.calculate(previous, current);
      expect(live.appRates.containsKey('com.example.new'), isFalse);
    });
  });

  group('UsageService.poll with a fake source', () {
    test('second poll derives rates from the first snapshot', () async {
      final service = UsageService(
        source: FakeUsageDataSource([
          snapshot(atMs: 0, totalRx: 0, totalTx: 0),
          snapshot(atMs: 1000, totalRx: 2000, totalTx: 1000),
        ]),
      );
      final first = await service.poll();
      expect(first.rxBytesPerSecond, 0);
      final second = await service.poll();
      expect(second.rxBytesPerSecond, 2000);
      expect(second.txBytesPerSecond, 1000);
    });
  });

  group('formatBytes / formatRate', () {
    test('bytes use decimal units, as carriers bill', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1500), '1.50 KB');
      expect(formatBytes(1500000), '1.50 MB');
      expect(formatBytes(2500000000), '2.50 GB');
      expect(formatBytes(-1), '—');
    });

    test('rates', () {
      expect(formatRate(0), '0 B/s');
      expect(formatRate(1500), '1.50 KB/s');
    });
  });

  group('UsageSnapshot.fromJson', () {
    test('missing mobile fields mean unavailable, not zero', () {
      final parsed = UsageSnapshot.fromJson({
        'timestampMs': 0,
        'totalRx': 10,
        'totalTx': 20,
        'apps': [
          {'id': 'com.example.a', 'name': 'A', 'rx': 5, 'tx': 5},
        ],
      });
      expect(parsed.mobileRxBytes, -1);
      expect(parsed.mobileTxBytes, -1);
      expect(parsed.apps.single.id, 'com.example.a');
      expect(parsed.apps.single.totalBytes, 10);
    });
  });
}
