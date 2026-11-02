import 'package:flutter/services.dart';

import 'models.dart';

/// The only thing the UI ever talks to for usage data.
///
/// Implementations report *cumulative counters* (see models.dart). This
/// class turns successive snapshots into live rates, so no speed is ever
/// invented: a rate is always (new counter - old counter) / elapsed seconds.
abstract class UsageDataSource {
  Future<UsageStatus> getStatus();
  Future<void> openUsageSettings();
  Future<UsageSnapshot> getSnapshot();
}

/// Phase 3 VPN live mode channel methods.
///
/// Kept separate from [UsageDataSource] so fakes and non-Android
/// platforms are not forced to implement them. On a platform whose
/// native handler does not implement a method, the call degrades to
/// 'error' / false / inactive instead of crashing.
abstract class VpnLiveSource {
  /// 'ready' (consent already held, or just granted), 'denied' (user
  /// declined the system dialog), or 'error'.
  Future<String> prepareVpn();
  Future<bool> startVpnLive();
  Future<bool> stopVpnLive();
  Future<bool> isVpnLive();
  Future<VpnStatus> getVpnStatus();

  /// Cumulative VPN counters since the service started, as a
  /// [UsageSnapshot] with `source == 'vpn'`. Totals are sums of the
  /// per-app VPN counters (plus unattributed), NOT device boot
  /// counters — rates are still derived from deltas, so this is safe,
  /// but it must never be compared directly to a polling snapshot's
  /// boot totals. See Reconciliation in lib/src/vpn.dart.
  Future<UsageSnapshot> getVpnSnapshot();
}

/// Background sampling (Android foreground service) channel methods.
///
/// Kept separate from [UsageDataSource] so fakes and non-Android
/// platforms are not forced to implement them. On a platform whose
/// native handler does not implement a method, the call degrades to
/// false / empty instead of crashing.
abstract class BackgroundSamplingSource {
  Future<bool> startBackgroundSampling();
  Future<bool> stopBackgroundSampling();
  Future<bool> isBackgroundSampling();
  Future<List<String>> getBackgroundSamples();
  Future<void> clearBackgroundSamples();
}

/// The native platform-channel source.
///
/// Android: MainActivity.kt. Windows (Phase 2): the runner's native
/// collector in windows/runner/mymy_usage.cpp. Any other platform:
/// no handler, so [getStatus] reports 'unimplemented'.
class MethodChannelUsageDataSource
    implements UsageDataSource, BackgroundSamplingSource, VpnLiveSource {
  MethodChannelUsageDataSource({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('mymy/usage');

  final MethodChannel _channel;

  @override
  Future<UsageStatus> getStatus() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getStatus');
      if (raw == null) return _unimplementedStatus();
      return UsageStatus.fromJson(Map<String, dynamic>.from(raw));
    } on MissingPluginException {
      return _unimplementedStatus();
    } on PlatformException {
      return _unimplementedStatus();
    }
  }

  @override
  Future<void> openUsageSettings() async {
    try {
      await _channel.invokeMethod<void>('openUsageSettings');
    } on MissingPluginException {
      // Nothing to open on this platform; the UI shows the gap instead.
    } on PlatformException {
      // Same: never crash the dashboard because a settings page is missing.
    }
  }

  @override
  Future<UsageSnapshot> getSnapshot() async {
    final raw = await _channel.invokeMethod<Map>('getSnapshot');
    if (raw == null) {
      throw StateError('mymy/usage getSnapshot returned no data');
    }
    return UsageSnapshot.fromJson(Map<String, dynamic>.from(raw));
  }

  @override
  Future<bool> startBackgroundSampling() async {
    try {
      return await _channel.invokeMethod<bool>('startBackgroundSampling') ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> stopBackgroundSampling() async {
    try {
      return await _channel.invokeMethod<bool>('stopBackgroundSampling') ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isBackgroundSampling() async {
    try {
      return await _channel.invokeMethod<bool>('isBackgroundSampling') ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<String>> getBackgroundSamples() async {
    try {
      final raw =
          await _channel.invokeListMethod<String>('getBackgroundSamples');
      return raw ?? const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> clearBackgroundSamples() async {
    try {
      await _channel.invokeMethod<void>('clearBackgroundSamples');
    } catch (_) {}
  }

  @override
  Future<String> prepareVpn() async {
    try {
      return await _channel.invokeMethod<String>('prepareVpn') ?? 'error';
    } catch (_) {
      return 'error';
    }
  }

  @override
  Future<bool> startVpnLive() async {
    try {
      return await _channel.invokeMethod<bool>('startVpnLive') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> stopVpnLive() async {
    try {
      return await _channel.invokeMethod<bool>('stopVpnLive') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isVpnLive() async {
    try {
      return await _channel.invokeMethod<bool>('isVpnLive') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<VpnStatus> getVpnStatus() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getVpnStatus');
      if (raw == null) return VpnStatus.inactive;
      return VpnStatus.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return VpnStatus.inactive;
    }
  }

  @override
  Future<UsageSnapshot> getVpnSnapshot() async {
    final raw = await _channel.invokeMethod<Map>('getVpnSnapshot');
    if (raw == null) {
      throw StateError('mymy/usage getVpnSnapshot returned no data');
    }
    return UsageSnapshot.fromJson(Map<String, dynamic>.from(raw));
  }

  UsageStatus _unimplementedStatus() => const UsageStatus(
        hasPermission: false,
        engine: 'unimplemented',
        note: 'Live usage is not available on this platform yet.',
      );
}

/// A fake source for tests (and only for tests). It replays snapshots in
/// order so rate maths can be verified without a device.
class FakeUsageDataSource implements UsageDataSource {
  FakeUsageDataSource(this._snapshots, {this.status = const UsageStatus(
    hasPermission: true,
    engine: 'fake',
    note: 'Test source.',
  )});

  final List<UsageSnapshot> _snapshots;
  final UsageStatus status;
  int _index = 0;

  @override
  Future<UsageStatus> getStatus() async => status;

  @override
  Future<void> openUsageSettings() async {}

  @override
  Future<UsageSnapshot> getSnapshot() async {
    if (_snapshots.isEmpty) {
      throw StateError('FakeUsageDataSource has no snapshots');
    }
    final snapshot = _snapshots[_index];
    if (_index < _snapshots.length - 1) _index++;
    return snapshot;
  }
}

class UsageService {
  UsageService({UsageDataSource? source})
      : _source = source ?? resolveSource();

  /// The platform channel is the source on every platform now:
  /// Android (MainActivity.kt) and Windows Phase 2 (runner native
  /// collector) both implement it. A platform with no handler gets the
  /// explicit "not available" status instead of demo data.
  static UsageDataSource resolveSource() => MethodChannelUsageDataSource();

  final UsageDataSource _source;

  UsageDataSource get source => _source;
  UsageSnapshot? _previous;

  Future<UsageStatus> getStatus() => _source.getStatus();

  Future<void> openUsageSettings() => _source.openUsageSettings();

  /// Takes one snapshot and returns it with live rates derived from the
  /// previous snapshot. The first call has no previous snapshot, so its
  /// rates are 0 — that is honest, not a missing measurement.
  Future<LiveUsage> poll() async {
    final current = await _source.getSnapshot();
    final live = calculate(_previous, current);
    _previous = current;
    return live;
  }

  /// Pure rate maths, kept static so tests can exercise it directly.
  ///
  /// Counter resets (reboot, or a native counter restarting) produce a
  /// negative delta; those are clamped to 0 rather than shown as a
  /// negative speed.
  static LiveUsage calculate(UsageSnapshot? previous, UsageSnapshot current) {
    if (previous == null) {
      return LiveUsage(
        snapshot: current,
        rxBytesPerSecond: 0,
        txBytesPerSecond: 0,
        appRates: const {},
      );
    }
    final seconds = current.timestamp
        .difference(previous.timestamp)
        .inMilliseconds / 1000.0;
    if (seconds <= 0) {
      return LiveUsage(
        snapshot: current,
        rxBytesPerSecond: 0,
        txBytesPerSecond: 0,
        appRates: const {},
      );
    }

    double rate(int next, int prev) {
      final delta = next - prev;
      if (delta <= 0) return 0;
      return delta / seconds;
    }

    final previousApps = <String, AppUsage>{
      for (final app in previous.apps) app.id: app,
    };
    final appRates = <String, ({double rxPerSecond, double txPerSecond})>{};
    for (final app in current.apps) {
      final prev = previousApps[app.id];
      if (prev == null) continue;
      appRates[app.id] = (
        rxPerSecond: rate(app.rxBytes, prev.rxBytes),
        txPerSecond: rate(app.txBytes, prev.txBytes),
      );
    }

    return LiveUsage(
      snapshot: current,
      rxBytesPerSecond: rate(current.totalRxBytes, previous.totalRxBytes),
      txBytesPerSecond: rate(current.totalTxBytes, previous.totalTxBytes),
      appRates: appRates,
    );
  }
}
