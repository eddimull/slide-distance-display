import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One note on a bass-clef staff, with any ledger lines and a flat. Drawn
/// from paths rather than a music font, which phones don't reliably have.
class BassClefNote extends StatelessWidget {
  final int midi;

  /// Gap between staff lines.
  final double space;
  final Color color;

  const BassClefNote(this.midi,
      {super.key, this.space = 14, this.color = const Color(0xFFE8EAED)});

  // Letter of each semitone, spelled with flats (D♭ sits on D's line).
  static const _letter = [0, 1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 6];
  static const _flat = [false, true, false, true, false, false, true, false, true, false, true, false];

  /// Staff steps (lines and spaces) above C0 for [midi]: C=0, D=1 … B=6.
  static int diatonic(int midi) => (midi ~/ 12 - 1) * 7 + _letter[midi % 12];
  static bool isFlat(int midi) => _flat[midi % 12];

  /// Steps of the bottom (G2) and top (A3) lines.
  static const int bottomLine = 2 * 7 + 4, topLine = 3 * 7 + 5;

  /// Ledger lines the note needs, as steps.
  static List<int> ledgers(int midi) {
    final d = diatonic(midi);
    return [
      for (var l = topLine + 2; l <= d; l += 2) l,
      for (var l = bottomLine - 2; l >= d; l -= 2) l,
    ];
  }

  /// Width and height for the F2–F4 range at [space].
  static Size sizeFor(double space) => Size(space * 13.5, space * 8.6);

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Bass clef note',
        child: CustomPaint(
          size: sizeFor(space),
          painter: _StaffPainter(midi, space, color),
        ),
      );
}

class _StaffPainter extends CustomPainter {
  final int midi;
  final double s;
  final Color color;
  _StaffPainter(this.midi, this.s, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // Room above for F4's two ledger lines, a little below for F2.
    final bottomY = size.height - s * 1.4;
    double yOf(int step) => bottomY - (step - BassClefNote.bottomLine) * s / 2;

    final line = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = math.max(1, s / 10);
    for (var i = 0; i < 5; i++) {
      final y = bottomY - i * s;
      canvas.drawLine(Offset(s * 0.4, y), Offset(w - s * 0.4, y), line);
    }

    // Bass clef: a dot on the F line, a curl, and two dots either side of it.
    final ink = Paint()..color = color;
    final fLine = yOf(BassClefNote.bottomLine + 6); // F3
    final cx = s * 1.6;
    canvas.drawCircle(Offset(cx, fLine), s * 0.4, ink);
    final curl = Path()
      ..moveTo(cx - s * 0.3, fLine)
      ..cubicTo(cx - s * 0.45, fLine - s * 1.0, cx + s * 1.9, fLine - s * 1.45,
          cx + s * 2.15, fLine)
      ..cubicTo(cx + s * 2.4, fLine + s * 1.55, cx + s * 1.1, fLine + s * 2.7,
          cx - s * 0.6, fLine + s * 3.4);
    canvas.drawPath(
        curl,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.28
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(Offset(cx + s * 2.85, fLine - s * 0.5), s * 0.19, ink);
    canvas.drawCircle(Offset(cx + s * 2.85, fLine + s * 0.5), s * 0.19, ink);

    // The note.
    final d = BassClefNote.diatonic(midi);
    final y = yOf(d);
    final nx = w * 0.66;
    for (final l in BassClefNote.ledgers(midi)) {
      canvas.drawLine(Offset(nx - s * 1.05, yOf(l)), Offset(nx + s * 1.05, yOf(l)),
          line..strokeWidth = math.max(1.2, s / 8));
    }
    canvas.save();
    canvas.translate(nx, y);
    canvas.rotate(-0.35);
    canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: s * 1.32, height: s * 0.92),
        ink);
    canvas.restore();
    // Stem: down from the left on or above the middle line, else up.
    final stem = Paint()
      ..color = color
      ..strokeWidth = math.max(1.4, s / 7);
    if (d >= BassClefNote.bottomLine + 4) {
      final x = nx - s * 0.6;
      canvas.drawLine(Offset(x, y + s * 0.15), Offset(x, y + s * 3.4), stem);
    } else {
      final x = nx + s * 0.6;
      canvas.drawLine(Offset(x, y - s * 0.15), Offset(x, y - s * 3.4), stem);
    }

    if (BassClefNote.isFlat(midi)) {
      final fx = nx - s * 1.85;
      final flat = Path()
        ..moveTo(fx, y - s * 1.9)
        ..lineTo(fx, y + s * 0.55)
        ..cubicTo(fx + s * 0.85, y + s * 0.1, fx + s * 0.95, y - s * 0.55,
            fx + s * 0.35, y - s * 0.55)
        ..cubicTo(fx + s * 0.15, y - s * 0.55, fx, y - s * 0.35, fx, y - s * 0.15);
      canvas.drawPath(
          flat,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.4, s / 7)
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
    }
  }

  @override
  bool shouldRepaint(_StaffPainter old) =>
      old.midi != midi || old.s != s || old.color != color;
}
