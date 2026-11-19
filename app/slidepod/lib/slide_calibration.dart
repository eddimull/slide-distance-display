import 'dart:convert';
import 'dart:math' as math;

/// Slide calibration for a Bb tenor trombone, learned by playing.
///
/// Two things are learned together, in calibration mode only:
///
/// 1. **Where the positions are** in ToF millimetres. The sensor's reading
///    does not follow the ideal slide geometry (on the real pod the spacing
///    shrinks with distance: 1st→3rd 233 mm, 5th→7th 137 mm), so instead of a
///    formula we keep one anchor per position and draw a smooth monotone
///    curve through them.
/// 2. **How this horn tunes on each partial.** A real horn's partials are not
///    a perfect harmonic series; on the test horn the 6th partial sat ~13¢
///    sharp and the 2nd and 4th ~9¢ flat with the slide held still.
///
/// With the ToF as the truth for the slide, the difference between the pitch
/// you play and what this horn gives at that slide spot is your lipping.
/// Learning only happens in calibration mode: learning from normal playing
/// would absorb the player's lipping into the "horn" and hide it.
///
/// Physics used to find the partial and the pitch-implied slide extension:
/// with the slide out `s` semitones partial `n` sounds at `n·F0/2^(s/12)`,
/// so `s = 12·log2(n·F0/f)`.
class SlideCalibration {
  /// Bb1, the pedal tone (fundamental) in 1st position.
  static const double f0 = 58.270470189761239;

  /// Number of semitones from 1st to 7th position.
  static const double maxSemitones = 6.0;

  /// Partials used (2nd = Bb2 … 8th = Bb4 in 1st).
  static const int minPartial = 2, maxPartial = 8;

  // Uncalibrated default: 50–550 mm over 1st–7th with ideal spacing.
  static const double _defaultA = 50.0;
  static final double _defaultB = 500.0 / (math.pow(2, 0.5) - 1);

  /// Sample sums per (position 0–6, partial 2–8).
  final _cells = List.generate(
      7, (_) => List.generate(maxPartial - minPartial + 1, (_) => _Cell()));

  /// Horn correction per partial, in semitones (index n − minPartial).
  /// Positive = the horn plays sharp on that partial.
  final _offset = List.filled(maxPartial - minPartial + 1, 0.0);

  /// Anchors (mm, semitones), sorted by mm, once calibrated.
  List<(double, double)> _anchors = const [];
  List<double> _tangents = const [];

  /// True once at least two positions, two semitones apart, are captured.
  bool get calibrated => _anchors.length >= 2;

  /// Positions (1–7) with enough samples to anchor the curve.
  List<int> get capturedPositions => [
        for (var p = 0; p < 7; p++)
          if (_cells[p].any((c) => c.used)) p + 1,
      ];

  /// Number of partials captured at [position] (1–7).
  int partialsAt(int position) =>
      _cells[position - 1].where((c) => c.used).length;

  /// Partials 2–6 not yet heard in at least two positions. Each partial's
  /// horn offset is only known once it's been played; without it the
  /// partial falls back to the horn's average, which on the test horn put
  /// the (≈28¢ sharp) 6th partial's lip reading 25¢ off.
  List<int> get missingPartials => [
        for (var n = minPartial; n <= 6; n++)
          if (_cells.where((row) => row[n - minPartial].used).length < 2) n,
      ];

  /// Enough to stop calibrating: 1st, 3rd, 5th and 7th with two partials
  /// each, and every partial 2–6 heard in two positions.
  bool get complete =>
      [1, 3, 5, 7].every((p) => partialsAt(p) >= 2) && missingPartials.isEmpty;

  /// Horn correction for partial [n], in cents (0 if unknown).
  double partialOffsetCents(int n) =>
      n < minPartial || n > maxPartial ? 0 : 100 * _offset[n - minPartial];

  // ── Slide position from the ToF ──

  /// Slide extension in semitones (0 = 1st, 6 = 7th) for a ToF reading.
  double semitonesFromMm(double mm) {
    if (!calibrated) {
      final x = (mm - _defaultA) / _defaultB;
      if (x <= -0.5) return -12; // nonsense reading; clamp downstream
      return 12 * math.log(1 + x) / math.ln2;
    }
    return _interp(mm);
  }

  /// Normalised position 0.0 (1st) … 1.0 (7th), matching the BLE scale.
  double positionFromMm(double mm) =>
      (semitonesFromMm(mm) / maxSemitones).clamp(0.0, 1.0);

  // ── Pitch ──

  /// Slide extension implied by [freq] on partial [n] on an ideal horn.
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
    for (var n = minPartial; n <= maxPartial; n++) {
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

  /// Where this horn's slide would be to sound [freq], corrected for the
  /// horn's partial tuning: `(partial, semitones)`, or null.
  (int, double)? pitchSlide(double freq, double sensedSemis) {
    final hit = resolvePitch(freq, sensedSemis);
    if (hit == null) return null;
    final (n, s) = hit;
    return (n, s + _offset[n - minPartial]);
  }

  /// Lipping: how far [freq] is from what this horn gives on the same
  /// partial with the slide where the ToF says it is. Returns
  /// `(partial, cents)`; positive = played sharper than the slide gives.
  (int, double)? lipCents(double mm, double freq) {
    final sensed = semitonesFromMm(mm);
    final hit = pitchSlide(freq, sensed);
    if (hit == null) return null;
    final (n, s) = hit;
    return (n, 100 * (sensed - s));
  }

  // ── Learning (calibration mode only) ──

  /// Feeds one sample. Call only in calibration mode, while the slide is
  /// still and a steady note is sounding. Returns `(partial, position 1–7)`
  /// if the sample was used.
  (int, int)? addSample(double mm, double freq) {
    final hit = resolvePitch(freq, semitonesFromMm(mm),
        // Before the first fit the default mapping can be off by more than
        // half a position, so be more forgiving.
        maxDistance: calibrated ? 1.0 : 1.5);
    if (hit == null) return null;
    final (n, s) = hit;
    final p = s.round().clamp(0, 6);
    _cells[p][n - minPartial].add(mm, s);
    _refit();
    return (n, p + 1);
  }

  /// Alternates between the two unknowns: given the horn offsets, each
  /// position's anchor is the mean over its partials of (mm, corrected
  /// pitch slide); given the curve, each partial's offset is how far its
  /// notes sit from the curve.
  ///
  /// A shift shared by every partial can't be told apart from moving the
  /// whole curve, so it is pinned: 1st position (slide closed) is 0
  /// semitones by definition, and any overall sharpness (tuning slide, or a
  /// player who runs sharp) goes into the horn offsets. Without a 1st
  /// position anchor the mean offset is pinned to 0 instead.
  void _refit() {
    _offset.fillRange(0, _offset.length, 0);
    final has = [
      for (var i = 0; i < _offset.length; i++) _cells.any((row) => row[i].used)
    ];
    for (var iter = 0; iter < 6; iter++) {
      _setAnchors(_rawAnchors());
      if (!calibrated) {
        _offset.fillRange(0, _offset.length, 0);
        return;
      }
      for (var i = 0; i < _offset.length; i++) {
        if (!has[i]) continue;
        var d = 0.0, k = 0;
        for (final row in _cells) {
          final c = row[i];
          if (!c.used) continue;
          d += _interp(c.meanMm) - c.meanS;
          k++;
        }
        _offset[i] = d / k;
      }
      _shiftOffsets(-_mean(has));
    }
    // Gauge on 1st position, if captured.
    final first = _rawAnchor(_cells[0]);
    if (first != null) _shiftOffsets(-first.$2);
    // Partials never played get the horn's average.
    final avg = _mean(has);
    for (var i = 0; i < _offset.length; i++) {
      if (!has[i]) _offset[i] = avg;
    }
    _setAnchors(_rawAnchors());
  }

  double _mean(List<bool> has) {
    var t = 0.0, k = 0;
    for (var i = 0; i < _offset.length; i++) {
      if (has[i]) {
        t += _offset[i];
        k++;
      }
    }
    return k > 0 ? t / k : 0;
  }

  void _shiftOffsets(double by) {
    for (var i = 0; i < _offset.length; i++) {
      _offset[i] += by;
    }
  }

  /// (mean mm, mean corrected slide) over the partials played at a position.
  (double, double)? _rawAnchor(List<_Cell> row) {
    var mm = 0.0, s = 0.0, k = 0;
    for (var i = 0; i < row.length; i++) {
      final c = row[i];
      if (!c.used) continue;
      mm += c.meanMm;
      s += c.meanS + _offset[i];
      k++;
    }
    return k > 0 ? (mm / k, s / k) : null;
  }

  List<(double, double)> _rawAnchors() =>
      [for (final row in _cells) ?_rawAnchor(row)];

  /// Keeps anchors that make a monotone curve, then builds it. Needs two
  /// anchors at least two semitones apart, or the curve is noise.
  void _setAnchors(List<(double, double)> raw) {
    final a = [...raw]..sort((x, y) => x.$2.compareTo(y.$2)); // by semitones
    _anchors = const [];
    _tangents = const [];
    if (a.length < 2 || a.last.$2 - a.first.$2 < 2) return;
    // Sensor orientation: mm rises or falls with extension.
    final rising = a.last.$1 > a.first.$1;
    final mono = <(double, double)>[a.first];
    for (final p in a.skip(1)) {
      if (rising ? p.$1 > mono.last.$1 : p.$1 < mono.last.$1) mono.add(p);
    }
    if (mono.length < 2 || mono.last.$2 - mono.first.$2 < 2) return;
    if (!rising) mono.sort((x, y) => x.$1.compareTo(y.$1));
    _anchors = mono;
    _tangents = _fritschCarlson(mono);
  }

  /// Monotone cubic tangents (Fritsch–Carlson) for points sorted by x.
  static List<double> _fritschCarlson(List<(double, double)> p) {
    final n = p.length;
    final d = [
      for (var i = 0; i < n - 1; i++)
        (p[i + 1].$2 - p[i].$2) / (p[i + 1].$1 - p[i].$1)
    ];
    final m = List.filled(n, 0.0);
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for (var i = 1; i < n - 1; i++) {
      m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
    }
    for (var i = 0; i < n - 1; i++) {
      if (d[i] == 0) {
        m[i] = m[i + 1] = 0;
        continue;
      }
      final a = m[i] / d[i], b = m[i + 1] / d[i];
      final h = a * a + b * b;
      if (h > 9) {
        final t = 3 / math.sqrt(h);
        m[i] = t * a * d[i];
        m[i + 1] = t * b * d[i];
      }
    }
    return m;
  }

  /// Curve through the anchors; straight-line extension past the ends.
  double _interp(double mm) {
    final p = _anchors, m = _tangents;
    if (mm <= p.first.$1) return p.first.$2 + (mm - p.first.$1) * m.first;
    if (mm >= p.last.$1) return p.last.$2 + (mm - p.last.$1) * m.last;
    var i = 0;
    while (mm > p[i + 1].$1) {
      i++;
    }
    final h = p[i + 1].$1 - p[i].$1;
    final t = (mm - p[i].$1) / h;
    final t2 = t * t, t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * p[i].$2 +
        (t3 - 2 * t2 + t) * h * m[i] +
        (-2 * t3 + 3 * t2) * p[i + 1].$2 +
        (t3 - t2) * h * m[i + 1];
  }

  // ── Persistence ──

  /// Serialises the samples (not just the fit).
  String toJson() => jsonEncode({
        'v': 2,
        'cells': [
          for (final row in _cells) [for (final c in row) c.toJson()]
        ],
      });

  /// Restores state from [toJson]. Anything malformed or from an older
  /// version leaves a clean, uncalibrated state.
  void loadJson(String json) {
    reset();
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      if (m['v'] != 2) return;
      final rows = m['cells'] as List;
      if (rows.length != _cells.length) return;
      for (var p = 0; p < rows.length; p++) {
        final row = rows[p] as List;
        if (row.length != _cells[p].length) throw const FormatException();
        for (var i = 0; i < row.length; i++) {
          _cells[p][i].loadJson(row[i] as List);
        }
      }
      _refit();
    } catch (_) {
      reset();
    }
  }

  void reset() {
    for (final row in _cells) {
      for (final c in row) {
        c.clear();
      }
    }
    _offset.fillRange(0, _offset.length, 0);
    _anchors = const [];
    _tangents = const [];
  }
}

class _Cell {
  static const minCount = 10; // ~0.2 s of steady tone
  static const maxCount = 500; // then decay so a re-calibration takes over

  double _sMm = 0, _sS = 0;
  int count = 0;

  bool get used => count >= minCount;

  void add(double mm, double s) {
    if (count >= maxCount) {
      // Exponential forgetting: keep the mean, drop the weight.
      _sMm *= (maxCount - 1) / maxCount;
      _sS *= (maxCount - 1) / maxCount;
      count = maxCount - 1;
    }
    _sMm += mm;
    _sS += s;
    count++;
  }

  double get meanMm => _sMm / count;
  double get meanS => _sS / count;

  void clear() {
    _sMm = _sS = 0;
    count = 0;
  }

  List<num> toJson() => [_sMm, _sS, count];

  void loadJson(List l) {
    final c = (l[2] as num).toInt();
    if (c <= 0 || c > maxCount) return;
    _sMm = (l[0] as num).toDouble();
    _sS = (l[1] as num).toDouble();
    count = c;
  }
}
