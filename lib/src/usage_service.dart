import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'models.dart';
import 'windows_usage.dart' as windows;

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

/// The native platform-channel source used on Android.
///
/// On Windows this channel has no native handler, so [UsageService.resolve]
/// never selects this source there (see [windows.WindowsUsageDataSource]).
class MethodChannelUsageDataSource implements UsageDataSource {
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

  /// Picks the right source for the running platform.
  ///
  /// Windows goes to the Dart/FFI collector (Phase 1: adapter totals +
  /// active connections; per-process bytes are Phase 2). Everything else
  /// goes to the platform channel, which is only implemented on Android
  /// today — other platforms get the explicit "not available" status
  /// instead of demo data.
  static UsageDataSource resolveSource() {
    if (Platform.isWindows) return windows.WindowsUsageDataSource();
    return MethodChannelUsageDataSource();
  }

  final UsageDataSource _source;
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
