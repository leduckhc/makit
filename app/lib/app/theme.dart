import 'package:flutter/material.dart';

/// pino brand accent — logo green. The single hue in an otherwise neutral
/// (chroma-0) palette. See design-system/pino/MASTER.md.
const kPinoAccent = Color(0xFF4ADE80);
const _onAccent = Color(0xFF06210F);

/// Neutral (zero-hue) palette — identical character in light & dark; no blue.
const _bgLight = Color(0xFFFAFAFA);
const _surfaceLight = Color(0xFFFFFFFF);
const _textLight = Color(0xFF1B1B1B);
const _mutedLight = Color(0xFF636363);
const _hairlineLight = Color(0xFFDEDEDE);

const _bgDark = Color(0xFF171717);
const _surfaceDark = Color(0xFF242424);
const _textDark = Color(0xFFF5F5F5);
const _mutedDark = Color(0xFF9E9E9E);
const _hairlineDark = Color(0xFF333333);

ThemeData _build(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final bg = dark ? _bgDark : _bgLight;
  final surface = dark ? _surfaceDark : _surfaceLight;
  final scheme =
      ColorScheme.fromSeed(seedColor: kPinoAccent, brightness: brightness)
          .copyWith(
            primary: kPinoAccent,
            onPrimary: _onAccent,
            // Neutral surfaces (override the seed's green-tinted greys).
            surface: bg,
            onSurface: dark ? _textDark : _textLight,
            onSurfaceVariant: dark ? _mutedDark : _mutedLight,
            outline: dark ? _mutedDark : _mutedLight,
            outlineVariant: dark ? _hairlineDark : _hairlineLight,
            surfaceContainerLowest: bg,
            surfaceContainerLow: surface,
            surfaceContainer: surface,
            surfaceContainerHigh: surface,
            surfaceContainerHighest: surface,
          );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    textTheme: const TextTheme().apply(fontFamily: 'SF Pro Text'),
  );
}

final pinoLightTheme = _build(Brightness.light);
final pinoDarkTheme = _build(Brightness.dark);
