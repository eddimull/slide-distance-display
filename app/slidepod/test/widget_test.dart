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
    expect(find.text('Tap to connect'), findsOneWidget);
  });

  testWidgets('Easy mode shows only the position and tuning feedback',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'ui_easy': true});
    await tester.pumpWidget(const MaterialApp(home: HomePage(autoMock: true)));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Position'), findsOneWidget);
    expect(find.text('Raw'), findsNothing); // no raw data footer

    // Switching to Full brings the detail back, and is remembered.
    await tester.tap(find.text('Full'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Raw'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ui_easy'), isFalse);

    // Stop the mock's timers before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
