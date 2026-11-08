import 'dart:math' as math;
import 'package:flutter/foundation.dart';
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
  final bool autoMock;
  const HomePage({super.key, this.autoMock = kDebugMode});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late SlidePodSource _source = widget.autoMock ? SlidePodMock() : SlidePodBle();
  SlideData _data = const SlideData(rawMm: 0, filtMm: 0, position: 0);
  bool _scanning = false;
  bool _connected = false;
  late String _status = widget.autoMock ? 'Mock mode' : 'Tap to connect';

  // Velocity tracking
  double _velocity = 0;
  double _prevPosition = 0;
  DateTime _prevTime = DateTime.now();
  static const _velocitySmoothing = 0.3;

  // Average speed tracking (only counts time when moving > 0.5 pos/s)
  double _totalDistance = 0;
  double _activeSeconds = 0;

  @override
  void initState() {
    super.initState();
    _listen();
    if (widget.autoMock && _source.isMock) {
      _startMock();
    }
  }

  void _listen() {
    _source.dataStream.listen((d) {
      if (!mounted) return;
      final now = DateTime.now();
      final dt = now.difference(_prevTime).inMicroseconds / 1e6;
      if (dt > 0.001) {
        final delta = (d.position - _prevPosition).abs();
        final rawVel = delta / dt;
        _velocity = _velocity * (1 - _velocitySmoothing) + rawVel * _velocitySmoothing;
        if (_velocity * 7.0 >= 0.5) {
          _totalDistance += delta;
          _activeSeconds += dt;
        }
      }
      _prevPosition = d.position;
      _prevTime = now;
      setState(() => _data = d);
    });
    _source.connectionStream.listen((c) {
      if (mounted) {
        setState(() {
          _connected = c;
          _status = c
              ? (_source.isMock ? 'Mock connected' : 'Connected')
              : (_source.isMock ? 'Mock mode' : 'Disconnected');
          if (!c) {
            _velocity = 0;
            _totalDistance = 0;
            _activeSeconds = 0;
          }
        });
      }
    });
  }

  Future<void> _startMock() async {
    setState(() {
      _scanning = true;
      _status = 'Starting mock...';
    });
    await _source.connectFirst();
    if (mounted) setState(() => _scanning = false);
  }

  void _switchSource(bool useMock) {
    _source.disconnect();
    _source.dispose();
    _source = useMock ? SlidePodMock() : SlidePodBle();
    _data = const SlideData(rawMm: 0, filtMm: 0, position: 0);
    _connected = false;
    _velocity = 0;
    _totalDistance = 0;
    _activeSeconds = 0;
    _status = useMock ? 'Mock mode' : 'Tap to connect';
    _listen();
    setState(() {});
    if (useMock) _startMock();
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _scanAndConnect() async {
    if (_source.isMock) {
      if (_connected) {
        await _source.disconnect();
      } else {
        await _startMock();
      }
      return;
    }

    if (_connected) {
      await (_source as SlidePodBle).disconnect();
      return;
    }

    setState(() {
      _scanning = true;
      _status = 'Scanning...';
    });

    try {
      final ble = _source as SlidePodBle;
      final results = await ble.scan();

      if (results.isEmpty) {
        setState(() {
          _scanning = false;
          _status = 'No SlidePod found';
        });
        return;
      }

      if (results.length == 1) {
        setState(() => _status = 'Connecting...');
        await ble.connect(results.first.device);
      } else {
        if (!mounted) return;
        final device = await _showDevicePicker(results);
        if (device != null) {
          setState(() => _status = 'Connecting...');
          await ble.connect(device);
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
    final velocityPosPerSec = _velocity * 7.0;
    final avgPosPerSec = _activeSeconds > 0.5
        ? (_totalDistance * 7.0) / _activeSeconds
        : 0.0;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              const SizedBox(height: 24),
              // Connection row
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

              // Debug: mock/BLE toggle
              if (kDebugMode) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('BLE',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Switch(
                      value: _source.isMock,
                      onChanged: (v) => _switchSource(v),
                    ),
                    const Text('Mock',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ],

              const Spacer(),

              // Slide position number
              Text(
                slideNum != null ? '$slideNum' : '-',
                style: const TextStyle(
                  fontSize: 120,
                  fontWeight: FontWeight.w200,
                  height: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                slideNum != null ? 'Position' : 'Not connected',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.grey,
                    ),
              ),

              const SizedBox(height: 24),

              // Speedometers
              if (_connected) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Column(
                      children: [
                        SizedBox(
                          height: 100,
                          width: 160,
                          child: _Speedometer(
                            value: velocityPosPerSec,
                            maxValue: 5.0,
                            label: 'Speed',
                          ),
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        SizedBox(
                          height: 100,
                          width: 160,
                          child: _Speedometer(
                            value: avgPosPerSec,
                            maxValue: 5.0,
                            label: 'Avg',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Slide position bar
                _SlideBar(position: _data.position),
                const SizedBox(height: 20),

                // Raw data
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

// ── Speedometer gauge ───────────────────────────────────────────────────

class _Speedometer extends StatelessWidget {
  final double value;
  final double maxValue;
  final String label;

  const _Speedometer({
    required this.value,
    required this.maxValue,
    this.label = '',
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SpeedometerPainter(
        value: value.clamp(0, maxValue),
        maxValue: maxValue,
        label: label,
      ),
    );
  }
}

class _SpeedometerPainter extends CustomPainter {
  final double value;
  final double maxValue;
  final String label;

  _SpeedometerPainter({
    required this.value,
    required this.maxValue,
    this.label = '',
  });

  static const _green = Color(0xFF4CAF50);
  static const _amber = Color(0xFFFFC107);
  static const _deepOrange = Color(0xFFFF5722);

  Color _colorAt(double t) {
    if (t < 0.5) return Color.lerp(_green, _amber, t * 2)!;
    return Color.lerp(_amber, _deepOrange, (t - 0.5) * 2)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 220;
    final center = Offset(size.width / 2, size.height - 8 * scale);
    final radius = size.width / 2 - 14 * scale;
    const startAngle = math.pi;
    const sweepAngle = math.pi;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final arcWidth = 10 * scale;

    canvas.drawArc(
      rect, startAngle, sweepAngle, false,
      Paint()
        ..color = Colors.grey.shade800
        ..style = PaintingStyle.stroke
        ..strokeWidth = arcWidth
        ..strokeCap = StrokeCap.round,
    );

    final fraction = (value / maxValue).clamp(0.0, 1.0);
    if (fraction > 0.005) {
      const segments = 40;
      final filledSegments = (fraction * segments).ceil();
      final segSweep = sweepAngle / segments;
      for (var i = 0; i < filledSegments; i++) {
        final t = i / segments;
        final isLast = i == filledSegments - 1;
        final thisSweep = isLast
            ? (fraction * sweepAngle) - (i * segSweep)
            : segSweep + 0.01;
        canvas.drawArc(
          rect, startAngle + i * segSweep, thisSweep, false,
          Paint()
            ..color = _colorAt(t)
            ..style = PaintingStyle.stroke
            ..strokeWidth = arcWidth
            ..strokeCap = (i == 0 || isLast) ? StrokeCap.round : StrokeCap.butt,
        );
      }
    }

    final tickPaint = Paint()
      ..color = Colors.grey.shade600
      ..strokeWidth = 1.0 * scale;
    for (var i = 0; i <= 5; i++) {
      final angle = startAngle + (sweepAngle * i / 5);
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + dir * (radius + 4 * scale),
        center + dir * (radius + 10 * scale),
        tickPaint,
      );
    }

    final needleAngle = startAngle + sweepAngle * fraction;
    final needleTip = center +
        Offset(math.cos(needleAngle), math.sin(needleAngle)) * (radius - 6 * scale);
    canvas.drawLine(
      center, needleTip,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.0 * scale
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawCircle(center, 4 * scale, Paint()..color = Colors.white);
    canvas.drawCircle(center, 2.5 * scale, Paint()..color = Colors.grey.shade900);

    final valueTp = TextPainter(
      text: TextSpan(
        text: value.toStringAsFixed(1),
        style: TextStyle(
          color: Colors.white,
          fontSize: 16 * scale,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    valueTp.paint(canvas, Offset(center.dx - valueTp.width / 2, center.dy - 28 * scale));

    final unitTp = TextPainter(
      text: TextSpan(
        text: label.isEmpty ? 'pos/s' : label,
        style: TextStyle(color: Colors.grey.shade500, fontSize: 9 * scale),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    unitTp.paint(canvas, Offset(center.dx - unitTp.width / 2, center.dy - 14 * scale));
  }

  @override
  bool shouldRepaint(_SpeedometerPainter old) =>
      old.value != value || old.maxValue != maxValue || old.label != label;
}

// ── Slide bar ───────────────────────────────────────────────────────────

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

// ── Data chip ───────────────────────────────────────────────────────────

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
