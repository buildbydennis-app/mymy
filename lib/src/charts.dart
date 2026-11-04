import 'dart:math' as math;

import 'history.dart';
import 'models.dart';

/// Phase 5 — pure chart-data builders.
///
/// Every builder takes only real snapshots / recorded history and
/// returns data the widgets draw. An empty input returns an empty
/// result, and the widgets show "No data yet" — no builder ever
/// synthesises a sample curve.

/// One live-rate sample (1-second poll, rates already derived and
/// clamped >= 0 by UsageService).
class RatePoint {
  const RatePoint({
    required this.timestamp,
    required this.rxBytesPerSecond,
    required this.txBytesPerSecond,
  });

  final DateTime timestamp;
  final double rxBytesPerSecond;
  final double txBytesPerSecond;
}

/// Fixed-size ring buffer of recent rate samples. The Live tab keeps
/// the last few minutes (default 180 samples = 3 minutes at 1 Hz);
/// older samples drop off, so the chart is always "recent", never a
/// full-day curve pretended from sparse samples.
class RateHistory {
  RateHistory({this.capacity = 180});

  final int capacity;
  final List<RatePoint> _points = [];

  List<RatePoint> get points => List.unmodifiable(_points);
  bool get isEmpty => _points.isEmpty;

  void add(RatePoint point) {
    _points.add(point);
    while (_points.length > capacity) {
      _points.removeAt(0);
    }
  }

  /// Peak rate across both directions, for chart scaling. 0 when empty.
  double get peak {
    var max = 0.0;
    for (final p in _points) {
      max = math.max(max, math.max(p.rxBytesPerSecond, p.txBytesPerSecond));
    }
    return max;
  }
}

/// Top apps by total, largest first, capped at [limit].
List<AppUsage> topAppsByTotal(List<AppUsage> apps, [int limit = 10]) {
  final sorted = [...apps]
    ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
  return sorted.take(limit).toList();
}

/// One donut slice. Shares always sum to 1.0 over the slices returned
/// (top apps + one "Other" slice when the tail is non-empty).
class DonutSlice {
  const DonutSlice({required this.label, required this.bytes, required this.share});

  final String label;
  final int bytes;

  /// Fraction of the total, 0.0–1.0.
  final double share;
}

List<DonutSlice> donutShares(List<AppUsage> apps, [int topN = 8]) {
  final total = apps.fold<int>(0, (sum, a) => sum + a.totalBytes);
  if (total <= 0 || apps.isEmpty) return const [];
  final sorted = [...apps]
    ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
  final top = sorted.take(topN).toList();
  final slices = <DonutSlice>[
    for (final app in top)
      DonutSlice(
        label: app.name.isEmpty ? app.id : app.name,
        bytes: app.totalBytes,
        share: app.totalBytes / total,
      ),
  ];
  final tail = sorted.skip(topN).fold<int>(0, (sum, a) => sum + a.totalBytes);
  if (tail > 0) {
    slices.add(
      DonutSlice(label: 'Other', bytes: tail, share: tail / total),
    );
  }
  return slices;
}

/// One daily bar, oldest first as supplied by HistorySummary.last7Daily.
class DailyBar {
  const DailyBar({required this.date, required this.totalBytes});

  final String date;
  final int totalBytes;
}

List<DailyBar> dailyBars(List<DailyTotal> daily) => [
      for (final d in daily) DailyBar(date: d.date, totalBytes: d.totalBytes),
    ];

/// Normalises values to 0.0–1.0 bar heights against the largest value.
/// All-zero input yields all-zero heights (drawn as an empty chart,
/// not a flat sample line).
List<double> barHeights(List<int> values) {
  if (values.isEmpty) return const [];
  final max = values.fold<int>(0, math.max);
  if (max <= 0) return List.filled(values.length, 0);
  return [for (final v in values) v / max];
}
