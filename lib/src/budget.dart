import 'package:shared_preferences/shared_preferences.dart';

/// Daily data cap, local only. No server, no push, no blocking.
///
/// The cap is intentionally simple: one daily total (device-wide,
/// recorded while sampling) against one MB value. When crossed, the
/// dashboard shows a banner + a persistent alert card. A local
/// notification plugin was deliberately NOT added in Phase 2: the
/// budget alert is shown when the app is open or on reopen after a
/// background merge, which keeps the Android build surface small and
/// the alert logic purely testable. The foreground service's ongoing
/// notification is the only notification MyMy posts in Phase 2.

class BudgetChecker {
  /// True only when a cap is set (> 0) and today's recorded total has
  /// reached it. Never fires with no cap set.
  static bool crossed(int todayTotalBytes, int? capBytes) {
    if (capBytes == null || capBytes <= 0) return false;
    return todayTotalBytes >= capBytes;
  }

  static int? capBytesFromMb(double? mb) {
    if (mb == null || mb <= 0) return null;
    return (mb * 1000000).round();
  }
}

class BudgetStore {
  BudgetStore(this._prefs);

  final SharedPreferences _prefs;
  static const _key = 'daily_cap_mb';

  static Future<BudgetStore> load() async {
    return BudgetStore(await SharedPreferences.getInstance());
  }

  double? get capMb {
    final value = _prefs.getDouble(_key);
    if (value == null || value <= 0) return null;
    return value;
  }

  Future<void> setCapMb(double? mb) async {
    if (mb == null || mb <= 0) {
      await _prefs.remove(_key);
    } else {
      await _prefs.setDouble(_key, mb);
    }
  }
}
