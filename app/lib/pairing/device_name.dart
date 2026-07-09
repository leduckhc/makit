/// Resolves the human-facing device name used as the pairing label.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Method channel backed by native handlers (iOS `UIDevice.current.name`,
/// Android device name). Mirrors the `makit/qr_scanner` custom-channel pattern
/// so we don't pull in a third-party device-info plugin (see SECURITY.md §5).
const MethodChannel deviceInfoChannel = MethodChannel('makit/device_info');

/// The device's human name (e.g. "KC's iPhone") to send as the pairing label
/// so it shows up by name in the desktop Devices list.
///
/// Falls back to a platform-generic name when the native channel is
/// unavailable (desktop, tests, or an OS that doesn't expose a name).
Future<String> deviceName() async {
  try {
    final name = await deviceInfoChannel.invokeMethod<String>('name');
    if (name != null && name.trim().isNotEmpty) return name.trim();
  } catch (_) {
    // Channel not implemented on this platform (or under test) — fall through.
  }
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isAndroid) return 'Android device';
  if (Platform.isMacOS) return 'Mac';
  return 'phone';
}
