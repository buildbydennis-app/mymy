/// Shared data model for MyMy.
///
/// The rule this file encodes: native code reports *cumulative counters*
/// (bytes since boot / since the connection started). It never reports a
/// "speed". The live speed is always derived in Dart as
/// `(newTotal - oldTotal) / elapsedSeconds`, so a displayed speed is a
/// measurement over a real interval, never an invented number.
library;

/// One app (Android) or one process (Windows).
class AppUsage {
  const AppUsage({
    required this.id,
    required this.name,
    required this.rxBytes,
    required this.txBytes,
    this.mobileRxBytes = -1,
    this.mobileTxBytes = -1,
  });

  /// Android package name, or Windows process name + pid, e.g. `chrome.exe:1234`.
  final String id;
  final String name;
  final int rxBytes;
  final int txBytes;

  /// Phase 5: per-app mobile split from NetworkStatsManager, when the
  /// native side could measure it. -1 means unknown (Windows, VPN
  /// snapshots, or a device whose mobile query returned nothing) —
  /// never 0 presented as "used no mobile data".
  final int mobileRxBytes;
  final int mobileTxBytes;

  int get totalBytes => rxBytes + txBytes;

  /// Wi-Fi / other bytes, derived as total − mobile, or -1 when the
  /// mobile split is unknown. Derived, never measured directly.
  int get wifiBytes {
    if (mobileRxBytes < 0 || mobileTxBytes < 0) return -1;
    final wifi = totalBytes - mobileRxBytes - mobileTxBytes;
    return wifi < 0 ? 0 : wifi;
  }

  int get mobileBytes =>
      mobileRxBytes < 0 || mobileTxBytes < 0
          ? -1
          : mobileRxBytes + mobileTxBytes;

  factory AppUsage.fromJson(Map<String, dynamic> json) => AppUsage(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        rxBytes: (json['rx'] as num?)?.toInt() ?? 0,
        txBytes: (json['tx'] as num?)?.toInt() ?? 0,
        mobileRxBytes: (json['mobileRx'] as num?)?.toInt() ?? -1,
        mobileTxBytes: (json['mobileTx'] as num?)?.toInt() ?? -1,
      );
}

/// One live connection, shown on Windows in Phase 1 where per-process byte
/// counters are not yet available (see docs/BUILD_PLAN.md).
class LiveConnection {
  const LiveConnection({
    required this.processName,
    required this.pid,
    required this.remote,
  });

  final String processName;
  final int pid;
  final String remote;

  factory LiveConnection.fromJson(Map<String, dynamic> json) =>
      LiveConnection(
        processName: json['process'] as String? ?? '',
        pid: (json['pid'] as num?)?.toInt() ?? 0,
        remote: json['remote'] as String? ?? '',
      );
}

/// One snapshot of cumulative counters.
class UsageSnapshot {
  const UsageSnapshot({
    required this.timestamp,
    required this.totalRxBytes,
    required this.totalTxBytes,
    required this.mobileRxBytes,
    required this.mobileTxBytes,
    required this.apps,
    required this.connections,
    this.source = 'polling',
  });

  final DateTime timestamp;
  final int totalRxBytes;
  final int totalTxBytes;

  /// -1 on platforms that cannot split mobile vs Wi-Fi (Windows).
  final int mobileRxBytes;
  final int mobileTxBytes;

  final List<AppUsage> apps;
  final List<LiveConnection> connections;

  /// Where this snapshot came from: 'polling' (NetworkStatsManager /
  /// Windows collector) or 'vpn' (Android VPN live mode). History keeps
  /// a separate baseline per source, so switching modes never creates
  /// a false delta, and a day fed by both sources is labelled 'mixed'.
  final String source;

  int get totalBytes => totalRxBytes + totalTxBytes;

  factory UsageSnapshot.fromJson(Map<String, dynamic> json) {
    final appsJson = json['apps'] as List<dynamic>? ?? const [];
    final connsJson = json['connections'] as List<dynamic>? ?? const [];
    return UsageSnapshot(
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['timestampMs'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      totalRxBytes: (json['totalRx'] as num?)?.toInt() ?? 0,
      totalTxBytes: (json['totalTx'] as num?)?.toInt() ?? 0,
      mobileRxBytes: (json['mobileRx'] as num?)?.toInt() ?? -1,
      mobileTxBytes: (json['mobileTx'] as num?)?.toInt() ?? -1,
      source: json['source'] as String? ?? 'polling',
      apps: appsJson
          .whereType<Map>()
          .map((e) => AppUsage.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      connections: connsJson
          .whereType<Map>()
          .map((e) => LiveConnection.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// A snapshot plus the live rates derived from the previous snapshot.
class LiveUsage {
  const LiveUsage({
    required this.snapshot,
    required this.rxBytesPerSecond,
    required this.txBytesPerSecond,
    required this.appRates,
  });

  final UsageSnapshot snapshot;

  /// Device-wide live rates. Negative deltas (counter reset after a reboot)
  /// are clamped to zero by [UsageService].
  final double rxBytesPerSecond;
  final double txBytesPerSecond;

  /// Per-app live rates, keyed by [AppUsage.id].
  final Map<String, ({double rxPerSecond, double txPerSecond})> appRates;
}

/// Status reported by the native VPN side (MainActivity /
/// VpnLiveService). `active` is the only field that may start the VPN
/// badge; everything else is diagnostic.
class VpnStatus {
  const VpnStatus({
    required this.active,
    required this.startedAtMs,
    required this.error,
    required this.totalRxBytes,
    required this.totalTxBytes,
    required this.unattributedRxBytes,
    required this.unattributedTxBytes,
  });

  final bool active;
  final int? startedAtMs;
  final String error;
  final int totalRxBytes;
  final int totalTxBytes;
  final int unattributedRxBytes;
  final int unattributedTxBytes;

  static const inactive = VpnStatus(
    active: false,
    startedAtMs: null,
    error: '',
    totalRxBytes: 0,
    totalTxBytes: 0,
    unattributedRxBytes: 0,
    unattributedTxBytes: 0,
  );

  factory VpnStatus.fromJson(Map<String, dynamic> json) => VpnStatus(
        active: json['active'] as bool? ?? false,
        startedAtMs: (json['startedAtMs'] as num?)?.toInt(),
        error: json['error'] as String? ?? '',
        totalRxBytes: (json['totalRx'] as num?)?.toInt() ?? 0,
        totalTxBytes: (json['totalTx'] as num?)?.toInt() ?? 0,
        unattributedRxBytes:
            (json['unattributedRx'] as num?)?.toInt() ?? 0,
        unattributedTxBytes:
            (json['unattributedTx'] as num?)?.toInt() ?? 0,
      );
}

/// Permission / engine status reported by the native side.
class UsageStatus {
  const UsageStatus({
    required this.hasPermission,
    required this.engine,
    required this.note,
  });

  final bool hasPermission;

  /// e.g. `network-stats` (Android), `ip-helper` (Windows Phase 1).
  final String engine;
  final String note;

  factory UsageStatus.fromJson(Map<String, dynamic> json) => UsageStatus(
        hasPermission: json['hasPermission'] as bool? ?? false,
        engine: json['engine'] as String? ?? 'unknown',
        note: json['note'] as String? ?? '',
      );
}
