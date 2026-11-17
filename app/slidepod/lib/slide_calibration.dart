import 'dart:convert';
import 'dart:math' as math;

/// Pitch-based slide calibration for a Bb tenor trombone.
///
/// Physics: with the slide out by `s` semitones, the fundamental is
/// `F0 / 2^(s/12)`, and partial `n` sounds at `n` times that. So a detected
/// frequency on partial `n` gives the exact slide extension in semitones:
///
///     s = 12 · log2(n · F0 / f)
///
/// Using the true harmonic series (not equal temperament) matters: the 5th
/// partial is ~14¢ flat and the 7th ~31¢ flat, which really does move the slide.
///
/// Slide travel is not linear in semitones. The tube length goes up as
/// `2^(s/12)`, and the slide is a U, so travel is half the added length:
///
///     travel_mm = (L0 / 2) · (2^(s/12) − 1)
///
/// We fit the ToF reading as `mm = a + b · (2^(s/12) − 1)`, with `a` (sensor
/// offset at 1st position) and `b` (≈ L0/2, sign = sensor orientation) found
/// by least squares over pitch-tagged samples.
class SlideCalibration {
  /// Bb1, the pedal tone (fundamental) in 1st position.
  static const double f0 = 58.270470189761239;

  /// Number of semitones from 1st to 7th position.
  static const double maxSemitones = 6.0;

  // Uncalibrated default: the firmware's 50–550 mm range spread over
  // 1st–7th with the correct nonlinear spacing.
  static final double _defaultB = 500.0 / (math.pow(2, 0.5) - 1);
  double a = 50.0;
  late double b = _defaultB;

  /// True once a fit from real pitch samples has replaced the default.
  bool calibrated = false;

  /// Running sums per semitone bucket (0–6) so one position held for a long
  /// time doesn't swamp the fit.
  final _buckets = List.generate(7, (_) => _Bucket());

  static double _x(double semis) => math.pow(2, semis / 12).toDouble() - 1;

  /// Slide extension in semitones (0 = 1st, 6 = 7th) for a ToF reading.
  double semitonesFromMm(double mm) {
    final x = (mm - a) / b;
    if (x <= -0.5) return -12; // nonsense reading; clamp downstream
    return 12 * math.log(1 + x) / math.ln2;
  }

  /// Normalised position 0.0 (1st) … 1.0 (7th), matching the BLE scale.
  double positionFromMm(double mm) =>
      (semitonesFromMm(mm) / maxSemitones).clamp(0.0, 1.0);

  /// Slide extension implied by [freq] on partial [n].
  static double semitonesFromPitch(double freq, int n) =>
      12 * math.log(n * f0 / freq) / math.ln2;

  /// Picks the partial whose implied slide extension is in range and closest
  /// to [sensedSemis] (where the ToF thinks the slide is). Returns
  /// `(partial, semitones)` or null if nothing plausible.
  ///
  /// Neighbouring partials imply extensions at least ~2 semitones apart
  /// (7th vs 8th), so the ToF only needs to be within about a position to
  /// pick the right one.
  static (int, double)? resolvePitch(double freq, double sensedSemis,
      {double maxDistance = 1.0}) {
    (int, double)? best;
    double bestDist = double.infinity;
    for (var n = 2; n <= 8; n++) {
      final s = semitonesFromPitch(freq, n);
      if (s < -0.5 || s > maxSemitones + 0.5) continue;
      final d = (s - sensedSemis).abs();
      if (d < bestDist) {
        bestDist = d;
        best = (n, s);
      }
    }
    return bestDist <= maxDistance ? best : null;
  }

  /// Feeds one pitch-tagged sample. Call only while the slide is roughly
  /// still, so the filtered ToF value isn't lagging the pitch.
  /// Returns the resolved `(partial, semitones)` if the sample was used.
  (int, double)? addSample(double mm, double freq) {
    final hit = resolvePitch(freq, semitonesFromMm(mm),
        // Before the first fit the default mapping can be off by a position
        // or more, so be more forgiving.
        maxDistance: calibrated ? 1.0 : 1.5);
    if (hit == null) return null;
    final (_, s) = hit;
    final bucket = _buckets[s.round().clamp(0, 6)];
    bucket.add(_x(s), mm);
    _refit();
    return hit;
  }

  /// Weighted least squares over bucket means (each bucket weighs the same).
  void _refit() {
    final used = _buckets.where((b) => b.count >= _Bucket.minCount).toList();
    if (used.length < 2) return;
    // Need some spread, or the slope is noise.
    final xs = used.map((b) => b.meanX);
    if (xs.reduce(math.max) - xs.reduce(math.min) < _x(2) - _x(0)) return;

    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (final bk in used) {
      sx += bk.meanX;
      sy += bk.meanY;
      sxx += bk.meanX * bk.meanX;
      sxy += bk.meanX * bk.meanY;
    }
    final k = used.length.toDouble();
    final denom = k * sxx - sx * sx;
    if (denom.abs() < 1e-9) return;
    final newB = (k * sxy - sx * sy) / denom;
    // A Bb tenor's L0/2 is ~1.3 m; reject fits wildly off that.
    if (newB.abs() < 300 || newB.abs() > 5000) return;
    b = newB;
    a = (sy - b * sx) / k;
    calibrated = true;
  }

  /// Number of positions (0–6 semitone buckets) with enough samples.
  int get bucketsFilled =>
      _buckets.where((b) => b.count >= _Bucket.minCount).length;

  /// Serialises the learned samples (not just the fit), so learning
  /// continues across sessions instead of starting from one frozen line.
  String toJson() => jsonEncode({
        'v': 1,
        'buckets': [for (final bk in _buckets) bk.toJson()],
      });

  /// Restores state from [toJson]. Ignores anything malformed.
  void loadJson(String json) {
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      if (m['v'] != 1) return;
      final list = m['buckets'] as List;
      if (list.length != _buckets.length) return;
      reset();
      for (var i = 0; i < list.length; i++) {
        _buckets[i].loadJson(list[i] as List);
      }
      _refit();
    } catch (_) {
      reset();
    }
  }

  void reset() {
    a = 50.0;
    b = _defaultB;
    calibrated = false;
    for (final bk in _buckets) {
      bk.clear();
    }
  }
}

class _Bucket {
  static const minCount = 10; // ~0.2 s of steady tone at 50 Hz
  static const maxCount = 500; // then decay so it tracks drift

  double _sx = 0, _sy = 0;
  int count = 0;

  void add(double x, double y) {
    if (count >= maxCount) {
      // Exponential forgetting: keep the mean, drop the weight.
      _sx *= (maxCount - 1) / maxCount;
      _sy *= (maxCount - 1) / maxCount;
      count = maxCount - 1;
    }
    _sx += x;
    _sy += y;
    count++;
  }

  double get meanX => _sx / count;
  double get meanY => _sy / count;

  void clear() {
    _sx = _sy = 0;
    count = 0;
  }

  List<num> toJson() => [_sx, _sy, count];

  void loadJson(List l) {
    final c = (l[2] as num).toInt();
    if (c <= 0 || c > maxCount) return;
    _sx = (l[0] as num).toDouble();
    _sy = (l[1] as num).toDouble();
    count = c;
  }
}
