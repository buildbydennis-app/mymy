import 'package:flutter_test/flutter_test.dart';
import 'package:mymy/src/history.dart';
import 'package:mymy/src/models.dart';
import 'package:mymy/src/usage_service.dart';
import 'package:mymy/src/vpn.dart';
import 'package:shared_preferences/shared_preferences.dart';

UsageSnapshot snap({
  required DateTime at,
  required int totalRx,
  required int totalTx,
  String source = 'polling',
  List<AppUsage> apps = const [],
}) =>
    UsageSnapshot(
      timestamp: at,
      totalRxBytes: totalRx,
      totalTxBytes: totalTx,
      mobileRxBytes: -1,
      mobileTxBytes: -1,
      apps: apps,
      connections: const [],
      source: source,
    );

DateTime todayAt(int hour, int minute) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

/// Controllable fake VPN source for state/flow tests (never a real
/// service). Lives in the test file, not in shipped code.
class FakeVpnLiveSource implements VpnLiveSource {
  FakeVpnLiveSource({
    this.prepareResult = 'ready',
    this.startResult = true,
    this.active = false,
    this.snapshot,
  });

  String prepareResult;
  bool startResult;
  bool active;
  UsageSnapshot? snapshot;
  bool stopped = false;

  @override
  Future<String> prepareVpn() async => prepareResult;
  @override
  Future<bool> startVpnLive() async {
    if (startResult) active = true;
    return startResult;
  }

  @override
  Future<bool> stopVpnLive() async {
    stopped = true;
    active = false;
    return true;
  }

  @override
  Future<bool> isVpnLive() async => active;
  @override
  Future<VpnStatus> getVpnStatus() async => VpnStatus(
        active: active,
        startedAtMs: active ? 123456 : null,
        error: '',
        totalRxBytes: snapshot?.totalRxBytes ?? 0,
        totalTxBytes: snapshot?.totalTxBytes ?? 0,
        unattributedRxBytes: 0,
        unattributedTxBytes: 0,
      );
  @override
  Future<UsageSnapshot> getVpnSnapshot() async {
    final s = snapshot;
    if (s == null) throw StateError('no VPN snapshot');
    return s;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VpnLiveState defaults and teardown', () {
    test('mode starts as polling, never VPN', () {
      final state = VpnLiveState();
      expect(state.mode, LiveMode.polling);
      expect(state.vpnActive, isFalse);
      expect(state.canStartVpn, isFalse); // no disclosure yet
    });

    test('disclosure gates start; stop clears everything', () {
      final state = VpnLiveState(disclosureAccepted: true);
      expect(state.canStartVpn, isTrue);
      state.markStarted(999);
      expect(state.mode, LiveMode.vpn);
      expect(state.vpnActive, isTrue);
      expect(state.startedAtMs, 999);
      state.markStopped(errorMessage: 'stopped');
      expect(state.mode, LiveMode.polling);
      expect(state.vpnActive, isFalse);
      expect(state.startedAtMs, isNull);
    });
  });

  group('VpnDisclosureStore', () {
    test('acceptance persists, default is not accepted', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await VpnDisclosureStore.load();
      expect(store.accepted, isFalse);
      await store.accept();
      final reloaded = await VpnDisclosureStore.load();
      expect(reloaded.accepted, isTrue);
      expect(reloaded.acceptedAtMs, isNotNull);
    });
  });

  group('Reconciliation', () {
    test('match within tolerance', () {
      final result = Reconciliation.check(
        vpnRxBytes: 6000000,
        vpnTxBytes: 4000000,
        netBaseline: snap(at: todayAt(10, 0), totalRx: 1000, totalTx: 1000),
        netNow: snap(at: todayAt(10, 5), totalRx: 1000 + 6500000, totalTx: 1000 + 4000000),
      );
      expect(result.status, 'match');
      expect(result.vpnTotalBytes, 10000000);
      expect(result.systemDeltaBytes, 10500000);
    });

    test('mismatch beyond tolerance warns with numbers', () {
      final result = Reconciliation.check(
        vpnRxBytes: 500000,
        vpnTxBytes: 500000,
        netBaseline: snap(at: todayAt(10, 0), totalRx: 0, totalTx: 0),
        netNow: snap(at: todayAt(10, 5), totalRx: 9000000, totalTx: 1000000),
      );
      expect(result.status, 'mismatch');
      expect(result.vpnTotalBytes, 1000000);
      expect(result.systemDeltaBytes, 10000000);
      expect(result.differenceBytes, 9000000);
      expect(result.message, contains('IPv6'));
    });

    test('missing baseline and counter reset are unavailable, not match', () {
      final noBaseline = Reconciliation.check(
        vpnRxBytes: 100,
        vpnTxBytes: 100,
        netBaseline: null,
        netNow: snap(at: todayAt(10, 5), totalRx: 100, totalTx: 100),
      );
      expect(noBaseline.status, 'unavailable');
      final reset = Reconciliation.check(
        vpnRxBytes: 100,
        vpnTxBytes: 100,
        netBaseline: snap(at: todayAt(10, 0), totalRx: 9000, totalTx: 9000),
        netNow: snap(at: todayAt(10, 5), totalRx: 100, totalTx: 100),
      );
      expect(reset.status, 'unavailable');
    });

    test('tolerance is 1MB floor or 25 percent, whichever is larger', () {
      expect(Reconciliation.toleranceFor(1000000), 1000000);
      expect(Reconciliation.toleranceFor(8000000), 2000000);
    });
  });

  group('VPN snapshot JSON', () {
    test('parses source vpn, unattributed app, mobile unavailable', () {
      final parsed = UsageSnapshot.fromJson({
        'timestampMs': 123,
        'totalRx': 5000,
        'totalTx': 3000,
        'mobileRx': -1,
        'mobileTx': -1,
        'source': 'vpn',
        'apps': [
          {'id': 'com.example.a', 'name': 'A', 'rx': 4000, 'tx': 2000},
          {
            'id': 'unattributed',
            'name': 'Unattributed (could not be mapped)',
            'rx': 1000,
            'tx': 1000,
          },
        ],
        'connections': const [],
      });
      expect(parsed.source, 'vpn');
      expect(parsed.apps.length, 2);
      expect(parsed.apps.last.id, 'unattributed');
      expect(parsed.mobileRxBytes, -1);
    });

    test('missing source defaults to polling, never vpn', () {
      final parsed = UsageSnapshot.fromJson({
        'timestampMs': 0,
        'totalRx': 1,
        'totalTx': 2,
        'apps': const [],
      });
      expect(parsed.source, 'polling');
    });
  });

  group('VpnPollingService', () {
    test('rates derive from VPN deltas with their own previous', () async {
      final source = FakeVpnLiveSource(
        snapshot: snap(
          at: todayAt(10, 0),
          totalRx: 0,
          totalTx: 0,
          source: 'vpn',
        ),
      );
      final service = VpnPollingService(source);
      final first = await service.poll();
      expect(first.rxBytesPerSecond, 0);
      source.snapshot = snap(
        at: todayAt(10, 0).add(const Duration(seconds: 2)),
        totalRx: 4000,
        totalTx: 2000,
        source: 'vpn',
      );
      final second = await service.poll();
      expect(second.rxBytesPerSecond, 2000);
      service.reset();
      final afterReset = await service.poll();
      expect(afterReset.rxBytesPerSecond, 0);
    });
  });

  group('History source separation', () {
    test('switching modes does not invent a delta; day is mixed', () async {
      final store = InMemoryHistoryStore();
      // Polling: baseline + 1000.
      await store.record(
        snap(at: todayAt(10, 0), totalRx: 10000, totalTx: 10000),
        force: true,
      );
      await store.record(
        snap(at: todayAt(10, 1), totalRx: 11000, totalTx: 10000),
        force: true,
      );
      // VPN: first sample is a baseline (its own counters, unrelated
      // to polling boot totals), second sample adds 500.
      await store.record(
        snap(
          at: todayAt(10, 2),
          totalRx: 0,
          totalTx: 0,
          source: 'vpn',
        ),
        force: true,
      );
      await store.record(
        snap(
          at: todayAt(10, 3),
          totalRx: 500,
          totalTx: 0,
          source: 'vpn',
        ),
        force: true,
      );
      final summary = await store.summary();
      expect(summary.today.totalBytes, 1500); // 1000 polling + 500 VPN
      expect(summary.today.source, 'mixed');
    });
  });
}
