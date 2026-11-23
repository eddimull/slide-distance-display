/// A synthetic take: a horn played with known slide and lip errors.
library;

import 'dart:math' as math;

import 'package:seventh/slide_calibration.dart';
import 'package:seventh/take.dart';
import 'package:seventh/take_analysis.dart';

final cal = SlideCalibration();

double off(int n) => cal.partialOffsetCents(n) / 100;
double etFreq(int midi) => 440.0 * math.pow(2, (midi - 69) / 12);

/// This horn's slide spot for [midi] on partial [n].
double targetFor(int midi, int n) =>
    SlideCalibration.semitonesFromPitch(etFreq(midi), n) + off(n);

/// What this horn sounds on partial [n] with the slide at [s], lipped by
/// [lip] cents.
double hornFreq(int n, double s, double lip) =>
    n * SlideCalibration.f0 / math.pow(2, (s - off(n)) / 12) *
    math.pow(2, lip / 1200);

/// One note of a synthetic take. [keys] are slide keyframes `(ms from the
/// note's start, semitones)` for the move into it, eased between; the slide
/// holds the last one.
class SynthNote {
  final int midi, partial;
  final double lip;
  final List<(int, double)> keys;
  SynthNote(this.midi, this.partial, this.lip, this.keys);
}

const noteMs = 1000, gapMs = 120, firstStart = 300, frameMs = 20, lagMs = 40;

Take synthTake(List<SynthNote> notes) {
  final keys = <(int, double)>[(0, notes.first.keys.last.$2)];
  for (var i = 0; i < notes.length; i++) {
    final start = firstStart + i * (noteMs + gapMs);
    for (final (dt, s) in notes[i].keys) {
      keys.add((start + dt, s));
    }
  }
  double slideAt(int t) {
    if (t <= keys.first.$1) return keys.first.$2;
    for (var k = 1; k < keys.length; k++) {
      final (t0, s0) = keys[k - 1];
      final (t1, s1) = keys[k];
      if (t <= t1) {
        if (t1 == t0) return s1;
        final u = (t - t0) / (t1 - t0);
        return s0 + (s1 - s0) * (1 - math.cos(math.pi * u)) / 2;
      }
    }
    return keys.last.$2;
  }

  final rng = math.Random(1);
  final end = firstStart + notes.length * (noteMs + gapMs);
  final frames = <TakeFrame>[];
  for (var t = 0; t <= end; t += frameMs) {
    // The pitch heard now is the horn as it was lagMs ago.
    final tp = t - lagMs;
    double? freq;
    final i = (tp - firstStart) ~/ (noteMs + gapMs);
    if (tp >= firstStart && i < notes.length) {
      final into = tp - firstStart - i * (noteMs + gapMs);
      if (into < noteMs) {
        final n = notes[i];
        final noise = (rng.nextDouble() - 0.5) * 4; // ±2¢
        freq = hornFreq(n.partial, slideAt(tp), n.lip + noise);
      }
    }
    frames.add((tMs: t, mm: null, semis: slideAt(t), freq: freq));
  }
  return Take(
      id: 'synth', title: 'synth', started: DateTime(2026), frames: frames);
}

final c4 = targetFor(60, 5),
    eb4 = targetFor(63, 6),
    f4 = targetFor(65, 6),
    g4 = targetFor(67, 8),
    a4 = targetFor(69, 8);

/// The B♭ major scale from the design: overshoots into C4 and E♭4, G4 stops
/// short then creeps out, A4 stays short.
TakeAnalysis synthScale() => TakeAnalysis.analyze(synthScaleTake(), cal);

Take synthScaleTake() => synthTake([
      SynthNote(58, 4, 3, [(0, 0)]),
      // Out to 3rd, overshoots by 0.20, settles 0.12 long.
      SynthNote(60, 5, 6, [(-120, 0), (-50, c4 + 0.20), (-10, c4 + 0.12)]),
      // Back onto the bumper.
      SynthNote(62, 5, -14, [(-120, c4 + 0.12), (-20, 0)]),
      // Overshoot +0.35, settled +0.20, lips not helping.
      SynthNote(63, 6, 0, [(-120, 0), (-40, eb4 + 0.35), (0, eb4 + 0.20)]),
      SynthNote(65, 6, 2, [(-120, eb4 + 0.20), (-20, f4)]),
      // Stops 0.25 short, then creeps out 210 ms into the note.
      SynthNote(67, 8, 1,
          [(-150, f4), (-40, g4 - 0.25), (40, g4 - 0.25), (210, g4 + 0.03)]),
      // Comes in but stays 0.15 short (too far out); lips it up sharp.
      SynthNote(69, 8, 26, [(-120, g4 + 0.03), (-20, a4 + 0.15)]),
      SynthNote(70, 8, -10, [(-120, a4 + 0.15), (-20, 0)]),
    ]);

