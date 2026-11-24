import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:share_plus/share_plus.dart';

import 'take.dart';
import 'take_analysis.dart';
import 'take_store.dart';

/// One row per note: its intonation and cause, and the slide move into it.
/// Positions are chart positions (1 = 1st), errors in positions with + =
/// too far in the direction the slide was going.
String takeCsv(TakeAnalysis a) {
  String f(double? v, [int places = 2]) => v == null ? '' : v.toStringAsFixed(places);
  final rows = <List<String>>[
    [
      'note', 'start_s', 'end_s', 'cents', 'partial', 'target_position',
      'landed_position', 'slide_cents', 'lip_cents', 'cause', 'late_slide',
      'shift_from', 'shift_result', 'shift_ms', 'peak_pos_per_s',
      'peak_error', 'first_stop_error', 'landed_error', 'settle_after_onset_ms',
    ],
    for (final n in a.notes)
      [
        n.name,
        f(n.startMs / 1000, 3),
        f(n.endMs / 1000, 3),
        f(n.cents, 1),
        n.partial?.toString() ?? '',
        f(n.targetSemis == null ? null : 1 + n.targetSemis!),
        f(n.landedSemis == null ? null : 1 + n.landedSemis!),
        f(n.slideCents, 1),
        f(n.lipCents, 1),
        n.cause.name,
        n.lateSlide ? 'yes' : '',
        f(n.shift == null ? null : 1 + n.shift!.fromSemis),
        n.shift?.result.name ?? '',
        n.shift?.durationMs.toString() ?? '',
        f(n.shift?.peakSpeed, 1),
        f(n.shift?.peakError),
        f(n.shift?.firstStopError),
        f(n.shift?.landedError),
        n.shift?.settleAfterOnsetMs.toString() ?? '',
      ],
  ];
  // Note names have no commas or quotes; nothing needs escaping.
  return '${rows.map((r) => r.join(',')).join('\n')}\n';
}

/// A file name from the take's title: "B♭ scale" → "B-scale".
String exportName(Take take) {
  final base = take.title
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return base.isEmpty ? take.id : base;
}

/// Shares the take: its audio (if any), the analysis as CSV, and the take
/// itself as JSON (re-analysable later), through the system share sheet.
Future<ShareResult> shareTake(TakeAnalysis a, TakeStore? store,
    {Rect? origin}) async {
  final take = a.take;
  final name = exportName(take);
  final files = <XFile>[
    XFile.fromData(Uint8List.fromList(utf8.encode(takeCsv(a))),
        mimeType: 'text/csv'),
    XFile.fromData(Uint8List.fromList(utf8.encode(take.toJson())),
        mimeType: 'application/json'),
  ];
  // The names go in fileNameOverrides, not XFile's name: off the web an
  // XFile's name comes from its path, so one made from data has none, and
  // share_plus then wrote to a folder ("Is a directory").
  final names = ['$name.csv', '$name.take.json'];
  final audio = await store?.audioPath(take);
  if (audio != null) {
    // From memory too, so it's shared under the take's name, not its id
    // (share_plus renames only files without a path). ~32 KB a second.
    files.insert(0, XFile.fromData(await XFile(audio).readAsBytes(), mimeType: 'audio/wav'));
    names.insert(0, '$name.wav');
  }
  return SharePlus.instance.share(ShareParams(
    files: files,
    fileNameOverrides: names,
    subject: take.title,
    text: '${take.title}: ${a.inTuneCount}/${a.notes.length} notes in tune, '
        '${a.cleanShifts}/${a.shifts.length} clean slide moves.',
    sharePositionOrigin: origin,
  ));
}
