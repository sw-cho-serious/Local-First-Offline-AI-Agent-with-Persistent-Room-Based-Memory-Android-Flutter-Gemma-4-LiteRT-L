import 'dart:async';
import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class NativeActions {
  static const MethodChannel _calendarChannel =
      MethodChannel('com.weilong.hako/calendar');
  static const MethodChannel _speechChannel =
      MethodChannel('com.weilong.hako/speech');
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Taipei'));
    } catch (_) {
      // Fallback to UTC if location lookup fails in unusual environments.
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _notifications.initialize(settings: settings);
    _initialized = true;
  }

  static Future<bool> ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    final manage = await Permission.manageExternalStorage.status;
    if (manage.isGranted) return true;
    final req = await Permission.manageExternalStorage.request();
    if (req.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  static Future<bool> ensureCameraPermission() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.camera.status;
    if (status.isGranted) return true;
    final req = await Permission.camera.request();
    return req.isGranted;
  }

  static Future<({bool inserted, String calendarName, String? error})>
      insertCalendarEventDirect({
    required String title,
    required DateTime startTime,
    DateTime? endTime,
    String? description,
  }) async {
    if (!Platform.isAndroid) {
      return (inserted: false, calendarName: '', error: '非 Android 環境');
    }
    var status = await Permission.calendarFullAccess.status;
    if (!status.isGranted) {
      status = await Permission.calendarFullAccess.request();
    }
    if (!status.isGranted) {
      return (inserted: false, calendarName: '', error: '未授權日曆讀寫權限');
    }

    final end = endTime ?? startTime.add(const Duration(hours: 1));
    try {
      final res = await _calendarChannel.invokeMapMethod<String, dynamic>(
        'insertEvent',
        {
          'title': title,
          'description': description ?? 'KODARI 離線排程建立',
          'startMs': startTime.millisecondsSinceEpoch,
          'endMs': end.millisecondsSinceEpoch,
        },
      );
      if (res != null && res['ok'] == true) {
        return (
          inserted: true,
          calendarName: (res['calendarName'] ?? '系統日曆').toString(),
          error: null,
        );
      }
      return (
        inserted: false,
        calendarName: '',
        error: res?['reason']?.toString() ?? '寫入失敗',
      );
    } catch (e) {
      return (inserted: false, calendarName: '', error: e.toString());
    }
  }

  static Future<void> openCalendarDraft({
    required String title,
    required DateTime startTime,
    DateTime? endTime,
    String? description,
  }) async {
    if (!Platform.isAndroid) return;
    final end = endTime ?? startTime.add(const Duration(hours: 1));
    final intent = AndroidIntent(
      action: 'android.intent.action.INSERT',
      data: 'content://com.android.calendar/events',
      arguments: <String, dynamic>{
        'title': title,
        'description': description ?? 'KODARI 離線排程建立',
        'beginTime': startTime.millisecondsSinceEpoch,
        'endTime': end.millisecondsSinceEpoch,
      },
    );
    await intent.launch();
  }

  static Future<({bool scheduled, String displayTime})> scheduleReminder({
    required String title,
    required String body,
    required DateTime triggerTime,
  }) async {
    await initialize();
    final safeTime = triggerTime.isBefore(DateTime.now())
        ? DateTime.now().add(const Duration(seconds: 15))
        : triggerTime;

    if (Platform.isAndroid && !kIsWeb) {
      await Permission.notification.request();
      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
      await androidPlugin?.requestExactAlarmsPermission();
    }

    final id = safeTime.millisecondsSinceEpoch.remainder(100000);
    const androidDetails = AndroidNotificationDetails(
      'xiaoliu_reminders',
      'KODARI 現場提醒',
      channelDescription: '出車、調機與現場待辦鬧鐘提醒',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    try {
      final tzDate = tz.TZDateTime.from(safeTime, tz.local);
      await _notifications.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tzDate,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } catch (e) {
      debugPrint('[NativeActions] exactAllowWhileIdle failed ($e), falling back to inexact');
      try {
        final tzDate = tz.TZDateTime.from(safeTime, tz.local);
        await _notifications.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: tzDate,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (e2) {
        debugPrint('[NativeActions] inexact zonedSchedule failed ($e2)');
      }
    }

    // Unconditional in-process Timer fallback for reminders <= 2 hours so
    // Samsung/Sony Doze delays never miss short-term notifications.
    final delay = safeTime.difference(DateTime.now());
    if (delay > Duration.zero && delay <= const Duration(hours: 2)) {
      Timer(delay, () {
        unawaited(_notifications.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: details,
        ));
      });
    }

    final h = safeTime.hour.toString().padLeft(2, '0');
    final m = safeTime.minute.toString().padLeft(2, '0');
    return (
      scheduled: true,
      displayTime: '${safeTime.month}/${safeTime.day} $h:$m',
    );
  }

  static Future<String?> listenSpeech() async {
    if (!Platform.isAndroid) return null;
    try {
      final spoken = await _speechChannel.invokeMethod<String>('startListening');
      final clean = spoken?.trim();
      return (clean == null || clean.isEmpty) ? null : clean;
    } catch (e) {
      debugPrint('[NativeActions] speech recognition error: $e');
      return null;
    }
  }

  static Future<void> setSystemAlarmClock({
    required int hour,
    required int minute,
    required String message,
    bool skipUi = false,
  }) async {
    if (!Platform.isAndroid) return;
    final intent = AndroidIntent(
      action: 'android.intent.action.SET_ALARM',
      arguments: <String, dynamic>{
        'android.intent.extra.alarm.HOUR': hour.clamp(0, 23),
        'android.intent.extra.alarm.MINUTES': minute.clamp(0, 59),
        'android.intent.extra.alarm.MESSAGE': message,
        'android.intent.extra.alarm.SKIP_UI': skipUi,
      },
    );
    await intent.launch();
  }
}
