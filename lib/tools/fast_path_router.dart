class FastPathMatch {
  const FastPathMatch({
    required this.toolName,
    required this.args,
    required this.label,
  });

  final String toolName;
  final Map<String, dynamic> args;
  final String label;
}

/// Inspired by GHOST's <2ms `FastPathRouter` & `IntentBagger`:
/// - Mode A (`matchFastPath`): Anchored natural-language match executes directly
///   in Dart/MethodChannel with 0 token cost, 0 model waking, and <2ms latency.
/// - Mode B (`bagIntentHints`): Partial entity/hint extraction appended only to
///   the current User Turn prompt without polluting System Instruction or KV-Cache.
class FastPathRouter {
  static FastPathMatch? matchFastPath(String rawText) {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty || trimmed.startsWith('@') || trimmed.startsWith('/')) {
      return null;
    }
    // Never short-circuit multi-sentence/long engineering paragraphs or calculations.
    if (trimmed.length > 64 || trimmed.contains('\n')) {
      return null;
    }

    // Strip optional polite conversational lead-in.
    final clean = trimmed
        .replaceFirst(
          RegExp(r'^(?:請|麻煩|幫我|可不可以幫我|麻煩幫我|可以幫我|KODARI|可達)[，,\s]*'),
          '',
        )
        .trim();
    if (clean.isEmpty) return null;

    // 1. Flashlight ON / OFF (pure spoken command)
    if (RegExp(r'^(?:打開|開啟|開|開起)?\s*(?:手電筒|閃光燈|照明燈?)$').hasMatch(clean) ||
        clean == '開燈' ||
        clean == '開手電筒') {
      return const FastPathMatch(
        toolName: 'device_action',
        args: {'action': 'setFlashlight', 'value': 'on'},
        label: 'FastPath:手電筒開',
      );
    }
    if (RegExp(r'^(?:關掉|關閉|關|關起)?\s*(?:手電筒|閃光燈)(?:關掉|關閉)?$').hasMatch(clean) ||
        RegExp(r'^(?:把)?(?:手電筒|閃光燈|燈)關掉$').hasMatch(clean) ||
        clean == '關燈' ||
        clean == '關手電筒') {
      return const FastPathMatch(
        toolName: 'device_action',
        args: {'action': 'setFlashlight', 'value': 'off'},
        label: 'FastPath:手電筒關',
      );
    }

    // 2. Countdown timer (e.g., "倒數 15 分鐘 看烤漆爐", "設個 30 秒倒數")
    final timerLead = RegExp(
      r'^(?:設|設定|開啟|開)?(?:一個|個)?(?:倒數計時|倒數|計時器|計時)\s*(\d+\s*(?:分鐘|分|秒鐘|秒))\s*(.*)$',
    ).firstMatch(clean);
    if (timerLead != null) {
      final duration = timerLead.group(1)!.trim();
      final msg = timerLead.group(2)?.trim() ?? '';
      return FastPathMatch(
        toolName: 'device_action',
        args: {
          'action': 'setTimerOrAlarm',
          'value': duration,
          if (msg.isNotEmpty) 'message': msg,
        },
        label: 'FastPath:倒數計時',
      );
    }
    final timerMid = RegExp(
      r'^(\d+\s*(?:分鐘|分|秒鐘|秒))(?:後)?(?:的)?(?:倒數計時|倒數|計時|叫我|提醒我)\s*(.*)$',
    ).firstMatch(clean);
    if (timerMid != null) {
      final duration = timerMid.group(1)!.trim();
      final msg = timerMid.group(2)?.trim() ?? '';
      return FastPathMatch(
        toolName: 'device_action',
        args: {
          'action': 'setTimerOrAlarm',
          'value': duration,
          if (msg.isNotEmpty) 'message': msg,
        },
        label: 'FastPath:倒數計時',
      );
    }

    // 3. System clock alarm (e.g., "設明天早上7點半的鬧鐘 追金代交期", "設 08:30 鬧鐘")
    final alarmMatch = RegExp(
      r'^(?:設|設定|定)(?:一個|個)?(?:明天|明早|今天|早上|上午|下午|晚上|\s)*(\d{1,2}\s*[:：點時]\s*(?:\d{1,2}|半)?)\s*(?:分)?(?:的)?鬧鐘\s*(.*)$',
    ).firstMatch(clean);
    if (alarmMatch != null) {
      var rawClock = alarmMatch.group(1)!.replaceAll('半', '30').trim();
      if (RegExp(r'(?:下午|晚上|晚間)').hasMatch(clean)) {
        final hMatch = RegExp(r'^(\d{1,2})').firstMatch(rawClock);
        final h = int.tryParse(hMatch?.group(1) ?? '');
        if (h != null && h < 12) {
          rawClock = rawClock.replaceFirst(hMatch!.group(1)!, '${h + 12}');
        }
      }
      final msg = alarmMatch.group(2)?.trim() ?? '';
      return FastPathMatch(
        toolName: 'device_action',
        args: {
          'action': 'setTimerOrAlarm',
          'value': rawClock,
          if (msg.isNotEmpty) 'message': msg,
        },
        label: 'FastPath:系統鬧鐘',
      );
    }

    // 4. Google Maps navigation (e.g., "導航去台北車站", "帶我去高雄港")
    final mapMatch = RegExp(
      r'^(?:導航去|導航到|開地圖去|帶我去|開導航去|Google Maps\s*導航)\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (mapMatch != null) {
      final dest = mapMatch.group(1)!.trim();
      if (dest.isNotEmpty) {
        return FastPathMatch(
          toolName: 'device_action',
          args: {'action': 'openMap', 'value': dest},
          label: 'FastPath:地圖導航',
        );
      }
    }

    // 5. Dial phone with explicit digits (safe ACTION_DIAL prefill only)
    final dialMatch = RegExp(
      r'^(?:打電話給|打給|撥號給|撥給|撥電話給|撥號)\s*([\d\s\-\+\*#]{6,})$',
    ).firstMatch(clean);
    if (dialMatch != null) {
      final phone = dialMatch.group(1)!.replaceAll(RegExp(r'\s+'), '').trim();
      if (phone.length >= 6) {
        return FastPathMatch(
          toolName: 'device_action',
          args: {'action': 'dialPhone', 'value': phone},
          label: 'FastPath:撥號預填',
        );
      }
    }

    // 6. System settings shortcut
    final settingsMatch = RegExp(
      r'^(?:打開|開啟|跳轉|進|去)?\s*(wifi|wi-fi|藍牙|藍芽|熱點|網路共用|定位|gps|系統設定)\s*(?:設定|頁面|面板)?$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (settingsMatch != null) {
      final panel = settingsMatch.group(1)!.trim();
      return FastPathMatch(
        toolName: 'device_action',
        args: {'action': 'openSettings', 'value': panel},
        label: 'FastPath:系統設定',
      );
    }

    // 7. Spoken keyless web search (e.g., "上網查 304白鐵比重", "聯網搜尋 古坑五金行")
    final webMatch = RegExp(
      r'^(?:上網查(?:一下)?|聯網查(?:詢|一下)?|上網搜尋?|網路搜尋?|Google查(?:一下)?)\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (webMatch != null) {
      final q = webMatch.group(1)!.trim();
      if (q.isNotEmpty) {
        return FastPathMatch(
          toolName: 'web_search',
          args: {'query': q},
          label: 'FastPath:免Key聯網',
        );
      }
    }

    // 8. Spoken peer consultation (e.g., "呼叫參謀 ...", "問一下 Spark ...")
    final peerMatch = RegExp(
      r'^(?:呼叫參謀|問參謀|問\s*Spark|呼叫同伴|找支援|問雲端同伴)[，,:\s]*(.+)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (peerMatch != null) {
      final q = peerMatch.group(1)!.trim();
      if (q.isNotEmpty) {
        return FastPathMatch(
          toolName: 'consult_peer',
          args: {'query': q},
          label: 'FastPath:呼叫同伴',
        );
      }
    }

    return null;
  }

  /// Mode B IntentBagger: extracts compact 1-line tool hints for the active turn
  /// ONLY when relevant keywords appear in normal LLM prompts (never pollutes System Prompt).
  static String? bagIntentHints(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) return null;

    final hints = <String>[];
    if (RegExp(r'\b09\d{8}\b|\b0\d{1,2}-?\d{6,8}\b').hasMatch(text)) {
      hints.add('偵測到電話號碼，需撥號請用 device_action(action=dialPhone)');
    }
    if (RegExp(r'(?:手電筒|照明|好暗|太暗|很暗|昏暗|黑漆漆|看不見)').hasMatch(text)) {
      hints.add('照明需求可用 device_action(action=setFlashlight)');
    }
    if (RegExp(r'(?:導航|怎麼去|路線|Google\s*Maps)', caseSensitive: false).hasMatch(text)) {
      hints.add('導航需求可用 device_action(action=openMap)');
    }
    if (RegExp(r'(?:上網|聯網|查新聞|查電話|營業時間|價格|幾點關)').hasMatch(text)) {
      hints.add('需即時外部資訊請用 web_search');
    }
    if (RegExp(r'(?:參謀|Spark|排抽計算|搞不定|支援)', caseSensitive: false).hasMatch(text)) {
      hints.add('若超出端側4B把握度請呼出 consult_peer');
    }
    if (RegExp(r'(?:倒數|幾分鐘後|鬧鐘|叫我)').hasMatch(text)) {
      hints.add('系統倒數可用 device_action(action=setTimerOrAlarm)');
    }

    if (hints.isEmpty) return null;
    return '[Intent Hints: ${hints.take(2).join('；')}]';
  }
}
