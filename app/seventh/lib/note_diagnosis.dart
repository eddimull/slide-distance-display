import 'dart:math' as math;

import 'slide_calibration.dart';
import 'take_analysis.dart';
import 'take_style.dart';

enum DiagnosisKind { good, slide, lip }

/// What went on with one note, in a player's words.
class NoteDiagnosis {
  final DiagnosisKind kind;
  final String headline;
  final String body;
  const NoteDiagnosis(this.kind, this.headline, this.body);
}

String ordinal(int n) => switch (n % 100) {
      11 || 12 || 13 => '${n}th',
      _ => switch (n % 10) {
          1 => '${n}st',
          2 => '${n}nd',
          3 => '${n}rd',
          _ => '${n}th',
        },
    };

/// ToF millimetres for [semis] of extension (the inverse of
/// [SlideCalibration.semitonesFromMm], which rises with distance).
double mmAtSemis(SlideCalibration cal, double semis) {
  var lo = -50.0, hi = 1500.0;
  for (var i = 0; i < 40; i++) {
    final mid = (lo + hi) / 2;
    if (cal.semitonesFromMm(mid) < semis) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return (lo + hi) / 2;
}

NoteDiagnosis diagnose(NoteAnalysis n, SlideCalibration cal) {
  final pos = n.targetPosition;
  final posName = pos == null ? 'the position' : ordinal(pos);
  final shift = n.shift;
  final late = n.lateSlide && shift != null
      ? ' The slide was still moving ${shift.settleAfterOnsetMs} ms into the note.'
      : '';

  if (n.cause == NoteCause.inTune) {
    final buf = StringBuffer('Within ±10¢ (${centsLabel(n.cents)}).');
    if (shift != null && shift.result == ShiftResult.overshot) {
      buf.write(' The slide went ${posDelta(shift.peakError)} past '
          '$posName on the way and settled ${posDelta(shift.landedError)}.');
    } else if (shift != null && shift.result == ShiftResult.short) {
      buf.write(shift.crept
          ? ' The slide stopped ${posDelta(shift.firstStopError)} short '
              'of $posName, then crept on.'
          : ' The slide rested ${posDelta(shift.landedError)} short of '
              '$posName; the lips covered it.');
    }
    buf.write(late);
    return NoteDiagnosis(DiagnosisKind.good, 'In tune', buf.toString());
  }

  final landed = n.landedSemis, target = n.targetSemis;
  final sc = n.slideCents, lc = n.lipCents;

  if (n.cause == NoteCause.slide && landed != null && target != null && sc != null) {
    final reach = math.max(target, 0.0);
    final err = landed - reach; // + = further out
    final mm = (mmAtSemis(cal, landed) - mmAtSemis(cal, reach)).abs();
    final out = err > 0;
    return NoteDiagnosis(
      DiagnosisKind.slide,
      'Slide too far ${out ? 'out' : 'in'} by ${err.abs().toStringAsFixed(2)}',
      'About ${(mm / 10).toStringAsFixed(1)} cm ${out ? 'past' : 'short of'} '
          '$posName. Landing at ${(1 + landed).toStringAsFixed(2)} gives '
          '${centsLabel(sc)}, and you played ${centsLabel(n.cents)}, so the '
          'pitch followed the slide. '
          '${out ? 'Bring the slide in.' : 'Take the slide out a little further.'}'
          '$late',
    );
  }

  // The lips.
  final sharp = n.cents > 0;
  if (target != null && target < 0 && landed != null) {
    return NoteDiagnosis(
      DiagnosisKind.lip,
      'Needs lipping ${sharp ? 'down' : 'up'}',
      'On the ${ordinal(n.partial ?? 0)} partial your horn wants the slide '
          'inside 1st, which it can\'t reach. You played '
          '${centsLabel(n.cents)}: lip it ${sharp ? 'down' : 'up'}, or try an '
          'alternate position.$late',
    );
  }
  final lip = lc ?? n.cents;
  final slidePart = sc == null
      ? ''
      : ' The slide was within ${((landed ?? 0) - math.max(target ?? 0, 0)).abs().toStringAsFixed(2)} '
          'of $posName, which only accounts for ${centsLabel(sc)}.';
  return NoteDiagnosis(
    DiagnosisKind.lip,
    'Lips pulled it ${lip > 0 ? 'sharp' : 'flat'} by ${lip.abs().round()}¢',
    'You played ${centsLabel(n.cents)}.$slidePart '
        'Aim the note ${sharp ? 'down' : 'up'} with the air and lips.$late',
  );
}
