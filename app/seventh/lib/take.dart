import 'dart:convert';
import 'dart:typed_data';

/// One update during a take, [tMs] after the take started.
///
/// [mm] is the smoothed ToF reading and [semis] the slide extension it maps
/// to through the calibration at the time (0 = 1st, 6 = 7th); both null when
/// the sensor had no reading. [freq] is the pitch heard (null = no note). The
/// raw millimetres are kept so a take can be re-analysed after the slide is
/// recalibrated.
typedef TakeFrame = ({int tMs, double? mm, double? semis, double? freq});

/// A recorded take: the slide and pitch at every update, plus the audio file
/// that goes with it (if the platform could record one).
class Take {
  static const int version = 1;

  final String id;
  String title;
  final DateTime started;
  final List<TakeFrame> frames;

  /// File name of the take's WAV next to its JSON, or null when there is no
  /// audio (web build, mic off).
  final String? audioFile;
  final int audioRate;

  /// Where the audio starts on the frames' clock: audio sample 0 is at
  /// [audioOffsetMs] (may be negative: the mic was already running).
  final int audioOffsetMs;

  Take({
    required this.id,
    required this.title,
    required this.started,
    required this.frames,
    this.audioFile,
    this.audioRate = 16000,
    this.audioOffsetMs = 0,
  });

  int get durationMs => frames.isEmpty ? 0 : frames.last.tMs;

  /// Compact JSON: one array per column rather than one object per frame
  /// (a minute at 50 Hz is 3000 frames).
  String toJson() {
    double? r(double? v, int places) {
      if (v == null || !v.isFinite) return null;
      final p = [1, 10, 100, 1000][places];
      return (v * p).roundToDouble() / p;
    }

    return jsonEncode({
      'v': version,
      'id': id,
      'title': title,
      'started': started.toUtc().toIso8601String(),
      if (audioFile != null)
        'audio': {'file': audioFile, 'rate': audioRate, 'offsetMs': audioOffsetMs},
      't': [for (final f in frames) f.tMs],
      'mm': [for (final f in frames) r(f.mm, 1)],
      'semis': [for (final f in frames) r(f.semis, 3)],
      'hz': [for (final f in frames) r(f.freq, 2)],
    });
  }

  static Take fromJson(String json) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    final t = (m['t'] as List).cast<num>();
    final mm = (m['mm'] as List).cast<num?>();
    final semis = (m['semis'] as List).cast<num?>();
    final hz = (m['hz'] as List).cast<num?>();
    final audio = m['audio'] as Map<String, dynamic>?;
    return Take(
      id: m['id'] as String,
      title: m['title'] as String,
      started: DateTime.parse(m['started'] as String).toLocal(),
      frames: [
        for (var i = 0; i < t.length; i++)
          (
            tMs: t[i].toInt(),
            mm: mm[i]?.toDouble(),
            semis: semis[i]?.toDouble(),
            freq: hz[i]?.toDouble(),
          ),
      ],
      audioFile: audio?['file'] as String?,
      audioRate: (audio?['rate'] as num?)?.toInt() ?? 16000,
      audioOffsetMs: (audio?['offsetMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Collects a take while it is played: feed it every reading ([addFrame])
/// and every chunk of mic PCM ([addPcm]), then [finish].
class TakeRecorder {
  final DateTime started;
  final int audioRate;
  final _frames = <TakeFrame>[];
  final _pcm = BytesBuilder(); // copies: the mic may reuse its buffers
  int? _audioOffsetMs;

  TakeRecorder({DateTime? started, this.audioRate = 16000})
      : started = started ?? DateTime.now();

  int _ms(DateTime t) => t.difference(started).inMilliseconds;

  int get elapsedMs => _ms(DateTime.now());
  int get frameCount => _frames.length;
  List<TakeFrame> get frames => List.unmodifiable(_frames);

  void addFrame(DateTime t, {double? mm, double? semis, double? freq}) {
    final ms = _ms(t);
    if (ms < 0) return;
    _frames.add((
      tMs: ms,
      mm: mm,
      semis: semis,
      freq: freq != null && freq > 30 ? freq : null,
    ));
  }

  /// A chunk of 16-bit little-endian mono PCM that arrived at [t]. The first
  /// chunk sets where the audio sits on the frames' clock: it ended at [t],
  /// so it started one chunk length earlier.
  void addPcm(DateTime t, Uint8List chunk) {
    if (chunk.isEmpty) return;
    _audioOffsetMs ??=
        _ms(t) - (chunk.length ~/ 2 * 1000 / audioRate).round();
    _pcm.add(chunk);
  }

  bool get hasAudio => _pcm.isNotEmpty;

  /// The finished take and its WAV bytes (null when no audio came in).
  (Take, Uint8List?) finish({required String id, required String title}) {
    final audio = hasAudio ? wavBytes(_pcm.takeBytes(), audioRate) : null;
    return (
      Take(
        id: id,
        title: title,
        started: started,
        frames: List.of(_frames),
        audioFile: audio == null ? null : '$id.wav',
        audioRate: audioRate,
        audioOffsetMs: _audioOffsetMs ?? 0,
      ),
      audio,
    );
  }
}

/// A RIFF/WAVE file around 16-bit mono PCM.
Uint8List wavBytes(Uint8List pcm16, int sampleRate) {
  final len = pcm16.length & ~1; // whole samples only
  final out = Uint8List(44 + len);
  final b = ByteData.sublistView(out);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      out[at + i] = s.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + len, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little); // fmt chunk size
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  b.setUint16(32, 2, Endian.little); // block align
  b.setUint16(34, 16, Endian.little); // bits per sample
  tag(36, 'data');
  b.setUint32(40, len, Endian.little);
  out.setRange(44, 44 + len, pcm16);
  return out;
}
