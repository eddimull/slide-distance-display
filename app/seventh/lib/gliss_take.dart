import 'slide_calibration.dart';

/// One update: the ToF reading (null = the sensor had none) and the pitch
/// heard at the time (null = no note).
typedef CalFrame = ({DateTime t, double? mm, double? freq});

enum GlissPhase {
  /// Waiting for the start note, held in 1st.
  waiting,

  /// Start note heard in 1st; waiting for the slide to move.
  holding,

  /// On the way out to 7th.
  sweeping,

  /// Accepted: [GlissTake.samples] are ready for [SlideCalibration.addGliss].
  done,
}

enum GlissIssue {
  /// From 1st to 7th in under [GlissTake.minSweep].
  tooFast,

  /// The note stopped (a breath, a tongued restart, or the slide stopped)
  /// before 7th.
  stoppedEarly,

  /// The pitch jumped, most likely to another partial.
  jumped,
}

/// Records one guided glissando on a known [partial]: hold the start note in
/// 1st, then slide slowly out to 7th on one breath.
///
/// Because the partial is known, every frame's pitch gives the slide
/// extension directly, with no guessing from the (uncalibrated) ToF. A take
/// that fails one of the checks is thrown away and [issue] says why; the
/// take then waits for the start note again by itself.
class GlissTake {
  final int partial;

  /// How much later the pitch reading describes the slide than the ToF
  /// reading: the YIN window is 48 ms (centre 24 ms back) plus audio
  /// buffering. Each pitch is paired with the ToF reading this much
  /// earlier. Not yet measured on the phone.
  final Duration pitchLag;

  GlissTake(this.partial, {this.pitchLag = const Duration(milliseconds: 40)});

  /// The start note counts as "in 1st" within this many semitones.
  static const double startRange = 0.7;

  /// The start note must be held this long, steady within [holdSteady]
  /// semitones, before the sweep. (The middle of a gliss on the wrong
  /// partial passes through the start note too, but doesn't stay.)
  static const minHold = Duration(milliseconds: 300);
  static const double holdSteady = 0.3;

  /// Reaching this far counts as 7th (a short 7th is common).
  static const double endSemis = 5.5;

  /// Least time from leaving 1st to reaching 7th (~5 s is asked for).
  static const minSweep = Duration(seconds: 2);

  /// Silence that ends the note.
  static const gap = Duration(milliseconds: 150);

  /// A frame-to-frame step larger than this is a glitch or a new partial;
  /// [maxOutliers] in a row fails the take.
  static const double jumpSemis = 0.6;
  static const int maxOutliers = 4;

  /// Above this (semitones/s) the screen asks to slow down.
  static const double fastPace = 2.5;

  GlissPhase phase = GlissPhase.waiting;

  /// Why the last attempt was thrown away; cleared when a new one starts.
  GlissIssue? issue;

  /// Where the pitch puts the slide now (semitones), if a note is heard.
  double? semis;

  /// Furthest this attempt has got (semitones).
  double reached = 0;

  /// Smoothed sweep speed (semitones/s).
  double pace = 0;

  /// (mm, semitones from pitch) pairs of the accepted take.
  final samples = <(double, double)>[];

  /// ToF reading while the start note was held.
  double? closedMm;

  final _mmHist = <(DateTime, double)>[];
  final _holdMm = <double>[];
  DateTime? _holdStart, _lastHeard, _sweepStart, _reachedEnd, _lastT;
  double? _lastS, _holdS;
  bool _armed = false;
  int _outliers = 0;

  bool get tooFast => phase == GlissPhase.sweeping && pace > fastPace;

  void feed(CalFrame f) {
    final t = f.t;
    if (f.mm != null) _mmHist.add((t, f.mm!));
    final keep = t.subtract(pitchLag * 2 + const Duration(milliseconds: 200));
    while (_mmHist.length > 2 && _mmHist.first.$1.isBefore(keep)) {
      _mmHist.removeAt(0);
    }
    if (phase == GlissPhase.done) return;

    final freq = f.freq;
    final s = freq == null || freq <= 30
        ? null
        : SlideCalibration.semitonesFromPitch(freq, partial);
    if (s != null && phase == GlissPhase.sweeping && (s < -1 || s > 7)) {
      // A note, but nowhere on this partial: it jumped.
      _lastHeard = t;
      semis = null;
      _outlier();
      return;
    }
    if (s == null || s < -1 || s > 7) {
      semis = null;
      final last = _lastHeard;
      if (last != null && t.difference(last) >= gap) _noteEnded();
      return;
    }
    _lastHeard = t;
    semis = s;
    final mm = _mmAt(t.subtract(pitchLag));

    switch (phase) {
      case GlissPhase.waiting:
        if (s.abs() <= startRange) {
          _clear();
          issue = null;
          phase = GlissPhase.holding;
          _holdAt(t, s);
          _hold(t, mm, s);
        }
      case GlissPhase.holding:
        if (s.abs() <= startRange) {
          if (!_armed) {
            if ((s - _holdS!).abs() > holdSteady) {
              _holdAt(t, s); // still moving: the hold starts here
            } else if (t.difference(_holdStart!) >= minHold) {
              _armed = true;
            }
          }
          _hold(t, mm, s);
        } else if (_armed &&
            _holdMm.isNotEmpty &&
            (s - _lastS!).abs() <= jumpSemis) {
          final held = [..._holdMm]..sort();
          closedMm = held[held.length ~/ 2];
          phase = GlissPhase.sweeping;
          _sweepStart = t;
          _sweep(t, mm, s);
        } else {
          // Not a held start, or a jump straight off it: start over.
          _restart(null);
        }
      case GlissPhase.sweeping:
        _sweep(t, mm, s);
      case GlissPhase.done:
        break;
    }
  }

  /// Throws the attempt away (the "Restart this one" button).
  void restart() => _restart(null);

  void _holdAt(DateTime t, double s) {
    _holdStart = t;
    _holdS = s;
    _armed = false;
    _holdMm.clear();
    samples.clear();
  }

  /// [mm] is null when the ToF had nothing then: the pitch still counts
  /// towards the take, it just gives no sample.
  void _hold(DateTime t, double? mm, double s) {
    if (mm != null) {
      // The closed-slide reading: only while the held pitch is steady, not
      // the first slow part of the sweep.
      if ((s - _holdS!).abs() <= holdSteady) _holdMm.add(mm);
      samples.add((mm, s));
    }
    _lastS = s;
    _lastT = t;
  }

  void _sweep(DateTime t, double? mm, double s) {
    final last = _lastS!;
    if ((s - last).abs() > jumpSemis) {
      _outlier();
      return;
    }
    _outliers = 0;
    final dt = t.difference(_lastT!).inMicroseconds / 1e6;
    if (dt > 0) pace = pace * 0.85 + (s - last) / dt * 0.15;
    _lastS = s;
    _lastT = t;
    if (mm != null) samples.add((mm, s));
    if (s > reached) reached = s;
    if (s >= endSemis) _reachedEnd ??= t;
  }

  void _outlier() {
    if (++_outliers >= maxOutliers) _restart(GlissIssue.jumped);
  }

  void _noteEnded() {
    switch (phase) {
      case GlissPhase.holding:
        _restart(null); // just stopped playing; nothing wrong
      case GlissPhase.sweeping:
        final end = _reachedEnd;
        if (end == null) {
          _restart(GlissIssue.stoppedEarly);
        } else if (end.difference(_sweepStart!) < minSweep) {
          _restart(GlissIssue.tooFast);
        } else {
          phase = GlissPhase.done;
        }
      case GlissPhase.waiting:
      case GlissPhase.done:
        break;
    }
  }

  void _restart(GlissIssue? why) {
    if (why != null) issue = why;
    phase = GlissPhase.waiting;
    _clear();
  }

  void _clear() {
    samples.clear();
    _holdMm.clear();
    closedMm = null;
    reached = 0;
    pace = 0;
    _holdStart = _sweepStart = _reachedEnd = _lastT = null;
    _lastS = _holdS = null;
    _armed = false;
    _outliers = 0;
  }

  /// Readings further apart than this don't bracket a moment: the sensor
  /// was blind in between (Medium mode runs at ~41 ms).
  static const _maxGap = Duration(milliseconds: 60);

  /// ToF reading at [t], interpolated from the recent history, or null if
  /// the sensor had none around then.
  double? _mmAt(DateTime t) {
    final h = _mmHist;
    if (h.isEmpty) return null;
    if (!t.isAfter(h.first.$1)) {
      return h.first.$1.difference(t) <= _maxGap ? h.first.$2 : null;
    }
    if (!t.isBefore(h.last.$1)) {
      return t.difference(h.last.$1) <= _maxGap ? h.last.$2 : null;
    }
    for (var i = h.length - 1; i > 0; i--) {
      final (t0, m0) = h[i - 1];
      if (!t.isBefore(t0)) {
        final (t1, m1) = h[i];
        if (t1.difference(t0) > _maxGap) return null;
        final span = t1.difference(t0).inMicroseconds;
        if (span <= 0) return m1;
        final a = (t.difference(t0).inMicroseconds / span).clamp(0.0, 1.0);
        return m0 + (m1 - m0) * a;
      }
    }
    return h.last.$2;
  }
}
