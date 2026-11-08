import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'slidepod_ble.dart';

void main() => runApp(const SlidePodApp());

class SlidePodApp extends StatelessWidget {
  const SlidePodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SlidePod',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1565C0),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _ble = SlidePodBle();
  SlideData _data = const SlideData(rawMm: 0, filtMm: 0, position: 0);
  bool _scanning = false;
  bool _connected = false;
  String _status = 'Tap to connect';

  @override
  void initState() {
    super.initState();
    _ble.dataStream.listen((d) {
      if (mounted) setState(() => _data = d);
    });
    _ble.connectionStream.listen((c) {
      if (mounted) {
        setState(() {
          _connected = c;
          _status = c ? 'Connected' : 'Disconnected';
        });
      }
    });
  }

  @override
  void dispose() {
    _ble.dispose();
    super.dispose();
  }

  Future<void> _scanAndConnect() async {
    if (_connected) {
      await _ble.disconnect();
      return;
    }

    setState(() {
      _scanning = true;
      _status = 'Scanning...';
    });

    try {
      final results = await _ble.scan();

      if (results.isEmpty) {
        setState(() {
          _scanning = false;
          _status = 'No SlidePod found';
        });
        return;
      }

      if (results.length == 1) {
        setState(() => _status = 'Connecting...');
        await _ble.connect(results.first.device);
      } else {
        if (!mounted) return;
        final device = await _showDevicePicker(results);
        if (device != null) {
          setState(() => _status = 'Connecting...');
          await _ble.connect(device);
        } else {
          setState(() => _status = 'Tap to connect');
        }
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<BluetoothDevice?> _showDevicePicker(List<ScanResult> results) {
    return showModalBottomSheet<BluetoothDevice>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Select SlidePod',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          for (final r in results)
            ListTile(
              title: Text(r.device.platformName.isNotEmpty
                  ? r.device.platformName
                  : 'SlidePod'),
              subtitle: Text(r.device.remoteId.str),
              trailing: Text('${r.rssi} dBm'),
              onTap: () => Navigator.pop(ctx, r.device),
            ),
        ],
      ),
    );
  }

  int _positionToSlide(double pos) {
    final raw = pos * 7.0;
    return raw.round().clamp(1, 7);
  }

  @override
  Widget build(BuildContext context) {
    final slideNum = _connected ? _positionToSlide(_data.position) : null;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              const SizedBox(height: 24),
              // Connection button
              GestureDetector(
                onTap: _scanning ? null : _scanAndConnect,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _connected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth,
                      color: _connected ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _status,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (_scanning) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),

              const Spacer(),

              // Slide position number
              Text(
                slideNum != null ? '$slideNum' : '-',
                style: const TextStyle(
                  fontSize: 160,
                  fontWeight: FontWeight.w200,
                  height: 1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                slideNum != null ? 'Position' : 'Not connected',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.grey,
                    ),
              ),

              const Spacer(),

              // Slide position bar and data
              if (_connected) ...[
                _SlideBar(position: _data.position),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _DataChip(label: 'Raw', value: '${_data.rawMm} mm'),
                    _DataChip(
                        label: 'Filtered', value: '${_data.filtMm} mm'),
                    _DataChip(
                        label: 'Position',
                        value: _data.position.toStringAsFixed(3)),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SlideBar extends StatelessWidget {
  final double position;
  const _SlideBar({required this.position});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(7, (i) {
              final pos = i / 6.0;
              final active = (position - pos).abs() < 0.08;
              return Text(
                '${i + 1}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  color: active ? Colors.blue : Colors.grey,
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: LinearProgressIndicator(
              value: position.clamp(0.0, 1.0),
              backgroundColor: Colors.grey.shade800,
              valueColor: const AlwaysStoppedAnimation(Colors.blue),
            ),
          ),
        ),
      ],
    );
  }
}

class _DataChip extends StatelessWidget {
  final String label;
  final String value;
  const _DataChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
