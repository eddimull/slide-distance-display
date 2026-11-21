import 'dart:typed_data';

import 'take.dart';
import 'take_store_stub.dart'
    if (dart.library.io) 'take_store_io.dart' as impl;

/// A take's listing entry, without its frames.
typedef TakeSummary = ({String id, String title, DateTime started, int durationMs});

/// Saved takes: each is `<id>.json` plus `<id>.wav` when it has audio.
abstract class TakeStore {
  /// The app's own store: files in the documents directory on the phone,
  /// or a [MemoryTakeStore] where files can't be written (web).
  static Future<TakeStore> open() => impl.openTakeStore();

  /// False when takes are lost when the app closes.
  bool get persistent;

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

/// Takes kept for this run of the app only (web build).
class MemoryTakeStore implements TakeStore {
  final _takes = <String, Take>{};

  @override
  bool get persistent => false;

  @override
  Future<void> save(Take take, Uint8List? wav) async => _takes[take.id] = take;

  @override
  Future<List<TakeSummary>> list() async => [
        for (final t in _takes.values)
          (id: t.id, title: t.title, started: t.started, durationMs: t.durationMs),
      ]..sort((a, b) => b.started.compareTo(a.started));

  @override
  Future<Take?> load(String id) async => _takes[id];

  @override
  Future<String?> audioPath(Take take) async => null;

  @override
  Future<void> delete(String id) async => _takes.remove(id);
}
