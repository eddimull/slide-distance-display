import 'dart:convert';

import 'package:http/http.dart' as http;

/// The Seventh server (seventh-server): sign-in, rounds and leaderboards.
/// Override the address with `--dart-define=SEVENTH_API=http://…/api`.
const seventhApiBase =
    String.fromEnvironment('SEVENTH_API', defaultValue: 'https://seventh.app/api');

/// A request the server turned down, with its reason (shown to the player).
class ApiException implements Exception {
  final int status;
  final String message;
  const ApiException(this.status, this.message);

  /// 401: the token is no good any more (revoked, or the account deleted).
  bool get signedOut => status == 401;

  /// 409: the scoring changed; this version of the app can't post scores.
  bool get outdated => status == 409;

  @override
  String toString() => message;
}

class Player {
  final int id;
  final String? displayName;
  const Player(this.id, this.displayName);

  static Player fromJson(Map<String, dynamic> m) =>
      Player((m['id'] as num).toInt(), m['display_name'] as String?);
}

class SignIn {
  final String token;
  final Player player;
  const SignIn(this.token, this.player);
}

/// Where a score stands on a board: 1 = top.
class Standing {
  final int rank, score;
  const Standing(this.rank, this.score);

  static Standing? fromJson(Object? m) => m is Map<String, dynamic>
      ? Standing((m['rank'] as num).toInt(), (m['score'] as num).toInt())
      : null;
}

/// A round as the server scored it, and the player's place afterwards.
class PostedRound {
  final int score;
  final Standing? all, week;
  const PostedRound(this.score, this.all, this.week);
}

/// One player's best on a board.
class BoardEntry {
  final int rank, userId, score, found, bestCombo;
  final String? displayName;
  final DateTime at;
  const BoardEntry({
    required this.rank,
    required this.userId,
    required this.displayName,
    required this.score,
    required this.found,
    required this.bestCombo,
    required this.at,
  });

  static BoardEntry fromJson(Map<String, dynamic> m) => BoardEntry(
        rank: (m['rank'] as num).toInt(),
        userId: (m['user_id'] as num).toInt(),
        displayName: m['display_name'] as String?,
        score: (m['score'] as num).toInt(),
        found: (m['found'] as num?)?.toInt() ?? 0,
        bestCombo: (m['best_combo'] as num?)?.toInt() ?? 0,
        at: DateTime.parse(m['achieved_at'] as String).toLocal(),
      );
}

/// A game's online board for one period: the top [entries], how many
/// [players] are on it, and (signed in, with a score there) [me].
class Board {
  final int players;
  final List<BoardEntry> entries;
  final Standing? me;
  const Board(this.players, this.entries, this.me);
}

class SeventhApi {
  final String base;
  final http.Client _http;

  SeventhApi({this.base = seventhApiBase, http.Client? client})
      : _http = client ?? http.Client();

  Future<SignIn> signInWithGoogle(String idToken, {String? device}) async {
    final m = await _send('POST', '/auth/google',
        body: {'id_token': idToken, 'device': ?device});
    return SignIn(m['token'] as String,
        Player.fromJson(m['user'] as Map<String, dynamic>));
  }

  /// [code] is Apple's authorization code: the server exchanges it so that
  /// deleting the account can revoke Sign in with Apple.
  Future<SignIn> signInWithApple(String idToken,
      {String? code, String? device}) async {
    final m = await _send('POST', '/auth/apple',
        body: {'id_token': idToken, 'code': ?code, 'device': ?device});
    return SignIn(m['token'] as String,
        Player.fromJson(m['user'] as Map<String, dynamic>));
  }

  Future<Player> me(String token) async => Player.fromJson(
      (await _send('GET', '/me', token: token))['user'] as Map<String, dynamic>);

  Future<Player> setName(String token, String name) async => Player.fromJson(
      (await _send('PATCH', '/me', token: token, body: {'display_name': name}))[
          'user'] as Map<String, dynamic>);

  Future<void> signOut(String token) =>
      _send('POST', '/auth/sign-out', token: token);

  /// Deletes the player, their rounds and scores.
  Future<void> deleteAccount(String token) =>
      _send('DELETE', '/me', token: token);

  /// [cards] are the round's [CardResult.toLog]s; the server re-scores them.
  Future<PostedRound> postRound(
    String token, {
    required String game,
    required int rulesVersion,
    required String platform,
    required int clientScore,
    required List<Map<String, Object?>> cards,
  }) async {
    final m = await _send('POST', '/rounds', token: token, body: {
      'game': game,
      'rules_version': rulesVersion,
      'platform': platform,
      'client_score': clientScore,
      'cards': cards,
    });
    return PostedRound((m['score'] as num).toInt(), Standing.fromJson(m['all']),
        Standing.fromJson(m['week']));
  }

  /// [week]: this week's board (from Monday, UTC), else all time. With
  /// [token], the board says where the player stands.
  Future<Board> leaderboard(String game, {bool week = false, String? token}) async {
    final m = await _send(
        'GET', '/leaderboards/$game?period=${week ? 'week' : 'all'}',
        token: token);
    return Board(
      (m['players'] as num?)?.toInt() ?? 0,
      [
        for (final e in (m['entries'] as List? ?? const []))
          BoardEntry.fromJson(e as Map<String, dynamic>)
      ],
      Standing.fromJson(m['me']),
    );
  }

  Future<Map<String, dynamic>> _send(String method, String path,
      {String? token, Map<String, Object?>? body}) async {
    final req = http.Request(method, Uri.parse('$base$path'))
      ..headers['Accept'] = 'application/json';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(
          await _http.send(req).timeout(const Duration(seconds: 15)));
    } catch (_) {
      throw const ApiException(0, 'Couldn\'t reach the Seventh server.');
    }
    final Object? json = res.body.isEmpty ? null : _decode(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return json is Map<String, dynamic> ? json : const {};
    }
    final msg = json is Map<String, dynamic> ? json['message'] : null;
    throw ApiException(res.statusCode,
        msg is String ? msg : 'The server said no (${res.statusCode}).');
  }

  static Object? _decode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }
}
