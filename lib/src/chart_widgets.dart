import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'charts.dart';
import 'format.dart';
import 'glass.dart';
import 'models.dart';

/// Phase 5 — chart widgets drawn with CustomPaint / layout bars from
/// real data only. Every chart carries a caption stating the question
/// it answers, and an empty state that says "No data yet" — never a
/// sample curve.
///
/// Colours stay in the logo palette: download cyan, upload indigo,
/// bars cyan, donut slices from a fixed palette.

const _downColor = Color(0xFF22D3EE);
const _upColor = Color(0xFF818CF8);

class ChartCaption extends StatelessWidget {
  const ChartCaption({super.key, required this.question, required this.note});

  final String question;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 2),
        Text(note, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}

class EmptyChart extends StatelessWidget {
  const EmptyChart({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(message, style: const TextStyle(color: Colors.white70)),
      ),
    );
  }
}

/// Live rate line/area chart over the session ring buffer.
class RateAreaChart extends StatelessWidget {
  const RateAreaChart({super.key, required this.history});

  final RateHistory history;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const EmptyChart(message: 'No data yet — keep the app open.');
    }
    final peak = history.peak <= 0 ? 1.0 : history.peak;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 140,
          width: double.infinity,
          child: CustomPaint(
            painter: _RatePainter(points: history.points, peak: peak),
          ),
        ),
        const SizedBox(height: 8),
        const Row(
          children: [
            _LegendDot(color: _downColor, label: 'Download'),
            SizedBox(width: 16),
            _LegendDot(color: _upColor, label: 'Upload'),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Peak in window: ${formatRate(peak)}',
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}

class _RatePainter extends CustomPainter {
  _RatePainter({required this.points, required this.peak});

  final List<RatePoint> points;
  final double peak;

  @override
  void paint(Canvas canvas, Size size) {
    Offset point(int i, double value) {
      final x = points.length <= 1
          ? 0.0
          : i / (points.length - 1) * size.width;
      final y = size.height - (value / peak) * (size.height - 8) - 4;
      return Offset(x, y);
    }

    void drawSeries(double Function(RatePoint) pick, Color color) {
      if (points.isEmpty) return;
      final line = Path();
      final fill = Path();
      for (var i = 0; i < points.length; i++) {
        final p = point(i, pick(points[i]));
        if (i == 0) {
          line.moveTo(p.dx, p.dy);
          fill.moveTo(p.dx, size.height);
          fill.lineTo(p.dx, p.dy);
        } else {
          line.lineTo(p.dx, p.dy);
          fill.lineTo(p.dx, p.dy);
        }
      }
      fill.lineTo(size.width, size.height);
      fill.close();
      canvas.drawPath(
        fill,
        Paint()..color = color.withValues(alpha: 0.18),
      );
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    drawSeries((p) => p.rxBytesPerSecond, _downColor);
    drawSeries((p) => p.txBytesPerSecond, _upColor);
  }

  @override
  bool shouldRepaint(covariant _RatePainter old) =>
      old.points != points || old.peak != peak;
}

/// Horizontal bars for top apps: label + proportional bar + value.
/// Layout bars (not CustomPaint) keep long app names readable.
class TopAppsBarList extends StatelessWidget {
  const TopAppsBarList({super.key, required this.apps});

  final List<AppUsage> apps;

  @override
  Widget build(BuildContext context) {
    if (apps.isEmpty) {
      return const EmptyChart(message: 'No data yet.');
    }
    final max = apps.fold<int>(0, (m, a) => math.max(m, a.totalBytes));
    return Column(
      children: [
        for (final app in apps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    app.name.isEmpty ? app.id : app.name,
                    style: const TextStyle(color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: max <= 0 ? 0 : app.totalBytes / max,
                      child: Container(
                        height: 12,
                        decoration: BoxDecoration(
                          color: glassCyan,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatBytes(app.totalBytes),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Donut / share chart, drawn with CustomPaint arcs.
class ShareDonutChart extends StatelessWidget {
  const ShareDonutChart({super.key, required this.slices});

  final List<DonutSlice> slices;

  @override
  Widget build(BuildContext context) {
    if (slices.isEmpty) {
      return const EmptyChart(message: 'No data yet.');
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          height: 140,
          child: CustomPaint(painter: _DonutPainter(slices: slices)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < slices.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      _LegendDot(
                        color: _donutPalette[i % _donutPalette.length],
                        label: '',
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          slices[i].label,
                          style: const TextStyle(color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(slices[i].share * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

const _donutPalette = <Color>[
  Color(0xFF22D3EE),
  Color(0xFF818CF8),
  Color(0xFF34D399),
  Color(0xFFFBBF24),
  Color(0xFFF472B6),
  Color(0xFF60A5FA),
  Color(0xFFA78BFA),
  Color(0xFF94A3B8),
  Color(0xFFC5A04D),
];

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.slices});

  final List<DonutSlice> slices;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;
    final rect = Rect.fromCircle(center: center, radius: radius);
    var start = -math.pi / 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i].share * 2 * math.pi;
      canvas.drawArc(
        rect,
        start,
        sweep,
        true,
        Paint()..color = _donutPalette[i % _donutPalette.length],
      );
      start += sweep;
    }
    // Punch the hole: donut, not pie.
    canvas.drawCircle(
      center,
      radius * 0.58,
      Paint()..color = const Color(0xFF131B4A),
    );
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) => old.slices != slices;
}

/// Vertical daily bars for the History tab (last 7 recorded days).
class DailyBarChart extends StatelessWidget {
  const DailyBarChart({super.key, required this.bars});

  final List<DailyBar> bars;

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty || bars.every((b) => b.totalBytes <= 0)) {
      return const EmptyChart(
        message: 'No recorded usage in the last 7 days yet.',
      );
    }
    final heights = barHeights([for (final b in bars) b.totalBytes]);
    return Column(
      children: [
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < bars.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          formatBytes(bars[i].totalBytes),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: 96 * (heights[i] == 0 ? 0.02 : heights[i]),
                          decoration: BoxDecoration(
                            color: glassCyan,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final b in bars)
              Expanded(
                child: Center(
                  child: Text(
                    _shortDate(b.date),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  String _shortDate(String iso) {
    // '2026-11-04' -> '11-04'.
    if (iso.length >= 10) return iso.substring(5, 10);
    return iso;
  }
}
