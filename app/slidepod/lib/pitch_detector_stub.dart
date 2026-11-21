import 'dart:async';
import 'dart:typed_data';
import 'pitch_detector.dart';

PitchDetector createPitchDetector() => _StubPitchDetector();

class _StubPitchDetector implements PitchDetector {
  final _controller = StreamController<double?>.broadcast();

  @override
  Stream<double?> get pitchStream => _controller.stream;

  @override
  Stream<Uint8List> get pcmStream => const Stream.empty();

  @override
  int get sampleRate => 16000;

  @override
  Future<void> start() async {}

  @override
  void stop() {}

  @override
  void dispose() => _controller.close();
}
