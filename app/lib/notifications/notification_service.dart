import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_request.dart';
import '../pairing/readiness.dart';

/// SharedPreferences key for the SPEC-07 pending-action replay queue.
const kPendingActionsKey = 'makit_pending_actions';

/// SharedPreferences flag: have we ever shown the OS notification prompt?
/// The platform permission query can't distinguish "not yet asked" from
/// "denied", so we track it ourselves to drive the onboarding notifications
/// gate (SPEC-09).
const kNotifAskedKey = 'makit_notif_asked';

/// Upper bound on the SPEC-07 pending-action replay queue. Prevents unbounded
/// growth in SharedPreferences when actions are never drained.
const kMaxPendingActions = 50;

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
    // Cap the queue so a never-drained backlog can't grow without bound.
    if (queue.length > kMaxPendingActions) {
      queue.removeRange(0, queue.length - kMaxPendingActions);
    }
    await prefs.setStringList(kPendingActionsKey, queue);
  } catch (_) {
    // Best-effort: a failed enqueue must not crash the background isolate.
  }
}

/// Test-only seam for the private [_persistPendingAction] enqueue path.
@visibleForTesting
Future<void> persistPendingActionForTest(
  String? payload,
  String actionId,
  String? input,
) => _persistPendingAction(payload, actionId, input);

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

  /// Initialise the plugin. Safe to call once at boot.
  ///
  /// SPEC-09: does NOT request permission up front. The onboarding wizard owns
  /// the prompt (via [requestPermission]) so it's asked with context, and
  /// [permissionStatus] can report `notDetermined` before then.
  Future<void> init() async {
    if (_ready) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
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
    _ready = true;
  }

  /// Query (do not request) the current OS notification-permission status.
  ///
  /// The platform APIs only report enabled/disabled, so `notDetermined` vs
  /// `denied` is disambiguated with the [kNotifAskedKey] flag we set in
  /// [requestPermission]. Best-effort: any failure → [NotificationPermission.unsupported].
  Future<NotificationPermission> permissionStatus() async {
    try {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final macos = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      bool? enabled;
      if (ios != null) {
        enabled = (await ios.checkPermissions())?.isEnabled;
      } else if (macos != null) {
        enabled = (await macos.checkPermissions())?.isEnabled;
      } else if (android != null) {
        enabled = await android.areNotificationsEnabled();
      } else {
        return NotificationPermission.unsupported;
      }

      if (enabled == true) return NotificationPermission.granted;
      final prefs = await SharedPreferences.getInstance();
      final asked = prefs.getBool(kNotifAskedKey) ?? false;
      return asked
          ? NotificationPermission.denied
          : NotificationPermission.notDetermined;
    } catch (_) {
      return NotificationPermission.unsupported;
    }
  }

  /// Show the OS permission prompt (records that we asked), then report the
  /// resulting status. Called from the onboarding notifications step.
  Future<NotificationPermission> requestPermission() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kNotifAskedKey, true);
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final macos = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        await ios.requestPermissions(alert: true, badge: true, sound: true);
      } else if (macos != null) {
        await macos.requestPermissions(alert: true, badge: true, sound: true);
      } else if (android != null) {
        await android.requestNotificationsPermission();
      }
    } catch (_) {
      // Best-effort: fall through to a fresh status query below.
    }
    return permissionStatus();
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
  ///
  /// Returns `true` when the notification was handed to the plugin, `false`
  /// when it could not be shown (service not ready, permission denied, or a
  /// platform throw) — the caller uses this to fall back to an in-app dialog.
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? category,
  }) async {
    if (!_ready) return false;
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
      return true;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[makit] notification show failed: $e');
      }
      return false;
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
