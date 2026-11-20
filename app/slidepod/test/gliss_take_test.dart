import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/gliss_take.dart';
import 'package:slidepod/slide_calibration.dart';

import 'sim_horn.dart';

void main() {
  test('a slow gliss is accepted', () {
    final take = runTake(3, glissFrames(3));
    expect(take.phase, GlissPhase.done);
    expect(take.issue, isNull);
    expect(take.closedMm, closeTo(mmAnchors[0], 2));
    expect(take.reached, greaterThan(GlissTake.endSemis));
    expect(take.samples.length, greaterThan(250));
  });

  test('pairs each pitch with the ToF reading from when it was played', () {
    // With the pitch 40 ms behind the slide, pairing it with the ToF reading
    // at the same moment reads positions up to ~0.05 semitone short.
    final take = runTake(3, glissFrames(3));
    final cal = SlideCalibration()..addGliss(3, take.samples, take.closedMm!);
    for (final p in [2, 4, 6]) {
      expect(
        cal.semitonesFromMm(mmAt(p - 1.0)),
        closeTo(p - 1.0, 0.03),
        reason: 'position $p',
      );
    }
  });

  test('a gliss still counts when the ToF loses the slide far out', () {
    // No readings past 480 mm (about 5th½): the pitch still carries the
    // take to 7th, and the sensor-blind part just gives no samples.
    final take = runTake(3, glissFrames(3, blind: (mm) => mm > 480));
    expect(take.phase, GlissPhase.done);
    expect(take.samples.map((p) => p.$1), everyElement(lessThan(490)));
    final cal = SlideCalibration()..addGliss(3, take.samples, take.closedMm!);
    for (final p in [1, 3, 5]) {
      expect(cal.semitonesFromMm(mmAt(p - 1.0)), closeTo(p - 1.0, 0.05),
          reason: 'position $p');
    }
  });

  test('too fast a sweep is thrown away', () {
    final take = runTake(3, glissFrames(3, sweep: const Duration(seconds: 1)));
    expect(take.phase, GlissPhase.waiting);
    expect(take.issue, GlissIssue.tooFast);
    expect(take.samples, isEmpty);
  });

  test('a note that stops before 7th is thrown away', () {
    final take = runTake(3, glissFrames(3, toSemis: 3.5));
    expect(take.issue, GlissIssue.stoppedEarly);
    // A breath halfway.
    final breath = runTake(
      3,
      glissFrames(3, tamper: (t, f) => t > 3.0 && t < 3.3 ? null : f),
    );
    expect(breath.issue, GlissIssue.stoppedEarly);
  });

  test('jumping to another partial is caught', () {
    // Pops up to the 4th partial partway out.
    final take = runTake(
      3,
      glissFrames(
        3,
        tamper: (t, f) => t > 3.0 && t < 3.6 && f != null ? f * 4 / 3 : f,
      ),
    );
    expect(take.issue, GlissIssue.jumped);
  });

  test('a one-frame pitch glitch is ignored', () {
    final take = runTake(
      3,
      glissFrames(
        3,
        tamper: (t, f) => t > 3.0 && t < 3.02 && f != null ? f * 2 : f,
      ),
    );
    expect(take.phase, GlissPhase.done);
  });

  test('the wrong start note never starts a take', () {
    // Asked for F3 (3rd partial), playing the 4th partial gliss instead.
    final take = runTake(3, glissFrames(4));
    expect(take.phase, GlissPhase.waiting);
    expect(take.issue, isNull);
  });

  test('after a failed take the next one starts by itself', () {
    final take = GlissTake(3);
    glissFrames(3, sweep: const Duration(seconds: 1)).forEach(take.feed);
    expect(take.issue, GlissIssue.tooFast);
    glissFrames(3, start: DateTime(2026, 11, 20, 0, 1)).forEach(take.feed);
    expect(take.phase, GlissPhase.done);
    expect(take.issue, isNull);
  });
}
