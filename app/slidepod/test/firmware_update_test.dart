import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slidepod/firmware_update.dart';

/// The pod's side of the update protocol, as the firmware does it: data in
/// order into a 16 KB buffer drained to "flash", PROGRESS every 4 KB, RESEND
/// for a gap or no room, END checks the hash and the signature.
class FakePod implements OtaLink {
  @override
  final int chunk;
  final int hw;

  /// Drop every [dropEvery]th data write (0: none), as a busy radio would.
  final int dropEvery;
  final List<int> goodSignature;
  FakePod({this.chunk = 240, this.hw = 1, this.dropEvery = 0, required this.goodSignature});

  final _events = StreamController<List<int>>.broadcast();
  final flash = BytesBuilder();
  int size = 0, queued = 0, writes = 0;
  List<int> sha = const [];
  bool active = false, installed = false, resendSent = false;
  final _buffer = <int>[];

  @override
  Stream<List<int>> get events => _events.stream;

  void _emit(List<int> e) => scheduleMicrotask(() => _events.add(e));
  List<int> _u32(int kind, int v) => [kind, v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24 & 255];

  @override
  Future<void> control(List<int> b) async {
    switch (b[0]) {
      case 1:
        size = b[1] | b[2] << 8 | b[3] << 16 | b[4] << 24;
        if (b[5] != hw) return _emit([1, 2]);
        sha = b.sublist(6, 38);
        active = true;
        _emit([1, 0]);
      case 3:
        final sig = b.sublist(2, 2 + b[1]);
        final hash = sha256.convert(flash.toBytes()).bytes;
        if (flash.length != size) return _emit([6, 8]);
        if (!_eq(hash, sha)) return _emit([6, 5]);
        if (!_eq(sig, goodSignature)) return _emit([6, 6]);
        installed = true;
        _emit([3, 0]);
      case 2:
        active = false;
    }
  }

  @override
  Future<void> data(List<int> b) async {
    writes++;
    if (dropEvery > 0 && writes % dropEvery == 0) return; // lost in the air
    if (!active) return;
    final off = b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24;
    final len = b.length - 4;
    if (off < queued) return;
    if (off > queued || 16 * 1024 - _buffer.length < len) {
      if (!resendSent) _emit(_u32(5, queued));
      resendSent = true;
      return;
    }
    _buffer.addAll(b.sublist(4));
    queued += len;
    resendSent = false;
    // The writer task drains in 4 KB pieces, or the tail.
    while (_buffer.length >= 4096 || (queued == size && _buffer.isNotEmpty)) {
      final n = min(4096, _buffer.length);
      flash.add(_buffer.sublist(0, n));
      _buffer.removeRange(0, n);
      _emit(_u32(4, flash.length));
    }
  }
}

bool _eq(List<int> a, List<int> b) =>
    a.length == b.length && Iterable.generate(a.length).every((i) => a[i] == b[i]);

void main() {
  final rng = Random(7);
  final image = Uint8List.fromList(List.generate(50 * 1024 + 123, (_) => rng.nextInt(256)));
  final sig = List.generate(70, (i) => i);
  FirmwareBuild build({List<int>? signature, int hw = 1}) => FirmwareBuild(
        version: '0.5.1',
        hardware: hw,
        file: 'slidepod-rev1-0.5.1.bin',
        size: image.length,
        sha256: sha256.convert(image).bytes,
        signature: signature ?? sig,
      );

  test('an update arrives whole and the pod installs it', () async {
    final pod = FakePod(goodSignature: sig);
    final progress = <double>[];
    await runOta(pod, image, build(), onProgress: progress.add);
    expect(pod.installed, isTrue);
    expect(pod.flash.toBytes(), image);
    expect(progress.last, 1.0);
  });

  test('lost chunks are sent again', () async {
    final pod = FakePod(goodSignature: sig, dropEvery: 37);
    await runOta(pod, image, build(), quiet: const Duration(milliseconds: 50));
    expect(pod.installed, isTrue);
    expect(pod.flash.toBytes(), image);
  });

  test('the pod refuses an unsigned image, and the wrong board', () async {
    await expectLater(runOta(FakePod(goodSignature: sig), image, build(signature: [1, 2, 3])),
        throwsA(isA<OtaException>().having((e) => e.message, 'message', contains('signed'))));
    await expectLater(runOta(FakePod(goodSignature: sig, hw: 2), image, build()),
        throwsA(isA<OtaException>().having((e) => e.message, 'message', contains('board'))));
  });

  test('versions compare by number', () {
    expect(isNewer('0.5.1', '0.5.0'), isTrue);
    expect(isNewer('0.10.0', '0.9.3'), isTrue);
    expect(isNewer('0.5.0', '0.5.0'), isFalse);
    expect(isNewer('0.4.9', '0.5.0'), isFalse);
    expect(isNewer('1.0', '0.9.9-beta'), isTrue);
  });

  test('the manifest offers a newer build for the pod\'s board', () async {
    final manifest = {
      'version': '0.5.1',
      'builds': {
        '1': {
          'file': 'slidepod-rev1-0.5.1.bin',
          'size': image.length,
          'sha256': sha256.convert(image).toString(),
          'signature': base64.encode(sig),
        },
      },
    };
    final client = MockClient((req) async => switch (req.url.path) {
          '/firmware/manifest.json' => http.Response(jsonEncode(manifest), 200),
          '/firmware/slidepod-rev1-0.5.1.bin' => http.Response.bytes(image, 200),
          _ => http.Response('', 404),
        });
    final catalog = FirmwareCatalog(client: client, base: 'https://seventh.test/firmware');
    final m = (await catalog.manifest())!;
    expect(m.updateFor(1, '0.5.0')?.version, '0.5.1');
    expect(m.updateFor(1, '0.5.1'), isNull);
    expect(m.updateFor(2, '0.4.0'), isNull);
    final b = m.updateFor(1, '0.4.1')!;
    expect(await catalog.download(b), image);

    // A damaged download is caught before it goes near the pod.
    final bad = FirmwareCatalog(
        client: MockClient((req) async => http.Response.bytes([1, 2, 3], 200)),
        base: 'https://seventh.test/firmware');
    await expectLater(bad.download(b), throwsA(isA<OtaException>()));
  });

  test('test firmware is offered only to pods set to it, and only if newer',
      () async {
    Map<String, dynamic> m(String v) => {
          'version': v,
          'builds': {
            '1': {
              'file': 'slidepod-rev1-$v.bin',
              'size': 1,
              'sha256': '00',
              'signature': base64.encode([1]),
            },
          },
        };
    var beta = m('0.5.3');
    final client = MockClient((req) async => switch (req.url.path) {
          '/firmware/manifest.json' => http.Response(jsonEncode(m('0.5.2')), 200),
          '/firmware/manifest-beta.json' => http.Response(jsonEncode(beta), 200),
          _ => http.Response('', 404),
        });
    var c = FirmwareCatalog(client: client, base: 'https://seventh.test/firmware');
    expect((await c.manifest())!.version, '0.5.2');
    expect((await c.manifest(beta: true))!.version, '0.5.3');

    // Once promoted, the beta is older than or the same as everyone's.
    beta = m('0.5.1');
    c = FirmwareCatalog(client: client, base: 'https://seventh.test/firmware');
    expect((await c.manifest(beta: true))!.version, '0.5.2');
  });
}
