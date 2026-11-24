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

  /// The response, when it says more (a 409 on a calibration carries the
  /// newer copy).
  final Map<String, dynamic>? body;
  const ApiException(this.status, this.message, {this.body});

  /// 401: the token is no good any more (revoked, or the account deleted).
  bool get signedOut => status == 401;

  /// 409: the scoring changed; this version of the app can't post scores.
  /// (Linking a pod: it's on another account.)
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

/// A SlidePod linked to the player's account.
class LinkedPod {
  final int id;
  final String serial;
  final String? name, firmware;
  const LinkedPod(this.id, this.serial, this.name, this.firmware);

  static LinkedPod fromJson(Map<String, dynamic> m) => LinkedPod(
        (m['id'] as num).toInt(),
        m['serial'] as String,
        m['name'] as String?,
        m['firmware'] as String?,
      );
}

/// One of the player's instruments; [calibration] only when fetched one at
/// a time (the app's SlideCalibration JSON).
class Instrument {
  final int id;
  final String name, kind;
  final String? make;
  final int? podId;
  final bool hasCalibration;
  final DateTime? calibrationAt;
  final String? calibration;
  const Instrument({
    required this.id,
    required this.name,
    required this.kind,
    this.make,
    this.podId,
    this.hasCalibration = false,
    this.calibrationAt,
    this.calibration,
  });

  static const kinds = {
    'tenor': 'Tenor',
    'tenor_f': 'Tenor with F attachment',
    'bass': 'Bass',
    'alto': 'Alto',
    'other': 'Other',
  };

  String get kindLabel => kinds[kind] ?? kind;

  static Instrument fromJson(Map<String, dynamic> m) {
    final cal = m['calibration'];
    final at = m['calibration_updated_at'] as String?;
    return Instrument(
      id: (m['id'] as num).toInt(),
      name: m['name'] as String,
      kind: m['kind'] as String,
      make: m['make'] as String?,
      podId: (m['pod_id'] as num?)?.toInt(),
      hasCalibration: m['has_calibration'] == true || cal != null,
      calibrationAt: at == null ? null : DateTime.parse(at),
      calibration: cal == null ? null : jsonEncode(cal),
    );
  }
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

  Future<List<LinkedPod>> pods(String token) async => [
        for (final p in ((await _send('GET', '/pods', token: token))['pods']
                as List? ??
            const []))
          LinkedPod.fromJson(p as Map<String, dynamic>)
      ];

  /// Links the pod (or refreshes it, if it's already this player's).
  /// Throws [ApiException] 409 if it's on another account.
  Future<LinkedPod> linkPod(String token,
          {required String serial,
          String? name,
          String? firmware,
          int? hardware}) async =>
      LinkedPod.fromJson((await _send('POST', '/pods', token: token, body: {
        'serial': serial,
        'name': ?name,
        'firmware': ?firmware,
        'hardware': ?hardware,
      }))['pod'] as Map<String, dynamic>);

  Future<LinkedPod> renamePod(String token, int id, String name) async =>
      LinkedPod.fromJson((await _send('PATCH', '/pods/$id',
          token: token, body: {'name': name}))['pod'] as Map<String, dynamic>);

  Future<void> unlinkPod(String token, int id) =>
      _send('DELETE', '/pods/$id', token: token);

  Future<List<Instrument>> instruments(String token) async => [
        for (final i in ((await _send('GET', '/instruments', token: token))[
                'instruments'] as List? ??
            const []))
          Instrument.fromJson(i as Map<String, dynamic>)
      ];

  /// With its calibration.
  Future<Instrument> instrument(String token, int id) async => Instrument.fromJson(
      (await _send('GET', '/instruments/$id', token: token))['instrument']
          as Map<String, dynamic>);

  Future<Instrument> addInstrument(String token,
          {required String name, required String kind, String? make, int? podId}) async =>
      Instrument.fromJson((await _send('POST', '/instruments', token: token, body: {
        'name': name,
        'kind': kind,
        'make': ?make,
        'pod_id': ?podId,
      }))['instrument'] as Map<String, dynamic>);

  /// [fields]: name, kind, make, pod_id (null clears make and pod_id).
  Future<Instrument> updateInstrument(
          String token, int id, Map<String, Object?> fields) async =>
      Instrument.fromJson((await _send('PATCH', '/instruments/$id',
          token: token, body: fields))['instrument'] as Map<String, dynamic>);

  Future<void> deleteInstrument(String token, int id) =>
      _send('DELETE', '/instruments/$id', token: token);

  /// Throws [ApiException] 409 with the newer saved copy in its body when
  /// [at] is older than what's saved.
  Future<Instrument> putCalibration(
          String token, int id, String calibration, DateTime at) async =>
      Instrument.fromJson((await _send('PUT', '/instruments/$id/calibration',
          token: token,
          body: {
            'calibration': jsonDecode(calibration),
            'updated_at': at.toUtc().toIso8601String(),
          }))['instrument'] as Map<String, dynamic>);

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
        msg is String ? msg : 'The server said no (${res.statusCode}).',
        body: json is Map<String, dynamic> ? json : null);
  }

  static Object? _decode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }
}
