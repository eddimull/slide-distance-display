import 'package:flutter/material.dart';

import 'account.dart';
import 'account_screen.dart';
import 'flash_card_screen.dart' show ordinal, thousands;
import 'seventh_api.dart';
import 'take_style.dart';

/// A game's online leaderboard on seventh.app, this week's or all time:
/// the top players, and where the signed-in player stands.
class LeaderboardView extends StatefulWidget {
  final Account account;
  final String gameId;
  final bool week;

  const LeaderboardView({
    super.key,
    required this.account,
    required this.gameId,
    required this.week,
  });

  @override
  State<LeaderboardView> createState() => _LeaderboardViewState();
}

class _LeaderboardViewState extends State<LeaderboardView>
    with AutomaticKeepAliveClientMixin {
  Board? _board;
  String? _error;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final b =
          await widget.account.leaderboard(widget.gameId, week: widget.week);
      if (!mounted) return;
      setState(() => _board = b);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _signIn() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AccountScreen(account: widget.account)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final b = _board;
    if (b == null) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error ?? 'Couldn\'t load the leaderboard.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: TakeStyle.muted)),
                  const SizedBox(height: 8),
                  TextButton(
                      key: const Key('retry'),
                      onPressed: _load,
                      child: const Text('Try again')),
                ],
              ),
      );
    }
    final myId = widget.account.signedIn ? widget.account.player!.id : null;
    final meListed = b.entries.any((e) => e.userId == myId);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (b.entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                  widget.week
                      ? 'No scores this week yet. Be the first!'
                      : 'No scores yet. Be the first!',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: TakeStyle.muted)),
            )
          else
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
                      SizedBox(width: 36, child: Text('#', style: _head)),
                      Expanded(child: Text('PLAYER', style: _head)),
                      Text('SCORE', style: _head),
                    ]),
                  ),
                  for (final e in b.entries) _row(e, mine: e.userId == myId),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (!widget.account.signedIn)
            Row(
              children: [
                const Expanded(
                  child: Text('Sign in to put your rounds on the leaderboards.',
                      style: TextStyle(fontSize: 13, color: TakeStyle.body)),
                ),
                TextButton(
                    key: const Key('board_sign_in'),
                    onPressed: _signIn,
                    child: const Text('Sign in')),
              ],
            )
          else if (b.me == null)
            Text(
                widget.week
                    ? 'You haven\'t posted a round this week.'
                    : 'You haven\'t posted a round yet.',
                style: const TextStyle(fontSize: 13, color: TakeStyle.body))
          else if (!meListed)
            Text(
                'You\'re ${ordinal(b.me!.rank)} of ${b.players}, '
                'with ${thousands(b.me!.score)}.',
                key: const Key('my_place'),
                style: const TextStyle(fontSize: 13, color: TakeStyle.body)),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                '${b.players} ${b.players == 1 ? 'player' : 'players'}'
                '${widget.week ? ' this week (from Monday, UTC)' : ''}. '
                'Each player\'s best round counts.',
                style: const TextStyle(fontSize: 12, color: TakeStyle.muted)),
          ),
        ],
      ),
    );
  }

  Widget _row(BoardEntry e, {required bool mine}) {
    final top = e.rank == 1;
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: mine
            ? const Color(0xFF1E2A3A)
            : top
                ? const Color(0xFF17291B)
                : null,
        border: const Border(top: BorderSide(color: TakeStyle.chip)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text('${e.rank}',
                style: TakeStyle.mono.copyWith(
                    fontSize: 13,
                    color: top ? const Color(0xFF8FD694) : TakeStyle.muted)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${e.displayName ?? 'Unnamed player'}${mine ? ' (you)' : ''}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: mine ? FontWeight.w600 : FontWeight.w500,
                        fontStyle: e.displayName == null
                            ? FontStyle.italic
                            : FontStyle.normal,
                        color: e.displayName == null
                            ? TakeStyle.muted
                            : TakeStyle.text)),
                Text('${e.found} found · combo ${e.bestCombo}',
                    style:
                        const TextStyle(fontSize: 11, color: TakeStyle.muted)),
              ],
            ),
          ),
          Text(thousands(e.score),
              style: TakeStyle.mono.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: TakeStyle.text)),
        ],
      ),
    );
  }
}

const _head = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: TakeStyle.muted);
