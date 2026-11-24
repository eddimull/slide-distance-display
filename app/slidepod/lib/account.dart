import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'flash_card_game.dart';
import 'pod_info.dart';
import 'seventh_api.dart';

/// The player's Seventh account, for the online leaderboards: signed in or
/// not, their leaderboard name, and posting rounds. The API token is kept
/// on the device.
class Account extends ChangeNotifier {
  final SeventhApi api;
  final SharedPreferences prefs;

  /// The platform rounds are posted as: android, ios or web; null where
  /// the leaderboards aren't offered (desktop).
  final String? platform;

  Account(this.api, this.prefs, {required this.platform}) {
    _token = prefs.getString(_tokenKey);
    final id = prefs.getInt(_idKey);
    if (_token != null && id != null) {
      _player = Player(id, prefs.getString(_nameKey));
    }
  }

  static const _tokenKey = 'seventh_token',
      _idKey = 'seventh_player_id',
      _nameKey = 'seventh_player_name';

  String? _token;
  Player? _player;

  bool get available => platform != null;
  bool get signedIn => _token != null && _player != null;
  Player? get player => _player;

  /// Signed in, but no leaderboard name yet: rounds post, but the boards
  /// show them nameless, so ask for one.
  bool get needsName => signedIn && _player!.displayName == null;

  /// Refreshes the name from the server; signs out if the token is gone.
  Future<void> refresh() async {
    final t = _token;
    if (t == null) return;
    try {
      await _setPlayer(await api.me(t));
    } on ApiException catch (e) {
      if (e.signedOut) await _forget();
      return;
    }
    await loadPods();
  }

  Future<void> signInWithGoogle(String idToken) async =>
      _signedIn(await api.signInWithGoogle(idToken, device: platform));

  Future<void> signInWithApple(String idToken, {String? code}) async =>
      _signedIn(await api.signInWithApple(idToken, code: code, device: platform));

  /// Throws [ApiException] (e.g. "That name is taken.").
  Future<void> setName(String name) async =>
      _setPlayer(await api.setName(_token!, name.trim()));

  Future<void> signOut() async {
    final t = _token;
    await _forget();
    if (t != null) {
      try {
        await api.signOut(t);
      } on ApiException {
        // Signed out here either way.
      }
    }
  }

  /// Deletes the account and everything on the server; throws
  /// [ApiException] if the server couldn't (still signed in then).
  Future<void> deleteAccount() async {
    try {
      await api.deleteAccount(_token!);
    } on ApiException catch (e) {
      if (!e.signedOut) rethrow;
    }
    await _forget();
  }

  List<LinkedPod> _pods = const [];

  /// The player's linked SlidePods, as last loaded ([loadPods]).
  List<LinkedPod> get pods => _pods;

  /// The linked pod with [serial], if it's one of the player's.
  LinkedPod? linkedPod(String serial) {
    for (final p in _pods) {
      if (p.serial == serial.toUpperCase()) return p;
    }
    return null;
  }

  Future<void> loadPods() async {
    final t = _token;
    if (t == null) return;
    try {
      _pods = await api.pods(t);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.signedOut) await _forget();
    }
  }

  /// Links [pod] to the account. Throws [ApiException] (409: it's on
  /// someone else's).
  Future<LinkedPod> linkPod(PodInfo pod) async {
    final linked = await _guard((t) => api.linkPod(t,
        serial: pod.serial,
        name: pod.name,
        firmware: pod.firmware,
        hardware: pod.hardware));
    _pods = [for (final p in _pods) if (p.id != linked.id) p, linked];
    notifyListeners();
    return linked;
  }

  /// A linked pod just connected: tell the server its name and firmware
  /// (and that it was seen). Quietly does nothing otherwise.
  Future<void> podSeen(PodInfo pod) async {
    if (!signedIn || linkedPod(pod.serial) == null) return;
    try {
      await linkPod(pod);
    } on ApiException {
      // Only bookkeeping.
    }
  }

  Future<void> renamePod(LinkedPod pod, String name) async {
    final renamed = await _guard((t) => api.renamePod(t, pod.id, name));
    _pods = [for (final p in _pods) p.id == renamed.id ? renamed : p];
    notifyListeners();
  }

  Future<void> unlinkPod(LinkedPod pod) async {
    await _guard((t) => api.unlinkPod(t, pod.id));
    _pods = [for (final p in _pods) if (p.id != pod.id) p];
    notifyListeners();
  }

  /// Runs [call] with the token; signs out if the server says it's gone.
  Future<T> _guard<T>(Future<T> Function(String token) call) async {
    final t = _token;
    if (t == null) throw const ApiException(401, 'Sign in first.');
    try {
      return await call(t);
    } on ApiException catch (e) {
      if (e.signedOut) await _forget();
      rethrow;
    }
  }

  /// Posts a finished round for the leaderboards. Null when signed out or
  /// not offered here; throws [ApiException] if the server refused it.
  /// A game's online board; with [player]'s place when signed in.
  Future<Board> leaderboard(String game, {bool week = false}) =>
      api.leaderboard(game, week: week, token: _token);

  Future<PostedRound?> postRound(
      String game, int rulesVersion, FlashCardRound round) async {
    final t = _token;
    if (t == null || platform == null) return null;
    try {
      return await api.postRound(t,
          game: game,
          rulesVersion: rulesVersion,
          platform: platform!,
          clientScore: round.score,
          cards: [for (final r in round.results) r.toLog()]);
    } on ApiException catch (e) {
      if (e.signedOut) await _forget();
      rethrow;
    }
  }

  Future<void> _signedIn(SignIn s) async {
    _token = s.token;
    await prefs.setString(_tokenKey, s.token);
    await _setPlayer(s.player);
    unawaited(loadPods());
  }

  Future<void> _setPlayer(Player p) async {
    _player = p;
    await prefs.setInt(_idKey, p.id);
    if (p.displayName == null) {
      await prefs.remove(_nameKey);
    } else {
      await prefs.setString(_nameKey, p.displayName!);
    }
    notifyListeners();
  }

  Future<void> _forget() async {
    _token = null;
    _player = null;
    _pods = const [];
    await prefs.remove(_tokenKey);
    await prefs.remove(_idKey);
    await prefs.remove(_nameKey);
    notifyListeners();
  }
}

/// Which platform this is, as the server knows them.
String? seventhPlatform() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    _ => null,
  };
}
