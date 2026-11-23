import 'dart:async';
import 'dart:typed_data';

import 'pitch_detector_stub.dart'
    if (dart.library.js_interop) 'pitch_detector_web.dart'
    if (dart.library.io) 'pitch_detector_io.dart' as impl;

abstract class PitchDetector {
  Stream<double?> get pitchStream;

  /// The raw mic audio the pitch comes from: 16-bit little-endian mono PCM
  /// at [sampleRate], as it arrives. Empty where the platform doesn't give
  /// access to it (web).
  Stream<Uint8List> get pcmStream;
  int get sampleRate;
  Future<void> start();
  void stop();
  void dispose();

  factory PitchDetector() => impl.createPitchDetector();
}
