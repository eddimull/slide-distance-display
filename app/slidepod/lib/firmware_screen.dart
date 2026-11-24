import 'package:flutter/material.dart';

import 'firmware_update.dart';
import 'slidepod_ble.dart';
import 'ui/seventh.dart';

enum _Step { downloading, sending, installing, restarting, done, failed }

/// Updates the connected pod's firmware to [build]: download, send,
/// install (the pod checks the signature), and reconnect.
class FirmwareUpdateScreen extends StatefulWidget {
  final SlidePodSource source;
  final FirmwareBuild build;
  final FirmwareCatalog catalog;
  FirmwareUpdateScreen(
      {super.key, required this.source, required this.build, FirmwareCatalog? catalog})
      : catalog = catalog ?? FirmwareCatalog.shared;

  @override
  State<FirmwareUpdateScreen> createState() => _FirmwareUpdateScreenState();
}

class _FirmwareUpdateScreenState extends State<FirmwareUpdateScreen> {
  _Step _step = _Step.downloading;
  double _sent = 0;
  String? _error;
  final _watch = Stopwatch();

  bool get _busy => _step.index < _Step.done.index;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _step = _Step.downloading;
      _sent = 0;
      _error = null;
    });
    try {
      if (!widget.source.connected) {
        throw const OtaException('Connect to the SlidePod first.');
      }
      final image = await widget.catalog.download(widget.build);
      if (!mounted) return;
      setState(() => _step = _Step.sending);
      _watch
        ..reset()
        ..start();
      await widget.source.updateFirmware(image, widget.build, onProgress: (p) {
        if (!mounted) return;
        setState(() {
          _sent = p;
          if (p >= 1) _step = _Step.installing;
        });
      });
      _watch.stop();
      if (!mounted) return;
      setState(() => _step = _Step.restarting);
      final back = await widget.source.reconnect();
      if (!mounted) return;
      // A firmware that doesn't start is rolled back by the pod: then it's
      // still on the old version.
      final now = widget.source.pod?.firmware;
      if (back && now != null && now != widget.build.version) {
        _fail('The new firmware didn\'t start properly, so the SlidePod went '
            'back to $now. Nothing is lost; please let us know.');
        return;
      }
      setState(() {
        _step = _Step.done;
        if (!back) _error = 'Installed. Reconnect from the pod button when it\'s back.';
      });
    } on OtaException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('The connection dropped. The SlidePod keeps its old firmware.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _step = _Step.failed;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.build;
    final (String title, String detail) = switch (_step) {
      _Step.downloading => ('Downloading', 'Firmware ${b.version}'),
      _Step.sending => ('Sending to your SlidePod', _rate()),
      _Step.installing => ('Installing', 'The SlidePod checks it\'s a genuine update'),
      _Step.restarting => ('Restarting', 'Reconnecting to your SlidePod…'),
      _Step.done => ('Updated', 'Firmware ${widget.source.pod?.firmware ?? b.version}'),
      _Step.failed => ('Not updated', _error ?? ''),
    };
    final progress = switch (_step) {
      _Step.downloading => null,
      _Step.sending => _sent,
      _Step.failed => 0.0,
      _ => 1.0,
    };
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !_busy,
          title: const Text('Firmware update'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Seventh.gutter, 24, Seventh.gutter, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Center(
                  child: SizedBox(
                    width: 180,
                    height: 180,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 10,
                            strokeCap: StrokeCap.round,
                            backgroundColor: Seventh.card,
                            color: _step == _Step.failed
                                ? Seventh.off
                                : _step == _Step.done
                                    ? Seventh.inTune
                                    : Seventh.accent,
                          ),
                        ),
                        if (_step == _Step.sending)
                          Text('${(_sent * 100).floor()} %',
                              style: Seventh.mono.copyWith(
                                  fontSize: 32, fontWeight: FontWeight.w600, color: Seventh.text))
                        else
                          Icon(
                            switch (_step) {
                              _Step.done => Icons.check,
                              _Step.failed => Icons.close,
                              _ => Icons.system_update_alt,
                            },
                            size: 48,
                            color: _step == _Step.failed
                                ? Seventh.off
                                : _step == _Step.done
                                    ? Seventh.inTune
                                    : Seventh.body,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(title, textAlign: TextAlign.center, style: Seventh.screenTitle.copyWith(fontSize: 24)),
                const SizedBox(height: 6),
                Text(detail, textAlign: TextAlign.center, style: Seventh.bodyText),
                if (_step == _Step.done && _error != null) ...[
                  const SizedBox(height: 6),
                  Text(_error!, textAlign: TextAlign.center, style: Seventh.small),
                ],
                const Spacer(),
                if (_busy)
                  const Text(
                    'Keep the SlidePod switched on and near the phone. If anything '
                    'goes wrong, it keeps the firmware it has.',
                    textAlign: TextAlign.center,
                    style: Seventh.small,
                  )
                else if (_step == _Step.failed) ...[
                  FilledButton(onPressed: _run, child: const Text('Try again')),
                  const SizedBox(height: 8),
                  OutlinedButton(
                      onPressed: () => Navigator.pop(context), child: const Text('Close')),
                ] else
                  FilledButton(
                      onPressed: () => Navigator.pop(context), child: const Text('Done')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _rate() {
    final kb = _sent * widget.build.size / 1024;
    final s = _watch.elapsedMilliseconds / 1000;
    final total = widget.build.size / 1024;
    return s < 1
        ? '${total.round()} KB'
        : '${kb.round()} of ${total.round()} KB · ${(kb / s).round()} KB/s';
  }
}
