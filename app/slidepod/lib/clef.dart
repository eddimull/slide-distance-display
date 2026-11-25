/// The clefs a trombone reads: bass, and the C clefs (tenor and alto).
enum Clef {
  bass('Bass clef', 2 * 7 + 4, 6), // lines G2 B2 D3 F3 A3; F clef on the 4th
  tenor('Tenor clef', 3 * 7 + 1, 6), // lines D3 F3 A3 C4 E4; C clef on the 4th
  alto('Alto clef', 3 * 7 + 3, 4); // lines F3 A3 C4 E4 G4; C clef on the 3rd

  final String label;

  /// Staff step ([diatonic]) of the bottom line.
  final int bottomLine;

  /// Steps above the bottom line of the line the clef names (F or C).
  final int clefLine;

  const Clef(this.label, this.bottomLine, this.clefLine);

  int get topLine => bottomLine + 8;
  int get middleLine => bottomLine + 4;

  /// Steps of [midi] above this clef's bottom line (0 = on it; 8 = the top
  /// line; negative below the staff).
  int offset(int midi) => diatonic(midi) - bottomLine;

  /// Ledger lines [midi] needs, as offsets from the bottom line.
  List<int> ledgers(int midi) {
    final o = offset(midi);
    return [
      for (var l = 10; l <= o; l += 2) l,
      for (var l = -2; l >= o; l -= 2) l,
    ];
  }

  // Letter of each semitone, spelled with flats (D♭ sits on D's place).
  static const _letter = [0, 1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 6];
  static const _flat = [false, true, false, true, false, false, true, false, true, false, true, false];

  /// Staff steps (lines and spaces) above C0 for [midi]: C=0, D=1 … B=6.
  static int diatonic(int midi) => (midi ~/ 12 - 1) * 7 + _letter[midi % 12];
  static bool isFlat(int midi) => _flat[midi % 12];
}
