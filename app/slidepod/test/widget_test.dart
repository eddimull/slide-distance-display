import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/main.dart';

void main() {
  testWidgets('App renders without errors', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: HomePage(autoMock: false),
    ));
    expect(find.text('Tap to connect'), findsOneWidget);
  });
}
