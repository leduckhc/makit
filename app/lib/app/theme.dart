import 'package:flutter/material.dart';

/// makit brand seed — logo green (≈150° hue). Material 3's
/// [ColorScheme.fromSeed] derives the palette (primary/secondary/tertiary and
/// their containers, error, on-colors) from this single seed.
const kMakitAccent = Color(0xFF4ADE80);

// Neutral (chroma-0) surface ramp. Stock M3 tints the neutral surfaces toward
// the seed (a faint green); we override just the surface tones back to pure
// grey so the background reads neutral, while keeping M3's *stepped* elevation
// hierarchy (Lowest → Highest) and the seed-derived primary/accent colors.
const _surfaceLight = Color(0xFFFAFAFA); // scaffold background
const _containerLowestLight = Color(0xFFFFFFFF);
const _containerLowLight = Color(0xFFF3F3F3);
const _containerLight = Color(0xFFEDEDED);
const _containerHighLight = Color(0xFFE7E7E7);
const _containerHighestLight = Color(0xFFE1E1E1);
const _onSurfaceLight = Color(0xFF1B1B1B);
const _mutedLight = Color(0xFF636363);
const _hairlineLight = Color(0xFFDEDEDE);

const _surfaceDark = Color(0xFF171717); // scaffold background
const _containerLowestDark = Color(0xFF121212);
const _containerLowDark = Color(0xFF1E1E1E);
const _containerDark = Color(0xFF242424);
const _containerHighDark = Color(0xFF2E2E2E);
const _containerHighestDark = Color(0xFF383838);
const _onSurfaceDark = Color(0xFFF5F5F5);
const _mutedDark = Color(0xFF9E9E9E);
const _hairlineDark = Color(0xFF333333);

ThemeData _build(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: kMakitAccent,
        brightness: brightness,
      ).copyWith(
        // Neutral (C=0) surface ramp — keeps M3 elevation stepping, drops the tint.
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
      );
  final baseTypography = dark
      ? Typography.material2021().white
      : Typography.material2021().black;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: _makitTextTheme(
      baseTypography,
    ).apply(fontFamily: kSansFontFamily),
  );
}

final makitLightTheme = _build(Brightness.light);
final makitDarkTheme = _build(Brightness.dark);

// ─── Semantic status palette ──────────────────────────────────────────────────
// Beyond the neutral ramp + brand green, these are the ONLY sanctioned hues
// (see DESIGN.md → Colors). They are tuned to sit with the neutral M3 surfaces
// rather than the shouting stock `Colors.orange/red`. Everything that shows a
// status (SessionStatusChip/Dot, connection chip, settings, sessions list)
// reads from these so a state reads identically everywhere:
//   running / connected / active / ok  → colorScheme.primary
//   error / offline                     → colorScheme.error
//   idle / exited / draft / muted       → colorScheme.outline

/// Awaiting input, connecting/reconnecting, dev-fake, transient issues.
const Color kStatusWarning = Color(0xFFE0A72E);

/// Awaiting approval — a stronger "act now" tone than [kStatusWarning].
const Color kStatusCaution = Color(0xFFE07B39);

/// Git diff hues (also used by change chips). See DESIGN.md → Colors.
const Color kDiffAdd = Color(0xFF3FB950);
const Color kDiffDel = Color(0xFFF85149);

// ─── Spacing ───────────────────────────────────────────────────────────
// The layout rhythm (see DESIGN.md → Spacing). Prefer these over raw literals
// for padding, gaps, and `SizedBox` spacers so the scale stays consistent.
// Base unit is 4px with 2px half-steps for tight icon/label gaps.
const double kSpace2 = 2;
const double kSpace4 = 4;
const double kSpace6 = 6;
const double kSpace8 = 8;
const double kSpace10 = 10;
const double kSpace12 = 12;
const double kSpace16 = 16;
const double kSpace20 = 20;
const double kSpace24 = 24;
const double kSpace32 = 32;

// ─── Corner radius ────────────────────────────────────────────────────
// See DESIGN.md → Spacing → Radius. The chat surface also exposes
// kChatRadiusSmall/Medium/Large (= kRadius8/12/16) for transcript rows.
const double kRadius6 = 6; // tiny tags / badges
const double kRadius8 = 8; // chips, pills, code blocks, small controls
const double kRadius10 = 10; // list tiles, medium controls
const double kRadius12 = 12; // cards, banners
const double kRadius16 = 16; // message bubbles, large sheets

// ─── Typography ──────────────────────────────────────────────────────────────
// One canonical type scale for the whole app. Widgets read these roles through
// `Theme.of(context).textTheme.<role>` instead of hardcoding `fontSize`, so the
// app has a single source of truth for sizing and weight. See root DESIGN.md.

/// Proportional UI face. System font on Apple platforms; falls back elsewhere.
const String kSansFontFamily = 'SF Pro Text';

/// Monospace face for code, diffs, tool output, and identifiers. Flutter has no
/// generic `monospace` on every platform, so real faces are listed as fallback.
const String kMonoFontFamily = 'monospace';
const List<String> kMonoFallback = [
  'SF Mono',
  'Menlo',
  'Consolas',
  'Roboto Mono',
  'Courier New',
  'monospace',
];

/// Retint any text style as monospace using the canonical family + fallback.
extension MakitMonoText on TextStyle {
  TextStyle get mono =>
      copyWith(fontFamily: kMonoFontFamily, fontFamilyFallback: kMonoFallback);
}

/// Extra roles layered on the canonical [TextTheme].
extension MakitTextRoles on TextTheme {
  /// Extra-small (xs) label for dense pills, tags, badges, and chip-action
  /// buttons — one step below `labelSmall` (10px) so chips read as clearly
  /// secondary to body text. See DESIGN.md → Typography.
  TextStyle? get labelXs => labelSmall?.copyWith(fontSize: 10);
}

/// Leading-glyph size for pills/badges, paired with `textTheme.labelXs` so a
/// chip's icon and label stay in proportion and read smaller than body.
const double kPillIconSize = 11;

/// Pins the app's type scale on top of a Material 2021 base. Only the roles the
/// app uses are re-sized; colors are applied later by [ThemeData] from the
/// [ColorScheme]. `bodyMedium` (13) is the primary reading/body size.
TextTheme _makitTextTheme(TextTheme base) => base.copyWith(
  titleLarge: base.titleLarge?.copyWith(
    fontSize: 20,
    fontWeight: FontWeight.w600,
  ),
  titleMedium: base.titleMedium?.copyWith(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  ),
  titleSmall: base.titleSmall?.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  ),
  bodyLarge: base.bodyLarge?.copyWith(fontSize: 15),
  bodyMedium: base.bodyMedium?.copyWith(fontSize: 13),
  bodySmall: base.bodySmall?.copyWith(fontSize: 12),
  labelLarge: base.labelLarge?.copyWith(fontSize: 14),
  labelMedium: base.labelMedium?.copyWith(fontSize: 12),
  labelSmall: base.labelSmall?.copyWith(fontSize: 11),
);
