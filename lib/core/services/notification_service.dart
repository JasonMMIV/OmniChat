import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'background/background_run_monitor.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;
  /// `getNotificationAppLaunchDetails` keeps reporting the launch payload for
  /// the whole process; without this guard every HomePage rebuild/remount
  /// would re-open the same conversation from a cold-start tap.
  static bool _launchConsumed = false;

  /// Web-safe Android check (`dart:io` Platform throws on web).
  static bool get _isAndroidSupported => !kIsWeb && Platform.isAndroid;
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'kelivo_bg_chat_v2',
    'Chat Background',
    description: 'Notifications for chat generation status',
    importance: Importance.high,
    playSound: true,
  );

  static Future<void> ensureInitialized() async {
    if (!_isAndroidSupported) return;
    if (_inited) return;

    // Android initialization
    const AndroidInitializationSettings androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings init = InitializationSettings(android: androidInit);
    // P2-2: a tap on the completion notification asks the chat page to open
    // the conversation that finished (payload = conversation id).
    await _plugin.initialize(init, onDidReceiveNotificationResponse: _onResponse);

    // Create channel
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(_channel);
      // Runtime notification permission (Android 13+) should be requested by app UI if needed
    }
    _inited = true;
  }

  /// Ensure Android 13+ notifications permission is granted (no-op on lower versions/other platforms).
  static Future<bool> ensureAndroidNotificationsPermission() async {
    if (!_isAndroidSupported) return true;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    try {
      final enabled = await android.areNotificationsEnabled();
      if (enabled == true) return true;
    } catch (_) {}
    try {
      final ok = await android.requestNotificationsPermission();
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static void _onResponse(NotificationResponse response) {
    final payload = (response.payload ?? '').trim();
    if (payload.isEmpty) return;
    BackgroundRunMonitor.instance.requestOpen(payload);
  }

  /// Conversation id carried by the notification that launched the app, if
  /// any. Used once at startup so a cold-start tap still opens the chat.
  static Future<String?> consumeLaunchConversationId() async {
    if (_launchConsumed) return null;
    if (!_isAndroidSupported) return null;
    try {
      await ensureInitialized();
      final details = await _plugin.getNotificationAppLaunchDetails();
      _launchConsumed = true;
      if (details?.didNotificationLaunchApp != true) return null;
      final payload = (details?.notificationResponse?.payload ?? '').trim();
      return payload.isEmpty ? null : payload;
    } catch (_) {
      return null;
    }
  }

  /// P2-2: report a finished background generation. [conversationId] is the
  /// tap payload. A single notification id is reused so the newest result
  /// replaces the previous one instead of stacking a history in the shade.
  static Future<void> showRunFinished({
    required String title,
    required String body,
    required String conversationId,
  }) async {
    if (!_isAndroidSupported) return;
    await ensureInitialized();
    await _plugin.show(
      2001,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          ticker: 'OmniChat',
          styleInformation: const DefaultStyleInformation(true, true),
        ),
      ),
      payload: conversationId,
    );
  }
}
