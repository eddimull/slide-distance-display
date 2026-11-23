import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'take_analysis.dart';
import 'take_style.dart';

/// The take on one time axis: where the slide was (against this horn's
/// target for each note, with ▲ overshoots and ▼ short stops), how fast it
/// moved, and how far each note was from in tune. Tap to seek. Takes longer
/// than fits scroll sideways and follow the playhead.
class TakeTimeline extends StatefulWidget {
  final TakeAnalysis analysis;
  final int playheadMs;
  final (int, int)? loop;
  final int? selectedNote;
  final ValueChanged<int> onSeek;

  const TakeTimeline({
    super.key,
    required this.analysis,
    required this.playheadMs,
    required this.onSeek,
    this.loop,
    this.selectedNote,
  });

  static const double height = 300;

  /// Narrowest the time axis is drawn: more than this per second scrolls.
  static const double minPxPerSecond = 36;

  @override
  State<TakeTimeline> createState() => _TakeTimelineState();
}

class _TakeTimelineState extends State<TakeTimeline> {
  final _scroll = ScrollController();
  double _width = 0, _view = 0;

  @override
  void didUpdateWidget(TakeTimeline old) {
    super.didUpdateWidget(old);
    if (old.playheadMs != widget.playheadMs) _follow();
  }

  void _follow() {
    if (!_scroll.hasClients || _width <= _view) return;
    final x = _TimelinePainter.xFor(
        widget.playheadMs, widget.analysis.take.durationMs, _width);
    final off = _scroll.offset;
    if (x < off + 24 || x > off + _view - 24) {
      _scroll.jumpTo((x - _view * 0.3).clamp(0.0, _width - _view));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final dur = math.max(1, widget.analysis.take.durationMs);
      _view = box.maxWidth;
      _width = math.max(_view, dur / 1000 * TakeTimeline.minPxPerSecond);
      return SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        physics: _width > _view
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => widget.onSeek(
              _TimelinePainter.timeFor(d.localPosition.dx, dur, _width)),
          child: CustomPaint(
            size: Size(_width, TakeTimeline.height),
            painter: _TimelinePainter(
              analysis: widget.analysis,
              playheadMs: widget.playheadMs,
              loop: widget.loop,
              selectedNote: widget.selectedNote,
            ),
          ),
        ),
      );
    });
  }
}

class _TimelinePainter extends CustomPainter {
  final TakeAnalysis analysis;
  final int playheadMs;
  final (int, int)? loop;
  final int? selectedNote;

  _TimelinePainter({
    required this.analysis,
    required this.playheadMs,
    required this.loop,
    required this.selectedNote,
  });

  static const double gutter = 26, right = 8;

  // Lanes, top to bottom.
  static const double labelsTop = 0, slideTop = 18, rowH = 15;
  static const double slideBottom = slideTop + 6 * rowH + 16; // 124
  static const double speedTop = slideBottom + 10, speedBottom = speedTop + 54;
  static const double tuneTop = speedBottom + 10, tuneBottom = tuneTop + 80;
  static const double axisY = tuneBottom + 14;

  static double xFor(int ms, int durMs, double width) =>
      gutter + (width - gutter - right) * ms / math.max(1, durMs);

  static int timeFor(double x, int durMs, double width) =>
      ((x - gutter) / (width - gutter - right) * durMs)
          .round()
          .clamp(0, durMs);

  double _ySemis(double s) => slideTop + 8 + s.clamp(-0.4, 6.4) * rowH;

  static const _centsRange = 50.0;
  double _yCents(double c) {
    final mid = (tuneTop + 18 + tuneBottom) / 2;
    final half = (tuneBottom - tuneTop - 18) / 2;
    return mid - c.clamp(-_centsRange, _centsRange) / _centsRange * half;
  }

  void _text(Canvas canvas, String s, Offset at, TextStyle style,
      {TextAlign align = TextAlign.left}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) {
      TextAlign.center => tp.width / 2,
      TextAlign.right => tp.width,
      _ => 0.0,
    };
    tp.paint(canvas, at - Offset(dx, 0));
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint p,
      {double dash = 3, double gap = 2}) {
    final len = (b - a).distance;
    if (len == 0) return;
    final dir = (b - a) / len;
    for (var d = 0.0; d < len; d += dash + gap) {
      canvas.drawLine(a + dir * d, a + dir * math.min(len, d + dash), p);
    }
  }

  void _triangle(Canvas canvas, Offset c, bool up, Color color) {
    const s = 5.0;
    final path = up
        ? (Path()
          ..moveTo(c.dx, c.dy - s)
          ..lineTo(c.dx + s, c.dy + s)
          ..lineTo(c.dx - s, c.dy + s))
        : (Path()
          ..moveTo(c.dx - s, c.dy - s)
          ..lineTo(c.dx + s, c.dy - s)
          ..lineTo(c.dx, c.dy + s));
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final dur = math.max(1, analysis.take.durationMs);
    double x(int ms) => xFor(ms, dur, w);
    const small = TextStyle(fontSize: 9, color: TakeStyle.muted);
    final mono = TakeStyle.mono.copyWith(fontSize: 9, color: TakeStyle.muted);

    // Loop region and the selected note.
    if (loop != null) {
      final r = Rect.fromLTRB(x(loop!.$1), 0, x(loop!.$2), axisY - 10);
      canvas.drawRect(r, Paint()..color = TakeStyle.accent.withValues(alpha: 0.08));
      final edge = Paint()
        ..color = TakeStyle.accent.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      canvas.drawLine(r.topLeft, r.bottomLeft, edge);
      canvas.drawLine(r.topRight, r.bottomRight, edge);
    }

    // Note names over each note, where there's room.
    for (final n in analysis.notes) {
      final x0 = x(n.startMs), x1 = x(n.endMs);
      if (x1 - x0 < 18) continue;
      final sel = n.index == selectedNote;
      _text(canvas, noteName(n.midi), Offset((x0 + x1) / 2, labelsTop + 2),
          small.copyWith(
              color: sel ? TakeStyle.text : TakeStyle.muted,
              fontWeight: sel ? FontWeight.w600 : FontWeight.normal),
          align: TextAlign.center);
    }

    // ── Slide position ──
    for (var p = 1; p <= 7; p++) {
      final y = _ySemis(p - 1.0);
      final c = TakeStyle.position(p);
      canvas.drawLine(Offset(gutter, y), Offset(w - right, y),
          Paint()
            ..color = c.withValues(alpha: 0.3)
            ..strokeWidth = 1);
      _text(canvas, '$p', Offset(gutter - 8, y - 6), mono.copyWith(color: c),
          align: TextAlign.right);
    }
    final target = Paint()
      ..color = TakeStyle.muted
      ..strokeWidth = 1.5;
    for (final n in analysis.notes) {
      if (n.targetSemis == null) continue;
      final y = _ySemis(math.max(0, n.targetSemis!));
      _dashed(canvas, Offset(x(n.startMs), y), Offset(x(n.endMs), y), target);
    }
    final trace = Path();
    var pen = false;
    int? lastT;
    for (final f in analysis.take.frames) {
      if (f.semis == null) continue;
      final pt = Offset(x(f.tMs), _ySemis(f.semis!));
      if (!pen || (lastT != null && f.tMs - lastT > 150)) {
        trace.moveTo(pt.dx, pt.dy);
        pen = true;
      } else {
        trace.lineTo(pt.dx, pt.dy);
      }
      lastT = f.tMs;
    }
    canvas.drawPath(
        trace,
        Paint()
          ..color = TakeStyle.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round);
    for (final n in analysis.notes) {
      final s = n.shift;
      if (s == null) continue;
      if (s.result == ShiftResult.overshot) {
        final semis = s.targetSemis + s.direction * s.peakError;
        _triangle(canvas, Offset(x(s.extremeMs), _ySemis(semis) + 9), true,
            TakeStyle.over);
      } else if (s.result == ShiftResult.short) {
        final semis = s.targetSemis + s.direction * s.firstStopError;
        _triangle(canvas, Offset(x(s.firstStopMs), _ySemis(semis) - 9), false,
            TakeStyle.short);
      }
    }

    // ── Slide speed ──
    final divider = Paint()..color = TakeStyle.line;
    canvas.drawLine(Offset(0, speedTop - 5), Offset(w, speedTop - 5), divider);
    _text(canvas, 'SLIDE SPEED (pos/s)', Offset(w - right, speedTop),
        small.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.4),
        align: TextAlign.right);
    final top = math.max(10.0, analysis.peakSpeed * 1.1);
    double ySpeed(double v) =>
        speedBottom - (v.abs() / top).clamp(0.0, 1.0) * (speedBottom - speedTop - 4);
    _dashed(canvas, Offset(gutter, ySpeed(10)), Offset(w - right, ySpeed(10)),
        divider);
    _text(canvas, '10', Offset(gutter - 4, ySpeed(10) - 6), mono,
        align: TextAlign.right);
    _text(canvas, '0', Offset(gutter - 4, speedBottom - 6), mono,
        align: TextAlign.right);
    final area = Path()..moveTo(gutter, speedBottom);
    final curve = Path();
    var first = true;
    for (final s in analysis.speed) {
      final pt = Offset(x(s.tMs), ySpeed(s.speed));
      area.lineTo(pt.dx, pt.dy);
      if (first) {
        curve.moveTo(pt.dx, pt.dy);
        first = false;
      } else {
        curve.lineTo(pt.dx, pt.dy);
      }
    }
    area
      ..lineTo(w - right, speedBottom)
      ..close();
    canvas.drawPath(area, Paint()..color = TakeStyle.text.withValues(alpha: 0.1));
    canvas.drawPath(
        curve,
        Paint()
          ..color = TakeStyle.body
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
    // Each move's peak, coloured by how it ended.
    for (final n in analysis.notes) {
      final s = n.shift;
      if (s == null || s.peakSpeed < 1) continue;
      final color = switch (s.result) {
        ShiftResult.overshot => const Color(0xFFFFCC80),
        ShiftResult.short => const Color(0xFFB0BCFF),
        ShiftResult.clean => TakeStyle.muted,
      };
      final peakAt = analysis.speed
          .where((v) => v.tMs >= s.startMs && v.tMs <= n.endMs)
          .fold<({int tMs, double speed})?>(
              null,
              (best, v) =>
                  best == null || v.speed.abs() > best.speed.abs() ? v : best);
      if (peakAt == null) continue;
      _text(canvas, s.peakSpeed.toStringAsFixed(1),
          Offset(x(peakAt.tMs), ySpeed(peakAt.speed) - 11),
          mono.copyWith(fontSize: 8, color: color),
          align: TextAlign.center);
    }

    // ── Intonation ──
    canvas.drawLine(Offset(0, tuneTop - 5), Offset(w, tuneTop - 5), divider);
    _text(canvas, 'INTONATION (¢)', Offset(8, tuneTop),
        small.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.4));
    canvas.drawRect(
        Rect.fromLTRB(gutter, _yCents(10), w - right, _yCents(-10)),
        Paint()..color = TakeStyle.good.withValues(alpha: 0.12));
    canvas.drawLine(Offset(gutter, _yCents(0)), Offset(w - right, _yCents(0)),
        Paint()..color = const Color(0xFF5F6670));
    for (final c in [25.0, -25.0]) {
      _dashed(canvas, Offset(gutter, _yCents(c)), Offset(w - right, _yCents(c)),
          divider);
    }
    _text(canvas, '+25', Offset(gutter - 4, _yCents(25) - 6), mono,
        align: TextAlign.right);
    _text(canvas, '0', Offset(gutter - 4, _yCents(0) - 6), mono,
        align: TextAlign.right);
    _text(canvas, '−25', Offset(gutter - 4, _yCents(-25) - 6), mono,
        align: TextAlign.right);
    for (final n in analysis.notes) {
      final y = _yCents(n.cents);
      final x0 = x(n.startMs) + 2, x1 = math.max(x0 + 2, x(n.endMs) - 2);
      canvas.drawLine(
          Offset(x0, y),
          Offset(x1, y),
          Paint()
            ..color = TakeStyle.centsColor(n.cents)
            ..strokeWidth = n.index == selectedNote ? 5 : 4
            ..strokeCap = StrokeCap.round);
    }

    // ── Time axis ──
    final secs = dur / 1000;
    final pxPerSec = (w - gutter - right) / secs;
    final step = [1, 2, 5, 10, 15, 30, 60].firstWhere(
        (s) => s * pxPerSec >= 44,
        orElse: () => 120);
    for (var s = 0; s <= secs; s += step) {
      _text(canvas, s == 0 ? '0s' : '$s', Offset(x(s * 1000), axisY - 8), mono,
          align: TextAlign.center);
    }

    // ── Playhead ──
    final px = x(playheadMs.clamp(0, dur));
    canvas.drawLine(Offset(px, slideTop - 2), Offset(px, tuneBottom),
        Paint()
          ..color = TakeStyle.accent
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.analysis != analysis ||
      old.playheadMs != playheadMs ||
      old.loop != loop ||
      old.selectedNote != selectedNote;
}
