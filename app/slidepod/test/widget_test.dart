import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slidepod/main.dart';

void main() {
  testWidgets('App renders without errors', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(
      home: HomePage(autoMock: false),
    ));
    expect(find.text('Connect'), findsOneWidget); // the pod pill
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('no calibration prompt for the mock, only for a real pod',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: HomePage(autoMock: true)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Calibrate your slide so positions read true'),
        findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Easy mode shows only the position and tuning feedback',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'ui_easy': true});
    await tester.pumpWidget(const MaterialApp(home: HomePage(autoMock: true)));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Position'), findsOneWidget);
    expect(find.text('Raw'), findsNothing); // no raw data footer

    // Switching to Full brings the detail back, and is remembered.
    await tester.tap(find.text('Detail'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Raw'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ui_easy'), isFalse);

    // Stop the mock's timers before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tabs: Live, Takes, Learn; Easy mode has a practice card',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'ui_easy': true});
    await tester.pumpWidget(const MaterialApp(home: HomePage(autoMock: true)));
    await tester.pump(const Duration(seconds: 2));
    // Prefs are cached across tests (an earlier one picked Full): pick Easy.
    await tester.tap(find.text('Simple'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Practise your positions'), findsOneWidget);

    // Closing it hides it, says where the games are, and remembers.
    await tester.tap(find.byTooltip('Hide this card'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Practise your positions'), findsNothing);
    expect(find.text('Hidden. The games are always in Learn.'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ui_practice_card_hidden'), isTrue);

    // Undo brings it back (once the snackbar has slid in).
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Undo'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Practise your positions'), findsOneWidget);

    // The Learn tab lists the games.
    await tester.tap(find.text('Learn'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Position Flash'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
