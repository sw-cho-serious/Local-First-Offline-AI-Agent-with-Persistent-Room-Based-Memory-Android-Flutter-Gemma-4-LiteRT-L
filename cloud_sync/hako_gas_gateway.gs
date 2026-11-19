/**
 * ============================================================================
 * 🛸 HAKO × KODARI — Phase 2 雲端交班同步 GAS 閘道 (v1.0)
 * ============================================================================
 * ⚠️ 安全隔離原則：
 *   本腳本僅應綁定在「全新建立的專屬 Google Sheet（例如：HAKO_KODARI_雲端交班庫）」，
 *   與其他正式業務試算表 100% 實體隔離，絕對不碰其他重要帳務資料！
 *
 * 🛠️ 部署步驟（3 分鐘完成）：
 *   1. 在 Google Drive 新建一份空白試算表，命名為「HAKO_KODARI_雲端交班庫」。
 *   2. 點擊試算表上方選單：「擴充功能」→「Apps Script」。
 *   3. 清空預設程式碼，把這整份檔案貼上並儲存。
 *   4. (選填安全鎖) 修改下方 SYNC_TOKEN 為你自己的暗號（兩支手機設定同一個）。
 *   5. 右上角「部署」→「新增部署作業」→ 類型選「網頁應用程式 (Web App)」：
 *      - 執行身分：我
 *      - 誰可以存取：所有人（或擁有 Google 帳戶的任何人）
 *   6. 部署後複製「網頁應用程式網址 (URL)」，貼進手機 HAKO App 頂部 ☁️ 設定即可！
 * ============================================================================
 */

const SYNC_TOKEN = ''; // 留空表示不驗 token；若填寫暗號，兩支手機設定同一個即可

const TABLE_SCHEMAS = {
  'traits': ['name', 'content', 'updated_at', 'is_deleted'],
  'rooms': ['room_id', 'title', 'subtitle', 'color_hex', 'accessory', 'avatar_state', 'rolling_summary', 'summarized_until_msg_id', 'updated_at', 'is_deleted'],
  'data': ['key', 'room_id', 'value', 'updated_at', 'is_deleted'],
  'messages': ['msg_uid', 'room_id', 'role', 'content', 'image_path', 'tool_pill', 'card_json', 'is_starred', 'archived_color_hex', 'archived_title', 'created_at', 'is_deleted'],
  'hooks': ['name', 'description', 'params_json', 'body', 'updated_at', 'is_deleted'],
  'skills': ['id', 'name', 'trigger_keywords', 'description', 'content_md', 'enabled', 'updated_at', 'is_deleted'],
  'peer_logs': ['id', 'room_id', 'query', 'reply', 'peer', 'created_at'],
  'photo_uploads': ['id', 'room_id', 'file_name', 'drive_url', 'note', 'created_at']
};

function doGet(e) {
  return ContentService.createTextOutput(JSON.stringify({
    ok: true,
    service: 'HAKO_KODARI_P2_GATEWAY',
    time: Date.now()
  })).setMimeType(ContentService.MimeType.JSON);
}

function doPost(e) {
  const lock = LockService.getScriptLock();
  lock.waitLock(15000);
  try {
    const body = JSON.parse(e.postData.contents || '{}');
    if (SYNC_TOKEN && body.token !== SYNC_TOKEN) {
      return jsonOut({ ok: false, error: 'SYNC_TOKEN 驗證失敗' });
    }

    const ss = SpreadsheetApp.getActiveSpreadsheet();
    ensureSheetsExist_(ss);

    if (body.action === 'consult_peer') {
      return handleConsultPeer_(ss, body);
    }
    if (body.action === 'upload_photo') {
      return handleUploadPhoto_(ss, body);
    }

    const clientLastSync = Number(body.last_sync_at || 0);
    const payload = body.payload || {};

    // 1. Merge client pending records into Sheet (LWW by updated_at / created_at)
    mergeKeyedSheet_(ss.getSheetByName('traits'), TABLE_SCHEMAS.traits, 'name', 'updated_at', payload.traits || []);
    mergeKeyedSheet_(ss.getSheetByName('rooms'), TABLE_SCHEMAS.rooms, 'room_id', 'updated_at', payload.rooms || []);
    mergeKeyedSheet_(ss.getSheetByName('data'), TABLE_SCHEMAS.data, 'key', 'updated_at', payload.data || []);
    mergeKeyedSheet_(ss.getSheetByName('hooks'), TABLE_SCHEMAS.hooks, 'name', 'updated_at', payload.hooks || []);
    mergeKeyedSheet_(ss.getSheetByName('skills'), TABLE_SCHEMAS.skills, 'id', 'updated_at', payload.skills || []);
    mergeMessagesSheet_(ss.getSheetByName('messages'), payload.messages || []);

    // 2. Refresh human/AI-readable dashboard sheet for Aero/Spark handoff
    rebuildDashboardSheet_(ss);

    // 2.5 Optional: Mirror active room todos to Google Tasks ('HAKO 工作待辦') if Tasks Advanced Service is enabled
    try {
      syncTodosToGoogleTasks_(ss);
    } catch (_) {}

    // 3. Collect remote delta since clientLastSync
    const remotePayload = {
      traits: readRowsSince_(ss.getSheetByName('traits'), TABLE_SCHEMAS.traits, 'updated_at', clientLastSync),
      rooms: readRowsSince_(ss.getSheetByName('rooms'), TABLE_SCHEMAS.rooms, 'updated_at', clientLastSync),
      data: readRowsSince_(ss.getSheetByName('data'), TABLE_SCHEMAS.data, 'updated_at', clientLastSync),
      messages: readRowsSince_(ss.getSheetByName('messages'), TABLE_SCHEMAS.messages, 'created_at', clientLastSync),
      hooks: readRowsSince_(ss.getSheetByName('hooks'), TABLE_SCHEMAS.hooks, 'updated_at', clientLastSync),
      skills: readRowsSince_(ss.getSheetByName('skills'), TABLE_SCHEMAS.skills, 'updated_at', clientLastSync)
    };

    return jsonOut({
      ok: true,
      server_time: Date.now(),
      remote_payload: remotePayload
    });
  } catch (err) {
    return jsonOut({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function jsonOut(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function ensureSheetsExist_(ss) {
  Object.keys(TABLE_SCHEMAS).forEach(function (name) {
    let sh = ss.getSheetByName(name);
    if (!sh) {
      sh = ss.insertSheet(name);
      sh.appendRow(TABLE_SCHEMAS[name]);
      sh.setFrozenRows(1);
    }
  });
  if (!ss.getSheetByName('KODARI_現場交班看板')) {
    const dash = ss.insertSheet('KODARI_現場交班看板', 0);
    dash.appendRow(['房間ID', '案場／房間名稱', '精靈狀態', '完成率', '待辦與現場紀錄', '最後更新']);
    dash.setFrozenRows(1);
  }
}

function mergeKeyedSheet_(sh, cols, pkCol, tsCol, incomingRows) {
  if (!incomingRows || incomingRows.length === 0) return;
  const values = sh.getDataRange().getValues();
  const pkIdx = cols.indexOf(pkCol);
  const tsIdx = cols.indexOf(tsCol);
  const rowIndexByPk = {};
  for (let i = 1; i < values.length; i++) {
    rowIndexByPk[String(values[i][pkIdx])] = i + 1;
  }

  incomingRows.forEach(function (item) {
    const pk = String(item[pkCol] || '');
    if (!pk) return;
    const inTs = Number(item[tsCol] || 0);
    const existingRowNum = rowIndexByPk[pk];
    const rowData = cols.map(function (c) { return item[c] !== undefined ? item[c] : ''; });

    if (!existingRowNum) {
      sh.appendRow(rowData);
      rowIndexByPk[pk] = sh.getLastRow();
    } else {
      const curTs = Number(values[existingRowNum - 1][tsIdx] || 0);
      if (inTs >= curTs) {
        sh.getRange(existingRowNum, 1, 1, cols.length).setValues([rowData]);
      }
    }
  });
}

function mergeMessagesSheet_(sh, incomingRows) {
  if (!incomingRows || incomingRows.length === 0) return;
  const cols = TABLE_SCHEMAS.messages;
  const values = sh.getDataRange().getValues();
  const uidIdx = cols.indexOf('msg_uid');
  const rowIndexByUid = {};
  for (let i = 1; i < values.length; i++) {
    rowIndexByUid[String(values[i][uidIdx])] = i + 1;
  }

  incomingRows.forEach(function (item) {
    const uid = String(item.room_id || '') + '|' + String(item.role || '') + '|' + String(item.created_at || '') + '|' + String(item.content || '').slice(0, 40);
    item.msg_uid = uid;
    const rowData = cols.map(function (c) { return item[c] !== undefined ? item[c] : ''; });
    const existingRowNum = rowIndexByUid[uid];
    if (!existingRowNum) {
      sh.appendRow(rowData);
      rowIndexByUid[uid] = sh.getLastRow();
    } else {
      sh.getRange(existingRowNum, 1, 1, cols.length).setValues([rowData]);
    }
  });
}

function readRowsSince_(sh, cols, tsCol, sinceMs) {
  const values = sh.getDataRange().getValues();
  if (values.length <= 1) return [];
  const tsIdx = cols.indexOf(tsCol);
  const out = [];
  for (let i = 1; i < values.length; i++) {
    const row = values[i];
    const ts = Number(row[tsIdx] || 0);
    if (sinceMs === 0 || ts > sinceMs) {
      const obj = {};
      cols.forEach(function (c, idx) { obj[c] = row[idx]; });
      out.push(obj);
    }
  }
  return out;
}

function rebuildDashboardSheet_(ss) {
  const dash = ss.getSheetByName('KODARI_現場交班看板');
  const rooms = sheetToObjects_(ss.getSheetByName('rooms'), TABLE_SCHEMAS.rooms);
  const data = sheetToObjects_(ss.getSheetByName('data'), TABLE_SCHEMAS.data);
  const dataByRoom = {};
  data.forEach(function (d) {
    if (Number(d.is_deleted || 0) === 0) dataByRoom[d.room_id] = d.value || '';
  });

  dash.clearContents();
  dash.appendRow(['房間ID', '案場／房間名稱', '精靈狀態', '完成率', '待辦與現場紀錄', '最後更新']);
  rooms.filter(function (r) { return Number(r.is_deleted || 0) === 0; }).forEach(function (r) {
    const rawTodo = String(dataByRoom[r.room_id] || '');
    const lines = rawTodo.split('\n').filter(function (l) { return l.trim().length > 0; });
    const done = lines.filter(function (l) { return /^-\s*\[[xXO]\]/.test(l.trim()); }).length;
    const pct = lines.length > 0 ? Math.round((done / lines.length) * 100) + '%' : '-';
    const tsStr = r.updated_at ? Utilities.formatDate(new Date(Number(r.updated_at)), 'Asia/Taipei', 'yyyy-MM-dd HH:mm') : '';
    dash.appendRow([r.room_id, r.title, r.avatar_state, pct, rawTodo, tsStr]);
  });
}

function sheetToObjects_(sh, cols) {
  const values = sh.getDataRange().getValues();
  const list = [];
  for (let i = 1; i < values.length; i++) {
    const obj = {};
    cols.forEach(function (c, idx) { obj[c] = values[i][idx]; });
    list.push(obj);
  }
  return list;
}

/**
 * 選配功能：把 HAKO 各工作房間的待辦鏡像同步到你的「Google Tasks（HAKO 工作待辦）」清單。
 * 啟用方式：Apps Script 左側「服務 +」→ 加入「Google Tasks API」(Tasks) → 重新部署即可。
 */
function syncTodosToGoogleTasks_(ss) {
  if (typeof Tasks === 'undefined') return;

  const listTitle = 'HAKO 工作待辦';
  const taskLists = Tasks.Tasklists.list().items || [];
  let targetList = taskLists.find(function (l) { return l.title === listTitle; });
  if (!targetList) {
    targetList = Tasks.Tasklists.insert({ title: listTitle });
  }
  const listId = targetList.id;

  const existing = (Tasks.Tasks.list(listId, { showCompleted: true, showHidden: true, maxResults: 100 }).items) || [];
  const byTitle = {};
  existing.forEach(function (t) {
    if (t.title) byTitle[t.title] = t;
  });

  const rooms = sheetToObjects_(ss.getSheetByName('rooms'), TABLE_SCHEMAS.rooms);
  const data = sheetToObjects_(ss.getSheetByName('data'), TABLE_SCHEMAS.data);
  const dataByRoom = {};
  data.forEach(function (d) {
    if (Number(d.is_deleted || 0) === 0) dataByRoom[d.room_id] = d.value || '';
  });

  rooms.forEach(function (r) {
    if (Number(r.is_deleted || 0) !== 0) return;
    if (String(r.room_id || '').indexOf('para:archives:') === 0) return;
    const rawTodo = String(dataByRoom[r.room_id] || '');
    const lines = rawTodo.split('\n');
    lines.forEach(function (line) {
      const m = line.trim().match(/^-\s*\[([xXO\s])\]\s*(.+)$/);
      if (!m) return;
      const isDone = m[1] !== ' ';
      const itemText = m[2].trim();
      if (!itemText) return;
      const taskTitle = '[' + r.title + '] ' + itemText;
      const desiredStatus = isDone ? 'completed' : 'needsAction';
      const cur = byTitle[taskTitle];
      if (!cur) {
        if (!isDone) {
          Tasks.Tasks.insert({ title: taskTitle }, listId);
        }
      } else if (cur.status !== desiredStatus) {
        cur.status = desiredStatus;
        if (!isDone) delete cur.completed;
        Tasks.Tasks.update(cur, listId, cur.id);
      }
    });
  });
}

function handleConsultPeer_(ss, body) {
  const query = String(body.query || '').trim();
  const contextText = String(body.context || '').trim();
  const roomId = String(body.room_id || 'main').trim();
  const fallbackReason = String(body.fallback_reason || '').trim();

  if (!query) {
    return jsonOut({ ok: false, error: '缺少 consult_peer 查詢問題內容 (query)' });
  }

  // Build active factory room/todo background from Google Sheet
  const rooms = sheetToObjects_(ss.getSheetByName('rooms'), TABLE_SCHEMAS.rooms);
  const data = sheetToObjects_(ss.getSheetByName('data'), TABLE_SCHEMAS.data);
  const roomTitleById = {};
  rooms.forEach(function (r) {
    if (Number(r.is_deleted || 0) === 0) roomTitleById[r.room_id] = r.title;
  });

  const activeTodoSummaries = [];
  data.forEach(function (d) {
    if (Number(d.is_deleted || 0) !== 0) return;
    const title = roomTitleById[d.room_id] || d.room_id;
    const val = String(d.value || '').trim();
    if (val) {
      activeTodoSummaries.push('【' + title + '】\n' + val);
    }
  });

  const boardContext = activeTodoSummaries.slice(0, 8).join('\n\n');
  const apiKey = PropertiesService.getScriptProperties().getProperty('GEMINI_API_KEY') || '';

  let replyText = '';
  let sources = [];
  let peerName = 'Spark 參謀';

  if (apiKey) {
    try {
      const sysText = '你是雲端參謀 Spark，與手機端工兵 KODARI 協同支援現場使用者。' +
        '語氣規則：繁體中文、直接簡潔、平輩稱呼「你」（嚴禁使用「您」），有實務結論直接條列重點。' +
        '當涉及廠內材料規則時須注意 1.09 耗損、3.5mm 鋸路、6.4m 093Z/094、300kg 特殊排抽門檻。';
      const userPrompt = '【發起房間】' + (roomTitleById[roomId] || roomId) + '\n' +
        (fallbackReason ? '【端側 fallback 原因】' + fallbackReason + '\n' : '') +
        (contextText ? '【端側補充上下文】\n' + contextText + '\n\n' : '') +
        (boardContext ? '【目前交班待辦總覽】\n' + boardContext + '\n\n' : '') +
        '【使用者現場提問】\n' + query;

      const endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=' + encodeURIComponent(apiKey);
      const res = UrlFetchApp.fetch(endpoint, {
        method: 'post',
        contentType: 'application/json',
        muteHttpExceptions: true,
        payload: JSON.stringify({
          systemInstruction: { parts: [{ text: sysText }] },
          contents: [{ role: 'user', parts: [{ text: userPrompt }] }],
          tools: [{ google_search: {} }]
        })
      });

      const code = res.getResponseCode();
      if (code >= 200 && code < 300) {
        const parsed = JSON.parse(res.getContentText() || '{}');
        const cand = (parsed.candidates && parsed.candidates[0]) || {};
        const parts = (cand.content && cand.content.parts) || [];
        replyText = parts.map(function (p) { return p.text || ''; }).join('\n').trim();

        const grounding = cand.groundingMetadata || {};
        const chunks = grounding.groundingChunks || [];
        chunks.forEach(function (ch) {
          if (ch.web && ch.web.uri) {
            const uri = String(ch.web.uri);
            const domainMatch = uri.match(/^https?:\/\/([^\/]+)/i);
            sources.push({
              title: String(ch.web.title || '雲端查證來源'),
              url: uri,
              snippet: '',
              domain: domainMatch ? domainMatch[1] : ''
            });
          }
        });
      } else {
        replyText = '雲端參謀呼叫 Gemini 回傳 HTTP ' + code + '：' + res.getContentText().slice(0, 180);
      }
    } catch (err) {
      replyText = '雲端參謀連線異常：' + String(err);
    }
  }

  if (!replyText) {
    peerName = 'HAKO 雲端庫直查（尚未設定 GEMINI_API_KEY）';
    const kw = query.toLowerCase();
    const matchedLines = [];
    activeTodoSummaries.forEach(function (block) {
      block.split('\n').forEach(function (line) {
        if (line.toLowerCase().indexOf(kw) !== -1) matchedLines.push(line);
      });
    });

    const messages = sheetToObjects_(ss.getSheetByName('messages'), TABLE_SCHEMAS.messages);
    messages.forEach(function (m) {
      if (Number(m.is_deleted || 0) === 0 && String(m.content || '').toLowerCase().indexOf(kw) !== -1) {
        matchedLines.push('[' + (roomTitleById[m.room_id] || m.room_id) + '] ' + String(m.content).slice(0, 100));
      }
    });

    if (matchedLines.length > 0) {
      replyText = '目前 GAS 還沒設定 GEMINI_API_KEY，我先從雲端交班庫幫你撈出相關紀錄：\n' +
        matchedLines.slice(0, 8).join('\n');
    } else {
      replyText = '已收到請求「' + query + '」，目前 GAS 指令碼屬性尚未設定 GEMINI_API_KEY（可至 Apps Script「專案設定 → 指令碼屬性」填入 GEMINI_API_KEY 即可直接開啟雲端 Spark 聯網參謀）。\n目前雲端庫共有 ' + activeTodoSummaries.length + ' 間活躍待辦房，暫無吻合「' + query + '」的紀錄。';
    }
  }

  try {
    const peerLogSheet = ss.getSheetByName('peer_logs');
    if (peerLogSheet) {
      peerLogSheet.appendRow([
        Utilities.getUuid(),
        roomId,
        query,
        replyText.slice(0, 4000),
        peerName,
        Date.now()
      ]);
    }
  } catch (_) {}

  return jsonOut({
    ok: true,
    peer: peerName,
    reply: replyText,
    sources: sources.slice(0, 5),
    server_time: Date.now()
  });
}

function handleUploadPhoto_(ss, body) {
  const b64 = String(body.base64_jpg || '').trim();
  const roomId = String(body.room_id || 'main').trim();
  const roomTitle = String(body.room_title || roomId).trim();
  const note = String(body.note || '').trim();
  const createTodo = body.create_todo === true;
  const fileName = String(body.file_name || ('hako_' + Date.now() + '.jpg')).trim();

  if (!b64) {
    return jsonOut({ ok: false, error: '缺少 base64_jpg 影像資料' });
  }

  try {
    const folderName = 'HAKO_KODARI_現場照片庫';
    const folders = DriveApp.getFoldersByName(folderName);
    const rootFolder = folders.hasNext() ? folders.next() : DriveApp.createFolder(folderName);

    const bytes = Utilities.base64Decode(b64);
    const blob = Utilities.newBlob(bytes, 'image/jpeg', fileName);
    const file = rootFolder.createFile(blob);
    const driveUrl = file.getUrl();

    const uploadSheet = ss.getSheetByName('photo_uploads');
    if (uploadSheet) {
      uploadSheet.appendRow([file.getId(), roomId, fileName, driveUrl, note, Date.now()]);
    }

    // ONLY mirror into 'HAKO 工作待辦' if explicitly marked as a todo (e.g. annotated dimension photos or pinned items)
    if (createTodo) {
      try {
        if (typeof Tasks !== 'undefined') {
          const listTitle = 'HAKO 工作待辦';
          const taskLists = Tasks.Tasklists.list().items || [];
          let targetList = taskLists.find(function (l) { return l.title === listTitle; });
          if (!targetList) targetList = Tasks.Tasklists.insert({ title: listTitle });
          const label = note ? note : '現場實拍照';
          Tasks.Tasks.insert({
            title: '[' + roomTitle + '] 📷 ' + label,
            notes: driveUrl
          }, targetList.id);
        }
      } catch (_) {}
    }

    return jsonOut({
      ok: true,
      file_id: file.getId(),
      drive_url: driveUrl,
      server_time: Date.now()
    });
  } catch (err) {
    return jsonOut({ ok: false, error: 'Drive 上傳失敗：' + String(err) });
  }
}

