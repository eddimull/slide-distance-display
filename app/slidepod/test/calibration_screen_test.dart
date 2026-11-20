import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/calibration_screen.dart';
import 'package:slidepod/gliss_take.dart';
import 'package:slidepod/slide_calibration.dart';

import 'sim_horn.dart';

void main() {
  testWidgets('instructions, three glisses, then a calibration comes back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final frames = StreamController<CalFrame>.broadcast();
    final asked = <int?>[];
    SlideCalibration? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.push<SlideCalibration>(
                context,
                MaterialPageRoute(
                  builder: (_) => CalibrationScreen(
                    frames: frames.stream,
                    onListeningFor: asked.add,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Calibrate your slide'), findsOneWidget);
    expect(find.text('B♭2 → E2'), findsOneWidget);
    await tester.tap(find.text('Start calibration'));
    await tester.pump();

    var start = DateTime(2026, 11, 20);
    for (final (i, n) in SlideCalibration.glissPartials.indexed) {
      expect(
        find.text(
          'Gliss ${i + 1} of 3 · ${['2nd', '3rd', '4th'][i]} partial'
              .toUpperCase(),
        ),
        findsOneWidget,
      );
      // A rushed attempt first: the screen says so and waits for another.
      for (final f in glissFrames(
        n,
        start: start,
        sweep: const Duration(seconds: 1),
      )) {
        frames.add(f);
      }
      await tester.pump();
      expect(find.text('A bit too fast'), findsOneWidget);
      start = start.add(const Duration(seconds: 10));
      for (final f in glissFrames(n, start: start)) {
        frames.add(f);
      }
      await tester.pump();
      start = start.add(const Duration(seconds: 10));
    }

    expect(find.text('Slide calibrated'), findsOneWidget);
    expect(asked, [2, 3, 4, null]);
    await tester.tap(find.text('Start playing'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.calibrated, isTrue);
    expect(result!.glissedPartials, [2, 3, 4]);
    await frames.close();
  });
}
