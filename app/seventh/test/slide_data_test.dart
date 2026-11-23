import 'package:flutter_test/flutter_test.dart';
import 'package:seventh/slidepod_ble.dart';

void main() {
  test('6-byte payload (old firmware): no piezo', () {
    final d = SlideData.fromBytes([0x2c, 0x01, 0x2a, 0x01, 0x88, 0x13]);
    expect(d.rawMm, 300);
    expect(d.filtMm, 298);
    expect(d.position, 0.5);
    expect(d.hasPiezo, isFalse);
    expect(d.pitchHz, isNull);
  });

  test('raw_mm 0xFFFF: the ToF had no reading', () {
    final d = SlideData.fromBytes([0xff, 0xff, 0xff, 0xff, 0, 0, 0x1a, 0x09]);
    expect(d.hasRange, isFalse);
    expect(d.pitchHz, 233.0);
    expect(SlideData.fromBytes([0x2c, 0x01, 0, 0, 0, 0, 0, 0]).hasRange, isTrue);
  });

  test('8-byte payload: pitch in 0.1 Hz, 0 = silent', () {
    // 2330 → 233.0 Hz (Bb3)
    final d = SlideData.fromBytes([0, 0, 0, 0, 0, 0, 0x1a, 0x09]);
    expect(d.hasPiezo, isTrue);
    expect(d.pitchHz, 233.0);
    final silent = SlideData.fromBytes([0, 0, 0, 0, 0, 0, 0, 0]);
    expect(silent.hasPiezo, isTrue);
    expect(silent.pitchHz, isNull);
  });
}
