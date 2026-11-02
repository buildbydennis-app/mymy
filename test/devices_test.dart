import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mymy/src/devices.dart';
import 'package:mymy/src/models.dart';

UsageSnapshot localSnapshot({
  int rx = 1000,
  int tx = 500,
  List<AppUsage> apps = const [],
  List<LiveConnection> connections = const [],
}) =>
    UsageSnapshot(
      timestamp: DateTime(2026, 11, 2, 12, 0),
      totalRxBytes: rx,
      totalTxBytes: tx,
      mobileRxBytes: 400,
      mobileTxBytes: 200,
      apps: apps,
      connections: connections,
    );

void main() {
  group('Share payload allowlist — nothing else may leave the device', () {
    test('toShareJson keys are exactly the allowlist', () {
      final shared = RemoteDeviceSnapshot.fromLocal(
        localSnapshot(
          apps: const [AppUsage(id: 'com.example', name: 'Example', rxBytes: 10, txBytes: 5)],
          connections: const [
            LiveConnection(processName: 'chrome.exe', pid: 1, remote: '93.184.216.34:443'),
          ],
        ),
        deviceLabel: 'Laptop',
        todayRxBytes: 900,
        todayTxBytes: 450,
      );
      final json = shared.toShareJson();
      expect(
        json.keys.toSet(),
        {
          'deviceLabel',
          'timestampMs',
          'totalRx',
          'totalTx',
          'mobileRx',
          'mobileTx',
          'todayRx',
          'todayTx',
          'apps',
        },
      );
      expect(json.containsKey('connections'), isFalse);
      expect(jsonEncode(json).contains('93.184.216.34'), isFalse);
      final appJson = (json['apps'] as List).first as Map;
      expect(appJson.keys.toSet(), {'id', 'name', 'rx', 'tx'});
    });

    test('fromShareJson strips any connections field in a payload', () {
      final parsed = RemoteDeviceSnapshot.fromShareJson({
        'deviceLabel': 'Phone',
        'timestampMs': 1000,
        'totalRx': 10,
        'totalTx': 5,
        'mobileRx': -1,
        'mobileTx': -1,
        'apps': [],
        'connections': [
          {'process': 'x', 'pid': 1, 'remote': '1.2.3.4:80'},
        ],
        'urls': ['https://example.com'],
      });
      expect(parsed.toUsageSnapshot().connections, isEmpty);
      expect(parsed.toUsageSnapshot().source, 'remote');
    });

    test('today fields are optional and absent means unknown, not zero', () {
      final parsed = RemoteDeviceSnapshot.fromShareJson({
        'deviceLabel': 'Phone',
        'timestampMs': 1000,
        'totalRx': 10,
        'totalTx': 5,
        'apps': [],
      });
      expect(parsed.todayRxBytes, isNull);
      expect(parsed.mobileRxBytes, -1);
    });
  });

  group('Pairing PIN', () {
    test('generated PIN is 6 digits', () {
      final pin = PinManager.generate();
      expect(RegExp(r'^\d{6}$').hasMatch(pin.pin), isTrue);
    });

    test('correct PIN validates once, then is consumed', () {
      final manager = PinManager.generate();
      final now = DateTime.now();
      expect(manager.tryPin(manager.pin, now), isTrue);
      expect(manager.tryPin(manager.pin, now), isFalse);
    });

    test('PIN expires after 2 minutes', () {
      final start = DateTime(2026, 11, 2, 12, 0);
      final manager = PinManager.generate(now: start);
      expect(
        manager.tryPin(manager.pin, start.add(const Duration(minutes: 2, seconds: 1))),
        isFalse,
      );
    });

    test('5 failed attempts lock the PIN even for the correct digits', () {
      final manager = PinManager.generate();
      final now = DateTime.now();
      for (var i = 0; i < 5; i++) {
        expect(manager.tryPin('000000', now), isFalse);
      }
      expect(manager.isLocked, isTrue);
      expect(manager.tryPin(manager.pin, now), isFalse);
    });
  });

  group('Bearer token', () {
    test('is 43 base64url chars (256 bits) and unique', () {
      final a = generateBearerToken();
      final b = generateBearerToken();
      expect(a.length, 43);
      expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(a), isTrue);
      expect(a, isNot(equals(b)));
    });
  });

  group('Pairing payload', () {
    test('round-trips, and a label with | is sanitised', () {
      final payload = PairingPayload(
        host: '192.168.1.10',
        port: 48123,
        pin: '123456',
        label: 'My | Laptop',
      ).encode();
      final parsed = PairingPayload.parse(payload);
      expect(parsed.host, '192.168.1.10');
      expect(parsed.port, 48123);
      expect(parsed.pin, '123456');
      expect(parsed.label, 'My   Laptop');
    });

    test('malformed payloads throw', () {
      expect(() => PairingPayload.parse('hello'), throwsFormatException);
      expect(() => PairingPayload.parse('MYMY|v1|host|abc|123456|L'), throwsFormatException);
      expect(() => PairingPayload.parse('MYMY|v1|host|48123|123456'), throwsFormatException);
    });
  });

  group('LAN address picking', () {
    test('prefers private ranges over public, never loopback', () {
      expect(pickLanAddress(['127.0.0.1', '8.8.8.8', '192.168.1.5']), '192.168.1.5');
      expect(pickLanAddress(['10.0.0.2', '172.16.0.9']), '10.0.0.2');
      expect(pickLanAddress(['127.0.0.1']), isNull);
      expect(pickLanAddress([]), isNull);
    });
  });

  group('Remote rates and stale detection', () {
    RemoteDeviceSnapshot remoteAt(int seconds, int rx, int tx) =>
        RemoteDeviceSnapshot(
          deviceLabel: 'Laptop',
          timestamp: DateTime(2026, 11, 2, 12, 0, seconds),
          totalRxBytes: rx,
          totalTxBytes: tx,
          mobileRxBytes: -1,
          mobileTxBytes: -1,
          todayRxBytes: null,
          todayTxBytes: null,
          apps: const [],
        );

    test('remote rates derive from successive remote snapshots', () async {
      final device = PairedDevice(id: 'h:1', label: 'Laptop', host: 'h', port: 1, token: 't');
      final fetcher = FakeRemoteFetcher(snapshots: [remoteAt(0, 1000, 500), remoteAt(10, 3000, 1000)]);
      final poller = RemoteDevicePoller(device);
      await poller.poll(fetcher, DateTime(2026, 11, 2, 12, 0));
      final live = await poller.poll(fetcher, DateTime(2026, 11, 2, 12, 0, 10));
      expect(live.rxBytesPerSecond, 200);
      expect(live.txBytesPerSecond, 50);
      expect(poller.statusAt(DateTime(2026, 11, 2, 12, 0, 10)), 'Online');
    });

    test('counter reset on remote clamps to zero, never negative', () async {
      final device = PairedDevice(id: 'h:1', label: 'Laptop', host: 'h', port: 1, token: 't');
      final fetcher = FakeRemoteFetcher(snapshots: [remoteAt(0, 5000, 5000), remoteAt(10, 100, 100)]);
      final poller = RemoteDevicePoller(device);
      await poller.poll(fetcher, DateTime(2026, 11, 2, 12, 0));
      final live = await poller.poll(fetcher, DateTime(2026, 11, 2, 12, 0, 10));
      expect(live.rxBytesPerSecond, 0);
      expect(live.txBytesPerSecond, 0);
    });

    test('failed poll after 15s is Stale with zero rates; never answered is Offline', () async {
      final device = PairedDevice(id: 'h:1', label: 'Laptop', host: 'h', port: 1, token: 't');
      final poller = RemoteDevicePoller(device);
      final live = await poller.poll(
        FakeRemoteFetcher(fetchFails: true),
        DateTime(2026, 11, 2, 12, 0),
      );
      expect(live.rxBytesPerSecond, 0);
      expect(poller.statusAt(DateTime(2026, 11, 2, 12, 0)), 'Offline');

      final okFetcher = FakeRemoteFetcher(snapshots: [remoteAt(0, 1000, 500)]);
      await poller.poll(okFetcher, DateTime(2026, 11, 2, 12, 0));
      final stale = await poller.poll(
        FakeRemoteFetcher(fetchFails: true),
        DateTime(2026, 11, 2, 12, 0, 20),
      );
      expect(stale.rxBytesPerSecond, 0);
      expect(poller.statusAt(DateTime(2026, 11, 2, 12, 0, 20)), 'Stale');
      expect(poller.lastSeen, DateTime(2026, 11, 2, 12, 0));
    });

    test('remote snapshots never mix into local history source values', () {
      final remote = remoteAt(0, 1000, 500);
      expect(remote.toUsageSnapshot().source, 'remote');
      expect(remote.toUsageSnapshot().source, isNot(equals('polling')));
      expect(remote.toUsageSnapshot().source, isNot(equals('vpn')));
    });
  });

  group('Host server over loopback (Dart-level pairing proof)', () {
    test('pair once, fetch with token, 401 without, 403 on reused PIN', () async {
      final server = LanHostServer(
        snapshotProvider: () async => localSnapshot(
          rx: 777,
          tx: 333,
          apps: const [AppUsage(id: 'a', name: 'App', rxBytes: 10, txBytes: 5)],
          connections: const [LiveConnection(processName: 'p', pid: 1, remote: '9.9.9.9:443')],
        ),
        todayProvider: () async => (rx: 700, tx: 300),
        deviceLabel: 'Test host',
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await server.start();
      addTearDown(server.stop);
      final pin = server.pin;
      final parts = server.endpoint.split(':');
      final port = int.parse(parts.last);

      final client = HttpClient();
      addTearDown(client.close);
      Future<HttpClientResponse> postPair(String attempt) async {
        final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/pair'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'pin': attempt}));
        return req.close();
      }

      // No token -> 401.
      final noAuth = await client.getUrl(Uri.parse('http://127.0.0.1:$port/snapshot'));
      final noAuthResp = await noAuth.close();
      expect(noAuthResp.statusCode, HttpStatus.unauthorized);
      await noAuthResp.drain<void>();

      // Wrong PIN -> 403.
      final wrong = await postPair('000000');
      expect(wrong.statusCode, HttpStatus.forbidden);
      await wrong.drain<void>();

      // Correct PIN -> token, once.
      final ok = await postPair(pin);
      expect(ok.statusCode, HttpStatus.ok);
      final token = (jsonDecode(await utf8.decoder.bind(ok).join()) as Map)['token'] as String;
      expect(token.length, 43);

      // Reused PIN -> 403 (single-use).
      final reused = await postPair(pin);
      expect(reused.statusCode, HttpStatus.forbidden);
      await reused.drain<void>();

      // Fetch with token -> sanitised payload only.
      final getReq = await client.getUrl(Uri.parse('http://127.0.0.1:$port/snapshot'));
      getReq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final getResp = await getReq.close();
      expect(getResp.statusCode, HttpStatus.ok);
      final payload = jsonDecode(await utf8.decoder.bind(getResp).join()) as Map<String, dynamic>;
      expect(payload['totalRx'], 777);
      expect(payload['todayRx'], 700);
      expect(payload.containsKey('connections'), isFalse);
      expect(jsonEncode(payload).contains('9.9.9.9'), isFalse);
      expect(payload['deviceLabel'], 'Test host');

      // Stop revokes: old token no longer works on a restarted server
      // (a fresh server instance has a fresh token; here we assert the
      // stopped server simply stops answering).
      await server.stop();
      expect(
        () async {
          final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/snapshot'));
          await req.close().timeout(const Duration(seconds: 2));
        },
        throwsA(anything),
      );
    });
  });
}
