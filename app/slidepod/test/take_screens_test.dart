import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/gliss_take.dart';
import 'package:slidepod/record_screen.dart';
import 'package:slidepod/review_screen.dart';
import 'package:slidepod/take.dart';
import 'package:slidepod/take_store.dart';
import 'package:slidepod/takes_screen.dart';

import 'synth_take.dart';

Future<void> tall(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('review: summary, moves, notes; tap a note to loop it',
      (tester) async {
    await tall(tester);
    await tester.pumpWidget(MaterialApp(
        home: ReviewScreen(take: synthScaleTake(), cal: cal)));
    await tester.pump();

    expect(find.text('Slide moves'), findsOneWidget);
    expect(find.text('Overshot'), findsWidgets); // tile + tags
    expect(find.text('Stopped short'), findsOneWidget);
    expect(find.text('E♭4'), findsWidgets);
    expect(find.textContaining('No audio with this take'), findsOneWidget);

    // The notes list row for E♭4 (the last of its matches: moves list
    // first says "into E♭4").
    await tester.tap(find.text('E♭4').last);
    await tester.pump();
    expect(find.text('Looping E♭4'), findsOneWidget);
  });

  testWidgets('review: speed steps by 0.05 and presets jump', (tester) async {
    await tall(tester);
    await tester.pumpWidget(MaterialApp(
        home: ReviewScreen(take: synthScaleTake(), cal: cal)));
    await tester.pump();
    expect(find.text('0.50×'), findsOneWidget);
    await tester.tap(find.byTooltip('Slower'));
    await tester.pump();
    expect(find.text('0.45×'), findsOneWidget);
    await tester.tap(find.text('1.25×'));
    await tester.pump();
    expect(find.text('1.25×'), findsWidgets);
    await tester.tap(find.byTooltip('Faster'));
    await tester.tap(find.byTooltip('Faster'));
    await tester.pump();
    expect(find.text('1.35×'), findsOneWidget);
  });

  testWidgets('review: playing without audio moves the playhead',
      (tester) async {
    await tall(tester);
    await tester.pumpWidget(MaterialApp(
        home: ReviewScreen(take: synthScaleTake(), cal: cal)));
    await tester.pump();
    expect(find.text('0:00.0'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2)); // 1 s of take at 0.5×
    expect(find.text('0:00.0'), findsNothing);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
  });

  testWidgets('record: stop saves the take and pops it', (tester) async {
    final frames = StreamController<CalFrame>.broadcast();
    final store = MemoryTakeStore();
    Take? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await Navigator.of(context).push<Take>(MaterialPageRoute(
              builder: (_) => RecordScreen(
                frames: frames.stream,
                pcm: const Stream<Uint8List>.empty(),
                sampleRate: 16000,
                cal: cal,
                store: store,
              ),
            ));
          },
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    // The recording clock ticks, so nothing ever "settles" while it runs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    for (var i = 0; i < 5; i++) {
      frames.add((t: DateTime.now(), mm: 300.0, freq: 233.08));
    }
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('B♭3'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Stop and review'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(result, isNotNull);
    expect(result!.frames, hasLength(5));
    expect((await store.list()).single.id, result!.id);
    await frames.close();
  });

  testWidgets('takes: record from the list opens the review', (tester) async {
    await tall(tester);
    final store = MemoryTakeStore();
    await tester.pumpWidget(MaterialApp(
      home: TakesScreen(
        store: store,
        cal: cal,
        onRecord: () async {
          final t = synthScaleTake()..title = 'Scale';
          await store.save(t, null);
          return t;
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('No takes yet'), findsOneWidget);

    await tester.tap(find.text('Record take'));
    await tester.pumpAndSettle();
    expect(find.text('Slide moves'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Scale'), findsOneWidget);
  });
}
