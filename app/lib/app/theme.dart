import 'package:flutter/material.dart';

// Minimal, calm palette. Real design pass later.
const _seed = Color(0xFF4F6CFF);

final pinoLightTheme = ThemeData(
  useMaterial3: true,
  colorScheme:
      ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.light),
  textTheme: const TextTheme().apply(fontFamily: 'SF Pro Text'),
);

final pinoDarkTheme = ThemeData(
  useMaterial3: true,
  colorScheme:
      ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
  textTheme: const TextTheme().apply(fontFamily: 'SF Pro Text'),
);
