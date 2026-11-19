import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/one_euro.dart';

final t0 = DateTime(2026);
DateTime at(double s) => t0.add(Duration(microseconds: (s * 1e6).round()));

double sd(List<double> xs) {
  final m = xs.reduce((a, b) => a + b) / xs.length;
  return math.sqrt(xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / xs.length);
}

void main() {
  test('fast move: output keeps up (lag < 5 ms at 1 m/s)', () {
    final f = OneEuroFilter();
    const dt = 0.0375; // pod reading period
    double out = 0, truth = 0;
    for (var i = 0; i < 200; i++) {
      truth = 100 + 1000 * i * dt; // 1000 mm/s ramp
      out = f.update(truth, at(i * dt));
    }
    final lagMs = (truth - out) / 1000 * 1000;
    expect(lagMs, lessThan(5));
  });

  test('replay of a real phone session: less jitter at rest, tracks moves', () {
    final rows = File('test/fixtures/tof_session_79s.csv')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty)
        .map((l) => l.split(',').map(double.parse).toList())
        .toList();
    final f = OneEuroFilter();
    final out = [for (final r in rows) f.update(r[1], at(r[0]))];
    final raw = [for (final r in rows) r[1]];
    final n = raw.length;
    // Zero-delay reference: centred 5-point mean.
    final ref = [
      for (var i = 0; i < n; i++)
        () {
          final w = raw.sublist(math.max(0, i - 2), math.min(n, i + 3));
          return w.reduce((a, b) => a + b) / w.length;
        }()
    ];
    final restRaw = <double>[], restOut = <double>[], moveErr = <double>[];
    for (var i = 1; i < n - 1; i++) {
      final speed = (ref[i + 1] - ref[i - 1]).abs() / (rows[i + 1][0] - rows[i - 1][0]);
      if (speed < 20) {
        restRaw.add(raw[i] - ref[i]);
        restOut.add(out[i] - ref[i]);
      } else if (speed > 200) {
        moveErr.add((out[i] - ref[i]).abs());
      }
    }
    moveErr.sort();
    expect(sd(restOut), lessThan(sd(restRaw) * 0.7)); // ~0.86 vs 1.56 mm
    expect(moveErr[moveErr.length ~/ 2], lessThan(10)); // old Kalman: 45 mm
  });

  test('deadband: holds still through noise, follows a real move', () {
    final f = OneEuroFilter(deadband: 2);
    final rng = math.Random(1);
    final rest = [
      for (var i = 0; i < 300; i++)
        f.update(300 + (rng.nextDouble() - 0.5) * 3, at(i * 0.0176))
    ].sublist(100);
    expect(rest.reduce(math.max) - rest.reduce(math.min), lessThan(1.5));
    double out = 0;
    for (var i = 0; i < 100; i++) {
      out = f.update(400, at((300 + i) * 0.0176));
    }
    expect((out - 400).abs(), lessThanOrEqualTo(2)); // within the band
  });
}
