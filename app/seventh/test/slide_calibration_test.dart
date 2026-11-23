import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:seventh/slide_calibration.dart';
import 'package:seventh/upper_partials.dart';

import 'sim_horn.dart';

/// Plays a steady note on [partial] at [pos] (1–7) for [secs] through the
/// listener, then a moment of silence.
void playNote(
  UpperPartialListener l,
  DateTime t0,
  int partial,
  int pos, {
  double lip = 0,
  double wobble = 6,
  double secs = 1.0,
  int seed = 0,
}) {
  final rng = math.Random(seed);
  final s = pos - 1.0;
  var t = 0.0;
  for (; t < secs; t += 0.0176) {
    l.feed(
      t0.add(Duration(microseconds: (t * 1e6).round())),
      mmAt(s) + (rng.nextDouble() - 0.5) * 3,
      freqAt(partial, s, lip + (rng.nextDouble() - 0.5) * wobble),
      still: true,
    );
  }
  l.feed(
    t0.add(Duration(microseconds: (t * 1e6).round())),
    mmAt(s),
    null,
    still: true,
  );
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

  test('three glisses map every position', () {
    final cal = glissCalibrated();
    expect(cal.calibrated, isTrue);
    expect(cal.glissedPartials, [2, 3, 4]);
    for (var p = 1; p <= 7; p++) {
      expect(
        cal.semitonesFromMm(mmAt(p - 1.0)),
        closeTo(p - 1.0, 0.08),
        reason: 'position $p',
      );
    }
  });

  test('one gliss is already enough to map the slide', () {
    final cal = SlideCalibration();
    final take = runTake(3, glissFrames(3));
    cal.addGliss(3, take.samples, take.closedMm!);
    expect(cal.calibrated, isTrue);
    for (var p = 1; p <= 7; p++) {
      expect(
        cal.semitonesFromMm(mmAt(p - 1.0)),
        closeTo(p - 1.0, 0.1),
        reason: 'position $p',
      );
    }
  });

  test('learns the gliss partials\' tuning', () {
    final cal = glissCalibrated();
    for (final n in [2, 3, 4]) {
      expect(
        cal.partialOffsetCents(n),
        closeTo(hornCents[n]!, 4),
        reason: 'partial $n',
      );
    }
  });

  test('upper partials start from the educated guess', () {
    final cal = glissCalibrated();
    final lower =
        [2, 3, 4].map(cal.partialOffsetCents).reduce((a, b) => a + b) / 3;
    SlideCalibration.upperPrior.forEach((n, c) {
      expect(
        cal.partialOffsetCents(n),
        closeTo(lower + c, 1e-6),
        reason: 'partial $n',
      );
      expect(cal.notesHeard(n), 0);
    });
    expect(cal.learnedUpper, isEmpty);
  });

  test('upper partials are learned from steady notes while playing', () {
    final cal = glissCalibrated();
    final l = UpperPartialListener(cal);
    var t = DateTime(2026, 11, 20);
    var seed = 0;
    for (var rep = 0; rep < 4; rep++) {
      for (final (n, pos) in [(5, 1), (5, 4), (6, 2), (6, 5), (7, 1), (8, 3)]) {
        playNote(l, t, n, pos, seed: seed++);
        t = t.add(const Duration(seconds: 2));
      }
    }
    expect(cal.learnedUpper, [5, 6, 7, 8]);
    // Blended with the guess (3 notes' worth), so not all the way there yet.
    for (final n in [5, 6, 7, 8]) {
      final guess = cal.partialOffsetCents(n);
      expect(guess, closeTo(hornCents[n]!, 8), reason: 'partial $n');
    }
    expect(cal.notesHeard(6), 8);
  });

  test('bends, wrong partials and short notes are not learned', () {
    final cal = glissCalibrated();
    final l = UpperPartialListener(cal);
    final before = cal.partialOffsetCents(6);
    final t = DateTime(2026, 11, 20);
    // Short.
    playNote(l, t, 6, 3, secs: 0.4);
    // A wide bend: spreads ±40¢ across the note.
    playNote(l, t.add(const Duration(seconds: 2)), 6, 3, wobble: 80);
    // Lipped 70¢ off the estimate.
    playNote(l, t.add(const Duration(seconds: 4)), 6, 3, lip: -70);
    expect(cal.notesHeard(6), 0);
    expect(cal.partialOffsetCents(6), before);
  });

  test('nothing is learned before the slide is calibrated', () {
    final cal = SlideCalibration();
    final l = UpperPartialListener(cal);
    playNote(l, DateTime(2026, 11, 20), 6, 1, secs: 2);
    expect(cal.notesHeard(6), 0);
  });

  test('with no ToF reading, the pitch places the slide', () {
    final cal = glissCalibrated();
    // B2 on the 3rd partial in 7th, last seen in 6th.
    expect(cal.semitonesFromPitchNear(freqAt(3, 6.0), 5.0), closeTo(6.0, 0.05));
    // F3: 3rd partial in 1st or 4th partial in ~5th; the slide was in 5th.
    expect(cal.semitonesFromPitchNear(freqAt(4, 3.95), 4.0), closeTo(3.95, 0.05));
    // Fast moves while blind: still found 2½ semitones from where it was.
    expect(cal.semitonesFromPitchNear(freqAt(2, 6.0), 3.5), closeTo(6.0, 0.05));
    expect(cal.semitonesFromPitchNear(null, 3.0), isNull);
  });

  test('reads lipping as the pitch vs where the slide is', () {
    final cal = glissCalibrated();
    for (final (pos, partial) in [(1, 4), (3, 2), (5, 3), (7, 4), (4, 3)]) {
      final s = pos - 1.0;
      for (final lip in [0.0, 20.0, -25.0]) {
        final (n, cents) = cal.lipCents(mmAt(s), freqAt(partial, s, lip))!;
        expect(n, partial);
        expect(
          cents,
          closeTo(lip, 8),
          reason: 'pos $pos partial $partial lip $lip',
        );
      }
    }
  });

  test('round-trips through JSON, heard notes included', () {
    final cal = glissCalibrated();
    final l = UpperPartialListener(cal);
    playNote(l, DateTime(2026, 11, 20), 6, 2);
    expect(cal.notesHeard(6), 1);
    final restored = SlideCalibration()..loadJson(cal.toJson());
    expect(restored.calibrated, isTrue);
    expect(restored.notesHeard(6), 1);
    for (final mm in [0.0, 100.0, 300.0, 600.0]) {
      expect(
        restored.semitonesFromMm(mm),
        closeTo(cal.semitonesFromMm(mm), 1e-9),
      );
    }
    for (var n = 2; n <= 8; n++) {
      expect(
        restored.partialOffsetCents(n),
        closeTo(cal.partialOffsetCents(n), 1e-9),
      );
    }

    // Garbage or an unknown format leaves a clean, uncalibrated state.
    for (final bad in ['{"v":3,"cells":"nope"}', '{"v":1,"buckets":[]}', 'x']) {
      final c = SlideCalibration()..loadJson(bad);
      expect(c.calibrated, isFalse);
    }
  });

  test('carries over a calibration from the held-note flow (v2)', () {
    // v2: per position (1st–7th) × partial (2–8), [sum mm, sum semis, n].
    // Held notes in 1st, 3rd, 5th, 7th on partials 2–6.
    final cells = [
      for (var p = 0; p < 7; p++)
        [
          for (var n = 2; n <= 8; n++)
            p.isEven && n <= 6
                ? [mmAt(p.toDouble()) * 20, (p - hornCents[n]! / 100) * 20, 20]
                : [0, 0, 0],
        ],
    ];
    final cal = SlideCalibration()
      ..loadJson(jsonEncode({'v': 2, 'cells': cells}));
    expect(cal.calibrated, isTrue);
    for (final p in [1, 3, 5, 7]) {
      expect(
        cal.semitonesFromMm(mmAt(p - 1.0)),
        closeTo(p - 1.0, 0.02),
        reason: 'position $p',
      );
    }
    // Partials that were played keep what was measured; 7th and 8th get the
    // guess.
    expect(cal.partialOffsetCents(6), closeTo(hornCents[6]!, 1));
    final lower =
        [2, 3, 4].map(cal.partialOffsetCents).reduce((a, b) => a + b) / 3;
    expect(
      cal.partialOffsetCents(7),
      closeTo(lower + SlideCalibration.upperPrior[7]!, 1e-6),
    );
  });
}
