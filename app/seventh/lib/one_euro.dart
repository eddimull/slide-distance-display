import 'dart:math' as math;

/// One-Euro filter (Casiez, Roussel & Vogel, CHI 2012): a low-pass whose
/// cutoff rises with speed. Smooths sensor jitter when the slide is still,
/// gets out of the way when it moves.
///
/// Defaults were picked by replaying a real 79 s phone session (2146 ToF
/// readings): no measurable lag during motion (vs 120 ms for the old
/// Kalman filter) while cutting at-rest jitter from 1.56 to 0.86 mm.
class OneEuroFilter {
  /// Cutoff (Hz) when still. Lower = smoother at rest.
  double minCutoff;

  /// How fast the cutoff opens up with speed (per mm/s). Higher = less lag.
  double beta;

  /// Cutoff (Hz) for the speed estimate itself.
  double derivCutoff;

  /// Output hold (mm, ±): the returned value only moves once the filtered
  /// value gets further than this from it. Sensor noise makes the speed
  /// estimate twitch, which opens the cutoff even at rest; on the 79 s replay
  /// ±2 mm cut idle bounce from 3.8 to 0.75 mm peak-to-peak with no change in
  /// tracking error during moves. 0 disables it.
  double deadband;

  double? _x;
  double? _held;
  double _dx = 0;
  DateTime? _t;

  OneEuroFilter({
    this.minCutoff = 1.0,
    this.beta = 0.2,
    this.derivCutoff = 1.0,
    this.deadband = 0,
  });

  static double _alpha(double cutoff, double dt) {
    final r = 2 * math.pi * cutoff * dt;
    return r / (r + 1);
  }

  /// Filters [value] sampled at [time] (arrival time is fine).
  double update(double value, DateTime time) {
    final x = _x;
    final t = _t;
    _t = time;
    if (x == null || t == null) return _held = _x = value;
    // Guard against duplicate/zero timestamps.
    final dt = math.max(time.difference(t).inMicroseconds / 1e6, 1e-3);
    final d = (value - x) / dt;
    _dx += _alpha(derivCutoff, dt) * (d - _dx);
    final cutoff = minCutoff + beta * _dx.abs();
    final y = _x = x + _alpha(cutoff, dt) * (value - x);
    final h = _held ?? y;
    return _held = y > h + deadband
        ? y - deadband
        : y < h - deadband
            ? y + deadband
            : h;
  }

  void reset() {
    _x = null;
    _held = null;
    _t = null;
    _dx = 0;
  }
}
