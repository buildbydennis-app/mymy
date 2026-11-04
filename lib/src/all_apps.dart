import 'app_info.dart';
import 'models.dart';

/// Phase 5 — the all-apps list.
///
/// The old per-app list only contained UIDs that NetworkStatsManager
/// returned for today, i.e. apps that had already used data. This
/// merge starts from the *installed* list and joins data totals onto
/// it, so an installed app with no data today still appears — shown
/// as 0 / "No data today", never hidden and never given fake bytes.
///
/// Windows has no installed-apps list in Phase 5: its merged list is
/// built from collector processes only, and the UI must label it
/// "processes seen by the collector", not "all apps".

enum AppListFilter { all, dataUsers, system, userApps }

/// One row of the all-apps list.
class MergedApp {
  const MergedApp({
    required this.id,
    required this.name,
    required this.rxBytes,
    required this.txBytes,
    required this.rateBytesPerSecond,
    required this.isSystem,
    required this.enabled,
    this.activity,
    this.isInstalledListEntry = true,
  });

  /// Package name (Android) or process id (Windows).
  final String id;
  final String name;
  final int rxBytes;
  final int txBytes;

  /// Live rate (rx + tx) derived from polling deltas, clamped >= 0
  /// by UsageService. 0 when no previous snapshot exists.
  final double rateBytesPerSecond;
  final bool isSystem;
  final bool enabled;

  /// Observable activity, or null when the OS returned none.
  final AppActivity? activity;

  /// False for rows that came only from a data snapshot (Windows
  /// processes, or Android data users with no installed-list entry).
  /// The UI uses this to label the list honestly.
  final bool isInstalledListEntry;

  int get totalBytes => rxBytes + txBytes;
  bool get hasDataToday => totalBytes > 0;
}

/// Merges an installed list with a data snapshot.
///
/// - Every installed app appears, even with zero bytes.
/// - Every data row with no installed entry still appears (a UID the
///   installed list did not return, e.g. a system UID, or a Windows
///   process) — dropping measured data would be worse than showing
///   a row without a system flag.
/// - System flag and enabled state come only from the installed
///   entry; a data-only row is not guessed to be system or user.
List<MergedApp> mergeApps({
  required List<InstalledApp> installed,
  required List<AppUsage> stats,
  Map<String, double> rates = const {},
}) {
  final byId = <String, AppUsage>{};
  for (final app in stats) {
    byId[app.id] = app;
  }
  final merged = <MergedApp>[];
  final seen = <String>{};
  for (final app in installed) {
    seen.add(app.packageName);
    final data = byId[app.packageName];
    merged.add(
      MergedApp(
        id: app.packageName,
        name: app.label.isEmpty ? app.packageName : app.label,
        rxBytes: data?.rxBytes ?? 0,
        txBytes: data?.txBytes ?? 0,
        rateBytesPerSecond: rates[app.packageName] ?? 0,
        isSystem: app.isSystem,
        enabled: app.enabled,
        isInstalledListEntry: true,
      ),
    );
  }
  for (final app in stats) {
    if (seen.contains(app.id)) continue;
    merged.add(
      MergedApp(
        id: app.id,
        name: app.name.isEmpty ? app.id : app.name,
        rxBytes: app.rxBytes,
        txBytes: app.txBytes,
        rateBytesPerSecond: rates[app.id] ?? 0,
        isSystem: false,
        enabled: true,
        isInstalledListEntry: false,
      ),
    );
  }
  return merged;
}

/// Attaches observable activity to merged rows by package name.
/// Rows without an activity entry keep a null activity — the badge
/// then reads as unknown, never as a guessed state.
List<MergedApp> attachActivity(
  List<MergedApp> apps,
  Map<String, AppActivity> activity,
) {
  if (activity.isEmpty) return apps;
  return [
    for (final app in apps)
      MergedApp(
        id: app.id,
        name: app.name,
        rxBytes: app.rxBytes,
        txBytes: app.txBytes,
        rateBytesPerSecond: app.rateBytesPerSecond,
        isSystem: app.isSystem,
        enabled: app.enabled,
        activity: activity[app.id] ?? app.activity,
        isInstalledListEntry: app.isInstalledListEntry,
      ),
  ];
}

List<MergedApp> filterApps(List<MergedApp> apps, AppListFilter filter) {
  switch (filter) {
    case AppListFilter.all:
      return apps;
    case AppListFilter.dataUsers:
      return apps.where((a) => a.hasDataToday).toList();
    case AppListFilter.system:
      return apps.where((a) => a.isSystem).toList();
    case AppListFilter.userApps:
      return apps.where((a) => !a.isSystem).toList();
  }
}

/// Same order as before: current rate first, then total.
List<MergedApp> sortApps(List<MergedApp> apps) {
  final sorted = [...apps];
  sorted.sort((a, b) {
    if (b.rateBytesPerSecond != a.rateBytesPerSecond) {
      return b.rateBytesPerSecond.compareTo(a.rateBytesPerSecond);
    }
    return b.totalBytes.compareTo(a.totalBytes);
  });
  return sorted;
}

/// Badge rule, documented because the badge is the honest boundary:
///
/// - "Foreground now": ActivityManager actually reported the package
///   running, OR UsageStats last-used is within the last 2 minutes.
///   Either way this means *recent usage-stats activity*, NOT a
///   claimed complete live process list.
/// - "Background recently": used within the last 24 hours, but not
///   in the last 2 minutes.
/// - "Not recently used": no UsageStats record in the last 24 hours,
///   or no record at all when an activity entry exists with no
///   last-used time.
/// - "Activity unknown": no activity signal reached Dart at all
///   (e.g. usage access not granted, or the platform has no
///   UsageStats). Never shown as "not running".
String activityBadge(MergedApp app, {required DateTime now}) {
  final activity = app.activity;
  if (activity == null) return 'Activity unknown';
  if (activity.osReportedRunning) return 'Foreground now';
  final lastUsedMs = activity.lastUsedMs;
  if (lastUsedMs != null) {
    final age = now.millisecondsSinceEpoch - lastUsedMs;
    if (age >= 0 && age <= 2 * 60 * 1000) return 'Foreground now';
    if (age > 0 && age <= 24 * 60 * 60 * 1000) return 'Background recently';
    return 'Not recently used';
  }
  return 'Not recently used';
}
