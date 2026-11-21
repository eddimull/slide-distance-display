import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/take.dart';
import 'package:slidepod/take_store.dart';
import 'package:slidepod/take_store_io.dart';

void main() {
  final t0 = DateTime(2026, 11, 21, 9, 41);

  test('recorder: frames on the take clock, pitch below 30 Hz dropped', () {
    final r = TakeRecorder(started: t0);
    r.addFrame(t0.add(const Duration(milliseconds: 20)),
        mm: 263.04, semis: 0.0123456, freq: 233.08123);
    r.addFrame(t0.add(const Duration(milliseconds: 40)), freq: 12);
    r.addFrame(t0.subtract(const Duration(milliseconds: 5)), freq: 233);
    final (take, wav) = r.finish(id: 'a', title: 'Scale');
    expect(take.frames, hasLength(2));
    expect(take.frames[0].tMs, 20);
    expect(take.frames[1].freq, isNull);
    expect(take.frames[1].semis, isNull);
    expect(take.durationMs, 40);
    expect(wav, isNull);
    expect(take.audioFile, isNull);
  });

  test('recorder: audio offset is where the first chunk began', () {
    final r = TakeRecorder(started: t0, audioRate: 16000);
    // 320 samples = 20 ms, arriving 100 ms in: it started at 80 ms.
    r.addPcm(t0.add(const Duration(milliseconds: 100)), Uint8List(640));
    r.addPcm(t0.add(const Duration(milliseconds: 120)), Uint8List(640));
    final (take, wav) = r.finish(id: 'b', title: 'x');
    expect(take.audioOffsetMs, 80);
    expect(take.audioFile, 'b.wav');
    expect(wav!.length, 44 + 1280);
  });

  test('WAV header', () {
    final wav = wavBytes(Uint8List.fromList([1, 2, 3, 4, 5]), 16000);
    final b = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 16)), 'WAVEfmt ');
    expect(b.getUint16(22, Endian.little), 1); // mono
    expect(b.getUint32(24, Endian.little), 16000);
    expect(b.getUint16(34, Endian.little), 16);
    expect(b.getUint32(40, Endian.little), 4); // odd byte dropped
    expect(wav.length, 48);
  });

  test('JSON round trip, rounded', () {
    final take = Take(
      id: 'c',
      title: 'B♭ major scale',
      started: t0,
      frames: [
        (tMs: 0, mm: 263.04, semis: 0.0123456, freq: 233.08123),
        (tMs: 20, mm: null, semis: null, freq: null),
      ],
      audioFile: 'c.wav',
      audioOffsetMs: -12,
    );
    final back = Take.fromJson(take.toJson());
    expect(back.title, 'B♭ major scale');
    expect(back.started, t0);
    expect(back.audioFile, 'c.wav');
    expect(back.audioOffsetMs, -12);
    expect(back.frames[0], (tMs: 0, mm: 263.0, semis: 0.012, freq: 233.08));
    expect(back.frames[1], (tMs: 20, mm: null, semis: null, freq: null));
  });

  test('ids sort by start time', () {
    final a = TakeStore.newId(DateTime.utc(2026, 1, 2, 3, 4, 5, 6));
    final b = TakeStore.newId(DateTime.utc(2026, 1, 2, 3, 4, 5, 7));
    expect(a, '20260102-030405-006');
    expect(a.compareTo(b), lessThan(0));
  });

  group('file store', () {
    late Directory tmp;
    late FileTakeStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('takes');
      store = FileTakeStore(Directory('${tmp.path}/takes'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Take make(String id, DateTime started, {bool audio = false}) => Take(
          id: id,
          title: 'T $id',
          started: started,
          frames: [(tMs: 0, mm: 1, semis: 0, freq: 100), (tMs: 900, mm: 1, semis: 0, freq: null)],
          audioFile: audio ? '$id.wav' : null,
        );

    test('save, list newest first, load, delete', () async {
      expect(await store.list(), isEmpty);
      await store.save(make('one', t0), null);
      final two = make('two', t0.add(const Duration(minutes: 1)), audio: true);
      await store.save(two, wavBytes(Uint8List(32), 16000));

      final list = await store.list();
      expect(list.map((s) => s.id), ['two', 'one']);
      expect(list.first.durationMs, 900);

      final back = (await store.load('two'))!;
      expect(back.frames, hasLength(2));
      final path = await store.audioPath(back);
      expect(File(path!).lengthSync(), 44 + 32);

      await store.delete('two');
      expect((await store.list()).map((s) => s.id), ['one']);
      expect(File(path).existsSync(), isFalse);
    });

    test('refuses ids that reach outside the folder', () async {
      expect(() => store.save(make('../x', t0), null), throwsArgumentError);
      expect(await store.load('../x'), isNull);
    });

    test('a damaged file is left out of the list', () async {
      await store.save(make('good', t0), null);
      File('${store.dir.path}/bad.json').writeAsStringSync('{nope');
      expect((await store.list()).map((s) => s.id), ['good']);
    });
  });
}
