/// SPEC-background-wake-notifications Slice 2 — push-token registration seam.
///
/// [pushRegisterBody] is the pure `cmd` body the app sends after a successful
/// (re)connect. [PushRegistrar] isolates native APNs/FCM token retrieval behind
/// a platform channel/plugin; [NoopPushRegistrar] is the default (no token →
/// the app never sends `push.register`, and the server falls back to Slice-1).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../transport/protocol.dart';

/// Build the `push.register` command body. Pure + unit-tested.
Map<String, dynamic> pushRegisterBody({
  required String token,
  required String platform,
}) => {'kind': CmdKind.registerPush.wire, 'token': token, 'platform': platform};

/// Native push-token provider seam. A real implementation wraps a platform
/// channel (iOS `AppDelegate` forwards the APNs token; Android/FCM later).
abstract class PushRegistrar {
  /// The routing platform for this registrar: "apns" | "fcm".
  String get platform;

  /// The current push token, or null when unavailable (permission declined,
  /// not yet retrieved, or no native provider wired).
  Future<String?> getToken();

  /// Install a listener fired when a token first becomes (or newly becomes)
  /// available. The APNs token can arrive AFTER the socket connects, so the
  /// [ConnectionController] subscribes to this to send `push.register` late.
  /// Passing null detaches the listener.
  set onToken(void Function(String token)? listener);
}

/// Default registrar: no native provider, so no token. Keeps the composition
/// root buildable without platform wiring; the app simply skips registration
/// and the server stays on the Slice-1 fallback.
class NoopPushRegistrar implements PushRegistrar {
  const NoopPushRegistrar();

  @override
  String get platform => 'apns';

  @override
  Future<String?> getToken() async => null;

  @override
  set onToken(void Function(String token)? listener) {
    // No native provider → a token never arrives, so nothing to notify.
  }
}

/// A registrar whose token is provided by a caller (e.g. once the iOS
/// `AppDelegate` channel delivers the APNs token). Kept trivial + testable.
@immutable
class ProvidedPushRegistrar implements PushRegistrar {
  const ProvidedPushRegistrar(this._token, {this.platform = 'apns'});

  final String? _token;

  @override
  final String platform;

  @override
  Future<String?> getToken() async => _token;

  @override
  set onToken(void Function(String token)? listener) {
    // Token is fixed at construction, so it never "newly" arrives.
  }
}

/// Method-channel-backed registrar (SPEC-background-wake-notifications W4 Dart half). Listens on the
/// `makit/push` channel that iOS `AppDelegate` invokes with the hex APNs token.
///
/// The token can arrive AFTER the socket connects, so this stores the latest
/// token AND fires [onToken] so the [ConnectionController] can send
/// `push.register` mid-connection. [getToken] returns the stored token (null
/// until the native `didRegister` call fires).
class ChannelPushRegistrar implements PushRegistrar {
  ChannelPushRegistrar({MethodChannel? channel, this.platform = 'apns'})
    : _channel = channel ?? const MethodChannel(pushChannelName) {
    _channel.setMethodCallHandler(_handle);
  }

  /// The native channel name (mirrors `AppDelegate.swift`).
  static const String pushChannelName = 'makit/push';

  /// The native method name for a delivered APNs token (mirrors AppDelegate).
  static const String didRegisterMethod = 'didRegister';

  final MethodChannel _channel;

  @override
  final String platform;

  String? _token;
  void Function(String token)? _onToken;

  @override
  Future<String?> getToken() async => _token;

  @override
  set onToken(void Function(String token)? listener) => _onToken = listener;

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == didRegisterMethod) {
      final token = call.arguments;
      if (token is String && token.isNotEmpty) {
        _token = token;
        _onToken?.call(token);
      }
    }
    // `didFail` and unknown methods: ignore (best-effort seam; a missing token
    // simply leaves the app on the Slice-1 fallback).
    return null;
  }
}
