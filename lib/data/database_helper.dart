import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  /// Creates an isolated instance for unit tests.
  DatabaseHelper.forTesting({this.databaseFactoryOverride, this.dbPathOverride});

  DatabaseFactory? databaseFactoryOverride;
  String? dbPathOverride;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<Database> _initDb() async {
    final factory = databaseFactoryOverride ?? databaseFactory;
    final dbPath = dbPathOverride ?? p.join(await getDatabasesPath(), 'xiaoliu.db');

    return factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: _onCreate,
      ),
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE traits (
        name TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE rooms (
        room_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL DEFAULT '',
        color_hex TEXT NOT NULL,
        accessory TEXT DEFAULT 'helmet',
        avatar_state TEXT DEFAULT 'idle',
        rolling_summary TEXT DEFAULT '',
        summarized_until_msg_id INTEGER DEFAULT 0,
        updated_at INTEGER NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE data (
        key TEXT PRIMARY KEY,
        room_id TEXT NOT NULL,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        image_path TEXT,
        tool_pill TEXT,
        card_json TEXT,
        is_starred INTEGER DEFAULT 0,
        archived_color_hex TEXT,
        archived_title TEXT,
        created_at INTEGER NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE hooks (
        name TEXT PRIMARY KEY,
        description TEXT,
        params_json TEXT,
        body TEXT,
        updated_at INTEGER NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE profiles (
        code TEXT PRIMARY KEY,
        weight_per_m REAL NOT NULL,
        stock_rule TEXT NOT NULL,
        extrudable INTEGER NOT NULL,
        note TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE machine_tuning (
        id TEXT PRIMARY KEY,
        keywords TEXT NOT NULL,
        title TEXT NOT NULL,
        formula TEXT NOT NULL,
        note TEXT
      )
    ''');

    await db.execute('CREATE INDEX idx_messages_room ON messages(room_id, is_deleted, id)');
    await db.execute('CREATE INDEX idx_data_room ON data(room_id, is_deleted)');
  }

  Future<String> _loadAssetWithFallback(String localPath, String fallbackPath) async {
    try {
      return await rootBundle.loadString(localPath);
    } catch (_) {
      return await rootBundle.loadString(fallbackPath);
    }
  }

  Future<void> seedIfNeeded() async {
    final personaRaw = await _loadAssetWithFallback(
      'assets/seeds/persona_seed.local.json',
      'assets/seeds/persona_seed.example.json',
    );
    final profilesRaw = await _loadAssetWithFallback(
      'assets/seeds/profiles.local.json',
      'assets/seeds/profiles.example.json',
    );
    final tuningRaw = await _loadAssetWithFallback(
      'assets/seeds/machine_tuning.local.json',
      'assets/seeds/machine_tuning.example.json',
    );

    await seedFromStrings(
      personaJson: personaRaw,
      profilesJson: profilesRaw,
      tuningJson: tuningRaw,
    );
  }

  Future<void> seedFromStrings({
    required String personaJson,
    required String profilesJson,
    required String tuningJson,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. Seed traits if empty, or seamlessly upgrade legacy 小六 persona to KODARI
    final personaMap = jsonDecode(personaJson) as Map<String, dynamic>;
    final traitCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM traits WHERE is_deleted = 0'),
        ) ??
        0;
    if (traitCount == 0) {
      final batch = db.batch();
      for (final entry in personaMap.entries) {
        batch.insert(
          'traits',
          {
            'name': entry.key,
            'content': entry.value.toString(),
            'updated_at': now,
            'sync_status': 'pending',
            'is_deleted': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    } else {
      final existingSoulRows = await db.query(
        'traits',
        where: "name = 'SOUL.md' AND is_deleted = 0",
        limit: 1,
      );
      if (existingSoulRows.isNotEmpty) {
        final soulContent = existingSoulRows.first['content'] as String? ?? '';
        if (soulContent.contains('小六') || soulContent.contains('第六席')) {
          for (final key in ['SOUL.md', 'VOICE.md']) {
            if (personaMap.containsKey(key)) {
              await db.update(
                'traits',
                {
                  'content': personaMap[key].toString(),
                  'updated_at': now,
                  'sync_status': 'pending',
                },
                where: 'name = ?',
                whereArgs: [key],
              );
            }
          }
          await db.update(
            'rooms',
            {
              'title': 'KODARI 主房間',
              'subtitle': 'HAKO 大廳 • 一秒開聊／隨手記',
              'updated_at': now,
              'sync_status': 'pending',
            },
            where: "room_id = 'main' AND title = '小六主房間'",
          );
        }
      }
    }

    // Ensure MEMORY.md exists for autonomous background user-fact distillation
    final existingMemory = await db.query(
      'traits',
      where: "name = 'MEMORY.md'",
      limit: 1,
    );
    if (existingMemory.isEmpty) {
      await db.insert('traits', {
        'name': 'MEMORY.md',
        'content': '# 長期自主蒸餾記憶（背景自動整理，上限 20 條）\n',
        'updated_at': now,
        'sync_status': 'pending',
        'is_deleted': 0,
      });
    }

    // 2. Seed profiles (refreshable static lookup table)
    final profileCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM profiles'),
        ) ??
        0;
    if (profileCount == 0) {
      final profilesList = jsonDecode(profilesJson) as List<dynamic>;
      final batch = db.batch();
      for (final item in profilesList) {
        final m = item as Map<String, dynamic>;
        batch.insert(
          'profiles',
          {
            'code': m['code'],
            'weight_per_m': (m['weight_per_m'] as num).toDouble(),
            'stock_rule': m['stock_rule'] ?? '6000mm',
            'extrudable': m['extrudable'] ?? 0,
            'note': m['note'] ?? '',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }

    // 3. Seed machine tuning table
    final tuningCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM machine_tuning'),
        ) ??
        0;
    if (tuningCount == 0) {
      final tuningList = jsonDecode(tuningJson) as List<dynamic>;
      final batch = db.batch();
      for (final item in tuningList) {
        final m = item as Map<String, dynamic>;
        batch.insert(
          'machine_tuning',
          {
            'id': m['id'],
            'keywords': m['keywords'] ?? '',
            'title': m['title'] ?? '',
            'formula': m['formula'] ?? '',
            'note': m['note'] ?? '',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }

    // 4. Seed default rooms if empty
    final roomCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM rooms WHERE is_deleted = 0'),
        ) ??
        0;
    if (roomCount == 0) {
      final defaultRooms = [
        (
          roomId: 'main',
          title: 'KODARI 主房間',
          subtitle: 'HAKO 大廳 • 一秒開聊／隨手記',
          colorHex: '#3A4150',
          accessory: 'main',
          state: 'idle',
          todos: '',
          greeting: '我醒著。今天有啥急事要記，還是先拍張現場圖給我看看？',
        ),
        (
          roomId: 'para:projects:demo_project_a',
          title: '示範專案 A (現場進度)',
          subtitle: 'para:projects:demo_project_a',
          colorHex: '#F59E0B',
          accessory: 'helmet',
          state: 'working',
          todos: '- [x] 前置規格與尺寸確認\n- [x] 現場加工圖面核對\n- [ ] 明日 08:00 出車裝車',
          greeting: '示範專案 A 房間開好了。進度卡在上面，這案的排程或現場問題直接丟進來記。',
        ),
        (
          roomId: 'para:projects:demo_project_b',
          title: '示範專案 B (材料估算)',
          subtitle: 'para:projects:demo_project_b',
          colorHex: '#3B82F6',
          accessory: 'helmet',
          state: 'idle',
          todos: '- [x] 標準定尺下料確認\n- [ ] 檢查批號總重是否達門檻',
          greeting: '示範專案 B 就位。需要算材料重量或記加工進度跟我講一聲。',
        ),
        (
          roomId: 'para:areas:daily_maintenance',
          title: '日常維護 & 設備參數',
          subtitle: 'para:areas:daily_maintenance',
          colorHex: '#A16207',
          accessory: 'wrench',
          state: 'idle',
          todos: '- [ ] 設備耗材與損耗例行檢查',
          greeting: '設備參數、保養維修或日常雜事都丟這間。',
        ),
        (
          roomId: 'para:archives:demo_archived',
          title: '示範封存專案（已結案）',
          subtitle: 'para:archives:demo_archived',
          colorHex: '#E5E7EB',
          accessory: 'sleep',
          state: 'done',
          todos: '- [x] 現場安裝驗收完成\n- [x] 餘料入庫登記',
          greeting: '這案已結案收工了，有要翻舊紀錄再叫我。',
        ),
      ];

      for (final r in defaultRooms) {
        await db.insert('rooms', {
          'room_id': r.roomId,
          'title': r.title,
          'subtitle': r.subtitle,
          'color_hex': r.colorHex,
          'accessory': r.accessory,
          'avatar_state': r.state,
          'rolling_summary': '',
          'summarized_until_msg_id': 0,
          'updated_at': now,
          'sync_status': 'pending',
          'is_deleted': 0,
        });
        if (r.todos.isNotEmpty) {
          await db.insert('data', {
            'key': r.roomId,
            'room_id': r.roomId,
            'value': r.todos,
            'updated_at': now,
            'sync_status': 'pending',
            'is_deleted': 0,
          });
        }
        await db.insert('messages', {
          'room_id': r.roomId,
          'role': 'model',
          'content': r.greeting,
          'created_at': now,
          'sync_status': 'pending',
          'is_deleted': 0,
        });
      }
    }
  }

  // ---------------- Traits ----------------

  Future<Map<String, String>> getAllTraits() async {
    final db = await database;
    final rows = await db.query(
      'traits',
      where: 'is_deleted = 0',
      orderBy: 'name ASC',
    );
    return {
      for (final row in rows) row['name'] as String: row['content'] as String,
    };
  }

  Future<void> upsertTrait(String name, String content) async {
    final db = await database;
    await db.insert(
      'traits',
      {
        'name': name,
        'content': content,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'sync_status': 'pending',
        'is_deleted': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------- Rooms ----------------

  Future<List<RoomRecord>> getRooms() async {
    final db = await database;
    final rows = await db.query(
      'rooms',
      where: 'is_deleted = 0',
      orderBy: "CASE WHEN room_id = 'main' THEN 0 WHEN room_id LIKE 'para:archives:%' THEN 2 ELSE 1 END, updated_at DESC",
    );
    return rows.map(RoomRecord.fromMap).toList();
  }

  Future<RoomRecord?> getRoom(String roomId) async {
    final db = await database;
    final rows = await db.query(
      'rooms',
      where: 'room_id = ? AND is_deleted = 0',
      whereArgs: [roomId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RoomRecord.fromMap(rows.first);
  }

  Future<RoomRecord> createRoom({
    required String title,
    String colorHex = '#F59E0B',
    String accessory = 'helmet',
    String categoryPrefix = 'para:projects:',
  }) async {
    final db = await database;
    final cleanName = title.trim().replaceAll(RegExp(r'\s+'), '_');
    final roomId = cleanName.startsWith('para:') ? cleanName : '$categoryPrefix$cleanName';
    final now = DateTime.now().millisecondsSinceEpoch;

    final existing = await getRoom(roomId);
    if (existing != null) return existing;

    final record = {
      'room_id': roomId,
      'title': title.trim(),
      'subtitle': roomId,
      'color_hex': colorHex,
      'accessory': accessory,
      'avatar_state': 'idle',
      'rolling_summary': '',
      'summarized_until_msg_id': 0,
      'updated_at': now,
      'sync_status': 'pending',
      'is_deleted': 0,
    };
    await db.insert('rooms', record, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('messages', {
      'room_id': roomId,
      'role': 'model',
      'content': '「${title.trim()}」房間開張了，這案的圖面、尺寸或出車提醒直接丟這間。',
      'created_at': now,
      'sync_status': 'pending',
      'is_deleted': 0,
    });
    return RoomRecord.fromMap(record);
  }

  Future<void> updateRoomAvatarState(String roomId, SpiritState state) async {
    final db = await database;
    await db.update(
      'rooms',
      {
        'avatar_state': state.code,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'sync_status': 'pending',
      },
      where: 'room_id = ?',
      whereArgs: [roomId],
    );
  }

  Future<void> archiveRoom(String roomId) async {
    if (roomId == 'main') return;
    final db = await database;
    final room = await getRoom(roomId);
    if (room == null) return;
    final newTitle = room.title.contains('（已封存）') ? room.title : '${room.title}（已封存）';
    await db.update(
      'rooms',
      {
        'title': newTitle,
        'color_hex': '#E5E7EB',
        'accessory': 'sleep',
        'avatar_state': SpiritState.done.code,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'sync_status': 'pending',
      },
      where: 'room_id = ?',
      whereArgs: [roomId],
    );
  }

  /// Soft-deletes a room and its data/messages (preserving tombstones for P2 sync).
  Future<void> deleteRoom(String roomId) async {
    if (roomId == 'main') return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    batch.update(
      'rooms',
      {'is_deleted': 1, 'updated_at': now, 'sync_status': 'pending'},
      where: 'room_id = ?',
      whereArgs: [roomId],
    );
    batch.update(
      'data',
      {'is_deleted': 1, 'updated_at': now, 'sync_status': 'pending'},
      where: 'room_id = ?',
      whereArgs: [roomId],
    );
    batch.update(
      'messages',
      {'is_deleted': 1, 'sync_status': 'pending'},
      where: 'room_id = ?',
      whereArgs: [roomId],
    );
    await batch.commit(noResult: true);
  }

  Future<void> updateRoomSummary({
    required String roomId,
    required String summary,
    required int untilMsgId,
  }) async {
    final db = await database;
    await db.update(
      'rooms',
      {
        'rolling_summary': summary,
        'summarized_until_msg_id': untilMsgId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'sync_status': 'pending',
      },
      where: 'room_id = ?',
      whereArgs: [roomId],
    );
  }

  // ---------------- Data & Anti-Wipe Todo Engine ----------------

  String dataKeyForRoom(String roomId) {
    return roomId == 'main' ? 'para:areas:大廳雜記' : roomId;
  }

  Future<String> getDataValue(String key) async {
    final db = await database;
    final rows = await db.query(
      'data',
      where: 'key = ? AND is_deleted = 0',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    return rows.first['value'] as String;
  }

  Future<List<Map<String, Object?>>> queryDataKeys({
    String? prefix,
    String? roomId,
    String? keyword,
  }) async {
    final db = await database;
    final whereParts = <String>['is_deleted = 0'];
    final args = <Object?>[];
    if (roomId != null && roomId.isNotEmpty) {
      whereParts.add('room_id = ?');
      args.add(roomId);
    }
    if (prefix != null && prefix.isNotEmpty) {
      whereParts.add('key LIKE ?');
      args.add('$prefix%');
    }
    if (keyword != null && keyword.isNotEmpty) {
      whereParts.add('(key LIKE ? OR value LIKE ?)');
      args.addAll(['%$keyword%', '%$keyword%']);
    }
    return db.query(
      'data',
      columns: ['key', 'room_id', 'updated_at'],
      where: whereParts.join(' AND '),
      whereArgs: args,
      orderBy: 'updated_at DESC',
      limit: 25,
    );
  }

  /// Safe append / toggle todo writer: NEVER overwrites existing checklist items.
  Future<({String key, String updatedValue, bool toggled, int total, int done})> upsertTodoItem({
    required String roomId,
    required String itemText,
    String? key,
    String? status,
  }) async {
    final db = await database;
    final resolvedKey = (key != null && key.trim().isNotEmpty)
        ? key.trim()
        : dataKeyForRoom(roomId);
    final existing = await getDataValue(resolvedKey);
    final lines = existing.trim().isEmpty
        ? <String>[]
        : existing.split('\n').map((e) => e.trimRight()).where((e) => e.isNotEmpty).toList();

    final cleanItem = itemText
        .replaceFirst(RegExp(r'^-\s*\[[ xXoO]\]\s*'), '')
        .trim();

    var didToggle = false;
    final normalizedStatus = status?.toLowerCase().trim() ?? 'pending';

    if (normalizedStatus == 'done' || normalizedStatus == 'toggle') {
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].toLowerCase().contains(cleanItem.toLowerCase())) {
          final stripped = lines[i].replaceFirst(RegExp(r'^-\s*\[[ xXoO]\]\s*'), '');
          final isCurrentlyDone = RegExp(r'^-\s*\[[xXoO]\]').hasMatch(lines[i]);
          final targetDone = normalizedStatus == 'done' ? true : !isCurrentlyDone;
          lines[i] = targetDone ? '- [x] $stripped' : '- [ ] $stripped';
          didToggle = true;
          break;
        }
      }
      if (!didToggle && cleanItem.isNotEmpty) {
        lines.add(normalizedStatus == 'done' ? '- [x] $cleanItem' : '- [ ] $cleanItem');
      }
    } else if (cleanItem.isNotEmpty) {
      final alreadyExists = lines.any(
        (l) => l.replaceFirst(RegExp(r'^-\s*\[[ xXoO]\]\s*'), '').trim() == cleanItem,
      );
      if (!alreadyExists) {
        lines.add('- [ ] $cleanItem');
      }
    }

    final newValue = lines.join('\n');
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'data',
      {
        'key': resolvedKey,
        'room_id': roomId,
        'value': newValue,
        'updated_at': now,
        'sync_status': 'pending',
        'is_deleted': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final parsed = parseTodos(newValue);
    final doneCount = parsed.where((t) => t.done).length;
    return (
      key: resolvedKey,
      updatedValue: newValue,
      toggled: didToggle,
      total: parsed.length,
      done: doneCount,
    );
  }

  Future<List<TodoItem>> getRoomTodos(String roomId) async {
    final key = dataKeyForRoom(roomId);
    final raw = await getDataValue(key);
    return parseTodos(raw);
  }

  Future<void> toggleTodoAtIndex(String roomId, int lineIndex) async {
    final db = await database;
    final key = dataKeyForRoom(roomId);
    final raw = await getDataValue(key);
    if (raw.trim().isEmpty) return;

    final lines = raw.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return;
    final line = lines[lineIndex];
    if (line.startsWith('- [x]') || line.startsWith('- [X]') || line.startsWith('- [O]')) {
      lines[lineIndex] = line.replaceFirst(RegExp(r'^-\s*\[[xXO]\]'), '- [ ]');
    } else if (line.startsWith('- [ ]')) {
      lines[lineIndex] = line.replaceFirst('- [ ]', '- [x]');
    } else {
      lines[lineIndex] = '- [x] $line';
    }

    await db.insert(
      'data',
      {
        'key': key,
        'room_id': roomId,
        'value': lines.join('\n'),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'sync_status': 'pending',
        'is_deleted': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static List<TodoItem> parseTodos(String markdown) {
    if (markdown.trim().isEmpty) return const [];
    final lines = markdown.split('\n');
    final items = <TodoItem>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (RegExp(r'^-\s*\[[xXO]\]').hasMatch(line)) {
        items.add(TodoItem(
          lineIndex: i,
          text: line.replaceFirst(RegExp(r'^-\s*\[[xXO]\]\s*'), ''),
          done: true,
        ));
      } else if (line.startsWith('- [ ]')) {
        items.add(TodoItem(
          lineIndex: i,
          text: line.replaceFirst(RegExp(r'^-\s*\[\s\]\s*'), ''),
          done: false,
        ));
      } else {
        items.add(TodoItem(lineIndex: i, text: line, done: false));
      }
    }
    return items;
  }

  static double calculateProgress(List<TodoItem> todos) {
    if (todos.isEmpty) return 0.0;
    final done = todos.where((t) => t.done).length;
    return done / todos.length;
  }

  // ---------------- Messages ----------------

  Future<List<ChatMessageRecord>> getMessages(String roomId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'room_id = ? AND is_deleted = 0',
      whereArgs: [roomId],
      orderBy: 'id ASC',
    );
    return rows.map(ChatMessageRecord.fromMap).toList();
  }

  Future<ChatMessageRecord> insertMessage({
    required String roomId,
    required String role,
    required String content,
    String? imagePath,
    String? toolPill,
    String? cardJson,
    bool isStarred = false,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('messages', {
      'room_id': roomId,
      'role': role,
      'content': content,
      'image_path': imagePath,
      'tool_pill': toolPill,
      'card_json': cardJson,
      'is_starred': isStarred ? 1 : 0,
      'created_at': now,
      'sync_status': 'pending',
      'is_deleted': 0,
    });
    await db.update(
      'rooms',
      {'updated_at': now, 'sync_status': 'pending'},
      where: 'room_id = ?',
      whereArgs: [roomId],
    );
    return ChatMessageRecord(
      id: id,
      roomId: roomId,
      role: role,
      content: content,
      imagePath: imagePath,
      toolPill: toolPill,
      cardJson: cardJson,
      isStarred: isStarred,
      createdAt: now,
    );
  }

  Future<void> setMessageStarred(int messageId, bool starred) async {
    final db = await database;
    await db.update(
      'messages',
      {
        'is_starred': starred ? 1 : 0,
        'sync_status': 'pending',
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Copies a user message (and optional photo) to targetRoomId, adds as todo,
  /// and tints the original bubble in its source room with the target room's color.
  Future<void> archiveUserMessageToRoom({
    required int messageId,
    required String targetRoomId,
    bool addAsTodo = true,
  }) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'id = ? AND is_deleted = 0',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final srcMsg = ChatMessageRecord.fromMap(rows.first);
    final srcRoom = await getRoom(srcMsg.roomId);
    final targetRoom = await getRoom(targetRoomId);
    if (targetRoom == null) return;

    await db.update(
      'messages',
      {
        'archived_color_hex': targetRoom.colorHex,
        'archived_title': targetRoom.title,
        'sync_status': 'pending',
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );

    await insertMessage(
      roomId: targetRoomId,
      role: 'user',
      content: srcMsg.content,
      imagePath: srcMsg.imagePath,
      toolPill: '📂 從「${srcRoom?.title ?? '其他房間'}」轉存',
      isStarred: srcMsg.isStarred,
    );

    if (addAsTodo && srcMsg.content.trim().isNotEmpty) {
      await upsertTodoItem(roomId: targetRoomId, itemText: srcMsg.content.trim());
    }
  }

  // ---------------- Global Pending Memo Inbox ----------------

  Future<GlobalPendingMemo> getGlobalPendingMemo() async {
    final db = await database;
    final rooms = await getRooms();
    final roomMap = {for (final r in rooms) r.roomId: r};

    final starredRows = await db.query(
      'messages',
      where: 'is_starred = 1 AND is_deleted = 0',
      orderBy: 'id DESC',
    );
    final starred = starredRows.map((row) {
      final msg = ChatMessageRecord.fromMap(row);
      return (message: msg, room: roomMap[msg.roomId]);
    }).toList();

    final todoGroups = <RoomTodoGroup>[];
    for (final room in rooms) {
      final todos = await getRoomTodos(room.roomId);
      final pending = todos.where((t) => !t.done).toList();
      if (pending.isNotEmpty) {
        todoGroups.add(RoomTodoGroup(room: room, todos: pending));
      }
    }

    return GlobalPendingMemo(
      starredMessages: starred,
      pendingTodoGroups: todoGroups,
    );
  }

  /// Cross-room memory search (intended for the 'main' hub room).
  Future<List<({String roomId, String roomTitle, String source, String snippet})>>
      searchGlobalMemory(String query) async {
    final db = await database;
    final rooms = await getRooms();
    final roomMap = {for (final r in rooms) r.roomId: r};

    const stopWords = {
      '我們',
      '聊怎樣了',
      '聊了什麼',
      '怎麼樣',
      '什麼',
      '在哪',
      '請問',
      '記得',
      '一下',
      '最近',
    };
    final tokens = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'[\s,，。？?！!]+'))
        .map((t) {
          var clean = t;
          if (clean.length > 2 && clean.endsWith('房間')) {
            clean = clean.substring(0, clean.length - 2);
          } else if (clean.length > 1 && clean.endsWith('房')) {
            clean = clean.substring(0, clean.length - 1);
          }
          return clean;
        })
        .where((t) => t.isNotEmpty && !stopWords.contains(t))
        .toList();

    final strictHits =
        <({String roomId, String roomTitle, String source, String snippet})>[];
    final looseHits =
        <({String roomId, String roomTitle, String source, String snippet})>[];

    void addHit(
      List<({String roomId, String roomTitle, String source, String snippet})> target, {
      required String roomId,
      required String roomTitle,
      required String source,
      required String snippet,
    }) {
      if (target.length >= 8) return;
      if (target.any((h) => h.roomId == roomId && h.snippet == snippet)) return;
      target.add((
        roomId: roomId,
        roomTitle: roomTitle,
        source: source,
        snippet: snippet,
      ));
    }

    // 1. Check matching room summaries
    if (tokens.isNotEmpty) {
      for (final r in rooms) {
        if (r.rollingSummary.trim().isEmpty) continue;
        final hay = '${r.title} ${r.rollingSummary}'.toLowerCase();
        if (tokens.every(hay.contains)) {
          addHit(
            strictHits,
            roomId: r.roomId,
            roomTitle: r.title,
            source: '摘要',
            snippet: r.rollingSummary.trim(),
          );
        } else if (tokens.any(hay.contains)) {
          addHit(
            looseHits,
            roomId: r.roomId,
            roomTitle: r.title,
            source: '摘要',
            snippet: r.rollingSummary.trim(),
          );
        }
      }
    }

    // 2. Search room todos & notes in `data`
    final dataRows = await db.query('data', where: 'is_deleted = 0');
    for (final row in dataRows) {
      final roomId = (row['room_id'] ?? '').toString();
      final roomTitle = roomMap[roomId]?.title ?? roomId;
      final value = (row['value'] ?? '').toString();
      for (final rawLine in value.split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        final hay = '$roomTitle $line'.toLowerCase();
        if (tokens.isEmpty) {
          if (!line.startsWith('- [x]') && !line.startsWith('- [O]')) {
            addHit(
              strictHits,
              roomId: roomId,
              roomTitle: roomTitle,
              source: '待辦',
              snippet: line,
            );
          }
        } else if (tokens.every(hay.contains)) {
          addHit(
            strictHits,
            roomId: roomId,
            roomTitle: roomTitle,
            source: '待辦',
            snippet: line,
          );
        } else if (tokens.any(hay.contains)) {
          addHit(
            looseHits,
            roomId: roomId,
            roomTitle: roomTitle,
            source: '待辦',
            snippet: line,
          );
        }
      }
    }

    // 3. Search chat history in `messages` (newest first, excluding search commands themselves)
    if (tokens.isNotEmpty) {
      final msgRows = await db.query(
        'messages',
        where: "is_deleted = 0 AND role != 'divider'",
        orderBy: 'created_at DESC',
        limit: 300,
      );
      for (final row in msgRows) {
        final roomId = (row['room_id'] ?? '').toString();
        final roomTitle = roomMap[roomId]?.title ?? roomId;
        final role = (row['role'] ?? '').toString();
        final content = (row['content'] ?? '').toString().trim();
        if (content.isEmpty) continue;
        if (content.startsWith('@搜記憶') || content.startsWith('@查記憶')) {
          continue;
        }
        final hay = '$roomTitle $content'.toLowerCase();
        if (tokens.every(hay.contains)) {
          addHit(
            strictHits,
            roomId: roomId,
            roomTitle: roomTitle,
            source: role == 'user' ? '你說過' : 'KODARI',
            snippet: content,
          );
        } else if (tokens.any(hay.contains)) {
          addHit(
            looseHits,
            roomId: roomId,
            roomTitle: roomTitle,
            source: role == 'user' ? '你說過' : 'KODARI',
            snippet: content,
          );
        }
      }
    }

    return strictHits.isNotEmpty ? strictHits : looseHits;
  }

  /// Appends a newly distilled long-term user fact into MEMORY.md (deduped, max 20 entries).
  Future<bool> appendDistilledMemory(String rawFact) async {
    var clean = rawFact
        .replaceAll(RegExp(r'^[-*•\s]+'), '')
        .replaceAll('\n', ' ')
        .trim();
    if (clean.isEmpty) return false;
    final upper = clean.toUpperCase();
    if (upper == 'NONE' || upper.contains('NONE') || clean == '無' || clean == '（無）') {
      return false;
    }
    if (clean.length > 60) {
      clean = '${clean.substring(0, 60)}...';
    }

    final traits = await getAllTraits();
    final existing = traits['MEMORY.md'] ?? '# 長期自主蒸餾記憶（背景自動整理，上限 20 條）\n';
    final items = existing
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('- '))
        .toList();

    final lowerNew = clean.toLowerCase();
    if (items.any((l) => l.substring(2).trim().toLowerCase() == lowerNew || l.toLowerCase().contains(lowerNew))) {
      return false;
    }

    items.add('- $clean');
    final capped = items.length > 20 ? items.sublist(items.length - 20) : items;
    final nextContent = '# 長期自主蒸餾記憶（背景自動整理，上限 20 條）\n${capped.join('\n')}\n';
    await upsertTrait('MEMORY.md', nextContent);
    return true;
  }

  // ---------------- Offline Engineering Lookup Tables ----------------

  Future<List<ProfileRecord>> lookupProfiles(String query) async {
    final db = await database;
    final q = query.trim();
    if (q.isEmpty) {
      final rows = await db.query('profiles', orderBy: 'code ASC', limit: 30);
      return rows.map(ProfileRecord.fromMap).toList();
    }

    final exact = await db.query(
      'profiles',
      where: 'UPPER(code) = UPPER(?)',
      whereArgs: [q],
      limit: 1,
    );
    if (exact.isNotEmpty) {
      return exact.map(ProfileRecord.fromMap).toList();
    }

    final fuzzy = await db.query(
      'profiles',
      where: 'UPPER(code) LIKE UPPER(?) OR note LIKE ?',
      whereArgs: ['%$q%', '%$q%'],
      orderBy: 'code ASC',
      limit: 20,
    );
    return fuzzy.map(ProfileRecord.fromMap).toList();
  }

  Future<List<MachineTuningRecord>> lookupMachineTuning(String query) async {
    final db = await database;
    final q = query.trim();
    if (q.isEmpty) {
      final rows = await db.query('machine_tuning', orderBy: 'id ASC');
      return rows.map(MachineTuningRecord.fromMap).toList();
    }

    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final rows = await db.query('machine_tuning');
    final all = rows.map(MachineTuningRecord.fromMap).toList();
    return all.where((r) {
      final haystack = '${r.id} ${r.keywords} ${r.title} ${r.formula} ${r.note}'.toLowerCase();
      return tokens.every((t) => haystack.contains(t.toLowerCase()));
    }).toList();
  }

  // ---------------- Phase 2 Cloud Sync Engine (LWW + Tombstones) ----------------

  Future<int> getPendingSyncCount() async {
    final db = await database;
    var total = 0;
    for (final table in const ['traits', 'rooms', 'data', 'messages', 'hooks']) {
      final count = Sqflite.firstIntValue(
            await db.rawQuery("SELECT COUNT(*) FROM $table WHERE sync_status = 'pending'"),
          ) ??
          0;
      total += count;
    }
    return total;
  }

  Future<Map<String, dynamic>> exportSyncPayload({bool onlyPending = false}) async {
    final db = await database;
    final where = onlyPending ? "sync_status = 'pending'" : null;
    final traits = await db.query('traits', where: where);
    final rooms = await db.query('rooms', where: where);
    final data = await db.query('data', where: where);
    final messages = await db.query('messages', where: where);
    final hooks = await db.query('hooks', where: where);

    return {
      'app': 'HAKO',
      'agent': 'KODARI',
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'traits': traits,
      'rooms': rooms,
      'data': data,
      'messages': messages,
      'hooks': hooks,
    };
  }

  Future<void> markAllSynced(int syncTimestampMs) async {
    final db = await database;
    final batch = db.batch();
    for (final table in const ['traits', 'rooms', 'data', 'hooks']) {
      batch.update(
        table,
        {'sync_status': 'synced'},
        where: "sync_status = 'pending' AND updated_at <= ?",
        whereArgs: [syncTimestampMs],
      );
    }
    batch.update(
      'messages',
      {'sync_status': 'synced'},
      where: "sync_status = 'pending' AND created_at <= ?",
      whereArgs: [syncTimestampMs],
    );
    await batch.commit(noResult: true);
  }

  Future<({int upserted, int deleted})> mergeRemoteSyncPayload(
    Map<String, dynamic> payload,
  ) async {
    final db = await database;
    var upserted = 0;
    var deleted = 0;

    Future<void> mergeKeyedTable({
      required String table,
      required String pkColumn,
      required List<dynamic> rows,
      required List<String> columns,
    }) async {
      for (final raw in rows) {
        if (raw is! Map) continue;
        final row = Map<String, Object?>.from(raw);
        final pkValue = row[pkColumn];
        if (pkValue == null) continue;
        final remoteUpdated = (row['updated_at'] as num?)?.toInt() ?? 0;
        final remoteDeleted = (row['is_deleted'] as num?)?.toInt() ?? 0;

        final existing = await db.query(
          table,
          columns: ['updated_at'],
          where: '$pkColumn = ?',
          whereArgs: [pkValue],
          limit: 1,
        );

        final localUpdated = existing.isEmpty
            ? -1
            : ((existing.first['updated_at'] as num?)?.toInt() ?? 0);

        if (existing.isEmpty || remoteUpdated > localUpdated) {
          final filtered = <String, Object?>{
            for (final col in columns)
              if (row.containsKey(col)) col: row[col],
            'sync_status': 'synced',
          };
          await db.insert(
            table,
            filtered,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          if (remoteDeleted == 1) {
            deleted++;
          } else {
            upserted++;
          }
        }
      }
    }

    await mergeKeyedTable(
      table: 'traits',
      pkColumn: 'name',
      rows: payload['traits'] as List<dynamic>? ?? const [],
      columns: ['name', 'content', 'updated_at', 'is_deleted'],
    );
    await mergeKeyedTable(
      table: 'rooms',
      pkColumn: 'room_id',
      rows: payload['rooms'] as List<dynamic>? ?? const [],
      columns: [
        'room_id',
        'title',
        'subtitle',
        'color_hex',
        'accessory',
        'avatar_state',
        'rolling_summary',
        'summarized_until_msg_id',
        'updated_at',
        'is_deleted',
      ],
    );
    await mergeKeyedTable(
      table: 'data',
      pkColumn: 'key',
      rows: payload['data'] as List<dynamic>? ?? const [],
      columns: ['key', 'room_id', 'value', 'updated_at', 'is_deleted'],
    );
    await mergeKeyedTable(
      table: 'hooks',
      pkColumn: 'name',
      rows: payload['hooks'] as List<dynamic>? ?? const [],
      columns: ['name', 'description', 'params_json', 'body', 'updated_at', 'is_deleted'],
    );

    // Deduplicate messages by (room_id, role, created_at, content) across devices
    final remoteMessages = payload['messages'] as List<dynamic>? ?? const [];
    for (final raw in remoteMessages) {
      if (raw is! Map) continue;
      final m = Map<String, Object?>.from(raw);
      final roomId = m['room_id']?.toString();
      final role = m['role']?.toString();
      final content = m['content']?.toString();
      final createdAt = (m['created_at'] as num?)?.toInt();
      if (roomId == null || role == null || content == null || createdAt == null) {
        continue;
      }
      final remoteDeleted = (m['is_deleted'] as num?)?.toInt() ?? 0;
      final remoteStarred = (m['is_starred'] as num?)?.toInt() ?? 0;

      final existing = await db.query(
        'messages',
        where: 'room_id = ? AND role = ? AND created_at = ? AND content = ?',
        whereArgs: [roomId, role, createdAt, content],
        limit: 1,
      );

      if (existing.isEmpty) {
        await db.insert('messages', {
          'room_id': roomId,
          'role': role,
          'content': content,
          'image_path': m['image_path'],
          'tool_pill': m['tool_pill'],
          'card_json': m['card_json'],
          'is_starred': remoteStarred,
          'archived_color_hex': m['archived_color_hex'],
          'archived_title': m['archived_title'],
          'created_at': createdAt,
          'sync_status': 'synced',
          'is_deleted': remoteDeleted,
        });
        if (remoteDeleted == 1) {
          deleted++;
        } else {
          upserted++;
        }
      } else if (remoteDeleted == 1 && (existing.first['is_deleted'] as int? ?? 0) == 0) {
        await db.update(
          'messages',
          {'is_deleted': 1, 'sync_status': 'synced'},
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
        deleted++;
      }
    }

    return (upserted: upserted, deleted: deleted);
  }
}
