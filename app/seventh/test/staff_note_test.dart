import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seventh/staff_note.dart';

void main() {
  test('staff steps: lines G2 B2 D3 F3 A3', () {
    int step(int midi) => BassClefNote.diatonic(midi);
    expect(step(43), BassClefNote.bottomLine); // G2
    expect(step(57), BassClefNote.topLine); // A3
    expect(step(53) - step(43), 6); // F3: fourth line
    expect(step(63), step(64)); // E♭3 sits on E's place
    expect(BassClefNote.isFlat(63), isTrue);
    expect(BassClefNote.isFlat(64), isFalse);
  });

  test('ledger lines: none for F2, two for F4', () {
    expect(BassClefNote.ledgers(41), isEmpty); // F2, the space below
    expect(BassClefNote.ledgers(57), isEmpty); // A3, the top line
    expect(BassClefNote.ledgers(60), [BassClefNote.topLine + 2]); // C4
    expect(BassClefNote.ledgers(65), hasLength(2)); // F4: C4 and E4 lines
    expect(BassClefNote.ledgers(40), [BassClefNote.bottomLine - 2]); // E2
  });

  testWidgets('draws every note F2–F4 without trouble', (tester) async {
    for (var m = 41; m <= 65; m++) {
      await tester.pumpWidget(MaterialApp(home: Center(child: BassClefNote(m))));
      expect(tester.takeException(), isNull);
    }
  });
}
