import 'usage_service.dart';
import 'models.dart';

/// Windows collector — Phase 1 stub, deliberately honest.
///
/// What was tried: the `win32` package (6.4.0) was added and inspected.
/// Its generated iphlpapi bindings do NOT include GetIfTable2,
/// GetExtendedTcpTable, GetExtendedUdpTable or GetPerTcpConnectionEStats,
/// so the Phase 1 Windows plan (adapter totals + active connections via
/// win32) cannot be built on that package without hand-written FFI for
/// variable-length table structs. Shipping hand-written FFI blind — with
/// no Windows machine here to run it on — would be guessing, so it is
/// NOT shipped.
///
/// What Phase 2 must do instead (see docs/BUILD_PLAN.md): a small native
/// Windows plugin (C++) using IP Helper + ETW
/// (Microsoft-Windows-Kernel-Network), built and smoke-tested on a real
/// Windows machine / Windows CI runner, reporting the same cumulative
/// counter contract as Android. Until then this source reports its
/// status plainly and refuses to return a snapshot, so the dashboard
/// shows "not available on Windows yet" instead of invented numbers.
class WindowsUsageDataSource implements UsageDataSource {
  @override
  Future<UsageStatus> getStatus() async => const UsageStatus(
        hasPermission: false,
        engine: 'windows-phase2-pending',
        note:
            'Windows live usage is not implemented in Phase 1. Per-process '
            'bytes need the Phase 2 native ETW / IP Helper collector, which '
            'must be built and tested on Windows. See docs/BUILD_PLAN.md.',
      );

  @override
  Future<void> openUsageSettings() async {
    // No Windows settings page is meaningful here yet.
  }

  @override
  Future<UsageSnapshot> getSnapshot() async {
    throw StateError(
      'Windows usage collection is not implemented in Phase 1 '
      '(engine: windows-phase2-pending). See docs/BUILD_PLAN.md.',
    );
  }
}
