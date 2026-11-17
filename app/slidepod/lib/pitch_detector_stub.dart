import 'dart:async';
import 'pitch_detector.dart';

PitchDetector createPitchDetector() => _StubPitchDetector();

class _StubPitchDetector implements PitchDetector {
  final _controller = StreamController<double?>.broadcast();

  @override
  Stream<double?> get pitchStream => _controller.stream;

  @override
  Future<void> start() async {}

  @override
  void stop() {}

  @override
  void dispose() => _controller.close();
}
