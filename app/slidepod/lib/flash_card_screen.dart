import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'account.dart';
import 'flash_card_game.dart';
import 'gliss_take.dart';
import 'high_scores.dart';
import 'high_scores_screen.dart';
import 'seventh_api.dart';
import 'slide_calibration.dart';
import 'staff_note.dart';
import 'take_style.dart';
import 'ui/seventh.dart';

/// One flash-card game: what its cards are and how it's explained.
class FlashGameSpec {
  final String id, title;
  final int level;
  final String levelName, headline;

  /// The first how-to-play step: (bold, rest).
  final (String, String) firstStep;

  /// The third step's second half (after "The faster you arrive, the
  /// more it scores.").
  final String thirdStep;

  /// Cards are notes on a staff (else position numbers).
  final bool notes;
  final FlashDeck Function() deck;
  final FlashCardRules rules;

  /// The server's rules version for this game (seventh-server's
  /// config/games.php). Bump it with any change to [rules] or scoring.
  final int rulesVersion;

  const FlashGameSpec({
    required this.id,
    required this.title,
    required this.level,
    required this.levelName,
    required this.headline,
    required this.firstStep,
    this.thirdStep = 'No need to play a note.',
    required this.notes,
    required this.deck,
    this.rules = const FlashCardRules(),
    this.rulesVersion = 1,
  });

  bool get needsPitch => rules.needsPitch;

  String get levelLabel => 'LEVEL $level · ${levelName.toUpperCase()}';
}

PositionDeck _positions() => PositionDeck();
NoteDeck _notes() => NoteDeck();

const positionFlash = FlashGameSpec(
  id: 'position_flash',
  title: 'Position Flash',
  level: 1,
  levelName: 'Getting started',
  headline: 'Get to the position, fast',
  firstStep: ('A number comes up.', 'It\'s the position to go to.'),
  notes: false,
  deck: _positions,
);

const noteFlash = FlashGameSpec(
  id: 'note_flash',
  title: 'Note Flash',
  level: 2,
  levelName: 'Reading notes',
  headline: 'Find the note on the slide',
  firstStep: ('A note comes up, F2 to F4.',
      'Go to a position that plays it: any one counts.'),
  notes: true,
  deck: _notes,
);

const playTheNote = FlashGameSpec(
  id: 'play_the_note',
  title: 'Play the Note',
  level: 3,
  levelName: 'Playing',
  headline: 'Play it, slide and all',
  firstStep: ('A note comes up, F2 to F4.',
      'Play it, with the slide in a position for it.'),
  thirdStep: 'Within ±10¢ earns a bonus on top.',
  notes: true,
  deck: _notes,
  // Allows time to start the note; the note must hold within ±25¢.
  // Version 2: the slide counts within ±0.6 of the position (±0.3 before).
  // Played in tune, a note sits where that horn plays it, which can be
  // ~0.4 from the chart (in-tune E3 and E4 at 2.4 on a test horn, B2 at
  // 6.6): ±0.3 turned away notes played spot on. The next position that
  // plays the same note is 3 or more away, so this can't take a wrong one.
  rules: FlashCardRules(parBaseMs: 1000, pitchGateCents: 25, tolerance: 0.6),
  rulesVersion: 2,
);

/// A flash-card game ([positionFlash], [noteFlash], [playTheNote]): a card comes up, put
/// the slide where it says, as fast as you can, and keep a combo going.
/// Rounds last 30 seconds; the score goes on the game's high-score table.
class FlashCardScreen extends StatefulWidget {
  static const gameId = 'position_flash';
  static const title = 'Position Flash';

  /// ToF readings with the pitch heard (used by the playing levels).
  final Stream<CalFrame> frames;
  final SlideCalibration cal;
  final HighScores scores;

  /// Signed in: rounds also go to the online leaderboards.
  final Account? account;

  /// Overrides the game's own rules (tests).
  final FlashCardRules? rules;

  /// Turns the mic on (playing levels), before a round starts.
  final Future<void> Function()? ensureMic;
  final FlashGameSpec spec;

  /// The compact pod pill, shown during a round (null: none).
  final WidgetBuilder? pod;

  /// For tests: the round's random cards, and the clock (ms).
  final math.Random? rng;
  final int Function()? clock;

  const FlashCardScreen({
    super.key,
    required this.frames,
    required this.cal,
    required this.scores,
    this.account,
    this.rules,
    this.ensureMic,
    this.spec = positionFlash,
    this.pod,
    this.rng,
    this.clock,
  });

  @override
  State<FlashCardScreen> createState() => _FlashCardScreenState();
}

String seconds(num ms) => '${(ms / 1000).toStringAsFixed(2)} s';

/// The round clock: "0:23".
String clockSeconds(int ms) {
  final s = (ms / 1000).ceil();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 1st, 2nd, 3rd, 4th … 11th, 12th, 13th … 21st.
String ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (n % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' };
  return '$n$suffix';
}

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
    // No `alignment`: that makes a Container fill a Wrap's whole width.
    return Container(
      height: height,
      constraints: BoxConstraints(minWidth: height * 1.4),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(height / 2)),
      child: Center(
        widthFactor: 1,
        child: Text('×$mult',
          style: TakeStyle.mono.copyWith(
              fontSize: height * 0.5, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }
}

class _FlashCardScreenState extends State<FlashCardScreen>
    with SingleTickerProviderStateMixin {
  late final FlashCardRound _round =
      FlashCardRound(
          rules: _r, deck: widget.spec.deck(), rng: widget.rng, log: debugPrint);
  double? _freq;
  late final Ticker _ticker;
  final _clock = Stopwatch()..start();
  StreamSubscription<CalFrame>? _sub;
  double? _semis, _mm;
  bool _seen = false; // any reading yet
  int? _rank; // place on the table after a round
  int? _bestBefore;
  bool _submitted = false;

  /// The online leaderboards, after a round: where it placed, or why it
  /// didn't post.
  PostedRound? _posted;
  String? _postError;
  bool _posting = false;

  int get _now => widget.clock?.call() ?? _clock.elapsedMilliseconds;
  FlashCardRules get _r => widget.rules ?? widget.spec.rules;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _tick());
    _sub = widget.frames.listen((f) {
      _mm = f.mm;
      _semis = f.mm == null ? null : widget.cal.semitonesFromMm(f.mm!);
      _freq = f.freq;
      _seen = _seen || f.mm != null;
      _tick();
    });
  }

  void _tick() {
    final was = _round.phase;
    _round.update(_now, _semis, freq: _freq, mm: _mm);
    if (_round.phase == FlashPhase.done && was != FlashPhase.done) {
      _ticker.stop();
      _submit();
    }
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (widget.spec.needsPitch) await widget.ensureMic?.call();
    if (!mounted) return;
    _rank = null;
    _submitted = false;
    _posted = null;
    _postError = null;
    _bestBefore = widget.scores.best(widget.spec.id)?.score;
    _round.start(_now);
    if (!_ticker.isActive) _ticker.start();
    setState(() {});
  }

  Future<void> _submit() async {
    if (_submitted) return;
    _submitted = true;
    final avg = _round.avgMs;
    final rank = await widget.scores.submit(
      widget.spec.id,
      ScoreEntry(
        score: _round.score,
        at: DateTime.now(),
        detail: '${_round.hits} found · combo ${_round.bestCombo}'
            '${avg == null ? '' : ' · avg ${seconds(avg)}'}',
      ),
    );
    if (mounted) setState(() => _rank = rank);
    await _post();
  }

  Future<void> _post() async {
    final a = widget.account;
    // Rules overridden (tests) can't be scored by the server.
    if (a == null || !a.signedIn || widget.rules != null) return;
    setState(() => _posting = true);
    try {
      final p =
          await a.postRound(widget.spec.id, widget.spec.rulesVersion, _round);
      if (mounted) setState(() => _posted = p);
    } on ApiException catch (e) {
      if (mounted) setState(() => _postError = e.message);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  /// "3rd this week · 41st all time", or why the round isn't on the boards.
  String? get _onlineLine {
    if (_posting) return 'Posting to the leaderboards…';
    if (_postError != null) return _postError;
    final p = _posted;
    if (p == null) return null;
    return [
      if (p.week != null) '${ordinal(p.week!.rank)} this week',
      if (p.all != null) '${ordinal(p.all!.rank)} all time',
    ].join(' · ');
  }

  void _openScores() => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HighScoresScreen(
          scores: widget.scores,
          gameId: widget.spec.id,
          title: widget.spec.title,
          subtitle: '${widget.spec.title} · Level ${widget.spec.level}',
          account: widget.account,
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
        title: _playing
            ? Text(clockSeconds(_round.roundRemainingMs(_now)),
                semanticsLabel:
                    '${(_round.roundRemainingMs(_now) / 1000).ceil()} seconds left',
                style: TakeStyle.mono.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: _round.roundRemainingMs(_now) <= 5000
                        ? TakeStyle.warn
                        : TakeStyle.text))
            : Text(widget.spec.title,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: TakeStyle.text)),
        actions: [
          if (_playing) ...[
            // The pod, so a dying battery shows mid-round.
            if (widget.pod != null) ...[
              widget.pod!(context),
              const SizedBox(width: 10),
            ],
            _ComboPips(_round.combo, _round.multiplier, _r.comboStep, _r.maxMultiplier),
            const SizedBox(width: 8),
            Semantics(
                label: 'Multiplier ×${_round.multiplier}, combo ${_round.combo}',
                child: ExcludeSemantics(child: MultBadge(_round.multiplier))),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 64),
              child: Text(thousands(_round.score),
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
    final best = widget.scores.best(widget.spec.id);
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
    // The explanation scrolls; the high score and Start stay in reach.
    return Column(
      children: [
        Expanded(
          child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.spec.levelLabel, style: label),
              const SizedBox(height: 4),
              Text(widget.spec.headline,
                  style: const TextStyle(
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
              child: widget.spec.notes
                  ? const FittedBox(
                      child: Padding(
                        padding: EdgeInsets.all(3),
                        child: BassClefNote(63, space: 6),
                      ),
                    )
                  : const Text('5',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w300,
                          color: TakeStyle.text)),
            ),
            widget.spec.firstStep.$1,
            widget.spec.firstStep.$2),
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
            widget.spec.thirdStep),
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
              if (widget.spec.needsPitch) ...[
                Text(
                    'The note has to hold within ±${_r.pitchGateCents!.round()}¢ '
                    'to count. Within ±${_r.inTuneCents.round()}¢: '
                    '+${_r.inTuneBonus} on top, before the multiplier.',
                    style: const TextStyle(
                        fontSize: 12, height: 1.45, color: TakeStyle.muted)),
                const SizedBox(height: 6),
              ],
              Text(
                  'Par is longer for bigger moves, so a 1st → 7th card is as '
                  'fair as 3rd → 4th. ${_r.roundMs ~/ 1000} seconds a round: '
                  'as many cards as you can.',
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
      ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: TakeStyle.chip))),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
        Row(
          children: [
            const Text('High score',
                style: TextStyle(fontSize: 13, color: TakeStyle.muted)),
            const Spacer(),
            Text(best == null ? '–' : thousands(best.score),
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
          ),
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
    final card = _round.card!;
    final feedback = _round.phase == FlashPhase.feedback;
    final ring = widget.spec.notes ? 270.0 : 240.0;
    final last = feedback ? _round.results.last : null;
    final at = _semis == null ? null : (1 + _semis!.round()).clamp(1, 7);
    // Position Flash: the card is one position, shown in its colour.
    final int? target =
        widget.spec.notes || card.positions.length != 1 ? null : card.positions.first;
    final targetColor = target == null ? TakeStyle.accent : Seventh.position(target);
    String detail = '';
    if (last != null) {
      final parts = [
        if (last.cents != null) centsLabel(last.cents!),
        if (last.inTune) 'in tune +${last.bonus}',
        if (last.hit && last.multiplier > 1) '× ${last.multiplier}',
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
              // The round's clock.
              value: _round.roundRemainingMs(_now) / _r.roundMs,
              minHeight: 4,
              backgroundColor: TakeStyle.line,
              color: TakeStyle.muted,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: SizedBox(
              width: ring,
              height: ring,
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
                          : targetColor,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.spec.notes) ...[
                        BassClefNote(card.midi!, space: 13),
                        Text(prettyNote(card.label),
                            semanticsLabel: 'Note ${card.label}',
                            style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w500,
                                color: TakeStyle.text)),
                      ] else
                        Text(card.label,
                            semanticsLabel: 'Position ${card.label}',
                            style: Seventh.mono.copyWith(
                                fontSize: 140,
                                fontWeight: FontWeight.w600,
                                height: 1,
                                letterSpacing: -4,
                                color: target == null ? TakeStyle.text : targetColor)),
                      SizedBox(
                        height: 24,
                        child: last == null
                            ? null
                            : Text(
                                last.hit
                                    ? '${widget.spec.notes ? '${ordinalPos(last.position!)} · ' : ''}'
                                        '${seconds(last.ms!)} · +${last.points}'
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
        if (widget.spec.needsPitch)
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 40, 16),
            child: PitchMeter(
                cents: feedback ? last!.cents : _round.heardCents,
                gate: _r.pitchGateCents!,
                inTune: _r.inTuneCents),
          )
        else if (widget.spec.notes)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text('Any position that plays it counts.',
                style: TextStyle(fontSize: 13, color: TakeStyle.muted)),
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
                    // The target filled in its colour; each other position
                    // underlined in its own; where the slide is, outlined.
                    decoration: BoxDecoration(
                      color: target == p ? Seventh.position(p) : TakeStyle.card,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: at == p ? TakeStyle.text : Colors.transparent,
                          width: 1.5),
                    ),
                    foregroundDecoration: target == p
                        ? null
                        : BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border(
                                bottom: BorderSide(
                                    color: Seventh.position(p).withValues(alpha: 0.4),
                                    width: 3))),
                    child: Text('$p',
                        style: TakeStyle.mono.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: target == p
                                ? Seventh.ground
                                : at == p
                                    ? TakeStyle.text
                                    : TakeStyle.muted)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Results ──

  /// The notes that took longest, where they were found, and where else
  /// they could have been.
  List<Widget> _slowNotes() {
    final by = _round.avgMsByCard();
    if (by.isEmpty) return const [];
    final slow = by.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final top = slow.take(3).toList();
    /// Positions [label] was found in this round.
    Set<int> used(String label) => {
          for (final r in _round.results)
            if (r.hit && r.card.label == label) r.position!,
        };
    String where(String label) =>
        'found in ${used(label).map(ordinalPos).join(', ')}';

    // "E3 is also in 7th": the other positions of the slow notes.
    final elsewhere = <String>[];
    for (final e in top) {
      final card = _round.results.firstWhere((r) => r.card.label == e.key).card;
      final others = (card.positions.difference(used(e.key)).toList()..sort());
      if (others.isEmpty) continue;
      elsewhere.add(
          '${prettyNote(e.key)} is also in ${others.map(ordinalPos).join(' and ')}');
    }
    return [
      const SizedBox(height: 18),
      const Text('NOTES THAT TOOK LONGEST', style: TakeStyle.sectionLabel),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
            color: TakeStyle.card, borderRadius: BorderRadius.circular(14)),
        child: Column(
          children: [
            for (final (i, e) in top.indexed)
              Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  border: i == 0
                      ? null
                      : const Border(top: BorderSide(color: TakeStyle.chip)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(prettyNote(e.key),
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: TakeStyle.text)),
                    ),
                    Expanded(
                      child: Text(where(e.key),
                          style:
                              const TextStyle(fontSize: 13, color: TakeStyle.body)),
                    ),
                    Text(seconds(e.value),
                        style: TakeStyle.mono.copyWith(
                            fontSize: 13, color: const Color(0xFFFFCC80))),
                  ],
                ),
              ),
          ],
        ),
      ),
      if (elsewhere.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
            '${elsewhere.join('; ')}: any position counts, and the nearer one '
            'scores better.',
            style: const TextStyle(fontSize: 13, height: 1.45, color: TakeStyle.muted)),
      ],
    ];
  }

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
        Text(thousands(_round.score),
            semanticsLabel: '${_round.score}',
            textAlign: TextAlign.center,
            style: TakeStyle.mono.copyWith(
                fontSize: 72,
                fontWeight: FontWeight.w600,
                letterSpacing: -2,
                color: TakeStyle.text)),
        if (newBest && beat != null && beat > 0)
          Text('$beat more than your last best',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: TakeStyle.muted)),
        if (_onlineLine case final line?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(line,
                key: const Key('online'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: _postError != null ? TakeStyle.warn : TakeStyle.accent)),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
                child: StatTile(
                    value: '${_round.hits}',
                    unit: _round.results.length > _round.hits
                        ? '/${_round.results.length}'
                        : null,
                    label: 'Found')),
            const SizedBox(width: 8),
            Expanded(
                child: widget.spec.needsPitch
                    ? StatTile(
                        value:
                            '${_round.results.where((c) => c.inTune).length}',
                        unit: '/${_round.hits}',
                        label: 'In tune (±${_r.inTuneCents.round()}¢)',
                        color: TakeStyle.good)
                    : StatTile(
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
          childAspectRatio: widget.spec.needsPitch
              ? 0.72
              : widget.spec.notes
                  ? 0.85
                  : 1.05,
          children: [
            for (final c in _round.results)
              Container(
                decoration: BoxDecoration(
                  color: c.hit ? TakeStyle.card : Seventh.offBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!widget.spec.notes && c.card.positions.length == 1)
                      _CardChip(c.card.positions.first, hit: c.hit)
                    else
                      Text(prettyNote(c.card.label),
                          style: TextStyle(
                              fontSize: widget.spec.notes ? 15 : 20,
                              fontWeight:
                                  widget.spec.notes ? FontWeight.w500 : FontWeight.w400,
                              color: c.hit ? TakeStyle.body : Seventh.off)),
                    const SizedBox(height: 3),
                    if (widget.spec.notes && c.hit)
                      Text(ordinalPos(c.position!),
                          style: TakeStyle.mono.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: TakeStyle.position(c.position!))),
                    Text(c.hit ? seconds(c.ms!) : 'missed',
                        style: TakeStyle.mono.copyWith(
                            fontSize: 10,
                            color: c.hit ? TakeStyle.body : const Color(0xFFEF9A9A))),
                    if (c.cents != null)
                      Text(centsLabel(c.cents!),
                          style: TakeStyle.mono.copyWith(
                              fontSize: 10, color: TakeStyle.centsColor(c.cents!))),
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
        if (widget.spec.notes) ..._slowNotes(),
        if (byPos.isNotEmpty && !widget.spec.notes) ...[
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
                child: const Text('Scores'),
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
/// A card's position as a numbered chip in its colour; an outline if missed.
class _CardChip extends StatelessWidget {
  final int position;
  final bool hit;
  const _CardChip(this.position, {required this.hit});

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hit ? Seventh.position(position) : null,
          border: hit ? null : Border.all(color: Seventh.off, width: 2),
        ),
        child: Text('$position',
            style: Seventh.mono.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: hit ? Seventh.ground : Seventh.off)),
      );
}

/// 18240 → "18,240".
String thousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '−' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

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

/// How far the note heard is from the card's: a bar from −50 to +50¢ with
/// the counting zone (±[gate]) and the in-tune zone (±[inTune]) marked.
class PitchMeter extends StatelessWidget {
  final double? cents;
  final double gate, inTune;
  const PitchMeter(
      {super.key, required this.cents, required this.gate, required this.inTune});

  @override
  Widget build(BuildContext context) {
    final c = cents;
    final heard = c == null
        ? 'Listening…'
        : c.abs() > gate
            ? 'not this note yet'
            : centsLabel(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text("YOU'RE PLAYING",
                  style: TakeStyle.sectionLabel,
                  overflow: TextOverflow.ellipsis),
            ),
            Text(heard,
                style: TakeStyle.mono.copyWith(
                    fontSize: 14,
                    color: c == null || c.abs() > gate
                        ? TakeStyle.muted
                        : TakeStyle.centsColor(c))),
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          label: c == null ? 'No note heard' : '${c.round()} cents',
          child: CustomPaint(
            size: const Size(double.infinity, 22),
            painter: _MeterPainter(c, gate, inTune),
          ),
        ),
      ],
    );
  }
}

class _MeterPainter extends CustomPainter {
  final double? cents;
  final double gate, inTune;
  _MeterPainter(this.cents, this.gate, this.inTune);

  @override
  void paint(Canvas canvas, Size size) {
    const range = 50.0;
    final w = size.width, mid = size.height / 2;
    double x(double c) => w / 2 + c.clamp(-range, range) / range * w / 2;
    RRect bar(double from, double to) => RRect.fromLTRBR(
        x(from), mid - 4, x(to), mid + 4, const Radius.circular(4));
    canvas.drawRRect(bar(-range, range), Paint()..color = TakeStyle.chip);
    canvas.drawRRect(
        bar(-gate, gate), Paint()..color = TakeStyle.warn.withValues(alpha: 0.25));
    canvas.drawRRect(bar(-inTune, inTune),
        Paint()..color = TakeStyle.good.withValues(alpha: 0.45));
    canvas.drawLine(Offset(w / 2, 0), Offset(w / 2, size.height),
        Paint()..color = const Color(0xFF5F6670));
    final c = cents;
    if (c == null || c.abs() > range) return;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x(c), mid), width: 4, height: size.height),
            const Radius.circular(2)),
        Paint()..color = TakeStyle.centsColor(c));
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.cents != cents || old.gate != gate || old.inTune != inTune;
}
