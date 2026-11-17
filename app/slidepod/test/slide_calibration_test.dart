import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/slide_calibration.dart';

// "Real" instrument: sensor reads 72 mm at 1st, L0/2 = 1.32 m.
const trueA = 72.0, trueB = 1320.0;
double mmAt(double semis) => trueA + trueB * (math.pow(2, semis / 12) - 1);
double freqAt(int partial, double semis, [double cents = 0]) =>
    partial * SlideCalibration.f0 / math.pow(2, (semis * 100 + cents) / 1200);

void main() {
  test('resolves partial from pitch near the sensed position', () {
    // F4 is 6th partial in 1st, but 8th partial in ~6th position.
    final f4 = 349.23;
    expect(SlideCalibration.resolvePitch(f4, 0.2)!.$1, 6);
    expect(SlideCalibration.resolvePitch(f4, 4.8)!.$1, 8);
    // C4 on 5th partial in 3rd: the 5th partial is ~14¢ flat of ET, so an
    // in-tune C needs the slide ~0.14 semitone short of exactly 3rd.
    final (n, s) = SlideCalibration.resolvePitch(261.63, 2.0)!;
    expect(n, 5);
    expect(s, closeTo(1.86, 0.02));
  });

  test('converges to true geometry from played notes', () {
    final cal = SlideCalibration();
    final rng = math.Random(1);
    // Play a few notes, each held ~0.5 s, at positions 1, 3, 4, 6.
    for (final (partial, pos) in [(2, 1), (3, 3), (4, 4), (3, 6), (5, 1)]) {
      final semis = (pos - 1).toDouble();
      for (var i = 0; i < 25; i++) {
        final mm = mmAt(semis) + (rng.nextDouble() - 0.5) * 4; // ±2 mm noise
        final cents = (rng.nextDouble() - 0.5) * 16; // ±8¢ lipping
        cal.addSample(mm, freqAt(partial, semis, cents));
      }
    }
    expect(cal.calibrated, isTrue);
    expect(cal.a, closeTo(trueA, 3));
    expect(cal.b, closeTo(trueB, 30));
    // Every position, including ones never played, lands within 0.05 pos.
    for (var p = 1; p <= 7; p++) {
      final s = cal.semitonesFromMm(mmAt(p - 1.0));
      expect(s, closeTo(p - 1.0, 0.05), reason: 'position $p');
    }
  });
}
