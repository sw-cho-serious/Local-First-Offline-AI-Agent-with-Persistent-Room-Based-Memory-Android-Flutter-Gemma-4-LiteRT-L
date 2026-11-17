import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class AlbumPhotoItem {
  const AlbumPhotoItem({
    required this.id,
    required this.displayName,
    required this.dateTakenMs,
    required this.width,
    required this.height,
    required this.bucketName,
    required this.thumbPath,
  });

  final int id;
  final String displayName;
  final int dateTakenMs;
  final int width;
  final int height;
  final String bucketName;
  final String thumbPath;

  factory AlbumPhotoItem.fromMap(Map<Object?, Object?> map) {
    return AlbumPhotoItem(
      id: (map['id'] as num?)?.toInt() ?? 0,
      displayName: map['displayName']?.toString() ?? 'photo.jpg',
      dateTakenMs: (map['dateTakenMs'] as num?)?.toInt() ?? 0,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      bucketName: map['bucketName']?.toString() ?? '相簿',
      thumbPath: map['thumbPath']?.toString() ?? '',
    );
  }
}

class DeviceLocationResult {
  const DeviceLocationResult({
    required this.ok,
    this.lat,
    this.lng,
    this.altitude,
    this.accuracy,
    this.provider,
    this.timestampMs,
    this.stale = false,
    this.reason,
  });

  final bool ok;
  final double? lat;
  final double? lng;
  final double? altitude;
  final double? accuracy;
  final String? provider;
  final int? timestampMs;
  final bool stale;
  final String? reason;

  String get coordsText =>
      ok && lat != null && lng != null ? '${lat!.toStringAsFixed(6)}, ${lng!.toStringAsFixed(6)}' : '';

  String get googleMapsUrl =>
      ok && lat != null && lng != null ? 'https://maps.google.com/?q=${lat!.toStringAsFixed(6)},${lng!.toStringAsFixed(6)}' : '';
}

class NativeActions {
  static const MethodChannel _calendarChannel =
      MethodChannel('com.weilong.hako/calendar');
  static const MethodChannel _speechChannel =
      MethodChannel('com.weilong.hako/speech');
  static const MethodChannel _deviceChannel =
      MethodChannel('com.weilong.hako/device');
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

    const androidSettings = AndroidInitializationSettings('ic_stat_hako');
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

  static Future<bool> ensureLocationPermission() async {
    if (!Platform.isAndroid) return true;
    var status = await Permission.locationWhenInUse.status;
    if (status.isGranted) return true;
    status = await Permission.locationWhenInUse.request();
    if (status.isGranted) return true;
    final legacy = await Permission.location.request();
    return legacy.isGranted;
  }

  static Future<DeviceLocationResult> getCurrentLocation() async {
    if (!Platform.isAndroid) {
      return const DeviceLocationResult(ok: false, reason: '非 Android 裝置環境');
    }
    final granted = await ensureLocationPermission();
    if (!granted) {
      return const DeviceLocationResult(ok: false, reason: '請先允許定位權限後再抓取 GPS 座標');
    }
    try {
      final res = await _deviceChannel.invokeMapMethod<String, dynamic>('getCurrentLocation');
      if (res == null || res['ok'] != true) {
        return DeviceLocationResult(
          ok: false,
          reason: res?['reason']?.toString() ?? '無法取得 GPS 座標',
        );
      }
      return DeviceLocationResult(
        ok: true,
        lat: (res['lat'] as num?)?.toDouble(),
        lng: (res['lng'] as num?)?.toDouble(),
        altitude: (res['altitude'] as num?)?.toDouble(),
        accuracy: (res['accuracy'] as num?)?.toDouble(),
        provider: res['provider']?.toString(),
        timestampMs: (res['timestampMs'] as num?)?.toInt(),
        stale: res['stale'] == true,
      );
    } catch (e) {
      return DeviceLocationResult(ok: false, reason: e.toString());
    }
  }

  static Future<void> openMapLocation(
    double lat,
    double lng, {
    String? label,
  }) async {
    if (!Platform.isAndroid) return;
    final encodedLabel = Uri.encodeComponent(
      (label == null || label.trim().isEmpty) ? 'HAKO 標點' : label.trim(),
    );
    final geoUri = 'geo:${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}'
        '?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}($encodedLabel)';
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: geoUri,
      );
      await intent.launch();
    } catch (_) {
      final webIntent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: 'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}',
      );
      await webIntent.launch();
    }
  }

  static Future<({bool ok, bool withImage, String? error})> shareToLine({
    required String text,
    String? imagePath,
  }) async {
    if (!Platform.isAndroid) {
      return (ok: false, withImage: false, error: '非 Android 裝置環境');
    }
    try {
      final res = await _deviceChannel.invokeMapMethod<String, dynamic>(
        'shareContent',
        {
          'text': text,
          'imagePath': imagePath,
        },
      );
      if (res != null && res['ok'] == true) {
        return (ok: true, withImage: res['withImage'] == true, error: null);
      }
      return (
        ok: false,
        withImage: false,
        error: res?['reason']?.toString() ?? '系統分享開啟失敗',
      );
    } catch (e) {
      return (ok: false, withImage: false, error: e.toString());
    }
  }

  static Future<bool> ensurePhotoAlbumPermission() async {
    if (!Platform.isAndroid) return true;
    final photoStatus = await Permission.photos.status;
    if (photoStatus.isGranted || photoStatus.isLimited) return true;
    final photoReq = await Permission.photos.request();
    if (photoReq.isGranted || photoReq.isLimited) return true;
    if ((await Permission.manageExternalStorage.status).isGranted) return true;
    final storageReq = await Permission.storage.request();
    return storageReq.isGranted;
  }

  static Future<List<AlbumPhotoItem>> scanRecentAlbumPhotos({
    int limit = 30,
    int sinceMs = 0,
  }) async {
    if (!Platform.isAndroid) return const [];
    final granted = await ensurePhotoAlbumPermission();
    if (!granted) return const [];
    try {
      final list = await _deviceChannel.invokeListMethod<dynamic>(
        'scanRecentPhotos',
        {'limit': limit, 'sinceMs': sinceMs},
      );
      if (list == null) return const [];
      return list
          .whereType<Map<Object?, Object?>>()
          .map(AlbumPhotoItem.fromMap)
          .where((item) => item.thumbPath.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[NativeActions] scanRecentAlbumPhotos error: $e');
      return const [];
    }
  }

  static Future<String?> copyAlbumPhotoToTemp(int id) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _deviceChannel.invokeMethod<String>(
        'copyAlbumPhoto',
        {'id': id},
      );
    } catch (e) {
      debugPrint('[NativeActions] copyAlbumPhotoToTemp error: $e');
      return null;
    }
  }

  static Future<({bool ok, String result, String? error})> evaluateJsSandbox({
    required String code,
    required Map<String, dynamic> args,
  }) async {
    if (!Platform.isAndroid) {
      return (ok: false, result: '', error: 'Android WebView 沙盒僅於實體機執行');
    }
    try {
      final res = await _deviceChannel.invokeMapMethod<String, dynamic>(
        'evalJsHook',
        {
          'code': code,
          'argsJson': jsonEncode(args),
        },
      );
      if (res != null && res['ok'] == true) {
        return (ok: true, result: (res['result'] ?? '').toString(), error: null);
      }
      return (
        ok: false,
        result: '',
        error: res?['error']?.toString() ?? 'JS 執行失敗',
      );
    } catch (e) {
      return (ok: false, result: '', error: e.toString());
    }
  }
}
