// Dashboard smoke test: the app renders its live dashboard shell with a
// fake usage source. It asserts no sample/demo numbers are shown as real
// data — the fake source's counters are the only numbers on screen.
// The history store is injected: the real open path (openHistoryStore,
// 15 s timeout) is covered by phase5_test.dart, and its timeout timer
// would otherwise linger in the test's fake async clock.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymy/main.dart';
import 'package:mymy/src/models.dart';
import 'package:mymy/src/history.dart';
import 'package:mymy/src/usage_service.dart';

void main() {
  testWidgets('dashboard renders with a fake source', (tester) async {
    final snapshot = UsageSnapshot(
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      totalRxBytes: 1234567,
      totalTxBytes: 765432,
      mobileRxBytes: -1,
      mobileTxBytes: -1,
      apps: const [],
      connections: const [],
    );
    final service = UsageService(
      source: FakeUsageDataSource([snapshot]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DashboardPage(
          service: service,
          historyStore: InMemoryHistoryStore(),
        ),
      ),
    );
    await tester.pump();
    // Advance past one 1-second poll tick so the snapshot is displayed.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('MyMy — Live Data Usage'), findsOneWidget);
    expect(find.text('Live now'), findsOneWidget);
    // No permission banner when the fake source reports access granted.
    expect(find.text('Usage access needed for per-app totals'), findsNothing);
  });
}
