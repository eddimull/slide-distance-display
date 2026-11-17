import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'pitch_detector.dart';
import 'slidepod_ble.dart';
import 'trombone_chart.dart';

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

  // Position history (rolling buffer for line chart)
  final List<double> _posHistory = [];
  static const _maxHistory = 500; // ~10s at 50Hz

  // Pitch detection
  final PitchDetector _pitchDetector = PitchDetector();
  StreamSubscription? _pitchSub;
  double? _detectedFreq;
  bool _micActive = false;

  // Mock pitch simulation
  final math.Random _mockRng = math.Random();
  int _mockPartial = 3;
  int _mockPartialTicks = 0;

  // Pitch history (normalized 0–1 matching position scale)
  final List<double?> _pitchHistory = [];

  @override
  void initState() {
    super.initState();
    _listen();
    _pitchSub = _pitchDetector.pitchStream.listen((freq) {
      if (mounted) setState(() => _detectedFreq = freq);
    });
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

      // Mock pitch: simulate a detected frequency in mock mode
      if (_source.isMock) {
        _mockPartialTicks++;
        if (_mockPartialTicks > 100 + _mockRng.nextInt(150)) {
          _mockPartial = 2 + _mockRng.nextInt(5); // partials 2–6
          _mockPartialTicks = 0;
        }
        final slide = (d.position * 6 + 1).round().clamp(1, 7);
        final midi = TromboneChart.midiAt(_mockPartial, slide);
        final exact = TromboneChart.frequency(midi);
        // Add ±15 cents of random detuning
        final centsOff = (_mockRng.nextDouble() - 0.5) * 30;
        _detectedFreq = exact * math.pow(2, centsOff / 1200);
      }

      // Track pitch as a normalized position (which slide position the pitch maps to)
      double? pitchPos;
      if (_detectedFreq != null && _detectedFreq! > 30) {
        final slide = (d.position * 6 + 1).round().clamp(1, 7);
        final (note, c) = TromboneChart.closestAt(slide, _detectedFreq!);
        if (c.abs() < 100 && note.partial >= 2) {
          pitchPos = (note.midi - TromboneChart.midiAt(note.partial, 1)).abs() / 6.0;
        }
      }

      _posHistory.add(d.position);
      _pitchHistory.add(pitchPos);
      if (_posHistory.length > _maxHistory) {
        _posHistory.removeAt(0);
        _pitchHistory.removeAt(0);
      }

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
            _posHistory.clear();
            _pitchHistory.clear();
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
    _posHistory.clear();
    _pitchHistory.clear();
    _status = useMock ? 'Mock mode' : 'Tap to connect';
    _listen();
    setState(() {});
    if (useMock) _startMock();
  }

  Future<void> _toggleMic() async {
    if (_micActive) {
      _pitchDetector.stop();
      setState(() {
        _micActive = false;
        _detectedFreq = null;
      });
    } else {
      await _pitchDetector.start();
      setState(() => _micActive = true);
    }
  }

  @override
  void dispose() {
    _pitchSub?.cancel();
    _pitchDetector.dispose();
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

    // Find active note for tuner display
    ChartNote? activeNote;
    double? activeCents;
    if (_connected && _detectedFreq != null && _detectedFreq! > 30) {
      final slide = slideNum ?? 1;
      final (note, c) = TromboneChart.closestAt(slide, _detectedFreq!);
      if (c.abs() < 100 && note.partial >= 2) {
        activeNote = note;
        activeCents = c;
      }
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _scanning ? null : _scanAndConnect,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _connected
                              ? Icons.bluetooth_connected
                              : Icons.bluetooth,
                          size: 18,
                          color: _connected ? Colors.blue : Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Text(_status,
                            style: Theme.of(context).textTheme.bodySmall),
                        if (_scanning) ...[
                          const SizedBox(width: 6),
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (kDebugMode)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('BLE',
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade600)),
                        SizedBox(
                          height: 28,
                          child: Switch(
                            value: _source.isMock,
                            onChanged: (v) => _switchSource(v),
                          ),
                        ),
                        Text('Mock',
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade600)),
                      ],
                    ),
                ],
              ),
            ),

            if (!_connected) ...[
              const Spacer(),
              Text('-',
                  style: const TextStyle(
                      fontSize: 80, fontWeight: FontWeight.w200, height: 1)),
              const SizedBox(height: 2),
              Text('Not connected',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey)),
              const Spacer(),
            ],

            if (_connected)
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      const SizedBox(height: 4),

                      // ── Top row: Position + Gauges ──
                      Row(
                        children: [
                          SizedBox(
                            width: 90,
                            child: Column(
                              children: [
                                Text(
                                  '${slideNum ?? "-"}',
                                  style: const TextStyle(
                                    fontSize: 64,
                                    fontWeight: FontWeight.w200,
                                    height: 1,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text('Position',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500)),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  height: 70,
                                  width: 120,
                                  child: _Speedometer(
                                    value: velocityPosPerSec,
                                    maxValue: 5.0,
                                    label: 'Speed',
                                  ),
                                ),
                                const SizedBox(width: 4),
                                SizedBox(
                                  height: 70,
                                  width: 120,
                                  child: _Speedometer(
                                    value: avgPosPerSec,
                                    maxValue: 5.0,
                                    label: 'Avg',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      // ── Slide bar ──
                      const SizedBox(height: 4),
                      _SlideBar(position: _data.position),
                      const SizedBox(height: 8),

                      // ── Divider ──
                      Divider(height: 1, color: Colors.grey.shade800),
                      const SizedBox(height: 8),

                      // ── Tuner (compact) ──
                      _CompactTuner(
                        slidePosition: slideNum ?? 1,
                        activeNote: activeNote,
                        cents: activeCents,
                        freq: _detectedFreq,
                        micActive: _micActive || _source.isMock,
                        isMock: _source.isMock,
                        onMicToggle: _toggleMic,
                      ),
                      const SizedBox(height: 8),

                      // ── Divider ──
                      Divider(height: 1, color: Colors.grey.shade800),
                      const SizedBox(height: 8),

                      // ── History chart ──
                      if (_posHistory.length > 1)
                        _PositionChart(
                          history: _posHistory,
                          pitchHistory: _pitchHistory,
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('Waiting for data...',
                              style: TextStyle(color: Colors.grey.shade600)),
                        ),
                      const SizedBox(height: 8),

                      // ── Raw data footer ──
                      Divider(height: 1, color: Colors.grey.shade800),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _DataChip(
                                label: 'Raw', value: '${_data.rawMm} mm'),
                            _DataChip(
                                label: 'Filtered',
                                value: '${_data.filtMm} mm'),
                            _DataChip(
                                label: 'Position',
                                value: _data.position.toStringAsFixed(3)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
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

// ── Compact tuner (Option B layout) ───────────────────────────────────

class _CompactTuner extends StatelessWidget {
  final int slidePosition;
  final ChartNote? activeNote;
  final double? cents;
  final double? freq;
  final bool micActive;
  final bool isMock;
  final VoidCallback onMicToggle;

  const _CompactTuner({
    required this.slidePosition,
    required this.activeNote,
    required this.cents,
    required this.freq,
    required this.micActive,
    required this.isMock,
    required this.onMicToggle,
  });

  @override
  Widget build(BuildContext context) {
    final notes = TromboneChart.notesAt(slidePosition);
    final displayed =
        notes.where((n) => n.partial >= 2).toList().reversed.toList();

    final hasNote = activeNote != null;
    final c = cents ?? 0.0;
    final inTune = hasNote && c.abs() < 10;
    final noteColor = !hasNote
        ? Colors.grey.shade700
        : inTune
            ? Colors.green
            : c.abs() < 25
                ? Colors.amber
                : Colors.red;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tuner row: note + cents bar + mic icon
        Row(
          children: [
            // Detected note
            SizedBox(
              width: 60,
              child: Column(
                children: [
                  Text(
                    hasNote ? activeNote!.name : '-',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      height: 1,
                      color: noteColor,
                    ),
                  ),
                  Text(
                    hasNote ? '${freq?.toStringAsFixed(1)} Hz' : '',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Cents bar
            Expanded(
              child: Column(
                children: [
                  Row(
                    children: [
                      Text('-50',
                          style: TextStyle(
                              fontSize: 9, color: Colors.grey.shade600)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: SizedBox(
                          height: 16,
                          child: CustomPaint(
                            painter: _CentsBarPainter(
                              cents: hasNote ? c.clamp(-50, 50) : 0,
                              active: hasNote,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('+50',
                          style: TextStyle(
                              fontSize: 9, color: Colors.grey.shade600)),
                    ],
                  ),
                  if (hasNote)
                    Text(
                      '${c >= 0 ? '+' : ''}${c.toStringAsFixed(0)}¢',
                      style: TextStyle(fontSize: 10, color: noteColor),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Mic toggle
            if (isMock)
              Icon(Icons.music_note, size: 20, color: Colors.amber.shade400)
            else
              GestureDetector(
                onTap: onMicToggle,
                child: Icon(
                  micActive ? Icons.mic : Icons.mic_off,
                  size: 20,
                  color: micActive ? Colors.blue : Colors.grey,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // Note chips
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final n in displayed)
              _NoteChip(
                note: n,
                active: activeNote?.partial == n.partial,
              ),
          ],
        ),
      ],
    );
  }
}

class _CentsBarPainter extends CustomPainter {
  final double cents;
  final bool active;
  _CentsBarPainter({required this.cents, this.active = true});

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.width / 2;

    // Background track
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 4, size.width, size.height - 8),
        const Radius.circular(4),
      ),
      Paint()..color = Colors.grey.shade800,
    );

    // Center tick
    canvas.drawLine(
      Offset(mid, 0),
      Offset(mid, size.height),
      Paint()
        ..color = Colors.grey.shade500
        ..strokeWidth = 1.5,
    );

    // Indicator
    if (active) {
      final offset = mid + (cents / 50) * mid;
      final inTune = cents.abs() < 10;
      final color = inTune
          ? Colors.green
          : cents.abs() < 25
              ? Colors.amber
              : Colors.red;
      canvas.drawCircle(
        Offset(offset, size.height / 2),
        6,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_CentsBarPainter old) =>
      old.cents != cents || old.active != active;
}

class _NoteChip extends StatelessWidget {
  final ChartNote note;
  final bool active;
  const _NoteChip({required this.note, this.active = false});

  @override
  Widget build(BuildContext context) {
    final bright = note.partial <= 6;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? Colors.green.shade900
            : bright
                ? Colors.blueGrey.shade800
                : Colors.blueGrey.shade900,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active
              ? Colors.green
              : bright
                  ? Colors.blueGrey.shade600
                  : Colors.blueGrey.shade700,
          width: active ? 1.5 : 0.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            note.name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: active
                  ? Colors.green.shade100
                  : bright
                      ? Colors.white
                      : Colors.grey.shade500,
            ),
          ),
          Text(
            '${note.freq.toStringAsFixed(0)} Hz',
            style: TextStyle(
              fontSize: 9,
              color: active
                  ? Colors.green.shade300
                  : bright
                      ? Colors.grey.shade400
                      : Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Position history chart ──────────────────────────────────────────────

class _PositionChart extends StatelessWidget {
  final List<double> history;
  final List<double?> pitchHistory;
  const _PositionChart({required this.history, required this.pitchHistory});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Legend
        Row(
          children: [
            Container(width: 12, height: 2, color: Colors.blue),
            const SizedBox(width: 4),
            Text('Position',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
            const SizedBox(width: 12),
            Container(width: 12, height: 2, color: Colors.green),
            const SizedBox(width: 4),
            Text('Pitch',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 120,
          child: CustomPaint(
            painter: _PositionChartPainter(
              history: history,
              pitchHistory: pitchHistory,
            ),
            size: const Size(double.infinity, 120),
          ),
        ),
      ],
    );
  }
}

class _PositionChartPainter extends CustomPainter {
  final List<double> history;
  final List<double?> pitchHistory;
  _PositionChartPainter({required this.history, required this.pitchHistory});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;

    final chartLeft = 24.0;
    final chartWidth = size.width - chartLeft;
    final chartHeight = size.height - 4;

    // Background
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(chartLeft, 0, chartWidth, chartHeight),
        const Radius.circular(4),
      ),
      Paint()..color = Colors.grey.shade900,
    );

    // Horizontal grid lines for each position (1–7)
    for (var pos = 1; pos <= 7; pos++) {
      final y = chartHeight - ((pos - 1) / 6.0) * chartHeight;
      final isThird = pos == 3;
      canvas.drawLine(
        Offset(chartLeft, y),
        Offset(size.width, y),
        Paint()
          ..color = isThird
              ? Colors.amber.withValues(alpha: 0.3)
              : Colors.grey.shade800
          ..strokeWidth = isThird ? 1.0 : 0.5,
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '$pos',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(chartLeft - tp.width - 4, y - tp.height / 2));
    }

    final n = history.length;

    // Draw pitch history (green, behind position line)
    if (pitchHistory.length >= 2) {
      final pitchPath = Path();
      bool started = false;
      for (var i = 0; i < pitchHistory.length && i < n; i++) {
        final p = pitchHistory[i];
        if (p == null) {
          started = false;
          continue;
        }
        final x = chartLeft + (i / (n - 1)) * chartWidth;
        final y = chartHeight - p * chartHeight;
        if (!started) {
          pitchPath.moveTo(x, y);
          started = true;
        } else {
          pitchPath.lineTo(x, y);
        }
      }
      canvas.drawPath(
        pitchPath,
        Paint()
          ..color = Colors.green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Draw position line (blue)
    final path = Path();
    for (var i = 0; i < n; i++) {
      final x = chartLeft + (i / (n - 1)) * chartWidth;
      final y = chartHeight - history[i] * chartHeight;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );

    // Current position dot
    final lastX = size.width;
    final lastY = chartHeight - history.last * chartHeight;
    canvas.drawCircle(Offset(lastX, lastY), 3, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(_PositionChartPainter old) => true;
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
