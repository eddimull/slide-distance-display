import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'flash_card_game.dart';
import 'gliss_take.dart';
import 'high_scores.dart';
import 'high_scores_screen.dart';
import 'slide_calibration.dart';
import 'take_style.dart';

/// Position Flash: a number comes up, put the slide there, as fast as you
/// can, and keep a combo going. Ten cards a round; the score goes on the
/// high-score table.
class FlashCardScreen extends StatefulWidget {
  static const gameId = 'position_flash';
  static const title = 'Position Flash';

  /// ToF readings (the pitch is ignored: no playing needed).
  final Stream<CalFrame> frames;
  final SlideCalibration cal;
  final HighScores scores;
  final FlashCardRules rules;

  /// For tests: the round's random cards, and the clock (ms).
  final math.Random? rng;
  final int Function()? clock;

  const FlashCardScreen({
    super.key,
    required this.frames,
    required this.cal,
    required this.scores,
    this.rules = const FlashCardRules(),
    this.rng,
    this.clock,
  });

  @override
  State<FlashCardScreen> createState() => _FlashCardScreenState();
}

String seconds(num ms) => '${(ms / 1000).toStringAsFixed(2)} s';

String ordinalPos(int p) => switch (p) {
      1 => '1st',
      2 => '2nd',
      3 => '3rd',
      _ => '${p}th',
    };

/// Multiplier colours, ×1 to ×4: (background, text).
const _multColors = [
  (TakeStyle.chip, TakeStyle.body),
  (Color(0xFF1E2A3A), Color(0xFF90CAF9)),
  (Color(0xFF3A2E1A), Color(0xFFFFCC80)),
  (Color(0xFF1E3A24), Color(0xFF8FD694)),
];

(Color, Color) multColor(int m) => _multColors[(m - 1).clamp(0, 3)];

class MultBadge extends StatelessWidget {
  final int mult;
  final double height;
  const MultBadge(this.mult, {super.key, this.height = 28});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = multColor(mult);
    return Container(
      height: height,
      constraints: BoxConstraints(minWidth: height * 1.4),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(height / 2)),
      child: Text('×$mult',
          style: TakeStyle.mono.copyWith(
              fontSize: height * 0.5, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

class _FlashCardScreenState extends State<FlashCardScreen>
    with SingleTickerProviderStateMixin {
  late final FlashCardRound _round =
      FlashCardRound(rules: widget.rules, rng: widget.rng);
  late final Ticker _ticker;
  final _clock = Stopwatch()..start();
  StreamSubscription<CalFrame>? _sub;
  double? _semis;
  bool _seen = false; // any reading yet
  int? _rank; // place on the table after a round
  int? _bestBefore;
  bool _submitted = false;

  int get _now => widget.clock?.call() ?? _clock.elapsedMilliseconds;
  FlashCardRules get _r => widget.rules;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _tick());
    _sub = widget.frames.listen((f) {
      _semis = f.mm == null ? null : widget.cal.semitonesFromMm(f.mm!);
      _seen = _seen || f.mm != null;
      _tick();
    });
  }

  void _tick() {
    final was = _round.phase;
    _round.update(_now, _semis);
    if (_round.phase == FlashPhase.done && was != FlashPhase.done) {
      _ticker.stop();
      _submit();
    }
    if (mounted) setState(() {});
  }

  void _start() {
    _rank = null;
    _submitted = false;
    _bestBefore = widget.scores.best(FlashCardScreen.gameId)?.score;
    _round.start(_now);
    if (!_ticker.isActive) _ticker.start();
    setState(() {});
  }

  Future<void> _submit() async {
    if (_submitted) return;
    _submitted = true;
    final avg = _round.avgMs;
    final rank = await widget.scores.submit(
      FlashCardScreen.gameId,
      ScoreEntry(
        score: _round.score,
        at: DateTime.now(),
        detail: '${_round.hits}/${_r.cards} · combo ${_round.bestCombo}'
            '${avg == null ? '' : ' · avg ${seconds(avg)}'}',
      ),
    );
    if (mounted) setState(() => _rank = rank);
  }

  void _openScores() => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HighScoresScreen(
          scores: widget.scores,
          gameId: FlashCardScreen.gameId,
          title: FlashCardScreen.title,
          subtitle: 'Position Flash · Level 1',
        ),
      ));

  @override
  void dispose() {
    _ticker.dispose();
    _sub?.cancel();
    super.dispose();
  }

  bool get _playing =>
      _round.phase == FlashPhase.card || _round.phase == FlashPhase.feedback;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        titleSpacing: 0,
        leading: _playing || _round.phase == FlashPhase.countdown
            ? IconButton(
                tooltip: 'Quit round',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: Text(
            _playing
                ? 'Card ${_round.results.length + (_round.phase == FlashPhase.card ? 1 : 0)} of ${_r.cards}'
                : FlashCardScreen.title,
            style: TextStyle(
                fontSize: _playing ? 13 : 17,
                fontWeight: _playing ? FontWeight.w400 : FontWeight.w600,
                color: _playing ? TakeStyle.muted : TakeStyle.text)),
        actions: [
          if (_playing) ...[
            _ComboPips(_round.combo, _round.multiplier, _r.comboStep, _r.maxMultiplier),
            const SizedBox(width: 8),
            Semantics(
                label: 'Multiplier ×${_round.multiplier}, combo ${_round.combo}',
                child: ExcludeSemantics(child: MultBadge(_round.multiplier))),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 64),
              child: Text('${_round.score}',
                  textAlign: TextAlign.right,
                  style: TakeStyle.mono.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: TakeStyle.text)),
            ),
            const SizedBox(width: 16),
          ],
        ],
      ),
      body: SafeArea(
        child: switch (_round.phase) {
          FlashPhase.idle => _intro(),
          FlashPhase.countdown => _countdown(),
          FlashPhase.card || FlashPhase.feedback => _card(),
          FlashPhase.done => _results(),
        },
      ),
    );
  }

  // ── Intro ──

  Widget _step(Widget icon, String bold, String rest) => Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
            color: TakeStyle.card, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            SizedBox(width: 48, height: 48, child: Center(child: icon)),
            const SizedBox(width: 14),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: bold,
                      style: const TextStyle(
                          color: TakeStyle.text, fontWeight: FontWeight.w600)),
                  TextSpan(text: ' $rest'),
                ]),
                style: const TextStyle(
                    fontSize: 14, height: 1.4, color: TakeStyle.body),
              ),
            ),
          ],
        ),
      );

  Widget _intro() {
    final best = widget.scores.best(FlashCardScreen.gameId);
    const label = TakeStyle.sectionLabel;
    Widget figure(String v, String l, Color c) => Expanded(
          child: Column(children: [
            Text(v,
                style: TakeStyle.mono.copyWith(
                    fontSize: 18, fontWeight: FontWeight.w600, color: c)),
            const SizedBox(height: 2),
            Text(l,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: TakeStyle.muted)),
          ]),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('LEVEL 1 · GETTING STARTED', style: label),
              SizedBox(height: 4),
              Text('Get to the position, fast',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: TakeStyle.text)),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _step(
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: TakeStyle.chip, borderRadius: BorderRadius.circular(12)),
              child: const Text('5',
                  style: TextStyle(
                      fontSize: 26, fontWeight: FontWeight.w300, color: TakeStyle.text)),
            ),
            'A number comes up.',
            'It\'s the position to go to.'),
        const SizedBox(height: 8),
        _step(
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                  value: 0.7,
                  strokeWidth: 4,
                  color: TakeStyle.accent,
                  backgroundColor: TakeStyle.line),
            ),
            'Move the slide there and hold it',
            'until the ring fills. Swinging past doesn\'t count.'),
        const SizedBox(height: 8),
        _step(
            Container(
              width: 48,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: const Color(0xFF1E3A24),
                  borderRadius: BorderRadius.circular(12)),
              child: Text('+1240',
                  style: TakeStyle.mono.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF8FD694))),
            ),
            'The faster you arrive, the more it scores.',
            'No need to play a note.'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: TakeStyle.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('SCORING', style: label),
              const SizedBox(height: 8),
              Row(children: [
                figure('${_r.maxPoints}', 'Most per card', const Color(0xFF8FD694)),
                figure('${_r.parPoints}', 'On par', TakeStyle.text),
                figure('0', 'Not there in ${_r.timeoutMs ~/ 1000} s',
                    const Color(0xFFEF9A9A)),
              ]),
              const SizedBox(height: 10),
              Text(
                  'Par is longer for bigger moves, so a 1st → 7th card is as '
                  'fair as 3rd → 4th. ${_r.cards} cards a round.',
                  style: const TextStyle(
                      fontSize: 12, height: 1.45, color: TakeStyle.muted)),
              const Divider(height: 24, color: TakeStyle.line),
              const Text('COMBO', style: label),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var m = 1; m <= _r.maxMultiplier; m++) ...[
                    MultBadge(m),
                    if (m < _r.maxMultiplier)
                      const Icon(Icons.arrow_forward,
                          size: 14, color: TakeStyle.muted),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                  'Every ${_r.comboStep} cards in a row on par or faster raises '
                  'the multiplier. Slower than par, or a miss, and it starts '
                  'again at ×1.',
                  style: const TextStyle(
                      fontSize: 12, height: 1.45, color: TakeStyle.muted)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Text('High score',
                style: TextStyle(fontSize: 13, color: TakeStyle.muted)),
            const Spacer(),
            Text(best == null ? '–' : '${best.score}',
                style: TakeStyle.mono.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: TakeStyle.text)),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            backgroundColor: TakeStyle.accent,
            foregroundColor: TakeStyle.onAccent,
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          onPressed: _seen ? _start : null,
          child: Text(_seen ? 'Start' : 'Waiting for the slide pod…'),
        ),
      ],
    );
  }

  // ── Countdown and cards ──

  Widget _countdown() {
    final left = (_round.remainingMs(_now) / 1000).ceil();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Get ready',
              style: TextStyle(fontSize: 18, color: TakeStyle.muted)),
          Text('${math.max(1, left)}',
              style: const TextStyle(
                  fontSize: 120, fontWeight: FontWeight.w300, color: TakeStyle.text)),
        ],
      ),
    );
  }

  Widget _card() {
    final target = _round.target!;
    final feedback = _round.phase == FlashPhase.feedback;
    final last = feedback ? _round.results.last : null;
    final at = _semis == null ? null : (1 + _semis!.round()).clamp(1, 7);
    String detail = '';
    if (last != null) {
      final parts = [
        if (last.hit && last.multiplier > 1) '${last.base} × ${last.multiplier}',
        if (last.brokeCombo) 'combo lost',
      ];
      detail = parts.join(' · ');
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: feedback ? 0 : _round.remainingMs(_now) / _r.timeoutMs,
              minHeight: 4,
              backgroundColor: TakeStyle.line,
              color: TakeStyle.muted,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: SizedBox(
              width: 240,
              height: 240,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CircularProgressIndicator(
                      value: feedback ? 1 : _round.holdProgress(_now),
                      strokeWidth: 8,
                      strokeCap: StrokeCap.round,
                      backgroundColor: TakeStyle.card,
                      color: feedback
                          ? (last!.hit ? TakeStyle.good : TakeStyle.bad)
                          : TakeStyle.accent,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$target',
                          semanticsLabel: 'Position $target',
                          style: const TextStyle(
                              fontSize: 140,
                              fontWeight: FontWeight.w300,
                              height: 1,
                              color: TakeStyle.text)),
                      SizedBox(
                        height: 24,
                        child: last == null
                            ? null
                            : Text(
                                last.hit
                                    ? '${seconds(last.ms!)} · +${last.points}'
                                    : 'Missed',
                                style: TakeStyle.mono.copyWith(
                                    fontSize: 18,
                                    color: last.hit
                                        ? const Color(0xFF8FD694)
                                        : const Color(0xFFEF9A9A))),
                      ),
                      SizedBox(
                        height: 16,
                        child: Text(detail,
                            style: const TextStyle(
                                fontSize: 12, color: TakeStyle.muted)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        // Where the slide is: the seven positions, the nearest lit.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          child: Row(
            children: [
              for (var p = 1; p <= 7; p++)
                Expanded(
                  child: Container(
                    height: 40,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: at == p ? TakeStyle.chip : TakeStyle.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: at == p ? TakeStyle.body : Colors.transparent),
                    ),
                    child: Text('$p',
                        style: TakeStyle.mono.copyWith(
                            fontSize: 14,
                            color: at == p ? TakeStyle.text : TakeStyle.muted)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Results ──

  Widget _results() {
    final avg = _round.avgMs;
    final byPos = _round.avgMsByPosition();
    final slowest = byPos.isEmpty
        ? null
        : byPos.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final newBest = _rank == 1;
    final beat = _bestBefore == null ? null : _round.score - _bestBefore!;
    const label = TakeStyle.sectionLabel;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Center(
          child: newBest
              ? Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                      color: const Color(0xFF1E3A24),
                      borderRadius: BorderRadius.circular(15)),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.emoji_events_outlined,
                          size: 16, color: Color(0xFF8FD694)),
                      SizedBox(width: 6),
                      Text('New high score',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF8FD694))),
                    ],
                  ),
                )
              : Text(
                  _rank != null ? 'Number $_rank on your table' : 'Round over',
                  style: const TextStyle(fontSize: 14, color: TakeStyle.muted)),
        ),
        const SizedBox(height: 6),
        Text('${_round.score}',
            textAlign: TextAlign.center,
            style: TakeStyle.mono.copyWith(
                fontSize: 72, fontWeight: FontWeight.w500, color: TakeStyle.text)),
        if (newBest && beat != null && beat > 0)
          Text('$beat more than your last best',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: TakeStyle.muted)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
                child: StatTile(
                    value: '${_round.hits}', unit: '/${_r.cards}', label: 'Found')),
            const SizedBox(width: 8),
            Expanded(
                child: StatTile(
                    value: avg == null ? '–' : (avg / 1000).toStringAsFixed(2),
                    unit: avg == null ? null : 's',
                    label: 'Average')),
            const SizedBox(width: 8),
            Expanded(
                child: StatTile(
                    value: '${_round.bestCombo}',
                    unit: ' ×${_r.multiplier(_round.bestCombo)}',
                    label: 'Best combo',
                    color: multColor(_r.multiplier(_round.bestCombo)).$2)),
          ],
        ),
        const SizedBox(height: 18),
        const Text('EACH CARD', style: label),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 5,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 1.05,
          children: [
            for (final c in _round.results)
              Container(
                decoration: BoxDecoration(
                  color: c.hit ? TakeStyle.card : const Color(0xFF2A1A1A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${c.target}',
                        style: TextStyle(
                            fontSize: 20,
                            color: c.hit ? TakeStyle.body : const Color(0xFFEF9A9A))),
                    Text(c.hit ? seconds(c.ms!) : 'missed',
                        style: TakeStyle.mono.copyWith(
                            fontSize: 10,
                            color: c.hit ? TakeStyle.body : const Color(0xFFEF9A9A))),
                    if (c.hit)
                      Text('×${c.multiplier}',
                          style: TakeStyle.mono.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: c.multiplier == 1
                                  ? TakeStyle.muted
                                  : multColor(c.multiplier).$2)),
                  ],
                ),
              ),
          ],
        ),
        if (byPos.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text('TIME TO FIND EACH POSITION', style: label),
          const SizedBox(height: 8),
          for (var p = 1; p <= 7; p++)
            if (byPos[p] case final ms?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    PositionBadge(p),
                    const SizedBox(width: 10),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) => Container(
                          height: 10,
                          decoration: BoxDecoration(
                              color: TakeStyle.card,
                              borderRadius: BorderRadius.circular(5)),
                          alignment: Alignment.centerLeft,
                          child: Container(
                            height: 10,
                            width: box.maxWidth * (ms / 1500).clamp(0.03, 1.0),
                            decoration: BoxDecoration(
                              color: p == slowest?.key && byPos.length > 1
                                  ? TakeStyle.warn
                                  : TakeStyle.body,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 56,
                      child: Text(seconds(ms),
                          textAlign: TextAlign.right,
                          style: TakeStyle.mono
                              .copyWith(fontSize: 13, color: TakeStyle.body)),
                    ),
                  ],
                ),
              ),
          if (slowest != null && byPos.length > 1) ...[
            const SizedBox(height: 8),
            Text(
                '${ordinalPos(slowest.key)} took you longest: worth some extra practice.',
                style: const TextStyle(fontSize: 13, color: TakeStyle.muted)),
          ],
        ],
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              flex: 5,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  foregroundColor: TakeStyle.text,
                  side: const BorderSide(color: TakeStyle.line),
                ),
                onPressed: _openScores,
                child: const Text('High scores'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 7,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  backgroundColor: TakeStyle.accent,
                  foregroundColor: TakeStyle.onAccent,
                  textStyle:
                      const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: _start,
                child: const Text('Play again'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Dots filling toward the next multiplier; all lit at the top.
class _ComboPips extends StatelessWidget {
  final int combo, mult, step, max;
  const _ComboPips(this.combo, this.mult, this.step, this.max);

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < step; i++)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(left: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: mult >= max
                      ? const Color(0xFF8FD694)
                      : i < combo % step
                          ? TakeStyle.text
                          : TakeStyle.line,
                ),
              ),
          ],
        ),
      );
}
