import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'usage_service.dart';

/// Phase 3 — opt-in Android VPN live mode.
///
/// Polling stays the default. VPN mode is OFF by default, opt-in only,
/// and only ever runs after the prominent disclosure has been accepted
/// AND the system VPN consent dialog has been approved. Turning it off
/// returns the dashboard to polling; nothing about VPN mode is
/// persistent across app restarts except the disclosure acceptance
/// itself (the mode always starts as polling on launch, so a VPN is
/// never silently re-established).

enum LiveMode { polling, vpn }

/// Prominent-disclosure acceptance, persisted locally.
///
/// Acceptance does NOT start the VPN and does NOT survive as an active
/// mode: it only records that the user has seen and accepted the
/// disclosure text. The system VPN consent dialog is still required
/// on every start.
class VpnDisclosureStore {
  VpnDisclosureStore(this._prefs);

  final SharedPreferences _prefs;
  static const _key = 'vpn_disclosure_accepted';
  static const _atKey = 'vpn_disclosure_accepted_at_ms';

  static Future<VpnDisclosureStore> load() async {
    return VpnDisclosureStore(await SharedPreferences.getInstance());
  }

  bool get accepted => _prefs.getBool(_key) ?? false;
  int? get acceptedAtMs => _prefs.getInt(_atKey);

  Future<void> accept() async {
    await _prefs.setBool(_key, true);
    await _prefs.setInt(
      _atKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> clear() async {
    await _prefs.remove(_key);
    await _prefs.remove(_atKey);
  }
}

/// Pure mode state, testable without a channel.
///
/// Rules enforced here, not just in the UI:
/// - The mode starts as polling, always.
/// - VPN can only start when disclosure is accepted AND the caller
///   confirms system consent was granted.
/// - Stopping clears the active flag, the start time, and any
///   reconciliation result, so a stale VPN badge can never linger.
class VpnLiveState {
  VpnLiveState({
    this.mode = LiveMode.polling,
    this.disclosureAccepted = false,
    this.vpnActive = false,
    this.startedAtMs,
    this.error = '',
  });

  LiveMode mode;
  bool disclosureAccepted;
  bool vpnActive;
  int? startedAtMs;
  String error;

  bool get canStartVpn => disclosureAccepted && !vpnActive;

  void markStarted(int startedAt) {
    mode = LiveMode.vpn;
    vpnActive = true;
    startedAtMs = startedAt;
    error = '';
  }

  void markStopped({String errorMessage = ''}) {
    mode = LiveMode.polling;
    vpnActive = false;
    startedAtMs = null;
    error = errorMessage;
  }
}

/// Reconciliation of VPN-counted totals against NetworkStats totals
/// over the SAME window.
///
/// VPN totals are cumulative since the VPN started. NetworkStats
/// totals are cumulative since boot (polling snapshots) or since
/// midnight (per-app). They are therefore never compared directly:
/// the caller passes a polling snapshot taken at VPN start (the
/// baseline) and a polling snapshot taken now, and the system delta
/// for that window is compared to the VPN total for that window.
///
/// Tolerance accounts for the documented gaps: IPv6 traffic bypasses
/// the VPN (no IPv6 route is added, so it still works but is not
/// VPN-counted), connections established before VPN start are not
/// VPN-counted, unattributed bytes are counted separately, and
/// header accounting differs slightly. A mismatch is surfaced as a
/// warning with numbers, never silently resolved in favour of one
/// source.
class ReconciliationResult {
  const ReconciliationResult({
    required this.status,
    required this.vpnTotalBytes,
    required this.systemDeltaBytes,
    required this.differenceBytes,
    required this.message,
  });

  /// 'match', 'mismatch', or 'unavailable' (no baseline, or a counter
  /// reset between baseline and now).
  final String status;
  final int vpnTotalBytes;
  final int systemDeltaBytes;
  final int differenceBytes;
  final String message;
}

class Reconciliation {
  /// Absolute floor (1 MB) plus 25% of the system delta, whichever is
  /// larger. Small windows are noisy; large windows tolerate header
  /// and bypass differences.
  static int toleranceFor(int systemDeltaBytes) {
    final relative = (systemDeltaBytes * 0.25).round();
    return relative > 1000000 ? relative : 1000000;
  }

  static ReconciliationResult check({
    required int vpnRxBytes,
    required int vpnTxBytes,
    UsageSnapshot? netBaseline,
    UsageSnapshot? netNow,
  }) {
    if (netBaseline == null || netNow == null) {
      return const ReconciliationResult(
        status: 'unavailable',
        vpnTotalBytes: 0,
        systemDeltaBytes: 0,
        differenceBytes: 0,
        message: 'Reconciliation unavailable: no system baseline was '
            'captured when VPN mode started (for example, VPN mode was '
            'already running when the app reopened).',
      );
    }
    final netRxDelta = netNow.totalRxBytes - netBaseline.totalRxBytes;
    final netTxDelta = netNow.totalTxBytes - netBaseline.totalTxBytes;
    if (netRxDelta < 0 || netTxDelta < 0) {
      return const ReconciliationResult(
        status: 'unavailable',
        vpnTotalBytes: 0,
        systemDeltaBytes: 0,
        differenceBytes: 0,
        message: 'Reconciliation unavailable: the system counters reset '
            '(reboot) between the baseline and now, so the window is '
            'not comparable.',
      );
    }
    final vpnTotal = vpnRxBytes + vpnTxBytes;
    final systemDelta = netRxDelta + netTxDelta;
    final difference = (vpnTotal - systemDelta).abs();
    final tolerance = toleranceFor(systemDelta);
    if (difference <= tolerance) {
      return ReconciliationResult(
        status: 'match',
        vpnTotalBytes: vpnTotal,
        systemDeltaBytes: systemDelta,
        differenceBytes: difference,
        message: 'VPN-counted totals reconcile with system totals for '
            'this VPN session (within tolerance).',
      );
    }
    return ReconciliationResult(
      status: 'mismatch',
      vpnTotalBytes: vpnTotal,
      systemDeltaBytes: systemDelta,
      differenceBytes: difference,
      message: 'VPN-counted totals differ from system totals for this '
          'VPN session by more than tolerance. Possible reasons: '
          'IPv6 traffic bypasses the VPN and is not VPN-counted, '
          'connections established before VPN start are not '
          'VPN-counted, or bytes could not be attributed to an app '
          '(shown as Unattributed). Neither source is silently '
          'preferred.',
    );
  }
}

/// Polls VPN snapshots and derives rates with the same maths as
/// polling ([UsageService.calculate]), but with its own previous
/// snapshot, so switching modes never creates a rate spike from the
/// other mode's counters.
class VpnPollingService {
  VpnPollingService(this.source);

  final VpnLiveSource source;
  UsageSnapshot? _previous;

  void reset() {
    _previous = null;
  }

  Future<LiveUsage> poll() async {
    final current = await source.getVpnSnapshot();
    final live = UsageService.calculate(_previous, current);
    _previous = current;
    return live;
  }
}

/// The exact disclosure text shown before VPN mode can start. Kept
/// here (not only in the UI) so tests and docs quote the same words.
const vpnDisclosureText =
    'MyMy VPN live mode will route your device traffic through MyMy '
    'itself, on this device only. There is no server: no traffic, '
    'content, or browsing history leaves your phone. MyMy counts '
    'bytes per app only — it does not inspect the content of your '
    'traffic, and it never blocks or limits any app.\n\n'
    'While VPN live mode is active, any other VPN on this device will '
    'be disconnected, because Android allows only one VPN at a time. '
    'Battery use will be higher than in polling mode.\n\n'
    'You can turn VPN live mode off at any time from the Live tab or '
    'from its notification, and MyMy returns to polling mode.';
