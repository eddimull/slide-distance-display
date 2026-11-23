import 'slide_calibration.dart';

/// Learns the upper partials' (5th–8th) tuning in the background, from
/// normal playing.
///
/// Only long, steady notes with the slide still count. For each, the
/// middle of the note (no attack or release) gives how far the ideal-horn
/// slide for that pitch sits from where the ToF has the slide; the median
/// of that is handed to [SlideCalibration.addUpperNote], which blends it
/// with the partial's educated guess.
///
/// This is learning from normal playing, so a player who always lips a
/// note the same way will have that absorbed into the horn's tuning. Long
/// steady notes and medians keep one-off bends out.
class UpperPartialListener {
  final SlideCalibration cal;
  UpperPartialListener(this.cal);

  /// Shortest note that counts.
  static const minNote = Duration(milliseconds: 600);

  /// A note whose middle half spreads wider than this (cents) is a bend or a
  /// shaky note, not the horn.
  static const double maxSpread = 20;

  int? _n;
  DateTime? _start;
  final _d = <double>[];

  /// Feeds one reading. [still]: the slide isn't moving. Returns the partial
  /// learned from if a note just ended and was taken.
  int? feed(DateTime t, double mm, double? freq, {required bool still}) {
    if (!cal.calibrated || freq == null || freq <= 30 || !still) return _end(t);
    final sensed = cal.semitonesFromMm(mm);
    final hit = SlideCalibration.resolvePitch(freq, sensed);
    if (hit == null || hit.$1 < SlideCalibration.firstUpper) return _end(t);
    final (n, s) = hit;
    int? learned;
    if (n != _n) {
      learned = _end(t);
      _n = n;
      _start = t;
    }
    _d.add(100 * (sensed - s));
    return learned;
  }

  int? _end(DateTime t) {
    final n = _n, start = _start;
    _n = null;
    _start = null;
    if (n == null || start == null) return null;
    final d = [..._d];
    _d.clear();
    if (t.difference(start) < minNote || d.length < 20) return null;
    // Middle 60%: skip the attack and the release.
    final mid = d.sublist((d.length * 0.2).floor(), (d.length * 0.8).ceil())
      ..sort();
    final q1 = mid[mid.length ~/ 4], q3 = mid[(mid.length * 3) ~/ 4];
    if (q3 - q1 > maxSpread) return null;
    return cal.addUpperNote(n, mid[mid.length ~/ 2]) ? n : null;
  }

  void reset() {
    _n = null;
    _start = null;
    _d.clear();
  }
}
