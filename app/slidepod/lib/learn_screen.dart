import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'account.dart';
import 'account_screen.dart';
import 'flash_card_screen.dart';
import 'gliss_take.dart';
import 'high_scores.dart';
import 'high_scores_screen.dart';
import 'slide_calibration.dart';
import 'take_style.dart';
import 'ui/seventh.dart';

/// What a game gets from the app.
class LearnContext {
  final Stream<CalFrame> frames;
  final SlideCalibration cal;
  final HighScores scores;

  /// The online leaderboards account (null: not offered).
  final Account? account;

  /// Turns the mic on, for the levels that need playing.
  final Future<void> Function()? ensureMic;

  /// The compact pod pill, for a round's header.
  final WidgetBuilder? pod;

  /// Whether the pod is connected, as it changes (for screens pushed on
  /// top of the tab), and how to connect it (null: can't from here, or
  /// already connecting).
  final ValueListenable<bool>? connection;
  final VoidCallback? connect;

  /// True while [connect] is scanning for or connecting to the pod.
  final ValueListenable<bool>? searching;
  const LearnContext(
      {required this.frames,
      required this.cal,
      required this.scores,
      this.account,
      this.ensureMic,
      this.pod,
      this.connection,
      this.connect,
      this.searching});
}

/// Not connected: a button that connects the pod (the same as the pod
/// pill), showing it's searching while it does; or just the note when it
/// can't connect from here.
class ConnectPrompt extends StatelessWidget {
  final VoidCallback? onConnect;
  final ValueListenable<bool>? searching;
  const ConnectPrompt({super.key, this.onConnect, this.searching});

  @override
  Widget build(BuildContext context) {
    final connect = onConnect;
    if (connect == null) {
      return const Text('Connect the slide pod to play.',
          style: TextStyle(fontSize: 13, color: TakeStyle.warn));
    }
    return ValueListenableBuilder<bool>(
      valueListenable: searching ?? ValueNotifier(false),
      builder: (context, busy, _) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            foregroundColor: TakeStyle.text,
            disabledForegroundColor: TakeStyle.body,
            side: const BorderSide(color: TakeStyle.accent)),
        onPressed: busy ? null : connect,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: TakeStyle.accent))
            : const Icon(Icons.bluetooth, size: 20, color: TakeStyle.accent),
        label: Text(busy
            ? 'Searching for the slide pod…'
            : 'Connect the slide pod to play'),
      ),
    );
  }
}

/// The score in a level that opens the next one.
const levelUpScore = 15000;

/// A game in the Learn tab, with its own ladder of [levels]: Level 1 is
/// always open, and each after it opens at [levelUpScore] in the one
/// before.
class LearnGame {
  final String tag, title, blurb;

  /// Needs the horn played (pitch), not just the slide.
  final bool needsPlaying;
  final List<FlashGameSpec> levels;

  const LearnGame({
    required this.tag,
    required this.title,
    required this.blurb,
    this.needsPlaying = false,
    required this.levels,
  });

  /// Which levels are open.
  List<bool> open(HighScores s) {
    int best(String id) => s.best(id)?.score ?? 0;
    final out = <bool>[];
    for (var i = 0; i < levels.length; i++) {
      out.add(i == 0 || out[i - 1] && best(levels[i - 1].id) >= levelUpScore);
    }
    return out;
  }

  /// The highest open level.
  FlashGameSpec current(HighScores s) => levels[open(s).lastIndexOf(true)];

  /// What a level is called on the scores screen.
  ScoreGame scoreGame(FlashGameSpec l) => ScoreGame(
      l.id, '$title ${l.level}', '$title · Level ${l.level} · ${l.levelName}');
}

/// The Learn games, easiest first. Each has its own levels, and every
/// game's Level 1 is open from the start.
final learnGames = <LearnGame>[
  LearnGame(
    tag: 'POSITIONS',
    title: 'Position Flash',
    blurb: 'A position number comes up: put the slide there and hold it. '
        'Faster scores more.',
    levels: positionFlashLevels,
  ),
  LearnGame(
    tag: 'READING NOTES',
    title: 'Note Flash',
    blurb: 'A note comes up on the staff: put the slide in a position that '
        'plays it. No need to play.',
    levels: noteFlashLevels,
  ),
  LearnGame(
    tag: 'PLAYING',
    title: 'Play the Note',
    blurb: 'A note comes up: play it, with the slide in a position for it. '
        'In tune earns a bonus.',
    needsPlaying: true,
    levels: playTheNoteLevels,
  ),
];

/// Every open level, for the scores screen.
List<ScoreGame> openScoreGames(HighScores s) => [
      for (final g in learnGames)
        for (final (i, l) in g.levels.indexed)
          if (g.open(s)[i]) g.scoreGame(l),
    ];

/// Plays [level] of [game]; back when the round screen closes.
Future<void> playLevel(BuildContext context, LearnContext learn, LearnGame game,
    FlashGameSpec level) {
  return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FlashCardScreen(
            frames: learn.frames,
            cal: learn.cal,
            scores: learn.scores,
            account: learn.account,
            pod: learn.pod,
            spec: level,
            ensureMic: game.needsPlaying ? learn.ensureMic : null,
          )));
}

/// The Learn tab: one card per game, its current level and Play. Tap a
/// card for the game's levels.
class LearnScreen extends StatefulWidget {
  final LearnContext learn;
  final bool connected;
  final List<LearnGame>? games;

  /// The tab's top bar (title, pod, profile). Null: a plain one with an
  /// account button.
  final PreferredSizeWidget? topBar;

  const LearnScreen({
    super.key,
    this.topBar,
    required this.learn,
    this.connected = true,
    this.games,
  });

  @override
  State<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends State<LearnScreen> {
  List<LearnGame> get _games => widget.games ?? learnGames;

  Future<void> _play(LearnGame g, FlashGameSpec l) async {
    await playLevel(context, widget.learn, g, l);
    if (mounted) setState(() {}); // new scores, maybe a level opened
  }

  Future<void> _levels(LearnGame g) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LearnLevelsScreen(
            game: g, learn: widget.learn, connected: widget.connected)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: widget.topBar ?? AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        automaticallyImplyLeading: false,
        title: const Text('Learn',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        actions: [
          if (widget.learn.account case final a? when a.available)
            ListenableBuilder(
              listenable: a,
              builder: (context, _) => IconButton(
                key: const Key('account'),
                tooltip: a.signedIn ? 'Leaderboards account' : 'Sign in for leaderboards',
                icon: Icon(a.signedIn
                    ? Icons.account_circle
                    : Icons.account_circle_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AccountScreen(account: a))),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(
                'Thirty-second games. Score ${thousands(levelUpScore)} to open '
                'each game\'s next level.',
                style: const TextStyle(fontSize: 14, height: 1.45, color: TakeStyle.body)),
          ),
          if (!widget.connected)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: ConnectPrompt(
                  onConnect: widget.learn.connect,
                  searching: widget.learn.searching),
            ),
          for (final g in _games) _gameCard(g),
        ],
      ),
    );
  }

  Widget _gameCard(LearnGame g) {
    final s = widget.learn.scores;
    final open = g.open(s);
    final cur = g.current(s);
    final best = s.best(cur.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: TakeStyle.card, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            onTap: () => _levels(g),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(g.tag, style: TakeStyle.sectionLabel),
                        const SizedBox(height: 4),
                        Text(g.title,
                            style: Seventh.screenTitle.copyWith(fontSize: 22)),
                        const SizedBox(height: 2),
                        Text('Level ${cur.level} of ${g.levels.length} · ${cur.levelName}',
                            style: const TextStyle(fontSize: 13, color: TakeStyle.muted)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      color: TakeStyle.muted, semanticLabel: 'Levels'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LevelDots(open: open, current: cur.level),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    cur.level < g.levels.length
                                        ? 'Best · ${thousands(levelUpScore)} opens Level ${cur.level + 1}'
                                        : 'Best',
                                    style: const TextStyle(
                                        fontSize: 11, color: TakeStyle.muted)),
                                Text(best == null ? '–' : thousands(best.score),
                                    style: TakeStyle.mono.copyWith(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                        color: TakeStyle.text)),
                              ],
                            ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
                      onPressed: widget.connected ? () => _play(g, cur) : null,
                      child: const Text('Play'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A game's levels as a row of bars: passed green, the current one blue,
/// the rest grey.
class LevelDots extends StatelessWidget {
  final List<bool> open;
  final int current;
  const LevelDots({super.key, required this.open, required this.current});

  @override
  Widget build(BuildContext context) {
    final n = open.length;
    return Semantics(
      label: 'Level $current of $n',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var i = 0; i < n; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i + 1 == current
                        ? TakeStyle.accent
                        : open[i]
                            ? TakeStyle.good
                            : TakeStyle.line,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One game's levels: each with its range and best score, the locked ones
/// with what opens them. Tap an open level to play it.
class LearnLevelsScreen extends StatefulWidget {
  final LearnGame game;
  final LearnContext learn;
  final bool connected;
  const LearnLevelsScreen(
      {super.key, required this.game, required this.learn, this.connected = true});

  @override
  State<LearnLevelsScreen> createState() => _LearnLevelsScreenState();
}

class _LearnLevelsScreenState extends State<LearnLevelsScreen> {
  LearnGame get g => widget.game;

  /// Connected now: from the app as it changes, else as it was on opening.
  bool get _connected => widget.learn.connection?.value ?? widget.connected;

  @override
  void initState() {
    super.initState();
    widget.learn.connection?.addListener(_changed);
  }

  @override
  void dispose() {
    widget.learn.connection?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _play(FlashGameSpec l) async {
    await playLevel(context, widget.learn, g, l);
    if (mounted) setState(() {});
  }

  void _scores() {
    final s = widget.learn.scores;
    final games = [
      for (final (i, l) in g.levels.indexed)
        if (g.open(s)[i]) g.scoreGame(l),
    ];
    final first = games.isEmpty ? g.scoreGame(g.levels.first) : games.last;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HighScoresScreen(
              scores: s,
              gameId: first.id,
              title: first.title,
              subtitle: first.subtitle,
              account: widget.learn.account,
              games: games,
            )));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.learn.scores;
    final open = g.open(s);
    final cur = g.current(s);
    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        title: Text(g.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          TextButton(onPressed: _scores, child: const Text('Scores')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        children: [
          Text(g.tag, style: TakeStyle.sectionLabel),
          const SizedBox(height: 6),
          Text('${g.blurb} Score ${thousands(levelUpScore)} to open the next level.',
              style: const TextStyle(fontSize: 14, height: 1.45, color: TakeStyle.body)),
          if (!_connected) ...[
            const SizedBox(height: 12),
            ConnectPrompt(
                onConnect: widget.learn.connect,
                searching: widget.learn.searching),
          ],
          const SizedBox(height: 16),
          for (final (i, l) in g.levels.indexed)
            _level(l, open[i], l == cur, i == 0 ? null : g.levels[i - 1]),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _connected ? () => _play(cur) : null,
            child: Text('Play Level ${cur.level} · ${cur.levelName}'),
          ),
        ),
      ),
    );
  }

  Widget _level(FlashGameSpec l, bool open, bool current, FlashGameSpec? before) {
    final best = widget.learn.scores.best(l.id);
    final passed = open && !current;
    final String detail;
    if (open || before == null) {
      detail = l.summary;
    } else {
      detail = '${thousands(levelUpScore)} in Level ${before.level} opens it';
    }
    final badge = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: current
            ? TakeStyle.accent
            : passed
                ? Seventh.inTuneBg
                : null,
        border: open ? null : Border.all(color: TakeStyle.line),
      ),
      child: passed
          ? const Icon(Icons.check, size: 16, color: TakeStyle.good, semanticLabel: 'Passed')
          : Text('${l.level}',
              style: TakeStyle.mono.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: current ? TakeStyle.onAccent : TakeStyle.muted)),
    );
    final row = Row(
      children: [
        badge,
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(current ? 'LEVEL ${l.level} · NOW' : 'LEVEL ${l.level}',
                  style: TakeStyle.sectionLabel.copyWith(
                      fontSize: 11,
                      color: current ? Seventh.accentSoft : TakeStyle.muted)),
              Text(l.levelName,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: open ? TakeStyle.text : TakeStyle.muted)),
              Text(detail,
                  style: const TextStyle(fontSize: 12, color: TakeStyle.muted)),
            ],
          ),
        ),
        if (open)
          Text(best == null ? '–' : thousands(best.score),
              style: TakeStyle.mono.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: passed ? TakeStyle.good : TakeStyle.text))
        else
          const Icon(Icons.lock_outline, size: 18, color: TakeStyle.muted,
              semanticLabel: 'Locked'),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: current ? TakeStyle.chip : (open ? TakeStyle.card : Colors.transparent),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
              color: current
                  ? TakeStyle.accent
                  : (open ? Colors.transparent : TakeStyle.chip)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: open && _connected ? () => _play(l) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: row,
          ),
        ),
      ),
    );
  }
}
