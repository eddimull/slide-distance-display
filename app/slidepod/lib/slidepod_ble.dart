import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'pod_info.dart';

class SlideData {
  /// Sent as raw_mm when the ToF has no valid reading this cycle (the slide
  /// out of sight, often far out in Medium mode).
  static const noReading = 0xFFFF;

  final int rawMm;
  final int filtMm;
  final double position;

  /// Pitch from the pod's piezo pickup, or null if silent / unclear.
  final double? pitchHz;

  /// True if the firmware sends pitch at all (8-byte payload). Older
  /// firmware sends 6 bytes.
  final bool hasPiezo;

  /// False when the pod had no ToF reading ([noReading]).
  bool get hasRange => rawMm != noReading;

  const SlideData({
    required this.rawMm,
    required this.filtMm,
    required this.position,
    this.pitchHz,
    this.hasPiezo = false,
  });

  static SlideData fromBytes(List<int> bytes) {
    if (bytes.length < 6) return const SlideData(rawMm: 0, filtMm: 0, position: 0);
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final hasPiezo = bytes.length >= 8;
    final pitch10 = hasPiezo ? data.getUint16(6, Endian.little) : 0;
    return SlideData(
      rawMm: data.getUint16(0, Endian.little),
      filtMm: data.getUint16(2, Endian.little),
      position: data.getUint16(4, Endian.little) / 10000.0,
      pitchHz: pitch10 > 0 ? pitch10 / 10.0 : null,
      hasPiezo: hasPiezo,
    );
  }
}

abstract class SlidePodSource {
  Stream<SlideData> get dataStream;
  Stream<bool> get connectionStream;
  bool get connected;
  bool get isMock;
  Future<void> connectFirst();
  Future<void> disconnect();

  /// Holds the pod's LED at [rgb] (levels 0–255), or hands it back to the
  /// pod's own status colours when null. No-op if unsupported.
  Future<void> setLed((int, int, int)? rgb);

  /// The connected pod: its serial, name and firmware. Null when not
  /// connected, or on firmware before 0.3 (which can't say).
  PodInfo? get pod;

  /// Renames the connected pod (it advertises the new name from the next
  /// disconnect). Throws [StateError] if the pod can't be renamed, and
  /// [ArgumentError] for a name it won't take (see [podNameProblem]).
  Future<void> rename(String name);

  /// Flashes the pod's LED white a few times, to show which pod this is.
  Future<void> blink();

  /// The connected pod's battery, kept up to date (firmware 0.4 and up;
  /// null otherwise).
  PodPower? get power;
  Stream<PodPower?> get powerStream;
  void dispose();
}

/// Flashes [setLed] white twice, then hands the LED back to the pod.
Future<void> blinkLed(Future<void> Function((int, int, int)?) setLed) async {
  for (var i = 0; i < 2; i++) {
    await setLed((255, 255, 255));
    await Future<void>.delayed(const Duration(milliseconds: 180));
    await setLed((0, 0, 0));
    await Future<void>.delayed(const Duration(milliseconds: 140));
  }
  await setLed(null);
}

// ── Mock source: triangle wave matching firmware sim ─────────────────────

class SlidePodMock implements SlidePodSource {
  Timer? _timer;
  final _rng = Random();
  double _rawMm = 300;
  double _targetMm = 300;
  double _speed = 4;
  int _holdTicks = 0;

  final _dataController = StreamController<SlideData>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  bool _connected = false;

  @override
  Stream<SlideData> get dataStream => _dataController.stream;
  @override
  Stream<bool> get connectionStream => _connectionController.stream;
  @override
  bool get connected => _connected;
  @override
  bool get isMock => true;

  PodInfo _pod = const PodInfo(
      serial: '000000000000', name: 'Mock pod', firmware: 'mock', hardware: 0);
  @override
  PodInfo? get pod => _connected ? _pod : null;

  @override
  Future<void> rename(String name) async {
    final problem = podNameProblem(name);
    if (problem != null) throw ArgumentError(problem);
    _pod = _pod.withName(name);
  }

  @override
  Future<void> blink() async {}

  @override
  PodPower? get power => _connected
      ? const PodPower(percent: 72, usb: false, millivolts: 3960)
      : null;
  @override
  Stream<PodPower?> get powerStream =>
      _connectionController.stream.map((_) => power);

  @override
  Future<void> connectFirst() async {
    await Future.delayed(const Duration(milliseconds: 300));
    _connected = true;
    _connectionController.add(true);
    _pickNewTarget();
    _timer = Timer.periodic(const Duration(milliseconds: 20), _tick);
  }

  void _pickNewTarget() {
    _targetMm = 50 + _rng.nextDouble() * 500;
    _speed = 1 + _rng.nextDouble() * 9;
    _holdTicks = 0;
  }

  /// Calibration demo: instead of random moves, repeat a gliss: hold in
  /// 1st for 1 s, slide out to 7th over 5 s, hold 0.5 s, then go quiet and
  /// return. [sounding] says when the mock player is blowing.
  bool get glissMode => _glissTick >= 0;
  set glissMode(bool on) {
    if (on == glissMode) return;
    _glissTick = on ? 0 : -1;
  }

  int _glissTick = -1; // 20 ms ticks into the gliss cycle; -1 = off
  static const _glissCycle = 400; // 8 s

  bool get sounding => glissMode && _glissTick < 325;

  void _tick(Timer _) {
    if (glissMode) {
      _glissTick = (_glissTick + 1) % _glissCycle;
      final t = _glissTick;
      _rawMm = t < 50
          ? 50
          : t < 300
              ? 50 + 500 * (t - 50) / 250
              : t < 325
                  ? 550
                  : 550 - 500 * ((t - 325) / 75).clamp(0.0, 1.0);
    } else if (_holdTicks > 0) {
      _holdTicks--;
      if (_holdTicks == 0) _pickNewTarget();
    } else {
      final dist = _targetMm - _rawMm;
      if (dist.abs() < _speed) {
        _rawMm = _targetMm;
        _holdTicks = 5 + _rng.nextInt(40);
      } else {
        _rawMm += dist.sign * _speed;
      }
    }

    final mm = _rawMm.round().clamp(50, 550);
    final pos = ((mm - 50) / 500.0).clamp(0.0, 1.0);
    _dataController.add(SlideData(
      rawMm: mm,
      filtMm: mm,
      position: pos,
    ));
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    _connected = false;
    _connectionController.add(false);
  }

  @override
  Future<void> setLed((int, int, int)? rgb) async {}

  @override
  void dispose() {
    _timer?.cancel();
    _dataController.close();
    _connectionController.close();
  }
}

// ── Real BLE source ─────────────────────────────────────────────────────

class SlidePodBle implements SlidePodSource {
  static final _svcUuid = Guid("d5e40001-7537-4463-a441-27f2d3140fab");
  static final _posUuid = Guid("d5e40002-7537-4463-a441-27f2d3140fab");
  static final _ledUuid = Guid("d5e40003-7537-4463-a441-27f2d3140fab");
  static final _nameUuid = Guid("d5e40004-7537-4463-a441-27f2d3140fab");
  static final _infoUuid = Guid("d5e40005-7537-4463-a441-27f2d3140fab");
  static final _powerUuid = Guid("d5e40006-7537-4463-a441-27f2d3140fab");
  PodPower? _power;
  StreamSubscription? _powerSub;
  final _powerController = StreamController<PodPower?>.broadcast();

  @override
  PodPower? get power => _connected ? _power : null;
  @override
  Stream<PodPower?> get powerStream => _powerController.stream;
  BluetoothCharacteristic? _ledChr; // absent on older firmware
  BluetoothCharacteristic? _nameChr; // firmware 0.3 and up
  PodInfo? _pod;

  @override
  PodInfo? get pod => _connected ? _pod : null;

  /// The name a scanned pod advertises (older firmware: "SlidePod").
  static String advertisedName(ScanResult r) {
    final adv = r.advertisementData.advName;
    if (adv.isNotEmpty) return adv;
    final p = r.device.platformName;
    return p.isNotEmpty ? p : 'SlidePod';
  }

  /// A scanned pod's serial, from its advert; null on older firmware and
  /// on the web (the browser's chooser doesn't pass adverts on).
  static String? advertisedSerial(ScanResult r) =>
      serialFromAdvert(r.advertisementData.manufacturerData);

  BluetoothDevice? _device;
  StreamSubscription? _notifySub;
  StreamSubscription? _stateSub;

  final _dataController = StreamController<SlideData>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  @override
  Stream<SlideData> get dataStream => _dataController.stream;
  @override
  Stream<bool> get connectionStream => _connectionController.stream;

  bool _connected = false;
  @override
  bool get connected => _connected;
  @override
  bool get isMock => false;

  Future<List<ScanResult>> scan({Duration timeout = const Duration(seconds: 4)}) async {
    if (kIsWeb) return scanWeb();
    final results = <ScanResult>[];
    final sub = FlutterBluePlus.onScanResults.listen((r) {
      for (final sr in r) {
        if (sr.device.platformName == 'SlidePod' ||
            sr.advertisementData.serviceUuids.contains(_svcUuid)) {
          if (!results.any((e) => e.device.remoteId == sr.device.remoteId)) {
            results.add(sr);
          }
        }
      }
    });
    // No withServices filter: Android's hardware 128-bit UUID filter drops
    // SlidePod's advert on some phones (seen on Samsung S21). We filter by
    // name/UUID in the listener above instead.
    await FlutterBluePlus.startScan(timeout: timeout);
    // startScan returns once scanning has *started*; wait for the timeout
    // to end it before dropping the listener.
    await FlutterBluePlus.isScanning.where((s) => !s).first;
    await sub.cancel();
    return results;
  }

  /// Device Information (0x180A): lets the web build read the pod's serial
  /// once the firmware reports one.
  static final _deviceInfoUuid = Guid("180a");

  /// Web Bluetooth has no background scan: startScan opens the browser's
  /// chooser and returns once the user has picked a pod (or closed it). The
  /// filters keep the chooser to SlidePods, and the browser only lets the
  /// page use services named here, so SlidePod's service must be listed
  /// or discoverServices finds nothing. Must run from a tap (the browser
  /// needs a user gesture) on an https page such as seventh.app/app.
  @visibleForTesting
  Future<List<ScanResult>> scanWeb() async {
    if (!await FlutterBluePlus.isSupported) {
      throw Exception('This browser has no Bluetooth: use Chrome or Edge');
    }
    final results = <ScanResult>[];
    final picked = Completer<void>();
    final sub = FlutterBluePlus.onScanResults.listen((r) {
      for (final sr in r) {
        if (!results.any((e) => e.device.remoteId == sr.device.remoteId)) {
          results.add(sr);
        }
      }
      if (results.isNotEmpty && !picked.isCompleted) picked.complete();
    }, onError: (_) {
      // The chooser was closed: nothing is coming.
      if (!picked.isCompleted) picked.complete();
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [_svcUuid],
        withNames: ['SlidePod'],
        webOptionalServices: [_svcUuid, _deviceInfoUuid],
      );
      // The pick arrives during startScan but reaches onScanResults a moment
      // after it returns (it's buffered); stopping now would drop it.
      await picked.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (_) {
      // The user closed the chooser: same as finding nothing.
    } finally {
      await FlutterBluePlus.stopScan();
      await sub.cancel();
    }
    return results;
  }

  @override
  Future<void> connectFirst() async {
    final results = await scan();
    if (results.isEmpty) throw Exception('No SlidePod found');
    await connect(results.first.device);
  }

  Future<void> connect(BluetoothDevice device) async {
    _device = device;

    _stateSub?.cancel();
    _stateSub = device.connectionState.listen((state) {
      final isConnected = state == BluetoothConnectionState.connected;
      if (_connected != isConnected) {
        _connected = isConnected;
        _connectionController.add(isConnected);
      }
      if (!isConnected) {
        _notifySub?.cancel();
        _notifySub = null;
      }
    });

    await device.connect(license: License.nonprofit, autoConnect: false);
    final services = await device.discoverServices();

    _ledChr = null;
    _nameChr = null;
    _pod = null;
    for (final svc in services) {
      if (svc.serviceUuid != _svcUuid) continue;
      BluetoothCharacteristic? infoChr, powerChr;
      for (final chr in svc.characteristics) {
        if (chr.characteristicUuid == _ledUuid) _ledChr = chr;
        if (chr.characteristicUuid == _nameUuid) _nameChr = chr;
        if (chr.characteristicUuid == _infoUuid) infoChr = chr;
        if (chr.characteristicUuid == _powerUuid) powerChr = chr;
      }
      await _readIdentity(infoChr);
      await _watchPower(powerChr);
      // Show which pod this is before the data (and the app's LED colours)
      // starts.
      await blink();
      for (final chr in svc.characteristics) {
        if (chr.characteristicUuid == _posUuid) {
          await chr.setNotifyValue(true);
          _notifySub = chr.onValueReceived.listen((bytes) {
            _dataController.add(SlideData.fromBytes(bytes));
          });
          return;
        }
      }
    }
  }

  Future<void> _readIdentity(BluetoothCharacteristic? infoChr) async {
    final nameChr = _nameChr;
    if (infoChr == null || nameChr == null) return;
    try {
      final name = utf8.decode(await nameChr.read(), allowMalformed: true);
      _pod = PodInfo.fromInfo(await infoChr.read(), name);
    } catch (_) {
      _pod = null; // identity is extra; never fail the connection over it
    }
  }

  Future<void> _watchPower(BluetoothCharacteristic? chr) async {
    _powerSub?.cancel();
    _powerSub = null;
    _power = null;
    _powerController.add(null);
    if (chr == null) return;
    try {
      _powerSub = chr.onValueReceived.listen((b) {
        _power = PodPower.fromBytes(b);
        _powerController.add(_power);
      });
      await chr.setNotifyValue(true);
      _power = PodPower.fromBytes(await chr.read());
      _powerController.add(_power);
    } catch (_) {
      // The battery is extra; never fail the connection over it.
    }
  }

  @override
  Future<void> rename(String name) async {
    final chr = _nameChr;
    final pod = _pod;
    if (chr == null || pod == null || !_connected) {
      throw StateError('This SlidePod needs newer firmware to be renamed.');
    }
    final problem = podNameProblem(name);
    if (problem != null) throw ArgumentError(problem);
    await chr.write(utf8.encode(name));
    // The pod reads back its name: the old one if it refused the new one.
    final now = utf8.decode(await chr.read(), allowMalformed: true);
    if (now != name) throw ArgumentError('The SlidePod didn\'t take that name.');
    _pod = pod.withName(now);
  }

  @override
  Future<void> blink() => blinkLed(setLed);

  @override
  Future<void> setLed((int, int, int)? rgb) async {
    final chr = _ledChr;
    if (chr == null || !_connected) return;
    final payload = rgb == null ? [0] : [1, rgb.$1, rgb.$2, rgb.$3];
    try {
      await chr.write(payload, withoutResponse: true);
    } catch (_) {
      // Cosmetic; never let the LED break the data stream.
    }
  }

  @override
  Future<void> disconnect() async {
    _notifySub?.cancel();
    _notifySub = null;
    await _device?.disconnect();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _stateSub?.cancel();
    _powerSub?.cancel();
    _dataController.close();
    _connectionController.close();
    _powerController.close();
  }
}
