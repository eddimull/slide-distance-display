import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'account.dart';
import 'ui/top_bar.dart';
import 'ui/seventh.dart';
import 'account_screen.dart';
import 'firmware_update.dart';
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

  /// Opens calibration (the sheet closes first); null hides the row.
  final VoidCallback? onCalibrate;

  /// Opens the firmware update to the build given (the sheet closes
  /// first); null: no updates offered.
  final void Function(FirmwareBuild)? onUpdate;

  /// Where updates come from (tests).
  final FirmwareCatalog? catalog;
  const PodSheet({
    super.key,
    required this.source,
    required this.account,
    required this.onDisconnect,
    this.onCalibrate,
    this.onUpdate,
    this.catalog,
  });

  @override
  State<PodSheet> createState() => _PodSheetState();
}

class _PodSheetState extends State<PodSheet> {
  static final _noAccount = ValueNotifier(0);
  bool _busy = false;
  String? _message;

  /// A newer build for this pod, once the manifest is in.
  FirmwareBuild? _update;

  /// Newer firmware exists, but this pod's can't take it over Bluetooth.
  bool _usbOnly = false;

  PodInfo? get _pod => widget.source.pod;

  @override
  void initState() {
    super.initState();
    if (widget.onUpdate != null) _checkFirmware();
  }

  Future<void> _checkFirmware() async {
    final m = await (widget.catalog ?? FirmwareCatalog.shared).manifest();
    final pod = _pod;
    if (!mounted || m == null || pod == null) return;
    final b = m.updateFor(pod.hardware, pod.firmware);
    setState(() {
      _update = pod.ota ? b : null;
      _usbOnly = b != null && !pod.ota;
    });
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
    final power = widget.source.power;
    return ListenableBuilder(
      listenable: account ?? _noAccount,
      builder: (context, _) {
        final linked = pod == null ? null : account?.linkedPod(pod.serial);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Seventh.gutter, 0, Seventh.gutter, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The pod, and renaming it.
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                          color: Seventh.raised,
                          borderRadius: BorderRadius.circular(16)),
                      child: const Icon(Icons.sensors, color: Seventh.inTune),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pod?.name ?? 'SlidePod',
                              overflow: TextOverflow.ellipsis,
                              style: Seventh.screenTitle.copyWith(fontSize: 22)),
                          const Text('Connected',
                              style: TextStyle(fontSize: 13, color: Seventh.inTune)),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          textStyle: const TextStyle(
                              fontFamily: Seventh.bodyFont,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      onPressed: pod == null || _busy ? null : _rename,
                      child: const Text('Rename'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _Tile(
                        label: 'Battery',
                        value: power == null
                            ? '–'
                            : power.usb && power.charged
                                ? 'Full'
                                : power.percent == null
                                    ? '–'
                                    : '${power.percent}',
                        unit: power?.percent != null && !(power!.usb && power.charged)
                            ? '\u00A0%'
                            : null,
                        lead: power == null
                            ? null
                            : BatteryGlyph(
                                percent: power.percent ?? 0,
                                charging: power.usb,
                                color: power.usb
                                    ? Seventh.inTune
                                    : power.low
                                        ? Seventh.off
                                        : Seventh.body),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: _Tile(label: 'Code', value: pod?.code ?? '–')),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _Tile(label: 'Firmware', value: pod?.firmware ?? 'old')),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                      color: Seventh.raised,
                      borderRadius: BorderRadius.circular(Seventh.cardRadius)),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.light_mode_outlined,
                        title: 'Blink',
                        trailing: 'Which pod is this?',
                        onTap: _busy ? null : () => _run(widget.source.blink),
                      ),
                      if (widget.onCalibrate != null)
                        _Row(
                          icon: Icons.tune,
                          title: 'Recalibrate',
                          divider: true,
                          onTap: _busy
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  widget.onCalibrate!();
                                },
                        ),
                      if (_update case final b?)
                        _Row(
                          icon: Icons.system_update_alt,
                          iconColor: Seventh.accent,
                          title: 'Update firmware',
                          trailing: b.version,
                          trailingColor: Seventh.accent,
                          divider: true,
                          onTap: _busy
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  widget.onUpdate!(b);
                                },
                        ),
                      if (pod != null && account != null && account.available)
                        if (widget.source.isMock)
                          const _Row(
                              icon: Icons.person_outline,
                              title: 'Mock pods can\'t be linked',
                              divider: true)
                        else if (!account.signedIn)
                          _Row(
                            icon: Icons.person_outline,
                            title: 'Sign in to link it to your account',
                            divider: true,
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => AccountScreen(account: account))),
                          )
                        else if (linked != null)
                          _Row(
                            icon: Icons.person,
                            iconColor: Seventh.inTune,
                            title: 'On your account',
                            trailing: 'Remove',
                            trailingColor: Seventh.accent,
                            divider: true,
                            onTap: _busy ? null : () => _run(() => account.unlinkPod(linked)),
                          )
                        else
                          _Row(
                            icon: Icons.person_add_alt,
                            iconColor: Seventh.accent,
                            title: 'Add to my account',
                            divider: true,
                            onTap: _busy
                                ? null
                                : () => _run(() async {
                                      await account.linkPod(pod);
                                      _message = 'Linked to your account.';
                                    }),
                          ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  pod == null
                      ? 'Older firmware: update it to rename this pod or link it to your account.'
                      : [
                          'Serial ${pod.serial} · firmware ${pod.firmware ?? '–'}',
                          if (_usbOnly)
                            'Newer firmware needs one update by USB first; after that it updates over Bluetooth.',
                        ].join('\n'),
                  style: Seventh.small,
                ),
                if (_message != null) ...[
                  const SizedBox(height: 10),
                  Text(_message!, style: const TextStyle(fontSize: 14, color: Seventh.body)),
                ],
                const SizedBox(height: 16),
                OutlinedButton(
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

class _Tile extends StatelessWidget {
  final String label, value;
  final String? unit;
  final Widget? lead;
  const _Tile({required this.label, required this.value, this.unit, this.lead});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Seventh.raised, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (lead != null) ...[lead!, const SizedBox(width: 6)],
                Flexible(
                  child: Text.rich(
                    TextSpan(text: value, children: [
                      if (unit != null)
                        TextSpan(
                            text: unit,
                            style: const TextStyle(fontSize: 12, color: Seventh.muted)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Seventh.mono.copyWith(
                        fontSize: 18, fontWeight: FontWeight.w600, color: Seventh.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: Seventh.muted)),
          ],
        ),
      );
}

class _Row extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? trailing;
  final Color trailingColor;
  final bool divider;
  final VoidCallback? onTap;
  const _Row({
    required this.icon,
    required this.title,
    this.iconColor = Seventh.body,
    this.trailing,
    this.trailingColor = Seventh.muted,
    this.divider = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              border: divider
                  ? const Border(top: BorderSide(color: Seventh.line))
                  : null),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 15, color: Seventh.text))),
              if (trailing != null)
                Text(trailing!,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: trailingColor == Seventh.muted
                            ? FontWeight.w400
                            : FontWeight.w600,
                        color: trailingColor)),
            ],
          ),
        ),
      );
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
