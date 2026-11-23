import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seventh/flash_card_game.dart';
import 'package:seventh/flash_card_screen.dart';
import 'package:seventh/gliss_take.dart';
import 'package:seventh/high_scores.dart';
import 'package:seventh/note_diagnosis.dart';
import 'package:seventh/slide_calibration.dart';

/// A deck of one note, for pinning a card.
class OnlyDeck extends FlashDeck {
  final String label;
  OnlyDeck(this.label);
  @override
  List<FlashCard> get cards =>
      [NoteDeck().cards.firstWhere((c) => c.label == label)];
  @override
  FlashCard deal(int from, FlashCard? last, math.Random rng) => cards.single;
}

double hz(FlashCard c, double cents) => c.freq * math.pow(2, cents / 1200);

void main() {
  final rules = playTheNote.rules;

  group('Play the Note round', () {
    late FlashCardRound round;
    late FlashCard card;
    var now = 0;

    /// Run [ms] of readings with the slide at [pos] (1–7, null = blind)
    /// and the pitch [cents] off the card's note (null = silence).
    void play(int ms, int? pos, double? cents) {
      final end = now + ms;
      while (now < end) {
        now += 20;
        round.update(now, pos == null ? null : pos - 1.0,
            freq: cents == null ? null : hz(card, cents));
      }
    }

    setUp(() {
      now = 0;
      round = FlashCardRound(rules: rules, deck: OnlyDeck('D3'));
      round.start(0);
      play(rules.countdownMs + 20, 1, null);
      expect(round.phase, FlashPhase.card);
      card = round.card!; // D3: 4th only
    });

    test('the slide alone isn\'t enough: it has to sound', () {
      play(1000, 4, null);
      expect(round.phase, FlashPhase.card);
      expect(round.heardCents, isNull);
      play(400, 4, 3);
      expect(round.phase, FlashPhase.feedback);
      final r = round.results.single;
      expect(r.position, 4);
      expect(r.cents, closeTo(3, 0.5));
      expect(r.inTune, isTrue);
      expect(r.bonus, rules.inTuneBonus);
      expect(r.points, (r.base + r.bonus) * r.multiplier);
    });

    test('the note alone isn\'t enough: the slide has to be there', () {
      play(1000, 1, 0); // lipped from 1st? still not in a position for D3
      expect(round.phase, FlashPhase.card);
    });

    test('within ±25¢ counts without the bonus; past it, no', () {
      play(400, 4, 40);
      expect(round.phase, FlashPhase.card);
      play(400, 4, -18);
      final r = round.results.single;
      expect(r.cents, closeTo(-18, 0.5));
      expect(r.inTune, isFalse);
      expect(r.bonus, 0);
    });

    test('an octave off, or a breath, breaks the hold', () {
      play(200, 4, 0);
      play(200, 4, 1200); // D4: wrong note
      play(200, 4, 0);
      play(60, 4, null); // a gap
      play(200, 4, 0);
      expect(round.phase, FlashPhase.card);
      play(200, 4, 0);
      expect(round.phase, FlashPhase.feedback);
    });

    test('par allows time to start the note', () {
      expect(rules.parMs(3), 1300);
      expect(rules.parMs(0), 1000);
    });
  });

  testWidgets('Play the Note: mic on at start, meter, in-tune results',
      (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final scores = await HighScores.open();
    final cal = SlideCalibration();
    final frames = StreamController<CalFrame>.broadcast();
    var now = 0;
    var micOn = 0;
    await tester.pumpWidget(MaterialApp(
      home: FlashCardScreen(
          frames: frames.stream,
          cal: cal,
          scores: scores,
          spec: playTheNote,
          ensureMic: () async => micOn++,
          clock: () => now),
    ));
    expect(find.text('LEVEL 3 · PLAYING'), findsOneWidget);
    expect(find.textContaining('within ±25¢'), findsOneWidget);

    Future<void> send(double semis, double? freq) async {
      frames.add((t: DateTime.now(), mm: mmAtSemis(cal, semis), freq: freq));
      await tester.pump();
    }

    final deck = NoteDeck();
    FlashCard shown() => deck.cards.firstWhere((c) => tester
        .widgetList<Text>(find.byType(Text))
        .any((t) => t.style?.fontSize == 30 && t.data == c.label));

    await send(0, null);
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(micOn, 1);
    now += 3100;
    await send(0, null);
    expect(find.text('Listening…'), findsOneWidget);

    bool done() => find.text('Play again').evaluate().isNotEmpty;
    var n = 0;
    while (!done() && n++ < 60) {
      final c = shown();
      final p = c.positions.first;
      now += 300;
      await send(p - 1.0, hz(c, n.isEven ? 4 : 18)); // every other in tune
      now += 320;
      await send(p - 1.0, hz(c, n.isEven ? 4 : 18));
      now += 520;
      await send(p - 1.0, null);
    }
    await tester.pump();
    expect(done(), isTrue);
    expect(find.text('In tune (±10¢)'), findsOneWidget);
    expect(find.text('+4¢'), findsWidgets); // on the cards
    expect(scores.best(playTheNote.id), isNotNull);
    await frames.close();
  });
}
