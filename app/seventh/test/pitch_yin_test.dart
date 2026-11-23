import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:seventh/pitch_yin.dart';

/// Brass-ish tone: weak fundamental, strong 2nd–4th harmonics, ±5¢ vibrato,
/// noise. Mirrors test/pitch_yin/test_pitch_yin.cpp in the firmware.
List<double?> run(double f, {double amp = 0.3, double noise = 0.01}) {
  const h = [0.35, 1.0, 0.9, 0.7, 0.45, 0.3, 0.2, 0.1];
  final rng = math.Random(1);
  final yin = PitchYin();
  final hop = (PitchYin.sampleRate / 50).round();
  final out = <double?>[];
  var n = 0;
  for (var frame = 0; frame < 25; frame++) {
    for (var i = 0; i < hop; i++, n++) {
      final t = n / PitchYin.sampleRate;
      final phase = 2 * math.pi * f *
          (t - 0.003 / (2 * math.pi * 5.5) * math.cos(2 * math.pi * 5.5 * t));
      var s = 0.0;
      for (var k = 0; k < h.length; k++) {
        if (f * (k + 1) > 0.45 * PitchYin.sampleRate) break;
        s += h[k] * math.sin((k + 1) * phase + k);
      }
      yin.push(amp / 3 * s + (rng.nextDouble() - 0.5) * 2 * noise);
    }
    final p = yin.detect();
    if (frame >= 4) out.add(p);
  }
  return out;
}

double cents(double a, double b) => 1200 * math.log(a / b) / math.ln2;

void main() {
  for (final (name, f) in [
    ('Bb1', 58.27), ('E2', 82.41), ('Bb2', 116.54), ('F3', 174.61),
    ('Bb3', 233.08), ('D4', 293.66), ('F4', 349.23), ('Bb4', 466.16),
    ('F5', 698.46),
  ]) {
    test('$name within vibrato, no octave errors', () {
      final got = run(f);
      expect(got.where((p) => p == null).length, lessThanOrEqualTo(2));
      for (final p in got.whereType<double>()) {
        expect(cents(p, f).abs(), lessThan(10), reason: '$p Hz');
      }
    });
  }

  test('quiet room is silent', () {
    final got = run(200, amp: 0, noise: 0.002);
    expect(got.every((p) => p == null), isTrue);
  });
}
