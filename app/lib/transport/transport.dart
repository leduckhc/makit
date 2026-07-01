import 'protocol.dart';

/// State of the underlying transport connection.
enum WsState { idle, connecting, connected, reconnecting, closed }

/// The transport seam consumed by `ConnectionController`.
///
/// This mirrors exactly the surface of [WsClient] that the controller uses,
/// so the controller can be driven by an in-memory fake in unit tests without
/// opening real sockets. See `ws_client.dart` for the production implementation
/// and `test/connection_controller_test.dart` for a hand-written fake.
abstract class Transport {
  /// Open the connection and send the auto-hello frame built from [helloBody].
  Future<void> connect(
    String url, {
    Map<String, dynamic> helloBody,
    String? pinnedFingerprint,
  });

  /// Tear down the connection.
  Future<void> close();

  /// Inbound application frames (everything that isn't an internally-consumed
  /// request/response correlation).
  Stream<Envelope> get frames;

  /// Connection lifecycle updates.
  Stream<WsState> get state;

  /// Send an envelope, preserving its caller-supplied id.
  void sendEnvelope(Envelope env);
}
