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
  'hooks': ['name', 'description', 'params_json', 'body', 'updated_at', 'is_deleted']
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

    const clientLastSync = Number(body.last_sync_at || 0);
    const payload = body.payload || {};

    // 1. Merge client pending records into Sheet (LWW by updated_at / created_at)
    mergeKeyedSheet_(ss.getSheetByName('traits'), TABLE_SCHEMAS.traits, 'name', 'updated_at', payload.traits || []);
    mergeKeyedSheet_(ss.getSheetByName('rooms'), TABLE_SCHEMAS.rooms, 'room_id', 'updated_at', payload.rooms || []);
    mergeKeyedSheet_(ss.getSheetByName('data'), TABLE_SCHEMAS.data, 'key', 'updated_at', payload.data || []);
    mergeKeyedSheet_(ss.getSheetByName('hooks'), TABLE_SCHEMAS.hooks, 'name', 'updated_at', payload.hooks || []);
    mergeMessagesSheet_(ss.getSheetByName('messages'), payload.messages || []);

    // 2. Refresh human/AI-readable dashboard sheet for Aero/Spark handoff
    rebuildDashboardSheet_(ss);

    // 3. Collect remote delta since clientLastSync
    const remotePayload = {
      traits: readRowsSince_(ss.getSheetByName('traits'), TABLE_SCHEMAS.traits, 'updated_at', clientLastSync),
      rooms: readRowsSince_(ss.getSheetByName('rooms'), TABLE_SCHEMAS.rooms, 'updated_at', clientLastSync),
      data: readRowsSince_(ss.getSheetByName('data'), TABLE_SCHEMAS.data, 'updated_at', clientLastSync),
      messages: readRowsSince_(ss.getSheetByName('messages'), TABLE_SCHEMAS.messages, 'created_at', clientLastSync),
      hooks: readRowsSince_(ss.getSheetByName('hooks'), TABLE_SCHEMAS.hooks, 'updated_at', clientLastSync)
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
