import 'take_analysis.dart';
import 'take_store.dart';

/// The few numbers a take's row and the trend card show.
class TakeStats {
  final int notes, inTune;
  final double avgAbsCents;
  final int shifts, cleanShifts;

  /// The slide over the take, downsampled for a thumbnail: (0–1 of the
  /// way through, semitones).
  final List<(double, double)> sketch;

  const TakeStats({
    required this.notes,
    required this.inTune,
    required this.avgAbsCents,
    required this.shifts,
    required this.cleanShifts,
    required this.sketch,
  });

  double get inTuneRatio => notes == 0 ? 0 : inTune / notes;

  factory TakeStats.of(TakeAnalysis a, {int points = 48}) {
    final frames = a.take.frames.where((f) => f.semis != null).toList();
    final dur = a.take.durationMs;
    final sketch = <(double, double)>[];
    if (frames.isNotEmpty && dur > 0) {
      final step = (frames.length / points).ceil().clamp(1, 1 << 30);
      for (var i = 0; i < frames.length; i += step) {
        sketch.add((frames[i].tMs / dur, frames[i].semis!));
      }
    }
    return TakeStats(
      notes: a.notes.length,
      inTune: a.inTuneCount,
      avgAbsCents: a.avgAbsCents,
      shifts: a.shifts.length,
      cleanShifts: a.cleanShifts,
      sketch: sketch,
    );
  }
}

/// Average deviation across the latest takes of one piece, oldest first.
class TakeTrend {
  final String title;
  final List<double> avgCents;
  const TakeTrend(this.title, this.avgCents);

  /// Latest minus first: negative = getting closer to in tune.
  double get change => avgCents.last - avgCents.first;
}

/// The trend for the newest take's piece, over its last [maxTakes] takes
/// that had notes in them; null with fewer than two.
TakeTrend? trendFor(List<(TakeSummary, TakeStats)> takes, {int maxTakes = 7}) {
  if (takes.isEmpty) return null;
  final newest = takes.reduce((a, b) => a.$1.started.isAfter(b.$1.started) ? a : b);
  final same = takes
      .where((t) => t.$1.title == newest.$1.title && t.$2.notes > 0)
      .toList()
    ..sort((a, b) => a.$1.started.compareTo(b.$1.started));
  if (same.length < 2) return null;
  final last = same.sublist(same.length - (same.length < maxTakes ? same.length : maxTakes));
  return TakeTrend(newest.$1.title, [for (final t in last) t.$2.avgAbsCents]);
}
