import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'gliss_take.dart';
import 'position_colors.dart';
import 'slide_calibration.dart';
import 'trombone_chart.dart';

/// Guided slide calibration: instructions, three slow glissandos from 1st
/// to 7th (2nd, 3rd and 4th partials), then a summary.
///
/// Pops with the new [SlideCalibration] when finished, or null if
/// abandoned, so the old calibration stays until a new one is complete.
class CalibrationScreen extends StatefulWidget {
  /// ToF readings with the pitch heard at the time.
  final Stream<CalFrame> frames;

  /// Told which partial is being asked for (null when none): mock mode
  /// plays it.
  final ValueChanged<int?>? onListeningFor;

  const CalibrationScreen({
    super.key,
    required this.frames,
    this.onListeningFor,
  });

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

const _ground = Color(0xFF121316);
const _card = Color(0xFF1B1D21);
const _chip = Color(0xFF23262C);
const _text = Color(0xFFECEDEF);
const _muted = Color(0xFFA3A7AE);
const _body = Color(0xFFB9BCC2);
const _accent = Color(0xFF7FD6E3);
const _onAccent = Color(0xFF0B2B31);
const _good = Color(0xFF8FE3A0);
const _warn = Color(0xFFFFB869);

/// Start and end note of each gliss, 1st → 7th.
String _glissNotes(int partial) {
  final top = TromboneChart.midiAt(partial, 1);
  return '${_pretty(TromboneChart.noteName(top))} → '
      '${_pretty(TromboneChart.noteName(top - 6))}';
}

String _startNote(int partial) =>
    _pretty(TromboneChart.noteName(TromboneChart.midiAt(partial, 1)));

String _pretty(String name) => name.replaceFirst('b', '♭');

String _ordinal(int n) => switch (n) {
  2 => '2nd',
  3 => '3rd',
  _ => '${n}th',
};

class _CalibrationScreenState extends State<CalibrationScreen> {
  static const _partials = SlideCalibration.glissPartials;

  /// 0 = instructions, 1–3 = gliss, 4 = done.
  int _step = 0;
  GlissTake? _take;
  SlideCalibration _staged = SlideCalibration();
  StreamSubscription<CalFrame>? _sub;
  double? _freq;

  @override
  void initState() {
    super.initState();
    _sub = widget.frames.listen(_onFrame);
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.onListeningFor?.call(null);
    super.dispose();
  }

  void _onFrame(CalFrame f) {
    final take = _take;
    if (take == null || !mounted) return;
    take.feed(f);
    if (take.phase == GlissPhase.done) {
      _staged.addGliss(take.partial, take.samples, take.closedMm!);
      _goTo(_step + 1);
      return;
    }
    setState(() => _freq = f.freq);
  }

  void _goTo(int step) {
    setState(() {
      if (step <= 0) _staged = SlideCalibration();
      _step = step;
      _take = step >= 1 && step <= _partials.length
          ? GlissTake(_partials[step - 1])
          : null;
    });
    widget.onListeningFor?.call(_take?.partial);
  }

  @override
  Widget build(BuildContext context) {
    final Widget page = switch (_step) {
      0 => _Intro(
        onStart: () => _goTo(1),
        onClose: () => Navigator.pop(context),
      ),
      4 => _Done(
        cal: _staged,
        onFinish: () => Navigator.pop(context, _staged),
        onRedo: () => _goTo(0),
      ),
      _ => _GlissPage(
        index: _step,
        take: _take!,
        freq: _freq,
        onBack: () => _goTo(0),
        onRestart: () => setState(() => _take!.restart()),
        onSkip: _staged.calibrated ? () => _goTo(_step + 1) : null,
      ),
    };
    return Scaffold(
      backgroundColor: _ground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: page,
        ),
      ),
    );
  }
}

// ── Shared pieces ───────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _PrimaryButton(this.label, this.onPressed);

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    width: double.infinity,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _accent,
        foregroundColor: _onAccent,
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.7,
      color: _muted,
    ),
  );
}

class _Card extends StatelessWidget {
  final Widget child;
  final Color color;
  final Color? border;
  const _Card({required this.child, this.color = _card, this.border});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(14),
      border: border == null ? null : Border.all(color: border!),
    ),
    child: child,
  );
}

// ── 1 · Instructions ────────────────────────────────────────────────────

class _Intro extends StatelessWidget {
  final VoidCallback onStart, onClose;
  const _Intro({required this.onStart, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close, color: _text),
              tooltip: 'Close',
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
            ),
            const Spacer(),
            const Text(
              'About 1 minute',
              style: TextStyle(fontSize: 13, color: _muted),
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                const Text(
                  'Calibrate your slide',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: _text,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'You\'ll play three slow glissandos, from 1st position all '
                  'the way out to 7th. SlidePod listens and learns where each '
                  'position sits on your horn.',
                  style: TextStyle(fontSize: 16, height: 1.5, color: _body),
                ),
                const SizedBox(height: 24),
                const _Step(
                  1,
                  'Get ready',
                  'Warm up and set your tuning slide first. Hold the horn the '
                      'way you normally play, with the phone nearby.',
                ),
                const _Step(
                  2,
                  'Start in 1st, on the note shown',
                  'Slide fully closed. Play the note mezzo-forte and hold it.',
                ),
                const _Step(
                  3,
                  'Gliss slowly down to 7th',
                  'One breath, one smooth sweep, about 5 seconds. Don\'t '
                      'tongue and don\'t stop at the positions. Let the slide set '
                      'the pitch.',
                ),
                const SizedBox(height: 6),
                _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionLabel('The three glisses'),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          for (final (i, label) in const [
                            (0, 'low'),
                            (1, 'middle'),
                            (2, 'high'),
                          ]) ...[
                            if (i > 0) const SizedBox(width: 8),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                  horizontal: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _chip,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  children: [
                                    FittedBox(
                                      child: Text(
                                        _glissNotes(
                                          SlideCalibration.glissPartials[i],
                                        ),
                                        style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                          color: _text,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      label,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: _muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Higher notes are learned on their own as you play.',
                        style: TextStyle(
                          fontSize: 13,
                          color: _muted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        _PrimaryButton('Start calibration', onStart),
        const SizedBox(height: 10),
        const Center(
          child: Text(
            'Turns the microphone on',
            style: TextStyle(fontSize: 13, color: _muted),
          ),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String title, body;
  const _Step(this.n, this.title, this.body);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: _chip, shape: BoxShape.circle),
          child: Text(
            '$n',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 15,
              color: _text,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: _muted,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ── 2 · Gliss ───────────────────────────────────────────────────────────

class _GlissPage extends StatelessWidget {
  final int index; // 1–3
  final GlissTake take;
  final double? freq;
  final VoidCallback onBack, onRestart;
  final VoidCallback? onSkip;

  const _GlissPage({
    required this.index,
    required this.take,
    required this.freq,
    required this.onBack,
    required this.onRestart,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final n = take.partial;
    final total = SlideCalibration.glissPartials.length;
    final f = freq;
    final hearing = f != null && f > 30
        ? _pretty(
            TromboneChart.noteName(
              (69 + 12 * math.log(f / 440) / math.ln2).round(),
            ),
          )
        : '–';
    // Slide coverage: where the pitch says the slide has got to.
    final reached = take.phase == GlissPhase.waiting ? 0.0 : take.reached;

    final (String status, Color statusColor) = switch (take.phase) {
      GlissPhase.waiting => (
        'Play ${_startNote(n)} in 1st and hold it',
        _muted,
      ),
      GlissPhase.holding => ('Now slide slowly out to 7th', _accent),
      _ when take.tooFast => ('Slow down', _warn),
      _ => ('Good pace, keep going', _good),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(
                Icons.arrow_back_ios_new,
                color: _text,
                size: 20,
              ),
              tooltip: 'Back to instructions',
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
            ),
            const Spacer(),
            for (var i = 1; i <= total; i++)
              Container(
                width: 28,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i <= index ? _accent : const Color(0xFF33363D),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            const Spacer(),
            const SizedBox(width: 40),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                _SectionLabel(
                  'Gliss $index of $total · ${_ordinal(n)} partial',
                ),
                const SizedBox(height: 6),
                Text(
                  _glissNotes(n),
                  style: const TextStyle(
                    fontSize: 44,
                    fontWeight: FontWeight.w700,
                    color: _text,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Start on ${_startNote(n)} in 1st. Hold it, then slide '
                  'slowly out to 7th.',
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    color: _body,
                  ),
                ),
                if (take.issue != null && take.phase == GlissPhase.waiting) ...[
                  const SizedBox(height: 24),
                  _IssueCard(take.issue!),
                ] else ...[
                  const SizedBox(height: 32),
                  Center(
                    child: Column(
                      children: [
                        const Text(
                          'Hearing',
                          style: TextStyle(fontSize: 14, color: _muted),
                        ),
                        Text(
                          hearing,
                          style: const TextStyle(
                            fontSize: 64,
                            fontWeight: FontWeight.w700,
                            color: _text,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                status,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 36),
                _Coverage(reached: reached),
                const SizedBox(height: 24),
                _Card(
                  child: Column(
                    children: [
                      for (var i = 1; i <= total; i++)
                        Padding(
                          padding: EdgeInsets.only(top: i == 1 ? 0 : 10),
                          child: _GlissRow(
                            label: _glissNotes(
                              SlideCalibration.glissPartials[i - 1],
                            ),
                            state: i < index
                                ? _RowState.done
                                : i == index
                                ? _RowState.current
                                : _RowState.next,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: onRestart,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _text,
                    side: const BorderSide(color: Color(0xFF3A3E46)),
                  ),
                  child: const Text(
                    'Restart this one',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ),
            if (onSkip != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: TextButton(
                    onPressed: onSkip,
                    style: TextButton.styleFrom(foregroundColor: _muted),
                    child: const Text('Skip', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _IssueCard extends StatelessWidget {
  final GlissIssue issue;
  const _IssueCard(this.issue);

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (issue) {
      GlissIssue.tooFast => (
        'A bit too fast',
        'Take about 5 seconds from 1st to 7th so the pitch and the slide '
            'sensor stay in step.',
      ),
      GlissIssue.stoppedEarly => (
        'The note stopped before 7th',
        'Keep one continuous tone, no breath or tonguing, and go all the way '
            'to the end of the slide.',
      ),
      GlissIssue.jumped => (
        'It jumped to a different note',
        'Stay on the note shown and let the slide bend it down.',
      ),
    };
    return _Card(
      color: const Color(0xFF2A1F14),
      border: const Color(0xFF5A3B1C),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule, color: _warn, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFFD2A0),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: const TextStyle(
              fontSize: 15,
              height: 1.5,
              color: Color(0xFFE8D3BC),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Play the start note again to retry.',
            style: TextStyle(fontSize: 14, color: Color(0xFFE8D3BC)),
          ),
        ],
      ),
    );
  }
}

class _Coverage extends StatelessWidget {
  final double reached; // semitones
  const _Coverage({required this.reached});

  @override
  Widget build(BuildContext context) {
    final frac = (reached / SlideCalibration.maxSemitones).clamp(0.0, 1.0);
    final upTo = reached <= 0 ? 0 : (1 + (reached + 0.25).floor()).clamp(1, 7);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Slide covered',
              style: TextStyle(fontSize: 13, color: _muted),
            ),
            const Spacer(),
            Text(
              upTo == 0
                  ? '–'
                  : upTo == 1
                  ? '1st'
                  : '1st – ${_posName(upTo)}',
              style: const TextStyle(
                fontSize: 13,
                color: _text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: LinearProgressIndicator(
            value: frac,
            minHeight: 18,
            color: _accent,
            backgroundColor: _chip,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var p = 1; p <= 7; p++)
              Expanded(
                child: Column(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p <= upTo ? PositionColors.screen[p - 1] : null,
                        border: p <= upTo
                            ? null
                            : Border.all(
                                color: PositionColors.screen[p - 1],
                                width: 2,
                              ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$p',
                      style: TextStyle(
                        fontSize: 12,
                        color: p <= upTo ? _text : _muted,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  static String _posName(int p) => switch (p) {
    1 => '1st',
    2 => '2nd',
    3 => '3rd',
    _ => '${p}th',
  };
}

enum _RowState { done, current, next }

class _GlissRow extends StatelessWidget {
  final String label;
  final _RowState state;
  const _GlissRow({required this.label, required this.state});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: state == _RowState.current ? FontWeight.w600 : null,
            color: state == _RowState.next ? _muted : _text,
          ),
        ),
      ),
      const SizedBox(width: 12),
      const Spacer(),
      switch (state) {
        _RowState.done => const Row(
          children: [
            Icon(Icons.check, color: _good, size: 16),
            SizedBox(width: 6),
            Text('Done', style: TextStyle(fontSize: 14, color: _good)),
          ],
        ),
        _RowState.current => const Text(
          'Listening…',
          style: TextStyle(fontSize: 14, color: _accent),
        ),
        _RowState.next => const Text(
          'Next',
          style: TextStyle(fontSize: 14, color: _muted),
        ),
      },
    ],
  );
}

// ── 3 · Done ────────────────────────────────────────────────────────────

class _Done extends StatelessWidget {
  final SlideCalibration cal;
  final VoidCallback onFinish, onRedo;
  const _Done({
    required this.cal,
    required this.onFinish,
    required this.onRedo,
  });

  @override
  Widget build(BuildContext context) {
    final glissed = cal.glissedPartials;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 56),
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1D3A26),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: _good, size: 32),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Slide calibrated',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: _text,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'All seven positions are mapped on your horn. It\'s saved, '
                  'so you won\'t need to do this again unless you change horns '
                  'or move the pod.',
                  style: TextStyle(fontSize: 16, height: 1.5, color: _body),
                ),
                const SizedBox(height: 28),
                _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionLabel('Positions'),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          for (var p = 1; p <= 7; p++) ...[
                            if (p > 1) const SizedBox(width: 6),
                            Expanded(
                              child: Container(
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: PositionColors.screen[p - 1],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '$p',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    color: Color(0xFF14151A),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'From ${glissed.length} '
                        '${glissed.length == 1 ? 'gliss' : 'glisses'}: '
                        '${glissed.map(_startNote).join(', ')}',
                        style: const TextStyle(fontSize: 13, color: _muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionLabel('Higher partials'),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          for (
                            var n = SlideCalibration.firstUpper;
                            n <= SlideCalibration.maxPartial;
                            n++
                          ) ...[
                            if (n > SlideCalibration.firstUpper)
                              const SizedBox(width: 8),
                            Expanded(
                              child: Container(
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: const Color(0xFF4A4E57),
                                  ),
                                ),
                                child: Text(
                                  _startNote(n),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: _body,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Tuning for these starts from a typical horn and is '
                        'learned as you play. Each one fills in after a few '
                        'long, steady notes in the upper register.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: _body,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        _PrimaryButton('Start playing', onFinish),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: TextButton(
            onPressed: onRedo,
            style: TextButton.styleFrom(foregroundColor: _text),
            child: const Text(
              'Redo calibration',
              style: TextStyle(fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }
}
