import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/flash_card_game.dart';
import 'package:slidepod/flash_card_screen.dart';

/// Rounds with known scores, shared with the server (slidepod-server's
/// tests/Fixtures/score_vectors.json): its PHP scorer must agree with this
/// one on every round. Regenerate after a rules change with
///   UPDATE_VECTORS=1 flutter test test/score_vectors_test.dart
/// and copy the file across.
const fixture = 'test/fixtures/score_vectors.json';

/// Plays one seeded round: how fast, how in tune and when it misses all
/// come from the seed, so the rounds cover slow cards, misses, combos to
/// ×4, alternate positions and (playing level) the in-tune bonus.
Map<String, Object?> playRound(FlashGameSpec spec, int seed, {bool fast = false}) {
  final rng = math.Random(seed);
  final rules = spec.rules;
  final round = FlashCardRound(rules: rules, deck: spec.deck(), rng: math.Random(seed + 1000));
  var now = 0;
  double? semis = rng.nextInt(7).toDouble();
  void step(int ms, {double? freq}) {
    final end = now + ms;
    while (now < end) {
      now += 20;
      round.update(now, semis, freq: freq);
    }
  }

  round.start(0);
  step(rules.countdownMs + 20);
  while (round.phase != FlashPhase.done) {
    final card = round.card!;
    final roll = rng.nextDouble();
    if (!fast && roll < 0.08) {
      step(rules.timeoutMs + 40); // a miss: never gets there
    } else {
      // Fast or slow, to the nearest answer or (sometimes) another one.
      final ps = card.positions.toList()..sort();
      final p = ps[rng.nextInt(ps.length)];
      final travel = fast || roll < 0.6 ? 200 + rng.nextInt(400) : 700 + rng.nextInt(1500);
      final cents = (rng.nextDouble() - 0.5) * 2 * (roll < 0.75 ? 9 : 22);
      final freq = rules.needsPitch ? card.freq * math.pow(2, cents / 1200) : null;
      step(travel, freq: freq);
      semis = p - 1.0;
      step(rules.holdMs + 40, freq: freq);
    }
    if (round.phase == FlashPhase.done) break;
    step(rules.feedbackMs + 20);
  }
  return {
    'name': '${spec.id} seed $seed${fast ? ' fast' : ''}',
    'game': spec.id,
    'rules_version': 1,
    'cards': [for (final r in round.results) r.toLog()],
    'expected': {
      'score': round.score,
      'found': round.hits,
      'answered': round.results.length,
      'best_combo': round.bestCombo,
      'in_tune': rules.needsPitch ? round.results.where((r) => r.inTune).length : null,
    },
  };
}

void main() {
  test('score vectors are current', () {
    final rounds = [
      for (final spec in [positionFlash, noteFlash, playTheNote])
        for (var seed = 1; seed <= 4; seed++) playRound(spec, seed),
      for (final spec in [positionFlash, noteFlash, playTheNote])
        playRound(spec, 9, fast: true),
    ];
    final json = '${const JsonEncoder.withIndent('  ').convert({
          'about': 'Rounds and their scores from the app (test/score_vectors_test.dart).',
          'rounds': rounds,
        })}\n';
    final file = File(fixture);
    if (Platform.environment['UPDATE_VECTORS'] == '1' || !file.existsSync()) {
      file.writeAsStringSync(json);
    }
    expect(file.readAsStringSync(), json,
        reason: 'The scoring changed: regenerate with UPDATE_VECTORS=1, '
            'bump the rules version, and update the server.');
    // The rounds exercise what they should.
    final all = rounds.map((r) => r['expected'] as Map).toList();
    expect(all.any((e) => e['found'] != e['answered']), isTrue); // misses
    expect(all.any((e) => (e['best_combo'] as int) >= 9), isTrue); // ×4
  });
}
