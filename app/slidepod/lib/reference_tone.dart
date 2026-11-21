import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import 'take.dart';

/// A short tone at an exact pitch, to hear what in tune is. Harmonics fall
/// off like a mellow brass tone, so it's easy to match by ear.
Uint8List referenceToneWav(double freq,
    {int sampleRate = 22050, int ms = 1600}) {
  const harmonics = [1.0, 0.62, 0.45, 0.3, 0.2, 0.12, 0.07];
  final n = sampleRate * ms ~/ 1000;
  final attack = sampleRate * 0.04, release = sampleRate * 0.25;
  final nyquist = sampleRate / 2;
  final pcm = Int16List(n);
  final norm = harmonics.reduce((a, b) => a + b);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    var v = 0.0;
    for (var h = 0; h < harmonics.length; h++) {
      final f = freq * (h + 1);
      if (f >= nyquist) break;
      v += harmonics[h] * math.sin(2 * math.pi * f * t);
    }
    final env = math.min(1.0, math.min(i / attack, (n - i) / release));
    pcm[i] = (v / norm * env * 0.8 * 32767).round().clamp(-32768, 32767);
  }
  return wavBytes(pcm.buffer.asUint8List(), sampleRate);
}

/// Plays [referenceToneWav]s; one player, made on first use.
class ReferenceTonePlayer {
  AudioPlayer? _player;
  final _cache = <int, Uri>{};

  /// Plays the equal-tempered note [midi]. Errors (no audio output) are
  /// swallowed: the tone is a convenience.
  Future<void> play(int midi) async {
    try {
      final uri = _cache[midi] ??= Uri.dataFromBytes(
          referenceToneWav(440.0 * math.pow(2, (midi - 69) / 12)),
          mimeType: 'audio/wav');
      final p = _player ??= AudioPlayer();
      await p.stop();
      await p.setAudioSource(AudioSource.uri(uri));
      p.play();
    } catch (_) {}
  }

  void dispose() => _player?.dispose();
}
