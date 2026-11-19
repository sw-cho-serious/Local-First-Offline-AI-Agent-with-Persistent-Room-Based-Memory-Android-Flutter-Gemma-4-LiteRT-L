import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoliu/core/async_mutex.dart';
import 'package:xiaoliu/core/image_compressor.dart';
import 'package:xiaoliu/core/token_estimator.dart';
import 'package:xiaoliu/data/database_helper.dart';
import 'package:xiaoliu/data/models.dart';
import 'package:xiaoliu/engine/gemma_litert_engine.dart';
import 'package:xiaoliu/tools/fast_path_router.dart';
import 'package:xiaoliu/tools/native_actions.dart';
import 'package:xiaoliu/tools/routine_scheduler.dart';
import 'package:xiaoliu/tools/tool_registry.dart';
import 'package:xiaoliu/tools/web_search_service.dart';
import 'package:xiaoliu/ui/widgets/kodari_floating_nub.dart';

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

    // Delete single todo & clear completed todos
    final removed = await db.clearCompletedTodos(roomId);
    expect(removed, 3);
    final remaining = await db.getRoomTodos(roomId);
    expect(remaining.length, 1);
    expect(remaining.first.done, isFalse);

    await db.deleteTodoAtIndex(roomId, remaining.first.lineIndex);
    expect(await db.getRoomTodos(roomId), isEmpty);
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

  test('ImageCompressor scales images with long edge > 1568px down to <= 1568px', () {
    final large = img.Image(width: 2000, height: 1000);
    final rawBytes = Uint8List.fromList(img.encodeJpg(large));
    final result = ImageCompressor.compressBytes(rawBytes);

    expect(result.width, 1568);
    expect(result.height, 784);
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

  test('P3 @ tools match aliases and voice commands cleanly', () {
    expect(ToolRegistry.matchLeadingAtTool('@量測標註 一樓大門')?.option.toolName, 'photo_annotate');
    expect(ToolRegistry.matchLeadingAtTool('@掃相簿')?.option.toolName, 'album_scan');
    expect(ToolRegistry.matchLeadingAtTool('@報位置 暗礁點')?.option.toolName, 'location_tool');
    expect(ToolRegistry.matchLeadingAtTool('@轉LINE 給阿弟')?.option.toolName, 'share_line');
    expect(ToolRegistry.matchLeadingAtTool('@技能')?.option.toolName, 'load_skill');
    expect(ToolRegistry.matchLeadingAtTool('@知識')?.option.toolName, 'load_skill');

    expect(ToolRegistry.normalizeSpokenCommand('可達 報位置 港口南堤'), '@報位置 港口南堤');
    expect(ToolRegistry.normalizeSpokenCommand('傳LINE'), '@轉LINE');
    expect(ToolRegistry.normalizeSpokenCommand('量測標註 二樓窗框'), '@量測標註 二樓窗框');
    expect(ToolRegistry.normalizeSpokenCommand('掃相簿'), '@掃相簿');
    expect(ToolRegistry.normalizeSpokenCommand('跑技能 估重109'), '@技能 估重109');

    expect(GemmaLiteRtEngine.detectSuggestedRoom('建立工廠雜記的房間'), '工廠雜記');
    expect(GemmaLiteRtEngine.detectSuggestedRoom('幫我開一個南科案房間'), '南科案');
    expect(GemmaLiteRtEngine.detectSuggestedRoom('開新房間叫路亞釣魚'), '路亞釣魚');
  });

  test('P4 JIT Skills CRUD, Markdown import, KV-preserving prompt, sync & native actions', () async {
    // 1. Seeded skills
    final seeded = await db.getSkills();
    expect(seeded.any((s) => s.name == '現場量測SOP'), isTrue);
    expect(seeded.any((s) => s.name == '現場硬體快捷助手'), isTrue);

    // 2. Parse Markdown with YAML frontmatter
    const sampleMd = '''
---
name: 天德大林檢核表
trigger_keywords: 天德,大林,外觀驗收
description: 天德大林案現場收尾核對清單
---
### 收尾重點
- 立柱底板四顆膨脹螺絲扭力確認
- 拍遠景照存進案場房
''';
    final parsed = SkillRecord.parseFromMarkdown(sampleMd);
    expect(parsed.name, '天德大林檢核表');
    expect(parsed.triggerKeywords, ['天德', '大林', '外觀驗收']);
    expect(parsed.description, '天德大林案現場收尾核對清單');
    expect(parsed.contentMd, contains('膨脹螺絲'));

    final saved = await db.upsertSkill(
      id: parsed.id,
      name: parsed.name,
      triggerKeywords: parsed.triggerKeywords,
      description: parsed.description,
      contentMd: parsed.contentMd,
    );

    // 3. Zero-LLM keyword & @Name matching + enabled toggle
    final hitByKw = await db.matchTriggeredSkills('今天要去大林看外觀');
    expect(hitByKw.any((s) => s.id == saved.id), isTrue);

    final hitByAt = await db.matchTriggeredSkills('@天德大林檢核表 開始');
    expect(hitByAt.any((s) => s.id == saved.id), isTrue);

    await db.toggleSkillEnabled(saved.id, false);
    expect(await db.matchTriggeredSkills('要去大林看外觀'), isEmpty);
    await db.toggleSkillEnabled(saved.id, true);

    // 4. KV-preserving turn prompt injection only adds content_md when triggered
    final promptInjected = GemmaLiteRtEngine.buildTurnUserPrompt(
      userText: '大林現場檢查',
      nowStamp: '2026-11-17 19:20 (週二)',
      triggeredSkills: [saved],
    );
    expect(promptInjected, contains('膨脹螺絲'));
    expect(promptInjected, endsWith('[現在時間 2026-11-17 19:20 (週二)] 大林現場檢查'));

    final promptClean = GemmaLiteRtEngine.buildTurnUserPrompt(
      userText: '今天吃什麼',
      nowStamp: '2026-11-17 19:21 (週二)',
    );
    expect(promptClean, '[現在時間 2026-11-17 19:21 (週二)] 今天吃什麼');

    // 5. P2 Sync payload & LWW merge for skills
    final exported = await db.exportSyncPayload(onlyPending: true);
    final exportedSkills = exported['skills'] as List<Map<String, Object?>>;
    expect(exportedSkills.any((row) => row['id'] == saved.id), isTrue);

    final mergeOut = await db.mergeRemoteSyncPayload({
      'skills': [
        {
          'id': 'skill_remote_fold6',
          'name': 'Fold6遠端技能',
          'trigger_keywords': '遠端測試,Fold6',
          'description': '另一支手機同步來的 Skill',
          'content_md': '步驟一：先開手電筒',
          'enabled': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch + 5000,
          'is_deleted': 0,
        },
      ],
    });
    expect(mergeOut.upserted, 1);
    final afterSync = await db.getSkills();
    expect(afterSync.any((s) => s.id == 'skill_remote_fold6'), isTrue);

    // 6. @動作 aliases, voice commands, callNative hook reserve, and load_skill tool
    expect(ToolRegistry.matchLeadingAtTool('@開燈')?.option.toolName, 'device_action');
    expect(ToolRegistry.matchLeadingAtTool('@關燈')?.cleanText, 'flashlight off');
    expect(ToolRegistry.matchLeadingAtTool('@撥號 0912345678')?.cleanText, 'dial 0912345678');
    expect(ToolRegistry.matchLeadingAtTool('@導航 斗六火車站')?.cleanText, 'map 斗六火車站');
    expect(ToolRegistry.matchLeadingAtTool('@倒數 15分鐘')?.cleanText, 'timer 15分鐘');
    expect(ToolRegistry.matchLeadingAtTool('@系統設定 wifi')?.cleanText, 'settings wifi');
    expect(ToolRegistry.matchLeadingAtTool('@知識 天德大林檢核表')?.option.toolName, 'load_skill');

    expect(ToolRegistry.normalizeSpokenCommand('可達 開手電筒'), '@開燈');
    expect(ToolRegistry.normalizeSpokenCommand('可達 關手電筒'), '@關燈');
    expect(ToolRegistry.normalizeSpokenCommand('導航去 斗六'), '@導航 斗六');

    final loadOut = await registry.executeTool(
      toolName: 'load_skill',
      args: {'name': '天德大林檢核表'},
      roomId: 'main',
    );
    expect(loadOut.toolResponse['found'], isTrue);
    expect(loadOut.toolResponse['content_md'], contains('膨脹螺絲'));

    await db.deleteSkill(saved.id);
    expect((await db.getSkills()).any((s) => s.id == saved.id), isFalse);
  });

  test('V2 Batch 1: FastPathRouter, WebSearch DuckDuckGo + Peer Fallback & Dual-Channel Engine', () async {
    SharedPreferences.setMockInitialValues({
      'hako_gas_webapp_url': 'https://script.google.com/macros/s/test-deploy/exec',
      'hako_gas_sync_token': 'weilong-secret',
    });

    // 1. <2ms FastPathRouter Mode A natural spoken commands
    final lightOn = FastPathRouter.matchFastPath('幫我開手電筒');
    expect(lightOn?.toolName, 'device_action');
    expect(lightOn?.args['action'], 'setFlashlight');
    expect(lightOn?.args['value'], 'on');

    final lightOff = FastPathRouter.matchFastPath('把閃光燈關掉');
    expect(lightOff?.args['value'], 'off');

    final timer = FastPathRouter.matchFastPath('倒數 15 分鐘 看烤漆爐');
    expect(timer?.args['action'], 'setTimerOrAlarm');
    expect(timer?.args['message'], '看烤漆爐');

    final alarm = FastPathRouter.matchFastPath('設明天早上7點半的鬧鐘 追金代交期');
    expect(alarm?.args['action'], 'setTimerOrAlarm');
    expect(alarm?.args['value'], '7點30');
    expect(alarm?.args['message'], '追金代交期');

    final nav = FastPathRouter.matchFastPath('導航去古坑新生路');
    expect(nav?.args['action'], 'openMap');
    expect(nav?.args['value'], '古坑新生路');

    final dial = FastPathRouter.matchFastPath('打電話給 0912345678');
    expect(dial?.args['action'], 'dialPhone');
    expect(dial?.args['value'], '0912345678');

    final wifi = FastPathRouter.matchFastPath('打開 Wi-Fi 設定');
    expect(wifi?.args['action'], 'openSettings');

    final webCmd = FastPathRouter.matchFastPath('上網查 304白鐵比重');
    expect(webCmd?.toolName, 'web_search');
    expect(webCmd?.args['query'], '304白鐵比重');

    final peerCmd = FastPathRouter.matchFastPath('呼叫參謀 算098M排抽');
    expect(peerCmd?.toolName, 'consult_peer');
    expect(peerCmd?.args['query'], '算098M排抽');

    // Mode B partial IntentBagger hints (only injected into user prompt)
    final hint = FastPathRouter.bagIntentHints('如果廠區太暗打給 0912345678 看看');
    expect(hint, contains('dialPhone'));
    expect(hint, contains('setFlashlight'));
    final turnPrompt = GemmaLiteRtEngine.buildTurnUserPrompt(
      userText: '如果廠區太暗打給 0912345678 看看',
      nowStamp: '2026-11-18 10:10 (週三)',
      intentHint: hint,
    );
    expect(turnPrompt, startsWith('[Intent Hints:'));

    // 2. DuckDuckGo HTML parsing & automatic fallback into consult_peer
    const sampleDdgHtml = '''
      <div class="result">
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fsteel-304">304 不鏽鋼比重表</a>
        <a class="result__snippet">304 白鐵理論密度約 7.93 g/cm3。</a>
      </div>
    ''';
    final parsedSources = WebSearchService.parseDuckDuckGoHtml(sampleDdgHtml);
    expect(parsedSources.length, 1);
    expect(parsedSources.first.url, 'https://example.com/steel-304');
    expect(parsedSources.first.effectiveDomain, 'example.com');
    expect(parsedSources.first.snippet, contains('7.93'));

    final fallbackClient = _FakeHttpClient((req) async {
      if (req.url.host == 'html.duckduckgo.com') {
        return http.Response('blocked', 403);
      }
      final payload = jsonDecode(req.body) as Map<String, dynamic>;
      expect(payload['action'], 'consult_peer');
      expect(payload['fallback_reason'], contains('403'));
      return http.Response(
        jsonEncode({
          'ok': true,
          'peer': 'Spark 參謀',
          'reply': '已由雲端參謀接手查詢完成。',
          'sources': [
            {
              'title': '雲端查證頁',
              'url': 'https://weilong.example/info',
              'domain': 'weilong.example',
            }
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final webFallbackOut = await WebSearchService.searchWithFallback(
      query: '304白鐵比重',
      client: fallbackClient,
    );
    expect(webFallbackOut.ok, isTrue);
    expect(webFallbackOut.usedPeerFallback, isTrue);
    expect(webFallbackOut.peerName, 'Spark 參謀');
    expect(webFallbackOut.sources.first.url, 'https://weilong.example/info');

    // 3. Dual-channel URL normalization & Channel B activation
    expect(
      GemmaLiteRtEngine.normalizeChatCompletionsUrl('127.0.0.1:8080'),
      'http://127.0.0.1:8080/v1/chat/completions',
    );
    expect(
      GemmaLiteRtEngine.normalizeChatCompletionsUrl('http://192.168.1.50:8080/v1'),
      'http://192.168.1.50:8080/v1/chat/completions',
    );
    expect(
      GemmaLiteRtEngine.formatShortEndpoint('http://192.168.1.50:8080/v1'),
      '192.168.1.50:8080',
    );

    final engine = GemmaLiteRtEngine(db: db, toolRegistry: registry);
    expect(engine.engineChannel, 'litert');
    await engine.configureEngineChannel(
      channel: 'local_http',
      httpUrl: 'http://127.0.0.1:8080/v1',
      httpModel: 'gemma-4-e4b-heretic',
    );
    expect(engine.isModelReady, isTrue);
    expect(engine.activeBackendLabel, 'GGUF • 127.0.0.1:8080');
  });

  test('V2 Batch 2: Operator 🚩 Flags & Reflection, Repetition Loop KV-Flush, Routine Next-3 Preview, /compact & RAM Context Cap', () async {
    // 1. RAM dynamic context cap (8GB -> 5120 vs 12GB -> 8192)
    const status8Gb = DeviceRuntimeStatus(
      ok: true,
      totalRamMb: 7800,
      availRamMb: 2100,
      lowMemory: false,
      isScreenInteractive: true,
      isCharging: false,
      batteryPct: 80,
    );
    const status12Gb = DeviceRuntimeStatus(
      ok: true,
      totalRamMb: 11800,
      availRamMb: 5400,
      lowMemory: false,
      isScreenInteractive: false,
      isCharging: true,
      batteryPct: 92,
    );
    expect(status8Gb.recommendedMaxContextTokens, 5120);
    expect(status12Gb.recommendedMaxContextTokens, 8192);

    // 2. Small-model repetition loop detection & trim
    final shortLoop = GemmaLiteRtEngine.detectAndTrimRepetitionLoop(
      '尺寸算好了，對對對對對對對對對對對對對對對對對對',
    );
    expect(shortLoop.hasLoop, isTrue);
    expect(shortLoop.cleanedText, '尺寸算好了，對');

    final phraseLoop = GemmaLiteRtEngine.detectAndTrimRepetitionLoop(
      '好的，這支要切300mm。這支要切300mm。這支要切300mm。這支要切300mm。',
    );
    expect(phraseLoop.hasLoop, isTrue);
    expect(phraseLoop.cleanedText, '好的，這支要切300mm。');

    final normalText = GemmaLiteRtEngine.detectAndTrimRepetitionLoop(
      '098M 共 12 支 × 1500mm，含 1.09 損耗約 8.83 kg。\n---\n記得扣 3.5mm 鋸路。',
    );
    expect(normalText.hasLoop, isFalse);

    // 3. RoutineScheduler Next-3 trigger preview (daily, weekly, cron)
    final baseTime = DateTime(2026, 11, 18, 9, 0); // 2026-11-18 is Wednesday (weekday=3)
    const dailyRoutine = RoutineRecord(
      id: 'r_daily',
      title: '早班對料',
      body: '',
      mode: 'daily',
      timeSpec: '07:30',
      weekdaysCsv: '1,2,3,4,5,6,7',
      enabled: true,
      updatedAt: 0,
    );
    final dailyNext3 = RoutineScheduler.computeNextOccurrences(dailyRoutine, from: baseTime, count: 3);
    expect(dailyNext3.length, 3);
    expect(dailyNext3[0], DateTime(2026, 11, 19, 7, 30));
    expect(dailyNext3[2], DateTime(2026, 11, 21, 7, 30));

    const cronRoutine = RoutineRecord(
      id: 'r_cron',
      title: '週一到週六追蹤',
      body: '',
      mode: 'cron',
      timeSpec: '30 7 * * 1-6',
      weekdaysCsv: '',
      enabled: true,
      updatedAt: 0,
    );
    final cronNext3 = RoutineScheduler.computeNextOccurrences(cronRoutine, from: baseTime, count: 3);
    expect(cronNext3.length, 3);
    expect(cronNext3[0], DateTime(2026, 11, 19, 7, 30)); // Thu
    expect(cronNext3[1], DateTime(2026, 11, 20, 7, 30)); // Fri
    expect(cronNext3[2], DateTime(2026, 11, 21, 7, 30)); // Sat (skips Sun if next!)

    // 4. Operator 🚩 Flags & idle self-reflection into MEMORY.md
    final badMsg = await db.insertMessage(
      roomId: 'main',
      role: 'model',
      content: '093Z 直接抓 6000mm 下料就好',
    );
    await db.flagMessage(
      messageId: badMsg.id,
      roomId: 'main',
      reason: '算料/鋸路錯',
      userNote: '093Z 要強制抓 6400mm 定尺',
      flaggedContent: badMsg.content,
    );
    expect((await db.getRoomFlaggedMessageIds('main')).contains(badMsg.id), isTrue);
    expect((await db.getOperatorFlags(onlyUnreviewed: true)).length, 1);

    final engine = GemmaLiteRtEngine(db: db, toolRegistry: registry);
    final reflectOut = await engine.runIdleFlaggedReflection(forceManual: true);
    expect(reflectOut.reviewedCount, 1);
    expect(reflectOut.lesson, contains('093Z'));
    expect(await db.getOperatorFlags(onlyUnreviewed: true), isEmpty);
    expect((await db.getAllTraits())['MEMORY.md'], contains('093Z'));

    // 5. Manual /compact force compression
    for (var i = 0; i < 4; i++) {
      await db.insertMessage(roomId: 'main', role: 'user', content: '補充尺寸 第$i批 ${1200 + i * 50}mm');
      await db.insertMessage(roomId: 'main', role: 'model', content: '收到 第$i批已記');
    }
    final compactRes = await engine.forceCompactRoom('main');
    expect(compactRes.compacted, isTrue);
    expect(compactRes.summary, isNotEmpty);
    expect((await db.getRoom('main'))?.rollingSummary, isNotEmpty);
  });

  test('WheelActionRegistry enforces 6 symmetrical unique slots & swap-on-collide', () async {
    expect(WheelActionRegistry.defaultSlots.length, 6);
    expect(WheelActionRegistry.defaultSlots.toSet().length, 6);
    expect(WheelActionRegistry.allActions.length, 14);

    // Sanitizes unknown IDs, duplicates, short lists, and long lists cleanly back to 6 unique IDs.
    final sanitized = WheelActionRegistry.sanitizeSlots([
      'bogus_id',
      'weather_douliu',
      'weather_douliu',
      'torch',
    ]);
    expect(sanitized.length, 6);
    expect(sanitized.toSet().length, 6);
    expect(sanitized[0], 'weather_douliu');
    expect(sanitized[1], 'torch');

    final truncated = WheelActionRegistry.sanitizeSlots([
      for (final a in WheelActionRegistry.allActions) a.id,
    ]);
    expect(truncated.length, 6);
    expect(truncated.toSet().length, 6);

    // Assigning an unequipped bench action replaces target slot cleanly.
    final assigned = WheelActionRegistry.swapOrAssignSlot(
      WheelActionRegistry.defaultSlots,
      5,
      'next_routine',
    );
    expect(assigned[5], 'next_routine');
    expect(assigned.length, 6);
    expect(assigned.toSet().length, 6);

    // Assigning an already-equipped action swaps positions without duplicating.
    final swapped = WheelActionRegistry.swapOrAssignSlot(assigned, 0, 'location_share');
    expect(swapped[0], 'location_share');
    expect(swapped[1], 'torch');
    expect(swapped.toSet().length, 6);

    // Round-trip SharedPreferences persistence
    SharedPreferences.setMockInitialValues({});
    final initial = await FloatingOverlayPreferences.getWheelSlots();
    expect(initial, WheelActionRegistry.defaultSlots);

    final saved = await FloatingOverlayPreferences.setWheelSlots(swapped);
    expect(saved, swapped);
    final loaded = await FloatingOverlayPreferences.getWheelSlots();
    expect(loaded, swapped);
  });
}

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this._handler);
  final Future<http.Response> Function(http.Request request) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    final res = await _handler(req);
    return http.StreamedResponse(
      Stream.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
    );
  }
}
