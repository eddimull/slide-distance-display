import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';

import 'slide_calibration.dart';
import 'take.dart';
import 'take_analysis.dart';
import 'take_store.dart';
import 'take_style.dart';
import 'take_timeline.dart';

/// One take, analysed: the timeline, playback at any speed from 0.1× to
/// 1.5× (pitch held), each slide move and each note. Tapping a note selects
/// it, seeks to it and loops it.
class ReviewScreen extends StatefulWidget {
  final Take take;
  final SlideCalibration cal;
  final TakeStore? store;

  const ReviewScreen({
    super.key,
    required this.take,
    required this.cal,
    this.store,
  });

  static const double minSpeed = 0.1, maxSpeed = 1.5, speedStep = 0.05;
  static const presets = [0.25, 0.5, 0.75, 1.0, 1.25];

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen>
    with SingleTickerProviderStateMixin {
  late final TakeAnalysis _a = TakeAnalysis.analyze(widget.take, widget.cal);
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  AudioPlayer? _player;
  bool _hasAudio = false;
  StreamSubscription<PlayerState>? _stateSub;

  int _pos = 0; // on the take's clock
  bool _playing = false;
  double _speed = 0.5;
  bool _loopOn = false;
  int? _selected; // note index

  int get _dur => math.max(1, widget.take.durationMs);

  (int, int)? get _loop {
    if (!_loopOn) return null;
    if (_selected == null) return (0, _dur);
    final n = _a.notes[_selected!];
    return (math.max(0, n.startMs - 150), math.min(_dur, n.endMs + 150));
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _openAudio();
  }

  Future<void> _openAudio() async {
    final path = await widget.store?.audioPath(widget.take);
    if (path == null || !mounted) return;
    try {
      final p = AudioPlayer();
      await p.setFilePath(path);
      await p.setSpeed(_speed);
      if (!mounted) {
        p.dispose();
        return;
      }
      _stateSub = p.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed && _playing) {
          _pause();
          setState(() => _pos = _dur);
        }
      });
      setState(() {
        _player = p;
        _hasAudio = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Can\'t play the audio: $e')));
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _stateSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    if (!_playing) return;
    var pos = _player != null
        ? _player!.position.inMilliseconds + widget.take.audioOffsetMs
        : _pos + (dt.inMicroseconds / 1000 * _speed).round();
    final loop = _loop;
    if (loop != null && pos >= loop.$2) {
      _seek(loop.$1);
      return;
    }
    if (pos >= _dur && _player == null) {
      pos = _dur;
      _pause();
    }
    setState(() => _pos = pos);
  }

  void _play() {
    if (_pos >= _dur) _seek(_loop?.$1 ?? 0);
    setState(() => _playing = true);
    _lastTick = Duration.zero;
    if (!_ticker.isActive) _ticker.start();
    _player?.play();
  }

  void _pause() {
    setState(() => _playing = false);
    _ticker.stop();
    _player?.pause();
  }

  void _seek(int ms) {
    final t = ms.clamp(0, _dur);
    setState(() => _pos = t);
    _player?.seek(Duration(
        milliseconds: math.max(0, t - widget.take.audioOffsetMs)));
  }

  void _setSpeed(double v) {
    final s = ((v / ReviewScreen.speedStep).round() * ReviewScreen.speedStep)
        .clamp(ReviewScreen.minSpeed, ReviewScreen.maxSpeed);
    setState(() => _speed = s);
    _player?.setSpeed(s);
  }

  void _selectNote(int i) {
    setState(() {
      _selected = _selected == i ? null : i;
      if (_selected != null) _loopOn = true;
    });
    if (_selected != null) _seek(_loop!.$1);
  }

  void _stepNote(int dir) {
    final notes = _a.notes;
    if (notes.isEmpty) return;
    int i;
    if (dir > 0) {
      i = notes.indexWhere((n) => n.startMs > _pos + 50);
      if (i < 0) return;
    } else {
      i = notes.lastIndexWhere((n) => n.startMs < _pos - 300);
      if (i < 0) i = 0;
    }
    if (_selected != null) {
      setState(() => _selected = i);
    }
    _seek(_selected != null ? _loop!.$1 : notes[i].startMs);
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: widget.take.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this take'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. B♭ major scale'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    final t = title?.trim();
    if (t == null || t.isEmpty || t == widget.take.title) return;
    setState(() => widget.take.title = t);
    await widget.store?.save(widget.take, null);
  }

  @override
  Widget build(BuildContext context) {
    final take = widget.take;
    final started = take.started;
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${started.year}-${two(started.month)}-${two(started.day)} '
        '${two(started.hour)}:${two(started.minute)}';

    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        titleSpacing: 0,
        title: InkWell(
          onTap: _rename,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(take.title,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              Text('$when · ${(take.durationMs / 1000).toStringAsFixed(1)} s',
                  style: const TextStyle(fontSize: 12, color: TakeStyle.muted)),
            ],
          ),
        ),
        actions: [
          IconButton(
              tooltip: 'Rename',
              onPressed: _rename,
              icon: const Icon(Icons.edit_outlined)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _summary(),
          const SizedBox(height: 12),
          _card(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: const [
                      Text('SLIDE POSITION', style: TakeStyle.sectionLabel),
                      _Legend('▲', TakeStyle.over, 'Overshot'),
                      _Legend('▼', TakeStyle.short, 'Short'),
                      _Legend('┄', TakeStyle.muted, 'Target'),
                    ],
                  ),
                ),
                if (_a.notes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No notes heard in this take.',
                        style: TextStyle(color: TakeStyle.muted)),
                  )
                else
                  TakeTimeline(
                    analysis: _a,
                    playheadMs: _pos,
                    loop: _loop,
                    selectedNote: _selected,
                    onSeek: _seek,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _transport(),
          if (_a.shifts.isNotEmpty) ...[
            _heading('Slide moves',
                '${_a.shifts.length} shifts · avg ${_a.avgShiftMs.round()} ms'),
            _moves(),
          ],
          if (_a.notes.isNotEmpty) ...[
            _heading('Notes', 'Tap a note to loop it'),
            _notes(),
          ],
        ],
      ),
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: TakeStyle.card, borderRadius: BorderRadius.circular(16)),
        child: child,
      );

  Widget _heading(String title, String note) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: TakeStyle.text)),
            const Spacer(),
            Flexible(
              child: Text(note,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11, color: TakeStyle.muted)),
            ),
          ],
        ),
      );

  Widget _summary() {
    final n = _a.notes.length;
    return Row(
      children: [
        Expanded(
            child: StatTile(
                value: '${_a.inTuneCount}', unit: '/$n', label: 'In tune (±10¢)')),
        const SizedBox(width: 8),
        Expanded(
            child: StatTile(
                value: _a.avgAbsCents.toStringAsFixed(1),
                unit: '¢',
                label: 'Avg deviation')),
        const SizedBox(width: 8),
        Expanded(
            child: StatTile(
                value: '${_a.cleanShifts}',
                unit: '/${_a.shifts.length}',
                label: 'Clean shifts')),
      ],
    );
  }

  Widget _transport() {
    final loop = _loop;
    final loopLabel = !_loopOn
        ? null
        : _selected == null
            ? 'Looping the whole take'
            : 'Looping ${noteName(_a.notes[_selected!].midi)}';
    return _card(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              Text(clockLabel(_pos),
                  style: TakeStyle.mono
                      .copyWith(fontSize: 12, color: TakeStyle.text)),
              Expanded(
                child: Text(loopLabel ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: TakeStyle.muted)),
              ),
              Text(clockLabel(_dur),
                  style: TakeStyle.mono
                      .copyWith(fontSize: 12, color: TakeStyle.muted)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: TakeStyle.accent,
              inactiveTrackColor: TakeStyle.line,
              thumbColor: TakeStyle.accent,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            ),
            child: Slider(
              value: _pos.clamp(0, _dur).toDouble(),
              max: _dur.toDouble(),
              secondaryTrackValue: loop?.$2.toDouble(),
              onChanged: (v) => _seek(v.round()),
              semanticFormatterCallback: (v) => clockLabel(v.round()),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: _loopOn ? 'Stop looping' : 'Loop',
                isSelected: _loopOn,
                onPressed: () => setState(() => _loopOn = !_loopOn),
                style: IconButton.styleFrom(
                  foregroundColor: TakeStyle.muted,
                  side: BorderSide(
                      color: _loopOn ? TakeStyle.accent : TakeStyle.line),
                ),
                selectedIcon: const Icon(Icons.repeat, color: TakeStyle.accent),
                icon: const Icon(Icons.repeat),
              ),
              IconButton(
                tooltip: 'Previous note',
                iconSize: 28,
                onPressed: () => _stepNote(-1),
                icon: const Icon(Icons.skip_previous_rounded, color: TakeStyle.text),
              ),
              SizedBox(
                width: 64,
                height: 64,
                child: IconButton.filled(
                  tooltip: _playing ? 'Pause' : 'Play',
                  style: IconButton.styleFrom(
                      backgroundColor: TakeStyle.accent,
                      foregroundColor: TakeStyle.onAccent),
                  iconSize: 32,
                  onPressed: _playing ? _pause : _play,
                  icon: Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
              ),
              IconButton(
                tooltip: 'Next note',
                iconSize: 28,
                onPressed: () => _stepNote(1),
                icon: const Icon(Icons.skip_next_rounded, color: TakeStyle.text),
              ),
              const SizedBox(width: 48),
            ],
          ),
          if (!_hasAudio)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                  'No audio with this take: playback moves the playhead only.',
                  style: TextStyle(fontSize: 11, color: TakeStyle.muted)),
            ),
          const Divider(height: 24, color: TakeStyle.chip),
          _speedControl(),
        ],
      ),
    );
  }

  Widget _speedControl() {
    const range = ReviewScreen.maxSpeed - ReviewScreen.minSpeed;
    return Column(
      children: [
        const Row(
          children: [
            Expanded(
              child: Text('PLAYBACK SPEED',
                  style: TakeStyle.sectionLabel,
                  overflow: TextOverflow.ellipsis),
            ),
            Text('Pitch preserved',
                style: TextStyle(fontSize: 11, color: TakeStyle.muted)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            IconButton.outlined(
              tooltip: 'Slower',
              onPressed: _speed > ReviewScreen.minSpeed + 0.001
                  ? () => _setSpeed(_speed - ReviewScreen.speedStep)
                  : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Text('${_speed.toStringAsFixed(2)}×',
                  textAlign: TextAlign.center,
                  style: TakeStyle.mono.copyWith(
                      fontSize: 28,
                      fontWeight: FontWeight.w500,
                      color: TakeStyle.text)),
            ),
            IconButton.outlined(
              tooltip: 'Faster',
              onPressed: _speed < ReviewScreen.maxSpeed - 0.001
                  ? () => _setSpeed(_speed + ReviewScreen.speedStep)
                  : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: TakeStyle.accent,
            inactiveTrackColor: TakeStyle.line,
            thumbColor: TakeStyle.accent,
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Slider(
            value: _speed,
            min: ReviewScreen.minSpeed,
            max: ReviewScreen.maxSpeed,
            divisions: (range / ReviewScreen.speedStep).round(),
            label: '${_speed.toStringAsFixed(2)}×',
            onChanged: _setSpeed,
          ),
        ),
        LayoutBuilder(builder: (context, box) {
          // Presets sit under their spot on the slider (24 px track inset).
          const inset = 24.0;
          final track = box.maxWidth - 2 * inset;
          return SizedBox(
            height: 36,
            child: Stack(
              children: [
                for (final p in ReviewScreen.presets)
                  Positioned(
                    left: inset +
                        track * (p - ReviewScreen.minSpeed) / range -
                        26,
                    width: 52,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(52, 36),
                        foregroundColor: (_speed - p).abs() < 0.001
                            ? TakeStyle.accent
                            : TakeStyle.muted,
                        backgroundColor: (_speed - p).abs() < 0.001
                            ? const Color(0xFF1E2A3A)
                            : null,
                      ),
                      onPressed: () => _setSpeed(p),
                      child: Text('$p×',
                          style: TakeStyle.mono.copyWith(fontSize: 12)),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _moves() {
    final rows = <Widget>[];
    for (final n in _a.notes) {
      final s = n.shift;
      if (s == null) continue;
      final from = (1 + s.fromSemis.round()).clamp(1, 7);
      final to = n.targetPosition ?? from;
      final String detail;
      switch (s.result) {
        case ShiftResult.clean:
          detail = s.toBumper ? 'on the bumper' : 'landed ${posDelta(s.landedError)}';
        case ShiftResult.overshot:
          detail = '${posDelta(s.peakError)} → settled ${posDelta(s.landedError)}';
        case ShiftResult.short:
          detail = s.crept
              ? '${posDelta(s.firstStopError)}, crept on '
                  '${math.max(0, s.settleAfterOnsetMs)} ms late'
              : '${posDelta(s.landedError)}, stayed short';
      }
      rows.add(InkWell(
        onTap: () => _selectNote(n.index),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: n.index == _selected ? const Color(0xFF1E2430) : null,
            border: rows.isEmpty
                ? null
                : const Border(top: BorderSide(color: TakeStyle.chip)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 78,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      PositionBadge(from, size: 22),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 3),
                        child: Icon(Icons.arrow_forward,
                            size: 12, color: TakeStyle.muted),
                      ),
                      PositionBadge(to, size: 22),
                    ]),
                    const SizedBox(height: 3),
                    Text('into ${noteName(n.midi)}',
                        style: const TextStyle(fontSize: 11, color: TakeStyle.muted)),
                  ],
                ),
              ),
              SizedBox(
                width: 54,
                child: Text('${s.durationMs}ms',
                    textAlign: TextAlign.right,
                    style: TakeStyle.mono
                        .copyWith(fontSize: 13, color: TakeStyle.text)),
              ),
              SizedBox(
                width: 46,
                child: Text(s.peakSpeed.toStringAsFixed(1),
                    textAlign: TextAlign.right,
                    style: TakeStyle.mono
                        .copyWith(fontSize: 13, color: TakeStyle.body)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    TakeTag(TakeStyle.shiftTag(s.result)),
                    const SizedBox(height: 3),
                    Text(detail,
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11, color: TakeStyle.muted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
    }
    return Column(
      children: [
        Row(
          children: [
            Expanded(
                child: StatTile(
                    value: '${_a.overshoots}',
                    label: 'Overshot',
                    color: const Color(0xFFFFCC80))),
            const SizedBox(width: 8),
            Expanded(
                child: StatTile(
                    value: '${_a.shorts}',
                    label: 'Stopped short',
                    color: const Color(0xFFB0BCFF))),
            const SizedBox(width: 8),
            Expanded(
                child: StatTile(
                    value: _a.peakSpeed.toStringAsFixed(1), label: 'Peak pos/s')),
          ],
        ),
        const SizedBox(height: 8),
        _card(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 10, 14, 6),
                  child: Row(
                    children: [
                      SizedBox(width: 78, child: Text('SHIFT', style: _colHead)),
                      SizedBox(
                          width: 54,
                          child: Text('TIME',
                              textAlign: TextAlign.right, style: _colHead)),
                      SizedBox(
                          width: 46,
                          child: Text('PEAK',
                              textAlign: TextAlign.right, style: _colHead)),
                      Expanded(
                          child: Text('ARRIVAL',
                              textAlign: TextAlign.right, style: _colHead)),
                    ],
                  ),
                ),
                ...rows,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _notes() {
    return _card(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            for (final n in _a.notes)
              InkWell(
                onTap: () => _selectNote(n.index),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: n.index == _selected ? const Color(0xFF1E2430) : null,
                    border: n.index == 0
                        ? null
                        : const Border(top: BorderSide(color: TakeStyle.chip)),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(noteName(n.midi),
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: TakeStyle.text)),
                      ),
                      SizedBox(
                        width: 34,
                        child: n.targetPosition == null
                            ? const SizedBox()
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: PositionBadge(n.targetPosition!)),
                      ),
                      SizedBox(
                        width: 50,
                        child: Text(
                            n.landedSemis == null
                                ? '—'
                                : (1 + n.landedSemis!).toStringAsFixed(2),
                            style: TakeStyle.mono
                                .copyWith(fontSize: 13, color: TakeStyle.body)),
                      ),
                      SizedBox(
                        width: 50,
                        child: Text(centsLabel(n.cents),
                            textAlign: TextAlign.right,
                            style: TakeStyle.mono.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: TakeStyle.centsColor(n.cents))),
                      ),
                      const Spacer(),
                      TakeTag(TakeStyle.causeTag(n)),
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

const _colHead = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: TakeStyle.muted);

class _Legend extends StatelessWidget {
  final String mark;
  final Color color;
  final String label;
  const _Legend(this.mark, this.color, this.label);

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(mark, style: TextStyle(fontSize: 10, color: color)),
          const SizedBox(width: 3),
          Text(label, style: const TextStyle(fontSize: 11, color: TakeStyle.muted)),
        ],
      );
}
