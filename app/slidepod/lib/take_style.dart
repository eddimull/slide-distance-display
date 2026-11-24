import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'position_colors.dart';
import 'ui/seventh.dart';
import 'take_analysis.dart';
import 'trombone_chart.dart';

/// Colours and formatting shared by the Takes, Recording and Review
/// screens; now the design system's ([Seventh]) under their old names.
class TakeStyle {
  static const ground = Seventh.ground;
  static const card = Seventh.card;
  static const chip = Seventh.raised;
  static const line = Seventh.line;
  static const text = Seventh.text;
  static const body = Seventh.body;
  static const muted = Seventh.muted;
  static const accent = Seventh.accent;
  static const onAccent = Seventh.onAccent;
  static const record = Seventh.record;

  // The design's one set of tuning colours.
  static const good = Seventh.inTune;
  static const warn = Seventh.close;
  static const bad = Seventh.off;

  /// Overshoot and stopped-short markers: told apart by lightness and
  /// shape (▲ / ▼) as well as hue.
  static const over = Color(0xFFFFB74D);
  static const short = Color(0xFF8C9EFF);

  static const mono = Seventh.mono;

  static const sectionLabel = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: muted,
  );

  static Color centsColor(double c) => Seventh.cents(c);

  /// Colour of chart position [p] (1–7).
  static Color position(int p) => PositionColors.screen[(p - 1).clamp(0, 6)];

  /// Colour of the position nearest [semis] of extension.
  static Color positionOfSemis(double semis) =>
      position(1 + semis.round().clamp(0, 6));

  static (String, Color, Color) shiftTag(ShiftResult r) => switch (r) {
        ShiftResult.clean => ('Clean', const Color(0xFF1E3A24), const Color(0xFF8FD694)),
        ShiftResult.overshot => ('Overshot', const Color(0xFF3A2E1A), const Color(0xFFFFCC80)),
        ShiftResult.short => ('Short', const Color(0xFF252A44), const Color(0xFFB0BCFF)),
      };

  static (String, Color, Color) causeTag(NoteAnalysis n) {
    if (n.lateSlide && n.cause != NoteCause.inTune) {
      return ('Late slide', chip, body);
    }
    return switch (n.cause) {
      NoteCause.inTune => ('In tune', const Color(0xFF1E3A24), const Color(0xFF8FD694)),
      NoteCause.slide => ('Slide', const Color(0xFF3A2E1A), const Color(0xFFFFCC80)),
      NoteCause.lip => ('Lip', const Color(0xFF3A2E1A), const Color(0xFFFFCC80)),
    };
  }
}

/// "Eb4" → "E♭4".
String prettyNote(String name) => name.replaceFirst('b', '♭');

String noteName(int midi) => prettyNote(TromboneChart.noteName(midi));

/// "+3¢", "−18¢", "0¢".
String centsLabel(double c) {
  final r = c.round();
  return '${r > 0 ? '+' : r < 0 ? '−' : ''}${r.abs()}¢';
}

/// "+0.20", "−0.25" (positions).
String posDelta(double d) {
  final v = (d * 100).round() / 100;
  return '${v > 0 ? '+' : v < 0 ? '−' : '±'}${v.abs().toStringAsFixed(2)}';
}

/// "0:04.2"
String clockLabel(int ms) {
  final m = math.max(0, ms);
  final min = m ~/ 60000;
  final sec = (m % 60000) / 1000;
  return '$min:${sec.toStringAsFixed(1).padLeft(4, '0')}';
}

/// Nearest equal-tempered note to [freq] and how far off it is.
(int midi, double cents) nearestNote(double freq) {
  final m = 69 + 12 * math.log(freq / 440) / math.ln2;
  final midi = m.round();
  return (midi, 100 * (m - midi));
}

/// A rounded tag ("Clean", "Lip").
class TakeTag extends StatelessWidget {
  final (String, Color, Color) tag;
  const TakeTag(this.tag, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tag.$2,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(tag.$1,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: tag.$3)),
      );
}

/// A position number in its colour.
class PositionBadge extends StatelessWidget {
  final int position;
  final double size;
  const PositionBadge(this.position, {super.key, this.size = 24});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: TakeStyle.position(position),
          shape: BoxShape.circle,
        ),
        child: Text('$position',
            style: TakeStyle.mono.copyWith(
                fontSize: size * 0.52,
                fontWeight: FontWeight.w600,
                color: TakeStyle.onAccent)),
      );
}

/// A small summary tile: a value over a label.
class StatTile extends StatelessWidget {
  final String value;
  final String? unit;
  final String label;
  final Color? color;
  const StatTile(
      {super.key, required this.value, this.unit, required this.label, this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
            color: TakeStyle.card, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: value,
                  style: TakeStyle.mono.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: color ?? TakeStyle.text)),
              if (unit != null)
                TextSpan(
                    text: unit,
                    style: TakeStyle.mono
                        .copyWith(fontSize: 14, color: TakeStyle.muted)),
            ])),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(fontSize: 11, color: TakeStyle.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      );
}
