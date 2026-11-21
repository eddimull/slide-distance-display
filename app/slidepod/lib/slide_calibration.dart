import 'dart:convert';
import 'dart:math' as math;

/// Slide calibration for a Bb tenor trombone, learned by playing.
///
/// Two things are learned:
///
/// 1. **Where the slide is** in ToF millimetres. The sensor's reading does
///    not follow the ideal slide geometry (on the real pod the spacing
///    shrinks with distance: 1st→3rd 233 mm, 5th→7th 137 mm), so instead of a
///    formula we keep anchors every quarter semitone and draw a smooth
///    monotone curve through them. They come from guided glissandos
///    ([addGliss]): one slow sweep from 1st to 7th on a known partial gives
///    an (mm, pitch) pair at every point along the slide.
/// 2. **How this horn tunes on each partial.** A real horn's partials are not
///    a perfect harmonic series; on the test horn the 6th partial sat ~30¢
///    sharp of the 2nd–4th. The gliss partials (2nd–4th) are fitted along
///    with the curve. The upper partials (5th–8th) start from an educated
///    guess ([upperPrior]) and are refined in the background from long,
///    steady notes ([addUpperNote]).
///
/// With the ToF as the truth for the slide, the difference between the pitch
/// you play and what this horn gives at that slide spot is your lipping.
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

  /// Partials played as guided glissandos: Bb2→E2, F3→B2, Bb3→E3.
  static const glissPartials = [2, 3, 4];

  /// Partials from here up are learned in the background.
  static const int firstUpper = 5;

  /// Educated guess for the upper partials before any are heard: cents
  /// sharp of the 2nd–4th partials' average. Measured on the test horn
  /// (held notes in 1st, 3rd, 5th and 7th, 2026-11-19): 5th +12, 6th +30,
  /// 7th +29, 8th +14. That includes how that player habitually lips them
  /// (the 5th and 7th partials sit flat of equal temperament and get
  /// lipped up), which is what the background learning converges on anyway.
  static const upperPrior = {5: 12.0, 6: 30.0, 7: 29.0, 8: 14.0};

  /// The guess counts as this many notes against what's heard.
  static const int priorWeight = 3;

  /// Notes heard before a partial counts as learned (for display).
  static const int notesToLearn = 3;

  /// Notes kept per partial; older ones are dropped so the estimate follows
  /// the horn (a new mouthpiece, a different tuning slide habit).
  static const int maxNotes = 20;

  /// A note further than this (cents) from the current estimate is not
  /// taken: a wrong partial, or a deliberate bend.
  static const double maxNoteDeviation = 50;

  // Anchor bins on the semitone axis: −0.5 … 6.75 every 0.25.
  static const double _binMin = -0.5, _binWidth = 0.25;
  static const int _binCount = 30;
  static const int _nPartials = maxPartial - minPartial + 1;

  // Uncalibrated default: 50–550 mm over 1st–7th with ideal spacing.
  static const double _defaultA = 50.0;
  static final double _defaultB = 500.0 / (math.pow(2, 0.5) - 1);

  /// Sample sums per (semitone bin, partial).
  final _cells = List.generate(
    _binCount,
    (_) => List.generate(_nPartials, (_) => _Cell()),
  );

  /// ToF reading with the slide closed (1st), averaged over glisses. Pins
  /// the curve: 1st is 0 semitones by definition.
  double _closedSum = 0;
  int _closedCount = 0;

  /// Upper-partial notes heard while playing: cents, per partial.
  final _notes = List.generate(_nPartials, (_) => <double>[]);

  /// Horn correction per partial, in semitones (index n − minPartial).
  /// Positive = the horn plays sharp on that partial.
  final _offset = List.filled(_nPartials, 0.0);

  /// Anchors (mm, semitones), sorted by mm, once calibrated.
  List<(double, double)> _anchors = const [];
  List<double> _tangents = const [];

  /// True once the slide is mapped (two anchors, two semitones apart).
  bool get calibrated => _anchors.length >= 2;

  /// Gliss partials with data.
  List<int> get glissedPartials => [
    for (final n in glissPartials)
      if (_fitted(n - minPartial)) n,
  ];

  /// Upper-partial notes heard on partial [n].
  int notesHeard(int n) =>
      n < firstUpper || n > maxPartial ? 0 : _notes[n - minPartial].length;

  /// Upper partials heard often enough to count as learned.
  List<int> get learnedUpper => [
    for (var n = firstUpper; n <= maxPartial; n++)
      if (notesHeard(n) >= notesToLearn) n,
  ];

  /// Horn correction for partial [n], in cents (0 if unknown).
  double partialOffsetCents(int n) =>
      n < minPartial || n > maxPartial ? 0 : 100 * _offset[n - minPartial];

  bool _fitted(int i) => _cells.any((row) => row[i].used);

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
  static (int, double)? resolvePitch(
    double freq,
    double sensedSemis, {
    double maxDistance = 1.0,
  }) {
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
  (int, double)? pitchSlide(double freq, double sensedSemis,
      {double maxDistance = 1.0}) {
    final hit = resolvePitch(freq, sensedSemis, maxDistance: maxDistance);
    if (hit == null) return null;
    final (n, s) = hit;
    return (n, s + _offset[n - minPartial]);
  }

  /// Slide extension (semitones) from the pitch alone, for when the ToF
  /// has no reading: the partial is the one that puts the slide nearest
  /// [lastSemis], where it was last seen. The slide can have moved while
  /// the sensor was blind, so this allows further than [pitchSlide].
  /// Null if no note, or nothing plausible.
  double? semitonesFromPitchNear(double? freq, double lastSemis) {
    if (freq == null || freq <= 30) return null;
    return pitchSlide(freq, lastSemis, maxDistance: 3.0)?.$2;
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

  // ── Learning ──

  /// Adds one accepted glissando on partial [n]: `(mm, semitones from
  /// pitch)` pairs along the slide, and the ToF reading while the start note
  /// was held in 1st.
  void addGliss(int n, List<(double, double)> samples, double closedMm) {
    if (n < minPartial || n > maxPartial) return;
    for (final (mm, s) in samples) {
      final b = ((s - _binMin) / _binWidth).round();
      if (b < 0 || b >= _binCount) continue;
      _cells[b][n - minPartial].add(mm, s);
    }
    _closedSum += closedMm;
    _closedCount++;
    _refit();
  }

  /// Adds one steady upper-partial note heard while playing: how far, in
  /// cents, the ideal-horn slide for that pitch sat from where the ToF had
  /// the slide (`100·(sensed − pitch)`). Returns whether it was taken.
  bool addUpperNote(int n, double cents) {
    if (n < firstUpper || n > maxPartial || !calibrated) return false;
    if ((cents - partialOffsetCents(n)).abs() > maxNoteDeviation) return false;
    final notes = _notes[n - minPartial]..add(cents);
    if (notes.length > maxNotes) notes.removeAt(0);
    _applyUpper();
    return true;
  }

  /// Alternates between the two unknowns: given the horn offsets, each
  /// bin's anchor is the mean over its partials of (mm, corrected pitch
  /// slide); given the curve, each partial's offset is how far its notes
  /// sit from the curve.
  ///
  /// A shift shared by every partial can't be told apart from moving the
  /// whole curve, so it is pinned: the slide closed is 0 semitones by
  /// definition, and any overall sharpness (tuning slide, or a player who
  /// runs sharp) goes into the horn offsets.
  void _refit() {
    _offset.fillRange(0, _nPartials, 0);
    final has = [for (var i = 0; i < _nPartials; i++) _fitted(i)];
    for (var iter = 0; iter < 6; iter++) {
      _setAnchors(_rawAnchors());
      if (!calibrated) {
        _offset.fillRange(0, _nPartials, 0);
        return;
      }
      for (var i = 0; i < _nPartials; i++) {
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
      _shiftOffsets(-_mean(has), has);
    }
    if (_closedCount > 0) {
      _shiftOffsets(-_interp(_closedSum / _closedCount), has);
      _setAnchors(_rawAnchors());
    }
    _applyUpper();
  }

  /// Offsets for the partials not fitted from glisses: the 2nd–4th average,
  /// plus (for 5th–8th) the guess, pulled towards the median of what's been
  /// heard as notes come in.
  void _applyUpper() {
    final has = [for (var i = 0; i < _nPartials; i++) _fitted(i)];
    final lower = [
      for (final n in glissPartials)
        if (has[n - minPartial]) n - minPartial,
    ];
    final base = lower.isEmpty
        ? _mean(has)
        : lower.map((i) => _offset[i]).reduce((a, b) => a + b) / lower.length;
    for (var n = minPartial; n <= maxPartial; n++) {
      final i = n - minPartial;
      if (n < firstUpper) {
        if (!has[i]) _offset[i] = base;
        continue;
      }
      // Partials 5–8 only have cells in calibrations from the old held-note
      // flow; then that is the starting point instead of the guess.
      final guess = has[i] ? _fittedOffset(i) : base + upperPrior[n]! / 100;
      final notes = _notes[i];
      if (notes.isEmpty) {
        _offset[i] = guess;
        continue;
      }
      final heard = _median(notes) / 100;
      _offset[i] =
          (guess * priorWeight + heard * notes.length) /
          (priorWeight + notes.length);
    }
  }

  /// Offset of a fitted partial straight from its cells and the curve.
  double _fittedOffset(int i) {
    var d = 0.0, k = 0;
    for (final row in _cells) {
      final c = row[i];
      if (!c.used) continue;
      d += _interp(c.meanMm) - c.meanS;
      k++;
    }
    return k > 0 ? d / k : 0;
  }

  static double _median(List<double> xs) {
    final s = [...xs]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  double _mean(List<bool> has) {
    var t = 0.0, k = 0;
    for (var i = 0; i < _nPartials; i++) {
      if (has[i]) {
        t += _offset[i];
        k++;
      }
    }
    return k > 0 ? t / k : 0;
  }

  void _shiftOffsets(double by, List<bool> has) {
    for (var i = 0; i < _nPartials; i++) {
      if (has[i]) _offset[i] += by;
    }
  }

  /// (mean mm, mean corrected slide) over the partials in a bin.
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

  List<(double, double)> _rawAnchors() => [
    for (final row in _cells) ?_rawAnchor(row),
  ];

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
        (p[i + 1].$2 - p[i].$2) / (p[i + 1].$1 - p[i].$1),
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

  /// Serialises the samples and heard notes (not just the fit).
  String toJson() => jsonEncode({
    'v': 3,
    'cells': [
      for (final row in _cells) [for (final c in row) c.toJson()],
    ],
    'closed': [_closedSum, _closedCount],
    'notes': _notes,
  });

  /// Restores state from [toJson]. A v2 calibration (held notes per
  /// position) is carried over. Anything malformed leaves a clean,
  /// uncalibrated state.
  void loadJson(String json) {
    reset();
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      final rows = m['cells'] as List;
      switch (m['v']) {
        case 3:
          if (rows.length != _binCount) return;
          for (var b = 0; b < rows.length; b++) {
            _loadRow(_cells[b], rows[b] as List);
          }
          final closed = m['closed'] as List;
          _closedSum = (closed[0] as num).toDouble();
          _closedCount = (closed[1] as num).toInt();
          final notes = m['notes'] as List;
          if (notes.length != _nPartials) throw const FormatException();
          for (var i = 0; i < _nPartials; i++) {
            _notes[i].addAll([
              for (final c in notes[i] as List) (c as num).toDouble(),
            ]);
          }
        case 2:
          // Held notes per position p (0–6) sit at p semitones.
          if (rows.length != 7) return;
          for (var p = 0; p < 7; p++) {
            _loadRow(
              _cells[((p - _binMin) / _binWidth).round()],
              rows[p] as List,
            );
          }
          for (final c in _cells[((0 - _binMin) / _binWidth).round()]) {
            if (!c.used) continue;
            _closedSum += c.meanMm;
            _closedCount++;
          }
        default:
          return;
      }
      _refit();
    } catch (_) {
      reset();
    }
  }

  static void _loadRow(List<_Cell> cells, List row) {
    if (row.length != cells.length) throw const FormatException();
    for (var i = 0; i < row.length; i++) {
      cells[i].loadJson(row[i] as List);
    }
  }

  void reset() {
    for (final row in _cells) {
      for (final c in row) {
        c.clear();
      }
    }
    for (final n in _notes) {
      n.clear();
    }
    _closedSum = 0;
    _closedCount = 0;
    _offset.fillRange(0, _nPartials, 0);
    _anchors = const [];
    _tangents = const [];
  }
}

class _Cell {
  // A quarter-semitone bin of a ~5 s gliss gets ~10 readings.
  static const minCount = 3;
  static const maxCount = 500; // then decay so newer data takes over

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
