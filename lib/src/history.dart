import 'dart:convert';
import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models.dart';

/// On-device history, Phase 2.
///
/// Honest definition, stated here because it decides what the numbers
/// mean: history totals are **recorded while MyMy was sampling** (the
/// live tab open, or the Android foreground service running). They are
/// NOT full OS day totals. A sample taken at 10:00 and the next at
/// 10:01 contribute only the positive delta between them; traffic
/// before MyMy first sampled that day is never invented, and a counter
/// drop (reboot) contributes zero, never a negative amount.
///
/// Persisted schema v1 (SQLite):
/// - `daily_totals(date, total_rx, total_tx, mobile_rx, mobile_tx)`
/// - `app_daily(date, app_id, app_name, rx, tx)`
/// - `meta(key, value)` — internal state only: the last recorded
///   snapshot, so deltas survive an app restart without double counting.
///   It is not user history and is never displayed.

String dateKey(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

class DailyTotal {
  const DailyTotal({
    required this.date,
    required this.rxBytes,
    required this.txBytes,
    required this.mobileRxBytes,
    required this.mobileTxBytes,
    this.source = 'polling',
  });

  final String date;
  final int rxBytes;
  final int txBytes;
  final int mobileRxBytes;
  final int mobileTxBytes;

  /// 'polling', 'vpn', or 'mixed' (both sources recorded that day).
  /// A day fed by only one source is never silently presented as if
  /// it came from the other.
  final String source;

  int get totalBytes => rxBytes + txBytes;
  static const empty = DailyTotal(
    date: '',
    rxBytes: 0,
    txBytes: 0,
    mobileRxBytes: -1,
    mobileTxBytes: -1,
  );
}

class AppDaily {
  const AppDaily({
    required this.date,
    required this.appId,
    required this.appName,
    required this.rxBytes,
    required this.txBytes,
    this.source = 'polling',
  });

  final String date;
  final String appId;
  final String appName;
  final int rxBytes;
  final int txBytes;

  /// Same 'polling' / 'vpn' / 'mixed' meaning as [DailyTotal.source].
  final String source;

  int get totalBytes => rxBytes + txBytes;
}

class HistorySummary {
  const HistorySummary({
    required this.today,
    required this.yesterday,
    required this.last7Days,
    required this.perAppToday,
  });

  final DailyTotal today;
  final DailyTotal yesterday;
  final DailyTotal last7Days;

  /// Per-app totals recorded today, largest first.
  final List<AppDaily> perAppToday;

  AppDaily? get biggestUserToday =>
      perAppToday.isEmpty ? null : perAppToday.first;
}

/// One positive delta between two snapshots, or null when there is no
/// previous snapshot to compare against.
({int rx, int tx, int? mobileRx, int? mobileTx, List<AppDaily> appDeltas})
computeDelta(UsageSnapshot previous, UsageSnapshot current) {
  // A new local day starts from zero: the jump between the last
  // sample yesterday and the first sample today is not today's
  // traffic (it includes everything since the last sample, plus any
  // reboot). The first sample of a day is a baseline, never a delta.
  if (dateKey(previous.timestamp) != dateKey(current.timestamp)) {
    return (
      rx: 0,
      tx: 0,
      mobileRx: null,
      mobileTx: null,
      appDeltas: const [],
    );
  }
  int delta(int next, int prev) => next > prev ? next - prev : 0;
  final appDeltas = <AppDaily>[];
  final prevApps = {for (final a in previous.apps) a.id: a};
  for (final app in current.apps) {
    final prev = prevApps[app.id];
    if (prev == null) continue;
    final rx = delta(app.rxBytes, prev.rxBytes);
    final tx = delta(app.txBytes, prev.txBytes);
    if (rx > 0 || tx > 0) {
      appDeltas.add(
        AppDaily(
          date: dateKey(current.timestamp),
          appId: app.id,
          appName: app.name,
          rxBytes: rx,
          txBytes: tx,
        ),
      );
    }
  }
  return (
    rx: delta(current.totalRxBytes, previous.totalRxBytes),
    tx: delta(current.totalTxBytes, previous.totalTxBytes),
    mobileRx: (current.mobileRxBytes >= 0 && previous.mobileRxBytes >= 0)
        ? delta(current.mobileRxBytes, previous.mobileRxBytes)
        : null,
    mobileTx: (current.mobileTxBytes >= 0 && previous.mobileTxBytes >= 0)
        ? delta(current.mobileTxBytes, previous.mobileTxBytes)
        : null,
    appDeltas: appDeltas,
  );
}

abstract class HistoryStore {
  /// Records one snapshot. Throttled to at most once per minute unless
  /// [force] is true (used on app close). A throttled-out sample is
  /// simply skipped — the next recorded sample covers the whole
  /// interval, so no traffic is lost, only granularity.
  Future<void> record(UsageSnapshot snapshot, {bool force = false});

  /// Merges background-service samples (raw snapshots, timestamp
  /// order). Samples at or before the last recorded timestamp are
  /// skipped, so a UI sample and a service sample for the same
  /// interval can never double-count.
  Future<void> mergeSamples(List<UsageSnapshot> samples);

  Future<HistorySummary> summary();

  /// False when the store fell back to in-memory (SQLite unavailable);
  /// history then lasts only for this app session.
  bool get isPersistent;

  Future<void> close();
}

/// In-memory store: same delta logic as SQLite, used in tests and as
/// the fallback when SQLite cannot be opened.
class InMemoryHistoryStore implements HistoryStore {
  final Map<String, DailyTotal> _daily = {};
  final Map<String, Map<String, AppDaily>> _appDaily = {};

  /// One baseline per source ('polling' vs 'vpn'). Switching modes
  /// must never turn the other mode's counters into a delta: the
  /// first sample of a mode is its baseline, exactly like the first
  /// sample of a day.
  final Map<String, UsageSnapshot> _lastBySource = {};
  DateTime? _lastRecordedAt;

  @override
  bool get isPersistent => false;

  @override
  Future<void> record(UsageSnapshot snapshot, {bool force = false}) async {
    if (!force && _lastRecordedAt != null) {
      if (DateTime.now().difference(_lastRecordedAt!) <
          const Duration(minutes: 1)) {
        return;
      }
    }
    _apply(snapshot);
    _lastRecordedAt = DateTime.now();
  }

  @override
  Future<void> mergeSamples(List<UsageSnapshot> samples) async {
    final ordered = [...samples]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final sample in ordered) {
      final last = _lastBySource[sample.source];
      if (last != null && !sample.timestamp.isAfter(last.timestamp)) {
        continue;
      }
      _apply(sample);
    }
  }

  void _apply(UsageSnapshot snapshot) {
    final previous = _lastBySource[snapshot.source];
    _lastBySource[snapshot.source] = snapshot;
    if (previous == null) return;
    final d = computeDelta(previous, snapshot);
    final key = dateKey(snapshot.timestamp);
    final old = _daily[key];
    _daily[key] = DailyTotal(
      date: key,
      rxBytes: (old?.rxBytes ?? 0) + d.rx,
      txBytes: (old?.txBytes ?? 0) + d.tx,
      mobileRxBytes: d.mobileRx == null
          ? (old?.mobileRxBytes ?? -1)
          : (old?.mobileRxBytes ?? -1) < 0
              ? d.mobileRx!
              : (old!.mobileRxBytes + d.mobileRx!),
      mobileTxBytes: d.mobileTx == null
          ? (old?.mobileTxBytes ?? -1)
          : (old?.mobileTxBytes ?? -1) < 0
              ? d.mobileTx!
              : (old!.mobileTxBytes + d.mobileTx!),
      source: old == null
          ? snapshot.source
          : (old.source == snapshot.source ? old.source : 'mixed'),
    );
    final perApp = _appDaily.putIfAbsent(key, () => {});
    for (final app in d.appDeltas) {
      final oldApp = perApp[app.appId];
      perApp[app.appId] = AppDaily(
        date: key,
        appId: app.appId,
        appName: app.appName,
        rxBytes: (oldApp?.rxBytes ?? 0) + app.rxBytes,
        txBytes: (oldApp?.txBytes ?? 0) + app.txBytes,
        source: oldApp == null
            ? snapshot.source
            : (oldApp.source == snapshot.source
                ? oldApp.source
                : 'mixed'),
      );
    }
  }

  @override
  Future<HistorySummary> summary() async {
    final now = DateTime.now();
    final todayKey = dateKey(now);
    final yesterdayKey = dateKey(now.subtract(const Duration(days: 1)));
    DailyTotal totalFor(List<String> keys) {
      var rx = 0, tx = 0, mrx = -1, mtx = -1;
      String? source;
      for (final key in keys) {
        final d = _daily[key];
        if (d == null) continue;
        rx += d.rxBytes;
        tx += d.txBytes;
        if (d.mobileRxBytes >= 0) mrx = (mrx < 0 ? 0 : mrx) + d.mobileRxBytes;
        if (d.mobileTxBytes >= 0) mtx = (mtx < 0 ? 0 : mtx) + d.mobileTxBytes;
        source = source == null
            ? d.source
            : (source == d.source ? source : 'mixed');
      }
      return DailyTotal(
        date: keys.first,
        rxBytes: rx,
        txBytes: tx,
        mobileRxBytes: mrx,
        mobileTxBytes: mtx,
        source: source ?? 'polling',
      );
    }

    final last7Keys = [
      for (var i = 0; i < 7; i++) dateKey(now.subtract(Duration(days: i))),
    ];
    final perApp = [...?_appDaily[todayKey]?.values]
      ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return HistorySummary(
      today: _daily[todayKey] ??
          DailyTotal(
            date: todayKey,
            rxBytes: 0,
            txBytes: 0,
            mobileRxBytes: -1,
            mobileTxBytes: -1,
          ),
      yesterday: _daily[yesterdayKey] ??
          DailyTotal(
            date: yesterdayKey,
            rxBytes: 0,
            txBytes: 0,
            mobileRxBytes: -1,
            mobileTxBytes: -1,
          ),
      last7Days: totalFor(last7Keys),
      perAppToday: perApp,
    );
  }

  @override
  Future<void> close() async {}
}

/// SQLite store (schema v1, see header). Opens the platform database
/// via sqflite on Android and sqflite_common_ffi on Windows/Linux.
/// Any open failure is caught by [open] and reported as an in-memory
/// fallback — never a crash on the dashboard.
class SqliteHistoryStore implements HistoryStore {
  SqliteHistoryStore._(this._db, this._lastBySource);

  final dynamic _db;
  final Map<String, UsageSnapshot> _lastBySource;
  DateTime? _lastRecordedAt;

  @override
  bool get isPersistent => true;

  static Future<HistoryStore> open() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = p.join(dir.path, 'mymy_history.db');
      dynamic db;
      Future<void> onUpgradeFn(dynamic db, int oldV, int newV) async {
        if (oldV < 2) {
          // Phase 3: record which source fed each day/app row.
          await db.execute(
            "ALTER TABLE daily_totals ADD COLUMN source TEXT "
            "NOT NULL DEFAULT 'polling'",
          );
          await db.execute(
            "ALTER TABLE app_daily ADD COLUMN source TEXT "
            "NOT NULL DEFAULT 'polling'",
          );
        }
      }

      if (Platform.isWindows || Platform.isLinux) {
        sqfliteFfiInit();
        db = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, version) async => _createSchema(db),
            onUpgrade: onUpgradeFn,
          ),
        );
      } else {
        db = await sqflite.openDatabase(
          path,
          version: 2,
          onCreate: (db, version) async => _createSchema(db),
          onUpgrade: onUpgradeFn,
        );
      }
      final lastBySource = <String, UsageSnapshot>{};
      for (final source in ['polling', 'vpn']) {
        final rows = await db.query(
          'meta',
          where: 'key = ?',
          whereArgs: ['last_snapshot_$source'],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          try {
            final json = jsonDecode(rows.first['value'] as String)
                as Map<String, dynamic>;
            lastBySource[source] = UsageSnapshot.fromJson(json);
          } catch (_) {}
        }
      }
      // Legacy Phase 2 key is the polling baseline.
      if (!lastBySource.containsKey('polling')) {
        final rows = await db.query(
          'meta',
          where: 'key = ?',
          whereArgs: ['last_snapshot'],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          try {
            final json = jsonDecode(rows.first['value'] as String)
                as Map<String, dynamic>;
            lastBySource['polling'] = UsageSnapshot.fromJson(json);
          } catch (_) {}
        }
      }
      return SqliteHistoryStore._(db, lastBySource);
    } catch (_) {
      return InMemoryHistoryStore();
    }
  }

  static Future<void> _createSchema(dynamic db) async {
    await db.execute(
      'CREATE TABLE daily_totals('
      'date TEXT PRIMARY KEY, total_rx INTEGER NOT NULL, '
      'total_tx INTEGER NOT NULL, mobile_rx INTEGER NOT NULL, '
      'mobile_tx INTEGER NOT NULL, source TEXT NOT NULL '
      "DEFAULT 'polling')",
    );
    await db.execute(
      'CREATE TABLE app_daily('
      'date TEXT NOT NULL, app_id TEXT NOT NULL, app_name TEXT NOT NULL, '
      'rx INTEGER NOT NULL, tx INTEGER NOT NULL, source TEXT NOT NULL '
      "DEFAULT 'polling', "
      'PRIMARY KEY(date, app_id))',
    );
    await db.execute(
      'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
  }

  @override
  Future<void> record(UsageSnapshot snapshot, {bool force = false}) async {
    if (!force && _lastRecordedAt != null) {
      if (DateTime.now().difference(_lastRecordedAt!) <
          const Duration(minutes: 1)) {
        return;
      }
    }
    await _apply(snapshot);
    _lastRecordedAt = DateTime.now();
  }

  @override
  Future<void> mergeSamples(List<UsageSnapshot> samples) async {
    final ordered = [...samples]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final sample in ordered) {
      final last = _lastBySource[sample.source];
      if (last != null && !sample.timestamp.isAfter(last.timestamp)) {
        continue;
      }
      await _apply(sample);
    }
  }

  Future<void> _apply(UsageSnapshot snapshot) async {
    final previous = _lastBySource[snapshot.source];
    _lastBySource[snapshot.source] = snapshot;
    await _db.insert(
      'meta',
      {
        'key': 'last_snapshot_${snapshot.source}',
        'value': jsonEncode(_snapshotToJson(snapshot)),
      },
      conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
    );
    if (previous == null) return;
    final d = computeDelta(previous, snapshot);
    final key = dateKey(snapshot.timestamp);
    final existing = await _db.query(
      'daily_totals',
      where: 'date = ?',
      whereArgs: [key],
      limit: 1,
    );
    final oldRx = existing.isEmpty ? 0 : existing.first['total_rx'] as int;
    final oldTx = existing.isEmpty ? 0 : existing.first['total_tx'] as int;
    final oldMrx = existing.isEmpty ? -1 : existing.first['mobile_rx'] as int;
    final oldMtx = existing.isEmpty ? -1 : existing.first['mobile_tx'] as int;
    final oldSource =
        existing.isEmpty ? null : existing.first['source'] as String?;
    await _db.insert(
      'daily_totals',
      {
        'date': key,
        'total_rx': oldRx + d.rx,
        'total_tx': oldTx + d.tx,
        'mobile_rx': d.mobileRx == null
            ? oldMrx
            : (oldMrx < 0 ? d.mobileRx! : oldMrx + d.mobileRx!),
        'mobile_tx': d.mobileTx == null
            ? oldMtx
            : (oldMtx < 0 ? d.mobileTx! : oldMtx + d.mobileTx!),
        'source': oldSource == null
            ? snapshot.source
            : (oldSource == snapshot.source ? oldSource : 'mixed'),
      },
      conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
    );
    for (final app in d.appDeltas) {
      final rows = await _db.query(
        'app_daily',
        where: 'date = ? AND app_id = ?',
        whereArgs: [key, app.appId],
        limit: 1,
      );
      final oldAppRx = rows.isEmpty ? 0 : rows.first['rx'] as int;
      final oldAppTx = rows.isEmpty ? 0 : rows.first['tx'] as int;
      final oldAppSource =
          rows.isEmpty ? null : rows.first['source'] as String?;
      await _db.insert(
        'app_daily',
        {
          'date': key,
          'app_id': app.appId,
          'app_name': app.appName,
          'rx': oldAppRx + app.rxBytes,
          'tx': oldAppTx + app.txBytes,
          'source': oldAppSource == null
              ? snapshot.source
              : (oldAppSource == snapshot.source
                  ? oldAppSource
                  : 'mixed'),
        },
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
    }
  }

  @override
  Future<HistorySummary> summary() async {
    final now = DateTime.now();
    final todayKey = dateKey(now);
    final yesterdayKey = dateKey(now.subtract(const Duration(days: 1)));
    Future<DailyTotal> totalFor(List<String> keys) async {
      var rx = 0, tx = 0, mrx = -1, mtx = -1;
      String? source;
      for (final key in keys) {
        final rows = await _db.query(
          'daily_totals',
          where: 'date = ?',
          whereArgs: [key],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        rx += rows.first['total_rx'] as int;
        tx += rows.first['total_tx'] as int;
        final r = rows.first['mobile_rx'] as int;
        final t = rows.first['mobile_tx'] as int;
        if (r >= 0) mrx = (mrx < 0 ? 0 : mrx) + r;
        if (t >= 0) mtx = (mtx < 0 ? 0 : mtx) + t;
        final rowSource = rows.first['source'] as String?;
        if (rowSource != null) {
          source = source == null
              ? rowSource
              : (source == rowSource ? source : 'mixed');
        }
      }
      return DailyTotal(
        date: keys.first,
        rxBytes: rx,
        txBytes: tx,
        mobileRxBytes: mrx,
        mobileTxBytes: mtx,
        source: source ?? 'polling',
      );
    }

    final last7Keys = [
      for (var i = 0; i < 7; i++) dateKey(now.subtract(Duration(days: i))),
    ];
    final perAppRows = await _db.query(
      'app_daily',
      where: 'date = ?',
      whereArgs: [todayKey],
      orderBy: '(rx + tx) DESC',
    );
    return HistorySummary(
      today: await totalFor([todayKey]),
      yesterday: await totalFor([yesterdayKey]),
      last7Days: await totalFor(last7Keys),
      perAppToday: perAppRows
          .map(
            (r) => AppDaily(
              date: todayKey,
              appId: r['app_id'] as String,
              appName: r['app_name'] as String,
              rxBytes: r['rx'] as int,
              txBytes: r['tx'] as int,
              source: r['source'] as String? ?? 'polling',
            ),
          )
          .toList(),
    );
  }

  @override
  Future<void> close() async {
    try {
      await _db.close();
    } catch (_) {}
  }
}

Map<String, dynamic> _snapshotToJson(UsageSnapshot s) => {
      'timestampMs': s.timestamp.millisecondsSinceEpoch,
      'totalRx': s.totalRxBytes,
      'totalTx': s.totalTxBytes,
      'mobileRx': s.mobileRxBytes,
      'mobileTx': s.mobileTxBytes,
      'source': s.source,
      'apps': [
        for (final a in s.apps)
          {'id': a.id, 'name': a.name, 'rx': a.rxBytes, 'tx': a.txBytes},
      ],
      'connections': const [],
    };
