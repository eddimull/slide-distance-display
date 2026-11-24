import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Where the signed firmware is published (seventh-server serves it, so the
/// web app can fetch it too). Override with
/// `--dart-define=SEVENTH_FIRMWARE=http://…/firmware`.
const firmwareBase = String.fromEnvironment('SEVENTH_FIRMWARE',
    defaultValue: 'https://seventh.app/firmware');

/// One hardware revision's build in the manifest.
class FirmwareBuild {
  final String version;
  final int hardware;
  final String file;
  final int size;
  final List<int> sha256;

  /// ECDSA P-256 over [sha256], DER: the pod only installs it if this
  /// matches the public key it was built with.
  final List<int> signature;

  const FirmwareBuild({
    required this.version,
    required this.hardware,
    required this.file,
    required this.size,
    required this.sha256,
    required this.signature,
  });
}

/// `manifest.json`: `{"version": "0.5.1", "builds": {"1": {"file": …,
/// "size": …, "sha256": hex, "signature": base64}, "2": {…}}}`.
class FirmwareManifest {
  final String version;
  final Map<int, FirmwareBuild> builds;
  const FirmwareManifest(this.version, this.builds);

  static FirmwareManifest? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final version = json['version'];
    final builds = json['builds'];
    if (version is! String || builds is! Map<String, dynamic>) return null;
    final out = <int, FirmwareBuild>{};
    for (final e in builds.entries) {
      final hw = int.tryParse(e.key);
      final b = e.value;
      if (hw == null || b is! Map<String, dynamic>) continue;
      try {
        out[hw] = FirmwareBuild(
          version: version,
          hardware: hw,
          file: b['file'] as String,
          size: (b['size'] as num).toInt(),
          sha256: _hex(b['sha256'] as String),
          signature: base64.decode(b['signature'] as String),
        );
      } catch (_) {
        // A malformed entry: skip it.
      }
    }
    return FirmwareManifest(version, out);
  }

  /// The build for [hardware] if it's newer than [current].
  FirmwareBuild? updateFor(int? hardware, String? current) {
    final b = builds[hardware];
    if (b == null || current == null) return null;
    return isNewer(b.version, current) ? b : null;
  }
}

List<int> _hex(String s) => [
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ];

/// "0.10.0" is newer than "0.9.3"; anything after a '-' is ignored.
bool isNewer(String a, String b) {
  List<int> parts(String v) => v
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < math.max(x.length, y.length); i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}

/// The published firmware, fetched once per run of the app.
class FirmwareCatalog {
  final http.Client _http;
  final String base;
  FirmwareCatalog({http.Client? client, this.base = firmwareBase})
      : _http = client ?? http.Client();

  static final shared = FirmwareCatalog();

  Future<FirmwareManifest?>? _manifest;

  /// Null if it can't be had (offline): no update is offered then, and
  /// the next call asks again.
  Future<FirmwareManifest?> manifest() {
    final m = _manifest ??= _fetch();
    m.then((v) {
      if (v == null && identical(_manifest, m)) _manifest = null;
    });
    return m;
  }

  Future<FirmwareManifest?> _fetch() async {
    try {
      final res = await _http
          // A fresh copy at least every minute, whatever caches it.
          .get(Uri.parse('$base/manifest.json'
              '?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return FirmwareManifest.fromJson(jsonDecode(res.body));
    } catch (_) {
      return null;
    }
  }

  /// Downloads [b], checking its size and SHA-256.
  Future<Uint8List> download(FirmwareBuild b) async {
    final res = await _http
        .get(Uri.parse('$base/${b.file}'))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw const OtaException('Couldn\'t download the update.');
    }
    final bytes = res.bodyBytes;
    if (bytes.length != b.size ||
        !_same(sha256.convert(bytes).bytes, b.sha256)) {
      throw const OtaException('The download was damaged. Try again.');
    }
    return bytes;
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class OtaException implements Exception {
  final String message;
  const OtaException(this.message);
  @override
  String toString() => message;
}

/// How the update reaches the pod: its control and data characteristics.
abstract class OtaLink {
  /// Bytes per data write, after the 4-byte offset.
  int get chunk;
  Future<void> control(List<int> bytes);
  Future<void> data(List<int> bytes);

  /// The pod's control notifications.
  Stream<List<int>> get events;
}

// The protocol (see the firmware's OtaCtrlWrite).
const _begin = 1, _abort = 2, _end = 3, _progress = 4, _resend = 5, _error = 6;

String otaError(int code) => switch (code) {
      1 => 'The update doesn\'t fit on this SlidePod.',
      2 => 'That update is for a different SlidePod board.',
      4 => 'The SlidePod couldn\'t write the update. Try again.',
      5 => 'The update was damaged on the way. Try again.',
      6 => 'The SlidePod refused it: it isn\'t signed by Seventh.',
      7 || 8 || 9 => 'The update didn\'t arrive whole. Try again.',
      _ => 'The SlidePod couldn\'t install the update (error $code).',
    };

/// Sends [image] to the pod and has it install it, reporting the share
/// sent (0–1). The pod keeps its firmware unless the whole image arrives
/// and its signature checks out; on success it reboots into the new one.
/// [window]: bytes in flight before waiting for the pod (it buffers 16 KB).
Future<void> runOta(
  OtaLink link,
  Uint8List image,
  FirmwareBuild build, {
  void Function(double)? onProgress,
  int window = 12 * 1024,
  Duration quiet = const Duration(seconds: 6),
}) async {
  final size = image.length;
  var acked = 0;
  int? resendFrom;
  int? result; // END: 0 or an error
  final begun = Completer<int>();
  final wake = StreamController<void>.broadcast();

  final sub = link.events.listen((e) {
    if (e.isEmpty) return;
    int u32() => e.length < 5 ? 0 : e[1] | e[2] << 8 | e[3] << 16 | e[4] << 24;
    switch (e[0]) {
      case _begin:
        if (!begun.isCompleted) begun.complete(e.length > 1 ? e[1] : 9);
      case _progress:
        acked = math.max(acked, u32());
        onProgress?.call(acked / size);
      case _resend:
        resendFrom = u32();
      case _end:
        result = e.length > 1 ? e[1] : 9;
      case _error:
        result = e.length > 1 ? e[1] : 9;
        if (!begun.isCompleted) begun.complete(result!);
    }
    wake.add(null);
  });

  Future<bool> next() => wake.stream.first
      .timeout(quiet)
      .then((_) => true, onError: (_) => false);

  try {
    final sizeBytes = [size & 0xFF, size >> 8 & 0xFF, size >> 16 & 0xFF, size >> 24 & 0xFF];
    await link.control([_begin, ...sizeBytes, build.hardware, ...build.sha256]);
    final ok = await begun.future.timeout(const Duration(seconds: 15),
        onTimeout: () => throw const OtaException('The SlidePod didn\'t answer.'));
    if (ok != 0) throw OtaException(otaError(ok));

    var sent = 0;
    var stalls = 0;
    while (acked < size) {
      if (result != null && result != 0) throw OtaException(otaError(result!));
      if (resendFrom != null) {
        sent = resendFrom!;
        resendFrom = null;
      }
      if (sent < size && sent - acked < window) {
        final n = math.min(link.chunk, size - sent);
        await link.data([
          sent & 0xFF, sent >> 8 & 0xFF, sent >> 16 & 0xFF, sent >> 24 & 0xFF,
          ...image.sublist(sent, sent + n),
        ]);
        sent += n;
        continue;
      }
      if (await next()) {
        stalls = 0;
        continue;
      }
      // Nothing for a while: send again from what the pod has.
      if (++stalls > 4) throw const OtaException('The SlidePod stopped answering.');
      sent = acked;
    }

    await link.control([_end, build.signature.length, ...build.signature]);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (result == null && DateTime.now().isBefore(deadline)) {
      await next();
    }
    if (result == null) throw const OtaException('The SlidePod didn\'t confirm the update.');
    if (result != 0) throw OtaException(otaError(result!));
  } catch (e) {
    if (result == null) {
      try {
        await link.control([_abort]);
      } catch (_) {}
    }
    rethrow;
  } finally {
    await sub.cancel();
    await wake.close();
  }
}
