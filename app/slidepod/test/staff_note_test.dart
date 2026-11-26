import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/staff_note.dart';

void main() {
  test('staff lines: bass G2–A3, tenor D3–E4, alto F3–G4', () {
    int step(int midi) => Clef.diatonic(midi);
    expect(step(43), Clef.bass.bottomLine); // G2
    expect(step(57), Clef.bass.topLine); // A3
    expect(Clef.bass.offset(53), Clef.bass.clefLine); // F3: the F line
    expect(step(50), Clef.tenor.bottomLine); // D3
    expect(step(64), Clef.tenor.topLine); // E4
    expect(Clef.tenor.offset(60), Clef.tenor.clefLine); // C4 on the 4th line
    expect(step(53), Clef.alto.bottomLine); // F3
    expect(step(67), Clef.alto.topLine); // G4
    expect(Clef.alto.offset(60), Clef.alto.clefLine); // C4 on the middle line
    expect(Clef.alto.clefLine, 4);
    expect(step(63), step(64)); // E♭ sits on E's place
    expect(Clef.isFlat(63), isTrue);
    expect(Clef.isFlat(64), isFalse);
  });

  test('ledger lines', () {
    expect(Clef.bass.ledgers(41), isEmpty); // F2, the space below
    expect(Clef.bass.ledgers(40), [-2]); // E2
    expect(Clef.bass.ledgers(65), [10, 12]); // F4: the C4 and E4 lines
    expect(Clef.bass.ledgers(70), [10, 12, 14, 16]); // B♭4: on the 4th
    expect(Clef.tenor.ledgers(40), [-2, -4, -6]); // E2
    expect(Clef.tenor.ledgers(70), [10, 12]); // B♭4
    expect(Clef.alto.ledgers(40), [-2, -4, -6, -8]); // E2
    expect(Clef.alto.ledgers(70), [10]); // B♭4
  });

  test('stems: an octave long, and ledger notes reach the middle line', () {
    // On or above the middle line (4): down; below: up.
    expect(StaffRange.stemEnd(5), -2); // E♭3 in bass: 3.5 spaces down
    expect(StaffRange.stemEnd(4), -3);
    expect(StaffRange.stemEnd(3), 10);
    // B♭4 on the 4th ledger line above the bass staff: down to the middle.
    expect(StaffRange.stemEnd(Clef.bass.offset(70)), 4);
    // G2 two ledger lines below the tenor staff: up to the middle.
    expect(StaffRange.stemEnd(Clef.tenor.offset(43)), 4);
  });

  test('a level\'s range covers every note in every clef, and the clefs', () {
    final octave = StaffRange.of([for (var m = 46; m <= 58; m++) m], [Clef.bass]);
    final wide = StaffRange.of([for (var m = 40; m <= 70; m++) m], [Clef.bass]);
    final all = StaffRange.of([for (var m = 40; m <= 70; m++) m], Clef.values);
    expect(wide.top, greaterThanOrEqualTo(16 + 3.8)); // B♭4 and its flat
    expect(wide.bottom, lessThanOrEqualTo(-3)); // E2
    expect(all.bottom, lessThanOrEqualTo(Clef.alto.offset(40) - 1)); // alto E2
    expect(octave.height(13), lessThan(wide.height(13)));
    expect(wide.height(13), lessThanOrEqualTo(all.height(13)));
    // The tenor C clef reaches a space above the staff.
    expect(StaffRange.of([60], [Clef.tenor]).top, greaterThan(9.5));
  });

  testWidgets('draws every note E2–D♭5 in every clef', (tester) async {
    final range = StaffRange.of([for (var m = 40; m <= 73; m++) m], Clef.values);
    for (final c in Clef.values) {
      for (var m = 40; m <= 73; m++) {
        await tester.pumpWidget(MaterialApp(
            home: Center(child: StaffNote(m, clef: c, space: 10, range: range))));
        expect(tester.takeException(), isNull);
      }
    }
    expect(find.bySemanticsLabel('Alto clef note'), findsOneWidget);
  });
}
