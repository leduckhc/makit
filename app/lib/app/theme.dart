import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// makit design tokens — Linear-based flat surface system (see DESIGN.md).
//
// Dark-first, flat depth via a surface ladder + 1px hairlines (no shadows in
// dark). A single green accent used scarcely. Desktop chrome (sidebar/topbar)
// is DARKER than content in both modes: canvas → surface-1 (content) →
// surface-2/3/4 for bubbles/cards. Two radii: 8 for controls (buttons/inputs),
// 12 for surfaces (cards/dialogs/menus). Type keeps a compact 13/12/11 desktop
// ramp (DESIGN.md §6 documents the desktop density) with negative tracking.
//
// M3-slot → DESIGN-ladder mapping (dark values shown):
//   surface                = surface-1 #0c0d10  (lifted chat content, active tab)
//   surfaceContainerLowest = canvas    #010102  (recessed chrome: sidebar/topbar/tab strip)
//   surfaceContainerLow    = surface-2 #16171b  (agent bubble, settings rows)
//   surfaceContainer       = surface-3 #1d1f24  (user bubble, active nav, tool card)
//   surfaceContainerHigh   = surface-4 #25272d  (composer field, pr bar)
//   surfaceContainerHighest= deepest   #2b2d34  (selected/hover states)
// ---------------------------------------------------------------------------

/// makit brand-mark green — decorative only: the `makit` logo mark and the
/// connection dot. NOT the CTA fill (that is `primary`, deepened for contrast).
const kMakitAccent = Color(0xFF4ADE80);

/// Near-black ink (light-mode onSurface headline color).
const kMakitInk = Color(0xFF0B0D0F);

/// Radius for small controls: buttons, inputs, tabs, segmented knobs (DESIGN md 8).
const kRadiusControl = 8.0;

/// Radius for surfaces: cards, dialogs, menus (DESIGN lg 12).
const kRadiusSurface = 12.0;

// ----- Surface ladder (DESIGN.md §2) ---------------------------------------
// Dark is a deep, faintly blue-tinted near-black (never #000). Light floors on
// an off-white canvas with white lifted content. `surfaceContainerLowest` is
// repurposed as the recessed *canvas* (darkest chrome), so chrome reads darker
// than the `surface` (surface-1) content column in both modes.
const _canvasLight = Color(0xFFF7F8FA); // surfaceContainerLowest — chrome floor
const _surface1Light = Color(0xFFFFFFFF); // surface — lifted content
const _surface2Light = Color(0xFFF0F1F4); // surfaceContainerLow
const _surface3Light = Color(0xFFE8EAEE); // surfaceContainer
const _surface4Light = Color(0xFFDFE1E7); // surfaceContainerHigh
const _surfaceTopLight = Color(0xFFD7D9E0); // surfaceContainerHighest
const _onSurfaceLight = Color(0xFF0B0D0F);
const _mutedLight = Color(0xFF6B7280);
const _hairlineLight = Color(0xFFE4E5EA);

const _canvasDark = Color(0xFF010102); // surfaceContainerLowest — chrome floor
const _surface1Dark = Color(0xFF0C0D10); // surface — lifted content
const _surface2Dark = Color(0xFF16171B); // surfaceContainerLow
const _surface3Dark = Color(0xFF1D1F24); // surfaceContainer
const _surface4Dark = Color(0xFF25272D); // surfaceContainerHigh
const _surfaceTopDark = Color(0xFF2B2D34); // surfaceContainerHighest
const _onSurfaceDark = Color(0xFFF7F8F8);
const _mutedDark = Color(0xFF8A8F98);
const _hairlineDark = Color(0xFF23252A);

// ----- Accent bindings (DESIGN.md §2) --------------------------------------
// `primary` is the deepened CTA/active/focus green — distinct from the bright
// decorative brand-mark ([kMakitAccent]). Light darkens further so white
// `on-primary` text clears 4.5:1.
const _primaryLight = Color(0xFF1F9D63);
const _primaryDark = Color(0xFF4CB782);
const _onPrimaryDark = Color(0xFF04130B);

ThemeData _build(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: kMakitAccent,
        brightness: brightness,
      ).copyWith(
        primary: dark ? _primaryDark : _primaryLight,
        onPrimary: dark ? _onPrimaryDark : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF1E3A29)
            : const Color(0xFFDCF5E4),
        onPrimaryContainer: dark
            ? const Color(0xFFA7F3C4)
            : const Color(0xFF14532D),
        // Secondary/tertiary collapse to neutrals/accent so no stray M3
        // pastel tints survive (chips, tonal buttons, status glyphs).
        secondary: dark ? _mutedDark : _mutedLight,
        onSecondary: dark ? _canvasDark : Colors.white,
        secondaryContainer: dark ? _surface4Dark : _surface4Light,
        onSecondaryContainer: dark ? _onSurfaceDark : _onSurfaceLight,
        tertiary: dark ? _primaryDark : _primaryLight,
        tertiaryContainer: dark ? _surface4Dark : _surface4Light,
        onTertiaryContainer: dark ? _onSurfaceDark : _onSurfaceLight,
        // Neutral surface ladder — blue-tinted near-black in dark (DESIGN §2).
        surface: dark ? _surface1Dark : _surface1Light,
        onSurface: dark ? _onSurfaceDark : _onSurfaceLight,
        onSurfaceVariant: dark ? _mutedDark : _mutedLight,
        outline: dark ? _mutedDark : _mutedLight,
        outlineVariant: dark ? _hairlineDark : _hairlineLight,
        surfaceContainerLowest: dark ? _canvasDark : _canvasLight,
        surfaceContainerLow: dark ? _surface2Dark : _surface2Light,
        surfaceContainer: dark ? _surface3Dark : _surface3Light,
        surfaceContainerHigh: dark ? _surface4Dark : _surface4Light,
        surfaceContainerHighest: dark ? _surfaceTopDark : _surfaceTopLight,
        surfaceTint: Colors.transparent,
      );

  final muted = scheme.onSurfaceVariant;
  final hairline = scheme.outlineVariant.withValues(alpha: 0.55);
  final hover = scheme.onSurface.withValues(alpha: dark ? 0.06 : 0.05);
  final pressed = scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.08);

  // ----- Typography: dashboard/chat ramp anchored at 13px body -----------
  // A dense product scale (NOT the landing-page scale in DESIGN.md §3):
  // body 13, meta 12/11, titles 15/17 with negative tracking; display/headline
  // stay small (20–24) since a dashboard rarely needs hero type. Titles 600,
  // body 400, labels 500.
  const family = 'SF Pro Text';
  final textTheme =
      TextTheme(
        displaySmall: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          height: 1.2,
        ),
        headlineSmall: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
          height: 1.25,
        ),
        titleLarge: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
          height: 1.3,
        ),
        titleMedium: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
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
          letterSpacing: -0.05,
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
          letterSpacing: 0.2,
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
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.08),
        disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.35),
        elevation: 0,
        minimumSize: const Size(64, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: controlShape,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ).copyWith(
        overlayColor: WidgetStatePropertyAll(
          scheme.onPrimary.withValues(alpha: 0.10),
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
