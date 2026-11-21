import 'package:flutter/material.dart';

import 'flash_card_screen.dart';
import 'gliss_take.dart';
import 'high_scores.dart';
import 'high_scores_screen.dart';
import 'slide_calibration.dart';
import 'take_style.dart';

/// What a game gets from the app.
class LearnContext {
  final Stream<CalFrame> frames;
  final SlideCalibration cal;
  final HighScores scores;
  const LearnContext(
      {required this.frames, required this.cal, required this.scores});
}

/// A level opens once the best score in [gameId] reaches [score].
class LevelGate {
  final String gameId, gameTitle;
  final int score;
  const LevelGate(this.gameId, this.gameTitle, this.score);
}

/// A level in the Learn list. [build] is null for one not made yet.
class LearnLevel {
  final int level;
  final String? levelName;
  final String title;
  final String? gameId;
  final String blurb;
  final String? scoring;

  /// Needs the horn played (pitch), not just the slide.
  final bool needsPlaying;

  /// What opens it; null = open as soon as the level before is.
  final LevelGate? gate;
  final Widget Function(LearnContext c)? build;

  const LearnLevel({
    required this.level,
    this.levelName,
    required this.title,
    this.gameId,
    required this.blurb,
    this.scoring,
    this.needsPlaying = false,
    this.gate,
    this.build,
  });
}

/// The levels, easiest first. New games go here.
final learnLevels = <LearnLevel>[
  LearnLevel(
    level: 1,
    levelName: 'Getting started',
    title: FlashCardScreen.title,
    gameId: FlashCardScreen.gameId,
    blurb: 'A position number comes up: put the slide there and hold it. '
        'Faster scores more.',
    build: (c) =>
        FlashCardScreen(frames: c.frames, cal: c.cal, scores: c.scores),
  ),
  const LearnLevel(
    level: 2,
    title: 'Coming soon',
    blurb: 'The next game.',
    gate: LevelGate(FlashCardScreen.gameId, FlashCardScreen.title, 15000),
  ),
  const LearnLevel(
    level: 3,
    title: 'Coming soon',
    blurb: 'Needs playing: pitch and slide.',
    needsPlaying: true,
  ),
];

/// Whether each of [levels] is open: the first always; each after it once
/// the one before is open and playable (a level with no game yet holds the
/// rest back) and its own gate, if any, is met.
List<bool> unlockedLevels(List<LearnLevel> levels, HighScores scores) {
  final out = <bool>[];
  for (final (i, l) in levels.indexed) {
    final prev = i == 0 || (out[i - 1] && levels[i - 1].build != null);
    final g = l.gate;
    final met = g == null || (scores.best(g.gameId)?.score ?? 0) >= g.score;
    out.add(prev && met);
  }
  return out;
}

/// Games for learning the slide positions, each with its own high scores.
/// Shown as the Learn tab.
class LearnScreen extends StatefulWidget {
  final LearnContext learn;
  final bool connected;
  final List<LearnLevel>? levels;

  const LearnScreen({
    super.key,
    required this.learn,
    this.connected = true,
    this.levels,
  });

  @override
  State<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends State<LearnScreen> {
  List<LearnLevel> get _levels => widget.levels ?? learnLevels;

  Future<void> _play(LearnLevel l) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => l.build!(widget.learn)));
    if (mounted) setState(() {}); // new scores, maybe a level opened
  }

  void _scores(LearnLevel l) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HighScoresScreen(
          scores: widget.learn.scores,
          gameId: l.gameId!,
          title: l.title,
          subtitle: '${l.title} · Level ${l.level}',
        ),
      ));

  @override
  Widget build(BuildContext context) {
    final open = unlockedLevels(_levels, widget.learn.scores);
    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        automaticallyImplyLeading: false,
        title: const Text('Learn',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(
                'Games for learning your slide positions. Beat your high '
                'score, then move up a level.',
                style: TextStyle(fontSize: 14, height: 1.45, color: TakeStyle.body)),
          ),
          if (!widget.connected)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text('Connect the slide pod to play.',
                  style: TextStyle(fontSize: 13, color: TakeStyle.warn)),
            ),
          for (final (i, l) in _levels.indexed)
            if (open[i] && l.build != null)
              _gameCard(l)
            else
              _lockedCard(l, open[i],
                  i == 0 || (open[i - 1] && _levels[i - 1].build != null)),
        ],
      ),
    );
  }

  Widget _gameCard(LearnLevel l) {
    final best = widget.learn.scores.best(l.gameId!);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: TakeStyle.card, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    'LEVEL ${l.level}'
                    '${l.levelName == null ? '' : ' · ${l.levelName!.toUpperCase()}'}',
                    style: TakeStyle.sectionLabel),
              ),
              if (!l.needsPlaying)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: const Color(0xFF1E2A3A),
                      borderRadius: BorderRadius.circular(6)),
                  child: const Text('No playing',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF90CAF9))),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(l.title,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w600, color: TakeStyle.text)),
          const SizedBox(height: 6),
          Text(l.blurb,
              style: const TextStyle(fontSize: 14, height: 1.45, color: TakeStyle.body)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('High score',
                        style: TextStyle(fontSize: 11, color: TakeStyle.muted)),
                    Text(best == null ? '–' : '${best.score}',
                        style: TakeStyle.mono.copyWith(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: TakeStyle.text)),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => _scores(l),
                child: const Text('High scores'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(88, 44),
                  backgroundColor: TakeStyle.accent,
                  foregroundColor: TakeStyle.onAccent,
                  textStyle:
                      const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                onPressed: widget.connected ? () => _play(l) : null,
                child: const Text('Play'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _lockedCard(LearnLevel l, bool open, bool prevOpen) {
    final g = l.gate;
    final best = g == null ? null : widget.learn.scores.best(g.gameId)?.score ?? 0;
    final String need;
    if (open) {
      need = 'Unlocked. The game is on its way.';
    } else if (g != null && prevOpen) {
      need = 'Score ${_thousands(g.score)} in ${g.gameTitle} to unlock';
    } else {
      need = 'Unlocks from Level ${l.level - 1}';
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF14171C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TakeStyle.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(open ? Icons.lock_open_outlined : Icons.lock_outline,
              size: 22, color: TakeStyle.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LEVEL ${l.level}', style: TakeStyle.sectionLabel),
                Text(l.title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500, color: TakeStyle.body)),
                const SizedBox(height: 2),
                Text(
                    [if (l.needsPlaying) 'Needs playing: pitch and slide.', need]
                        .join(' '),
                    style: const TextStyle(fontSize: 12, color: TakeStyle.muted)),
                if (g != null && prevOpen && !open) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: (best! / g.score).clamp(0.0, 1.0),
                            minHeight: 6,
                            backgroundColor: TakeStyle.chip,
                            color: TakeStyle.accent,
                            semanticsLabel:
                                'Progress to unlock: $best of ${g.score}',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${_thousands(best)} / ${_thousands(g.score)}',
                          style: TakeStyle.mono
                              .copyWith(fontSize: 11, color: TakeStyle.body)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 15000 → "15,000".
String _thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
