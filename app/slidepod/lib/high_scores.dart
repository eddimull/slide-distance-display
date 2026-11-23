import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One finished game for the table. [detail] is the game's own summary
/// line ("9/10 · avg 0.84 s").
class ScoreEntry {
  final int score;
  final DateTime at;
  final String detail;

  const ScoreEntry({required this.score, required this.at, this.detail = ''});

  Map<String, dynamic> toJson() =>
      {'score': score, 'at': at.toUtc().toIso8601String(), 'detail': detail};

  static ScoreEntry fromJson(Map<String, dynamic> m) => ScoreEntry(
        score: (m['score'] as num).toInt(),
        at: DateTime.parse(m['at'] as String).toLocal(),
        detail: m['detail'] as String? ?? '',
      );
}

/// The best [keep] scores of each game, highest first, kept on the device.
class HighScores {
  static const int keep = 10;
  final SharedPreferences prefs;
  HighScores(this.prefs);

  static Future<HighScores> open() async =>
      HighScores(await SharedPreferences.getInstance());

  String _key(String game) => 'scores_$game';

  List<ScoreEntry> top(String game) {
    final raw = prefs.getString(_key(game));
    if (raw == null) return [];
    try {
      return [
        for (final m in jsonDecode(raw) as List)
          ScoreEntry.fromJson(m as Map<String, dynamic>),
      ];
    } catch (_) {
      return []; // damaged: start the table again
    }
  }

  ScoreEntry? best(String game) {
    final t = top(game);
    return t.isEmpty ? null : t.first;
  }

  /// Adds [e]; returns its place (1 = new high score), or null if it
  /// didn't make the table. A tie goes below the earlier score.
  Future<int?> submit(String game, ScoreEntry e) async {
    final t = top(game);
    var i = t.indexWhere((x) => e.score > x.score);
    if (i < 0) i = t.length;
    if (i >= keep) return null;
    t.insert(i, e);
    if (t.length > keep) t.removeRange(keep, t.length);
    await prefs.setString(
        _key(game), jsonEncode([for (final x in t) x.toJson()]));
    return i + 1;
  }

  Future<void> clear(String game) => prefs.remove(_key(game));
}
