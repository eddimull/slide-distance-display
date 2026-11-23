import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'calibration_screen.dart';
import 'flash_card_screen.dart';
import 'gliss_take.dart';
import 'high_scores.dart';
import 'learn_screen.dart';
import 'one_euro.dart';
import 'pitch_detector.dart';
import 'position_colors.dart';
import 'record_screen.dart';
import 'slide_calibration.dart';
import 'slidepod_ble.dart';
import 'take.dart';
import 'take_store.dart';
import 'takes_screen.dart';
import 'trombone_chart.dart';
import 'upper_partials.dart';

void main() => runApp(const SeventhApp());

class SeventhApp extends StatelessWidget {
  const SeventhApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Seventh',
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

  // Maps ToF mm → slide position and the horn's partial tuning. The slide
  // map comes from the guided gliss calibration; the upper partials are
  // refined from steady notes while playing.
  final SlideCalibration _cal = SlideCalibration();
  late final UpperPartialListener _upper = UpperPartialListener(_cal);
  // Calibration screen open: no background learning, and the readings go
  // to it through _frames.
  bool _calibrating = false;
  final _frames = StreamController<CalFrame>.broadcast();
  // Mock mode: the partial the calibration screen is asking for.
  int? _mockCalPartial;
  bool _calPrompted = false;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _calPrompt;
  Future<void> _calLoaded = Future.value();
  // Easy mode: a limited display for new players learning positions.
  bool _easy = false;
  static const _easyKey = 'ui_easy';
  // Position the pod's LED was last set for: 0 = pod's own colours,
  // -1 = unknown (resend).
  int _ledSent = -1;
  // Latest lipping reading: (partial, cents), + = sharper than the slide.
  (int, double)? _lip;
  // Smoothing of the raw ToF reading (the pod sends it unfiltered).
  final OneEuroFilter _smooth = OneEuroFilter(deadband: 2);
  // When the pod last sent anything, and last had a ToF reading. Medium
  // mode sends every ~41 ms, so 100 ms of nothing means it's stuck.
  DateTime _lastPacket = DateTime.now();
  DateTime _lastRange = DateTime.now();
  static const _quietAfter = Duration(milliseconds: 100);
  // No ToF reading right now: the position comes from the pitch.
  bool _blind = false;
  // Mock mode only: the "real" slide geometry the mock pitch is generated
  // from, deliberately different from the default so calibration has work
  // to do.
  static const _mockTrueA = 80.0, _mockTrueB = 1150.0;
  // Calibration persistence. Mock data has its own fake geometry, so it
  // gets its own key and never pollutes the real instrument's calibration.
  SharedPreferences? _prefs;
  bool _calDirty = false;
  Timer? _calSaveTimer;
  String get _calKey => _source.isMock ? 'slide_cal_mock' : 'slide_cal';
  // Recorded takes; opened the first time the Takes tab is.
  Future<TakeStore>? _store;
  // High scores for the Learn games; opened on first use.
  Future<HighScores>? _scores;
  // Bottom tabs: Live, Takes, Learn.
  int _tab = 0;
  // Easy mode's "Practise your positions" card, until it's closed.
  bool _practiceHidden = false;
  static const _practiceKey = 'ui_practice_card_hidden';

  @override
  void initState() {
    super.initState();
    _listen();
    _loadCal();
    SharedPreferences.getInstance().then((p) {
      _prefs ??= p;
      if (mounted) {
        setState(() {
          _easy = p.getBool(_easyKey) ?? false;
          _practiceHidden = p.getBool(_practiceKey) ?? false;
        });
      }
    });
    // Samples arrive at 50 Hz; write at most every few seconds.
    _calSaveTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _saveCal());
    _pitchSub = _pitchDetector.pitchStream.listen((freq) {
      if (!mounted) return;
      _detectedFreq = freq;
      // The pod has gone quiet (the ToF blocking on a reading it can't get,
      // or older firmware that sends nothing then): let the mic, every
      // 20 ms, keep the display going from the pitch.
      if (_connected &&
          !_source.isMock &&
          DateTime.now().difference(_lastPacket) > _quietAfter) {
        _onReading(null);
      } else {
        setState(() {});
      }
    });
    if (widget.autoMock && _source.isMock) {
      _startMock();
    }
  }

  void _listen() {
    _source.dataStream.listen((raw) {
      if (mounted) _onReading(raw);
    });
    _source.connectionStream.listen((c) {
      if (mounted) {
        setState(() {
          _connected = c;
          _ledSent = -1; // new link: the pod starts on its own colours
          _status = c
              ? (_source.isMock ? 'Mock connected' : 'Connected')
              : (_source.isMock ? 'Mock mode' : 'Disconnected');
          if (!c) {
            _velocity = 0;
            _totalDistance = 0;
            _activeSeconds = 0;
            _posHistory.clear();
            _smooth.reset();
            _pitchHistory.clear();
            _lip = null;
            _blind = false;
          }
        });
        if (c) {
          _maybePromptCalibration();
        } else {
          _hideCalPrompt();
        }
      }
    });
  }

  /// One update of everything derived from the slide and the pitch. [raw]
  /// is a packet from the pod, or null when the pod has gone quiet and the
  /// mic drives the update instead (see [_pitchSub]).
  ///
  /// When the ToF has no reading (the pod sends [SlideData.noReading], or
  /// nothing at all: past 500 mm in Medium mode the crossbar can drop out
  /// for a while), the slide is placed from the pitch alone, on the partial
  /// nearest where it was last seen; with no note either it holds.
  void _onReading(SlideData? raw) {
    final now = DateTime.now();
    if (raw != null) _lastPacket = now;
    double? filt;
    if (raw != null && raw.hasRange) {
      // A gap: start the smoothing afresh rather than glide from where the
      // slide was before it.
      if (now.difference(_lastRange) > const Duration(milliseconds: 150)) {
        _smooth.reset();
      }
      _lastRange = now;
      // Smooth the raw reading here (the pod sends it unfiltered), then map
      // through the calibrated geometry rather than the firmware's guess.
      filt = _smooth.update(raw.rawMm.toDouble(), now);
    }

    // Mock pitch: simulate a detected frequency in mock mode
    final mock = _source is SlidePodMock ? _source as SlidePodMock : null;
    mock?.glissMode = _mockCalPartial != null;
    if (_source.isMock && filt != null) {
      if (_mockCalPartial != null) {
        _mockPartial = _mockCalPartial!; // play what calibration asks for
      } else if (++_mockPartialTicks > 100 + _mockRng.nextInt(150)) {
        _mockPartial = 2 + _mockRng.nextInt(5); // partials 2–6
        _mockPartialTicks = 0;
      }
      // Pitch follows the slide's true (hidden) geometry, on the harmonic
      // series, with ±10 cents of lipping noise.
      final x = (filt - _mockTrueA) / _mockTrueB;
      final semis = 12 * math.log(1 + x) / math.ln2;
      final centsOff = (_mockRng.nextDouble() - 0.5) * 20;
      _detectedFreq = _mockPartial *
          SlideCalibration.f0 /
          math.pow(2, (semis * 100 - centsOff) / 1200);
      if (mock != null && mock.glissMode && !mock.sounding) {
        _detectedFreq = null;
      }
    }
    final freq = raw?.pitchHz ?? _detectedFreq;

    final double position;
    double? pitchPos;
    (int, double)? lip;
    if (filt != null) {
      position = _cal.positionFromMm(filt);
      // Pitch → where this horn's slide would be for that note, and how far
      // that is from where the slide actually is (lipping).
      if (freq != null && freq > 30) {
        final hit = _cal.pitchSlide(freq, _cal.semitonesFromMm(filt));
        if (hit != null) pitchPos = hit.$2 / SlideCalibration.maxSemitones;
        lip = _cal.lipCents(filt, freq);
      }
    } else {
      final s = _cal.semitonesFromPitchNear(
          freq, _prevPosition * SlideCalibration.maxSemitones);
      position = s == null
          ? _prevPosition
          : (s / SlideCalibration.maxSemitones).clamp(0.0, 1.0);
      if (s != null) pitchPos = position;
      // No lipping reading: it needs the ToF to compare against.
    }
    _blind = filt == null;
    _lip = lip;

    final d = SlideData(
      rawMm: filt != null ? raw!.rawMm : _data.rawMm,
      filtMm: filt != null ? filt.round() : _data.filtMm,
      position: position,
      pitchHz: raw?.pitchHz,
      hasPiezo: raw?.hasPiezo ?? _data.hasPiezo,
    );
    _syncLed(_positionToSlide(d.position));
    final dt = now.difference(_prevTime).inMicroseconds / 1e6;
    if (dt > 0.001) {
      final delta = (d.position - _prevPosition).abs();
      final rawVel = delta / dt;
      _velocity = _velocity * (1 - _velocitySmoothing) + rawVel * _velocitySmoothing;
      if (_velocity * 6.0 >= 0.5) {
        _totalDistance += delta;
        _activeSeconds += dt;
      }
    }
    _prevPosition = d.position;
    _prevTime = now;

    // Calibration and recording listen to these.
    _frames.add((t: now, mm: filt, freq: freq));
    if (!_calibrating &&
        _upper.feed(now, filt ?? 0, filt == null ? null : freq,
                still: _velocity * 6.0 < 0.5) !=
            null) {
      // (No ToF: ends any note being listened to; can't learn from it.)
      _calDirty = true;
    }

    _posHistory.add(d.position);
    _pitchHistory.add(pitchPos);
    if (_posHistory.length > _maxHistory) {
      _posHistory.removeAt(0);
      _pitchHistory.removeAt(0);
    }

    // TEMP diagnostics (debug builds): read with adb logcat -s flutter.
    if (kDebugMode && ++_diagTick % 6 == 0) {
      debugPrint('DIAG ${now.millisecondsSinceEpoch % 100000} '
          'pkt=${raw == null ? 'none' : raw.hasRange ? raw.rawMm : 'noread'} '
          'filt=${filt?.toStringAsFixed(1) ?? '-'} '
          'pos=${(1 + 6 * position).toStringAsFixed(2)} '
          'freq=${freq?.toStringAsFixed(1) ?? '-'} vel=${(_velocity * 6).toStringAsFixed(2)}');
    }
    setState(() => _data = d);
  }
  int _diagTick = 0;

  /// Offers calibration, once, when the real pod is connected and there is
  /// no saved calibration (checked after it has finished loading).
  Future<void> _maybePromptCalibration() async {
    await _calLoaded;
    if (!mounted ||
        _calPrompted ||
        _calibrating ||
        !_connected ||
        _source.isMock ||
        _cal.calibrated) {
      return;
    }
    _calPrompted = true;
    _calPrompt = ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Calibrate your slide so positions read true'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(label: 'Calibrate', onPressed: _openCalibration),
    ));
    _calPrompt!.closed.then((_) => _calPrompt = null);
  }

  void _hideCalPrompt() {
    _calPrompt?.close();
    _calPrompt = null;
  }

  Future<void> _loadCal() => _calLoaded = _doLoadCal();

  Future<void> _doLoadCal() async {
    _prefs ??= await SharedPreferences.getInstance();
    final json = _prefs!.getString(_calKey);
    if (!mounted) return;
    setState(() => json == null ? _cal.reset() : _cal.loadJson(json));
  }

  void _saveCal() {
    if (!_calDirty || _prefs == null) return;
    _calDirty = false;
    _prefs!.setString(_calKey, _cal.toJson());
  }

  void _setEasy(bool easy) {
    setState(() => _easy = easy);
    _prefs?.setBool(_easyKey, easy);
    _syncLed(_positionToSlide(_data.position));
  }

  /// In Easy mode the pod's LED shows the position's colour; otherwise the
  /// pod runs its own status colours. Only writes on change.
  void _syncLed(int slide) {
    final want = _easy && _connected ? slide : 0;
    if (want == _ledSent) return;
    _ledSent = want;
    _source.setLed(want == 0 ? null : PositionColors.led[want - 1]);
  }

  /// Opens the guided calibration (turns the mic on). The current
  /// calibration is kept unless a new one is finished.
  Future<void> _openCalibration() async {
    if (_calibrating) return;
    _hideCalPrompt();
    if (!_micActive && !_source.isMock) await _toggleMic();
    if (!mounted) return;
    setState(() => _calibrating = true);
    _upper.reset();
    final result = await Navigator.of(context).push<SlideCalibration>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CalibrationScreen(
          frames: _frames.stream,
          onListeningFor: (n) => _mockCalPartial = n,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _calibrating = false;
      _mockCalPartial = null;
      if (result != null) _cal.loadJson(result.toJson());
    });
    if (result != null) {
      _calDirty = true;
      _saveCal();
    }
  }

  /// The Takes tab: recorded takes, where new ones are recorded from.
  Widget _takesTab() => FutureBuilder<TakeStore>(
        future: _store ??= TakeStore.open(),
        builder: (context, snap) {
          final store = snap.data;
          if (store == null) {
            return Center(
              child: snap.hasError
                  ? Text('Can\'t open the takes: ${snap.error}')
                  : const CircularProgressIndicator(),
            );
          }
          return TakesScreen(
            store: store,
            cal: _cal,
            canRecord: _connected,
            onRecord: ({title}) => _recordTake(store, title: title),
          );
        },
      );

  /// The Learn tab: games for learning the positions.
  Widget _learnTab() => FutureBuilder<HighScores>(
        future: _scores ??= HighScores.open(),
        builder: (context, snap) => snap.data == null
            ? const Center(child: CircularProgressIndicator())
            : LearnScreen(
                learn: LearnContext(
                    frames: _frames.stream,
                    cal: _cal,
                    scores: snap.data!,
                    ensureMic: () async {
                      if (!_micActive && !_source.isMock) await _toggleMic();
                    }),
                connected: _connected,
              ),
      );

  /// Straight into the first game, from Easy mode's card.
  Future<void> _openPractice() async {
    final scores = await (_scores ??= HighScores.open());
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          FlashCardScreen(frames: _frames.stream, cal: _cal, scores: scores),
    ));
  }

  void _setPracticeHidden(bool hidden) {
    setState(() => _practiceHidden = hidden);
    _prefs?.setBool(_practiceKey, hidden);
    if (!hidden) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('Hidden. The games are always in Learn.'),
        action: SnackBarAction(
            label: 'Undo', onPressed: () => _setPracticeHidden(false)),
      ));
  }

  /// Records one take (turning the mic on for pitch and audio), titled
  /// [title] when it's another take of a piece.
  Future<Take?> _recordTake(TakeStore store, {String? title}) async {
    if (!_micActive && !_source.isMock) await _toggleMic();
    if (!mounted) return null;
    return Navigator.of(context).push<Take>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => RecordScreen(
        frames: _frames.stream,
        pcm: _pitchDetector.pcmStream,
        sampleRate: _pitchDetector.sampleRate,
        cal: _cal,
        store: store,
        hearing: _micActive || _source.isMock || _data.hasPiezo,
        title: title,
      ),
    ));
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
    _saveCal();
    _source.disconnect();
    _source.dispose();
    _source = useMock ? SlidePodMock() : SlidePodBle();
    _data = const SlideData(rawMm: 0, filtMm: 0, position: 0);
    _connected = false;
    _velocity = 0;
    _totalDistance = 0;
    _activeSeconds = 0;
    _posHistory.clear();
    _smooth.reset();
    _pitchHistory.clear();
    // Mock mode fakes _detectedFreq; don't carry it over to the real pod.
    _detectedFreq = null;
    _lip = null;
    _blind = false;
    _ledSent = -1;
    _upper.reset();
    _hideCalPrompt();
    _calPrompted = false; // a different source: offer again if it needs it
    _status = useMock ? 'Mock mode' : 'Tap to connect';
    _listen();
    _loadCal();
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
      try {
        await _pitchDetector.start();
        setState(() => _micActive = true);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Mic unavailable: $e')));
      }
    }
  }

  @override
  void dispose() {
    _calSaveTimer?.cancel();
    _saveCal();
    _frames.close();
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

  /// Pitch to use: the pod's piezo (immune to room noise) when it hears
  /// something, otherwise this device's mic (web build only for now).
  double? get _freq => _data.pitchHz ?? _detectedFreq;
  String? get _freqSource => _data.pitchHz != null
      ? 'piezo'
      : _detectedFreq != null
          ? 'mic'
          : null;

  int _positionToSlide(double pos) {
    // pos 0.0 = 1st position, 1.0 = 7th → six intervals, not seven.
    return (1 + (pos * 6.0).round()).clamp(1, 7);
  }

  @override
  Widget build(BuildContext context) {
    final slideNum = _connected ? _positionToSlide(_data.position) : null;
    // The smoothed speed only decays toward zero, and each small step of the
    // held position adds a blip; below 0.2 positions/s the slide is still.
    final velocityPosPerSec = _velocity * 6.0 < 0.2 ? 0.0 : _velocity * 6.0;
    final avgPosPerSec = _activeSeconds > 0.5
        ? (_totalDistance * 6.0) / _activeSeconds
        : 0.0;

    // Find active note for tuner display
    ChartNote? activeNote;
    double? activeCents;
    final freq = _freq;
    if (_connected && freq != null && freq > 30) {
      final slide = slideNum ?? 1;
      final (note, c) = TromboneChart.closestAt(slide, freq);
      if (c.abs() < 100 && note.partial >= 2) {
        activeNote = note;
        activeCents = c;
      }
    }

    final live = SafeArea(
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
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Easy')),
                      ButtonSegment(value: false, label: Text('Full')),
                    ],
                    selected: {_easy},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => _setEasy(s.first),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(width: 8),
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

            if (_connected && _easy)
              Expanded(
                child: _EasyView(
                  slideNum: slideNum,
                  position: _data.position,
                  activeNote: activeNote,
                  cents: activeCents,
                  micActive: _micActive || _source.isMock,
                  isMock: _source.isMock,
                  onMicToggle: _toggleMic,
                  onPractice: _practiceHidden ? null : _openPractice,
                  onHidePractice: () => _setPracticeHidden(true),
                ),
              ),

            if (_connected && !_easy)
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
                                  // Replayed sessions peak around 19 pos/s.
                                  child: _Speedometer(
                                    value: velocityPosPerSec,
                                    maxValue: 20.0,
                                    label: 'Speed',
                                  ),
                                ),
                                const SizedBox(width: 4),
                                SizedBox(
                                  height: 70,
                                  width: 120,
                                  child: _Speedometer(
                                    value: avgPosPerSec,
                                    maxValue: 20.0,
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
                        lipCents: activeNote != null ? _lip?.$2 : null,
                        freq: _freq,
                        freqSource: _freqSource,
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
                                label: 'Raw',
                                value: _blind
                                    ? 'no echo'
                                    : '${_data.rawMm} mm'),
                            _DataChip(
                                label: 'Filtered',
                                value: '${_data.filtMm} mm'),
                            _DataChip(
                                label: 'Position',
                                value: _data.position.toStringAsFixed(3)),
                            // Tap to (re)calibrate.
                            GestureDetector(
                              onTap: _openCalibration,
                              child: _DataChip(
                                  label: _cal.calibrated
                                      ? 'Cal (tap to redo)'
                                      : 'Cal (tap to set)',
                                  value: _cal.calibrated
                                      ? 'upper ${_cal.learnedUpper.length}/4'
                                      : 'not set'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
    );

    return Scaffold(
      body: switch (_tab) {
        1 => _takesTab(),
        2 => _learnTab(),
        _ => live,
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.graphic_eq), label: 'Live'),
          NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music),
              label: 'Takes'),
          NavigationDestination(
              icon: Icon(Icons.school_outlined),
              selectedIcon: Icon(Icons.school),
              label: 'Learn'),
        ],
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
  final bool large;
  final List<Color>? colors; // per position (Easy mode)
  const _SlideBar({required this.position, this.large = false, this.colors});

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
                  fontSize: large ? 22 : 12,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  color: colors != null
                      ? colors![i].withValues(alpha: active ? 1 : 0.5)
                      : active
                          ? Colors.blue
                          : Colors.grey,
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: large ? 20 : 12,
            child: LinearProgressIndicator(
              value: position.clamp(0.0, 1.0),
              backgroundColor: Colors.grey.shade800,
              valueColor: AlwaysStoppedAnimation(colors == null
                  ? Colors.blue
                  : colors![(position * 6).round().clamp(0, 6)]),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Easy mode ───────────────────────────────────────────────────────────

/// Limited display for new players learning their positions: where the
/// slide is, and while a note sounds, the note with an arrow showing which
/// way to tune it. No gauges, charts, raw numbers, cents or lip readout.
class _EasyView extends StatelessWidget {
  final int? slideNum;
  final double position;
  final ChartNote? activeNote;
  final double? cents;
  final bool micActive;
  final bool isMock;
  final VoidCallback onMicToggle;

  /// Opens the first Learn game; null hides the card.
  final VoidCallback? onPractice;
  final VoidCallback onHidePractice;

  const _EasyView({
    required this.slideNum,
    required this.position,
    required this.activeNote,
    required this.cents,
    required this.micActive,
    required this.isMock,
    required this.onMicToggle,
    required this.onPractice,
    required this.onHidePractice,
  });

  static const _ordinals = ['1st', '2nd', '3rd', '4th', '5th', '6th', '7th'];

  @override
  Widget build(BuildContext context) {
    final hasNote = activeNote != null && cents != null;
    final c = cents ?? 0;
    final color = c.abs() < 10
        ? Colors.green
        : c.abs() < 25
            ? Colors.amber
            : Colors.red;
    // Flat -> bring the pitch up (slide in); sharp -> down (slide out).
    final (IconData icon, String hint) = c.abs() < 10
        ? (Icons.check_circle, 'in tune')
        : c < 0
            ? (Icons.arrow_upward, 'slide in')
            : (Icons.arrow_downward, 'slide out');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const Spacer(),
          Text('Position',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
          SizedBox(
            height: 150,
            child: FittedBox(
              child: Text(
                slideNum == null ? '-' : _ordinals[slideNum! - 1],
                style: TextStyle(
                  fontSize: 140,
                  fontWeight: FontWeight.w300,
                  color: slideNum == null
                      ? Colors.grey
                      : PositionColors.screen[slideNum! - 1],
                  height: 1,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SlideBar(
              position: position, large: true, colors: PositionColors.screen),
          const Spacer(),
          // Fixed height whether or not a note is sounding, so nothing jumps.
          SizedBox(
            height: 110,
            child: !hasNote
                ? Center(
                    child: Text(
                      micActive ? 'Play a note' : 'Tap the mic to hear your notes',
                      style:
                          TextStyle(fontSize: 22, color: Colors.grey.shade500),
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Fixed slot: "Bb3" is wider than "A3", and the
                      // arrow shouldn't move when the note changes.
                      SizedBox(
                        width: 170,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            activeNote!.name,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 72,
                              fontWeight: FontWeight.w600,
                              color: color,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      SizedBox(
                        width: 90,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(icon, size: 64, color: color),
                            Text(hint,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade400)),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          if (onPractice != null) _PracticeCard(onPractice!, onHidePractice),
          const Spacer(),
          if (!isMock)
            IconButton.filledTonal(
              iconSize: 36,
              onPressed: onMicToggle,
              icon: Icon(micActive ? Icons.mic : Icons.mic_off),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Easy mode's way into the Learn games, with a close button.
class _PracticeCard extends StatelessWidget {
  final VoidCallback onOpen, onHide;
  const _PracticeCard(this.onOpen, this.onHide);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text('5',
                          style: TextStyle(
                              fontSize: 28, fontWeight: FontWeight.w300)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Practise your positions',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text('Position Flash · no playing needed',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade400)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Hide this card',
            onPressed: onHide,
            icon: const Icon(Icons.close, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

// ── Compact tuner (Option B layout) ───────────────────────────────────

class _CompactTuner extends StatelessWidget {
  final int slidePosition;
  final ChartNote? activeNote;
  final double? cents;
  final double? lipCents; // + = played sharper than the slide position gives
  final double? freq;
  final String? freqSource; // 'piezo' / 'mic'
  final bool micActive;
  final bool isMock;
  final VoidCallback onMicToggle;

  const _CompactTuner({
    required this.slidePosition,
    required this.activeNote,
    required this.cents,
    required this.lipCents,
    required this.freq,
    required this.freqSource,
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
                  // Fixed-size slots so a new note never resizes the row.
                  SizedBox(
                    height: 32,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        hasNote ? activeNote!.name : '-',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                          height: 1,
                          color: noteColor,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    hasNote
                        ? '${freq?.toStringAsFixed(1)} Hz'
                            '${freqSource == 'piezo' ? ' ·pz' : ''}'
                        : '',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
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
                  // Always laid out (blank when no note) so the bar doesn't
                  // jump; fixed widths so changing numbers don't shift it.
                  // Left: tuning vs equal temperament. Right: lipping, i.e.
                  // the pitch vs what the horn gives where the slide is.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 56,
                        child: Text(
                          hasNote ? _signed(c) : '',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 10, color: noteColor),
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          hasNote && lipCents != null
                              ? 'lip ${_signed(lipCents!)}'
                              : '',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            color: lipCents == null || lipCents!.abs() < 10
                                ? Colors.grey.shade500
                                : lipCents!.abs() < 25
                                    ? Colors.amber
                                    : Colors.red,
                          ),
                        ),
                      ),
                    ],
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
        // Note chips: one row, each chip an equal share of the width.
        Row(
          children: [
            for (var i = 0; i < displayed.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: _NoteChip(
                  note: displayed[i],
                  active: activeNote?.partial == displayed[i].partial,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

String _signed(double cents) =>
    '${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(0)}¢';

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
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
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
          // Same width active or not, so the chip never changes size.
          width: 1.5,
        ),
      ),
      // Scale the labels down rather than wrap if the chip gets narrow.
      child: FittedBox(
        fit: BoxFit.scaleDown,
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
