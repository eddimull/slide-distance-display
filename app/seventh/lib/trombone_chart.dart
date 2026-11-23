import 'dart:math';

class ChartNote {
  final int partial;
  final String name;
  final int midi;
  final double freq;

  const ChartNote({
    required this.partial,
    required this.name,
    required this.midi,
    required this.freq,
  });
}

class TromboneChart {
  static const _noteNames = [
    'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B'
  ];

  // MIDI note for each partial (1–8) in first position (Bb tenor trombone)
  static const _pos1Midi = [34, 46, 53, 58, 62, 65, 68, 70];

  static int midiAt(int partial, int position) =>
      _pos1Midi[partial - 1] - (position - 1);

  static String noteName(int midi) {
    final note = midi % 12;
    final octave = (midi ~/ 12) - 1;
    return '${_noteNames[note]}$octave';
  }

  static double frequency(int midi) => 440.0 * pow(2, (midi - 69) / 12);

  /// All notes available at a given slide position (partials 1–8).
  static List<ChartNote> notesAt(int position) {
    return List.generate(8, (i) {
      final p = i + 1;
      final m = midiAt(p, position);
      return ChartNote(
        partial: p,
        name: noteName(m),
        midi: m,
        freq: frequency(m),
      );
    });
  }

  /// Find the closest note to a given frequency across all partials
  /// at a slide position. Returns the note and cents offset.
  static (ChartNote note, double cents) closestAt(int position, double freq) {
    final notes = notesAt(position);
    ChartNote best = notes.first;
    double bestCents = _centsFrom(notes.first.freq, freq).abs();
    for (final n in notes.skip(1)) {
      final c = _centsFrom(n.freq, freq).abs();
      if (c < bestCents) {
        best = n;
        bestCents = c;
      }
    }
    return (best, _centsFrom(best.freq, freq));
  }

  static double _centsFrom(double reference, double actual) =>
      1200 * log(actual / reference) / ln2;
}
