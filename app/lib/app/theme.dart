import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// makit design tokens — modern & minimalistic.
//
// One green accent on a monochrome neutral ramp. Chrome is borderless by
// default (background steps + whitespace do the separating), hairlines only
// where structure demands them. Two radii: 6 for controls/pills/inputs, 10
// for cards/dialogs/menus. Type is a tight 13/12/11 desktop ramp with subtle
// negative tracking on titles.
// ---------------------------------------------------------------------------

/// makit brand green — the single accent. Used sparingly: the primary CTA,
/// active/status signals. Fills always carry dark ink text ([kMakitInk]).
const kMakitAccent = Color(0xFF4ADE80);

/// Near-black ink used on accent fills (and as light-mode onSurface).
const kMakitInk = Color(0xFF0B0B0B);

/// Radius for small controls: pills, inputs, buttons, tabs, segmented knobs.
const kRadiusControl = 6.0;

/// Radius for surfaces: cards, dialogs, menus.
const kRadiusSurface = 10.0;

// ----- Neutral (chroma-0) surface ramp -------------------------------------
// Pure grey steps — no M3 seed tint — while keeping the M3 Lowest → Highest
// elevation stepping so existing `surfaceContainer*` call sites keep working.
const _surfaceLight = Color(0xFFFAFAFA); // scaffold background
const _containerLowestLight = Color(0xFFFFFFFF);
const _containerLowLight = Color(0xFFF4F4F4);
const _containerLight = Color(0xFFEDEDED);
const _containerHighLight = Color(0xFFE7E7E7);
const _containerHighestLight = Color(0xFFE0E0E0);
const _onSurfaceLight = kMakitInk;
const _mutedLight = Color(0xFF6B6B6B);
const _hairlineLight = Color(0xFFE2E2E2);

const _surfaceDark = Color(0xFF161616); // scaffold background
const _containerLowestDark = Color(0xFF101010);
const _containerLowDark = Color(0xFF1C1C1C);
const _containerDark = Color(0xFF222222);
const _containerHighDark = Color(0xFF292929);
const _containerHighestDark = Color(0xFF323232);
const _onSurfaceDark = Color(0xFFF2F2F2);
const _mutedDark = Color(0xFF9C9C9C);
const _hairlineDark = Color(0xFF2E2E2E);

// ----- Accent bindings ------------------------------------------------------
// The raw brand green is too light to read as text/icon on white, so light
// mode gets a deepened green for `primary` (links, active icons, status dots)
// while *fills* stay brand green + ink via the button themes below.
const _primaryLight = Color(0xFF15803D);
const _primaryDark = kMakitAccent;

ThemeData _build(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: kMakitAccent,
        brightness: brightness,
      ).copyWith(
        primary: dark ? _primaryDark : _primaryLight,
        onPrimary: dark ? kMakitInk : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF1E3A29)
            : const Color(0xFFDCF5E4),
        onPrimaryContainer: dark
            ? const Color(0xFFA7F3C4)
            : const Color(0xFF14532D),
        // Secondary/tertiary collapse to neutrals/accent so no stray M3
        // pastel tints survive (chips, tonal buttons, status glyphs).
        secondary: dark ? _mutedDark : _mutedLight,
        onSecondary: dark ? _surfaceDark : Colors.white,
        secondaryContainer: dark ? _containerHighDark : _containerHighLight,
        onSecondaryContainer: dark ? _onSurfaceDark : _onSurfaceLight,
        tertiary: dark ? _primaryDark : _primaryLight,
        tertiaryContainer: dark ? _containerHighDark : _containerHighLight,
        onTertiaryContainer: dark ? _onSurfaceDark : _onSurfaceLight,
        // Neutral (C=0) surface ramp — M3 elevation stepping, no tint.
        surface: dark ? _surfaceDark : _surfaceLight,
        onSurface: dark ? _onSurfaceDark : _onSurfaceLight,
        onSurfaceVariant: dark ? _mutedDark : _mutedLight,
        outline: dark ? _mutedDark : _mutedLight,
        outlineVariant: dark ? _hairlineDark : _hairlineLight,
        surfaceContainerLowest: dark
            ? _containerLowestDark
            : _containerLowestLight,
        surfaceContainerLow: dark ? _containerLowDark : _containerLowLight,
        surfaceContainer: dark ? _containerDark : _containerLight,
        surfaceContainerHigh: dark ? _containerHighDark : _containerHighLight,
        surfaceContainerHighest: dark
            ? _containerHighestDark
            : _containerHighestLight,
        surfaceTint: Colors.transparent,
      );

  final muted = scheme.onSurfaceVariant;
  final hairline = scheme.outlineVariant.withValues(alpha: 0.55);
  final hover = scheme.onSurface.withValues(alpha: dark ? 0.06 : 0.05);
  final pressed = scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.08);

  // ----- Typography: tight desktop ramp — 13 UI / 12 body-s / 11 metadata --
  // Titles 600 with -0.1..-0.2 tracking, body 400, labels 500.
  const family = 'SF Pro Text';
  final textTheme =
      TextTheme(
        titleLarge: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          height: 1.3,
        ),
        titleMedium: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.15,
          height: 1.3,
        ),
        titleSmall: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
          height: 1.3,
        ),
        bodyLarge: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          letterSpacing: -0.1,
          height: 1.45,
        ),
        bodyMedium: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          height: 1.45,
        ),
        bodySmall: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 1.35,
        ),
        labelLarge: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.1,
          height: 1.2,
        ),
        labelMedium: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          height: 1.2,
          color: muted,
        ),
      ).apply(
        fontFamily: family,
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      );

  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kRadiusControl),
  );
  final surfaceShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kRadiusSurface),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: textTheme,
    fontFamily: family,

    // ----- Density & interaction feel: compact desktop, quiet hovers -------
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    hoverColor: hover,
    focusColor: pressed,
    highlightColor: pressed,
    splashColor: Colors.transparent,
    dividerColor: hairline,

    // ----- Hairlines: outlineVariant @ ~55%, 1px, no gaps ------------------
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),

    // ----- Buttons: quiet by default; one filled green CTA -----------------
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kMakitAccent,
        foregroundColor: kMakitInk,
        disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.08),
        disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.35),
        elevation: 0,
        minimumSize: const Size(64, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: controlShape,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ).copyWith(
        overlayColor: WidgetStatePropertyAll(
          kMakitInk.withValues(alpha: 0.08),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(48, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: hairline),
        minimumSize: const Size(48, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(48, 32),
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),

    // ----- Segmented control: compact slider style (filled track lives at
    // the call site; the theme kills outlines and paints a rounded knob) ----
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? (dark ? scheme.surfaceContainerHighest : Colors.white)
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.onSurface : muted,
        ),
        overlayColor: WidgetStatePropertyAll(hover),
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: WidgetStatePropertyAll(controlShape),
        minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        textStyle: WidgetStatePropertyAll(textTheme.labelMedium),
        visualDensity: VisualDensity.compact,
      ),
    ),

    // ----- Dialogs & cards: flat surfaces, 10px radius, soft shadow only ---
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.55 : 0.25),
      shape: surfaceShape,
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: surfaceShape,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFF262626) : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusSurface),
        side: dark ? BorderSide(color: hairline) : BorderSide.none,
      ),
      textStyle: textTheme.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
    ),

    // ----- Lists: compact 30–34px rows, 6px control radius ------------------
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: muted,
      titleTextStyle: textTheme.bodyMedium,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(color: muted),
      visualDensity: VisualDensity.compact,
    ),

    // ----- Tooltips: small, dark, 6px radius --------------------------------
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF3A3A3A) : const Color(0xFF262626),
        borderRadius: BorderRadius.circular(kRadiusControl),
      ),
      textStyle: textTheme.labelSmall?.copyWith(color: Colors.white),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 400),
    ),

    // ----- Inputs: filled, borderless, 6px; quiet accent focus ring ---------
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: dark ? scheme.surfaceContainerHigh : Colors.white,
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      hintStyle: textTheme.bodyMedium?.copyWith(color: muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: BorderSide(color: hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: BorderSide(color: hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: BorderSide(
          color: scheme.primary.withValues(alpha: 0.6),
        ),
      ),
    ),

    // ----- Misc chrome -------------------------------------------------------
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHigh,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(
        scheme.onSurface.withValues(alpha: 0.22),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: surfaceShape,
      backgroundColor: dark ? const Color(0xFF303030) : const Color(0xFF262626),
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
    ),
  );
}

final makitLightTheme = _build(Brightness.light);
final makitDarkTheme = _build(Brightness.dark);
