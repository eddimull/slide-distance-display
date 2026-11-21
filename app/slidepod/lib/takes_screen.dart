import 'package:flutter/material.dart';

import 'dart:math' as math;

import 'review_screen.dart';
import 'slide_calibration.dart';
import 'take.dart';
import 'take_analysis.dart';
import 'take_stats.dart';
import 'take_store.dart';
import 'take_style.dart';

/// Recorded takes, newest first. Record starts a new one (through
/// [onRecord], which owns the live readings); a finished take opens in
/// review.
class TakesScreen extends StatefulWidget {
  final TakeStore store;
  final SlideCalibration cal;

  /// Records a take (titled [title] when given) and returns it, or null if
  /// it was discarded.
  final Future<Take?> Function({String? title}) onRecord;

  /// False when the pod isn't connected: recording is disabled.
  final bool canRecord;

  const TakesScreen({
    super.key,
    required this.store,
    required this.cal,
    required this.onRecord,
    this.canRecord = true,
  });

  @override
  State<TakesScreen> createState() => _TakesScreenState();
}

class _TakesScreenState extends State<TakesScreen> {
  List<TakeSummary>? _takes;

  /// Analysed once per take per run of the app (takes don't change, apart
  /// from their title).
  static final _stats = <String, TakeStats>{};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await widget.store.list();
    if (!mounted) return;
    setState(() => _takes = list);
    // Fill in each row's numbers, newest first, a take at a time.
    for (final t in list) {
      if (_stats.containsKey(t.id)) continue;
      final take = await widget.store.load(t.id);
      if (take == null) continue;
      _stats[t.id] = TakeStats.of(TakeAnalysis.analyze(take, widget.cal));
      if (mounted) setState(() {});
    }
  }

  Future<void> _open(String id) async {
    final take = await widget.store.load(id);
    if (take == null || !mounted) return;
    await _review(take);
  }

  Future<void> _review(Take take) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReviewScreen(
        take: take,
        cal: widget.cal,
        store: widget.store,
        onRecordAgain:
            widget.canRecord ? (title) => widget.onRecord(title: title) : null,
      ),
    ));
    _refresh(); // it may have been renamed
  }

  Future<void> _record() async {
    final take = await widget.onRecord();
    if (!mounted) return;
    await _refresh();
    if (take != null && mounted) await _review(take);
  }

  Future<bool> _confirmDelete(TakeSummary t) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete "${t.title}"?'),
          content: const Text('The recording and its analysis are removed.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete')),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final takes = _takes;
    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        title: const Text('Takes',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: widget.canRecord ? _record : null,
        backgroundColor:
            widget.canRecord ? TakeStyle.record : TakeStyle.chip,
        foregroundColor: widget.canRecord ? Colors.white : TakeStyle.muted,
        icon: const Icon(Icons.fiber_manual_record),
        label: Text(widget.canRecord ? 'Record take' : 'Connect to record'),
      ),
      body: takes == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
              children: [
                if (!widget.store.persistent)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                        'Takes are kept until the page is closed (no storage '
                        'or audio in the web build).',
                        style: TextStyle(fontSize: 12, color: TakeStyle.muted)),
                  ),
                if (_trend(takes) case final trend?) _TrendCard(trend),
                if (takes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Text(
                      'No takes yet.\nRecord one, then slow it down to see '
                      'where the slide and the pitch went.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: TakeStyle.muted, height: 1.5),
                    ),
                  )
                else
                  Container(
                    decoration: BoxDecoration(
                        color: TakeStyle.card,
                        borderRadius: BorderRadius.circular(16)),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final (i, t) in takes.indexed)
                          Dismissible(
                            key: ValueKey(t.id),
                            direction: DismissDirection.endToStart,
                            confirmDismiss: (_) => _confirmDelete(t),
                            onDismissed: (_) async {
                              setState(() => takes.remove(t));
                              _stats.remove(t.id);
                              await widget.store.delete(t.id);
                            },
                            background: Container(
                              color: TakeStyle.bad,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: const Icon(Icons.delete_outline,
                                  color: Colors.white),
                            ),
                            child: _TakeRow(t,
                                stats: _stats[t.id],
                                divider: i > 0,
                                onTap: () => _open(t.id)),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

TakeTrend? _trend(List<TakeSummary> takes) => trendFor([
      for (final t in takes)
        if (_TakesScreenState._stats[t.id] case final s?) (t, s),
    ]);

/// How the newest take's piece has gone over its recent takes.
class _TrendCard extends StatelessWidget {
  final TakeTrend trend;
  const _TrendCard(this.trend);

  @override
  Widget build(BuildContext context) {
    final change = trend.change;
    final better = change < -0.5, worse = change > 0.5;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
          color: TakeStyle.card, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    '${trend.title.toUpperCase()} · LAST ${trend.avgCents.length} TAKES',
                    overflow: TextOverflow.ellipsis,
                    style: TakeStyle.sectionLabel),
              ),
              Text(
                  '${change > 0 ? '+' : change < 0 ? '−' : '±'}'
                  '${change.abs().toStringAsFixed(1)}¢ avg',
                  style: TextStyle(
                      fontSize: 12,
                      color: better
                          ? const Color(0xFF8FD694)
                          : worse
                              ? const Color(0xFFFFCC80)
                              : TakeStyle.muted)),
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
            label: 'Average deviation from '
                '${trend.avgCents.first.toStringAsFixed(1)} to '
                '${trend.avgCents.last.toStringAsFixed(1)} cents',
            child: CustomPaint(
              size: const Size(double.infinity, 64),
              painter: _TrendPainter(trend.avgCents),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<double> values;
  _TrendPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    final hi = values.reduce(math.max), lo = values.reduce(math.min);
    final span = math.max(4.0, hi - lo);
    const bottom = 14.0;
    final h = size.height - bottom;
    double x(int i) => 6 + (size.width - 12) * i / (values.length - 1);
    double y(double v) => 6 + (h - 12) * (1 - (v - (hi - span)) / span);
    canvas.drawLine(Offset(0, h), Offset(size.width, h),
        Paint()..color = TakeStyle.line);
    final path = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i]));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = TakeStyle.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(Offset(x(i), y(values[i])),
          i == values.length - 1 ? 4 : 3, Paint()..color = TakeStyle.accent);
    }
    for (final (i, align) in [(0, 0.0), (values.length - 1, 1.0)]) {
      final tp = TextPainter(
        text: TextSpan(
            text: '${values[i].toStringAsFixed(1)}¢',
            style: TakeStyle.mono.copyWith(fontSize: 9, color: TakeStyle.muted)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((size.width - tp.width) * align, h + 2));
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.values != values;
}

/// The slide over a take, as a thumbnail.
class _SketchPainter extends CustomPainter {
  final List<(double, double)> sketch;
  _SketchPainter(this.sketch);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
        Paint()..color = TakeStyle.chip);
    if (sketch.length < 2) return;
    double x(double f) => 4 + (size.width - 8) * f;
    double y(double s) => 4 + (size.height - 8) * s.clamp(0.0, 6.0) / 6;
    final path = Path()..moveTo(x(sketch[0].$1), y(sketch[0].$2));
    for (final (f, s) in sketch.skip(1)) {
      path.lineTo(x(f), y(s));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = TakeStyle.body
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_SketchPainter old) => old.sketch != sketch;
}

class _TakeRow extends StatelessWidget {
  final TakeSummary take;
  final TakeStats? stats;
  final bool divider;
  final VoidCallback onTap;
  const _TakeRow(this.take,
      {this.stats, required this.divider, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = take.started;
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final today =
        s.year == now.year && s.month == now.month && s.day == now.day;
    final when = today
        ? 'Today ${two(s.hour)}:${two(s.minute)}'
        : '${s.year}-${two(s.month)}-${two(s.day)} ${two(s.hour)}:${two(s.minute)}';
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          border: divider
              ? const Border(top: BorderSide(color: TakeStyle.chip))
              : null,
        ),
        child: Row(
          children: [
            CustomPaint(
              size: const Size(56, 36),
              painter: _SketchPainter(stats?.sketch ?? const []),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(take.title,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: TakeStyle.text)),
                  const SizedBox(height: 2),
                  Text(
                      '$when · ${(take.durationMs / 1000).toStringAsFixed(1)} s',
                      style:
                          const TextStyle(fontSize: 12, color: TakeStyle.muted)),
                ],
              ),
            ),
            if (stats != null && stats!.notes > 0)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${stats!.inTune}/${stats!.notes}',
                      style: TakeStyle.mono.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: stats!.inTuneRatio >= 0.65
                              ? const Color(0xFF8FD694)
                              : const Color(0xFFFFCC80))),
                  const Text('in tune',
                      style: TextStyle(fontSize: 11, color: TakeStyle.muted)),
                ],
              ),
            const Icon(Icons.chevron_right, color: TakeStyle.muted),
          ],
        ),
      ),
    );
  }
}
