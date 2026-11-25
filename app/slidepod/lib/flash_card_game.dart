import 'dart:math' as math;

/// The rules of the flash-card games: a card is shown (a position, or a
/// note), you move the slide to a position that answers it, and the faster you get there the more it scores. No
/// playing needed, just the slide.
///
/// Cards reached on par or faster build a combo; every [comboStep] in a
/// row raises the multiplier on each card's points, up to [maxMultiplier].
/// A card slower than par scores at the current multiplier and then resets
/// the combo; a miss scores nothing and resets it.
class FlashCardRules {
  /// How long a round lasts, from the first card: as many cards as you can.
  /// A card still up when it runs out doesn't count either way.
  final int roundMs;

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

  /// Playing levels: the note has to be sounded within this many cents of
  /// the card's note, as well as the slide in a position for it, for the
  /// whole hold. Null = no playing needed.
  final double? pitchGateCents;

  /// Within this many cents (the median over the hold) earns
  /// [inTuneBonus] on top of the speed points.
  final double inTuneCents;
  final int inTuneBonus;

  const FlashCardRules({
    this.roundMs = 30000,
    this.tolerance = 0.3,
    this.holdMs = 300,
    this.timeoutMs = 6000,
    this.countdownMs = 3000,
    this.feedbackMs = 500,
    this.parBaseMs = 600,
    this.parPerPositionMs = 100,
    this.parPoints = 1000,
    this.maxPoints = 1500,
    this.comboStep = 3,
    this.maxMultiplier = 4,
    this.pitchGateCents,
    this.inTuneCents = 10,
    this.inTuneBonus = 300,
  });

  bool get needsPitch => pitchGateCents != null;

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

/// What a card asks for: [label] to show, and the positions (1–7) that
/// answer it. A note can have more than one ([NoteDeck]).
class FlashCard {
  final String id;
  final String label;
  final Set<int> positions;

  /// The note shown, for decks of notes.
  final int? midi;

  const FlashCard(
      {required this.id, required this.label, required this.positions, this.midi});

  double get freq => 440.0 * math.pow(2, (midi! - 69) / 12);

  /// How far [hz] is from this card's note, in cents.
  double centsOff(double hz) => 1200 * math.log(hz / freq) / math.ln2;

  /// Positions away from [from] to the nearest that answers it.
  int distanceFrom(int from) =>
      positions.map((p) => (p - from).abs()).reduce(math.min);
}

/// Where a round's cards come from.
abstract class FlashDeck {
  List<FlashCard> get cards;

  /// The next card: never one the slide already answers, nor the same card
  /// twice running.
  FlashCard deal(int from, FlashCard? last, math.Random rng) {
    final choices = [
      for (final c in cards)
        if (!c.positions.contains(from) && c.id != last?.id) c,
    ];
    return choices[rng.nextInt(choices.length)];
  }
}

/// Level 1: the seven positions, by number.
class PositionDeck extends FlashDeck {
  @override
  final List<FlashCard> cards = [
    for (var p = 1; p <= 7; p++)
      FlashCard(id: 'p$p', label: '$p', positions: {p}),
  ];
}

/// Level 2: the notes [lowMidi]–[highMidi] (F2–F4), each answered by any
/// position that plays it on partials [minPartial]–[maxPartial] of a B♭
/// tenor trombone.
class NoteDeck extends FlashDeck {
  static const int lowMidi = 41, highMidi = 65; // F2, F4
  static const int minPartial = 2, maxPartial = 6;

  /// MIDI note of each partial in 1st position, from the 2nd (B♭2).
  static const _firstPosition = {2: 46, 3: 53, 4: 58, 5: 62, 6: 65};

  /// Spelled the usual way for trombone (flats).
  static const _names = [
    'C', 'D♭', 'D', 'E♭', 'E', 'F', 'G♭', 'G', 'A♭', 'A', 'B♭', 'B',
  ];

  static String noteName(int midi) => '${_names[midi % 12]}${midi ~/ 12 - 1}';

  /// Positions (1–7) that play [midi] on partials 2–6.
  static Set<int> positionsFor(int midi) => {
        for (var n = minPartial; n <= maxPartial; n++)
          if (_firstPosition[n]! - midi case final d when d >= 0 && d <= 6) d + 1,
      };

  @override
  final List<FlashCard> cards = [
    for (var m = lowMidi; m <= highMidi; m++)
      FlashCard(
          id: 'n$m', label: noteName(m), positions: positionsFor(m), midi: m),
  ];
}

class CardResult {
  final FlashCard card;

  /// Where the slide was when it was shown, and the position it went to
  /// (null = missed).
  final int from;
  final int? position;

  /// Shown to arrival; null = missed.
  final int? ms;

  /// Points for the speed, any in-tune bonus, the multiplier it scored at,
  /// and the lot multiplied.
  final int base, bonus, multiplier;
  final int parMs;

  /// Playing levels: how far off the note was (median over the hold).
  final double? cents;

  /// The combo after this card, and whether this card ended one.
  final int comboAfter;
  final bool brokeCombo;

  const CardResult({
    required this.card,
    required this.from,
    required this.position,
    required this.ms,
    required this.base,
    this.bonus = 0,
    required this.multiplier,
    required this.parMs,
    this.cents,
    required this.comboAfter,
    this.brokeCombo = false,
  });

  int get points => (base + bonus) * multiplier;
  bool get inTune => bonus > 0;

  /// This card as the server's round log has it (the server re-scores the
  /// round from these; see slidepod-server's RoundScorer).
  Map<String, Object?> toLog() => {
        'card': card.id,
        'from': from,
        'position': position,
        'ms': ms,
        'cents': cents,
      };
  bool get hit => ms != null;
  bool get onPar => ms != null && ms! <= parMs;
  int get distance => card.distanceFrom(from);
}

/// One round. Feed it the time and where the slide is ([update]); it moves
/// through the countdown, the cards, and the result of each.
class FlashCardRound {
  final FlashCardRules rules;
  final FlashDeck deck;
  final math.Random _rng;

  /// Where the round says what it's deciding (cards, readings, holds
  /// starting and breaking, and why), for working out why a card won't
  /// take. Null: quiet. Never changes the scoring.
  final void Function(String)? log;

  FlashCardRound(
      {this.rules = const FlashCardRules(),
      FlashDeck? deck,
      math.Random? rng,
      this.log})
      : deck = deck ?? PositionDeck(),
        _rng = rng ?? math.Random();

  /// Logging only: when the last reading line went out, and whether this
  /// gap in the readings has been reported.
  int _loggedAt = -1 << 31;
  bool _gapLogged = false;

  /// A reading line at most this often while a card is up.
  static const logEveryMs = 200;

  void _log(int now, String msg) =>
      log?.call('[flash] +${card == null ? 0 : now - _shownAt}ms $msg');

  static String _f(double? x) => x == null ? '—' : x.toStringAsFixed(2);

  /// Where the slide has to be for each of the card's positions.
  String _windows() => [
        for (final p in card!.positions)
          '$p: ${_f(p - 1 - rules.tolerance)}–${_f(p - 1 + rules.tolerance)}'
      ].join(', ');

  FlashPhase phase = FlashPhase.idle;
  final results = <CardResult>[];

  /// The card showing, and when it was shown.
  FlashCard? card;
  int _shownAt = 0, _from = 1;
  int _phaseEnds = 0;

  /// When the round's clock runs out (set as the first card is dealt).
  int? _roundEnds;

  /// When the slide entered an answering position, and which (null = not
  /// in one); playing levels: the pitch over the hold so far.
  int? _enteredAt, _enteredPos;

  /// When the sensor last had a reading.
  int? _seenAt;

  /// A gap in the readings this short doesn't break a hold: far out (6th,
  /// 7th) the sensor misses about half its readings. Not a scoring rule.
  static const blindGapMs = 250;
  final _holdCents = <double>[];

  /// Playing levels: the pitch heard last, against the card's note
  /// (null = nothing heard), for the screen's meter.
  double? heardCents;

  /// Position (1–7) nearest the slide, last seen.
  int? _at;

  /// Cards in a row on par or faster, and the most this round.
  int combo = 0, bestCombo = 0;

  int get multiplier => rules.multiplier(combo);

  int get cardNumber => results.length + (phase == FlashPhase.card ? 1 : 0);

  /// Time left on the countdown / card, for the screen.
  int remainingMs(int now) => math.max(0, _phaseEnds - now);

  /// Time left in the round (all of it before the first card).
  int roundRemainingMs(int now) =>
      _roundEnds == null ? rules.roundMs : math.max(0, _roundEnds! - now);

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

  static Map<K, double> _mean<K>(Iterable<(K, int)> xs) {
    final sums = <K, List<int>>{};
    for (final (k, v) in xs) {
      (sums[k] ??= []).add(v);
    }
    return {
      for (final e in sums.entries)
        e.key: e.value.reduce((a, b) => a + b) / e.value.length,
    };
  }

  /// Mean arrival time per position gone to, for "which ones are slow".
  Map<int, double> avgMsByPosition() => _mean([
        for (final r in results)
          if (r.hit) (r.position!, r.ms!),
      ]);

  /// Mean arrival time per card (by label), for "which notes are slow".
  Map<String, double> avgMsByCard() => _mean([
        for (final r in results)
          if (r.hit) (r.card.label, r.ms!),
      ]);

  void start(int now) {
    results.clear();
    combo = 0;
    bestCombo = 0;
    card = null;
    _roundEnds = null;
    phase = FlashPhase.countdown;
    _phaseEnds = now + rules.countdownMs;
  }

  /// [semis] is the slide's extension (0 = 1st, 6 = 7th), null when the
  /// sensor has no reading (a blind sensor can't confirm a hold). [freq]
  /// is the pitch heard (playing levels; null = silence).
  ///
  /// [mm] is the raw sensor reading behind [semis], for the log only.
  void update(int now, double? semis, {double? freq, double? mm}) {
    if (semis != null) {
      _at = (1 + semis.round()).clamp(1, 7);
      _seenAt = now;
    }
    switch (phase) {
      case FlashPhase.idle:
      case FlashPhase.done:
        return;
      case FlashPhase.countdown:
      case FlashPhase.feedback:
        if (_roundEnds != null && now >= _roundEnds!) {
          phase = FlashPhase.done;
        } else if (now >= _phaseEnds) {
          _roundEnds ??= now + rules.roundMs;
          _deal(now);
        }
      case FlashPhase.card:
        if (now >= _roundEnds!) {
          // Time's up mid-card: it doesn't count.
          phase = FlashPhase.done;
          return;
        }
        int? zone;
        if (semis != null) {
          for (final p in card!.positions) {
            if ((semis - (p - 1)).abs() <= rules.tolerance) zone = p;
          }
        } else if (_enteredPos != null &&
            _seenAt != null &&
            now - _seenAt! <= blindGapMs) {
          // No reading for a moment (common far out, in 6th and 7th):
          // still where it last was, so the hold goes on.
          zone = _enteredPos;
        }
        final inRange = zone;
        double? cents;
        if (rules.needsPitch) {
          cents = freq == null || freq <= 30 ? null : card!.centsOff(freq);
          heardCents = cents;
          // The right note, sounding, or it isn't there yet.
          if (cents == null || cents.abs() > rules.pitchGateCents!) zone = null;
        }
        if (log != null) _logFrame(now, semis, mm, inRange, zone, cents);
        if (zone != null) {
          if (zone != _enteredPos) {
            _enteredAt = now;
            _enteredPos = zone;
            _holdCents.clear();
            _log(now, 'hold starts in $zone at ${_f(semis)} '
                '(needs ${rules.holdMs}ms)');
          }
          if (cents != null) _holdCents.add(cents);
          // A gap can carry a hold, but it finishes on a real reading.
          if (now - _enteredAt! >= rules.holdMs && semis != null) {
            _log(now, 'HIT $zone: held ${now - _enteredAt!}ms, '
                'arrived at ${_enteredAt! - _shownAt}ms');
            _finish(now, _enteredAt! - _shownAt, zone);
            return;
          }
        } else {
          _enteredAt = null;
          _enteredPos = null;
        }
        if (now - _shownAt >= rules.timeoutMs) {
          _log(now, 'MISS: timed out after ${rules.timeoutMs}ms, slide at '
              '${_f(semis)} (${_windows()})');
          _finish(now, null, null);
        }
    }
  }

  /// Logging only: why the hold is (or isn't) going, on a change, and a
  /// reading line every [logEveryMs].
  void _logFrame(int now, double? semis, double? mm, int? inRange, int? zone,
      double? cents) {
    if (semis == null) {
      if (!_gapLogged) {
        _gapLogged = true;
        _log(now, _enteredPos == null
            ? 'no reading from the sensor (mm ${_f(mm)})'
            : 'no reading: carrying the hold in $_enteredPos for up to '
                '${blindGapMs}ms');
      }
      if (_enteredPos != null && zone == null) {
        _log(now, 'hold in $_enteredPos broken: no reading for '
            '${now - (_seenAt ?? now)}ms (more than ${blindGapMs}ms)');
      }
      return;
    }
    if (_gapLogged) {
      _gapLogged = false;
      _log(now, 'reading back: ${_f(semis)} (mm ${_f(mm)})');
    }
    if (_enteredPos != null && zone != _enteredPos) {
      _log(now, zone != null
          ? 'hold in $_enteredPos broken: slide moved to $zone (${_f(semis)})'
          : inRange == null
              ? 'hold in $_enteredPos broken: slide at ${_f(semis)}, outside '
                  '${_windows()}'
              : 'hold in $_enteredPos broken: pitch ${_f(cents)}¢, outside '
                  '±${rules.pitchGateCents}¢');
    }
    if (now - _loggedAt >= logEveryMs) {
      _loggedAt = now;
      final pitch = rules.needsPitch ? ' pitch ${_f(cents)}¢' : '';
      _log(now, 'slide ${_f(semis)} (mm ${_f(mm)}, nearest '
          '${(1 + semis.round()).clamp(1, 7)})$pitch → '
          '${zone != null ? 'holding $zone ${now - (_enteredAt ?? now)}ms' : inRange != null ? 'in $inRange, pitch not there' : 'not in ${_windows()}'}');
    }
  }

  void _deal(int now) {
    _from = _at ?? 1;
    card = deck.deal(_from, card, _rng);
    _shownAt = now;
    _loggedAt = -1 << 31;
    _gapLogged = false;
    _log(now, 'card ${card!.label} from $_from: slide (0 = 1st) must be in '
        '${_windows()} for ${rules.holdMs}ms');
    _enteredAt = null;
    _enteredPos = null;
    _holdCents.clear();
    heardCents = null;
    _phaseEnds = now + rules.timeoutMs;
    phase = FlashPhase.card;
  }

  void _finish(int now, int? ms, int? position) {
    final d = card!.distanceFrom(_from);
    final par = rules.parMs(d);
    final mult = multiplier;
    final onPar = ms != null && ms <= par;
    final before = combo;
    combo = onPar ? combo + 1 : 0;
    bestCombo = math.max(bestCombo, combo);
    double? cents;
    if (ms != null && _holdCents.isNotEmpty) {
      final sorted = List.of(_holdCents)..sort();
      // To 0.01¢, as logged for the server, so both decide the bonus on
      // the same number.
      cents = (sorted[sorted.length ~/ 2] * 100).roundToDouble() / 100;
    }
    results.add(CardResult(
      card: card!,
      from: _from,
      position: position,
      ms: ms,
      base: ms == null ? 0 : rules.points(ms, d),
      bonus: cents != null && cents.abs() <= rules.inTuneCents
          ? rules.inTuneBonus
          : 0,
      cents: cents,
      multiplier: mult,
      parMs: par,
      comboAfter: combo,
      brokeCombo: !onPar && before > 0,
    ));
    _enteredAt = null;
    _enteredPos = null;
    phase = FlashPhase.feedback;
    _phaseEnds = now + rules.feedbackMs;
  }
}
