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
  });

  /// Android package name, or Windows process name + pid, e.g. `chrome.exe:1234`.
  final String id;
  final String name;
  final int rxBytes;
  final int txBytes;

  int get totalBytes => rxBytes + txBytes;

  factory AppUsage.fromJson(Map<String, dynamic> json) => AppUsage(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        rxBytes: (json['rx'] as num?)?.toInt() ?? 0,
        txBytes: (json['tx'] as num?)?.toInt() ?? 0,
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
  });

  final DateTime timestamp;
  final int totalRxBytes;
  final int totalTxBytes;

  /// -1 on platforms that cannot split mobile vs Wi-Fi (Windows).
  final int mobileRxBytes;
  final int mobileTxBytes;

  final List<AppUsage> apps;
  final List<LiveConnection> connections;

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
