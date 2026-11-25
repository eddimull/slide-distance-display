import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/live_position.dart';
import 'package:slidepod/trombone_chart.dart';

/// The 4th partial in [position], in tune.
double inTune(int position) =>
    TromboneChart.notesAt(position).firstWhere((n) => n.partial == 4).freq;

void main() {
  group('live position', () {
    test('silent: stays put within ±0.6, then moves', () {
      final live = LivePosition();
      expect(live.update(2.0), 3);
      expect(live.update(2.55), 3); // past halfway, still 3rd
      expect(live.update(2.59), 3);
      expect(live.update(2.65), 4); // more than 0.6 out
      expect(live.update(2.45), 4); // and back in, 4th holds too
      expect(live.update(2.35), 3);
    });

    test('an in-tune 3rd at 2.55 reads 3rd, not a sharp 4th', () {
      final live = LivePosition();
      // Coming in from 4th, where rounding alone would keep it 4th.
      expect(live.update(3.0), 4);
      expect(live.update(2.55, freq: inTune(3)), 3);
      // And the 4th's own note there reads 4th.
      expect(live.update(2.55, freq: inTune(4)), 4);
    });

    test('a note never pulls it more than 0.6 away', () {
      final live = LivePosition();
      expect(live.update(2.0, freq: inTune(5)), 3);
    });

    test('reset forgets the held position', () {
      final live = LivePosition()..update(2.55);
      live.reset();
      expect(live.update(2.55), 4);
    });
  });
}
