import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class SlideData {
  final int rawMm;
  final int filtMm;
  final double position;

  const SlideData({
    required this.rawMm,
    required this.filtMm,
    required this.position,
  });

  static SlideData fromBytes(List<int> bytes) {
    if (bytes.length < 6) return const SlideData(rawMm: 0, filtMm: 0, position: 0);
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    return SlideData(
      rawMm: data.getUint16(0, Endian.little),
      filtMm: data.getUint16(2, Endian.little),
      position: data.getUint16(4, Endian.little) / 10000.0,
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
  void dispose();
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

  void _tick(Timer _) {
    if (_holdTicks > 0) {
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
    await FlutterBluePlus.startScan(
      withServices: [_svcUuid],
      timeout: timeout,
    );
    sub.cancel();
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

    for (final svc in services) {
      if (svc.serviceUuid == _svcUuid) {
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
    _dataController.close();
    _connectionController.close();
  }
}
