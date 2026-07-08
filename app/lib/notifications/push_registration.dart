/// SPEC-07 Slice 2 — push-token registration seam.
///
/// [pushRegisterBody] is the pure `cmd` body the app sends after a successful
/// (re)connect. [PushRegistrar] isolates native APNs/FCM token retrieval behind
/// a platform channel/plugin; [NoopPushRegistrar] is the default (no token →
/// the app never sends `push.register`, and the server falls back to Slice-1).
library;

import 'package:flutter/foundation.dart';

import '../transport/protocol.dart';

/// Build the `push.register` command body. Pure + unit-tested.
Map<String, dynamic> pushRegisterBody({
  required String token,
  required String platform,
}) => {
  'kind': CmdKind.registerPush.wire,
  'token': token,
  'platform': platform,
};

/// Native push-token provider seam. A real implementation wraps a platform
/// channel (iOS `AppDelegate` forwards the APNs token; Android/FCM later).
abstract class PushRegistrar {
  /// The routing platform for this registrar: "apns" | "fcm".
  String get platform;

  /// The current push token, or null when unavailable (permission declined,
  /// not yet retrieved, or no native provider wired).
  Future<String?> getToken();
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
}
