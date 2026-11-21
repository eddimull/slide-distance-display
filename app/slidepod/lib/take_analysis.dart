import 'dart:math' as math;

import 'slide_calibration.dart';
import 'take.dart';
import 'trombone_chart.dart';

/// How a slide move ended, judged against the direction it was going.
enum ShiftResult {
  /// Arrived within [AnalysisConfig.slideTol] of the target and stayed.
  clean,

  /// Went past the target (it may have come back afterwards).
  overshot,

  /// Stopped before the target (it may have crept there afterwards).
  short,
}

/// Why a note was out of tune.
enum NoteCause {
  /// Within [AnalysisConfig.inTuneCents].
  inTune,

  /// The slide was off and the pitch followed it.
  slide,

  /// The slide was close enough; the lips moved the pitch.
  lip,
}

/// The slide's move into one note, from where it rested for the note before.
class ShiftAnalysis {
  /// Rest position before, and this horn's spot for the new note (semitones
  /// of extension: 0 = 1st, 6 = 7th; one position = one semitone).
  final double fromSemis, targetSemis;

  /// +1 = out (to a longer position), −1 = in.
  final int direction;

  /// When the slide started moving, and when it settled for good.
  final int startMs, arriveMs;

  /// Fastest point of the move, positions per second.
  final double peakSpeed;

  /// Distances past the target in the direction of travel (+ = too far,
  /// − = short), in positions: at the furthest point of the move, where the
  /// slide first stopped, and where it rested for the note.
  final double peakError, firstStopError, landedError;

  final ShiftResult result;

  /// Arrival relative to the note's start: negative = the slide got there
  /// before the note sounded (good), positive = still moving into it.
  final int settleAfterOnsetMs;

  /// Into 1st on the bumper: can't overshoot.
  final bool toBumper;

  const ShiftAnalysis({
    required this.fromSemis,
    required this.targetSemis,
    required this.direction,
    required this.startMs,
    required this.arriveMs,
    required this.peakSpeed,
    required this.peakError,
    required this.firstStopError,
    required this.landedError,
    required this.result,
    required this.settleAfterOnsetMs,
    required this.toBumper,
  });

  int get durationMs => arriveMs - startMs;

  /// Stopped short, then reached the target late.
  bool get crept =>
      result == ShiftResult.short &&
      landedError.abs() < firstStopError.abs();
}

class NoteAnalysis {
  final int index;
  final int startMs, endMs;

  /// Nearest equal-tempered note and how far off it the note was held.
  final int midi;
  final double cents;

  /// Partial and this horn's slide spot for the note; null when the slide
  /// wasn't seen or the note doesn't fit the horn.
  final int? partial;
  final double? targetSemis;

  /// Where the slide rested for the note; null if the ToF was blind.
  final double? landedSemis;

  /// The pitch error the slide accounts for (landing too far out = flat),
  /// and the rest, put down to the lips. `cents = slideCents + lipCents`.
  final double? slideCents, lipCents;

  final NoteCause cause;

  /// The move into this note; null for the first note, a repeated
  /// position, or when the slide wasn't seen.
  final ShiftAnalysis? shift;

  /// The slide was still settling well after the note started.
  final bool lateSlide;

  const NoteAnalysis({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.midi,
    required this.cents,
    this.partial,
    this.targetSemis,
    this.landedSemis,
    this.slideCents,
    this.lipCents,
    required this.cause,
    this.shift,
    this.lateSlide = false,
  });

  String get name => TromboneChart.noteName(midi);
  int get durationMs => endMs - startMs;
  double get freq => 440.0 * math.pow(2, (midi - 69) / 12);

  /// Chart position (1–7) of [targetSemis].
  int? get targetPosition =>
      targetSemis == null ? null : (1 + targetSemis!.round()).clamp(1, 7);
}

class AnalysisConfig {
  /// The pitch reading describes the slide this much later than the ToF
  /// (see [GlissTake.pitchLag]).
  final int pitchLagMs;

  /// A gap in the pitch longer than this ends a note.
  final int maxGapMs;

  /// Shorter runs of one pitch are glides or glitches, not notes.
  final int minNoteMs;

  /// A new note needs the pitch more than this many semitones from the
  /// current one, for [switchFrames] readings in a row.
  final double switchSemis;
  final int switchFrames;

  /// Half-width of the window the slide speed is measured over.
  final int speedWindowMs;

  /// Above this (positions/s) the slide is moving; below [stopSpeed] it has
  /// stopped.
  final double moveSpeed, stopSpeed;

  /// Closer to the target than this (positions) counts as on it.
  final double slideTol;

  /// Moves shorter than this (positions) are not shifts: the partials'
  /// own tuning puts their spots for one position up to ~0.4 apart.
  final double minShift;

  /// A move is looked for no earlier than this before its note (after a
  /// rest the slide may sit still for a long time, then move).
  final int maxShiftLeadMs;

  /// Still settling this long after the note started = late.
  final int lateMs;

  /// In tune within this many cents.
  final double inTuneCents;

  const AnalysisConfig({
    this.pitchLagMs = 40,
    this.maxGapMs = 100,
    this.minNoteMs = 100,
    this.switchSemis = 0.6,
    this.switchFrames = 3,
    this.speedWindowMs = 40,
    this.moveSpeed = 1.5,
    this.stopSpeed = 0.5,
    this.slideTol = 0.1,
    this.minShift = 0.5,
    this.maxShiftLeadMs = 1000,
    this.lateMs = 100,
    this.inTuneCents = 10,
  });
}

/// Splits a take into notes and measures, for each, the intonation and the
/// slide move into it.
///
/// Notes come from the pitch: a run of readings near one equal-tempered note
/// (with hysteresis, so a note held 40¢ off doesn't flicker). The slide is
/// measured from the ToF: where it rested for the note before, how fast it
/// moved, how far past or short of this horn's spot for the note it went,
/// and when it settled. Overshoot and undershoot are judged in the direction
/// of travel, so landing at 3.2 is an overshoot coming out from 1st but an
/// undershoot coming in from 5th.
class TakeAnalysis {
  final Take take;
  final List<NoteAnalysis> notes;

  /// Slide speed over the take (positions/s, signed: + = moving out), at
  /// each ToF reading.
  final List<({int tMs, double speed})> speed;

  final AnalysisConfig config;

  TakeAnalysis._(this.take, this.notes, this.speed, this.config);

  // ── Summary ──

  int get inTuneCount => notes.where((n) => n.cause == NoteCause.inTune).length;

  double get avgAbsCents => notes.isEmpty
      ? 0
      : notes.map((n) => n.cents.abs()).reduce((a, b) => a + b) / notes.length;

  List<ShiftAnalysis> get shifts => [
        for (final n in notes)
          if (n.shift != null) n.shift!,
      ];

  int _count(ShiftResult r) => shifts.where((s) => s.result == r).length;
  int get cleanShifts => _count(ShiftResult.clean);
  int get overshoots => _count(ShiftResult.overshot);
  int get shorts => _count(ShiftResult.short);

  double get peakSpeed =>
      shifts.isEmpty ? 0 : shifts.map((s) => s.peakSpeed).reduce(math.max);

  double get avgShiftMs => shifts.isEmpty
      ? 0
      : shifts.map((s) => s.durationMs).reduce((a, b) => a + b) /
          shifts.length;

  // ── Analysis ──

  static TakeAnalysis analyze(Take take, SlideCalibration cal,
      {AnalysisConfig config = const AnalysisConfig()}) {
    final slide = _Series([
      for (final f in take.frames)
        if (f.semis != null) (f.tMs, f.semis!),
    ]);
    final speed = slide.speeds(config.speedWindowMs);
    final pitch = [
      for (final f in take.frames)
        if (f.freq != null && f.freq! > 30)
          (f.tMs - config.pitchLagMs, 69 + 12 * math.log(f.freq! / 440) / math.ln2),
    ];
    final segs = _segment(pitch, config);

    final notes = <NoteAnalysis>[];
    for (var i = 0; i < segs.length; i++) {
      final seg = segs[i];
      // The move into a note is from the last note whose slide spot is
      // known (not a mic glitch on no partial).
      NoteAnalysis? prev;
      for (final n in notes.reversed) {
        if (n.targetSemis != null && n.landedSemis != null) {
          prev = n;
          break;
        }
      }
      notes.add(_note(i, seg, prev, slide, speed, cal, config));
    }
    return TakeAnalysis._(take, notes, speed, config);
  }

  /// Runs of pitch readings around one note: `(start, end, midi values)`.
  static List<(int, int, List<(int, double)>)> _segment(
      List<(int, double)> pitch, AnalysisConfig c) {
    final out = <(int, int, List<(int, double)>)>[];
    List<(int, double)>? cur;
    int curMidi = 0;
    List<(int, double)>? pending;

    void close() {
      if (cur != null && cur!.isNotEmpty) {
        final start = cur!.first.$1, end = cur!.last.$1;
        if (end - start >= c.minNoteMs) out.add((start, end, cur!));
      }
      cur = null;
      pending = null;
    }

    int? lastT;
    for (final p in pitch) {
      final (t, m) = p;
      if (lastT != null && t - lastT > c.maxGapMs) close();
      lastT = t;
      if (cur == null) {
        cur = [p];
        curMidi = m.round();
        continue;
      }
      if ((m - curMidi).abs() <= c.switchSemis) {
        cur!.add(p);
        pending = null;
        continue;
      }
      // Away from the note: a new one only if it stays away, near one pitch.
      if (pending != null && (m - pending!.first.$2).abs() > c.switchSemis) {
        pending = null;
      }
      (pending ??= []).add(p);
      if (pending!.length >= c.switchFrames) {
        final next = pending!;
        close();
        cur = next;
        curMidi = (next.map((e) => e.$2).reduce((a, b) => a + b) / next.length)
            .round();
      }
    }
    close();
    return out;
  }

  static double _median(List<double> xs) {
    final s = List.of(xs)..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }

  static NoteAnalysis _note(
      int index,
      (int, int, List<(int, double)>) seg,
      NoteAnalysis? prev,
      _Series slide,
      List<({int tMs, double speed})> speed,
      SlideCalibration cal,
      AnalysisConfig c) {
    final (start, end, readings) = seg;
    final dur = end - start;
    // Intonation from the held part: past the attack and any glide in,
    // before the release.
    final coreFrom = start + dur * 0.2, coreTo = start + dur * 0.9;
    var core = [
      for (final (t, m) in readings)
        if (t >= coreFrom && t <= coreTo) m,
    ];
    if (core.isEmpty) core = [for (final r in readings) r.$2];
    final m = _median(core);
    final midi = m.round();
    final cents = 100 * (m - midi);

    // Where the slide rested: the second half of the note.
    final rest = slide.valuesIn(start + dur ~/ 2, end);
    final landed = rest.isEmpty ? null : _median(rest);

    int? partial;
    double? target;
    if (landed != null) {
      final etFreq = 440.0 * math.pow(2, (midi - 69) / 12);
      final hit = cal.pitchSlide(etFreq, landed, maxDistance: 1.5);
      if (hit != null) (partial, target) = hit;
    }

    double? slideCents, lipCents;
    var cause = cents.abs() < c.inTuneCents ? NoteCause.inTune : NoteCause.lip;
    if (landed != null && target != null) {
      // Inside 1st is out of reach (a flat 5th or 7th partial): what the
      // slide can't fix is the lips' job.
      final reachable = math.max(target, 0.0);
      slideCents = -100 * (landed - reachable); // further out = flatter
      lipCents = cents - slideCents;
      if (cause != NoteCause.inTune) {
        cause = slideCents.abs() >= lipCents.abs()
            ? NoteCause.slide
            : NoteCause.lip;
      }
    }

    ShiftAnalysis? shift;
    if (prev != null &&
        prev.landedSemis != null &&
        landed != null &&
        target != null) {
      shift = _shift(prev, start, end, target, landed, slide, speed, c);
    }

    return NoteAnalysis(
      index: index,
      startMs: start,
      endMs: end,
      midi: midi,
      cents: cents,
      partial: partial,
      targetSemis: target,
      landedSemis: landed,
      slideCents: slideCents,
      lipCents: lipCents,
      cause: cause,
      shift: shift,
      lateSlide: shift != null && shift.settleAfterOnsetMs > c.lateMs,
    );
  }

  static ShiftAnalysis? _shift(
      NoteAnalysis prev,
      int noteStart,
      int noteEnd,
      double target,
      double landed,
      _Series slide,
      List<({int tMs, double speed})> speed,
      AnalysisConfig c) {
    // A move is a change of slide spot. A new partial at the same position
    // isn't one, even if the slide was off for either note.
    final from = prev.landedSemis!;
    final prevTarget = prev.targetSemis!;
    if ((target - prevTarget).abs() < c.minShift) return null;
    final dir = target > prevTarget ? 1 : -1;
    final toBumper = dir < 0 && target < 0.15;
    // The move happens somewhere between the previous note's rest and the
    // end of this one, and not long before this note.
    final winFrom = math.max(prev.startMs + prev.durationMs ~/ 2,
        noteStart - c.maxShiftLeadMs);
    final win = [
      for (final s in speed)
        if (s.tMs >= winFrom && s.tMs <= noteEnd) s,
    ];
    if (win.isEmpty) return null;

    // Peak speed in the direction of travel, then back to where it began.
    var peakI = 0;
    for (var i = 1; i < win.length; i++) {
      if (dir * win[i].speed > dir * win[peakI].speed) peakI = i;
    }
    final peak = dir * win[peakI].speed;
    if (peak < c.moveSpeed) {
      // No move near the note: the slide was placed well before it (after
      // a rest), or never went. Judge where it rested.
      final e = dir * (landed - target);
      return ShiftAnalysis(
        fromSemis: from,
        targetSemis: target,
        direction: dir,
        startMs: noteStart,
        arriveMs: noteStart,
        peakSpeed: math.max(0, peak),
        peakError: e,
        firstStopError: e,
        landedError: e,
        result: e < -c.slideTol
            ? ShiftResult.short
            : e > c.slideTol && !toBumper
                ? ShiftResult.overshot
                : ShiftResult.clean,
        settleAfterOnsetMs: 0,
        toBumper: toBumper,
      );
    }
    var startI = peakI;
    while (startI > 0 && dir * win[startI - 1].speed > c.stopSpeed) {
      startI--;
    }
    var stopI = peakI;
    while (stopI < win.length - 1 && dir * win[stopI].speed > c.stopSpeed) {
      stopI++;
    }
    final startMs = win[startI].tMs;

    // Furthest point in the direction of travel.
    final during = slide.valuesIn(startMs, noteEnd);
    final extreme = dir > 0 ? during.reduce(math.max) : during.reduce(math.min);
    final peakErr = dir * (extreme - target);
    final firstStop = slide.at(win[stopI].tMs) ?? landed;
    final firstErr = dir * (firstStop - target);
    final landedErr = dir * (landed - target);

    // Settled: after the last reading more than the tolerance from rest.
    var arrive = startMs;
    for (final (t, s) in slide.points) {
      if (t < startMs) continue;
      if (t > noteEnd) break;
      if ((s - landed).abs() > c.slideTol) arrive = t;
    }

    final ShiftResult result;
    if (toBumper) {
      // Onto the bumper: it can't go past, and if the horn wants it inside
      // 1st, resting on the bumper is as close as it gets.
      result = landed <= math.max(target, 0.0) + c.slideTol
          ? ShiftResult.clean
          : ShiftResult.short;
    } else if (peakErr > c.slideTol) {
      result = ShiftResult.overshot;
    } else if (firstErr < -c.slideTol || landedErr < -c.slideTol) {
      result = ShiftResult.short;
    } else {
      result = ShiftResult.clean;
    }

    return ShiftAnalysis(
      fromSemis: from,
      targetSemis: target,
      direction: dir,
      startMs: startMs,
      arriveMs: arrive,
      peakSpeed: peak,
      peakError: peakErr,
      firstStopError: firstErr,
      landedError: landedErr,
      result: result,
      settleAfterOnsetMs: arrive - noteStart,
      toBumper: toBumper,
    );
  }
}

/// Slide readings `(tMs, semitones)` in time order.
class _Series {
  final List<(int, double)> points;
  _Series(this.points);

  int _lowerBound(int t) {
    var lo = 0, hi = points.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (points[mid].$1 < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  List<double> valuesIn(num from, num to) {
    final out = <double>[];
    for (var i = _lowerBound(from.ceil()); i < points.length; i++) {
      if (points[i].$1 > to) break;
      out.add(points[i].$2);
    }
    return out;
  }

  /// Interpolated at [t]; null across a gap of more than 150 ms.
  double? at(int t) {
    final i = _lowerBound(t);
    if (i < points.length && points[i].$1 == t) return points[i].$2;
    if (i == 0 || i >= points.length) return null;
    final (t0, s0) = points[i - 1];
    final (t1, s1) = points[i];
    if (t1 - t0 > 150) return null;
    return s0 + (s1 - s0) * (t - t0) / (t1 - t0);
  }

  /// Speed at each reading: the slope across ±[halfMs].
  List<({int tMs, double speed})> speeds(int halfMs) {
    final out = <({int tMs, double speed})>[];
    var lo = 0, hi = 0;
    for (var i = 0; i < points.length; i++) {
      final t = points[i].$1;
      while (points[lo].$1 < t - halfMs) {
        lo++;
      }
      while (hi + 1 < points.length && points[hi + 1].$1 <= t + halfMs) {
        hi++;
      }
      final dt = points[hi].$1 - points[lo].$1;
      final v = dt < halfMs / 2
          ? 0.0
          : (points[hi].$2 - points[lo].$2) * 1000 / dt;
      out.add((tMs: t, speed: v));
    }
    return out;
  }
}
