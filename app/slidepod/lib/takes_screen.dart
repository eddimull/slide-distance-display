import 'package:flutter/material.dart';

import 'review_screen.dart';
import 'slide_calibration.dart';
import 'take.dart';
import 'take_store.dart';
import 'take_style.dart';

/// Recorded takes, newest first. Record starts a new one (through
/// [onRecord], which owns the live readings); a finished take opens in
/// review.
class TakesScreen extends StatefulWidget {
  final TakeStore store;
  final SlideCalibration cal;

  /// Records a take and returns it, or null if it was discarded.
  final Future<Take?> Function() onRecord;

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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await widget.store.list();
    if (mounted) setState(() => _takes = list);
  }

  Future<void> _open(String id) async {
    final take = await widget.store.load(id);
    if (take == null || !mounted) return;
    await _review(take);
  }

  Future<void> _review(Take take) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          ReviewScreen(take: take, cal: widget.cal, store: widget.store),
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
                                divider: i > 0, onTap: () => _open(t.id)),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _TakeRow extends StatelessWidget {
  final TakeSummary take;
  final bool divider;
  final VoidCallback onTap;
  const _TakeRow(this.take, {required this.divider, required this.onTap});

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
            const Icon(Icons.chevron_right, color: TakeStyle.muted),
          ],
        ),
      ),
    );
  }
}
