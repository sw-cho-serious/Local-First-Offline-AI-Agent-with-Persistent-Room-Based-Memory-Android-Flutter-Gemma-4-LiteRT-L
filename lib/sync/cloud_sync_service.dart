import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database_helper.dart';

class SyncResult {
  const SyncResult({
    required this.ok,
    required this.message,
    this.pushedCount = 0,
    this.pulledUpserts = 0,
    this.pulledDeletes = 0,
  });

  final bool ok;
  final String message;
  final int pushedCount;
  final int pulledUpserts;
  final int pulledDeletes;
}

/// Phase 2 Cloud Handoff & Sync Service:
/// - Zero background polling (only startup check, debounced post-write push, and manual cloud button).
/// - Physically isolated from factory inventory sheets via dedicated GAS Web App gateway.
class CloudSyncService extends ChangeNotifier {
  CloudSyncService(this._db);

  static const _prefUrlKey = 'hako_gas_webapp_url';
  static const _prefTokenKey = 'hako_gas_sync_token';
  static const _prefLastSyncKey = 'hako_last_sync_ms';

  final DatabaseHelper _db;

  String _gasUrl = '';
  String _syncToken = '';
  int _lastSyncAtMs = 0;
  int _pendingCount = 0;
  bool _isSyncing = false;
  String _lastStatusMessage = '尚未設定 GAS 閘道（支援手動複製交班包）';

  Timer? _debouncePushTimer;

  String get gasUrl => _gasUrl;
  String get syncToken => _syncToken;
  int get lastSyncAtMs => _lastSyncAtMs;
  int get pendingCount => _pendingCount;
  bool get isSyncing => _isSyncing;
  bool get isConfigured => _gasUrl.trim().isNotEmpty;
  String get lastStatusMessage => _lastStatusMessage;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _gasUrl = prefs.getString(_prefUrlKey) ?? '';
    _syncToken = prefs.getString(_prefTokenKey) ?? '';
    _lastSyncAtMs = prefs.getInt(_prefLastSyncKey) ?? 0;
    await refreshPendingCount();
  }

  Future<void> refreshPendingCount() async {
    _pendingCount = await _db.getPendingSyncCount();
    notifyListeners();
  }

  Future<void> saveConfig({required String url, required String token}) async {
    final prefs = await SharedPreferences.getInstance();
    _gasUrl = url.trim();
    _syncToken = token.trim();
    await prefs.setString(_prefUrlKey, _gasUrl);
    await prefs.setString(_prefTokenKey, _syncToken);
    _lastStatusMessage = isConfigured ? '已綁定雲端閘道，隨時可同步' : '尚未設定 GAS 閘道';
    notifyListeners();
  }

  /// Trigger 1: Silent sync once on app startup when URL is configured.
  Future<void> syncOnStartupIfConfigured() async {
    await initialize();
    if (isConfigured) {
      unawaited(syncNow(silent: true));
    }
  }

  /// Trigger 2: Debounced push right after local writes/deletes.
  void scheduleDebouncedPush() {
    unawaited(refreshPendingCount());
    if (!isConfigured) return;
    _debouncePushTimer?.cancel();
    _debouncePushTimer = Timer(const Duration(seconds: 3), () {
      unawaited(syncNow(silent: true));
    });
  }

  /// Trigger 3: Manual cloud button sync (two-way Push pending + Pull newer updates).
  Future<SyncResult> syncNow({bool silent = false}) async {
    if (!isConfigured) {
      return const SyncResult(ok: false, message: '請先填入 GAS Web App URL');
    }
    if (_isSyncing) {
      return const SyncResult(ok: false, message: '同步進行中…');
    }

    _isSyncing = true;
    if (!silent) {
      _lastStatusMessage = '☁️ 正在與雲端交班同步…';
      notifyListeners();
    }

    try {
      final pendingPayload = await _db.exportSyncPayload(onlyPending: true);
      final pushTimestamp = pendingPayload['exported_at'] as int;
      final pendingItemsCount =
          (pendingPayload['traits'] as List).length +
          (pendingPayload['rooms'] as List).length +
          (pendingPayload['data'] as List).length +
          (pendingPayload['messages'] as List).length +
          (pendingPayload['hooks'] as List).length;

      final bodyMap = <String, dynamic>{
        'action': 'sync',
        'token': _syncToken,
        'last_sync_at': _lastSyncAtMs,
        'payload': pendingPayload,
      };

      final responseJson = await _postToGas(Uri.parse(_gasUrl), bodyMap);
      if (responseJson['ok'] != true) {
        final err = responseJson['error']?.toString() ?? '未知閘道錯誤';
        _lastStatusMessage = '同步失敗：$err';
        notifyListeners();
        return SyncResult(ok: false, message: _lastStatusMessage);
      }

      // Mark pushed records synced before merging remote updates.
      await _db.markAllSynced(pushTimestamp);

      final remotePayload = responseJson['remote_payload'];
      var upserts = 0;
      var deletes = 0;
      if (remotePayload is Map<String, dynamic>) {
        final merged = await _db.mergeRemoteSyncPayload(remotePayload);
        upserts = merged.upserted;
        deletes = merged.deleted;
      }

      final serverTime = (responseJson['server_time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      _lastSyncAtMs = serverTime;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefLastSyncKey, _lastSyncAtMs);

      await refreshPendingCount();
      _lastStatusMessage =
          '✅ 已同步（送出 $pendingItemsCount 筆 / 拉回更新 $upserts 筆、移除 $deletes 筆）';
      notifyListeners();

      return SyncResult(
        ok: true,
        message: _lastStatusMessage,
        pushedCount: pendingItemsCount,
        pulledUpserts: upserts,
        pulledDeletes: deletes,
      );
    } catch (e) {
      _lastStatusMessage = '離線或連線失敗：$e';
      notifyListeners();
      return SyncResult(ok: false, message: _lastStatusMessage);
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  /// Handles GAS standard HTTP 302 redirect cleanly after POST execution.
  Future<Map<String, dynamic>> _postToGas(
    Uri uri,
    Map<String, dynamic> body,
  ) async {
    final encoded = jsonEncode(body);
    final res = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: encoded,
        )
        .timeout(const Duration(seconds: 20));

    if (res.statusCode == 302 || res.statusCode == 301 || res.statusCode == 307) {
      final loc = res.headers['location'];
      if (loc != null && loc.isNotEmpty) {
        final redirected = await http
            .get(Uri.parse(loc))
            .timeout(const Duration(seconds: 20));
        if (redirected.statusCode >= 200 && redirected.statusCode < 300) {
          return jsonDecode(redirected.body) as Map<String, dynamic>;
        }
        throw Exception('GAS redirect HTTP ${redirected.statusCode}');
      }
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw Exception('HTTP ${res.statusCode}');
  }

  /// Manual P2 handoff export (works 100% offline or across Sony <-> Fold 6).
  Future<String> exportFullSnapshotJson() async {
    final payload = await _db.exportSyncPayload(onlyPending: false);
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Manual P2 handoff import (merges snapshot via LWW without wiping newer local items).
  Future<({int upserted, int deleted})> importSnapshotJson(String rawJson) async {
    final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
    final res = await _db.mergeRemoteSyncPayload(decoded);
    await refreshPendingCount();
    return res;
  }

  @override
  void dispose() {
    _debouncePushTimer?.cancel();
    super.dispose();
  }
}
