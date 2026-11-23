import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seventh/take.dart';
import 'package:seventh/take_analysis.dart';

import 'synth_take.dart';

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
