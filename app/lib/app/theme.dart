import 'package:flutter/material.dart';

// Minimal, calm palette. Real design pass later.
/// Pino brand blue — used as the color-scheme seed and for accent affordances
/// (running badges, the user's message bubble). Shared so the value lives once.
const kPinoBrandBlue = Color(0xFF4F6CFF);
const _seed = kPinoBrandBlue;

final pinoLightTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.light,
  ),
  textTheme: const TextTheme().apply(fontFamily: 'SF Pro Text'),
);

final pinoDarkTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
  ),
  textTheme: const TextTheme().apply(fontFamily: 'SF Pro Text'),
);
