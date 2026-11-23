import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'gliss_take.dart';
import 'slide_calibration.dart';
import 'take.dart';
import 'take_store.dart';
import 'take_style.dart';

/// Records a take from the moment it opens: every reading the home screen
/// gets (slide and pitch) and the mic audio. Stop saves it and pops with
/// the [Take]; closing throws it away and pops with null.
class RecordScreen extends StatefulWidget {
  /// ToF readings with the pitch heard at the time.
  final Stream<CalFrame> frames;

  /// The mic's PCM (empty stream where there is none).
  final Stream<Uint8List> pcm;
  final int sampleRate;
  final SlideCalibration cal;
  final TakeStore store;

  /// True when pitch is coming in (mic on, piezo, or mock).
  final bool hearing;

  /// Title for the take (another take of a piece); null = by the time.
  final String? title;

  const RecordScreen({
    super.key,
    required this.frames,
    required this.pcm,
    required this.sampleRate,
    required this.cal,
    required this.store,
    this.hearing = true,
    this.title,
  });

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  late final TakeRecorder _rec = TakeRecorder(audioRate: widget.sampleRate);
  StreamSubscription<CalFrame>? _frameSub;
  StreamSubscription<Uint8List>? _pcmSub;
  Timer? _clock;
  bool _saving = false;
  // Kept so a retry after a failed save saves the same take (finishing
  // hands over the recorded audio).
  (Take, Uint8List?)? _finished;

  double? _semis; // last seen
  double? _freq;
  bool _audio = false;

  /// The last few seconds for the rolling trace: (ms, semis, cents).
  final _trail = <(int, double?, double?)>[];
  static const _trailMs = 4000;

  @override
  void initState() {
    super.initState();
    _frameSub = widget.frames.listen(_onFrame);
    _pcmSub = widget.pcm.listen((chunk) {
      _rec.addPcm(DateTime.now(), chunk);
      if (!_audio) setState(() => _audio = true);
    });
    // The timer readout moves even when no readings arrive.
    _clock = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => setState(() {}),
    );
  }

  void _onFrame(CalFrame f) {
    final semis = f.mm == null ? null : widget.cal.semitonesFromMm(f.mm!);
    _rec.addFrame(f.t, mm: f.mm, semis: semis, freq: f.freq);
    if (semis != null) _semis = semis;
    _freq = f.freq != null && f.freq! > 30 ? f.freq : null;
    final ms = _rec.elapsedMs;
    _trail.add((ms, semis, _freq == null ? null : nearestNote(_freq!).$2));
    while (_trail.isNotEmpty && _trail.first.$1 < ms - _trailMs) {
      _trail.removeAt(0);
    }
  }

  Future<void> _stop() async {
    if (_saving) return;
    setState(() => _saving = true);
    // Stop taking readings (no need to wait for the cancels).
    _frameSub?.cancel();
    _pcmSub?.cancel();
    _clock?.cancel();
    final s = _rec.started;
    String two(int v) => v.toString().padLeft(2, '0');
    final (take, wav) = _finished ??= _rec.finish(
      id: TakeStore.newId(s),
      title: widget.title ?? 'Take ${two(s.hour)}:${two(s.minute)}',
    );
    try {
      await widget.store.save(take, wav);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn\'t save the take: $e')));
      setState(() => _saving = false);
      return;
    }
    if (mounted) Navigator.of(context).pop(take);
  }

  Future<void> _cancel() async {
    final discard =
        _rec.frameCount < 50 ||
        (await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Discard this take?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Keep recording'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Discard'),
                  ),
                ],
              ),
            ) ??
            false);
    if (discard && mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _pcmSub?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semis = _semis;
    final pos = semis == null ? null : (1 + semis.round()).clamp(1, 7);
    final note = _freq == null ? null : nearestNote(_freq!);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: TakeStyle.ground,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Discard take',
                      onPressed: _saving ? null : _cancel,
                      icon: const Icon(Icons.close, color: TakeStyle.text),
                    ),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: TakeStyle.record,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      clockLabel(_rec.elapsedMs),
                      style: TakeStyle.mono.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        color: TakeStyle.text,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: _Source(
                                'Slide pod',
                                semis != null,
                                semis == null ? 'waiting' : 'live',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _Source(
                                'Mic audio',
                                _audio,
                                _audio
                                    ? '${widget.sampleRate ~/ 1000} kHz'
                                    : 'none',
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!widget.hearing)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Text(
                            'No pitch is coming in: turn the mic on to analyse intonation.',
                            style: TextStyle(
                              fontSize: 12,
                              color: TakeStyle.warn,
                            ),
                          ),
                        ),
                      const SizedBox(height: 28),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(
                            children: [
                              Text(
                                pos == null ? '–' : '$pos',
                                style: TextStyle(
                                  fontSize: 96,
                                  fontWeight: FontWeight.w300,
                                  height: 1,
                                  color: pos == null
                                      ? TakeStyle.muted
                                      : TakeStyle.position(pos),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                semis == null
                                    ? 'Position'
                                    : 'Position ${(1 + semis).toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: TakeStyle.muted,
                                ),
                              ),
                            ],
                          ),
                          Container(
                            width: 1,
                            height: 96,
                            margin: const EdgeInsets.symmetric(horizontal: 32),
                            color: TakeStyle.line,
                          ),
                          SizedBox(
                            width: 110,
                            child: Column(
                              children: [
                                Text(
                                  note == null ? '–' : noteName(note.$1),
                                  style: const TextStyle(
                                    fontSize: 52,
                                    fontWeight: FontWeight.w500,
                                    height: 1,
                                    color: TakeStyle.text,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  note == null ? ' ' : centsLabel(note.$2),
                                  style: TakeStyle.mono.copyWith(
                                    fontSize: 18,
                                    color: note == null
                                        ? TakeStyle.muted
                                        : TakeStyle.centsColor(note.$2),
                                  ),
                                ),
                                Text(
                                  _freq == null
                                      ? ' '
                                      : '${_freq!.toStringAsFixed(1)} Hz',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: TakeStyle.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        decoration: BoxDecoration(
                          color: TakeStyle.card,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'LAST 4 SECONDS',
                              style: TakeStyle.sectionLabel,
                            ),
                            const SizedBox(height: 6),
                            SizedBox(
                              height: 150,
                              width: double.infinity,
                              child: CustomPaint(
                                painter: _TrailPainter(
                                  List.of(_trail),
                                  _rec.elapsedMs,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                child: Semantics(
                  button: true,
                  label: 'Stop and review',
                  child: InkResponse(
                    onTap: _saving ? null : _stop,
                    radius: 48,
                    child: Container(
                      width: 84,
                      height: 84,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: TakeStyle.record, width: 4),
                      ),
                      child: _saving
                          ? const CircularProgressIndicator(
                              color: TakeStyle.record,
                            )
                          : Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: TakeStyle.record,
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Source extends StatelessWidget {
  final String label;
  final bool on;
  final String detail;
  const _Source(this.label, this.on, this.detail);

  @override
  Widget build(BuildContext context) => Container(
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: TakeStyle.card,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: on ? TakeStyle.good : TakeStyle.muted,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: TakeStyle.text),
        ),
        const Spacer(),
        Text(
          detail,
          style: TakeStyle.mono.copyWith(fontSize: 12, color: TakeStyle.muted),
        ),
      ],
    ),
  );
}

/// The rolling trace: slide position on top (gridlines in position
/// colours), cents below.
class _TrailPainter extends CustomPainter {
  final List<(int, double?, double?)> trail;
  final int nowMs;
  _TrailPainter(this.trail, this.nowMs);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    const slideH = 96.0, rowH = 14.0, gap = 10.0;
    double x(int ms) => w - (nowMs - ms) / _RecordScreenState._trailMs * w;
    double ys(double s) => 6 + s.clamp(-0.3, 6.3) * rowH;
    for (var p = 1; p <= 7; p++) {
      canvas.drawLine(
        Offset(0, ys(p - 1.0)),
        Offset(w, ys(p - 1.0)),
        Paint()..color = TakeStyle.position(p).withValues(alpha: 0.3),
      );
    }
    final tuneTop = slideH + gap, tuneBottom = size.height;
    final mid = (tuneTop + tuneBottom) / 2, half = (tuneBottom - tuneTop) / 2;
    double yc(double c) => mid - c.clamp(-50.0, 50.0) / 50 * half;
    canvas.drawLine(
      Offset(0, slideH + 2),
      Offset(w, slideH + 2),
      Paint()..color = TakeStyle.line,
    );
    canvas.drawRect(
      Rect.fromLTRB(0, yc(10), w, yc(-10)),
      Paint()..color = TakeStyle.good.withValues(alpha: 0.12),
    );
    canvas.drawLine(
      Offset(0, mid),
      Offset(w, mid),
      Paint()..color = const Color(0xFF5F6670),
    );

    void stroke(
      double? Function((int, double?, double?)) pick,
      double Function(double) y,
      Paint paint,
    ) {
      final path = Path();
      var pen = false;
      int? last;
      for (final e in trail) {
        final v = pick(e);
        if (v == null) {
          pen = false;
          continue;
        }
        final pt = Offset(x(e.$1), y(v));
        if (!pen || (last != null && e.$1 - last > 150)) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
        pen = true;
        last = e.$1;
      }
      canvas.drawPath(path, paint);
    }

    stroke(
      (e) => e.$2,
      ys,
      Paint()
        ..color = TakeStyle.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    stroke(
      (e) => e.$3,
      yc,
      Paint()
        ..color = TakeStyle.warn
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final lastSlide = trail.lastWhere(
      (e) => e.$2 != null,
      orElse: () => (0, null, null),
    );
    if (lastSlide.$2 != null) {
      final s = lastSlide.$2!;
      canvas.drawCircle(
        Offset(math.min(w - 4, x(lastSlide.$1)), ys(s)),
        4,
        Paint()..color = TakeStyle.positionOfSemis(s),
      );
    }
  }

  @override
  bool shouldRepaint(_TrailPainter old) => true;
}
