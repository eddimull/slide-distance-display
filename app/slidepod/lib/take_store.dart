import 'dart:typed_data';

import 'take.dart';
import 'take_store_stub.dart'
    if (dart.library.io) 'take_store_io.dart' as impl;

/// A take's listing entry, without its frames.
typedef TakeSummary = ({String id, String title, DateTime started, int durationMs});

/// Saved takes: each is `<id>.json` plus `<id>.wav` when it has audio.
abstract class TakeStore {
  /// The app's own store (documents directory on the phone). Null where
  /// takes can't be saved (web).
  static Future<TakeStore?> open() => impl.openTakeStore();

  Future<void> save(Take take, Uint8List? wav);
  Future<List<TakeSummary>> list();
  Future<Take?> load(String id);

  /// Path of the take's audio file, for the player; null if none.
  Future<String?> audioPath(Take take);
  Future<void> delete(String id);

  /// A new, sortable id for a take started at [t].
  static String newId(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final u = t.toUtc();
    return '${u.year}${two(u.month)}${two(u.day)}-'
        '${two(u.hour)}${two(u.minute)}${two(u.second)}-'
        '${u.millisecond.toString().padLeft(3, '0')}';
  }
}
