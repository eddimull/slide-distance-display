import 'dart:async';

import 'pitch_detector_stub.dart'
    if (dart.library.js_interop) 'pitch_detector_web.dart'
    if (dart.library.io) 'pitch_detector_io.dart' as impl;

abstract class PitchDetector {
  Stream<double?> get pitchStream;
  Future<void> start();
  void stop();
  void dispose();

  factory PitchDetector() => impl.createPitchDetector();
}
