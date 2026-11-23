import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'note_diagnosis.dart';
import 'reference_tone.dart';
import 'slide_calibration.dart';
import 'take_analysis.dart';
import 'take_store.dart';
import 'take_style.dart';

/// One note up close: what went wrong and why, how the slide arrived, the
/// pitch against what the slide alone would give, and the same note in
/// earlier takes of this piece. Pops with true to loop it slowly in review.
class NoteDetailScreen extends StatefulWidget {
  final TakeAnalysis analysis;
  final NoteAnalysis note;
  final SlideCalibration cal;
  final TakeStore? store;

  const NoteDetailScreen({
    super.key,
    required this.analysis,
    required this.note,
    required this.cal,
    this.store,
  });

  /// How many earlier takes the history looks at.
  static const historyTakes = 4;

  @override
  State<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  final _tone = ReferenceTonePlayer();
  List<double>? _history; // oldest first, earlier takes only

  NoteAnalysis get n => widget.note;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _tone.dispose();
    super.dispose();
  }

  /// The same note in earlier takes with this title: the one with the same
  /// pitch nearest the same place in the take.
  Future<void> _loadHistory() async {
    final store = widget.store;
    final take = widget.analysis.take;
    if (store == null) return;
    final earlier = (await store.list())
        .where((t) => t.title == take.title && t.started.isBefore(take.started))
        .take(NoteDetailScreen.historyTakes)
        .toList();
    final out = <double>[];
    for (final t in earlier.reversed) {
      final other = await store.load(t.id);
      if (other == null) continue;
      final a = TakeAnalysis.analyze(other, widget.cal);
      NoteAnalysis? best;
      for (final m in a.notes) {
        if (m.midi != n.midi) continue;
        if (best == null || (m.index - n.index).abs() < (best.index - n.index).abs()) {
          best = m;
        }
      }
      if (best != null) out.add(best.cents);
    }
    if (mounted) setState(() => _history = out);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    final d = diagnose(n, widget.cal);
    final pos = n.targetPosition;
    final s = n.shift;
    final (diagBg, diagHead, diagBody) = switch (d.kind) {
      DiagnosisKind.good => (const Color(0xFF17291B), const Color(0xFFC8EFCF), const Color(0xFFB9D6BE)),
      DiagnosisKind.slide => (const Color(0xFF2A2418), const Color(0xFFFFE0B2), const Color(0xFFE0D3BF)),
      DiagnosisKind.lip => (const Color(0xFF1F2238), const Color(0xFFD6DCFF), const Color(0xFFC3C8E6)),
    };
    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        titleSpacing: 0,
        title: Text(
            'Note ${n.index + 1} of ${a.notes.length} · '
            '${(n.startMs / 1000).toStringAsFixed(2)} – '
            '${(n.endMs / 1000).toStringAsFixed(2)} s',
            style: const TextStyle(fontSize: 13, color: TakeStyle.muted)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                Text(noteName(n.midi),
                    style: const TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.w500,
                        height: 1,
                        color: TakeStyle.text)),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (pos != null) ...[
                        PositionBadge(pos, size: 22),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                            [
                              if (pos != null) '${ordinal(pos)} position',
                              if (n.partial != null) '${ordinal(n.partial!)} partial',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 13, color: TakeStyle.body)),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                        '${centsLabel(n.cents)}'
                        '${n.landedSemis == null ? '' : ' · landed at ${(1 + n.landedSemis!).toStringAsFixed(2)}'}',
                        style: TakeStyle.mono.copyWith(
                            fontSize: 15, color: TakeStyle.centsColor(n.cents))),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: diagBg, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.headline,
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600, color: diagHead)),
                const SizedBox(height: 4),
                Text(d.body,
                    style: TextStyle(fontSize: 13, height: 1.45, color: diagBody)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (n.targetSemis != null && n.landedSemis != null)
            _ChartCard(
              title: 'SLIDE ARRIVAL',
              note: s == null
                  ? 'no move into this note'
                  : '${s.durationMs} ms · peak ${s.peakSpeed.toStringAsFixed(1)} pos/s',
              tag: s == null ? null : TakeStyle.shiftTag(s.result),
              child: CustomPaint(
                size: const Size(double.infinity, 140),
                painter: _ArrivalPainter(a, n),
              ),
            ),
          const SizedBox(height: 12),
          _ChartCard(
            title: 'PITCH',
            note: n.targetSemis == null ? '' : 'dashed: what the slide gives',
            child: CustomPaint(
              size: const Size(double.infinity, 110),
              painter: _PitchPainter(a.centsTrace(n), a.slideCentsTrace(n), n),
            ),
          ),
          if (_history != null && _history!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                      'This note, last ${_history!.length + 1} takes',
                      style: const TextStyle(fontSize: 12, color: TakeStyle.muted)),
                ),
                for (final c in _history!) _HistoryChip(c),
                _HistoryChip(n.cents, current: true),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                flex: 5,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    foregroundColor: TakeStyle.text,
                    side: const BorderSide(color: TakeStyle.line),
                  ),
                  onPressed: () => _tone.play(n.midi),
                  icon: const Icon(Icons.music_note),
                  label: Text('Hear ${noteName(n.midi)}'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 7,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: TakeStyle.accent,
                    foregroundColor: TakeStyle.onAccent,
                  ),
                  onPressed: () => Navigator.of(context).pop(true),
                  icon: const Icon(Icons.repeat),
                  label: const Text('Loop at 0.25×'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final String title, note;
  final (String, Color, Color)? tag;
  final Widget child;
  const _ChartCard(
      {required this.title, required this.note, this.tag, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        decoration: BoxDecoration(
            color: TakeStyle.card, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Row(
                children: [
                  Text(title, style: TakeStyle.sectionLabel),
                  const SizedBox(width: 8),
                  if (tag != null) TakeTag(tag!),
                  const Spacer(),
                  Flexible(
                    flex: 3,
                    child: Text(note,
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: TakeStyle.muted)),
                  ),
                ],
              ),
            ),
            child,
          ],
        ),
      );
}

class _HistoryChip extends StatelessWidget {
  final double cents;
  final bool current;
  const _HistoryChip(this.cents, {this.current = false});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: current ? const Color(0xFF1E2A3A) : TakeStyle.chip,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(centsLabel(cents).replaceAll('¢', ''),
            style: TakeStyle.mono.copyWith(
                fontSize: 12,
                color: current ? TakeStyle.text : TakeStyle.centsColor(cents))),
      );
}

TextPainter _label(String s, Color c, {double size = 9}) => TextPainter(
      text: TextSpan(
          text: s, style: TakeStyle.mono.copyWith(fontSize: size, color: c)),
      textDirection: TextDirection.ltr,
    )..layout();

void _dash(Canvas canvas, Offset a, Offset b, Paint p) {
  final len = (b - a).distance;
  if (len == 0) return;
  final dir = (b - a) / len;
  for (var d = 0.0; d < len; d += 7) {
    canvas.drawLine(a + dir * d, a + dir * math.min(len, d + 4), p);
  }
}

Path _tracePath(List<(int, double)> pts, Offset Function(int, double) at) {
  final path = Path();
  for (var i = 0; i < pts.length; i++) {
    final o = at(pts[i].$1, pts[i].$2);
    if (i == 0 || pts[i].$1 - pts[i - 1].$1 > 150) {
      path.moveTo(o.dx, o.dy);
    } else {
      path.lineTo(o.dx, o.dy);
    }
  }
  return path;
}

/// The slide coming into the note: its path against this horn's spot for
/// the note, with the onset and the moment it settled.
class _ArrivalPainter extends CustomPainter {
  final TakeAnalysis a;
  final NoteAnalysis n;
  _ArrivalPainter(this.a, this.n);

  @override
  void paint(Canvas canvas, Size size) {
    final s = n.shift;
    final from = s == null ? n.startMs - 300 : math.min(s.startMs, n.startMs) - 150;
    final to = math.min(n.endMs, math.max(n.startMs + 600, (s?.arriveMs ?? 0) + 300));
    final pts = a.slideTrace(from, to);
    final target = math.max(n.targetSemis!, 0.0);
    var lo = target - 0.4, hi = target + 0.4;
    for (final (_, v) in pts) {
      lo = math.min(lo, v - 0.1);
      hi = math.max(hi, v + 0.1);
    }
    const left = 26.0, bottom = 16.0;
    final w = size.width, h = size.height - bottom;
    double x(int t) => left + (w - left - 4) * (t - from) / math.max(1, to - from);
    double y(double v) => 4 + (h - 8) * (v - lo) / (hi - lo); // out = down

    // Whole positions in view, in their colours.
    for (var p = 1; p <= 7; p++) {
      final v = p - 1.0;
      if (v < lo || v > hi) continue;
      final c = TakeStyle.position(p);
      canvas.drawLine(Offset(left, y(v)), Offset(w, y(v)),
          Paint()..color = c.withValues(alpha: 0.35));
      final tp = _label('$p', c);
      tp.paint(canvas, Offset(left - 8 - tp.width, y(v) - tp.height / 2));
    }
    // This horn's spot and the tolerance either side.
    final tol = a.config.slideTol;
    canvas.drawRect(Rect.fromLTRB(left, y(target - tol), w, y(target + tol)),
        Paint()..color = TakeStyle.good.withValues(alpha: 0.12));
    _dash(canvas, Offset(left, y(target)), Offset(w, y(target)),
        Paint()
          ..color = TakeStyle.body
          ..strokeWidth = 1.5);

    final guide = Paint()..color = const Color(0xFF5F6670);
    void mark(int t, String label) {
      if (t < from || t > to) return;
      _dash(canvas, Offset(x(t), 0), Offset(x(t), h), guide);
      final tp = _label(label, TakeStyle.muted, size: 8);
      tp.paint(canvas, Offset(x(t) - tp.width / 2, h + 3));
    }

    mark(n.startMs, 'onset');
    if (s != null && s.arriveMs != n.startMs) {
      final d = s.arriveMs - n.startMs;
      mark(s.arriveMs, 'settled ${d >= 0 ? '+' : '−'}${d.abs()} ms');
    }

    canvas.drawPath(
        _tracePath(pts, (t, v) => Offset(x(t), y(v))),
        Paint()
          ..color = TakeStyle.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);

    if (s != null && s.result == ShiftResult.overshot) {
      final v = s.targetSemis + s.direction * s.peakError;
      canvas.drawCircle(Offset(x(s.extremeMs), y(v)), 4, Paint()..color = TakeStyle.over);
      final tp = _label(posDelta(s.peakError), const Color(0xFFFFCC80));
      tp.paint(canvas, Offset(x(s.extremeMs) + 6, y(v) - tp.height / 2));
    } else if (s != null && s.result == ShiftResult.short) {
      final v = s.targetSemis + s.direction * s.firstStopError;
      canvas.drawCircle(Offset(x(s.firstStopMs), y(v)), 4, Paint()..color = TakeStyle.short);
      final tp = _label(posDelta(s.firstStopError), const Color(0xFFB0BCFF));
      tp.paint(canvas, Offset(x(s.firstStopMs) + 6, y(v) - tp.height / 2));
    }
    // Where it rested, against the spot.
    final landed = n.landedSemis!;
    final err = landed - target;
    if (err.abs() >= 0.02) {
      final xe = w - 30;
      canvas.drawLine(Offset(xe, y(target)), Offset(xe, y(landed)),
          Paint()
            ..color = TakeStyle.warn
            ..strokeWidth = 2);
      final tp = _label(posDelta(err), const Color(0xFFFFCC80));
      tp.paint(canvas, Offset(xe + 4, (y(target) + y(landed)) / 2 - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_ArrivalPainter old) => old.a != a || old.n != n;
}

/// Cents over the note, with what the slide alone gives dashed: if they
/// run together the slide is the cause, if they part the lips are.
class _PitchPainter extends CustomPainter {
  final List<(int, double)> played, fromSlide;
  final NoteAnalysis n;
  _PitchPainter(this.played, this.fromSlide, this.n);

  @override
  void paint(Canvas canvas, Size size) {
    var range = 30.0;
    for (final (_, c) in [...played, ...fromSlide]) {
      range = math.max(range, math.min(60, c.abs() + 5));
    }
    const left = 30.0;
    final w = size.width, h = size.height;
    double x(int t) =>
        left + (w - left - 4) * (t - n.startMs) / math.max(1, n.endMs - n.startMs);
    double y(double c) => h / 2 - c.clamp(-range, range) / range * (h / 2 - 4);

    canvas.drawRect(Rect.fromLTRB(left, y(10), w, y(-10)),
        Paint()..color = TakeStyle.good.withValues(alpha: 0.12));
    canvas.drawLine(Offset(left, y(0)), Offset(w, y(0)),
        Paint()..color = const Color(0xFF5F6670));
    for (final c in [0.0, 25.0, -25.0]) {
      if (c.abs() > range) continue;
      final tp = _label(c == 0 ? '0' : centsLabel(c).replaceAll('¢', ''), TakeStyle.muted, size: 8);
      tp.paint(canvas, Offset(left - 6 - tp.width, y(c) - tp.height / 2));
    }
    final dash = Paint()
      ..color = TakeStyle.muted
      ..strokeWidth = 1.5;
    for (var i = 1; i < fromSlide.length; i++) {
      if (i.isOdd) continue; // dashed by skipping
      final (t0, c0) = fromSlide[i - 1];
      final (t1, c1) = fromSlide[i];
      canvas.drawLine(Offset(x(t0), y(c0)), Offset(x(t1), y(c1)), dash);
    }
    canvas.drawPath(
        _tracePath(played, (t, c) => Offset(x(t), y(c))),
        Paint()
          ..color = TakeStyle.centsColor(n.cents)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_PitchPainter old) =>
      old.played != played || old.fromSlide != fromSlide;
}
