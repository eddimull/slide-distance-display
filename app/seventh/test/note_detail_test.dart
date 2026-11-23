import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seventh/note_detail_screen.dart';
import 'package:seventh/note_diagnosis.dart';
import 'package:seventh/pitch_yin.dart';
import 'package:seventh/reference_tone.dart';
import 'package:seventh/review_screen.dart';
import 'package:seventh/take_analysis.dart';

import 'synth_take.dart';

void main() {
  final a = synthScale();
  NoteAnalysis note(String name) => a.notes.firstWhere((n) => n.name == name);

  group('diagnosis', () {
    test('slide: E♭4 too far out, in cm, bring it in', () {
      final d = diagnose(note('Eb4'), cal);
      expect(d.kind, DiagnosisKind.slide);
      expect(d.headline, 'Slide too far out by 0.20');
      expect(d.body, matches(RegExp(r'About \d+\.\d cm past 3rd')));
      expect(d.body, contains('Bring the slide in.'));
    });

    test('lip, where the horn wants the slide inside 1st', () {
      final d = diagnose(note('D4'), cal);
      expect(d.kind, DiagnosisKind.lip);
      expect(d.headline, 'Needs lipping up');
      expect(d.body, contains('5th partial'));
    });

    test('lip: A4 pushed sharp although the slide made it flat', () {
      final d = diagnose(note('A4'), cal);
      expect(d.kind, DiagnosisKind.lip);
      expect(d.headline, 'Lips pulled it sharp by 26¢');
      expect(d.body, contains('Aim the note down'));
    });

    test('in tune, but the slide stopped short and crept on late', () {
      final d = diagnose(note('G4'), cal);
      expect(d.kind, DiagnosisKind.good);
      expect(d.body, contains('stopped −0.25 short of 4th, then crept on'));
      expect(d.body, contains('still moving'));
    });

    test('mm for semitones inverts the calibration', () {
      for (final s in [0.0, 1.5, 3.0, 6.0]) {
        expect(cal.semitonesFromMm(mmAtSemis(cal, s)), closeTo(s, 0.001));
      }
    });

    test('ordinals', () {
      expect([1, 2, 3, 4, 11, 12, 13, 21, 22].map(ordinal),
          ['1st', '2nd', '3rd', '4th', '11th', '12th', '13th', '21st', '22nd']);
    });
  });

  test('reference tone is the asked pitch', () {
    for (final f in [233.08, 311.13, 466.16]) {
      final wav = referenceToneWav(f, sampleRate: 16000, ms: 500);
      final pcm = ByteData.sublistView(wav, 44);
      final yin = PitchYin();
      for (var i = 0; i < 4000; i++) {
        yin.push(pcm.getInt16(i * 2, Endian.little) / 32768);
      }
      expect(yin.detect(), closeTo(f, f * 0.003), reason: '$f Hz');
    }
  });

  testWidgets('breakdown: loop at 0.25× comes back looping the note slowly',
      (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(home: ReviewScreen(take: synthScaleTake(), cal: cal)));
    await tester.pump();

    // The notes list row (last match; the moves list says "into E♭4").
    await tester.tap(find.text('E♭4').last);
    await tester.pumpAndSettle();
    expect(find.byType(NoteDetailScreen), findsOneWidget);
    expect(find.text('Slide too far out by 0.20'), findsOneWidget);
    expect(find.text('SLIDE ARRIVAL'), findsOneWidget);
    expect(find.text('Hear E♭4'), findsOneWidget);

    await tester.tap(find.text('Loop at 0.25×'));
    // It comes back playing, so pump time rather than settle.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(NoteDetailScreen), findsNothing);
    expect(find.text('Looping E♭4'), findsOneWidget);
    expect(find.text('0.25×'), findsWidgets);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
  });
}
