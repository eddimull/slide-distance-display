import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'clef.dart';
import 'clef_glyphs.dart';

export 'clef.dart';

/// How far a staff reaches, in steps (half spaces) above its bottom line:
/// [top] down to [bottom], counting everything drawn (clef, ledger lines,
/// heads, stems, flats). A level sizes every card's staff to its whole
/// range, so the screen doesn't jump from card to card.
class StaffRange {
  final double top, bottom;
  const StaffRange(this.top, this.bottom);

  /// The extent of [midis] on any of [clefs].
  factory StaffRange.of(Iterable<int> midis, Iterable<Clef> clefs) {
    var top = 8.0, bottom = 0.0; // the staff itself
    for (final c in clefs) {
      final g = glyph(c).bounds; // in spaces, down from the clef's line
      top = math.max(top, c.clefLine - g.top * 2);
      bottom = math.min(bottom, c.clefLine - g.bottom * 2);
      for (final m in midis) {
        final o = c.offset(m);
        final stem = stemEnd(o);
        top = math.max(top, math.max(o + 1.0, stem.toDouble()));
        bottom = math.min(bottom, math.min(o - 1.0, stem.toDouble()));
        if (Clef.isFlat(m)) {
          top = math.max(top, o + 3.8);
          bottom = math.min(bottom, o - 1.1);
        }
      }
    }
    return StaffRange(top, bottom);
  }

  /// The extent that covers all of [ranges].
  factory StaffRange.union(Iterable<StaffRange> ranges) => StaffRange(
        ranges.map((r) => r.top).reduce(math.max),
        ranges.map((r) => r.bottom).reduce(math.min),
      );

  /// Height for this range at [space].
  double height(double space) => (top - bottom) * space / 2 + space * 0.6;

  /// Where a note's stem ends (offset from the bottom line): an octave
  /// (3.5 spaces) from the head, and always at least to the middle line.
  /// Down (from the left) on or above the middle line, else up.
  static int stemEnd(int o) => o >= 4 ? math.min(o - 7, 4) : math.max(o + 7, 4);

  static final _glyphs = <Clef, ClefGlyph>{};

  /// The clef's outline.
  static ClefGlyph glyph(Clef c) => _glyphs[c] ??=
      ClefGlyph(c == Clef.bass ? bassClefPath : cClefPath);
}

/// A clef outline, parsed once, in staff spaces.
class ClefGlyph {
  final List<(String, List<double>)> ops;
  late final Rect bounds = () {
    final xs = [for (final (_, a) in ops) for (var i = 0; i < a.length; i += 2) a[i]];
    final ys = [for (final (_, a) in ops) for (var i = 1; i < a.length; i += 2) a[i]];
    return Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min),
        xs.reduce(math.max), ys.reduce(math.max));
  }();

  ClefGlyph(String d) : ops = _parse(d);

  static List<(String, List<double>)> _parse(String d) {
    final out = <(String, List<double>)>[];
    final toks = d.split(' ').where((t) => t.isNotEmpty).toList();
    var i = 0;
    while (i < toks.length) {
      final cmd = toks[i++];
      final n = switch (cmd) {
        'M' || 'L' => 2,
        'C' => 6,
        'Z' => 0,
        _ => throw FormatException('Unexpected path command', cmd),
      };
      out.add((cmd, [for (var k = 0; k < n; k++) double.parse(toks[i++])]));
    }
    return out;
  }

  /// The outline at [space], its left edge at [x] and its line at [y].
  Path at(double x, double y, double space) {
    final p = Path();
    double px(double u) => x + u * space;
    double py(double v) => y + v * space;
    for (final (cmd, a) in ops) {
      switch (cmd) {
        case 'M':
          p.moveTo(px(a[0]), py(a[1]));
        case 'L':
          p.lineTo(px(a[0]), py(a[1]));
        case 'C':
          p.cubicTo(px(a[0]), py(a[1]), px(a[2]), py(a[3]), px(a[4]), py(a[5]));
        case 'Z':
          p.close();
      }
    }
    return p;
  }
}

/// One note on a staff in [clef], with any ledger lines and a flat. Drawn
/// from paths rather than a music font, which phones don't reliably have;
/// the clefs are engraved outlines ([bassClefPath], [cClefPath]).
class StaffNote extends StatelessWidget {
  final int midi;
  final Clef clef;

  /// Gap between staff lines.
  final double space;
  final Color color;

  /// How tall to draw the staff; null: just enough for this note.
  final StaffRange? range;

  const StaffNote(this.midi,
      {super.key,
      this.clef = Clef.bass,
      this.space = 14,
      this.range,
      this.color = const Color(0xFFE8EAED)});

  StaffRange get _range => range ?? StaffRange.of([midi], [clef]);

  static double width(double space) => space * 13.5;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '${clef.label} note',
        child: CustomPaint(
          size: Size(width(space), _range.height(space)),
          painter: _StaffPainter(midi, clef, space, color, _range),
        ),
      );
}

class _StaffPainter extends CustomPainter {
  final int midi;
  final Clef clef;
  final double s;
  final Color color;
  final StaffRange range;
  _StaffPainter(this.midi, this.clef, this.s, this.color, this.range);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    double yOf(num o) => s * 0.3 + (range.top - o) * s / 2;

    final line = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = math.max(1, s / 10);
    for (var o = 0; o <= 8; o += 2) {
      canvas.drawLine(Offset(s * 0.4, yOf(o)), Offset(w - s * 0.4, yOf(o)), line);
    }

    final ink = Paint()..color = color;
    canvas.drawPath(
        StaffRange.glyph(clef).at(s * 0.55, yOf(clef.clefLine), s), ink);

    // The note.
    final o = clef.offset(midi);
    final y = yOf(o);
    final nx = w * 0.66;
    final ledger = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = math.max(1.2, s / 8);
    for (final l in clef.ledgers(midi)) {
      canvas.drawLine(
          Offset(nx - s * 1.05, yOf(l)), Offset(nx + s * 1.05, yOf(l)), ledger);
    }
    canvas.save();
    canvas.translate(nx, y);
    canvas.rotate(-0.35);
    canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: s * 1.32, height: s * 0.92),
        ink);
    canvas.restore();
    final stem = Paint()
      ..color = color
      ..strokeWidth = math.max(1.4, s / 7);
    final end = yOf(StaffRange.stemEnd(o));
    if (o >= 4) {
      final x = nx - s * 0.6;
      canvas.drawLine(Offset(x, y + s * 0.15), Offset(x, end), stem);
    } else {
      final x = nx + s * 0.6;
      canvas.drawLine(Offset(x, y - s * 0.15), Offset(x, end), stem);
    }

    if (Clef.isFlat(midi)) {
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
      old.midi != midi ||
      old.clef != clef ||
      old.s != s ||
      old.color != color ||
      old.range.top != range.top ||
      old.range.bottom != range.bottom;
}
