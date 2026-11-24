import 'package:flutter/material.dart';

import 'seventh.dart';

/// The one cents meter (Live, games, Review): a −50…+50 ¢ track with the
/// close (±25) and in-tune (±10) bands, and a marker in the tuning colour.
/// [cents] null: no note, no marker.
class CentsMeter extends StatelessWidget {
  final double? cents;
  final bool labels;
  const CentsMeter({super.key, required this.cents, this.labels = true});

  @override
  Widget build(BuildContext context) {
    final c = cents;
    return Semantics(
      label: c == null ? 'No note' : '${signedCents(c)}, ${tuningWord(c)}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 18,
            width: double.infinity,
            child: CustomPaint(painter: _MeterPainter(c)),
          ),
          if (labels) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('−50¢', style: Seventh.mono.copyWith(fontSize: 11, color: Seventh.muted)),
                Text('0', style: Seventh.mono.copyWith(fontSize: 11, color: Seventh.muted)),
                Text('+50¢', style: Seventh.mono.copyWith(fontSize: 11, color: Seventh.muted)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  final double? cents;
  _MeterPainter(this.cents);

  @override
  void paint(Canvas canvas, Size size) {
    const trackH = 10.0;
    final top = (size.height - trackH) / 2;
    final w = size.width;
    double x(double c) => w / 2 + (c.clamp(-50, 50) / 50) * (w / 2);
    final r = const Radius.circular(trackH / 2);
    canvas.drawRRect(RRect.fromLTRBR(0, top, w, top + trackH, r),
        Paint()..color = Seventh.raised);
    canvas.drawRRect(RRect.fromLTRBR(x(-25), top, x(25), top + trackH, r),
        Paint()..color = const Color(0xFF2B2A24));
    canvas.drawRect(Rect.fromLTRB(x(-10), top, x(10), top + trackH),
        Paint()..color = Seventh.inTuneBg);
    final c = cents;
    if (c != null) {
      final m = x(c);
      canvas.drawRRect(
          RRect.fromLTRBR(m - 2, 0, m + 2, size.height, const Radius.circular(2)),
          Paint()..color = Seventh.cents(c));
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.cents != cents;
}

/// "+4¢", "−18¢" (with a real minus).
String signedCents(double c) {
  final n = c.round();
  return n > 0 ? '+$n¢' : n < 0 ? '−${-n}¢' : '0¢';
}

/// "in tune", "close", "off".
String tuningWord(double c) {
  final a = c.abs();
  return a < 10
      ? 'in tune'
      : a < 25
          ? 'close'
          : 'off';
}
