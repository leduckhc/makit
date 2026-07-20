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
  final scheme = ColorScheme.fromSeed(
    seedColor: kMakitAccent,
    brightness: brightness,
  ).copyWith(
    // Neutral (C=0) surface ramp — keeps M3 elevation stepping, drops the tint.
    surface: dark ? _surfaceDark : _surfaceLight,
    onSurface: dark ? _onSurfaceDark : _onSurfaceLight,
    onSurfaceVariant: dark ? _mutedDark : _mutedLight,
    outline: dark ? _mutedDark : _mutedLight,
    outlineVariant: dark ? _hairlineDark : _hairlineLight,
    surfaceContainerLowest: dark ? _containerLowestDark : _containerLowestLight,
    surfaceContainerLow: dark ? _containerLowDark : _containerLowLight,
    surfaceContainer: dark ? _containerDark : _containerLight,
    surfaceContainerHigh: dark ? _containerHighDark : _containerHighLight,
    surfaceContainerHighest: dark
        ? _containerHighestDark
        : _containerHighestLight,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: const TextTheme().apply(fontFamily: 'SF Pro Text'),
  );
}

final makitLightTheme = _build(Brightness.light);
final makitDarkTheme = _build(Brightness.dark);
