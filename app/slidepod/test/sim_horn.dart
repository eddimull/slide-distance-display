import 'dart:math' as math;

import 'package:slidepod/gliss_take.dart';
import 'package:slidepod/slide_calibration.dart';

// Simulated pod + horn, shaped like the real one measured on 2026-11-19:
// the ToF spacing shrinks with distance (no formula fits it), and the horn
// plays its partials off the ideal harmonic series.
const mmAnchors = [5.5, 125.0, 238.7, 335.0, 421.7, 495.0, 558.2]; // 1st–7th
const hornCents = {2: -9.0, 3: 3.0, 4: -8.0, 5: 1.0, 6: 13.0, 7: 20.0, 8: 5.0};

double mmAt(double semis) {
  final i = semis.floor().clamp(0, 5);
  return mmAnchors[i] + (mmAnchors[i + 1] - mmAnchors[i]) * (semis - i);
}

/// What the horn sounds on [partial] with the slide out [semis], plus lipping.
double freqAt(int partial, double semis, [double lipCents = 0]) =>
    partial *
    SlideCalibration.f0 /
    math.pow(2, (semis * 100 - hornCents[partial]! - lipCents) / 1200);

/// Frames of one gliss on [partial]: hold 1st for [hold], sweep to [toSemis]
/// over [sweep], hold [endHold], then silence. ToF every 17.6 ms; the pitch
/// describes the slide [pitchLag] earlier, like the phone mic.
List<CalFrame> glissFrames(
  int partial, {
  Duration hold = const Duration(milliseconds: 800),
  Duration sweep = const Duration(seconds: 5),
  Duration endHold = const Duration(milliseconds: 400),
  double toSemis = 6.1,
  Duration pitchLag = const Duration(milliseconds: 40),
  int seed = 1,
  DateTime? start,
  double? Function(double t, double? f)? tamper,
  bool Function(double mm)? blind,
}) {
  final rng = math.Random(seed);
  final t0 = start ?? DateTime(2026, 11, 20);
  final h = hold.inMicroseconds / 1e6,
      sw = sweep.inMicroseconds / 1e6,
      eh = endHold.inMicroseconds / 1e6,
      lag = pitchLag.inMicroseconds / 1e6;
  double semisAt(double t) => t < h
      ? 0
      : t < h + sw
      ? toSemis * (t - h) / sw
      : toSemis;
  final frames = <CalFrame>[];
  final end = h + sw + eh + 0.4;
  for (var t = 0.0; t < end; t += 0.0176) {
    final trueMm = mmAt(semisAt(t));
    final double? mm = blind != null && blind(trueMm)
        ? null
        : trueMm + (rng.nextDouble() - 0.5) * 3;
    double? f = t < h + sw + eh
        ? freqAt(
            partial,
            semisAt(math.max(0, t - lag)),
            (rng.nextDouble() - 0.5) * 6,
          )
        : null;
    if (tamper != null) f = tamper(t, f);
    frames.add((
      t: t0.add(Duration(microseconds: (t * 1e6).round())),
      mm: mm,
      freq: f,
    ));
  }
  return frames;
}

/// Runs [frames] through a fresh take and returns it.
GlissTake runTake(int partial, List<CalFrame> frames) {
  final take = GlissTake(partial);
  frames.forEach(take.feed);
  return take;
}

/// A calibration from the three guided glisses.
SlideCalibration glissCalibrated() {
  final cal = SlideCalibration();
  for (final (i, n) in SlideCalibration.glissPartials.indexed) {
    final take = runTake(n, glissFrames(n, seed: i + 1));
    if (take.phase != GlissPhase.done) throw StateError('take $n failed');
    cal.addGliss(n, take.samples, take.closedMm!);
  }
  return cal;
}
