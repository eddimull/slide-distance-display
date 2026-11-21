import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/take.dart';
import 'package:slidepod/take_export.dart';

import 'synth_take.dart';

void main() {
  test('CSV: a header and a row per note, with the move into it', () {
    final lines = takeCsv(synthScale()).trim().split('\n');
    final head = lines.first.split(',');
    expect(lines, hasLength(9));
    final rows = [
      for (final l in lines.skip(1)) Map.fromIterables(head, l.split(',')),
    ];
    expect(rows.map((r) => r['note']),
        ['Bb3', 'C4', 'D4', 'Eb4', 'F4', 'G4', 'A4', 'Bb4']);
    final eb = rows[3];
    expect(eb['cause'], 'slide');
    expect(eb['target_position'], '3.02');
    expect(eb['shift_result'], 'overshot');
    expect(double.parse(eb['peak_error']!), closeTo(0.35, 0.03));
    expect(rows[0]['shift_result'], ''); // first note: no move
    expect(rows[5]['late_slide'], 'yes'); // G4
    for (final r in rows) {
      expect(r.length, head.length);
    }
  });

  test('export names are safe file names', () {
    Take named(String t) =>
        Take(id: 'id1', title: t, started: DateTime(2026), frames: const []);
    expect(exportName(named('B♭ major scale')), 'B-major-scale');
    expect(exportName(named('Rochut No. 1, bars 1–8')), 'Rochut-No-1-bars-1-8');
    expect(exportName(named('♭♭')), 'id1');
  });
}
