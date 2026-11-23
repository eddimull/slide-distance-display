import 'dart:async';

import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/slidepod_ble.dart';

/// Web Bluetooth as flutter_blue_plus_web does it: startScan opens the
/// chooser and, once the user picks a device, reports it before returning.
final class _Chooser extends FlutterBluePlusPlatform {
  final bool cancel;
  _Chooser({this.cancel = false});

  final _scan = StreamController<BmScanResponse>.broadcast();
  BmScanSettings? request;

  @override
  Stream<BmScanResponse> get onScanResponse => _scan.stream;

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;

  @override
  Future<bool> startScan(BmScanSettings request) async {
    this.request = request;
    await Future<void>.delayed(const Duration(milliseconds: 5)); // the chooser
    if (cancel) {
      _scan.add(
        BmScanResponse(
          advertisements: [],
          success: false,
          errorCode: 0,
          errorString:
              'NotFoundError: User cancelled the requestDevice() chooser.',
        ),
      );
      return false;
    }
    _scan.add(
      BmScanResponse(
        advertisements: [
          BmScanAdvertisement(
            remoteId: DeviceIdentifier('web-pod-1'),
            platformName: 'SlidePod',
            advName: null,
            connectable: true,
            txPowerLevel: null,
            appearance: null,
            manufacturerData: {},
            serviceData: {},
            serviceUuids: [],
            rssi: 0,
          ),
        ],
        success: true,
        errorCode: 0,
        errorString: '',
      ),
    );
    return true;
  }

  @override
  Future<bool> stopScan(BmStopScanRequest request) async => true;
}

void main() {
  test('web scan keeps the pod picked in the chooser', () async {
    final chooser = _Chooser();
    FlutterBluePlusPlatform.instance = chooser;
    final results = await SlidePodBle().scanWeb();
    expect(results.map((r) => r.device.remoteId.str), ['web-pod-1']);
    // The page may only use services listed here.
    expect(
      chooser.request!.webOptionalServices,
      contains(Guid('d5e40001-7537-4463-a441-27f2d3140fab')),
    );
  });

  test('closing the chooser finds nothing', () async {
    FlutterBluePlusPlatform.instance = _Chooser(cancel: true);
    expect(await SlidePodBle().scanWeb(), isEmpty);
  });
}
