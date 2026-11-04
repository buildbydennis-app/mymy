import 'dart:math' as math;

import 'all_apps.dart';
import 'app_info.dart';

/// Phase 5 — the Live System Map ("neural link" graph), built ONLY
/// from observable signals.
///
/// THE BOUNDARY, in plain language (also in BUILD_PLAN and README):
/// Android does not expose real-time inter-app data sharing to an
/// ordinary app. So this map NEVER draws an app-to-app "data sharing"
/// edge. The only edges that exist are:
///
/// 1. App -> Mobile / Wi-Fi: the app's own per-transport totals from
///    NetworkStatsManager (mobile split known and > 0, or derived
///    Wi-Fi bytes > 0). No split signal means no edge, never a guess.
/// 2. App -> phone feature: AppOpsManager actually reported that op
///    as allowed for that package (Camera, Microphone, Fine
///    location). No signal means no badge and no edge.
/// 3. App -> app-group node: two or more installed packages share one
///    Linux UID (verifiable from PackageManager). The group node is
///    labelled "same app group (shared UID)" — it is a packaging
///    fact, not a claim that the apps exchange data.
///
/// Battery appears only as a device-level node label (from
/// BatteryManager), never per app. Foreground minutes from
/// UsageStats are labelled "foreground time", never "battery use".
///
/// Node size scales with live rate (square-root scale, floored so a
/// zero-rate app with data today is still visible). Colour encodes
/// state: foreground = cyan, background/recent = indigo, system =
/// gold, unknown = grey. The UI legend must state all of this.

enum MapNodeKind { hub, app, transport, feature, appGroup }

enum MapEdgeKind { transport, feature, sharedUid }

class MapNode {
  const MapNode({
    required this.id,
    required this.label,
    required this.kind,
    required this.sizeFactor,
    required this.colorKey,
    this.subtitle = '',
  });

  final String id;
  final String label;
  final MapNodeKind kind;

  /// 0.0–1.0, drives drawn radius. Hub is always 1.0.
  final double sizeFactor;

  /// 'foreground' | 'background' | 'system' | 'unknown' | 'hub' |
  /// 'transport' | 'feature' | 'group'.
  final String colorKey;
  final String subtitle;
}

class MapEdge {
  const MapEdge({
    required this.fromId,
    required this.toId,
    required this.kind,
    required this.label,
  });

  final String fromId;
  final String toId;
  final MapEdgeKind kind;
  final String label;
}

class SystemMap {
  const SystemMap({required this.nodes, required this.edges});

  final List<MapNode> nodes;
  final List<MapEdge> edges;

  /// The map is empty of apps when no app has a live rate and no app
  /// has data today — the widget then shows "No data yet".
  bool get hasAppNodes =>
      nodes.any((n) => n.kind == MapNodeKind.app);
}

String _colorKeyFor(MergedApp app, String badge) {
  if (app.isSystem) return 'system';
  if (badge == 'Foreground now') return 'foreground';
  if (badge == 'Background recently') return 'background';
  return 'unknown';
}

/// Builds the map from merged apps.
///
/// [mobileBytesOf] / [wifiBytesOf] give an app's per-transport bytes,
/// or -1 when unknown (the transport edge is then omitted). In the
/// dashboard these come from AppUsage.mobileBytes / wifiBytes, which
/// are only present on Android polling snapshots with a measured
/// mobile split; Windows and VPN snapshots pass -1, so they get no
/// transport edges — honestly, not wrongly.
/// [installed] is the installed list (for shared-UID grouping); it
/// may be empty on Windows, in which case no group nodes are made.
/// [rateOf] gives the app's live rate for node sizing.
SystemMap buildSystemMap({
  required List<MergedApp> apps,
  required Map<String, InstalledApp> installedById,
  required int Function(MergedApp app) mobileBytesOf,
  required int Function(MergedApp app) wifiBytesOf,
  required double Function(MergedApp app) rateOf,
  required DateTime now,
  DeviceBattery? battery,
}) {
  // Only apps actually using data right now appear as live nodes;
  // a zero-rate app with data today is not "live" on the map.
  final live = apps.where((a) => rateOf(a) > 0).toList();
  final nodes = <MapNode>[
    MapNode(
      id: 'device',
      label: 'This device',
      kind: MapNodeKind.hub,
      sizeFactor: 1,
      colorKey: 'hub',
      subtitle: battery == null || battery.levelPercent < 0
          ? 'Battery: unknown'
          : 'Battery: ${battery.levelPercent}%'
              '${battery.charging ? ' (charging)' : ''}',
    ),
  ];
  final edges = <MapEdge>[];
  var maxRate = 0.0;
  for (final app in live) {
    if (rateOf(app) > maxRate) maxRate = rateOf(app);
  }
  if (maxRate <= 0) maxRate = 1;

  final transportNodes = <String>{};
  final featureNodes = <String>{};
  for (final app in live) {
    final badge = activityBadge(app, now: now);
    // Square-root scale: rate differences stay visible without a
    // single heavy app dwarfing every other node to a dot.
    final sqrtSize = 0.35 + 0.65 * math.sqrt(rateOf(app) / maxRate);
    nodes.add(
      MapNode(
        id: 'app:${app.id}',
        label: app.name,
        kind: MapNodeKind.app,
        sizeFactor: sqrtSize,
        colorKey: _colorKeyFor(app, badge),
        subtitle: badge,
      ),
    );
    final mobile = mobileBytesOf(app);
    if (mobile > 0) {
      if (transportNodes.add('Mobile')) {
        nodes.add(
          const MapNode(
            id: 'transport:Mobile',
            label: 'Mobile',
            kind: MapNodeKind.transport,
            sizeFactor: 0.6,
            colorKey: 'transport',
            subtitle: 'Mobile data totals',
          ),
        );
      }
      edges.add(
        MapEdge(
          fromId: 'app:${app.id}',
          toId: 'transport:Mobile',
          kind: MapEdgeKind.transport,
          label: 'Mobile data',
        ),
      );
    }
    final wifi = wifiBytesOf(app);
    if (wifi > 0) {
      if (transportNodes.add('Wi-Fi')) {
        nodes.add(
          const MapNode(
            id: 'transport:Wi-Fi',
            label: 'Wi-Fi',
            kind: MapNodeKind.transport,
            sizeFactor: 0.6,
            colorKey: 'transport',
            subtitle: 'Wi-Fi / other totals',
          ),
        );
      }
      edges.add(
        MapEdge(
          fromId: 'app:${app.id}',
          toId: 'transport:Wi-Fi',
          kind: MapEdgeKind.transport,
          label: 'Wi-Fi data',
        ),
      );
    }
    final features = app.activity?.features ?? const <String>[];
    for (final feature in features) {
      final nodeId = 'feature:$feature';
      if (featureNodes.add(feature)) {
        nodes.add(
          MapNode(
            id: nodeId,
            label: feature,
            kind: MapNodeKind.feature,
            sizeFactor: 0.5,
            colorKey: 'feature',
            subtitle: 'Reported allowed by AppOps',
          ),
        );
      }
      edges.add(
        MapEdge(
          fromId: 'app:${app.id}',
          toId: nodeId,
          kind: MapEdgeKind.feature,
          label: 'Allowed: $feature',
        ),
      );
    }
  }

  // Shared-UID groups: only among installed packages that are live
  // nodes, and only when 2+ packages share one UID.
  final byUid = <int, List<InstalledApp>>{};
  for (final app in live) {
    final installed = installedById[app.id];
    if (installed == null || installed.uid < 0) continue;
    (byUid[installed.uid] ??= []).add(installed);
  }
  for (final entry in byUid.entries) {
    if (entry.value.length < 2) continue;
    final groupId = 'group:uid:${entry.key}';
    nodes.add(
      MapNode(
        id: groupId,
        label: 'Same app group',
        kind: MapNodeKind.appGroup,
        sizeFactor: 0.55,
        colorKey: 'group',
        subtitle: 'Shared UID ${entry.key}',
      ),
    );
    for (final installed in entry.value) {
      edges.add(
        MapEdge(
          fromId: 'app:${installed.packageName}',
          toId: groupId,
          kind: MapEdgeKind.sharedUid,
          label: 'Shared UID',
        ),
      );
    }
  }

  return SystemMap(nodes: nodes, edges: edges);
}
