import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoliu/core/async_mutex.dart';
import 'package:xiaoliu/core/image_compressor.dart';
import 'package:xiaoliu/core/token_estimator.dart';
import 'package:xiaoliu/data/database_helper.dart';
import 'package:xiaoliu/tools/gpx_parser.dart';
import 'package:xiaoliu/tools/hook_runtime.dart';
import 'package:xiaoliu/tools/tool_registry.dart';

void main() {
  sqfliteFfiInit();

  late DatabaseHelper db;
  late ToolRegistry registry;

  setUp(() async {
    db = DatabaseHelper.forTesting(
      databaseFactoryOverride: databaseFactoryFfi,
      dbPathOverride: inMemoryDatabasePath,
    );

    final persona = File('assets/seeds/persona_seed.local.json').existsSync()
        ? File('assets/seeds/persona_seed.local.json').readAsStringSync()
        : File('assets/seeds/persona_seed.example.json').readAsStringSync();
    final profiles = File('assets/seeds/profiles.local.json').existsSync()
        ? File('assets/seeds/profiles.local.json').readAsStringSync()
        : File('assets/seeds/profiles.example.json').readAsStringSync();
    final tuning = File('assets/seeds/machine_tuning.local.json').existsSync()
        ? File('assets/seeds/machine_tuning.local.json').readAsStringSync()
        : File('assets/seeds/machine_tuning.example.json').readAsStringSync();

    await db.seedFromStrings(
      personaJson: persona,
      profilesJson: profiles,
      tuningJson: tuning,
    );
    registry = ToolRegistry(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('Seeds traits, rooms, and profiles accurately', () async {
    final traits = await db.getAllTraits();
    expect(traits.containsKey('SOUL.md'), isTrue);
    expect(traits.containsKey('VOICE.md'), isTrue);
    expect(traits.containsKey('USER.md'), isTrue);

    final rooms = await db.getRooms();
    expect(rooms.first.roomId, 'main');
    expect(rooms.any((r) => r.roomId == 'para:projects:demo_project_a'), isTrue);

    final hits094 = await db.lookupProfiles('094');
    expect(hits094.first.code, '094');
    expect(hits094.first.weightPerM, closeTo(0.32, 0.001));
    expect(hits094.first.stockRule, contains('6400'));

    final hits098 = await db.lookupProfiles('098M');
    expect(hits098.first.extrudable, isTrue);
    expect(hits098.first.weightPerM, closeTo(0.45, 0.001));
  });

  test('data_write appends without wiping old todos and computes progress', () async {
    const roomId = 'para:projects:demo_project_a';
    final before = await db.getRoomTodos(roomId);
    expect(before.length, 3);

    await db.upsertTodoItem(roomId: roomId, itemText: '補兩支立柱');
    final afterAppend = await db.getRoomTodos(roomId);
    expect(afterAppend.length, 4);
    expect(afterAppend.last.text, '補兩支立柱');
    expect(afterAppend.last.done, isFalse);

    await db.upsertTodoItem(roomId: roomId, itemText: '補兩支立柱', status: 'done');
    final afterDone = await db.getRoomTodos(roomId);
    expect(afterDone.length, 4);
    expect(afterDone.last.done, isTrue);

    final progress = DatabaseHelper.calculateProgress(afterDone);
    expect(progress, closeTo(0.75, 0.01));
  });

  test('archiveUserMessageToRoom copies message, creates todo, and tints original bubble', () async {
    final userMsg = await db.insertMessage(
      roomId: 'main',
      role: 'user',
      content: '示範專案 A 蓋板補切兩支 343mm',
    );

    await db.archiveUserMessageToRoom(
      messageId: userMsg.id,
      targetRoomId: 'para:projects:demo_project_a',
      addAsTodo: true,
    );

    final mainMsgs = await db.getMessages('main');
    final updated = mainMsgs.firstWhere((m) => m.id == userMsg.id);
    expect(updated.archivedColorHex, '#F59E0B');
    expect(updated.archivedTitle, contains('示範專案 A'));

    final targetMsgs = await db.getMessages('para:projects:demo_project_a');
    expect(targetMsgs.any((m) => m.content.contains('343mm')), isTrue);

    final targetTodos = await db.getRoomTodos('para:projects:demo_project_a');
    expect(targetTodos.any((t) => t.text.contains('343mm')), isTrue);
  });

  test('Global pending memo aggregates starred messages and incomplete todos', () async {
    final msg = await db.insertMessage(
      roomId: 'para:projects:demo_project_b',
      role: 'user',
      content: '白板草稿先暫存',
      isStarred: true,
    );

    final memo = await db.getGlobalPendingMemo();
    expect(memo.starredMessages.any((e) => e.message.id == msg.id), isTrue);
    expect(memo.pendingTodoGroups, isNotEmpty);

    await db.setMessageStarred(msg.id, false);
    final afterUnstar = await db.getGlobalPendingMemo();
    expect(afterUnstar.starredMessages.any((e) => e.message.id == msg.id), isFalse);
  });

  test('ToolRegistry lookup_profile & lookup_machine_tuning return deterministic cards or not-found', () async {
    final profileOutcome = await registry.executeTool(
      toolName: 'lookup_profile',
      args: {'code': '098M', 'length_mm': 4000, 'qty': 200},
      roomId: 'main',
    );
    expect(profileOutcome.card, isNotNull);
    expect(profileOutcome.card!.title, contains('098M'));
    expect(profileOutcome.card!.rows.join('\n'), contains('360.00 kg'));

    final unknownTuning = await registry.executeTool(
      toolName: 'lookup_machine_tuning',
      args: {'query': '不存在的神秘機台參數XYZ'},
      roomId: 'main',
    );
    expect(unknownTuning.toolResponse['found'], isFalse);
    expect(unknownTuning.directReply, contains('查無參數'));
  });

  test('AsyncMutex strictly serializes concurrent operations', () async {
    final mutex = AsyncMutex();
    final events = <String>[];

    final f1 = mutex.synchronized(() async {
      events.add('start-1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      events.add('end-1');
    });
    final f2 = mutex.synchronized(() async {
      events.add('start-2');
      events.add('end-2');
    });

    await Future.wait([f1, f2]);
    expect(events, ['start-1', 'end-1', 'start-2', 'end-2']);
  });

  test('ImageCompressor scales images with long edge > 896px down to <= 896px', () {
    final large = img.Image(width: 2000, height: 1000);
    final rawBytes = Uint8List.fromList(img.encodeJpg(large));
    final result = ImageCompressor.compressBytes(rawBytes);

    expect(result.width, 896);
    expect(result.height, 448);
    expect(result.estimatedTokens, inInclusiveRange(256, 512));
  });

  test('deleteRoom soft-deletes target room and children while protecting main room', () async {
    await db.deleteRoom('main');
    final roomsAfterMainAttempt = await db.getRooms();
    expect(roomsAfterMainAttempt.any((r) => r.roomId == 'main'), isTrue);

    const targetRoomId = 'para:projects:demo_project_a';
    await db.insertMessage(
      roomId: targetRoomId,
      role: 'user',
      content: '準備刪除的測試訊息',
      isStarred: true,
    );

    await db.deleteRoom(targetRoomId);
    final roomsAfterDelete = await db.getRooms();
    expect(roomsAfterDelete.any((r) => r.roomId == targetRoomId), isFalse);
    expect(await db.getMessages(targetRoomId), isEmpty);
    expect(await db.getRoomTodos(targetRoomId), isEmpty);

    final pending = await db.exportSyncPayload(onlyPending: true);
    final deletedRoom = (pending['rooms'] as List<Map<String, Object?>>)
        .firstWhere((r) => r['room_id'] == targetRoomId);
    expect(deletedRoom['is_deleted'], 1);
  });

  test('P2 sync export, markAllSynced, and LWW + tombstone merge work reliably', () async {
    expect(await db.getPendingSyncCount(), greaterThan(0));

    final initialPayload = await db.exportSyncPayload(onlyPending: true);
    expect(initialPayload['app'], 'HAKO');
    expect(initialPayload['agent'], 'KODARI');

    final syncTs = DateTime.now().millisecondsSinceEpoch;
    await db.markAllSynced(syncTs);
    expect(await db.getPendingSyncCount(), 0);

    final msgTs = syncTs + 1000;
    final newerRoomTs = syncTs + 2000;
    final mergeRes = await db.mergeRemoteSyncPayload({
      'rooms': [
        {
          'room_id': 'para:projects:Fold6_新案場',
          'title': 'Fold6 新建案場',
          'subtitle': '遠端同步測試',
          'color_hex': '#38BDF8',
          'avatar_state': 'idle',
          'is_main': 0,
          'is_archived': 0,
          'rolling_summary': '',
          'summary_cursor_id': 0,
          'updated_at': newerRoomTs,
          'is_deleted': 0,
        },
        {
          'room_id': 'para:projects:demo_project_b',
          'title': '示範專案 B（遠端已刪）',
          'subtitle': '已刪除',
          'color_hex': '#10B981',
          'avatar_state': 'idle',
          'is_main': 0,
          'is_archived': 0,
          'rolling_summary': '',
          'summary_cursor_id': 0,
          'updated_at': newerRoomTs,
          'is_deleted': 1,
        },
      ],
      'messages': [
        {
          'room_id': 'para:projects:Fold6_新案場',
          'role': 'user',
          'content': '這是從 Fold 6 同步過來的交班訊息',
          'created_at': msgTs,
          'updated_at': msgTs,
          'is_deleted': 0,
        },
      ],
    });

    expect(mergeRes.upserted, greaterThanOrEqualTo(2));
    expect(mergeRes.deleted, 1);

    final roomsAfterMerge = await db.getRooms();
    expect(roomsAfterMerge.any((r) => r.roomId == 'para:projects:Fold6_新案場'), isTrue);
    expect(roomsAfterMerge.any((r) => r.roomId == 'para:projects:demo_project_b'), isFalse);

    // Re-importing same message should deduplicate cleanly and not duplicate rows
    await db.mergeRemoteSyncPayload({
      'messages': [
        {
          'room_id': 'para:projects:Fold6_新案場',
          'role': 'user',
          'content': '這是從 Fold 6 同步過來的交班訊息',
          'created_at': msgTs,
          'updated_at': msgTs,
          'is_deleted': 0,
        },
      ],
    });
    final syncedMsgs = await db.getMessages('para:projects:Fold6_新案場');
    expect(syncedMsgs.length, 1);
  });

  test('TokenEstimator and stale calendar year guard work accurately', () async {
    expect(TokenEstimator.estimateTextTokens('測試十個中文字長度呀'), 18);
    expect(TokenEstimator.formatCompact(1240), '1.2k');
    expect(TokenEstimator.formatCompact(780), '780');

    final calOutcome = await registry.executeTool(
      toolName: 'create_calendar_event',
      args: {
        'title': '測試今天排程',
        'start_iso': '2025-07-17T14:00:00',
        'description': '今天下午測試',
      },
      roomId: 'main',
    );
    final now = DateTime.now();
    expect(calOutcome.card, isNotNull);
    expect(calOutcome.card!.rows.first, contains('${now.year}/${now.month}/${now.day} 14:00'));

    final oneMin = ToolRegistry.parseLooseDateTime('1分鐘後測試響鈴');
    final diffSec = oneMin.difference(now).inSeconds;
    expect(diffSec, inInclusiveRange(55, 65));

    final fiveMin = ToolRegistry.parseLooseDateTime('五分鐘後喝水');
    expect(fiveMin.difference(now).inMinutes, inInclusiveRange(4, 5));

    final noAfter = ToolRegistry.parseLooseDateTime('測試 2分鐘');
    expect(noAfter.difference(now).inSeconds, inInclusiveRange(115, 125));

    final matched = ToolRegistry.matchLeadingAtTool('@排日曆 測試 今天');
    expect(matched, isNotNull);
    expect(matched!.option.toolName, 'create_calendar_event');
    expect(matched.cleanText, '測試 今天');

    final mil = ToolRegistry.parseLooseDateTime('今天1800 下班');
    expect(mil.hour, 18);
    expect(mil.minute, 0);
  });

  test('Main-only search_memory, global search, and voice normalization work accurately', () async {
    final mainOpts = ToolRegistry.optionsForRoom('main');
    final subOpts = ToolRegistry.optionsForRoom('para:projects:demo_project_a');
    expect(mainOpts.any((o) => o.toolName == 'search_memory'), isTrue);
    expect(subOpts.any((o) => o.toolName == 'search_memory'), isFalse);

    await db.insertMessage(
      roomId: 'para:projects:demo_project_a',
      role: 'user',
      content: '示範專案 A 需要補切 588mm 五支',
    );
    final hits = await db.searchGlobalMemory('588mm');
    expect(hits, isNotEmpty);
    expect(hits.first.roomId, 'para:projects:demo_project_a');

    expect(
      ToolRegistry.normalizeSpokenCommand('可達 設鬧鐘 5分鐘後喝水'),
      '@設鬧鐘 5分鐘後喝水',
    );
    expect(
      ToolRegistry.normalizeSpokenCommand('嘿可達，搜記憶 588mm'),
      '@搜記憶 588mm',
    );

    // Search command in main room should not match itself, and should match room title "示範專案 A"
    await db.insertMessage(
      roomId: 'main',
      role: 'user',
      content: '@搜記憶 示範專案A房 我們聊怎樣了',
    );
    final roomHits = await db.searchGlobalMemory('示範專案 A 我們聊怎樣了');
    expect(roomHits, isNotEmpty);
    expect(roomHits.any((h) => h.snippet.startsWith('@搜記憶')), isFalse);
    expect(roomHits.any((h) => h.roomId == 'para:projects:demo_project_a'), isTrue);

    // MEMORY.md autonomous distillation storage, dedupe, and 20-entry cap
    final traits = await db.getAllTraits();
    expect(traits.containsKey('MEMORY.md'), isTrue);
    expect(await db.appendDistilledMemory('NONE'), isFalse);
    expect(await db.appendDistilledMemory('- 喜歡早上八點準時出車'), isTrue);
    expect(await db.appendDistilledMemory('喜歡早上八點準時出車'), isFalse);
    for (var i = 0; i < 25; i++) {
      await db.appendDistilledMemory('記憶項目 $i');
    }
    final updatedTraits = await db.getAllTraits();
    final memLines = updatedTraits['MEMORY.md']!
        .split('\n')
        .where((l) => l.startsWith('- '))
        .toList();
    expect(memLines.length, 20);
  });

  test('Upgrades example profiles and tuning tables to full local seeds cleanly', () async {
    final upgradeDb = DatabaseHelper.forTesting(
      databaseFactoryOverride: databaseFactoryFfi,
      dbPathOverride: inMemoryDatabasePath,
    );
    try {
      final exPersona = File('assets/seeds/persona_seed.example.json').readAsStringSync();
      final exProfiles = File('assets/seeds/profiles.example.json').readAsStringSync();
      final exTuning = File('assets/seeds/machine_tuning.example.json').readAsStringSync();

      await upgradeDb.seedFromStrings(
        personaJson: exPersona,
        profilesJson: exProfiles,
        tuningJson: exTuning,
      );
      expect(await upgradeDb.lookupProfiles('SAMPLE-01'), isNotEmpty);

      final localProfiles = File('assets/seeds/profiles.local.json').existsSync()
          ? File('assets/seeds/profiles.local.json').readAsStringSync()
          : '[{"code":"093Z","weight_per_m":0.28,"stock_rule":"6400mm","extrudable":1,"note":""}]';
      final localTuning = File('assets/seeds/machine_tuning.local.json').existsSync()
          ? File('assets/seeds/machine_tuning.local.json').readAsStringSync()
          : '[{"id":"TUNE-REAL","keywords":"調機","title":"實務調機","formula":"OK","note":""}]';

      await upgradeDb.seedFromStrings(
        personaJson: exPersona,
        profilesJson: localProfiles,
        tuningJson: localTuning,
      );

      expect(await upgradeDb.lookupProfiles('SAMPLE-01'), isEmpty);
      expect(await upgradeDb.lookupProfiles('093Z'), isNotEmpty);
      expect(await upgradeDb.lookupMachineTuning('SAMPLE-TUNE'), isEmpty);
    } finally {
      await upgradeDb.close();
    }
  });

  test('HookRuntime executes seeded skills and custom registered formulas cleanly', () async {
    final hooks = await db.getHooks();
    expect(hooks.any((h) => h.name == '估重109'), isTrue);
    expect(hooks.any((h) => h.name == '鋸路餘料'), isTrue);

    final weightRes = await registry.executeTool(
      toolName: 'hook_tool',
      args: {'query': '估重109 0.5 2000 10'},
      roomId: 'main',
    );
    expect(weightRes.toolResponse['ok'], isTrue);
    expect(weightRes.toolResponse['output'], contains('10.00 kg'));
    expect(weightRes.toolResponse['output'], contains('10.90 kg'));

    final kerfRes = await registry.executeTool(
      toolName: 'hook_tool',
      args: {'query': '鋸路餘料 6000 1500 3'},
      roomId: 'main',
    );
    expect(kerfRes.toolResponse['ok'], isTrue);
    expect(kerfRes.toolResponse['output'], contains('1486.0mm'));
    expect(kerfRes.toolResponse['output'], contains('可入庫新資產'));

    // Register a new formula dynamically via @技能 command and invoke it
    final regRes = await registry.executeTool(
      toolName: 'hook_tool',
      args: {'query': '註冊 孔距檢查 | 欄杆孔數 | span,holes | (span / (holes - 1)).toFixed(1) + "mm"'},
      roomId: 'main',
    );
    expect(regRes.toolResponse['registered'], '孔距檢查');

    final callCustom = await registry.executeTool(
      toolName: 'hook_tool',
      args: {'query': '孔距檢查 1000 11'},
      roomId: 'main',
    );
    expect(callCustom.toolResponse['output'], '100.0mm');

    // Pure unit check on HookRuntime.parseRegisterCommand shorthand
    final shortSpec = HookRuntime.parseRegisterCommand('註冊 倍數 | a,b | a * b * 2');
    expect(shortSpec, isNotNull);
    expect(shortSpec!.params, ['a', 'b']);
  });

  test('GpxParser extracts Garmin waypoints, routes, and tracks with metadata', () {
    const sampleGpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Garmin Explore">
  <wpt lat="23.711234" lon="120.543210">
    <ele>42.5</ele>
    <time>2026-11-16T07:30:00Z</time>
    <name><![CDATA[斗六基地]]></name>
    <cmt>出發點</cmt>
  </wpt>
  <rtept lat="23.512345" lon="120.112233">
    <name>外傘頂洲暗礁</name>
    <desc>流溝咬況好</desc>
  </rtept>
  <trkpt lat="23.512345" lon="120.112233" />
  <trkpt lat="23.520000" lon="120.120000" />
</gpx>
''';
    final points = GpxParser.parse(sampleGpx);
    expect(points.length, 3);
    expect(points[0].name, '斗六基地');
    expect(points[0].elevation, closeTo(42.5, 0.01));
    expect(points[0].note, '出發點');
    expect(points[1].name, '外傘頂洲暗礁');
    expect(points[1].googleMapsUrl, 'https://maps.google.com/?q=23.512345,120.112233');
    expect(points[2].kind, 'trkpt');
  });

  test('P3 @ tools match aliases and voice commands cleanly', () {
    expect(ToolRegistry.matchLeadingAtTool('@量測標註 一樓大門')?.option.toolName, 'photo_annotate');
    expect(ToolRegistry.matchLeadingAtTool('@掃相簿')?.option.toolName, 'album_scan');
    expect(ToolRegistry.matchLeadingAtTool('@報位置 暗礁點')?.option.toolName, 'location_tool');
    expect(ToolRegistry.matchLeadingAtTool('@轉LINE 給阿弟')?.option.toolName, 'share_line');
    expect(ToolRegistry.matchLeadingAtTool('@技能 估重109')?.option.toolName, 'hook_tool');

    expect(ToolRegistry.normalizeSpokenCommand('可達 報位置 港口南堤'), '@報位置 港口南堤');
    expect(ToolRegistry.normalizeSpokenCommand('傳LINE'), '@轉LINE');
    expect(ToolRegistry.normalizeSpokenCommand('量測標註 二樓窗框'), '@量測標註 二樓窗框');
    expect(ToolRegistry.normalizeSpokenCommand('掃相簿'), '@掃相簿');
    expect(ToolRegistry.normalizeSpokenCommand('跑技能 估重109'), '@技能 估重109');
  });
}
