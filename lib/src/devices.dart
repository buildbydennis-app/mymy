import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'usage_service.dart';

/// Phase 4 — optional local-LAN cross-device view.
///
/// Privacy contract, enforced by construction, not by convention:
/// - What is shared: device totals + per-app bytes only.
/// - What is NEVER shared: traffic content, URLs, hostnames, DNS
///   names, browsing history, or connection remotes. The share
///   payload ([RemoteDeviceSnapshot.toShareJson]) is an allowlist:
///   anything not in that list cannot leave the device, because it
///   is never serialised. In particular, [UsageSnapshot.connections]
///   are dropped before sending — a remote device's connections
///   list is never transmitted, even if the local snapshot has one.
/// - No cloud, no account. Sharing happens only between two devices
///   the user explicitly pairs, on the same trusted LAN, while both
///   opt in. Either side can revoke at any time (see below).
/// - Security is LAN + bearer token ONLY. There is no TLS layer in
///   Phase 4, and no claim of end-to-end encryption is made anywhere:
///   a bearer token sent over plain HTTP on a LAN can be observed
///   by anyone else on that LAN. Do NOT pair on untrusted or public
///   Wi-Fi. The token must be treated like a password for the LAN.
/// - The bearer token is stored in app-private SharedPreferences
///   (not encrypted at rest). That is a known limitation of Phase 4:
///   it is acceptable only because the token is LAN-scoped and
///   revocable (host regenerates it), never a cloud credential.

/// A sanitised snapshot from a remote device.
///
/// Built only from [RemoteDeviceSnapshot.toShareJson] / fromShareJson,
/// so a remote snapshot can never carry connections, remotes, URLs,
/// or history fields into this device.
class RemoteDeviceSnapshot {
  const RemoteDeviceSnapshot({
    required this.deviceLabel,
    required this.timestamp,
    required this.totalRxBytes,
    required this.totalTxBytes,
    required this.mobileRxBytes,
    required this.mobileTxBytes,
    required this.todayRxBytes,
    required this.todayTxBytes,
    required this.apps,
  });

  final String deviceLabel;
  final DateTime timestamp;
  final int totalRxBytes;
  final int totalTxBytes;

  /// -1 when the remote device cannot split mobile vs Wi-Fi.
  final int mobileRxBytes;
  final int mobileTxBytes;

  /// Recorded-today totals from the remote device's own history
  /// store, or null when that device has none to report. These are
  /// the remote device's recorded totals, NOT this device's history,
  /// and they are never written into this device's history store.
  final int? todayRxBytes;
  final int? todayTxBytes;
  final List<AppUsage> apps;

  int get totalBytes => totalRxBytes + totalTxBytes;

  /// The ONLY serialisation that may leave the device. Allowlisted
  /// keys only — see the file header for what is deliberately absent.
  Map<String, dynamic> toShareJson() => {
        'deviceLabel': deviceLabel,
        'timestampMs': timestamp.millisecondsSinceEpoch,
        'totalRx': totalRxBytes,
        'totalTx': totalTxBytes,
        'mobileRx': mobileRxBytes,
        'mobileTx': mobileTxBytes,
        if (todayRxBytes != null) 'todayRx': todayRxBytes,
        if (todayTxBytes != null) 'todayTx': todayTxBytes,
        'apps': [
          for (final a in apps)
            {'id': a.id, 'name': a.name, 'rx': a.rxBytes, 'tx': a.txBytes},
        ],
      };

  factory RemoteDeviceSnapshot.fromShareJson(Map<String, dynamic> json) {
    final appsJson = json['apps'] as List<dynamic>? ?? const [];
    return RemoteDeviceSnapshot(
      deviceLabel: json['deviceLabel'] as String? ?? 'Remote device',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['timestampMs'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      totalRxBytes: (json['totalRx'] as num?)?.toInt() ?? 0,
      totalTxBytes: (json['totalTx'] as num?)?.toInt() ?? 0,
      mobileRxBytes: (json['mobileRx'] as num?)?.toInt() ?? -1,
      mobileTxBytes: (json['mobileTx'] as num?)?.toInt() ?? -1,
      todayRxBytes: (json['todayRx'] as num?)?.toInt(),
      todayTxBytes: (json['todayTx'] as num?)?.toInt(),
      // Any 'connections' key in the payload is ignored here on
      // purpose: it can never reach the UI or history as a remote
      // connection list.
      apps: appsJson
          .whereType<Map>()
          .map((e) => AppUsage.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  factory RemoteDeviceSnapshot.fromLocal(
    UsageSnapshot snapshot, {
    required String deviceLabel,
    int? todayRxBytes,
    int? todayTxBytes,
  }) =>
      RemoteDeviceSnapshot(
        deviceLabel: deviceLabel,
        timestamp: snapshot.timestamp,
        totalRxBytes: snapshot.totalRxBytes,
        totalTxBytes: snapshot.totalTxBytes,
        mobileRxBytes: snapshot.mobileRxBytes,
        mobileTxBytes: snapshot.mobileTxBytes,
        todayRxBytes: todayRxBytes,
        todayTxBytes: todayTxBytes,
        apps: snapshot.apps,
      );

  /// Converts to a [UsageSnapshot] for the shared rate maths
  /// ([UsageService.calculate]). Connections are always empty and
  /// source is always 'remote', so remote snapshots can never be
  /// mistaken for local polling/VPN snapshots in history.
  UsageSnapshot toUsageSnapshot() => UsageSnapshot(
        timestamp: timestamp,
        totalRxBytes: totalRxBytes,
        totalTxBytes: totalTxBytes,
        mobileRxBytes: mobileRxBytes,
        mobileTxBytes: mobileTxBytes,
        apps: apps,
        connections: const [],
        source: 'remote',
      );
}

/// One-time pairing PIN.
///
/// - 6 digits, generated with [Random.secure].
/// - Expires 2 minutes after creation.
/// - Single-use: a successful validation consumes it.
/// - Rate-limited: 5 failed attempts lock it until a new PIN is
///   generated. A locked or expired PIN never validates, even with
///   the correct digits.
class PinManager {
  PinManager._(this.pin, this.createdAt);

  final String pin;
  final DateTime createdAt;
  int _attempts = 0;
  bool _used = false;

  static const validity = Duration(minutes: 2);
  static const maxAttempts = 5;

  factory PinManager.generate({Random? random, DateTime? now}) {
    final r = random ?? Random.secure();
    final digits = r.nextInt(1000000).toString().padLeft(6, '0');
    return PinManager._(digits, now ?? DateTime.now());
  }

  bool get isUsed => _used;
  int get attempts => _attempts;

  bool isExpired(DateTime now) =>
      now.difference(createdAt) >= validity;

  bool get isLocked => _attempts >= maxAttempts;

  bool get isUsableNow => !_used && !isLocked && !isExpired(DateTime.now());

  /// Returns true only on a first, in-time, correct attempt. Every
  /// call counts as an attempt, including successful ones.
  bool tryPin(String attempt, DateTime now) {
    if (_used || isLocked || isExpired(now)) return false;
    _attempts++;
    if (attempt.trim() == pin) {
      _used = true;
      return true;
    }
    return false;
  }
}

/// A 256-bit bearer token, base64url without padding (43 chars).
/// Generated with [Random.secure]; two calls must never collide in
/// practice, and the token carries no meaning by itself — it is only
/// a LAN credential, revocable by regenerating it on the host.
String generateBearerToken({Random? random}) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => r.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// A device this device is paired with (guest side).
///
/// The token is stored in app-private preferences (see file header:
/// LAN-scoped and revocable, not encrypted at rest). The id is the
/// host address + port, so re-pairing the same host replaces the old
/// entry instead of duplicating it.
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.token,
  });

  final String id;
  final String label;
  final String host;
  final int port;
  final String token;

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        host: json['host'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 0,
        token: json['token'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'token': token,
      };

  PairedDevice renamed(String newLabel) => PairedDevice(
        id: id,
        label: newLabel,
        host: host,
        port: port,
        token: token,
      );
}

abstract class DevicesStore {
  Future<String?> getDeviceLabel();
  Future<void> setDeviceLabel(String label);
  Future<List<PairedDevice>> getPairedDevices();
  Future<void> savePairedDevice(PairedDevice device);
  Future<void> removePairedDevice(String id);
  Future<void> clearPairedDevices();
}

class PrefsDevicesStore implements DevicesStore {
  PrefsDevicesStore(this._prefs);

  final SharedPreferences _prefs;
  static const _labelKey = 'mymy_device_label';
  static const _pairedKey = 'mymy_paired_devices';

  static Future<PrefsDevicesStore> load() async =>
      PrefsDevicesStore(await SharedPreferences.getInstance());

  @override
  Future<String?> getDeviceLabel() async => _prefs.getString(_labelKey);

  @override
  Future<void> setDeviceLabel(String label) async {
    await _prefs.setString(_labelKey, label);
  }

  @override
  Future<List<PairedDevice>> getPairedDevices() async {
    final raw = _prefs.getString(_pairedKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => PairedDevice.fromJson(Map<String, dynamic>.from(e)))
          .where((d) => d.id.isNotEmpty && d.token.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> savePairedDevice(PairedDevice device) async {
    final current = await getPairedDevices();
    final next = [
      for (final d in current)
        if (d.id != device.id) d,
      device,
    ];
    await _prefs.setString(
      _pairedKey,
      jsonEncode([for (final d in next) d.toJson()]),
    );
  }

  @override
  Future<void> removePairedDevice(String id) async {
    final current = await getPairedDevices();
    final next = [for (final d in current) if (d.id != id) d];
    await _prefs.setString(
      _pairedKey,
      jsonEncode([for (final d in next) d.toJson()]),
    );
  }

  @override
  Future<void> clearPairedDevices() async {
    await _prefs.remove(_pairedKey);
  }
}

/// In-memory store for tests (and only for tests).
class InMemoryDevicesStore implements DevicesStore {
  String? _label;
  final List<PairedDevice> _paired = [];

  @override
  Future<String?> getDeviceLabel() async => _label;

  @override
  Future<void> setDeviceLabel(String label) async => _label = label;

  @override
  Future<List<PairedDevice>> getPairedDevices() async =>
      List<PairedDevice>.unmodifiable(_paired);

  @override
  Future<void> savePairedDevice(PairedDevice device) async {
    _paired.removeWhere((d) => d.id == device.id);
    _paired.add(device);
  }

  @override
  Future<void> removePairedDevice(String id) async {
    _paired.removeWhere((d) => d.id == id);
  }

  @override
  Future<void> clearPairedDevices() async => _paired.clear();
}

/// Default device label. Deliberately generic — it never contains a
/// personal identifier, a username, or a hostname. The user can edit
/// it on the Devices tab.
String defaultDeviceLabel() {
  if (Platform.isAndroid) return 'Android phone';
  if (Platform.isWindows) return 'Windows laptop';
  if (Platform.isMacOS) return 'Mac';
  if (Platform.isLinux) return 'Linux PC';
  return 'MyMy device';
}

/// Picks the LAN address from a list of IPv4 address strings.
///
/// Private LAN ranges first (192.168.x, 10.x, 172.16–31.x), then any
/// other non-loopback IPv4 address. Loopback (127.x) is never a LAN
/// address and is never returned here — loopback binding is only for
/// tests, which pass an explicit bind address to [LanHostServer].
String? pickLanAddress(List<String> candidates) {
  bool isPrivate(String ip) {
    if (ip.startsWith('192.168.')) return true;
    if (ip.startsWith('10.')) return true;
    final parts = ip.split('.');
    if (parts.length == 4 && parts[0] == '172') {
      final second = int.tryParse(parts[1]);
      if (second != null && second >= 16 && second <= 31) return true;
    }
    return false;
  }

  final usable = candidates
      .where((ip) => !ip.startsWith('127.') && ip.split('.').length == 4)
      .toList();
  for (final ip in usable) {
    if (isPrivate(ip)) return ip;
  }
  return usable.isEmpty ? null : usable.first;
}

/// Finds this device's LAN IPv4 address, or null when there is none
/// (e.g. no Wi-Fi / Ethernet connected). The host cannot start
/// without one — it fails visibly instead of binding to loopback
/// and pretending to be reachable.
Future<String?> findLanAddress() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    final candidates = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        candidates.add(address.address);
      }
    }
    return pickLanAddress(candidates);
  } catch (_) {
    return null;
  }
}

/// The QR / copyable pairing payload.
///
/// Format: `MYMY|v1|<host>|<port>|<pin>|<label>`. The label is
/// sanitised (no `|` or newlines) at creation so parsing is
/// unambiguous. The payload contains NO bearer token — the token is
/// only issued by the host after the PIN is accepted, so a
/// photographed QR code alone never grants access.
class PairingPayload {
  const PairingPayload({
    required this.host,
    required this.port,
    required this.pin,
    required this.label,
  });

  final String host;
  final int port;
  final String pin;
  final String label;

  static String sanitiseLabel(String label) =>
      label.replaceAll('|', ' ').replaceAll('\n', ' ').trim();

  String encode() =>
      'MYMY|v1|$host|$port|$pin|${sanitiseLabel(label)}';

  static PairingPayload parse(String text) {
    final parts = text.trim().split('|');
    if (parts.length != 6 || parts[0] != 'MYMY' || parts[1] != 'v1') {
      throw const FormatException(
        'Not a MyMy pairing code. Paste the full code from the host '
        'device, or enter host, port, and PIN manually.',
      );
    }
    final port = int.tryParse(parts[3]);
    if (parts[2].isEmpty || port == null || port <= 0 || port > 65535) {
      throw const FormatException('Pairing code has an invalid host or port.');
    }
    return PairingPayload(
      host: parts[2],
      port: port,
      pin: parts[4],
      label: parts[5],
    );
  }
}

/// The host side of pairing: a tiny LAN-only HTTP server.
///
/// Surface is deliberately minimal — exactly two endpoints:
/// - POST /pair {pin} → {token} on a valid, unused, in-time PIN,
///   otherwise 403. The PIN is consumed on success.
/// - GET /snapshot with `Authorization: Bearer <token>` →
///   [RemoteDeviceSnapshot.toShareJson]. Without a valid token: 401.
///   Every other path: 404.
///
/// The server binds to a LAN address only (never loopback in
/// production — tests pass an explicit loopback bind address). It
/// runs only while the user keeps hosting on in the Devices tab;
/// stopping it regenerates the bearer token, so every previously
/// issued guest token stops working immediately (host-side revoke).
class LanHostServer {
  LanHostServer({
    required this.snapshotProvider,
    this.todayProvider,
    required this.deviceLabel,
    this.bindAddress,
    this.port = 0,
    PinManager? pinManager,
    String? bearerToken,
  })  : _pinManager = pinManager ?? PinManager.generate(),
        _bearerToken = bearerToken ?? generateBearerToken();

  /// Returns the host's current local snapshot (totals + per-app).
  /// Connections in it are dropped by [RemoteDeviceSnapshot].
  final Future<UsageSnapshot> Function() snapshotProvider;

  /// Returns today's recorded totals from the host's history store,
  /// or null when unavailable. Recorded totals only, never invented.
  final Future<({int rx, int tx})?> Function()? todayProvider;
  final String deviceLabel;

  /// Explicit bind address. Null = discover the LAN address; a null
  /// discovery result makes [start] throw instead of binding to
  /// loopback and pretending to be reachable.
  final InternetAddress? bindAddress;
  final int port;

  PinManager _pinManager;
  String _bearerToken;
  HttpServer? _server;
  bool _running = false;

  bool get isRunning => _running;
  String get pin => _pinManager.pin;
  String get endpoint {
    final server = _server;
    if (server == null) throw StateError('Host server is not running');
    return 'http://${server.address.address}:${server.port}';
  }

  String get pairingPayload {
    final server = _server;
    if (server == null) throw StateError('Host server is not running');
    return PairingPayload(
      host: server.address.address,
      port: server.port,
      pin: _pinManager.pin,
      label: deviceLabel,
    ).encode();
  }

  DateTime get pinExpiresAt => _pinManager.createdAt.add(PinManager.validity);

  /// Generates a fresh PIN (previous PIN stops working). Use when
  /// the old PIN expired or was locked by failed attempts.
  void regeneratePin() {
    _pinManager = PinManager.generate();
  }

  Future<void> start() async {
    if (_running) return;
    InternetAddress address;
    if (bindAddress != null) {
      address = bindAddress!;
    } else {
      final lan = await findLanAddress();
      if (lan == null) {
        throw StateError(
          'No LAN address found. Connect this device to Wi-Fi or '
          'Ethernet, then try hosting again.',
        );
      }
      address = InternetAddress(lan);
    }
    final server = await HttpServer.bind(address, port);
    _server = server;
    _running = true;
    server.listen(_handleRequest);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'POST' && request.uri.path == '/pair') {
        await _handlePair(request);
      } else if (request.method == 'GET' &&
          request.uri.path == '/snapshot') {
        await _handleSnapshot(request);
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
        await request.response.close();
      }
    } catch (_) {
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('error');
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handlePair(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    String pin = '';
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      pin = json['pin'] as String? ?? '';
    } catch (_) {
      pin = '';
    }
    final response = request.response;
    if (_pinManager.tryPin(pin, DateTime.now())) {
      response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'token': _bearerToken}));
    } else {
      // Deliberately one status for wrong, expired, used, and
      // locked PINs: distinguishing them would give an attacker a
      // PIN oracle.
      response
        ..statusCode = HttpStatus.forbidden
        ..write('pairing failed');
    }
    await response.close();
  }

  Future<void> _handleSnapshot(HttpRequest request) async {
    final response = request.response;
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth != 'Bearer $_bearerToken') {
      response
        ..statusCode = HttpStatus.unauthorized
        ..write('unauthorized');
      await response.close();
      return;
    }
    final snapshot = await snapshotProvider();
    final today = await todayProvider?.call();
    final shared = RemoteDeviceSnapshot.fromLocal(
      snapshot,
      deviceLabel: deviceLabel,
      todayRxBytes: today?.rx,
      todayTxBytes: today?.tx,
    );
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(shared.toShareJson()));
    await response.close();
  }

  /// Stops the server AND revokes every issued guest token by
  /// regenerating the bearer token. A restarted server therefore
  /// requires fresh pairing — old guests do not silently reconnect.
  Future<void> stop() async {
    _running = false;
    _bearerToken = generateBearerToken();
    await _server?.close(force: true);
    _server = null;
  }
}

/// Guest-side network access to a paired host.
///
/// Kept behind an abstract class so tests and the UI can inject a
/// fake without touching the network.
abstract class RemoteFetcher {
  /// Exchanges a PIN for a bearer token. Throws on any failure.
  Future<String> pair({
    required String host,
    required int port,
    required String pin,
  });

  Future<RemoteDeviceSnapshot> fetch(PairedDevice device);
}

class HttpRemoteFetcher implements RemoteFetcher {
  /// No caller currently injects a client (the default constructs one
  /// per request); the parameter exists only so tests in this package
  /// could inject one later without changing the constructor shape.
  HttpRemoteFetcher({this._client});

  final HttpClient? _client;

  HttpClient _newClient() => _client ?? HttpClient();

  @override
  Future<String> pair({
    required String host,
    required int port,
    required String pin,
  }) async {
    final client = _newClient();
    try {
      final request = await client
          .postUrl(Uri.parse('http://$host:$port/pair'))
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'pin': pin}));
      final response = await request.close().timeout(
            const Duration(seconds: 5),
          );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
          'Pairing failed. Check the host, port, and PIN, and make '
          'sure the host is still showing a valid PIN.',
        );
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final token = json['token'] as String?;
      if (token == null || token.isEmpty) {
        throw StateError('Pairing failed: host returned no token.');
      }
      return token;
    } finally {
      if (_client == null) client.close();
    }
  }

  @override
  Future<RemoteDeviceSnapshot> fetch(PairedDevice device) async {
    final client = _newClient();
    try {
      final request = await client
          .getUrl(Uri.parse('http://${device.host}:${device.port}/snapshot'))
          .timeout(const Duration(seconds: 5));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${device.token}',
      );
      final response = await request.close().timeout(
            const Duration(seconds: 5),
          );
      if (response.statusCode == HttpStatus.unauthorized) {
        throw StateError(
          'Pairing revoked by the host. Remove this device and pair '
          'again to reconnect.',
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
          'Remote device returned ${response.statusCode}.',
        );
      }
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return RemoteDeviceSnapshot.fromShareJson(json);
    } finally {
      if (_client == null) client.close();
    }
  }
}

/// Fake fetcher for tests (and only for tests).
class FakeRemoteFetcher implements RemoteFetcher {
  FakeRemoteFetcher({
    this.pairToken = 'test-token',
    this.snapshots = const [],
    this.pairFails = false,
    this.fetchFails = false,
  });

  final String pairToken;
  final List<RemoteDeviceSnapshot> snapshots;
  final bool pairFails;
  final bool fetchFails;
  int _index = 0;

  @override
  Future<String> pair({
    required String host,
    required int port,
    required String pin,
  }) async {
    if (pairFails) throw StateError('Pairing failed (test).');
    return pairToken;
  }

  @override
  Future<RemoteDeviceSnapshot> fetch(PairedDevice device) async {
    if (fetchFails) throw StateError('Remote device unreachable (test).');
    if (snapshots.isEmpty) throw StateError('No test snapshots.');
    final snapshot = snapshots[_index];
    if (_index < snapshots.length - 1) _index++;
    return snapshot;
  }
}

/// Polling state for one remote device.
///
/// Rates use the shared [UsageService.calculate] maths over
/// successive remote snapshots (both timestamps come from the host,
/// so guest clock skew cannot invent a rate). A device that has not
/// answered successfully within [staleAfter] is Stale: its rates are
/// forced to 0 and the UI shows its last-seen time — never a frozen
/// rate presented as live, and never zeros presented as its usage.
/// A device that has never answered is Offline.
class RemoteDevicePoller {
  RemoteDevicePoller(this.device);

  final PairedDevice device;
  UsageSnapshot? _previous;
  RemoteDeviceSnapshot? _latest;
  DateTime? _lastSeen;
  String? _lastError;

  static const staleAfter = Duration(seconds: 15);

  RemoteDeviceSnapshot? get latest => _latest;
  DateTime? get lastSeen => _lastSeen;
  String? get lastError => _lastError;

  String statusAt(DateTime now) {
    if (_lastSeen == null) return 'Offline';
    if (now.difference(_lastSeen!) <= staleAfter) return 'Online';
    return 'Stale';
  }

  /// Polls once. Returns a [LiveUsage] for the remote device, or a
  /// zero-rate [LiveUsage] holding the last known snapshot when the
  /// poll failed (so the UI can keep showing last-seen data with a
  /// Stale label instead of crashing or blanking).
  Future<LiveUsage> poll(RemoteFetcher fetcher, DateTime now) async {
    try {
      final remote = await fetcher.fetch(device);
      final current = remote.toUsageSnapshot();
      final live = UsageService.calculate(_previous, current);
      _previous = current;
      _latest = remote;
      _lastSeen = now;
      _lastError = null;
      return live;
    } catch (e) {
      _lastError = e.toString();
      final last = _latest;
      if (last == null) {
        return LiveUsage(
          snapshot: UsageSnapshot(
            timestamp: now,
            totalRxBytes: 0,
            totalTxBytes: 0,
            mobileRxBytes: -1,
            mobileTxBytes: -1,
            apps: const [],
            connections: const [],
            source: 'remote',
          ),
          rxBytesPerSecond: 0,
          txBytesPerSecond: 0,
          appRates: const {},
        );
      }
      return LiveUsage(
        snapshot: last.toUsageSnapshot(),
        rxBytesPerSecond: 0,
        txBytesPerSecond: 0,
        appRates: const {},
      );
    }
  }
}
