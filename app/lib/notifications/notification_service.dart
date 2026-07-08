import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_request.dart';

/// SharedPreferences key for the SPEC-07 pending-action replay queue.
const kPendingActionsKey = 'pino_pending_actions';

/// SPEC-07 seam: fired when the user taps an actionable-notification button
/// while the app process is NOT alive. This runs in a separate
/// `@pragma('vm:entry-point')` isolate with no socket/Riverpod, so Slice 1
/// cannot respond here — it only persists the pending action for SPEC-07 to
/// drain (via `responseForAction` + `respondTo`) on next launch/reconnect.
@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse resp) {
  // SPEC-07: enqueue {requestId, actionId, input} for replay. Kept dependency-
  // light and best-effort; the live-isolate path (foreground actions) is what
  // Slice 1 relies on.
  final actionId = resp.actionId;
  if (actionId == null || actionId.isEmpty) return;
  unawaited(_persistPendingAction(resp.payload, actionId, resp.input));
}

Future<void> _persistPendingAction(
  String? payload,
  String actionId,
  String? input,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(kPendingActionsKey) ?? <String>[];
    queue.add(
      jsonEncode({'payload': payload, 'actionId': actionId, 'input': input}),
    );
    await prefs.setStringList(kPendingActionsKey, queue);
  } catch (_) {
    // Best-effort: a failed enqueue must not crash the background isolate.
  }
}

/// Thin wrapper around flutter_local_notifications. Not unit-tested (pure I/O);
/// the decision logic lives in notification_policy.dart and
/// notification_request.dart.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Called with the notification payload when the user taps the body of a
  /// notification (not an action button). Set by the app for deep-linking.
  void Function(String payload)? onTapSession;

  /// Called when the user taps an action button (Approve/Deny/Reply) on a live
  /// isolate. Set by the composition root to route the decision to `respondTo`.
  void Function(String actionId, String? input, String? payload)? onAction;

  bool _ready = false;

  static const _channelId = 'agent_status';
  static const _channelName = 'Agent activity';
  static const _channelDesc =
      'Fires when a backgrounded agent finishes or needs your input.';

  /// iOS/macOS notification categories that carry the action buttons. iOS
  /// matches a shown notification's `categoryIdentifier` against these.
  static final List<DarwinNotificationCategory> _darwinCategories = [
    DarwinNotificationCategory(
      kConfirmCategoryId,
      actions: [
        DarwinNotificationAction.plain(
          kApproveActionId,
          'Approve',
          options: {DarwinNotificationActionOption.foreground},
        ),
        DarwinNotificationAction.plain(
          kDenyActionId,
          'Deny',
          options: {
            DarwinNotificationActionOption.destructive,
            DarwinNotificationActionOption.foreground,
          },
        ),
      ],
    ),
    DarwinNotificationCategory(
      kQuestionCategoryId,
      actions: [
        DarwinNotificationAction.text(
          kReplyActionId,
          'Reply',
          buttonTitle: 'Send',
          placeholder: 'Type a reply…',
          options: {DarwinNotificationActionOption.foreground},
        ),
      ],
    ),
  ];

  /// Initialise the plugin and request permission. Safe to call once at boot.
  Future<void> init() async {
    if (_ready) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Ask for permission up front on iOS during init.
    final darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      notificationCategories: _darwinCategories,
    );
    await _plugin.initialize(
      settings: InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
      ),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
    );
    // Android 13+ runtime permission (no-op on older / other platforms).
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    _ready = true;
  }

  void _onResponse(NotificationResponse resp) {
    final actionId = resp.actionId;
    if (actionId != null && actionId.isNotEmpty) {
      onAction?.call(actionId, resp.input, resp.payload);
      return;
    }
    final payload = resp.payload;
    if (payload != null && payload.isNotEmpty) onTapSession?.call(payload);
  }

  /// Show a notification now. [payload] carries tap-routing info. When
  /// [category] is set, action buttons are attached (iOS via the registered
  /// category; Android via inline [AndroidNotificationAction]s).
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? category,
  }) async {
    if (!_ready) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        actions: _androidActionsFor(category),
      ),
      iOS: DarwinNotificationDetails(categoryIdentifier: category),
      macOS: DarwinNotificationDetails(categoryIdentifier: category),
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

  /// Android action buttons matching the given [category]. iOS derives its
  /// buttons from the registered category instead.
  List<AndroidNotificationAction>? _androidActionsFor(String? category) {
    switch (category) {
      case kConfirmCategoryId:
        return const [
          AndroidNotificationAction(
            kApproveActionId,
            'Approve',
            showsUserInterface: true,
          ),
          AndroidNotificationAction(
            kDenyActionId,
            'Deny',
            showsUserInterface: true,
          ),
        ];
      case kQuestionCategoryId:
        return const [
          AndroidNotificationAction(
            kReplyActionId,
            'Reply',
            showsUserInterface: true,
            inputs: [AndroidNotificationActionInput(label: 'Reply')],
          ),
        ];
      default:
        return null;
    }
  }
}
