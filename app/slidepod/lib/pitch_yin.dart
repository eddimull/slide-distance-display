import 'dart:math' as math;
import 'dart:typed_data';

/// YIN pitch detector (de Cheveigné & Kawahara, 2002), tuned for trombone.
/// Port of src/slidepod/pitch_yin.h, so the phone mic and the pod use the
/// same algorithm. Samples are floats in −1…1.
class PitchYin {
  static const double sampleRate = 16000;
  static const double minHz = 50; // just below the Bb1 pedal (58 Hz)
  static const double maxHz = 1000; // above a high Bb5 (932 Hz)
  static const int window = 768; // 48 ms: 2.4 periods of 50 Hz
  static final int tauMin = (sampleRate / maxHz).floor();
  static final int tauMax = (sampleRate / minHz).floor();
  static final int integrate = window - tauMax;

  /// Absolute YIN threshold: lower = stricter about periodicity.
  double threshold = 0.15;

  /// Below this RMS (full scale = 1.0) there's no note: ~−46 dBFS.
  double minRms = 0.005;

  // One-pole filters: high-pass ~20 Hz (DC, handling rumble), low-pass
  // ~1.2 kHz (hiss and upper harmonics that cause octave-up errors).
  static const double _hpA = 0.99218; // exp(-2π·20/16000)
  static const double _lpA = 0.37572; // 1 - exp(-2π·1200/16000)

  final Float32List _buf = Float32List(window);
  final Float32List _win = Float32List(window);
  late final Float32List _d = Float32List(tauMax + 1);
  int _head = 0, _filled = 0;
  double _hpPrevIn = 0, _hpPrevOut = 0, _lp = 0;
  double rms = 0;

  void push(double x) {
    final hp = _hpA * (_hpPrevOut + x - _hpPrevIn);
    _hpPrevIn = x;
    _hpPrevOut = hp;
    _lp += _lpA * (hp - _lp);
    _buf[_head] = _lp;
    _head = (_head + 1) % window;
    if (_filled < window) _filled++;
  }

  /// Fundamental in Hz, or null if there's no clear pitch.
  double? detect() {
    if (_filled < window) return null;
    for (var i = 0; i < window; i++) {
      _win[i] = _buf[(_head + i) % window];
    }

    var sumSq = 0.0;
    for (var i = 0; i < window; i++) {
      sumSq += _win[i] * _win[i];
    }
    rms = math.sqrt(sumSq / window);
    if (rms < minRms) return null;

    // Difference function, cumulative-mean normalised.
    _d[0] = 1;
    var running = 0.0;
    for (var tau = 1; tau <= tauMax; tau++) {
      var sum = 0.0;
      for (var i = 0; i < integrate; i++) {
        final delta = _win[i] - _win[i + tau];
        sum += delta * delta;
      }
      running += sum;
      _d[tau] = running > 0 ? sum * tau / running : 1;
    }

    // First dip under the threshold, then walk to its bottom.
    var tau = -1;
    for (var t = tauMin; t < tauMax; t++) {
      if (_d[t] < threshold) {
        while (t + 1 < tauMax && _d[t + 1] < _d[t]) {
          t++;
        }
        tau = t;
        break;
      }
    }
    if (tau < 0) return null;

    // Parabolic interpolation for a sub-sample period.
    var better = tau.toDouble();
    if (tau > tauMin && tau < tauMax) {
      final s0 = _d[tau - 1], s1 = _d[tau], s2 = _d[tau + 1];
      final denom = s0 - 2 * s1 + s2;
      if (denom.abs() > 1e-9) better += 0.5 * (s0 - s2) / denom;
    }
    return sampleRate / better;
  }
}
