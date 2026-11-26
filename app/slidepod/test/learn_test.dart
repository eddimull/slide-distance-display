import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slidepod/flash_card_game.dart';
import 'package:slidepod/flash_card_screen.dart';
import 'package:slidepod/staff_note.dart';
import 'package:slidepod/gliss_take.dart';
import 'package:slidepod/high_scores.dart';
import 'package:slidepod/high_scores_screen.dart';
import 'package:slidepod/learn_screen.dart';
import 'package:slidepod/note_diagnosis.dart';
import 'package:slidepod/slide_calibration.dart';

Future<HighScores> freshScores([Map<String, Object> init = const {}]) async {
  SharedPreferences.setMockInitialValues(init);
  return HighScores.open();
}

ScoreEntry entry(int score, [int day = 1]) =>
    ScoreEntry(score: score, at: DateTime(2026, 11, day), detail: 'd$score');

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  group('high scores', () {
    test('kept highest first, top ten, place returned', () async {
      final s = await freshScores();
      expect(await s.submit('g', entry(500)), 1);
      expect(await s.submit('g', entry(900)), 1);
      expect(await s.submit('g', entry(700)), 2);
      expect(await s.submit('g', entry(700, 2)), 3); // a tie goes below
      expect(s.top('g').map((e) => e.score), [900, 700, 700, 500]);
      expect(s.top('g')[1].at.day, 1);
      for (var i = 0; i < 10; i++) {
        await s.submit('g', entry(1000 + i));
      }
      expect(s.top('g'), hasLength(HighScores.keep));
      expect(await s.submit('g', entry(10)), isNull); // didn't make it
      expect(s.best('g')!.score, 1009);
      expect(s.top('other'), isEmpty);
    });

    test('a damaged table starts again', () async {
      final s = await freshScores({'scores_g': '{nope'});
      expect(s.top('g'), isEmpty);
      expect(await s.submit('g', entry(5)), 1);
    });

    test('dates read as Today / Yesterday / Nov 18', () {
      final now = DateTime(2026, 11, 21, 10);
      expect(HighScoresScreen.dateLabel(DateTime(2026, 11, 21, 8), now: now), 'Today');
      expect(HighScoresScreen.dateLabel(DateTime(2026, 11, 20, 23), now: now), 'Yesterday');
      expect(HighScoresScreen.dateLabel(DateTime(2026, 11, 18), now: now), 'Nov 18');
    });
  });

  group('unlocking', () {
    LearnGame game(String title) => learnGames.firstWhere((g) => g.title == title);

    test('each game is its own ladder, opened at 15,000 a level', () async {
      final s = await freshScores();
      final pos = game('Position Flash'), notes = game('Note Flash'),
          play = game('Play the Note');
      // Every game's Level 1 is open from the start.
      expect(pos.open(s), [true, false]);
      expect(notes.open(s), [true, false, false, false, false, false]);
      expect(play.open(s), [true, false, false, false, false, false]);
      expect(notes.current(s), noteFlash);

      await s.submit(positionFlash.id, entry(14999));
      expect(pos.open(s), [true, false]);
      await s.submit(positionFlash.id, entry(15000));
      expect(pos.open(s), [true, true]);
      expect(pos.current(s), positionFlashAll);
      // Position Flash doesn't open anything in the other games.
      await s.submit(positionFlashAll.id, entry(15000));
      expect(notes.open(s), [true, false, false, false, false, false]);
      expect(play.open(s), [true, false, false, false, false, false]);

      // Note Flash's levels don't open Play the Note's, nor the other way.
      await s.submit(noteFlashLevels[0].id, entry(16000));
      await s.submit(noteFlashLevels[1].id, entry(15000));
      expect(notes.open(s), [true, true, true, false, false, false]);
      expect(notes.current(s), noteFlashLevels[2]);
      expect(play.open(s), [true, false, false, false, false, false]);
      await s.submit(playTheNoteLevels[0].id, entry(15000));
      expect(play.open(s), [true, true, false, false, false, false]);
      expect(notes.open(s), [true, true, true, false, false, false]);
    });

    test('the levels: ids, ranges and names', () {
      expect({for (final l in allGameSpecs) l.id}, hasLength(14));
      expect(positionFlash.deck().cards.map((c) => c.label), ['1', '2', '3', '4']);
      expect(positionFlashAll.deck().cards, hasLength(7));
      final octave = noteFlashLevels[0].deck().cards;
      expect([octave.first.label, octave.last.label], ['B♭2', 'B♭3']);
      expect(noteFlashLevels[0].showNames, isTrue);
      expect(noteFlashLevels[1].showNames, isFalse);
      final wide = noteFlashLevels[2].deck().cards;
      expect([wide.first.label, wide.last.label], ['E2', 'B♭4']);
      // Every note has a position, E2 only 7th and B♭4 only 1st.
      expect(wide.every((c) => c.positions.isNotEmpty), isTrue);
      expect(wide.first.positions, {7});
      expect(wide.last.positions, {1});
      expect(wide.firstWhere((c) => c.label == 'F4').positions, {1, 4, 6});
      expect(noteFlashLevels[3].deck().cards.first.clef, Clef.tenor);
      expect(noteFlashLevels[4].deck().cards.first.clef, Clef.alto);
      for (final (i, l) in playTheNoteLevels.indexed) {
        expect(l.needsPitch, isTrue);
        expect(l.levelName, noteFlashLevels[i].levelName);
      }
    });

    test('All clefs deals every clef', () {
      final deck = noteFlashLevels[5].deck();
      final rng = math.Random(1);
      FlashCard? last;
      final seen = <Clef>{};
      for (var i = 0; i < 60; i++) {
        last = deck.deal(1, last, rng);
        seen.add(last.clef);
      }
      expect(seen, Clef.values.toSet());
    });

    test('clef levels keep to their staff: tenor D3–B♭4, alto F3–D♭5', () {
      String span(FlashGameSpec l, Clef c) {
        final m = (l.deck() as NoteDeck).midisIn(c);
        return '${NoteDeck.noteName(m.first)}–${NoteDeck.noteName(m.last)}';
      }
      expect(span(noteFlashLevels[3], Clef.tenor), 'D3–B♭4');
      expect(span(noteFlashLevels[4], Clef.alto), 'F3–D♭5');
      final mixed = noteFlashLevels[5];
      expect(span(mixed, Clef.bass), 'E2–B♭4');
      expect(span(mixed, Clef.tenor), 'D3–B♭4');
      expect(span(mixed, Clef.alto), 'F3–D♭5');
      // Above B♭4 take partials 9 and 10: C5 in 1st, D♭5 in 2nd.
      final alto = noteFlashLevels[4].deck().cards;
      expect(alto.firstWhere((c) => c.label == 'C5').positions, contains(1));
      expect(alto.last.positions, contains(2));
      expect(alto.every((c) => c.positions.isNotEmpty), isTrue);
      // All clefs deals each clef only its own notes.
      for (final l in [noteFlashLevels[3], noteFlashLevels[4], mixed]) {
        final deck = l.deck() as NoteDeck;
        final rng = math.Random(7);
        FlashCard? last;
        for (var i = 0; i < 2000; i++) {
          last = deck.deal(1 + i % 7, last, rng);
          expect(deck.midisIn(last.clef), contains(last.midi), reason: l.id);
        }
      }
      expect([for (final l in noteFlashLevels) l.rulesVersion], [3, 1, 1, 2, 2, 2]);
    });

    testWidgets('the tab: a card per game, its level and progress', (tester) async {
      tall(tester);
      final s = await freshScores();
      await s.submit(positionFlash.id, entry(16000));
      await s.submit(positionFlashAll.id, entry(10800));
      await tester.pumpWidget(MaterialApp(
        home: LearnScreen(
          learn: LearnContext(
              frames: const Stream.empty(), cal: SlideCalibration(), scores: s),
        ),
      ));
      expect(find.text('Position Flash'), findsOneWidget);
      expect(find.text('Level 2 of 2 · All seven'), findsOneWidget);
      expect(find.text('10,800'), findsOneWidget);
      expect(find.text('Level 1 of 6 · One octave'), findsNWidgets(2));
      expect(find.widgetWithText(FilledButton, 'Play'), findsNWidgets(3));

      // A game's levels: passed, current, locked.
      await tester.tap(find.text('Position Flash'));
      await tester.pumpAndSettle();
      expect(find.byType(LearnLevelsScreen), findsOneWidget);
      expect(find.text('LEVEL 2 · NOW'), findsOneWidget);
      expect(find.text('16,000'), findsOneWidget);
      expect(find.text('Play Level 2 · All seven'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Note Flash'));
      await tester.pumpAndSettle();
      expect(find.text('LEVEL 1 · NOW'), findsOneWidget);
      expect(find.text('15,000 in Level 1 opens it'), findsOneWidget);
      expect(find.text('Play Level 1 · One octave'), findsOneWidget);
    });

    testWidgets('not connected: no playing', (tester) async {
      tall(tester);
      final s = await freshScores();
      await tester.pumpWidget(MaterialApp(
        home: LearnScreen(
          connected: false,
          learn: LearnContext(
              frames: const Stream.empty(), cal: SlideCalibration(), scores: s),
        ),
      ));
      expect(find.text('Connect the slide pod to play.'), findsOneWidget);
      for (final b in tester.widgetList<FilledButton>(find.widgetWithText(FilledButton, 'Play'))) {
        expect(b.onPressed, isNull);
      }
    });

    testWidgets('not connected: the prompt connects, and Play turns on',
        (tester) async {
      tall(tester);
      final s = await freshScores();
      final connection = ValueNotifier(false);
      final searching = ValueNotifier(false);
      var connects = 0;
      final learn = LearnContext(
          frames: const Stream.empty(),
          cal: SlideCalibration(),
          scores: s,
          connection: connection,
          searching: searching,
          connect: () {
            connects++;
            searching.value = true;
          });
      await tester.pumpWidget(MaterialApp(
          home: LearnScreen(connected: false, learn: learn)));
      await tester.tap(find.text('Connect the slide pod to play'));
      expect(connects, 1);
      // Searching: it says so, and doesn't start another search.
      await tester.pump();
      expect(find.text('Searching for the slide pod…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Searching for the slide pod…'));
      expect(connects, 1);
      searching.value = false; // nothing found
      await tester.pump();
      expect(find.text('Connect the slide pod to play'), findsOneWidget);

      // On a game's levels, the same; then the pod connects.
      await tester.tap(find.text('Position Flash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect the slide pod to play'));
      expect(connects, 2);
      FilledButton play() =>
          tester.widget(find.widgetWithText(FilledButton, 'Play Level 1 · First four'));
      expect(play().onPressed, isNull);
      connection.value = true;
      await tester.pump();
      expect(find.text('Connect the slide pod to play'), findsNothing);
      expect(play().onPressed, isNotNull);
    });
  });

  testWidgets('a whole round: fast answers, ×4, a new high score',
      (tester) async {
    tall(tester);
    final scores = await freshScores();
    final cal = SlideCalibration();
    final frames = StreamController<CalFrame>.broadcast();
    var now = 0;
    await tester.pumpWidget(MaterialApp(
      home: FlashCardScreen(
          frames: frames.stream, cal: cal, scores: scores, clock: () => now),
    ));

    Future<void> slideTo(double semis) async {
      frames.add((t: DateTime.now(), mm: mmAtSemis(cal, semis), freq: null));
      await tester.pump();
    }

    int target() => int.parse(tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere((t) => t.style?.fontSize == 140)
        .data!);

    // Start is waiting for the pod until it hears from it.
    expect(find.text('Waiting for the slide pod…'), findsOneWidget);
    await slideTo(0);
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('Get ready'), findsOneWidget);

    now += 3100;
    await slideTo(0);
    bool done() => find.text('Play again').evaluate().isNotEmpty;
    expect(find.text('0:30'), findsOneWidget); // the round clock
    var cards = 0;
    while (!done() && cards++ < 60) {
      final t = target();
      now += 250;
      await slideTo(t - 1.0);
      now += 320; // held
      await slideTo(t - 1.0);
      now += 520;
      await slideTo(t - 1.0);
    }
    await tester.pump();
    expect(done(), isTrue);
    expect(cards, greaterThan(20));
    expect(find.text('New high score'), findsOneWidget);
    expect(find.text('Best combo'), findsOneWidget);
    expect(find.text('×4'), findsWidgets);
    final best = scores.best(FlashCardScreen.gameId)!;
    expect(best.detail, matches(RegExp(r'^\d+ found · combo \d+')));
    expect(find.text(thousands(best.score)), findsOneWidget);

    await tester.tap(find.text('Scores'));
    await tester.pumpAndSettle();
    expect(find.byType(HighScoresScreen), findsOneWidget);
    expect(find.text('Best'), findsOneWidget);
    await frames.close();
  });

  testWidgets('Note Flash: a note on the staff; any position that plays it',
      (tester) async {
    tall(tester);
    final scores = await freshScores();
    final cal = SlideCalibration();
    final frames = StreamController<CalFrame>.broadcast();
    var now = 0;
    await tester.pumpWidget(MaterialApp(
      home: FlashCardScreen(
          frames: frames.stream,
          cal: cal,
          scores: scores,
          spec: noteFlash,
          clock: () => now),
    ));
    expect(find.text('LEVEL 1 · ONE OCTAVE'), findsOneWidget);

    Future<void> slideTo(double semis) async {
      frames.add((t: DateTime.now(), mm: mmAtSemis(cal, semis), freq: null));
      await tester.pump();
    }

    final deck = noteFlash.deck();
    FlashCard shown() => deck.cards.firstWhere((c) => tester
        .widgetList<Text>(find.byType(Text))
        .any((t) => t.style?.fontSize == 30 && t.data == c.label));

    await slideTo(0);
    await tester.tap(find.text('Start'));
    await tester.pump();
    now += 3100;
    await slideTo(0);
    expect(find.byType(StaffNote), findsOneWidget);
    expect(find.text('Any position that plays it counts.'), findsOneWidget);

    bool done() => find.text('Play again').evaluate().isNotEmpty;
    var cards = 0;
    while (!done() && cards++ < 60) {
      final c = shown();
      final p = (c.positions.toList()..sort()).last; // the far one is fine too
      now += 400;
      await slideTo(p - 1.0);
      now += 320;
      await slideTo(p - 1.0);
      if (!done()) {
        expect(find.textContaining(ordinalPos(p)), findsWidgets, reason: c.label);
      }
      now += 520;
      await slideTo(p - 1.0);
    }
    await tester.pump();
    expect(done(), isTrue);
    expect(find.text('NOTES THAT TOOK LONGEST'), findsOneWidget);
    expect(scores.best(noteFlash.id)!.detail, contains('found'));
    expect(scores.best(FlashCardScreen.gameId), isNull); // its own table
    await frames.close();
  });

  testWidgets('No names: the name shows once the card is answered or missed',
      (tester) async {
    tall(tester);
    final scores = await freshScores();
    final cal = SlideCalibration();
    final frames = StreamController<CalFrame>.broadcast();
    var now = 0;
    final spec = noteFlashLevels[1];
    await tester.pumpWidget(MaterialApp(
      home: FlashCardScreen(
          frames: frames.stream,
          cal: cal,
          scores: scores,
          spec: spec,
          rng: math.Random(4),
          clock: () => now),
    ));
    Future<void> slideTo(double semis) async {
      frames.add((t: DateTime.now(), mm: mmAtSemis(cal, semis), freq: null));
      await tester.pump();
    }

    final deck = spec.deck();
    bool named(FlashCard c) => tester
        .widgetList<Text>(find.byType(Text))
        .any((t) => t.style?.fontSize == 30 && t.data == c.label);
    FlashCard? shown() => deck.cards.where(named).firstOrNull;

    await slideTo(0);
    await tester.tap(find.text('Start'));
    await tester.pump();
    now += 3100;
    await slideTo(0);
    expect(find.byType(StaffNote), findsOneWidget);
    expect(shown(), isNull, reason: 'no name while the card is up');

    // Miss it: the name, and where it is.
    now += spec.rules.timeoutMs + 40;
    await slideTo(0);
    final missed = shown();
    expect(missed, isNotNull);
    expect(find.textContaining("Missed · it's in "), findsOneWidget);
    expect(find.textContaining(ordinalPos((missed!.positions.toList()..sort()).first)),
        findsWidgets);

    // The next card: unnamed again until it's found.
    now += spec.rules.feedbackMs + 40;
    await slideTo(0);
    expect(shown(), isNull);
    await frames.close();
  });
}
