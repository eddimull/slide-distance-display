import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/slide_calibration.dart';
import 'package:slidepod/take.dart';
import 'package:slidepod/take_analysis.dart';

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
TakeAnalysis synthScale() => TakeAnalysis.analyze(
    synthTake([
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
    ]),
    cal);

void main() {
  group('synthetic B♭ major scale', () {
    final a = synthScale();
    final byName = {for (final n in a.notes) n.name: n};

    test('finds the eight notes', () {
      expect(a.notes.map((n) => n.midi), [58, 60, 62, 63, 65, 67, 69, 70]);
      for (final n in a.notes) {
        expect(n.durationMs, greaterThan(800), reason: n.name);
      }
    });

    test('resolves partial and this horn\'s slide spot', () {
      expect(byName['Eb4']!.partial, 6);
      expect(byName['Eb4']!.targetSemis, closeTo(eb4, 0.01));
      expect(byName['Eb4']!.targetPosition, 3);
      expect(byName['G4']!.targetPosition, 4);
      expect(byName['A4']!.targetPosition, 2);
    });

    test('overshoot: E♭4 went 0.35 past and rested 0.20 past', () {
      final s = byName['Eb4']!.shift!;
      expect(s.result, ShiftResult.overshot);
      expect(s.direction, 1);
      expect(s.peakError, closeTo(0.35, 0.03));
      expect(s.landedError, closeTo(0.20, 0.02));
      expect(s.peakSpeed, greaterThan(5));
    });

    test('undershoot: G4 stopped short, crept out late', () {
      final s = byName['G4']!.shift!;
      expect(s.result, ShiftResult.short);
      expect(s.firstStopError, closeTo(-0.25, 0.05));
      expect(s.crept, isTrue);
      expect(s.settleAfterOnsetMs, greaterThan(100));
      expect(byName['G4']!.lateSlide, isTrue);
    });

    test('undershoot coming in: A4 rested too far out', () {
      final s = byName['A4']!.shift!;
      expect(s.direction, -1);
      expect(s.result, ShiftResult.short);
      expect(s.landedError, closeTo(-0.15, 0.02));
      expect(s.crept, isFalse);
    });

    test('clean moves, and the bumper never counts as overshoot', () {
      expect(byName['F4']!.shift!.result, ShiftResult.clean);
      expect(byName['D4']!.shift!.toBumper, isTrue);
      expect(byName['D4']!.shift!.result, ShiftResult.clean);
      expect(byName['Bb4']!.shift!.result, ShiftResult.clean);
      expect(byName['Bb3']!.shift, isNull);
    });

    test('intonation and its cause: slide vs lips', () {
      final eb = byName['Eb4']!;
      expect(eb.cents, closeTo(-20, 3));
      expect(eb.slideCents, closeTo(-20, 2));
      expect(eb.cause, NoteCause.slide);

      // D4 on the 5th partial: this horn wants the slide inside 1st, which
      // it can't reach, so all of it is the lips'.
      final d = byName['D4']!;
      expect(d.targetSemis, lessThan(0));
      expect(d.cause, NoteCause.lip);
      expect(d.slideCents, closeTo(0, 1));
      expect(d.lipCents, closeTo(d.cents, 0.01));

      // A4: the slide made it 15¢ flat, the lips pushed it 26¢ sharp.
      final a4n = byName['A4']!;
      expect(a4n.slideCents, closeTo(-15, 2));
      expect(a4n.cents, closeTo(11, 3));
      expect(a4n.cause, NoteCause.lip);

      expect(byName['Bb3']!.cause, NoteCause.inTune);
      expect(byName['F4']!.cause, NoteCause.inTune);
    });

    test('summary', () {
      expect(a.shifts, hasLength(7));
      expect(a.overshoots, 2);
      expect(a.shorts, 2);
      expect(a.cleanShifts, 3);
      expect(a.peakSpeed, greaterThan(5));
    });
  });

  test('a new partial at the same position is not a slide move', () {
    final a = TakeAnalysis.analyze(
        synthTake([
          SynthNote(46, 2, 0, [(0, 0)]), // B♭2
          SynthNote(53, 3, 0, [(0, 0)]), // F3
          SynthNote(58, 4, 0, [(0, 0)]), // B♭3
        ]),
        cal);
    expect(a.notes, hasLength(3));
    expect(a.shifts, isEmpty);
  });

  test('real session: long tones on partials 2–8 in 1st, 3rd, 5th, 7th', () {
    // t_s, raw_mm, filt_mm, mic_hz ('-' = no pitch)
    final rows = File('test/fixtures/partials_session.csv')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .map((l) => l.split(','));
    final frames = <TakeFrame>[
      for (final r in rows)
        (
          tMs: (double.parse(r[0]) * 1000).round(),
          mm: double.parse(r[2]),
          semis: cal.semitonesFromMm(double.parse(r[2])),
          freq: r[3] == '-' ? null : double.parse(r[3]),
        ),
    ];
    final take = Take(
        id: 'real', title: 'real', started: DateTime(2026), frames: frames);
    final a = TakeAnalysis.analyze(take, cal);
    // The long tones (4 positions × 7 partials), give or take one missed;
    // shorter runs are the session's opening gliss and mic glitches.
    final held = a.notes.where((n) => n.durationMs >= 800).toList();
    expect(held.length, inInclusiveRange(24, 30));
    expect({for (final n in held) n.targetPosition}, containsAll([1, 3, 5, 7]));
    // Consecutive tones in one position are not moves; the four position
    // changes (made in the rests between sets) are.
    final moves = held.where((n) => n.shift != null).toList();
    expect(moves.length, inInclusiveRange(4, 8));
    int? dirAt(int ms) => a.notes
        .firstWhere((n) => (n.startMs - ms).abs() < 200)
        .shift
        ?.direction;
    expect(dirAt(29536), -1); // 7th → 1st
    expect(dirAt(42972), 1); // → 3rd
    expect(dirAt(56265), 1); // → 5th
    expect(dirAt(69612), 1); // → 7th
  });
}
