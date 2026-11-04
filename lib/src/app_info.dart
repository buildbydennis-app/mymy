import 'package:flutter/services.dart';

/// Phase 5 — installed apps, usage-stats activity, icons, battery.
///
/// Everything here is an *observable* signal, never an inference
/// presented as a measurement:
///
/// - Installed apps come from PackageManager on Android. On Android
///   11+ the list is subject to package-visibility filtering unless
///   the app holds QUERY_ALL_PACKAGES (deliberately NOT added in
///   Phase 5 — see BUILD_PLAN; a device test must compare the list
///   against Settings before any completeness claim).
/// - Activity comes from UsageStatsManager (already requires the
///   usage-access grant) plus the ActivityManager running-process
///   list, which modern Android limits — absence from that list
///   never proves an app is not running.
/// - Feature badges come from AppOpsManager checks for the package.
///   If the OS does not return an allowed op, no badge is shown —
///   never a guessed badge. An empty feature list means "no signal",
///   not "the app uses no features".
/// - Battery is device-level only (BatteryManager). There is no
///   per-app battery API for ordinary apps, so none is invented.
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    required this.isSystem,
    required this.enabled,
    required this.uid,
  });

  final String packageName;
  final String label;
  final bool isSystem;
  final bool enabled;

  /// Linux UID. Packages sharing one UID are one app group — the
  /// only verifiable reason to draw a link between two app nodes
  /// (see system_map.dart).
  final int uid;

  factory InstalledApp.fromJson(Map<String, dynamic> json) => InstalledApp(
        packageName: json['package'] as String? ?? '',
        label: json['label'] as String? ?? '',
        isSystem: json['isSystem'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? true,
        uid: (json['uid'] as num?)?.toInt() ?? -1,
      );
}

/// Observable activity for one package, or null fields when the OS
/// returned nothing for it.
class AppActivity {
  const AppActivity({
    required this.packageName,
    this.foregroundSeconds = 0,
    this.lastUsedMs,
    this.osReportedRunning = false,
    this.features = const [],
  });

  final String packageName;

  /// Total foreground time today from UsageStatsManager, in seconds.
  /// Labelled "foreground time" in the UI — never "battery use".
  final int foregroundSeconds;

  /// Last time the app was used, epoch millis, or null when
  /// UsageStats has no record for it.
  final int? lastUsedMs;

  /// True only when ActivityManager's running-process list actually
  /// named this package. False means "not reported running", never
  /// "proven not running" — modern Android returns an incomplete list.
  final bool osReportedRunning;

  /// Phone features AppOpsManager actually reported as allowed for
  /// this package, e.g. 'Camera', 'Microphone', 'Fine location'.
  /// Empty means no signal, not a claim of no feature use.
  final List<String> features;

  factory AppActivity.fromJson(Map<String, dynamic> json) {
    final rawFeatures = json['features'] as List<dynamic>? ?? const [];
    return AppActivity(
      packageName: json['package'] as String? ?? '',
      foregroundSeconds: (json['foregroundSeconds'] as num?)?.toInt() ?? 0,
      lastUsedMs: (json['lastUsedMs'] as num?)?.toInt(),
      osReportedRunning: json['osReportedRunning'] as bool? ?? false,
      features: rawFeatures.whereType<String>().toList(),
    );
  }
}

/// Device-level battery only. There is deliberately no per-app
/// battery type anywhere in Phase 5.
class DeviceBattery {
  const DeviceBattery({required this.levelPercent, required this.charging});

  /// 0–100, or -1 when the OS did not report a level.
  final int levelPercent;
  final bool charging;

  factory DeviceBattery.fromJson(Map<String, dynamic> json) =>
      DeviceBattery(
        levelPercent: (json['levelPercent'] as num?)?.toInt() ?? -1,
        charging: json['charging'] as bool? ?? false,
      );
}

abstract class AppInfoSource {
  Future<List<InstalledApp>> getInstalledApps();
  Future<Map<String, AppActivity>> getAppActivity();
  Future<Uint8List?> getAppIcon(String packageName);
  Future<DeviceBattery?> getBattery();
}

/// Native channel source (Android MainActivity). Every call degrades
/// to empty / null on a platform without the handler, so a missing
/// method can never crash the dashboard or invent an app list.
class MethodChannelAppInfoSource implements AppInfoSource {
  MethodChannelAppInfoSource({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('mymy/usage');

  final MethodChannel _channel;

  @override
  Future<List<InstalledApp>> getInstalledApps() async {
    try {
      final raw = await _channel.invokeListMethod<Map>('getInstalledApps');
      if (raw == null) return const [];
      return raw
          .map((e) => InstalledApp.fromJson(Map<String, dynamic>.from(e)))
          .where((a) => a.packageName.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<Map<String, AppActivity>> getAppActivity() async {
    try {
      final raw = await _channel.invokeListMethod<Map>('getAppActivity');
      if (raw == null) return const {};
      final out = <String, AppActivity>{};
      for (final e in raw) {
        final a = AppActivity.fromJson(Map<String, dynamic>.from(e));
        if (a.packageName.isNotEmpty) out[a.packageName] = a;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<Uint8List?> getAppIcon(String packageName) async {
    try {
      final bytes =
          await _channel.invokeMethod<Uint8List>('getAppIcon', packageName);
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<DeviceBattery?> getBattery() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getBattery');
      if (raw == null) return null;
      return DeviceBattery.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }
}
