import 'dart:math' as math;

/// The rules of Position Flash: a position number is shown, you move the
/// slide there, and the faster you get there the more it scores. No
/// playing needed, just the slide.
///
/// Cards reached on par or faster build a combo; every [comboStep] in a
/// row raises the multiplier on each card's points, up to [maxMultiplier].
/// A card slower than par scores at the current multiplier and then resets
/// the combo; a miss scores nothing and resets it.
class FlashCardRules {
  /// Cards in a round.
  final int cards;

  /// Within this many positions of the target counts as there.
  final double tolerance;

  /// The slide has to stay there this long, so swinging through a position
  /// on the way somewhere else doesn't count. The time scored is when it
  /// arrived, not when the hold finished.
  final int holdMs;

  /// No arrival by then: the card is missed and scores nothing.
  final int timeoutMs;

  /// "3, 2, 1" before the first card.
  final int countdownMs;

  /// How long a hit or miss is shown before the next card.
  final int feedbackMs;

  /// Par for a card: time to read it plus time to travel, per position of
  /// distance. Getting there on par scores [parPoints].
  final int parBaseMs, parPerPositionMs;
  final int parPoints, maxPoints;

  final int comboStep, maxMultiplier;

  const FlashCardRules({
    this.cards = 10,
    this.tolerance = 0.3,
    this.holdMs = 300,
    this.timeoutMs = 6000,
    this.countdownMs = 3000,
    this.feedbackMs = 700,
    this.parBaseMs = 600,
    this.parPerPositionMs = 100,
    this.parPoints = 1000,
    this.maxPoints = 1500,
    this.comboStep = 3,
    this.maxMultiplier = 4,
  });

  int parMs(int distance) => parBaseMs + parPerPositionMs * distance;

  /// Points for getting [distance] positions in [ms]: [parPoints] on par,
  /// more for faster (up to [maxPoints]), less for slower.
  /// The multiplier with [combo] cards in a row on par so far.
  int multiplier(int combo) =>
      math.min(maxMultiplier, 1 + combo ~/ comboStep);

  int points(int ms, int distance) => ms <= 0
      ? maxPoints
      : math.min(maxPoints, (parPoints * parMs(distance) / ms).round());
}

enum FlashPhase {
  /// Waiting for [FlashCardRound.start].
  idle,
  countdown,

  /// A card is up.
  card,

  /// Showing how the last card went.
  feedback,
  done,
}

class CardResult {
  /// Target position (1–7) and the position the slide was at when shown.
  final int target, from;

  /// Shown to arrival; null = missed.
  final int? ms;

  /// Points for the speed, the multiplier it scored at, and the two
  /// multiplied.
  final int base, multiplier;
  final int parMs;

  /// The combo after this card, and whether this card ended one.
  final int comboAfter;
  final bool brokeCombo;

  const CardResult({
    required this.target,
    required this.from,
    required this.ms,
    required this.base,
    required this.multiplier,
    required this.parMs,
    required this.comboAfter,
    this.brokeCombo = false,
  });

  int get points => base * multiplier;
  bool get hit => ms != null;
  bool get onPar => ms != null && ms! <= parMs;
  int get distance => (target - from).abs();
}

/// One round. Feed it the time and where the slide is ([update]); it moves
/// through the countdown, the cards, and the result of each.
class FlashCardRound {
  final FlashCardRules rules;
  final math.Random _rng;

  FlashCardRound({this.rules = const FlashCardRules(), math.Random? rng})
      : _rng = rng ?? math.Random();

  FlashPhase phase = FlashPhase.idle;
  final results = <CardResult>[];

  /// The card showing (1–7), and when it was shown.
  int? target;
  int _shownAt = 0, _from = 1;
  int _phaseEnds = 0;

  /// When the slide entered the target zone (null = not in it).
  int? _enteredAt;

  /// Position (1–7) nearest the slide, last seen.
  int? _at;

  /// Cards in a row on par or faster, and the most this round.
  int combo = 0, bestCombo = 0;

  int get multiplier => rules.multiplier(combo);

  int get cardNumber => results.length + (phase == FlashPhase.card ? 1 : 0);

  /// Time left on the countdown / card, for the screen.
  int remainingMs(int now) => math.max(0, _phaseEnds - now);

  /// 0–1 of the way into the current hold (for a progress ring).
  double holdProgress(int now) => _enteredAt == null
      ? 0
      : ((now - _enteredAt!) / rules.holdMs).clamp(0.0, 1.0);

  int get score => results.fold(0, (s, r) => s + r.points);
  int get hits => results.where((r) => r.hit).length;

  /// Mean arrival time of the cards hit; null if none.
  double? get avgMs {
    final hit = results.where((r) => r.hit).toList();
    if (hit.isEmpty) return null;
    return hit.map((r) => r.ms!).reduce((a, b) => a + b) / hit.length;
  }

  /// Mean arrival time per target position, for "which ones are slow".
  Map<int, double> avgMsByPosition() {
    final sums = <int, List<int>>{};
    for (final r in results) {
      if (r.hit) (sums[r.target] ??= []).add(r.ms!);
    }
    return {
      for (final e in sums.entries)
        e.key: e.value.reduce((a, b) => a + b) / e.value.length,
    };
  }

  void start(int now) {
    results.clear();
    combo = 0;
    bestCombo = 0;
    target = null;
    phase = FlashPhase.countdown;
    _phaseEnds = now + rules.countdownMs;
  }

  /// [semis] is the slide's extension (0 = 1st, 6 = 7th), null when the
  /// sensor has no reading (the slide counts as wherever it last was not:
  /// a blind sensor can't confirm a hold).
  void update(int now, double? semis) {
    if (semis != null) _at = (1 + semis.round()).clamp(1, 7);
    switch (phase) {
      case FlashPhase.idle:
      case FlashPhase.done:
        return;
      case FlashPhase.countdown:
      case FlashPhase.feedback:
        if (now >= _phaseEnds) {
          if (results.length >= rules.cards) {
            phase = FlashPhase.done;
          } else {
            _deal(now);
          }
        }
      case FlashPhase.card:
        final t = target!;
        final inZone = semis != null && (semis - (t - 1)).abs() <= rules.tolerance;
        if (inZone) {
          _enteredAt ??= now;
          if (now - _enteredAt! >= rules.holdMs) {
            _finish(now, _enteredAt! - _shownAt);
            return;
          }
        } else {
          _enteredAt = null;
        }
        if (now - _shownAt >= rules.timeoutMs) _finish(now, null);
    }
  }

  void _deal(int now) {
    // Never where the slide already is, nor the same card twice running.
    final from = _at ?? 1;
    final last = target;
    final choices = [
      for (var p = 1; p <= 7; p++)
        if (p != from && p != last) p,
    ];
    target = choices[_rng.nextInt(choices.length)];
    _from = from;
    _shownAt = now;
    _enteredAt = null;
    _phaseEnds = now + rules.timeoutMs;
    phase = FlashPhase.card;
  }

  void _finish(int now, int? ms) {
    final d = (target! - _from).abs();
    final par = rules.parMs(d);
    final mult = multiplier;
    final onPar = ms != null && ms <= par;
    final before = combo;
    combo = onPar ? combo + 1 : 0;
    bestCombo = math.max(bestCombo, combo);
    results.add(CardResult(
      target: target!,
      from: _from,
      ms: ms,
      base: ms == null ? 0 : rules.points(ms, d),
      multiplier: mult,
      parMs: par,
      comboAfter: combo,
      brokeCombo: !onPar && before > 0,
    ));
    _enteredAt = null;
    phase = FlashPhase.feedback;
    _phaseEnds = now + rules.feedbackMs;
  }
}
