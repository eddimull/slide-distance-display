import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/flash_card_game.dart';

/// Drives a round on a fake clock: [semis] is where the slide is.
class Driver {
  final FlashCardRound round;
  int now = 0;
  double? semis = 0; // 1st
  Driver([FlashCardRules rules = const FlashCardRules(), int seed = 1, FlashDeck? deck])
      : round = FlashCardRound(rules: rules, deck: deck, rng: math.Random(seed));

  void step(int ms) {
    final end = now + ms;
    while (now < end) {
      now += 20;
      round.update(now, semis);
    }
  }

  /// Starts and runs the countdown until the first card is up.
  void startToFirstCard() {
    round.start(now);
    step(round.rules.countdownMs + 20);
    expect(round.phase, FlashPhase.card);
  }

  /// The card's first answering position.
  int get target => round.card!.positions.first;

  /// Moves straight to the card's position after [ms] and holds it.
  void answer(int ms) {
    final t = target;
    step(ms);
    semis = t - 1.0;
    step(round.rules.holdMs + 40);
    expect(round.phase, FlashPhase.feedback);
  }

  /// Through the feedback to the next card (or the end).
  void next() => step(round.rules.feedbackMs + 20);
}

void main() {
  const rules = FlashCardRules();

  test('points: par for the distance, more if faster, capped', () {
    expect(rules.parMs(1), 700);
    expect(rules.parMs(6), 1200);
    expect(rules.points(700, 1), 1000);
    expect(rules.points(1400, 1), 500);
    expect(rules.points(100, 1), 1500); // cap
    expect(rules.points(1200, 6), 1000); // a long move on par is as good
  });

  test('multiplier: up one every 3 in a row, to ×4', () {
    expect([0, 1, 2, 3, 5, 6, 9, 30].map(rules.multiplier),
        [1, 1, 1, 2, 2, 3, 4, 4]);
  });

  test('countdown, then a card that isn\'t where the slide is', () {
    final d = Driver();
    d.round.start(0);
    d.step(1000);
    expect(d.round.phase, FlashPhase.countdown);
    expect(d.round.remainingMs(d.now), closeTo(2000, 20));
    d.step(2100);
    expect(d.round.phase, FlashPhase.card);
    expect(d.target, isNot(1));
  });

  test('never the same card twice running, nor where the slide is', () {
    for (var seed = 0; seed < 20; seed++) {
      final d = Driver(rules, seed);
      d.startToFirstCard();
      String? last;
      while (d.round.phase != FlashPhase.done) {
        final c = d.round.card!;
        expect(c.id, isNot(last));
        expect(c.positions, isNot(contains((1 + d.semis!.round()).clamp(1, 7))));
        last = c.id;
        d.answer(300);
        d.next();
      }
    }
  });

  test('time counts from arrival, but only once the slide holds there', () {
    final d = Driver();
    d.startToFirstCard();
    final t = d.target;
    // Swing through the position at 200 ms without stopping...
    d.step(200);
    d.semis = t - 1.0;
    d.step(100);
    d.semis = t - 1.0 + 0.8;
    d.step(200);
    expect(d.round.phase, FlashPhase.card);
    // ...then come back at 500 ms and hold.
    d.semis = t - 1.0 + 0.1; // within tolerance
    d.step(rules.holdMs + 40);
    expect(d.round.phase, FlashPhase.feedback);
    final r = d.round.results.single;
    expect(r.ms, inInclusiveRange(500, 540));
    expect(r.hit, isTrue);
  });

  test('a blind sensor breaks the hold', () {
    final d = Driver();
    d.startToFirstCard();
    d.semis = d.target - 1.0;
    d.step(200);
    d.semis = null;
    d.step(200);
    expect(d.round.phase, FlashPhase.card);
    expect(d.round.holdProgress(d.now), 0);
  });

  test('not there in time: missed, no points', () {
    final d = Driver();
    d.startToFirstCard();
    d.step(rules.timeoutMs + 40);
    expect(d.round.phase, FlashPhase.feedback);
    final r = d.round.results.single;
    expect(r.hit, isFalse);
    expect(r.points, 0);
  });

  test('combo: three on par makes ×2; a slow card scores ×2 then resets', () {
    final d = Driver();
    d.startToFirstCard();
    for (var i = 0; i < 3; i++) {
      d.answer(300); // well under any par
      expect(d.round.results.last.multiplier, 1);
      d.next();
    }
    expect(d.round.combo, 3);
    expect(d.round.multiplier, 2);

    d.answer(2500); // slower than par
    final slow = d.round.results.last;
    expect(slow.multiplier, 2);
    expect(slow.points, slow.base * 2);
    expect(slow.brokeCombo, isTrue);
    expect(d.round.combo, 0);
    expect(d.round.multiplier, 1);
    d.next();

    d.step(rules.timeoutMs + 40); // a miss with no combo breaks nothing
    expect(d.round.results.last.brokeCombo, isFalse);
    expect(d.round.bestCombo, 3);
  });

  test('a full round: 10 cards, all fast, reaches ×4', () {
    final d = Driver();
    d.startToFirstCard();
    while (d.round.phase != FlashPhase.done) {
      d.answer(200);
      d.next();
    }
    final r = d.round.results;
    expect(r, hasLength(10));
    expect(r.map((c) => c.multiplier), [1, 1, 1, 2, 2, 2, 3, 3, 3, 4]);
    expect(d.round.bestCombo, 10);
    expect(d.round.hits, 10);
    expect(d.round.score, r.fold<int>(0, (s, c) => s + c.points));
    expect(d.round.avgMsByPosition().keys, everyElement(inInclusiveRange(1, 7)));
  });

  group('notes deck (Level 2)', () {
    final deck = NoteDeck();

    test('F2 to F4, chromatic, spelled with flats', () {
      expect(deck.cards, hasLength(25));
      expect(deck.cards.first.label, 'F2');
      expect(deck.cards.last.label, 'F4');
      expect(deck.cards.map((c) => c.label),
          containsAll(['G♭2', 'B♭2', 'B2', 'E♭3', 'A♭3', 'D♭4']));
    });

    test('every position that plays it on partials 2–6', () {
      Set<int> at(String n) => deck.cards.firstWhere((c) => c.label == n).positions;
      expect(at('F2'), {6});
      expect(at('B♭2'), {1});
      expect(at('B2'), {7});
      expect(at('E3'), {2, 7});
      expect(at('F3'), {1, 6});
      expect(at('A3'), {2, 6});
      expect(at('B♭3'), {1, 5});
      expect(at('D4'), {1, 4});
      expect(at('E♭4'), {3});
      expect(at('F4'), {1});
      for (final c in deck.cards) {
        expect(c.positions, isNotEmpty, reason: c.label);
      }
    });

    test('par is to the nearest answer; the one used is recorded', () {
      final d = Driver(const FlashCardRules(), 3, NoteDeck());
      d.semis = 5.0; // 6th
      d.startToFirstCard();
      final c = d.round.card!;
      expect(c.positions, isNot(contains(6)));
      final near = (c.positions.toList()
            ..sort((a, b) => (a - 6).abs().compareTo((b - 6).abs())))
          .first;
      d.answer(300);
      final r = d.round.results.single;
      expect(r.position, c.positions.first);
      expect(r.distance, (near - 6).abs());
      expect(r.parMs, const FlashCardRules().parMs((near - 6).abs()));
    });

    test('either position of F3 counts', () {
      for (final p in [1, 6]) {
        final d = Driver(const FlashCardRules(), 1, _OnlyDeck('F3'));
        d.semis = 3.0; // 4th: neither
        d.startToFirstCard();
        d.step(200);
        d.semis = p - 1.0;
        d.step(360);
        expect(d.round.results.single.position, p);
      }
    });
  });
}

/// A deck of one note, for pinning a card.
class _OnlyDeck extends FlashDeck {
  final String label;
  _OnlyDeck(this.label);
  @override
  List<FlashCard> get cards => [NoteDeck().cards.firstWhere((c) => c.label == label)];
  @override
  FlashCard deal(int from, FlashCard? last, math.Random rng) => cards.single;
}
