import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'account.dart';
import 'pod_info.dart';
import 'seventh_api.dart';
import 'slidepod_ble.dart';

/// A pod found in a scan, as the picker shows it.
class FoundPod {
  final ScanResult result;
  final String name;
  final String? serial;
  final int rssi;
  const FoundPod(this.result, this.name, this.serial, this.rssi);

  static FoundPod of(ScanResult r) => FoundPod(
    r,
    SlidePodBle.advertisedName(r),
    SlidePodBle.advertisedSerial(r),
    r.rssi,
  );
}

/// Orders [pods] for the picker: the last one used, then the player's own,
/// then the rest, nearest (strongest signal) first within each.
List<FoundPod> sortPods(
  List<FoundPod> pods, {
  String? lastSerial,
  bool Function(String serial)? isMine,
}) {
  int rank(FoundPod p) {
    if (p.serial == null) return 2;
    if (p.serial == lastSerial) return 0;
    return (isMine?.call(p.serial!) ?? false) ? 1 : 2;
  }

  return [...pods]..sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : b.rssi.compareTo(a.rssi);
  });
}

/// Signal strength as 1–4 bars.
int signalBars(int rssi) => rssi >= -60
    ? 4
    : rssi >= -70
    ? 3
    : rssi >= -80
    ? 2
    : 1;

/// The picker shown when more than one SlidePod is in range. Pods can share
/// a name, so each row also shows the last 4 digits of its serial (what a
/// new pod's name ends in), and which is nearest.
Future<BluetoothDevice?> showPodPicker(
  BuildContext context,
  List<FoundPod> pods, {
  String? lastSerial,
  bool Function(String serial)? isMine,
}) {
  final sorted = sortPods(pods, lastSerial: lastSerial, isMine: isMine);
  final strongest = pods.map((p) => p.rssi).reduce((a, b) => a > b ? a : b);
  return showModalBottomSheet<BluetoothDevice>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Choose your SlidePod',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'The one you pick blinks white. Hold the phone near yours: '
              'the nearest is listed as such.',
            ),
          ),
          for (final p in sorted)
            ListTile(
              leading: _Bars(signalBars(p.rssi)),
              title: Text(p.name),
              subtitle: Text(
                [
                  if (p.serial != null &&
                      !p.name.endsWith(shortCode(p.serial!)))
                    shortCode(p.serial!),
                  if (p.rssi == strongest && pods.length > 1) 'Nearest',
                  if (p.serial != null && p.serial == lastSerial)
                    'Last used'
                  else if (p.serial != null &&
                      (isMine?.call(p.serial!) ?? false))
                    'Yours',
                ].join(' · '),
              ),
              onTap: () => Navigator.pop(ctx, p.result.device),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class _Bars extends StatelessWidget {
  final int bars;
  const _Bars(this.bars);

  @override
  Widget build(BuildContext context) {
    final on = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: 'Signal $bars of 4',
      child: SizedBox(
        width: 22,
        height: 18,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 1; i <= 4; i++)
              Container(
                width: 4,
                height: 4.5 * i,
                decoration: BoxDecoration(
                  color: i <= bars ? on : on.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The connected pod: its name and serial, renaming it, blinking it, and
/// linking it to the player's account.
class PodSheet extends StatefulWidget {
  final SlidePodSource source;
  final Account? account;
  final VoidCallback onDisconnect;
  const PodSheet({
    super.key,
    required this.source,
    required this.account,
    required this.onDisconnect,
  });

  @override
  State<PodSheet> createState() => _PodSheetState();
}

class _PodSheetState extends State<PodSheet> {
  static final _noAccount = ValueNotifier(0);
  bool _busy = false;
  String? _message;

  PodInfo? get _pod => widget.source.pod;

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await job();
    } on ApiException catch (e) {
      _message = e.message;
    } on ArgumentError catch (e) {
      _message = '${e.message}';
    } on StateError catch (e) {
      _message = e.message;
    } catch (_) {
      _message = 'That didn\'t work. Is the SlidePod still connected?';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename() async {
    final pod = _pod;
    if (pod == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(pod.name),
    );
    if (name == null || name == pod.name) return;
    await _run(() async {
      await widget.source.rename(name);
      final linked = widget.account?.linkedPod(pod.serial);
      if (linked != null) await widget.account!.renamePod(linked, name);
      _message = 'Renamed. Phones nearby see the new name once it disconnects.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final pod = _pod;
    final account = widget.account;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: account ?? _noAccount,
      builder: (context, _) {
        final linked = pod == null ? null : account?.linkedPod(pod.serial);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  pod?.name ?? 'SlidePod',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  pod == null
                      ? 'Older firmware: update it to rename this pod or link it to your account.'
                      : [
                          'Serial ${pod.serial}',
                          if (pod.firmware != null) 'firmware ${pod.firmware}',
                          if (widget.source.power != null)
                            'battery ${widget.source.power!.label}',
                        ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: pod == null || _busy ? null : _rename,
                        child: const Text('Rename'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(widget.source.blink),
                        child: const Text('Blink'),
                      ),
                    ),
                  ],
                ),
                if (pod != null && account != null && account.available) ...[
                  const SizedBox(height: 16),
                  if (!account.signedIn)
                    Text(
                      'Sign in (Learn → leaderboards) to link this SlidePod to your account.',
                      style: theme.textTheme.bodySmall,
                    )
                  else if (widget.source.isMock)
                    Text(
                      'Mock pods can\'t be linked.',
                      style: theme.textTheme.bodySmall,
                    )
                  else if (linked != null) ...[
                    Text(
                      'Linked to your account.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() => account.unlinkPod(linked)),
                      child: const Text('Remove from my account'),
                    ),
                  ] else
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await account.linkPod(pod);
                              _message = 'Linked to your account.';
                            }),
                      child: const Text('Add to my account'),
                    ),
                ],
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Text(_message!, style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.pop(context);
                          widget.onDisconnect();
                        },
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RenameDialog extends StatefulWidget {
  final String current;
  const _RenameDialog(this.current);

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _text = TextEditingController(text: widget.current);
  String? _problem;

  void _save() {
    final name = _text.text.trim();
    final problem = podNameProblem(name);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename SlidePod'),
    content: TextField(
      controller: _text,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _save(),
      decoration: InputDecoration(
        helperText: 'Phones nearby see this name.',
        errorText: _problem,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
