import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seventh/flash_card_game.dart';
import 'package:seventh/flash_card_screen.dart';
import 'package:seventh/staff_note.dart';
import 'package:seventh/gliss_take.dart';
import 'package:seventh/high_scores.dart';
import 'package:seventh/high_scores_screen.dart';
import 'package:seventh/learn_screen.dart';
import 'package:seventh/note_diagnosis.dart';
import 'package:seventh/slide_calibration.dart';

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
    test('Level 2 opens at 15,000 in Position Flash, Level 3 at 15,000 in Note Flash',
        () async {
      final s = await freshScores();
      expect(unlockedLevels(learnLevels, s), [true, false, false]);
      await s.submit(FlashCardScreen.gameId, entry(14999));
      expect(unlockedLevels(learnLevels, s), [true, false, false]);
      await s.submit(FlashCardScreen.gameId, entry(15000));
      expect(unlockedLevels(learnLevels, s), [true, true, false]);
      // Level 3 opens at 15,000 in Note Flash, but has no game yet.
      await s.submit(noteFlash.id, entry(15000));
      expect(unlockedLevels(learnLevels, s), [true, true, true]);
    });

    testWidgets('the hub shows progress toward the next level', (tester) async {
      tall(tester);
      final s = await freshScores();
      await s.submit(FlashCardScreen.gameId, entry(10800));
      await tester.pumpWidget(MaterialApp(
        home: LearnScreen(
          learn: LearnContext(
              frames: const Stream.empty(), cal: SlideCalibration(), scores: s),
        ),
      ));
      expect(find.text('Position Flash'), findsOneWidget);
      expect(find.text('10800'), findsOneWidget); // high score
      expect(find.text('Score 15,000 in Position Flash to unlock'), findsOneWidget);
      expect(find.text('10,800 / 15,000'), findsOneWidget);
      expect(find.text('Unlocks from Level 2'), findsNothing);
      expect(find.textContaining('Unlocks from Level 2'), findsOneWidget);
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
      final play = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Play'));
      expect(play.onPressed, isNull);
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
    expect(find.text('${best.score}'), findsOneWidget);

    await tester.tap(find.text('High scores'));
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
    expect(find.text('LEVEL 2 · READING NOTES'), findsOneWidget);

    Future<void> slideTo(double semis) async {
      frames.add((t: DateTime.now(), mm: mmAtSemis(cal, semis), freq: null));
      await tester.pump();
    }

    final deck = NoteDeck();
    FlashCard shown() => deck.cards.firstWhere((c) => tester
        .widgetList<Text>(find.byType(Text))
        .any((t) => t.style?.fontSize == 30 && t.data == c.label));

    await slideTo(0);
    await tester.tap(find.text('Start'));
    await tester.pump();
    now += 3100;
    await slideTo(0);
    expect(find.byType(BassClefNote), findsOneWidget);
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
}

