import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/note_detail_screen.dart';
import 'package:slidepod/take.dart';
import 'package:slidepod/take_analysis.dart';
import 'package:slidepod/take_stats.dart';
import 'package:slidepod/take_store.dart';
import 'package:slidepod/takes_screen.dart';

import 'synth_take.dart';

TakeStats stats(double cents, {int notes = 8}) => TakeStats(
    notes: notes,
    inTune: 4,
    avgAbsCents: cents,
    shifts: 7,
    cleanShifts: 3,
    sketch: const []);

TakeSummary summary(String title, int minute) => (
      id: '$title-$minute',
      title: title,
      started: DateTime(2026, 11, 21, 9, minute),
      durationMs: 9000,
    );

/// The synthetic scale as another take of the same piece, [minute] past 9.
Take scaleAt(int minute) {
  final t = synthScaleTake();
  return Take(
      id: 'scale-$minute',
      title: 'Scale',
      started: DateTime(2026, 11, 21, 9, minute),
      frames: t.frames);
}

void main() {
  test('stats from an analysis', () {
    final s = TakeStats.of(synthScale());
    expect(s.notes, 8);
    expect(s.inTune, synthScale().inTuneCount);
    expect(s.sketch.length, inInclusiveRange(40, 50));
    expect(s.sketch.first.$1, 0);
  });

  group('trend', () {
    test('the newest take\'s piece, oldest first, last seven', () {
      final takes = [
        for (var i = 0; i < 9; i++) (summary('Scale', i), stats(20.0 - i)),
        (summary('Etude', 5), stats(40)),
      ];
      final t = trendFor(takes)!;
      expect(t.title, 'Scale');
      expect(t.avgCents, [18, 17, 16, 15, 14, 13, 12]);
      expect(t.change, -6);
    });

    test('needs two takes with notes', () {
      expect(trendFor([(summary('Scale', 1), stats(10))]), isNull);
      expect(
          trendFor([
            (summary('Scale', 1), stats(10, notes: 0)),
            (summary('Scale', 2), stats(12)),
          ]),
          isNull);
      expect(trendFor([]), isNull);
    });
  });

  testWidgets('takes list: trend card and each take\'s score', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = MemoryTakeStore();
    for (final m in [1, 2, 3]) {
      await store.save(scaleAt(m), null);
    }
    await tester.pumpWidget(MaterialApp(
        home: TakesScreen(store: store, cal: cal, onRecord: ({title}) async => null)));
    await tester.pumpAndSettle();
    expect(find.text('SCALE · LAST 3'), findsOneWidget);
    final inTune = synthScale().inTuneCount;
    expect(find.text('$inTune/8'), findsNWidgets(3));
  });

  testWidgets('breakdown: the same note in earlier takes', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = MemoryTakeStore();
    for (final m in [1, 2, 3]) {
      await store.save(scaleAt(m), null);
    }
    final a = TakeAnalysis.analyze(scaleAt(3), cal);
    final eb = a.notes.firstWhere((n) => n.name == 'Eb4');
    await tester.pumpWidget(MaterialApp(
        home: NoteDetailScreen(analysis: a, note: eb, cal: cal, store: store)));
    await tester.pumpAndSettle();
    // Takes 1 and 2 plus this one.
    expect(find.text('This note, last 3 takes'), findsOneWidget);
  });
}
