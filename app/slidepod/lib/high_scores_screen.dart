import 'package:flutter/material.dart';

import 'high_scores.dart';
import 'take_style.dart';

/// One game's high-score table: the top three on a podium, then the list.
class HighScoresScreen extends StatelessWidget {
  final HighScores scores;
  final String gameId, title, subtitle;

  const HighScoresScreen({
    super.key,
    required this.scores,
    required this.gameId,
    required this.title,
    required this.subtitle,
  });

  static String dateLabel(DateTime t, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(n.year, n.month, n.day);
    final ago = today.difference(day).inDays;
    if (ago == 0) return 'Today';
    if (ago == 1) return 'Yesterday';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[t.month - 1]} ${t.day}';
  }

  @override
  Widget build(BuildContext context) {
    final top = scores.top(gameId);
    return Scaffold(
      backgroundColor: TakeStyle.ground,
      appBar: AppBar(
        backgroundColor: TakeStyle.ground,
        foregroundColor: TakeStyle.text,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('High scores',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text(subtitle,
                style: const TextStyle(fontSize: 12, color: TakeStyle.muted)),
          ],
        ),
      ),
      body: top.isEmpty
          ? const Center(
              child: Text('No scores yet. Play a round!',
                  style: TextStyle(color: TakeStyle.muted)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _podium(top),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                      color: TakeStyle.card,
                      borderRadius: BorderRadius.circular(16)),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(14, 10, 14, 6),
                        child: Row(children: [
                          SizedBox(width: 30, child: Text('#', style: _head)),
                          SizedBox(width: 72, child: Text('SCORE', style: _head)),
                          Expanded(child: Text('ROUND', style: _head)),
                          Text('DATE', style: _head),
                        ]),
                      ),
                      for (final (i, e) in top.indexed)
                        Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: i == 0 ? const Color(0xFF17291B) : null,
                            border: const Border(
                                top: BorderSide(color: TakeStyle.chip)),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 30,
                                child: Text('${i + 1}',
                                    style: TakeStyle.mono.copyWith(
                                        fontSize: 13,
                                        color: i == 0
                                            ? const Color(0xFF8FD694)
                                            : TakeStyle.muted)),
                              ),
                              SizedBox(
                                width: 72,
                                child: Text('${e.score}',
                                    style: TakeStyle.mono.copyWith(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: TakeStyle.text)),
                              ),
                              Expanded(
                                child: Text(e.detail,
                                    style: const TextStyle(
                                        fontSize: 12, color: TakeStyle.body)),
                              ),
                              Text(dateLabel(e.at),
                                  style: const TextStyle(
                                      fontSize: 12, color: TakeStyle.muted)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 10, 4, 0),
                  child: Text(
                      'Your best ${HighScores.keep} rounds are kept on this phone.',
                      style: TextStyle(fontSize: 12, color: TakeStyle.muted)),
                ),
              ],
            ),
    );
  }

  Widget _podium(List<ScoreEntry> top) {
    Widget step(int place, double height) {
      final e = place <= top.length ? top[place - 1] : null;
      final first = place == 1;
      return Expanded(
        child: Container(
          constraints: BoxConstraints(minHeight: height),
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
          decoration: BoxDecoration(
            color: first ? const Color(0xFF1E3A24) : TakeStyle.card,
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14), bottom: Radius.circular(8)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (first)
                const Icon(Icons.emoji_events_outlined,
                    size: 22, color: Color(0xFF8FD694)),
              Text(first ? 'Best' : place == 2 ? '2nd' : '3rd',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: first ? const Color(0xFF8FD694) : TakeStyle.body)),
              const SizedBox(height: 2),
              Text(e == null ? '–' : '${e.score}',
                  style: TakeStyle.mono.copyWith(
                      fontSize: first ? 22 : 18,
                      fontWeight: FontWeight.w600,
                      color: TakeStyle.text)),
            ],
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        step(2, 96),
        const SizedBox(width: 8),
        step(1, 124),
        const SizedBox(width: 8),
        step(3, 80),
      ],
    );
  }
}

const _head = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: TakeStyle.muted);
