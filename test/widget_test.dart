import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xiaoliu/core/async_mutex.dart';
import 'package:xiaoliu/core/image_compressor.dart';
import 'package:xiaoliu/core/token_estimator.dart';
import 'package:xiaoliu/data/database_helper.dart';
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
  });
}
