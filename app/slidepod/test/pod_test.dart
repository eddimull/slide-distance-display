import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slidepod/pod_info.dart';
import 'package:slidepod/pod_sheet.dart';
import 'package:slidepod/slidepod_ble.dart';

import 'account_test.dart' show account, signedIn;

ScanResult scan(
  String id, {
  String name = '',
  List<int>? serial,
  int rssi = -70,
}) => ScanResult(
  device: BluetoothDevice.fromId(id),
  advertisementData: AdvertisementData(
    advName: name,
    txPowerLevel: null,
    appearance: null,
    connectable: true,
    manufacturerData: {podCompanyId: ?serial},
    serviceData: const {},
    serviceUuids: const [],
  ),
  rssi: rssi,
  timeStamp: DateTime(2026),
);

/// A connected pod with no timers (the mock's 50 Hz stream never settles).
class _FakePod implements SlidePodSource {
  PodInfo _pod = const PodInfo(
    serial: '000000000000',
    name: 'Mock pod',
    firmware: 'mock',
    hardware: 0,
  );
  int blinks = 0;

  @override
  PodInfo? get pod => _pod;
  @override
  Future<void> rename(String name) async {
    final problem = podNameProblem(name);
    if (problem != null) throw ArgumentError(problem);
    _pod = _pod.withName(name);
  }

  @override
  Future<void> blink() async => blinks++;
  @override
  PodPower? get power => null;
  @override
  Stream<PodPower?> get powerStream => const Stream.empty();
  @override
  bool get connected => true;
  @override
  bool get isMock => true;
  @override
  Stream<SlideData> get dataStream => const Stream.empty();
  @override
  Stream<bool> get connectionStream => const Stream.empty();
  @override
  Future<void> connectFirst() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> setLed((int, int, int)? rgb) async {}
  @override
  void dispose() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('identity', () {
    test('the serial comes from the advert, in the order sent', () {
      expect(
        serialFromAdvert({
          podCompanyId: [0x7C, 0xDF, 0xA1, 0xE2, 0x3F, 0x2A],
        }),
        '7CDFA1E23F2A',
      );
      expect(serialFromAdvert({}), isNull);
      expect(
        serialFromAdvert({
          podCompanyId: [1, 2, 3],
        }),
        isNull,
      );
      expect(shortCode('7CDFA1E23F2A'), '3F2A');
    });

    test('the info characteristic', () {
      final info = PodInfo.fromInfo(
        utf8.encode('{"serial":"7cdfa1e23f2a","fw":"0.3.0","hw":2}'),
        'Bass pod',
      )!;
      expect(info.serial, '7CDFA1E23F2A');
      expect(info.firmware, '0.3.0');
      expect(info.hardware, 2);
      expect(info.code, '3F2A');
      expect(PodInfo.fromInfo(utf8.encode('nope'), 'x'), isNull);
      expect(PodInfo.fromInfo(utf8.encode('{"serial":"12"}'), 'x'), isNull);
    });

    test('names follow the pod\'s rule: 1–20 bytes of UTF-8', () {
      expect(podNameProblem('Bass pod'), isNull);
      expect(podNameProblem('♭' * 6), isNull); // 18 bytes
      expect(podNameProblem('♭' * 7), isNotNull); // 21 bytes
      expect(podNameProblem('   '), isNotNull);
      expect(podNameProblem('tab\there'), isNotNull);
    });

    test('battery', () {
      final p = PodPower.fromBytes([72, 0, 0x78, 0x0F])!;
      expect((p.percent, p.usb, p.millivolts, p.label), (72, false, 3960, '72\u00A0%'));
      expect(PodPower.fromBytes([64, 1, 0, 0])!.label, 'Charging, 64\u00A0%');
      expect(PodPower.fromBytes([100, 3, 0, 0])!.label, 'Charged');
      expect(PodPower.fromBytes([0xFF, 1, 0, 0])!.label, 'Charging');
      expect(PodPower.fromBytes([0xFF, 0, 0, 0])!.percent, isNull);
      expect(PodPower.fromBytes([10, 0, 0, 0])!.low, isTrue);
      expect(PodPower.fromBytes([10, 1, 0, 0])!.low, isFalse);
      expect(PodPower.fromBytes([1, 2]), isNull);
    });

    test('older firmware advertises only "SlidePod"', () {
      final r = scan('a');
      expect(SlidePodBle.advertisedName(r), 'SlidePod');
      expect(SlidePodBle.advertisedSerial(r), isNull);
    });
  });

  group('picker', () {
    final near = FoundPod.of(
      scan(
        'a',
        name: 'SlidePod 1111',
        serial: [0, 0, 0, 0, 0x11, 0x11],
        rssi: -50,
      ),
    );
    final mine = FoundPod.of(
      scan('b', name: 'Bass pod', serial: [0, 0, 0, 0, 0x22, 0x22], rssi: -80),
    );
    final last = FoundPod.of(
      scan(
        'c',
        name: 'SlidePod 3333',
        serial: [0, 0, 0, 0, 0x33, 0x33],
        rssi: -90,
      ),
    );
    final old = FoundPod.of(scan('d', rssi: -40));

    test('last used, then yours, then nearest first', () {
      final sorted = sortPods(
        [near, mine, last, old],
        lastSerial: '000000003333',
        isMine: (s) => s == '000000002222',
      );
      expect(sorted.map((p) => p.name), [
        'SlidePod 3333',
        'Bass pod',
        'SlidePod',
        'SlidePod 1111',
      ]);
    });

    test('signal bars', () {
      expect([-45, -65, -75, -95].map(signalBars), [4, 3, 2, 1]);
    });

    testWidgets('rows say which is which', (tester) async {
      BluetoothDevice? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => picked = await showPodPicker(ctx, [
                near,
                mine,
              ], isMine: (s) => s == '000000002222'),
              child: const Text('scan'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('scan'));
      await tester.pumpAndSettle();
      // The default name already ends in the code, so it isn't repeated.
      expect(find.text('Nearest'), findsOneWidget);
      expect(find.text('2222 · Yours'), findsOneWidget);
      await tester.tap(find.text('Bass pod'));
      await tester.pumpAndSettle();
      expect(picked!.remoteId.str, 'b');
    });
  });

  group('account', () {
    const pod = PodInfo(
      serial: '7CDFA1E23F2A',
      name: 'SlidePod 3F2A',
      firmware: '0.3.0',
      hardware: 2,
    );
    const linked = {
      'pod': {
        'id': 4,
        'serial': '7CDFA1E23F2A',
        'name': 'SlidePod 3F2A',
        'firmware': '0.3.0',
      },
    };

    test('linking, renaming and removing a pod', () async {
      final (a, server) = await account();
      server.routes['POST /api/auth/google'] = (200, signedIn);
      server.routes['GET /api/pods'] = (200, {'pods': []});
      await a.signInWithGoogle('t');

      server.routes['POST /api/pods'] = (201, linked);
      await a.linkPod(pod);
      expect(server.bodyOf('POST', '/pods'), {
        'serial': '7CDFA1E23F2A',
        'name': 'SlidePod 3F2A',
        'firmware': '0.3.0',
        'hardware': 2,
      });
      expect(a.linkedPod('7cdfa1e23f2a')!.id, 4);

      server.routes['PATCH /api/pods/4'] = (
        200,
        {
          'pod': {
            'id': 4,
            'serial': '7CDFA1E23F2A',
            'name': 'Bass pod',
            'firmware': '0.3.0',
          },
        },
      );
      await a.renamePod(a.linkedPod(pod.serial)!, 'Bass pod');
      expect(server.bodyOf('PATCH', '/pods/4'), {'name': 'Bass pod'});
      expect(a.pods.single.name, 'Bass pod');

      server.routes['DELETE /api/pods/4'] = (200, {'deleted': true});
      await a.unlinkPod(a.pods.single);
      expect(a.pods, isEmpty);
    });

    test('a pod on someone else\'s account', () async {
      final (a, server) = await account();
      server.routes['POST /api/auth/google'] = (200, signedIn);
      await a.signInWithGoogle('t');
      server.routes['POST /api/pods'] = (
        409,
        {'message': 'This SlidePod is linked to another account.'},
      );
      await expectLater(a.linkPod(pod), throwsA(isA<Exception>()));
      expect(a.pods, isEmpty);
    });

    test('only linked pods are refreshed when they connect', () async {
      final (a, server) = await account();
      server.routes['POST /api/auth/google'] = (200, signedIn);
      server.routes['GET /api/pods'] = (200, {'pods': []});
      await a.signInWithGoogle('t');
      await a.loadPods();
      await a.podSeen(pod);
      expect(
        server.requests.where(
          (r) => r.method == 'POST' && r.url.path == '/api/pods',
        ),
        isEmpty,
      );

      server.routes['GET /api/pods'] = (
        200,
        {
          'pods': [linked['pod']],
        },
      );
      server.routes['POST /api/pods'] = (200, linked);
      await a.loadPods();
      await a.podSeen(pod);
      expect(server.bodyOf('POST', '/pods')['serial'], '7CDFA1E23F2A');
    });

    test('signing out forgets the pods', () async {
      final (a, server) = await account();
      server.routes['POST /api/auth/google'] = (200, signedIn);
      server.routes['GET /api/pods'] = (
        200,
        {
          'pods': [linked['pod']],
        },
      );
      server.routes['POST /api/auth/sign-out'] = (200, null);
      await a.signInWithGoogle('t');
      await a.loadPods();
      expect(a.pods, hasLength(1));
      await a.signOut();
      expect(a.pods, isEmpty);
    });
  });

  testWidgets('the pod sheet renames the pod', (tester) async {
    final mock = _FakePod();
    var disconnected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PodSheet(
            source: mock,
            account: null,
            onDisconnect: () => disconnected = true,
          ),
        ),
      ),
    );
    expect(find.text('Mock pod'), findsOneWidget);
    expect(find.text('Serial 000000000000 · firmware mock'), findsOneWidget);

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '♭' * 7);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('That name is too long.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Bass pod');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(mock.pod!.name, 'Bass pod');
    expect(find.textContaining('Renamed.'), findsOneWidget);

    await tester.tap(find.text('Blink'));
    await tester.pumpAndSettle();
    expect(mock.blinks, 1);

    await tester.tap(find.text('Disconnect'));
    expect(disconnected, isTrue);
  });
}
