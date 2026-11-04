import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'system_map.dart';

/// Phase 5 — Live System Map widget.
///
/// Layout: device hub in the centre, app nodes on a ring, transport /
/// feature / group nodes on an outer ring. Node radius scales with
/// live rate (from SystemMap.sizeFactor); colour encodes state. The
/// legend below the canvas states exactly what each node and edge
/// means — including what the map does NOT show (no app-to-app data
/// sharing edges exist, because Android does not expose that).

Color _colorFor(String key) {
  switch (key) {
    case 'foreground':
      return const Color(0xFF22D3EE);
    case 'background':
      return const Color(0xFF818CF8);
    case 'system':
      return const Color(0xFFC5A04D);
    case 'hub':
      return const Color(0xFF22D3EE);
    case 'transport':
      return const Color(0xFF34D399);
    case 'feature':
      return const Color(0xFFF472B6);
    case 'group':
      return const Color(0xFFFBBF24);
    default:
      return const Color(0xFF94A3B8);
  }
}

class SystemMapWidget extends StatelessWidget {
  const SystemMapWidget({super.key, required this.map});

  final SystemMap map;

  @override
  Widget build(BuildContext context) {
    if (!map.hasAppNodes) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'No app is using data right now — the map appears when a '
            'poll shows a live rate.',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 300,
          width: double.infinity,
          child: CustomPaint(painter: _MapPainter(map: map)),
        ),
        const SizedBox(height: 8),
        const Text(
          'How to read this map — and what it does NOT show',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Centre: this device (battery shown at device level only). '
          'Ring: apps with a live rate right now — bigger = faster '
          'right now. Lines: app → Mobile / Wi-Fi means that app has '
          'measured totals on that transport; app → a feature means '
          'AppOps reported that feature allowed for the app; app → '
          '"Same app group" means the apps share one UID. There are '
          'NO lines between apps claiming they share data with each '
          'other: Android does not expose real-time inter-app data '
          'sharing, so MyMy does not draw it. Badges mean recent '
          'usage-stats activity, not a complete live process list, '
          'and foreground time is never labelled as battery use.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: const [
            _MapLegendDot(colorKey: 'foreground', label: 'Foreground now'),
            _MapLegendDot(colorKey: 'background', label: 'Background recently'),
            _MapLegendDot(colorKey: 'system', label: 'System app'),
            _MapLegendDot(colorKey: 'unknown', label: 'State unknown'),
            _MapLegendDot(colorKey: 'transport', label: 'Transport'),
            _MapLegendDot(colorKey: 'feature', label: 'Phone feature'),
            _MapLegendDot(colorKey: 'group', label: 'Shared UID group'),
          ],
        ),
      ],
    );
  }
}

class _MapLegendDot extends StatelessWidget {
  const _MapLegendDot({required this.colorKey, required this.label});

  final String colorKey;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: _colorFor(colorKey),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter({required this.map});

  final SystemMap map;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final appNodes = map.nodes
        .where((n) => n.kind == MapNodeKind.app)
        .toList();
    final outerNodes = map.nodes
        .where((n) =>
            n.kind == MapNodeKind.transport ||
            n.kind == MapNodeKind.feature ||
            n.kind == MapNodeKind.appGroup)
        .toList();
    final hub = map.nodes.firstWhere(
      (n) => n.kind == MapNodeKind.hub,
      orElse: () => map.nodes.first,
    );
    final positions = <String, Offset>{};
    positions[hub.id] = center;
    final innerR = math.min(size.width, size.height) * 0.30;
    for (var i = 0; i < appNodes.length; i++) {
      final angle = (2 * math.pi * i / appNodes.length) - math.pi / 2;
      positions[appNodes[i].id] = center +
          Offset(math.cos(angle) * innerR, math.sin(angle) * innerR);
    }
    final outerR = math.min(size.width, size.height) * 0.46;
    for (var i = 0; i < outerNodes.length; i++) {
      final angle =
          (2 * math.pi * i / math.max(outerNodes.length, 1)) - math.pi / 2;
      positions[outerNodes[i].id] = center +
          Offset(math.cos(angle) * outerR, math.sin(angle) * outerR);
    }

    // Edges first, under the nodes.
    final edgePaint = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..strokeWidth = 1.2;
    for (final edge in map.edges) {
      final from = positions[edge.fromId];
      final to = positions[edge.toId];
      if (from == null || to == null) continue;
      canvas.drawLine(from, to, edgePaint);
    }

    // Nodes: hub + ring nodes, with short labels underneath.
    void drawNode(MapNode node) {
      final pos = positions[node.id];
      if (pos == null) return;
      final radius = node.kind == MapNodeKind.hub
          ? 30.0
          : 12 + node.sizeFactor * 14;
      canvas.drawCircle(pos, radius, Paint()..color = _colorFor(node.colorKey));
      canvas.drawCircle(
        pos,
        radius,
        Paint()
          ..color = Colors.white.withOpacity(0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final label = node.label.length > 12
          ? '${node.label.substring(0, 11)}…'
          : node.label;
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 90);
      painter.paint(
        canvas,
        Offset(pos.dx - painter.width / 2, pos.dy + radius + 2),
      );
    }

    for (final node in map.nodes) {
      drawNode(node);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) => old.map != map;
}
