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
    await loadInstruments();
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

  // ── Instruments, and the calibration made on each ──

  static const _instrumentKey = 'instrument_id', _calAtKey = 'slide_cal_at';

  List<Instrument> _instruments = const [];

  /// The player's instruments, as last loaded ([loadInstruments]).
  List<Instrument> get instruments => _instruments;

  /// The instrument being played: its calibration is the one in use.
  Instrument? get currentInstrument {
    final id = prefs.getInt(_instrumentKey);
    for (final i in _instruments) {
      if (i.id == id) return i;
    }
    return null;
  }

  Future<void> loadInstruments() async {
    if (!signedIn) return;
    try {
      _instruments = await _guard(api.instruments);
      notifyListeners();
    } on ApiException {
      // Kept as they were.
    }
  }

  Future<Instrument> addInstrument(
      {required String name, required String kind, String? make, int? podId}) async {
    final i = await _guard((t) =>
        api.addInstrument(t, name: name, kind: kind, make: make, podId: podId));
    _instruments = [..._instruments, i];
    notifyListeners();
    return i;
  }

  Future<void> updateInstrument(Instrument i, Map<String, Object?> fields) async {
    final u = await _guard((t) => api.updateInstrument(t, i.id, fields));
    _instruments = [for (final x in _instruments) x.id == u.id ? u : x];
    notifyListeners();
  }

  Future<void> removeInstrument(Instrument i) async {
    await _guard((t) => api.deleteInstrument(t, i.id));
    _instruments = [for (final x in _instruments) if (x.id != i.id) x];
    if (prefs.getInt(_instrumentKey) == i.id) await prefs.remove(_instrumentKey);
    notifyListeners();
  }

  /// Makes [i] the instrument being played (null: none).
  Future<void> chooseInstrument(Instrument? i) async {
    if (i == null) {
      await prefs.remove(_instrumentKey);
    } else {
      await prefs.setInt(_instrumentKey, i.id);
    }
    notifyListeners();
  }

  /// When the phone's calibration last changed (null: never, or unknown).
  DateTime? get calibrationAt {
    final s = prefs.getString(_calAtKey);
    return s == null ? null : DateTime.tryParse(s);
  }

  /// The phone's calibration just changed (now, unless [at] says when).
  Future<void> calibrationChanged([DateTime? at]) => at == null
      ? prefs.setString(_calAtKey, DateTime.now().toUtc().toIso8601String())
      : prefs.setString(_calAtKey, at.toUtc().toIso8601String());

  /// Brings the phone's calibration ([local]: its JSON, or null) and the
  /// current instrument's together, newest wins. Returns the instrument's
  /// calibration when the phone should load it instead; null otherwise
  /// (signed out, no instrument, or the phone's is newest and was saved).
  /// [adoptLocal]: an instrument with none takes the phone's (a new one);
  /// otherwise a calibration-less instrument means starting over ('').
  Future<String?> syncCalibration(String? local, {bool adoptLocal = true}) async {
    final current = currentInstrument;
    if (!signedIn || current == null) return null;
    final Instrument server;
    try {
      server = await _guard((t) => api.instrument(t, current.id));
    } on ApiException {
      return null; // offline: try again later
    }
    final localAt = calibrationAt;
    final serverAt = server.calibrationAt;
    if (server.calibration != null &&
        (local == null || localAt == null || serverAt!.isAfter(localAt))) {
      await calibrationChanged(serverAt);
      return server.calibration;
    }
    if (server.calibration == null && !adoptLocal) {
      return '';
    }
    if (local == null) return null;
    if (serverAt != null && localAt != null && !localAt.isAfter(serverAt)) {
      return null; // the same
    }
    try {
      final saved = await _guard((t) => api.putCalibration(
          t, current.id, local, localAt ?? DateTime.now()));
      _instruments = [for (final x in _instruments) x.id == saved.id ? saved : x];
      notifyListeners();
    } on ApiException catch (e) {
      // Someone saved a newer one (another phone): take it.
      final inst = e.body?['instrument'];
      if (e.status == 409 && inst is Map<String, dynamic>) {
        final newer = Instrument.fromJson(inst);
        if (newer.calibration != null) {
          await calibrationChanged(newer.calibrationAt);
          return newer.calibration;
        }
      }
    }
    return null;
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
    unawaited(loadInstruments());
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
    _instruments = const [];
    await prefs.remove(_instrumentKey);
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
