import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'pitch_detector.dart';
import 'pitch_yin.dart';

PitchDetector createPitchDetector() => _MicPitchDetector();

/// Native (Android/iOS/desktop) mic → YIN. Streams 16 kHz mono PCM16 and
/// emits a pitch (or null) every 20 ms.
class _MicPitchDetector implements PitchDetector {
  final _controller = StreamController<double?>.broadcast();
  final _pcm = StreamController<Uint8List>.broadcast();
  // Created lazily: constructing it touches the platform channel, which
  // doesn't exist in widget tests.
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  final _yin = PitchYin();
  static final int _hop = (PitchYin.sampleRate / 50).round();
  int _sinceHop = 0;
  int? _carry; // odd byte left over from the previous chunk

  @override
  Stream<double?> get pitchStream => _controller.stream;

  @override
  Stream<Uint8List> get pcmStream => _pcm.stream;

  @override
  int get sampleRate => PitchYin.sampleRate.round();

  @override
  Future<void> start() async {
    final rec = _recorder ??= AudioRecorder();
    if (_sub != null) {
      // Already on, unless Android took the mic away underneath: playing
      // a take (just_audio) takes audio focus and the recorder pauses.
      if (await rec.isPaused()) {
        await rec.resume();
        return;
      }
      if (await rec.isRecording()) return;
      // Stopped altogether: start it again.
      await _sub?.cancel();
      _sub = null;
      _carry = null;
    }
    if (!await rec.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final stream = await rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      // Processing meant for speech mangles a sustained brass tone.
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.mic,
        manageBluetooth: false, // don't grab SCO; SlidePod is BLE anyway
      ),
    ));
    _sub = stream.listen(_onChunk);
  }

  void _onChunk(Uint8List bytes) {
    if (_pcm.hasListener) _pcm.add(bytes);
    var i = 0;
    if (_carry != null && bytes.isNotEmpty) {
      _push(_carry! | (bytes[0] << 8));
      _carry = null;
      i = 1;
    }
    for (; i + 1 < bytes.length; i += 2) {
      _push(bytes[i] | (bytes[i + 1] << 8));
    }
    if (i < bytes.length) _carry = bytes[i];
  }

  void _push(int u16) {
    final s = u16 >= 0x8000 ? u16 - 0x10000 : u16; // little-endian int16
    _yin.push(s / 32768.0);
    if (++_sinceHop >= _hop) {
      _sinceHop = 0;
      _controller.add(_yin.detect());
    }
  }

  @override
  void stop() {
    _sub?.cancel();
    _sub = null;
    _carry = null;
    _recorder?.stop();
  }

  @override
  void dispose() {
    stop();
    _recorder?.dispose();
    _controller.close();
    _pcm.close();
  }
}
