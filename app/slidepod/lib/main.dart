import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'account.dart';
import 'pod_sheet.dart';
import 'calibration_screen.dart';
import 'firmware_screen.dart';
import 'flash_card_screen.dart';
import 'gliss_take.dart';
import 'high_scores.dart';
import 'high_scores_screen.dart';
import 'instruments_screen.dart';
import 'learn_screen.dart';
import 'live_view.dart';
import 'one_euro.dart';
import 'pitch_detector.dart';
import 'position_colors.dart';
import 'record_screen.dart';
import 'seventh_api.dart';
import 'slide_calibration.dart';
import 'slidepod_ble.dart';
import 'take.dart';
import 'take_store.dart';
import 'takes_screen.dart';
import 'trombone_chart.dart';
import 'upper_partials.dart';
import 'ui/seventh.dart';
import 'ui/top_bar.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    for (final (font, file) in [
      ('Space Grotesk', 'fonts/OFL-SpaceGrotesk.txt'),
      ('Inter', 'fonts/OFL-Inter.txt'),
      ('JetBrains Mono', 'fonts/OFL-JetBrainsMono.txt'),
      ('Noto Music (♭ ♮ ♯)', 'fonts/OFL-NotoMusic.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([font], await rootBundle.loadString(file));
    }
  });
  runApp(const SlidePodApp());
}

class SlidePodApp extends StatelessWidget {
  const SlidePodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Seventh',
      theme: Seventh.theme(),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  /// Simulated SlidePod data instead of Bluetooth: debug builds only (as is
  /// the BLE/Mock switch). `--dart-define=MOCK=false` starts a debug build
  /// on the real thing.
  final bool autoMock;
  const HomePage({
    super.key,
    this.autoMock =
        kDebugMode && const bool.fromEnvironment('MOCK', defaultValue: true),
  });

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
  Future<(HighScores, Account)>? _learnReady;
  Future<Account>? _account;

  /// The online leaderboards account, opened once (and checked with the
  /// server in the background).
  Future<Account> _openAccount() => _account ??= (() async {
        final a = Account(SeventhApi(), await SharedPreferences.getInstance(),
            platform: seventhPlatform());
        unawaited(a.refresh());
        return a;
      })();
  // Bottom tabs: Live, Takes, Learn.
  int _tab = 0;
  // Easy mode's "Practise your positions" card, until it's closed.
  bool _practiceHidden = false;
  static const _practiceKey = 'ui_practice_card_hidden';

  @override
  void initState() {
    super.initState();
    _openAccount().then((a) async {
      if (!mounted) return;
      setState(() => _acct = a);
      // The account's instruments, then this phone's calibration with the
      // current one's.
      await a.loadInstruments();
      await _syncCal();
    });
    // Calibration keeps learning while you play: send it at most a minute
    // after it changes.
    _calSyncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_calPushDue) _syncCal();
    });
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
    _source.powerStream.listen((_) {
      if (mounted && _connected) setState(() => _status = _podStatus());
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

  /// The pod firmware the calibration was made on. A firmware update can
  /// change how far readings come out (0.5.3 read 7th ~80 mm shorter than
  /// before, and an older calibration put in-tune 7th at 6.3), so a pod on
  /// different firmware asks for a fresh one.
  static const _calFirmwareKey = 'slide_cal_firmware';

  /// Offers calibration, once per connection, when the real pod is
  /// connected and there's no saved calibration, or it was made on other
  /// firmware (checked after it has finished loading).
  Future<void> _maybePromptCalibration() async {
    await _calLoaded;
    if (!mounted || _calPrompted || _calibrating || !_connected || _source.isMock) {
      return;
    }
    final String message;
    if (!_cal.calibrated) {
      message = 'Calibrate your slide so positions read true';
    } else {
      final fw = _source.pod?.firmware;
      _prefs ??= await SharedPreferences.getInstance();
      final calFw = _prefs!.getString(_calFirmwareKey);
      if (fw == null) return;
      if (calFw == null) {
        // Made before this was kept: take it as made on this firmware.
        await _prefs!.setString(_calFirmwareKey, fw);
        return;
      }
      if (calFw == fw || !mounted) return;
      message = 'SlidePod firmware updated: recalibrate so positions read true';
    }
    _calPrompted = true;
    _calPrompt = ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 12),
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
    if (!_source.isMock) {
      // Changed on this phone: the account's copy is due an update.
      _acct?.calibrationChanged();
      _calPushDue = true;
    }
  }

  /// The calibration has changed since the account last had it.
  bool _calPushDue = false;
  Timer? _calSyncTimer;

  /// Brings the calibration and the current instrument's on the account
  /// together (signed in, with an instrument chosen): newest wins.
  /// [adoptLocal]: false when switching to another instrument, which
  /// starts uncalibrated if it has no calibration of its own.
  Future<void> _syncCal({bool adoptLocal = true}) async {
    final a = _acct;
    if (a == null || _source.isMock || !a.signedIn) return;
    await _calLoaded;
    _saveCal();
    _calPushDue = false;
    final load = await a.syncCalibration(_cal.calibrated ? _cal.toJson() : null,
        adoptLocal: adoptLocal);
    if (load == null || !mounted) return;
    setState(() => load.isEmpty ? _cal.reset() : _cal.loadJson(load));
    _prefs?.setString(_calKey, _cal.toJson());
  }

  /// Plays [i] from now on: the last one's calibration is saved first, then
  /// [i]'s is loaded. A new first instrument takes the phone's.
  Future<void> _useInstrument(Instrument i, {bool isNew = false}) async {
    final a = _acct;
    if (a == null) return;
    if (a.currentInstrument?.id != i.id) await _syncCal();
    await a.chooseInstrument(i);
    await _syncCal(adoptLocal: isNew && a.instruments.length == 1);
  }

  Future<void> _openInstruments() async {
    final a = _acct;
    if (a == null) return;
    final pod = _source.pod;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InstrumentsScreen(
              account: a,
              onChoose: _useInstrument,
              linkedPodId: pod == null ? null : a.linkedPod(pod.serial)?.id,
            )));
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
          pod: (_) => _podPill(compact: true),
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
      final fw = _source.pod?.firmware;
      if (fw != null) await _prefs?.setString(_calFirmwareKey, fw);
      await _syncCal();
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
            topBar: _topBar('Takes'),
            store: store,
            cal: _cal,
            canRecord: _connected,
            onRecord: ({title}) => _recordTake(store, title: title),
          );
        },
      );

  /// The Learn tab: games for learning the positions.
  Widget _learnTab() => FutureBuilder<(HighScores, Account)>(
        future: _learnReady ??= (() async {
          final scores = await (_scores ??= HighScores.open());
          return (scores, await _openAccount());
        })(),
        builder: (context, snap) => snap.data == null
            ? const Center(child: CircularProgressIndicator())
            : LearnScreen(
                topBar: _topBar('Learn'),
                learn: LearnContext(
                    frames: _frames.stream,
                    cal: _cal,
                    scores: snap.data!.$1,
                    account: snap.data!.$2,
                    ensureMic: () async {
                      if (!_micActive && !_source.isMock) await _toggleMic();
                    },
                    pod: (_) => _podPill(compact: true)),
                connected: _connected,
              ),
      );

  /// Straight into the first game, from Easy mode's card.
  Future<void> _openPractice() async {
    final scores = await (_scores ??= HighScores.open());
    final account = await _openAccount();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FlashCardScreen(
          frames: _frames.stream,
          cal: _cal,
          scores: scores,
          account: account,
          pod: (_) => _podPill(compact: true)),
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
      _status = 'Starting mock…';
    });
    await _source.connectFirst();
    if (mounted) setState(() => _scanning = false);
    await _connectedTo();
  }

  void _switchSource(bool useMock) {
    _saveCal();
    _source.disconnect();
    _source.dispose();
    _source = useMock ? SlidePodMock() : SlidePodBle();
    _data = const SlideData(rawMm: 0, filtMm: 0, position: 0);
    _connected = false;
    _velocity = 0;
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
    _calSyncTimer?.cancel();
    _saveCal();
    _frames.close();
    _pitchSub?.cancel();
    _pitchDetector.dispose();
    _source.dispose();
    super.dispose();
  }

  static const _lastPodKey = 'pod_last_serial';

  /// Connection problems, wherever you are (Live also shows them in place).
  void _notice(String msg) {
    if (!mounted || _tab == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// The account, once opened (for the profile avatar).
  Account? _acct;

  PodLink get _podLink => _connected
      ? PodLink.on
      : _scanning
          ? PodLink.connecting
          : PodLink.off;

  /// The pod pill: tap to connect, or (connected) the pod sheet.
  Widget _podPill({bool compact = false}) => PodPill(
        link: _podLink,
        name: _source.pod?.name ?? (_source.isMock ? 'Mock pod' : null),
        power: _source.power,
        compact: compact,
        onTap: _scanning ? null : _scanAndConnect,
      );

  Widget _profile() => ProfileAvatar(account: _acct, onTap: _openScores);

  /// Scores, for the games you've unlocked (the profile button).
  Future<void> _openScores() async {
    final scores = await (_scores ??= HighScores.open());
    if (!mounted) return;
    final open = unlockedLevels(learnLevels, scores);
    final games = [
      for (final (i, l) in learnLevels.indexed)
        if (open[i] && l.gameId != null && l.build != null)
          ScoreGame(l.gameId!, l.title, '${l.title} · Level ${l.level}'),
    ];
    final first = games.first;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HighScoresScreen(
              scores: scores,
              gameId: first.id,
              title: first.title,
              subtitle: first.subtitle,
              account: _acct,
              games: games,
            )));
  }

  /// The top bar of each tab.
  PreferredSizeWidget _topBar(String title) =>
      SeventhTopBar(title: title, pod: _podPill(), profile: _profile());

  /// Connected: the pod's sheet (rename, blink, link, disconnect).
  Future<void> _openPodSheet() async {
    final account = await _openAccount();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => PodSheet(
        source: _source,
        account: account,
        onDisconnect: () => _source.disconnect(),
        onCalibrate: _openCalibration,
        onInstruments: _openInstruments,
        onUpdate: _source.isMock
            ? null
            : (b) => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => FirmwareUpdateScreen(
                    source: _source, build: b, onRecalibrate: _openCalibration))),
      ),
    );
    if (mounted) setState(() => _status = _podStatus());
  }

  String _podStatus() {
    final name =
        _source.pod?.name ?? (_source.isMock ? 'Mock connected' : 'Connected');
    final power = _source.power;
    return power == null ? name : '$name · ${power.label}';
  }

  /// Just connected: remember the pod, and if it's linked to the account,
  /// tell the server it was seen (with its name and firmware).
  Future<void> _connectedTo() async {
    final pod = _source.pod;
    if (mounted) setState(() => _status = _podStatus());
    if (pod == null || _source.isMock) return;
    // Now the pod's firmware is known: a calibration made on other firmware
    // asks to be redone.
    unawaited(_maybePromptCalibration());
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_lastPodKey, pod.serial);
    final account = await _openAccount();
    if (account.signedIn && account.pods.isEmpty) await account.loadPods();
    await account.podSeen(pod);
    // The instrument this pod is on, if one says so.
    final linked = account.linkedPod(pod.serial);
    if (linked != null && account.currentInstrument?.podId != linked.id) {
      for (final i in account.instruments) {
        if (i.podId == linked.id) {
          await _useInstrument(i);
          break;
        }
      }
    }
  }

  Future<void> _scanAndConnect() async {
    if (_connected) {
      await _openPodSheet();
      return;
    }
    if (_source.isMock) {
      await _startMock();
      return;
    }

    setState(() {
      _scanning = true;
      _status = 'Scanning…';
    });

    try {
      final ble = _source as SlidePodBle;
      final results = await ble.scan();

      if (results.isEmpty) {
        setState(() {
          _scanning = false;
          _status = 'No SlidePod found';
        });
        _notice('No SlidePod found. Is it switched on?');
        return;
      }

      if (results.length == 1) {
        setState(() => _status = 'Connecting…');
        await ble.connect(results.first.device);
        await _connectedTo();
      } else {
        _prefs ??= await SharedPreferences.getInstance();
        final account = await _openAccount();
        if (!mounted) return;
        final device = await showPodPicker(
          context,
          [for (final r in results) FoundPod.of(r)],
          lastSerial: _prefs!.getString(_lastPodKey),
          isMine: (serial) => account.linkedPod(serial) != null,
        );
        if (device != null) {
          setState(() => _status = 'Connecting…');
          await ble.connect(device);
          await _connectedTo();
        } else {
          setState(() => _status = 'Tap to connect');
        }
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
      _notice('Couldn\'t connect: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
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
            // ── Top bar, then the view switch ──
            _topBar('Live'),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Seventh.gutter, 8, Seventh.gutter, 0),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('Simple')),
                        ButtonSegment(value: false, label: Text('Detail')),
                      ],
                      selected: {_easy},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => _setEasy(s.first),
                      // The design's 36 px switch, not a 48 px button row.
                      style: const ButtonStyle(
                        visualDensity: VisualDensity(vertical: -3),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: 'Debug: simulated pod',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Mock', style: Seventh.small),
                          Switch(
                            value: _source.isMock,
                            onChanged: (v) => _switchSource(v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            Expanded(
              child: LiveView(
                connected: _connected,
                status: switch (_status) {
                  'Tap to connect' || 'Disconnected' => 'Not connected',
                  final s => s,
                },
                onConnect: _scanning ? null : _scanAndConnect,
                reading: LiveReading(
                  position: _data.position,
                  mm: _blind ? null : _data.filtMm,
                  note: activeNote,
                  cents: activeCents,
                  lipCents: activeNote != null ? _lip?.$2 : null,
                  freq: _freq,
                  freqSource: _freqSource,
                  speed: velocityPosPerSec,
                ),
                detail: !_easy,
                micActive: _micActive || _source.isMock,
                isMock: _source.isMock,
                onMicToggle: _toggleMic,
                onPractice: _practiceHidden ? null : _openPractice,
                onHidePractice: () => _setPracticeHidden(true),
                calibrated: _cal.calibrated,
                upperLearned: _cal.learnedUpper.length,
                instrument: _acct?.currentInstrument?.name,
                onCalibrate: _openCalibration,
                positionHistory: _posHistory,
                pitchHistory: _pitchHistory,
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
