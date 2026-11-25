import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/flash_card_game.dart';
import 'package:slidepod/flash_card_screen.dart';
import 'package:slidepod/live_position.dart';
import 'package:slidepod/trombone_chart.dart';

/// The 4th partial in [position], in tune.
double inTune(int position) =>
    TromboneChart.notesAt(position).firstWhere((n) => n.partial == 4).freq;

void main() {
  group('live position', () {
    test('silent: stays put within ±0.6, then moves', () {
      final live = LivePosition();
      expect(live.update(2.0), 3);
      expect(live.update(2.55), 3); // past halfway, still 3rd
      expect(live.update(2.59), 3);
      expect(live.update(2.65), 4); // more than 0.6 out
      expect(live.update(2.45), 4); // and back in, 4th holds too
      expect(live.update(2.35), 3);
    });

    test('an in-tune 3rd at 2.55 reads 3rd, not a sharp 4th', () {
      final live = LivePosition();
      // Coming in from 4th, where rounding alone would keep it 4th.
      expect(live.update(3.0), 4);
      expect(live.update(2.55, freq: inTune(3)), 3);
      // And the 4th's own note there reads 4th.
      expect(live.update(2.55, freq: inTune(4)), 4);
    });

    test('a note never pulls it more than 0.6 away', () {
      final live = LivePosition();
      expect(live.update(2.0, freq: inTune(5)), 3);
    });

    test('reset forgets the held position', () {
      final live = LivePosition()..update(2.55);
      live.reset();
      expect(live.update(2.55), 4);
    });
  });

  test('Note Flash v2: within ±0.6 too', () {
    expect(noteFlash.rulesVersion, 2);
    expect(noteFlash.rules.tolerance, 0.6);
  });

  test('Position Flash v2: within ±0.6 counts (7th landed at 5.45)', () {
    expect(positionFlash.rulesVersion, 2);
    expect(positionFlash.rules.tolerance, 0.6);
    final round = FlashCardRound(rules: positionFlash.rules, deck: _Seventh());
    var now = 0;
    round.start(now);
    while (round.phase != FlashPhase.card) {
      round.update(now += 20, 0);
    }
    final shown = now;
    while (round.phase == FlashPhase.card) {
      round.update(now += 20, 5.45);
    }
    expect(round.results.single.hit, isTrue);
    expect(round.results.single.ms, 20);
    expect(now - shown, greaterThanOrEqualTo(positionFlash.rules.holdMs));
  });
}

class _Seventh extends FlashDeck {
  @override
  List<FlashCard> get cards =>
      [const FlashCard(id: 'p7', label: '7', positions: {7})];
  @override
  FlashCard deal(int from, FlashCard? last, math.Random rng) => cards.single;
}
