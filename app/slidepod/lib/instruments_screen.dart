import 'package:flutter/material.dart';

import 'account.dart';
import 'account_screen.dart';
import 'seventh_api.dart';
import 'ui/seventh.dart';
import 'ui/when.dart';

/// Your instruments: which one you're playing (its calibration is the one
/// in use, saved to your account), and adding, editing and removing them.
class InstrumentsScreen extends StatefulWidget {
  final Account account;

  /// Plays [i] from now on; [isNew]: just added (it takes the phone's
  /// calibration if it's the first).
  final Future<void> Function(Instrument i, {bool isNew}) onChoose;

  /// The connected pod's id on the account, if it's linked: instruments can
  /// be marked as the one it's on.
  final int? linkedPodId;

  const InstrumentsScreen({
    super.key,
    required this.account,
    required this.onChoose,
    this.linkedPodId,
  });

  @override
  State<InstrumentsScreen> createState() => _InstrumentsScreenState();
}

class _InstrumentsScreenState extends State<InstrumentsScreen> {
  bool _busy = false;
  String? _message;

  Account get _a => widget.account;

  @override
  void initState() {
    super.initState();
    _a.loadInstruments();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await job();
    } on ApiException catch (e) {
      _message = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final r = await showDialog<_Details>(
        context: context, builder: (_) => const _InstrumentDialog());
    if (r == null) return;
    await _run(() async {
      final i = await _a.addInstrument(
          name: r.name, kind: r.kind, make: r.make, podId: widget.linkedPodId);
      await widget.onChoose(i, isNew: true);
    });
  }

  Future<void> _edit(Instrument i) async {
    final r = await showDialog<_Details>(
        context: context, builder: (_) => _InstrumentDialog(initial: i));
    if (r == null) return;
    await _run(() => _a.updateInstrument(i, {'name': r.name, 'kind': r.kind, 'make': r.make}));
  }

  Future<void> _remove(Instrument i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${i.name}?'),
        content: const Text('Its calibration is removed from your account too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Seventh.offBg, foregroundColor: Seventh.off),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await _run(() => _a.removeInstrument(i));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Instruments')),
        body: ListenableBuilder(
          listenable: _a,
          builder: (context, _) {
            if (!_a.signedIn) return _signedOut(context);
            final current = _a.currentInstrument;
            final list = _a.instruments;
            return ListView(
              padding: const EdgeInsets.fromLTRB(Seventh.gutter, 8, Seventh.gutter, 24),
              children: [
                const Text(
                  'Each instrument keeps its own calibration on your account, '
                  'so it follows you to a new phone.',
                  style: Seventh.bodyText,
                ),
                const SizedBox(height: 16),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No instruments yet.',
                        textAlign: TextAlign.center, style: TextStyle(color: Seventh.muted)),
                  )
                else
                  Container(
                    decoration: BoxDecoration(
                        color: Seventh.card,
                        borderRadius: BorderRadius.circular(Seventh.cardRadius)),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final (n, i) in list.indexed)
                          _Row(
                            instrument: i,
                            current: i.id == current?.id,
                            onThisPod: widget.linkedPodId != null && i.podId == widget.linkedPodId,
                            divider: n > 0,
                            onTap: _busy || i.id == current?.id
                                ? null
                                : () => _run(() => widget.onChoose(i)),
                            onEdit: () => _edit(i),
                            onRemove: () => _remove(i),
                            onMount: widget.linkedPodId == null || i.podId == widget.linkedPodId
                                ? null
                                : () => _run(() => _a.updateInstrument(i, {'pod_id': widget.linkedPodId})),
                          ),
                      ],
                    ),
                  ),
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Text(_message!, style: const TextStyle(color: Seventh.off)),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add instrument'),
                ),
              ],
            );
          },
        ),
      );

  Widget _signedOut(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Save your instrument', style: Seventh.screenTitle),
              const SizedBox(height: 8),
              const Text(
                'Sign in to keep your instruments and their calibration on your '
                'account. Without it, the calibration stays on this phone.',
                textAlign: TextAlign.center,
                style: Seventh.bodyText,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => AccountScreen(account: _a))),
                child: const Text('Sign in'),
              ),
            ],
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  final Instrument instrument;
  final bool current, onThisPod, divider;
  final VoidCallback? onTap, onMount;
  final VoidCallback onEdit, onRemove;
  const _Row({
    required this.instrument,
    required this.current,
    required this.onThisPod,
    required this.divider,
    required this.onTap,
    required this.onEdit,
    required this.onRemove,
    required this.onMount,
  });

  @override
  Widget build(BuildContext context) {
    final i = instrument;
    final cal = i.calibrationAt;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        decoration: BoxDecoration(
          color: current ? const Color(0xFF1E2A3A) : null,
          border: divider ? const Border(top: BorderSide(color: Seventh.raised)) : null,
        ),
        child: Row(
          children: [
            Icon(current ? Icons.radio_button_checked : Icons.radio_button_off,
                color: current ? Seventh.accent : Seventh.muted, size: 22,
                semanticLabel: current ? 'Playing this one' : null),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i.name, style: Seventh.heading),
                  Text(
                    [
                      i.kindLabel,
                      if (i.make != null && i.make!.isNotEmpty) i.make!,
                      if (onThisPod) 'on this SlidePod',
                    ].join(' · '),
                    style: Seventh.small,
                  ),
                  Text(
                    cal == null ? 'Not calibrated' : 'Calibrated ${friendlyWhen(cal.toLocal())}',
                    style: TextStyle(
                        fontSize: 12, color: cal == null ? Seventh.close : Seventh.inTune),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert, color: Seventh.muted),
              onSelected: (v) => switch (v) {
                'edit' => onEdit(),
                'mount' => onMount?.call(),
                _ => onRemove(),
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (onMount != null)
                  const PopupMenuItem(value: 'mount', child: Text('It\'s on this SlidePod')),
                const PopupMenuItem(value: 'remove', child: Text('Remove')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Details {
  final String name, kind;
  final String? make;
  const _Details(this.name, this.kind, this.make);
}

class _InstrumentDialog extends StatefulWidget {
  final Instrument? initial;
  const _InstrumentDialog({this.initial});

  @override
  State<_InstrumentDialog> createState() => _InstrumentDialogState();
}

class _InstrumentDialogState extends State<_InstrumentDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _make = TextEditingController(text: widget.initial?.make ?? '');
  late String _kind = widget.initial?.kind ?? 'tenor';
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    _make.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty || name.length > 40) {
      setState(() => _problem = name.isEmpty ? 'Give it a name.' : 'That name is too long.');
      return;
    }
    final make = _make.text.trim();
    Navigator.pop(context, _Details(name, _kind, make.isEmpty ? null : make));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? 'Add instrument' : 'Edit instrument'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('instrument_name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: 'Name', hintText: 'Practice horn', errorText: _problem),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [
                for (final e in Instrument.kinds.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _make,
              decoration: const InputDecoration(
                  labelText: 'Make and model (optional)', hintText: 'Bach 42B'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}
