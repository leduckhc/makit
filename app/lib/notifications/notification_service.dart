import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications. Not unit-tested (pure I/O);
/// the decision logic lives in notification_policy.dart.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Called with the notification payload (a sessionId) when the user taps a
  /// notification. Set by the app so it can deep-link into the session.
  void Function(String sessionId)? onTapSession;

  bool _ready = false;

  static const _channelId = 'agent_status';
  static const _channelName = 'Agent activity';
  static const _channelDesc =
      'Fires when a backgrounded agent finishes or needs your input.';

  /// Initialise the plugin and request permission. Safe to call once at boot.
  Future<void> init() async {
    if (_ready) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Ask for permission up front on iOS during init.
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
      ),
      onDidReceiveNotificationResponse: (resp) {
        final sid = resp.payload;
        if (sid != null && sid.isNotEmpty) onTapSession?.call(sid);
      },
    );
    // Android 13+ runtime permission (no-op on older / other platforms).
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    _ready = true;
  }

  /// Show a notification now. [payload] carries the sessionId for tap routing.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_ready) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[pino] notification show failed: $e');
      }
    }
  }
}
