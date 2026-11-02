import 'dart:convert';

import 'history.dart';
import 'models.dart';
import 'usage_service.dart';

/// Merges Android foreground-service samples into history.
///
/// The service writes raw snapshots (one JSON line per minute) to a
/// file while the UI is closed. On reopen, this controller reads those
/// lines through the channel, feeds them to [HistoryStore.mergeSamples]
/// (which skips anything at or before the last recorded timestamp, so
/// UI and service samples for one interval can never double-count),
/// and then clears the file. Until that merge, service traffic is not
/// in history — it is pending, not lost, and never presented twice.
class BackgroundSamplingController {
  BackgroundSamplingController({
    required this.source,
    required this.history,
  });

  final BackgroundSamplingSource source;
  final HistoryStore history;

  /// Returns how many lines were parsed (0 when there is no service
  /// file, or on a platform without a service handler).
  Future<int> mergePendingSamples() async {
    final lines = await source.getBackgroundSamples();
    if (lines.isEmpty) return 0;
    final samples = <UsageSnapshot>[];
    for (final line in lines) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        samples.add(UsageSnapshot.fromJson(json));
      } catch (_) {
        // One corrupt line must not block the rest of the merge.
        continue;
      }
    }
    if (samples.isNotEmpty) {
      await history.mergeSamples(samples);
    }
    await source.clearBackgroundSamples();
    return samples.length;
  }
}
