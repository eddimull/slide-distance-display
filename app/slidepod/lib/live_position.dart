import 'trombone_chart.dart';

/// Which position (1–7) the Live view shows for the slide.
///
/// Rounding to the nearest position flips at the halfway point (2.50
/// between 3rd and 4th), but a horn plays a note in tune where it plays
/// it, which can be ~0.4 from the chart: an in-tune 3rd at 2.55 would
/// show as a very sharp 4th. So, like the Learn games (rules version 2), a
/// position counts within [tolerance] of it:
///
/// - the shown position stays until the slide is more than [tolerance]
///   from it (so it doesn't flicker at the boundary), and
/// - while a note sounds, of the positions within [tolerance], the one
///   that note is in tune for wins (so coming in from 4th, a 3rd played
///   in tune at 2.55 shows as 3rd too).
class LivePosition {
  static const tolerance = 0.6;

  int? _held;

  /// The position shown last; null before any reading.
  int? get position => _held;

  /// [semis] is the slide's extension (0 = 1st, 6 = 7th); [freq] the pitch
  /// heard (null or ≤ 30 Hz = silence).
  int update(double semis, {double? freq}) {
    final held = _held;
    if (held == null || (semis - (held - 1)).abs() > tolerance) {
      _held = (1 + semis.round()).clamp(1, 7);
    }
    if (freq != null && freq > 30) {
      int? best;
      double? bestCents;
      for (var p = 1; p <= 7; p++) {
        if ((semis - (p - 1)).abs() > tolerance) continue;
        final (note, c) = TromboneChart.closestAt(p, freq);
        if (note.partial < 2 || c.abs() >= 100) continue;
        if (bestCents == null || c.abs() < bestCents) {
          best = p;
          bestCents = c.abs();
        }
      }
      if (best != null) _held = best;
    }
    return _held!;
  }

  void reset() => _held = null;
}
