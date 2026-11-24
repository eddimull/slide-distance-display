import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'note_diagnosis.dart' show ordinal;
import 'take_style.dart' show prettyNote;
import 'trombone_chart.dart';
import 'ui/cents_meter.dart';
import 'ui/seventh.dart';

/// What the Live tab shows, from the pod and the pitch.
class LiveReading {
  /// Slide position 0 (1st) to 1 (7th).
  final double position;

  /// Smoothed distance; null while the ToF has no echo.
  final int? mm;

  /// The note heard and how far off it is; null when nothing clear.
  final ChartNote? note;
  final double? cents;

  /// Pitch vs what the horn gives where the slide is (+ = sharper).
  final double? lipCents;
  final double? freq;

  /// 'piezo' or 'mic'.
  final String? freqSource;

  /// Slide speed now, positions per second.
  final double speed;

  const LiveReading({
    required this.position,
    this.mm,
    this.note,
    this.cents,
    this.lipCents,
    this.freq,
    this.freqSource,
    this.speed = 0,
  });

  /// 1–7.
  int get slide => (1 + (position * 6).round()).clamp(1, 7);

  /// 1.00–7.00.
  double get exact => 1 + position * 6;
}

/// The Live tab's body: the position, the rail, what you're playing and
/// how in tune; Detail adds the partials, the last 4 seconds and
/// calibration. See the Live board of the app design.
class LiveView extends StatelessWidget {
  final bool connected;

  /// Shown when not connected: "Not connected", "No SlidePod found", …
  final String status;
  final VoidCallback? onConnect;
  final LiveReading reading;
  final bool detail;

  final bool micActive;
  final bool isMock;
  final VoidCallback onMicToggle;

  /// Opens Position Flash; null hides the card (Simple only).
  final VoidCallback? onPractice;
  final VoidCallback onHidePractice;

  final bool calibrated;
  final int upperLearned;
  final VoidCallback onCalibrate;

  /// Positions (0–1) and pitch positions (0–1, null where silent), oldest
  /// first, at ~50 Hz.
  final List<double> positionHistory;
  final List<double?> pitchHistory;

  const LiveView({
    super.key,
    required this.connected,
    required this.status,
    required this.onConnect,
    required this.reading,
    required this.detail,
    required this.micActive,
    required this.isMock,
    required this.onMicToggle,
    required this.onPractice,
    required this.onHidePractice,
    required this.calibrated,
    required this.upperLearned,
    required this.onCalibrate,
    required this.positionHistory,
    required this.pitchHistory,
  });

  @override
  Widget build(BuildContext context) {
    if (!connected) return _NotConnected(status: status, onConnect: onConnect);
    final r = reading;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Seventh.gutter, 14, Seventh.gutter, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PositionBlock(r),
                const SizedBox(height: 14),
                _Rail(r.slide),
                const SizedBox(height: 16),
                _PlayingCard(r, detail: detail),
                const SizedBox(height: 14),
                if (!detail && onPractice != null)
                  _PracticeCard(onOpen: onPractice!, onHide: onHidePractice),
                if (detail) ...[
                  _Partials(slide: r.slide, active: r.note),
                  const SizedBox(height: 12),
                  _TraceCard(
                      positions: positionHistory,
                      pitches: pitchHistory,
                      speed: r.speed),
                  const SizedBox(height: 10),
                  _CalibrationLine(
                      calibrated: calibrated,
                      upperLearned: upperLearned,
                      onCalibrate: onCalibrate),
                ],
              ],
            ),
          ),
        ),
        _MicRow(
          active: micActive,
          isMock: isMock,
          hearing: r.note != null,
          onToggle: onMicToggle,
        ),
      ],
    );
  }
}

class _NotConnected extends StatelessWidget {
  final String status;
  final VoidCallback? onConnect;
  const _NotConnected({required this.status, required this.onConnect});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                    color: Seventh.card, borderRadius: BorderRadius.circular(20)),
                child: const Icon(Icons.bluetooth, color: Seventh.muted, size: 30),
              ),
              const SizedBox(height: 18),
              const Text('Connect your SlidePod', style: Seventh.screenTitle),
              const SizedBox(height: 6),
              Text(status, textAlign: TextAlign.center, style: Seventh.small),
              const SizedBox(height: 4),
              const Text(
                'Switch it on and keep it near the phone.',
                textAlign: TextAlign.center,
                style: Seventh.small,
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: 200,
                child: FilledButton(onPressed: onConnect, child: const Text('Connect')),
              ),
            ],
          ),
        ),
      );
}

class _PositionBlock extends StatelessWidget {
  final LiveReading r;
  const _PositionBlock(this.r);

  @override
  Widget build(BuildContext context) => Semantics(
        label: '${ordinal(r.slide)} position',
        excludeSemantics: true,
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('${r.slide}',
                    style: Seventh.mono.copyWith(
                        fontSize: 120,
                        height: 0.9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -4,
                        color: Seventh.position(r.slide))),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('POSITION', style: Seventh.label),
                  Text(ordinal(r.slide),
                      style: Seventh.screenTitle.copyWith(fontSize: 26)),
                  Text(
                    [
                      r.exact.toStringAsFixed(2),
                      r.mm == null ? 'no echo' : '${r.mm} mm',
                    ].join(' · '),
                    style: Seventh.mono.copyWith(fontSize: 13, color: Seventh.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// The seven positions, the current one lit.
class _Rail extends StatelessWidget {
  final int slide;
  const _Rail(this.slide);

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Row(
          children: [
            for (var p = 1; p <= 7; p++) ...[
              if (p > 1) const SizedBox(width: 4),
              Expanded(
                child: Column(
                  children: [
                    SizedBox(
                      height: 14,
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          height: p == slide ? 14 : 8,
                          decoration: BoxDecoration(
                            color: Seventh.position(p)
                                .withValues(alpha: p == slide ? 1 : 0.28),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text('$p',
                        style: Seventh.mono.copyWith(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: p == slide ? Seventh.text : Seventh.muted)),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
}

class _PlayingCard extends StatelessWidget {
  final LiveReading r;
  final bool detail;
  const _PlayingCard(this.r, {required this.detail});

  @override
  Widget build(BuildContext context) {
    final note = r.note;
    final c = r.cents;
    final hearing = note != null && c != null;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Fixed height whether or not a note sounds, so nothing jumps.
          SizedBox(
            height: 74,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('PLAYING', style: Seventh.label),
                      Text(
                        hearing ? prettyNote(note.name) : '–',
                        style: Seventh.screenTitle.copyWith(
                            fontSize: 40,
                            height: 1.1,
                            color: hearing ? Seventh.text : Seventh.faint),
                      ),
                    ],
                  ),
                ),
                if (hearing)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _HintTag(c),
                      const SizedBox(height: 4),
                      Text(signedCents(c),
                          style: Seventh.mono.copyWith(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: Seventh.cents(c))),
                    ],
                  )
                else
                  const Text('Play a note', style: Seventh.small),
              ],
            ),
          ),
          const SizedBox(height: 10),
          CentsMeter(cents: hearing ? c : null),
          if (detail) ...[
            const SizedBox(height: 10),
            const Divider(),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    hearing
                        ? [
                            '${r.freq?.toStringAsFixed(1)} Hz',
                            ?r.freqSource,
                            '${ordinal(note.partial)} partial',
                          ].join(' · ')
                        : '–',
                    style: Seventh.mono.copyWith(fontSize: 12, color: Seventh.muted),
                  ),
                ),
                if (hearing && r.lipCents != null)
                  Text('lip ${signedCents(r.lipCents!)}',
                      style: Seventh.mono.copyWith(
                          fontSize: 12,
                          color: r.lipCents!.abs() < 10
                              ? Seventh.muted
                              : Seventh.cents(r.lipCents!))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// What to do about the tuning: flat → slide in, sharp → slide out.
class _HintTag extends StatelessWidget {
  final double cents;
  const _HintTag(this.cents);

  @override
  Widget build(BuildContext context) {
    final a = cents.abs();
    final (IconData icon, String text) = a < 10
        ? (Icons.check, 'In tune')
        : cents < 0
            ? (Icons.arrow_upward, a < 25 ? 'Slide in a little' : 'Slide in')
            : (Icons.arrow_downward, a < 25 ? 'Slide out a little' : 'Slide out');
    final fg = Seventh.cents(cents);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: Seventh.centsBg(cents),
          borderRadius: BorderRadius.circular(Seventh.tagRadius)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
        ],
      ),
    );
  }
}

class _PracticeCard extends StatelessWidget {
  final VoidCallback onOpen, onHide;
  const _PracticeCard({required this.onOpen, required this.onHide});

  @override
  Widget build(BuildContext context) => Material(
        color: Seventh.card,
        borderRadius: BorderRadius.circular(Seventh.cardRadius),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: Seventh.raised,
                            borderRadius: BorderRadius.circular(12)),
                        child: Text('5',
                            style: Seventh.mono.copyWith(
                                fontSize: 22, fontWeight: FontWeight.w600, color: Seventh.text)),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Practise your positions', style: Seventh.heading),
                            SizedBox(height: 2),
                            Text('Position Flash · no playing needed',
                                style: TextStyle(fontSize: 13, color: Seventh.muted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Hide this card',
              onPressed: onHide,
              icon: const Icon(Icons.close, size: 20, color: Seventh.muted),
            ),
            const SizedBox(width: 4),
          ],
        ),
      );
}

/// The notes the horn gives in this position, highest first; the one
/// you're playing lit.
class _Partials extends StatelessWidget {
  final int slide;
  final ChartNote? active;
  const _Partials({required this.slide, required this.active});

  @override
  Widget build(BuildContext context) {
    final notes = TromboneChart.notesAt(slide)
        .where((n) => n.partial >= 2)
        .toList()
        .reversed
        .take(7)
        .toList();
    return Row(
      children: [
        for (var i = 0; i < notes.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(child: _PartialChip(notes[i], active: active?.partial == notes[i].partial)),
        ],
      ],
    );
  }
}

class _PartialChip extends StatelessWidget {
  final ChartNote note;
  final bool active;
  const _PartialChip(this.note, {required this.active});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: active ? Seventh.inTuneBg : Seventh.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: active ? Seventh.inTune : Colors.transparent, width: 1.5),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            children: [
              Text(prettyNote(note.name),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? Seventh.inTune : Seventh.text)),
              Text('×${note.partial}',
                  style: Seventh.mono.copyWith(fontSize: 9, color: Seventh.muted)),
            ],
          ),
        ),
      );
}

/// The last 4 seconds: the slide (solid) and where the pitch puts it
/// (dashed).
class _TraceCard extends StatelessWidget {
  final List<double> positions;
  final List<double?> pitches;
  final double speed;
  const _TraceCard(
      {required this.positions, required this.pitches, required this.speed});

  /// ~4 s at 50 Hz.
  static const _span = 200;

  @override
  Widget build(BuildContext context) {
    final from = math.max(0, positions.length - _span);
    return _Card(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('LAST 4 SECONDS', style: Seventh.label)),
              Text('${speed.toStringAsFixed(1)} pos/s',
                  style: Seventh.mono.copyWith(fontSize: 11, color: Seventh.muted)),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 70,
            child: CustomPaint(
              painter: _TracePainter(
                positions.sublist(from),
                pitches.sublist(math.min(from, pitches.length)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  final List<double> positions;
  final List<double?> pitches;
  _TracePainter(this.positions, this.pitches);

  @override
  void paint(Canvas canvas, Size size) {
    // Faint guides at each position.
    final guide = Paint()
      ..color = Seventh.raised
      ..strokeWidth = 1;
    for (var p = 0; p <= 6; p++) {
      final y = size.height * (p / 6);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guide);
    }
    if (positions.length < 2) return;
    final n = _TraceCard._span;
    double x(int i) => size.width * (i + n - positions.length) / (n - 1);
    double y(double v) => size.height * v.clamp(0.0, 1.0);

    final slide = Path()..moveTo(x(0), y(positions[0]));
    for (var i = 1; i < positions.length; i++) {
      slide.lineTo(x(i), y(positions[i]));
    }
    canvas.drawPath(
        slide,
        Paint()
          ..color = Seventh.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);

    // Pitch as short dashes where there is one.
    final dash = Paint()
      ..color = Seventh.close
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < pitches.length; i += 3) {
      final a = pitches[i - 1], b = pitches[i];
      if (a == null || b == null) continue;
      canvas.drawLine(Offset(x(i - 1), y(a)), Offset(x(i), y(b)), dash);
    }
  }

  @override
  bool shouldRepaint(_TracePainter old) => true;
}

class _CalibrationLine extends StatelessWidget {
  final bool calibrated;
  final int upperLearned;
  final VoidCallback onCalibrate;
  const _CalibrationLine(
      {required this.calibrated, required this.upperLearned, required this.onCalibrate});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              calibrated ? 'Calibrated · upper $upperLearned/4' : 'Not calibrated',
              style: Seventh.small,
            ),
          ),
          TextButton(
            onPressed: onCalibrate,
            child: Text(calibrated ? 'Recalibrate' : 'Calibrate'),
          ),
        ],
      );
}

class _MicRow extends StatelessWidget {
  final bool active, isMock, hearing;
  final VoidCallback onToggle;
  const _MicRow(
      {required this.active,
      required this.isMock,
      required this.hearing,
      required this.onToggle});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Seventh.gutter, 4, Seventh.gutter, 12),
        child: Row(
          children: [
            if (!isMock) ...[
              Material(
                color: Seventh.raised,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: onToggle,
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: Icon(active ? Icons.mic : Icons.mic_off,
                        semanticLabel: active ? 'Microphone on' : 'Microphone off',
                        color: active ? Seventh.accent : Seventh.muted),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                isMock
                    ? 'Mock notes.'
                    : !active
                        ? 'Mic off. Tap it to hear your notes.'
                        : hearing
                            ? 'Listening.'
                            : 'Listening. Play a long note.',
                style: const TextStyle(fontSize: 13, color: Seventh.muted),
              ),
            ),
          ],
        ),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
            color: Seventh.card, borderRadius: BorderRadius.circular(Seventh.cardRadius)),
        child: child,
      );
}
