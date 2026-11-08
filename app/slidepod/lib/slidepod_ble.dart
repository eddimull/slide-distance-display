import 'dart:async';
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

class SlidePodBle {
  static final _svcUuid = Guid("d5e40001-7537-4463-a441-27f2d3140fab");
  static final _posUuid = Guid("d5e40002-7537-4463-a441-27f2d3140fab");

  BluetoothDevice? _device;
  StreamSubscription? _notifySub;
  StreamSubscription? _stateSub;

  final _dataController = StreamController<SlideData>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  Stream<SlideData> get dataStream => _dataController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;

  bool _connected = false;
  bool get connected => _connected;

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

  Future<void> disconnect() async {
    _notifySub?.cancel();
    _notifySub = null;
    await _device?.disconnect();
  }

  void dispose() {
    _notifySub?.cancel();
    _stateSub?.cancel();
    _dataController.close();
    _connectionController.close();
  }
}
