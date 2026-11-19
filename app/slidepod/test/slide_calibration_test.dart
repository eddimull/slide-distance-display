import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/slide_calibration.dart';

// Simulated pod + horn, shaped like the real one measured on 2026-11-19:
// the ToF spacing shrinks with distance (no formula fits it), and the horn
// plays its partials off the ideal harmonic series.
const mmAnchors = [5.5, 125.0, 238.7, 335.0, 421.7, 495.0, 558.2]; // 1st–7th
const hornCents = {2: -9.0, 3: 3.0, 4: -8.0, 5: 1.0, 6: 13.0};

double mmAt(double semis) {
  final i = semis.floor().clamp(0, 5);
  return mmAnchors[i] + (mmAnchors[i + 1] - mmAnchors[i]) * (semis - i);
}

/// What the horn sounds on [partial] with the slide out [semis], plus lipping.
double freqAt(int partial, double semis, [double lipCents = 0]) =>
    partial *
    SlideCalibration.f0 /
    math.pow(2, (semis * 100 - hornCents[partial]! - lipCents) / 1200);

SlideCalibration calibrated({int seed = 1}) {
  final cal = SlideCalibration();
  final rng = math.Random(seed);
  for (final pos in [1, 3, 5, 7]) {
    for (var partial = 2; partial <= 6; partial++) {
      final semis = pos - 1.0;
      for (var i = 0; i < 40; i++) {
        final mm = mmAt(semis) + (rng.nextDouble() - 0.5) * 8; // ±4 mm
        final lip = (rng.nextDouble() - 0.5) * 20; // ±10¢ wobble
        cal.addSample(mm, freqAt(partial, semis, lip));
      }
    }
  }
  return cal;
}

void main() {
  test('resolves partial from pitch near the sensed position', () {
    // F4 is 6th partial in 1st, but 8th partial in ~6th position.
    const f4 = 349.23;
    expect(SlideCalibration.resolvePitch(f4, 0.2)!.$1, 6);
    expect(SlideCalibration.resolvePitch(f4, 4.8)!.$1, 8);
    // C4 on 5th partial in 3rd: the 5th partial is ~14¢ flat of ET, so an
    // in-tune C needs the slide ~0.14 semitone short of exactly 3rd.
    final (n, s) = SlideCalibration.resolvePitch(261.63, 2.0)!;
    expect(n, 5);
    expect(s, closeTo(1.86, 0.02));
  });

  test('learns the sensor curve, including positions never played', () {
    final cal = calibrated();
    expect(cal.calibrated, isTrue);
    expect(cal.capturedPositions, [1, 3, 5, 7]);
    expect(cal.complete, isTrue);
    expect(cal.missingPartials, isEmpty);
    for (var p = 1; p <= 7; p++) {
      // Even positions are interpolated; the sim is piecewise linear there,
      // so allow a little more.
      final tol = p.isOdd ? 0.06 : 0.15;
      expect(cal.semitonesFromMm(mmAt(p - 1.0)), closeTo(p - 1.0, tol),
          reason: 'position $p');
    }
  });

  test('learns the horn\'s partial tuning', () {
    final cal = calibrated();
    hornCents.forEach((n, c) {
      expect(cal.partialOffsetCents(n), closeTo(c, 3),
          reason: 'partial $n');
    });
  });

  test('reads lipping as the pitch vs where the slide is', () {
    final cal = calibrated();
    for (final (pos, partial) in [(1, 4), (3, 6), (5, 2), (7, 5), (4, 3)]) {
      final s = pos - 1.0;
      for (final lip in [0.0, 20.0, -25.0]) {
        final (n, cents) = cal.lipCents(mmAt(s), freqAt(partial, s, lip))!;
        expect(n, partial);
        expect(cents, closeTo(lip, 6),
            reason: 'pos $pos partial $partial lip $lip');
      }
    }
  });

  test('replay of the real session: anchors land on the held positions', () {
    final rows = File('test/fixtures/partials_session.csv')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .map((l) => l.split(','))
        .toList();
    final cal = SlideCalibration();
    expect(cal.complete, isFalse);
    for (var i = 10; i < rows.length; i++) {
      if (rows[i][3] == '-') continue;
      final mm = double.parse(rows[i][2]);
      // Still: filtered mm hasn't moved over the last ~10 readings.
      if ((mm - double.parse(rows[i - 10][2])).abs() > 3) continue;
      cal.addSample(mm, double.parse(rows[i][3]));
    }
    expect(cal.capturedPositions, containsAll([1, 3, 5, 7]));
    // Mean held mm per position from the same session (all partials).
    for (final (pos, mm) in [(1, 5.5), (3, 238.7), (5, 421.7), (7, 558.2)]) {
      expect(cal.semitonesFromMm(mm), closeTo(pos - 1.0, 0.15),
          reason: 'position $pos');
    }
    // The horn's sharp 6th partial shows up against its flat 4th.
    expect(cal.partialOffsetCents(6) - cal.partialOffsetCents(4), greaterThan(15));
  });

  test('not complete until the upper partials are heard', () {
    final cal = SlideCalibration();
    for (final pos in [1, 3, 5, 7]) {
      for (var partial = 2; partial <= 4; partial++) {
        for (var i = 0; i < 20; i++) {
          cal.addSample(mmAt(pos - 1.0), freqAt(partial, pos - 1.0));
        }
      }
    }
    expect(cal.calibrated, isTrue);
    expect(cal.missingPartials, [5, 6]);
    expect(cal.complete, isFalse);
  });

  test('round-trips through JSON', () {
    final cal = calibrated();
    final restored = SlideCalibration()..loadJson(cal.toJson());
    expect(restored.calibrated, isTrue);
    expect(restored.capturedPositions, cal.capturedPositions);
    for (final mm in [0.0, 100.0, 300.0, 600.0]) {
      expect(restored.semitonesFromMm(mm), closeTo(cal.semitonesFromMm(mm), 1e-9));
    }
    for (var n = 2; n <= 8; n++) {
      expect(restored.partialOffsetCents(n), closeTo(cal.partialOffsetCents(n), 1e-9));
    }

    // Garbage or an old format leaves a clean, uncalibrated state.
    for (final bad in ['{"v":2,"cells":"nope"}', '{"v":1,"buckets":[]}', 'x']) {
      final c = SlideCalibration()..loadJson(bad);
      expect(c.calibrated, isFalse);
    }
  });
}
