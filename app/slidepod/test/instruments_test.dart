import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slidepod/account.dart';

import 'account_test.dart' show FakeServer, account, signedIn;

Map<String, dynamic> horn({int id = 3, Map<String, dynamic>? cal, String? at, int? podId}) => {
      'id': id,
      'name': 'Bach 42',
      'kind': 'tenor_f',
      'make': 'Bach',
      'pod_id': podId,
      'has_calibration': cal != null,
      'calibration_updated_at': at,
      if (cal != null) 'calibration': cal,
    };

const phoneCal = {'v': 3, 'from': 'phone'};
const serverCal = {'v': 3, 'from': 'server'};

Future<(Account, FakeServer)> signedInWithHorn({Map<String, dynamic>? cal, String? at}) async {
  final (a, server) = await account();
  server.routes['POST /api/auth/google'] = (200, signedIn);
  server.routes['GET /api/instruments'] = (200, {'instruments': [horn()]});
  server.routes['GET /api/instruments/3'] = (200, {'instrument': horn(cal: cal, at: at)});
  await a.signInWithGoogle('t');
  await a.loadInstruments();
  await a.chooseInstrument(a.instruments.single);
  return (a, server);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('no instrument, or signed out: nothing to sync', () async {
    final (a, server) = await account();
    expect(await a.syncCalibration(jsonEncode(phoneCal)), isNull);
    expect(server.requests, isEmpty);
  });

  test('the account\'s newer calibration is loaded', () async {
    final (a, _) = await signedInWithHorn(cal: serverCal, at: '2026-11-23T12:00:00Z');
    await a.calibrationChanged(DateTime.utc(2026, 11, 22));
    final load = await a.syncCalibration(jsonEncode(phoneCal));
    expect(jsonDecode(load!), serverCal);
    expect(a.calibrationAt, DateTime.utc(2026, 11, 23, 12));
  });

  test('the phone\'s newer calibration is saved, with when it was made', () async {
    final (a, server) = await signedInWithHorn(cal: serverCal, at: '2026-11-22T00:00:00Z');
    server.routes['PUT /api/instruments/3/calibration'] =
        (200, {'instrument': horn(at: '2026-11-23T09:00:00Z')});
    await a.calibrationChanged(DateTime.utc(2026, 11, 23, 9));
    expect(await a.syncCalibration(jsonEncode(phoneCal)), isNull);
    expect(server.bodyOf('PUT', '/instruments/3/calibration'),
        {'calibration': phoneCal, 'updated_at': '2026-11-23T09:00:00.000Z'});
  });

  test('a first instrument takes the phone\'s calibration', () async {
    final (a, server) = await signedInWithHorn();
    server.routes['PUT /api/instruments/3/calibration'] =
        (200, {'instrument': horn(at: '2026-11-23T09:00:00Z')});
    await a.calibrationChanged(DateTime.utc(2026, 11, 23, 9));
    expect(await a.syncCalibration(jsonEncode(phoneCal)), isNull);
    expect(server.bodyOf('PUT', '/instruments/3/calibration')['calibration'], phoneCal);
  });

  test('switching to an uncalibrated instrument starts over', () async {
    final (a, server) = await signedInWithHorn();
    expect(await a.syncCalibration(jsonEncode(phoneCal), adoptLocal: false), '');
    expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test('another phone saved a newer one: take it', () async {
    final (a, server) = await signedInWithHorn(cal: serverCal, at: '2026-11-22T00:00:00Z');
    server.routes['PUT /api/instruments/3/calibration'] = (409, {
      'message': 'A newer calibration is already saved.',
      'instrument': horn(cal: {'v': 3, 'from': 'other phone'}, at: '2026-11-23T10:00:00Z'),
    });
    await a.calibrationChanged(DateTime.utc(2026, 11, 23, 9));
    final load = await a.syncCalibration(jsonEncode(phoneCal));
    expect(jsonDecode(load!), {'v': 3, 'from': 'other phone'});
    expect(a.calibrationAt, DateTime.utc(2026, 11, 23, 10));
  });

  test('offline: the phone keeps its own', () async {
    final (a, server) = await signedInWithHorn(cal: serverCal, at: '2026-11-22T00:00:00Z');
    server.routes['GET /api/instruments/3'] = (503, {'message': 'Down.'});
    expect(await a.syncCalibration(jsonEncode(phoneCal)), isNull);
  });

  test('signing out forgets the instruments and which one', () async {
    final (a, server) = await signedInWithHorn();
    server.routes['POST /api/auth/sign-out'] = (200, null);
    expect(a.currentInstrument?.name, 'Bach 42');
    await a.signOut();
    expect(a.instruments, isEmpty);
    expect(a.currentInstrument, isNull);
  });
}
