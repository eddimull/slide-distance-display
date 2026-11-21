import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'pitch_detector.dart';

PitchDetector createPitchDetector() => _WebPitchDetector();

@JS('AudioContext')
extension type _AudioContext._(JSObject _) implements JSObject {
  external factory _AudioContext();
  external _MediaStreamSource createMediaStreamSource(web.MediaStream stream);
  external _AnalyserNode createAnalyser();
  external JSPromise<JSAny?> close();
  external num get sampleRate;
}

@JS('MediaStreamAudioSourceNode')
extension type _MediaStreamSource._(JSObject _) implements JSObject {
  external void connect(JSObject dest);
}

@JS('AnalyserNode')
extension type _AnalyserNode._(JSObject _) implements JSObject {
  external set fftSize(int value);
  external int get fftSize;
  external void getFloatTimeDomainData(JSFloat32Array array);
}

class _WebPitchDetector implements PitchDetector {
  final _controller = StreamController<double?>.broadcast();
  _AudioContext? _ctx;
  Timer? _timer;
  web.MediaStream? _stream;

  @override
  Stream<double?> get pitchStream => _controller.stream;

  // The analyser node only gives snapshots, not a continuous stream, so no
  // audio is recorded on the web.
  @override
  Stream<Uint8List> get pcmStream => const Stream.empty();

  @override
  int get sampleRate => 16000;

  @override
  Future<void> start() async {
    final mediaDevices = web.window.navigator.mediaDevices;
    _stream = await mediaDevices
        .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
        .toDart;

    _ctx = _AudioContext();
    final source = _ctx!.createMediaStreamSource(_stream!);
    final analyser = _ctx!.createAnalyser();
    analyser.fftSize = 2048;
    source.connect(analyser);

    final buf = Float32List(analyser.fftSize);
    final jsBuf = buf.toJS;
    final sampleRate = _ctx!.sampleRate.toDouble();

    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      analyser.getFloatTimeDomainData(jsBuf);
      // Copy back from JS buffer
      for (var i = 0; i < buf.length; i++) {
        buf[i] = jsBuf.toDart[i];
      }
      final freq = _detectPitch(buf, sampleRate);
      _controller.add(freq);
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    _stream?.getTracks().toDart.forEach((t) => t.stop());
    _stream = null;
    if (_ctx != null) {
      _ctx!.close();
      _ctx = null;
    }
  }

  @override
  void dispose() {
    stop();
    _controller.close();
  }

  /// Autocorrelation pitch detection (YIN-inspired).
  /// Returns frequency in Hz, or null if no clear pitch.
  static double? _detectPitch(Float32List buf, double sampleRate) {
    final n = buf.length;
    final halfN = n ~/ 2;

    // Check if there's enough signal
    double rms = 0;
    for (var i = 0; i < n; i++) {
      rms += buf[i] * buf[i];
    }
    rms = (rms / n);
    if (rms < 0.001) return null; // too quiet

    // Autocorrelation
    final corr = Float32List(halfN);
    for (var lag = 0; lag < halfN; lag++) {
      double sum = 0;
      for (var i = 0; i < halfN; i++) {
        sum += buf[i] * buf[i + lag];
      }
      corr[lag] = sum;
    }

    // Find the first dip then the next peak after it
    // Skip lag 0 (which is always the max) and very short lags (high freq noise)
    final minLag = (sampleRate / 1200).round(); // ~1200 Hz max
    final maxLag = (sampleRate / 50).round();   // ~50 Hz min

    // Find first point where correlation drops below threshold
    final threshold = corr[0] * 0.5;
    int dipLag = minLag;
    for (var i = minLag; i < maxLag && i < halfN; i++) {
      if (corr[i] < threshold) {
        dipLag = i;
        break;
      }
    }

    // Find the peak after the dip
    double bestVal = -1;
    int bestLag = dipLag;
    for (var i = dipLag; i < maxLag && i < halfN; i++) {
      if (corr[i] > bestVal) {
        bestVal = corr[i];
        bestLag = i;
      }
    }

    // Peak must be significant relative to zero-lag
    if (bestVal < corr[0] * 0.3) return null;

    // Parabolic interpolation for sub-sample accuracy
    if (bestLag > 0 && bestLag < halfN - 1) {
      final y0 = corr[bestLag - 1];
      final y1 = corr[bestLag];
      final y2 = corr[bestLag + 1];
      final d = (y0 - y2) / (2 * (y0 - 2 * y1 + y2));
      if (d.isFinite) {
        return sampleRate / (bestLag + d);
      }
    }

    return sampleRate / bestLag;
  }
}
