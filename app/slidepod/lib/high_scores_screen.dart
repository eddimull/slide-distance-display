import 'package:flutter/material.dart';

import 'account.dart';
import 'account_screen.dart';
import 'flash_card_screen.dart' show thousands;
import 'high_scores.dart';
import 'leaderboard_view.dart';
import 'take_style.dart';
import 'ui/seventh.dart';

/// A game the Scores screen can show.
class ScoreGame {
  final String id, title, subtitle;
  const ScoreGame(this.id, this.title, this.subtitle);
}

/// Scores: one game's leaderboards (this week, all time) and this phone's
/// best rounds, with the account at the bottom. With several [games] (from
/// the profile button), a row of them to switch between.
class HighScoresScreen extends StatefulWidget {
  final HighScores scores;
  final String gameId, title, subtitle;

  /// For the leaderboards and the account row (none when null or not
  /// offered).
  final Account? account;

  /// The games to switch between; just this one when null.
  final List<ScoreGame>? games;

  const HighScoresScreen({
    super.key,
    required this.scores,
    required this.gameId,
    required this.title,
    required this.subtitle,
    this.account,
    this.games,
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
  State<HighScoresScreen> createState() => _HighScoresScreenState();
}

class _HighScoresScreenState extends State<HighScoresScreen> {
  late ScoreGame _game = ScoreGame(widget.gameId, widget.title, widget.subtitle);

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final online = a != null && a.available;
    final games = widget.games;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (games != null && games.length > 1)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Seventh.gutter),
              children: [
                for (final g in games)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(g.title),
                      selected: g.id == _game.id,
                      showCheckmark: false,
                      selectedColor: Seventh.line,
                      onSelected: (_) => setState(() => _game = g),
                    ),
                  ),
              ],
            ),
          ),
        if (online)
          const Padding(
            padding: EdgeInsets.fromLTRB(Seventh.gutter, 8, Seventh.gutter, 10),
            child: _Segments(),
          ),
        Expanded(
          child: online
              ? TabBarView(
                  // A new game: new boards.
                  key: ValueKey(_game.id),
                  children: [
                    LeaderboardView(account: a, gameId: _game.id, week: true),
                    LeaderboardView(account: a, gameId: _game.id, week: false),
                    _Local(widget.scores, _game.id),
                  ],
                )
              : _Local(widget.scores, _game.id),
        ),
        if (online) _AccountRow(a),
      ],
    );
    final screen = Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Scores', style: Seventh.screenTitle),
            Text(_game.subtitle, style: Seventh.small),
          ],
        ),
      ),
      body: SafeArea(top: false, child: body),
    );
    // Signed in: this week's board first; else this phone's scores.
    return online
        ? DefaultTabController(
            length: 3, initialIndex: a.signedIn ? 0 : 2, child: screen)
        : screen;
  }
}

/// This week · All time · This phone, as the one segmented control.
class _Segments extends StatelessWidget {
  const _Segments();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
            color: Seventh.card, borderRadius: BorderRadius.circular(12)),
        child: TabBar(
          indicator: BoxDecoration(
              color: Seventh.line, borderRadius: BorderRadius.circular(9)),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          labelColor: Seventh.text,
          unselectedLabelColor: Seventh.muted,
          labelStyle: const TextStyle(
              fontFamily: Seventh.bodyFont, fontSize: 14, fontWeight: FontWeight.w600),
          unselectedLabelStyle:
              const TextStyle(fontFamily: Seventh.bodyFont, fontSize: 14),
          splashBorderRadius: BorderRadius.circular(9),
          tabs: const [
            Tab(key: Key('tab_week'), height: 36, text: 'This week'),
            Tab(key: Key('tab_all'), height: 36, text: 'All time'),
            Tab(key: Key('tab_phone'), height: 36, text: 'This phone'),
          ],
        ),
      );
}

/// The best rounds kept on this phone.
class _Local extends StatelessWidget {
  final HighScores scores;
  final String gameId;
  const _Local(this.scores, this.gameId);

  @override
  Widget build(BuildContext context) {
    final top = scores.top(gameId);
    if (top.isEmpty) {
      return const Center(
        child: Text('No scores yet. Play a round!',
            style: TextStyle(color: Seventh.muted)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Seventh.gutter, 0, Seventh.gutter, 16),
      children: [
        Container(
          decoration: BoxDecoration(
              color: Seventh.card,
              borderRadius: BorderRadius.circular(Seventh.cardRadius)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, e) in top.indexed)
                Container(
                  constraints: const BoxConstraints(minHeight: 54),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: i == 0 ? const Color(0xFF17291B) : null,
                    border: i == 0
                        ? null
                        : const Border(top: BorderSide(color: Seventh.raised)),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 26,
                        child: Text('${i + 1}',
                            style: Seventh.mono.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: i == 0 ? Seventh.inTune : Seventh.muted)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(i == 0 ? 'Best' : HighScoresScreen.dateLabel(e.at),
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: i == 0 ? FontWeight.w600 : FontWeight.w500,
                                    color: Seventh.text)),
                            Text(
                                i == 0
                                    ? '${HighScoresScreen.dateLabel(e.at)} · ${e.detail}'
                                    : e.detail,
                                style: const TextStyle(fontSize: 11, color: Seventh.muted)),
                          ],
                        ),
                      ),
                      Text(thousands(e.score),
                          style: Seventh.mono.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Seventh.text)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(2, 12, 2, 0),
          child: Text('Your best ${HighScores.keep} rounds stay on this phone.',
              style: TextStyle(fontSize: 13, color: TakeStyle.body)),
        ),
      ],
    );
  }
}

/// Who you are on the leaderboards, and the way to the account.
class _AccountRow extends StatelessWidget {
  final Account account;
  const _AccountRow(this.account);

  void _open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => AccountScreen(account: account)));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: account,
        builder: (context, _) {
          final name = account.player?.displayName;
          final signedIn = account.signedIn;
          return Container(
            margin: const EdgeInsets.fromLTRB(Seventh.gutter, 8, Seventh.gutter, 12),
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
                color: Seventh.card,
                borderRadius: BorderRadius.circular(Seventh.cardRadius)),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: signedIn ? const Color(0xFF2A3A4E) : Seventh.raised,
                  child: signedIn && name != null && name.isNotEmpty
                      ? Text(name.characters.first.toUpperCase(),
                          style: const TextStyle(
                              fontFamily: Seventh.titleFont,
                              fontWeight: FontWeight.w600,
                              color: Seventh.accentSoft))
                      : Icon(signedIn ? Icons.person : Icons.person_outline,
                          size: 20, color: Seventh.body),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          signedIn
                              ? name ?? 'No leaderboard name yet'
                              : 'Not signed in',
                          style: Seventh.heading.copyWith(fontSize: 15)),
                      Text(
                          signedIn
                              ? 'Your rounds go on the leaderboards'
                              : 'Sign in to put your rounds on them',
                          style: Seventh.small),
                    ],
                  ),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      textStyle: const TextStyle(
                          fontFamily: Seventh.bodyFont,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  onPressed: () => _open(context),
                  child: Text(signedIn ? 'Account' : 'Sign in'),
                ),
              ],
            ),
          );
        },
      );
}
