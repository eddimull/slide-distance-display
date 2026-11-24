import 'package:flutter/material.dart';

/// The Seventh design system ("Instrument panel"): one dark ground, one
/// blue for actions, the seven position colours as the app's signature, and
/// one set of tuning colours. See the Foundations board of the app design.
class Seventh {
  Seventh._();

  // ── Surfaces and text ──
  static const ground = Color(0xFF0F1115);
  static const card = Color(0xFF181B21);
  static const raised = Color(0xFF22262E);
  static const line = Color(0xFF2C313A);
  static const text = Color(0xFFE8EAED);
  static const body = Color(0xFFC4C7CC);
  static const muted = Color(0xFF9AA0A6);
  static const faint = Color(0xFF5F6670);

  /// Actions, selection and the playhead. Nothing else.
  static const accent = Color(0xFF64B5F6);
  static const accentSoft = Color(0xFF90CAF9);
  static const onAccent = ground;

  /// Recording, and the record button.
  static const record = Color(0xFFEF5350);

  // ── Tuning: one set, everywhere (always with the cents written out) ──
  static const inTune = Color(0xFF8FD694);
  static const inTuneBg = Color(0xFF1E3A24);
  static const close = Color(0xFFFFCC80);
  static const closeBg = Color(0xFF3A2E1A);
  static const off = Color(0xFFEF9A9A);
  static const offBg = Color(0xFF3A1E1E);

  /// In tune within ±10 ¢, close within ±25 ¢, else off.
  static Color cents(double c) {
    final a = c.abs();
    return a < 10
        ? inTune
        : a < 25
        ? close
        : off;
  }

  static Color centsBg(double c) {
    final a = c.abs();
    return a < 10
        ? inTuneBg
        : a < 25
        ? closeBg
        : offBg;
  }

  // ── Positions: match the pod's LED ──
  static const positions = [
    Color(0xFFEF5350), // 1st
    Color(0xFFFF9800), // 2nd
    Color(0xFFFFEB3B), // 3rd
    Color(0xFF66BB6A), // 4th
    Color(0xFF26C6DA), // 5th
    Color(0xFF42A5F5), // 6th
    Color(0xFFBA68C8), // 7th
  ];

  /// Colour of position [p] (1–7).
  static Color position(int p) => positions[(p - 1).clamp(0, 6)];

  // ── Shape ──
  static const cardRadius = 16.0;
  static const buttonRadius = 14.0;
  static const tagRadius = 8.0;
  static const buttonHeight = 52.0;
  static const gutter = 20.0;

  // ── Type ──
  static const titleFont = 'Space Grotesk';
  static const bodyFont = 'Inter';
  static const monoFont = 'JetBrains Mono';

  /// ♭ ♮ ♯, which the fonts above lack (B♭, never Bb).
  static const fallback = ['Seventh Symbols'];

  /// Tab titles: Live, Takes, Learn.
  static const tabTitle = TextStyle(
    fontFamily: titleFont, fontFamilyFallback: fallback,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    height: 1.1,
    color: text,
  );

  /// Screen titles (pushed screens, sheets).
  static const screenTitle = TextStyle(
    fontFamily: titleFont, fontFamilyFallback: fallback,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: text,
  );

  static const heading = TextStyle(
    fontFamily: bodyFont, fontFamilyFallback: fallback,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: text,
  );

  static const bodyText = TextStyle(
    fontFamily: bodyFont, fontFamilyFallback: fallback,
    fontSize: 15,
    height: 1.5,
    color: body,
  );

  static const small = TextStyle(
    fontFamily: bodyFont, fontFamilyFallback: fallback,
    fontSize: 12,
    color: muted,
  );

  /// Section labels, set in capitals by the caller: "LAST 4 SECONDS".
  static const label = TextStyle(
    fontFamily: bodyFont, fontFamilyFallback: fallback,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
    color: muted,
  );

  /// Numbers: positions, cents, scores, times.
  static const mono = TextStyle(
    fontFamily: monoFont, fontFamilyFallback: fallback,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static ThemeData theme() {
    const scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      surface: ground,
      onSurface: text,
      onSurfaceVariant: muted,
      surfaceContainerLowest: ground,
      surfaceContainerLow: card,
      surfaceContainer: card,
      surfaceContainerHigh: raised,
      surfaceContainerHighest: raised,
      outline: line,
      outlineVariant: raised,
      error: off,
      onError: ground,
      errorContainer: offBg,
      onErrorContainer: off,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: bodyFont,
    );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(buttonRadius),
    );
    const buttonText = TextStyle(
      fontFamily: bodyFont, fontFamilyFallback: fallback,
      fontSize: 16,
      fontWeight: FontWeight.w600,
    );
    return base.copyWith(
      scaffoldBackgroundColor: ground,
      canvasColor: ground,
      dividerColor: line,
      textTheme: _withFallback(base.textTheme
          .apply(bodyColor: body, displayColor: text, fontFamily: bodyFont)
          .copyWith(
            headlineLarge: tabTitle,
            headlineMedium: tabTitle.copyWith(fontSize: 26),
            headlineSmall: screenTitle.copyWith(fontSize: 22),
            titleLarge: screenTitle,
            titleMedium: heading,
            bodyLarge: bodyText,
            bodyMedium: bodyText.copyWith(fontSize: 14),
            bodySmall: small,
            labelSmall: label,
          )),
      appBarTheme: const AppBarTheme(
        backgroundColor: ground,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: screenTitle,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: raised,
          disabledForegroundColor: muted,
          minimumSize: const Size(64, buttonHeight),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size(64, buttonHeight),
          side: const BorderSide(color: line),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          minimumSize: const Size(48, 44),
          textStyle: buttonText.copyWith(fontSize: 15),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: raised,
          foregroundColor: text,
          elevation: 0,
          minimumSize: const Size(64, buttonHeight),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size(44, 44),
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: body,
        textColor: text,
        subtitleTextStyle: small,
        minVerticalPadding: 10,
      ),
      dividerTheme: const DividerThemeData(
        color: raised,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: line,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: screenTitle,
        contentTextStyle: bodyText,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: raised,
        contentTextStyle: TextStyle(
          fontFamily: bodyFont, fontFamilyFallback: fallback,
          fontSize: 14,
          color: text,
        ),
        actionTextColor: accent,
        behavior: SnackBarBehavior.floating,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? line : card,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? text : muted,
          ),
          side: const WidgetStatePropertyAll(BorderSide(color: card, width: 4)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: bodyFont, fontFamilyFallback: fallback,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: ground,
        surfaceTintColor: Colors.transparent,
        indicatorColor: raised,
        elevation: 0,
        height: 68,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? accent : muted,
            size: 22,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontFamily: bodyFont, fontFamilyFallback: fallback,
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: s.contains(WidgetState.selected) ? text : muted,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: raised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        helperStyle: small,
        hintStyle: const TextStyle(color: muted),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? onAccent : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : raised,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: raised,
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: raised,
        thumbColor: accent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: raised,
        side: BorderSide.none,
        labelStyle: const TextStyle(
          fontFamily: bodyFont, fontFamilyFallback: fallback,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: body,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tagRadius),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: raised,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(
          fontFamily: bodyFont, fontFamilyFallback: fallback,
          fontSize: 12,
          color: text,
        ),
      ),
    );
  }
}

TextTheme _withFallback(TextTheme t) => t.copyWith(
      displayLarge: t.displayLarge?.copyWith(fontFamilyFallback: Seventh.fallback),
      displayMedium: t.displayMedium?.copyWith(fontFamilyFallback: Seventh.fallback),
      displaySmall: t.displaySmall?.copyWith(fontFamilyFallback: Seventh.fallback),
      headlineLarge: t.headlineLarge?.copyWith(fontFamilyFallback: Seventh.fallback),
      headlineMedium: t.headlineMedium?.copyWith(fontFamilyFallback: Seventh.fallback),
      headlineSmall: t.headlineSmall?.copyWith(fontFamilyFallback: Seventh.fallback),
      titleLarge: t.titleLarge?.copyWith(fontFamilyFallback: Seventh.fallback),
      titleMedium: t.titleMedium?.copyWith(fontFamilyFallback: Seventh.fallback),
      titleSmall: t.titleSmall?.copyWith(fontFamilyFallback: Seventh.fallback),
      bodyLarge: t.bodyLarge?.copyWith(fontFamilyFallback: Seventh.fallback),
      bodyMedium: t.bodyMedium?.copyWith(fontFamilyFallback: Seventh.fallback),
      bodySmall: t.bodySmall?.copyWith(fontFamilyFallback: Seventh.fallback),
      labelLarge: t.labelLarge?.copyWith(fontFamilyFallback: Seventh.fallback),
      labelMedium: t.labelMedium?.copyWith(fontFamilyFallback: Seventh.fallback),
      labelSmall: t.labelSmall?.copyWith(fontFamilyFallback: Seventh.fallback),
    );

/// A tag: tuning, slide moves, "No playing".
class SeventhTag extends StatelessWidget {
  final String text;
  final Color background, foreground;
  const SeventhTag(
    this.text, {
    super.key,
    this.background = Seventh.raised,
    this.foreground = Seventh.body,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(Seventh.tagRadius),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: foreground,
      ),
    ),
  );
}

/// A position as a filled, numbered chip: the number carries it even
/// without the colour.
class PositionChip extends StatelessWidget {
  final int position;
  final double size;
  const PositionChip(this.position, {super.key, this.size = 28});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Seventh.position(position),
      shape: BoxShape.circle,
    ),
    child: Text(
      '$position',
      style: Seventh.mono.copyWith(
        fontSize: size * 0.5,
        fontWeight: FontWeight.w600,
        color: Seventh.ground,
      ),
    ),
  );
}
