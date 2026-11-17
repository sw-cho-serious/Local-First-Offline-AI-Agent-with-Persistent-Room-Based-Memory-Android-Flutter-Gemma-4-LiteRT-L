import 'dart:io';
import 'dart:math' as math;

import '../data/models.dart';
import 'native_actions.dart';

class HookExecutionResult {
  const HookExecutionResult({
    required this.ok,
    required this.output,
    required this.engineUsed,
    this.error,
  });

  final bool ok;
  final String output;
  final String engineUsed;
  final String? error;
}

class HookRegisterSpec {
  const HookRegisterSpec({
    required this.name,
    required this.description,
    required this.params,
    required this.body,
  });

  final String name;
  final String description;
  final List<String> params;
  final String body;
}

/// Pure-Dart JS/formula evaluator with Android isolated WebView sandbox fallback.
class HookRuntime {
  /// Parses "@技能 註冊 名稱 | 說明 | 參數1,參數2 | 公式" cleanly.
  static HookRegisterSpec? parseRegisterCommand(String rawText) {
    var trimmed = rawText.trim();
    if (trimmed.startsWith('註冊')) {
      trimmed = trimmed.substring(2).replaceFirst(RegExp(r'^[\s:：|]+'), '');
    } else if (trimmed.startsWith('新增')) {
      trimmed = trimmed.substring(2).replaceFirst(RegExp(r'^[\s:：|]+'), '');
    } else {
      return null;
    }

    final parts = trimmed.split('|').map((e) => e.trim()).toList();
    if (parts.length < 2) return null;

    if (parts.length == 2) {
      // Short form: 名稱 | 公式
      final name = parts[0];
      final body = _normalizeBody(parts[1]);
      if (name.isEmpty || body.isEmpty) return null;
      return HookRegisterSpec(
        name: name,
        description: '自訂快捷公式技能',
        params: _inferParamsFromBody(body),
        body: body,
      );
    }

    if (parts.length == 3) {
      // Medium form: 名稱 | 參數1,參數2 | 公式
      final name = parts[0];
      final params = parts[1]
          .split(RegExp(r'[,，\s]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final body = _normalizeBody(parts[2]);
      if (name.isEmpty || body.isEmpty) return null;
      return HookRegisterSpec(
        name: name,
        description: '自訂快捷公式技能',
        params: params,
        body: body,
      );
    }

    // Full form: 名稱 | 說明 | 參數1,參數2 | 公式
    final name = parts[0];
    final desc = parts[1].isEmpty ? '自訂快捷公式技能' : parts[1];
    final params = parts[2]
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final body = _normalizeBody(parts.sublist(3).join(' | '));
    if (name.isEmpty || body.isEmpty) return null;
    return HookRegisterSpec(
      name: name,
      description: desc,
      params: params,
      body: body,
    );
  }

  static String _normalizeBody(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return s;
    if (!s.contains('return ') && !s.contains(';')) {
      return 'return ($s);';
    }
    return s;
  }

  static List<String> _inferParamsFromBody(String body) {
    final matches = RegExp(r'\b[a-zA-Z_][a-zA-Z0-9_]*\b').allMatches(body);
    const reserved = {
      'const',
      'let',
      'var',
      'return',
      'Math',
      'ceil',
      'floor',
      'round',
      'abs',
      'max',
      'min',
      'pow',
      'sqrt',
      'toFixed',
      'true',
      'false',
      'null',
    };
    final out = <String>[];
    for (final m in matches) {
      final id = m.group(0)!;
      if (!reserved.contains(id) && !out.contains(id)) {
        out.add(id);
      }
    }
    return out;
  }

  /// Parses positional values or "key=val" arguments into hook params map.
  static Map<String, dynamic> bindArguments(HookRecord hook, String rawArgsText) {
    final result = <String, dynamic>{};
    final text = rawArgsText.trim();
    if (text.isEmpty) return result;

    // 1. Named arguments e.g. weight_per_m=0.45 length_mm=3200 qty=10
    final namedMatches = RegExp(r'([A-Za-z_\u4e00-\u9fff][A-Za-z0-9_\u4e00-\u9fff]*)\s*=\s*([^\s,，]+)')
        .allMatches(text)
        .toList();
    if (namedMatches.isNotEmpty) {
      for (final m in namedMatches) {
        final key = m.group(1)!;
        final rawVal = m.group(2)!;
        result[key] = _coerceScalar(rawVal);
      }
      return result;
    }

    // 2. Positional arguments mapped to hook.params in order
    final tokens = text
        .split(RegExp(r'[\s,，/]+'))
        .map((t) => t.replaceAll(RegExp(r'(mm|MM|cm|CM|kg|KG|支|隻|片|條)$'), '').trim())
        .where((t) => t.isNotEmpty)
        .toList();

    for (var i = 0; i < hook.params.length && i < tokens.length; i++) {
      result[hook.params[i]] = _coerceScalar(tokens[i]);
    }
    return result;
  }

  static dynamic _coerceScalar(String raw) {
    final s = raw.trim();
    final numVal = num.tryParse(s);
    if (numVal != null) return numVal.toDouble();
    if (s.toLowerCase() == 'true') return true;
    if (s.toLowerCase() == 'false') return false;
    return s;
  }

  static Future<HookExecutionResult> execute({
    required HookRecord hook,
    required Map<String, dynamic> args,
  }) async {
    final missing = hook.params.where((p) => !args.containsKey(p)).toList();
    if (missing.isNotEmpty) {
      return HookExecutionResult(
        ok: false,
        output: '',
        engineUsed: 'validator',
        error: '缺少參數：${missing.join(', ')}（依序輸入：${hook.params.join(' ')}）',
      );
    }

    try {
      final value = _evaluatePureDartSubset(hook.body, args);
      return HookExecutionResult(
        ok: true,
        output: _formatValue(value),
        engineUsed: 'dart-subset',
      );
    } catch (dartErr) {
      if (Platform.isAndroid) {
        final sandbox = await NativeActions.evaluateJsSandbox(
          code: hook.body,
          args: args,
        );
        if (sandbox.ok) {
          return HookExecutionResult(
            ok: true,
            output: sandbox.result,
            engineUsed: 'android-webview-sandbox',
          );
        }
        return HookExecutionResult(
          ok: false,
          output: '',
          engineUsed: 'android-webview-sandbox',
          error: sandbox.error ?? dartErr.toString(),
        );
      }
      return HookExecutionResult(
        ok: false,
        output: '',
        engineUsed: 'dart-subset',
        error: dartErr.toString(),
      );
    }
  }

  static String _formatValue(Object? val) {
    if (val == null) return '';
    if (val is double) {
      if (val.isNaN || val.isInfinite) return val.toString();
      if ((val - val.roundToDouble()).abs() < 1e-9) {
        return val.round().toString();
      }
      return double.parse(val.toStringAsFixed(4)).toString();
    }
    return val.toString();
  }

  static Object? _evaluatePureDartSubset(
    String body,
    Map<String, dynamic> args,
  ) {
    final env = <String, Object?>{
      for (final e in args.entries) e.key: e.value,
    };

    final statements = _splitStatements(body);
    if (statements.isEmpty) {
      throw const FormatException('技能公式內容為空');
    }

    Object? lastValue;
    for (final rawStmt in statements) {
      final stmt = rawStmt.trim();
      if (stmt.isEmpty) continue;

      if (stmt.startsWith('if ') || stmt.startsWith('if(') || stmt.startsWith('for') || stmt.startsWith('while')) {
        throw const FormatException('複雜控制流程轉交沙盒執行');
      }

      if (stmt.startsWith('return ')) {
        final expr = stmt.substring(7).trim();
        return _JsExprParser(expr, env).parse();
      }

      final declMatch = RegExp(
        r'^(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([\s\S]+)$',
      ).firstMatch(stmt);
      if (declMatch != null) {
        final name = declMatch.group(1)!;
        final expr = declMatch.group(2)!;
        env[name] = _JsExprParser(expr, env).parse();
        lastValue = env[name];
        continue;
      }

      final assignMatch = RegExp(
        r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([\s\S]+)$',
      ).firstMatch(stmt);
      if (assignMatch != null && !stmt.startsWith('==')) {
        final name = assignMatch.group(1)!;
        final expr = assignMatch.group(2)!;
        env[name] = _JsExprParser(expr, env).parse();
        lastValue = env[name];
        continue;
      }

      lastValue = _JsExprParser(stmt, env).parse();
    }

    return lastValue;
  }

  static List<String> _splitStatements(String body) {
    final out = <String>[];
    final buf = StringBuffer();
    String? quote;
    var depth = 0;

    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (quote != null) {
        buf.write(ch);
        if (ch == '\\' && i + 1 < body.length) {
          buf.write(body[++i]);
          continue;
        }
        if (ch == quote) {
          quote = null;
        }
        continue;
      }
      if (ch == '"' || ch == "'" || ch == '`') {
        quote = ch;
        buf.write(ch);
        continue;
      }
      if (ch == '(' || ch == '{' || ch == '[') depth++;
      if (ch == ')' || ch == '}' || ch == ']') depth--;

      if (ch == ';' && depth == 0) {
        final s = buf.toString().trim();
        if (s.isNotEmpty) out.add(s);
        buf.clear();
        continue;
      }
      buf.write(ch);
    }
    final tail = buf.toString().trim();
    if (tail.isNotEmpty) out.add(tail);
    return out;
  }
}

class _JsExprParser {
  _JsExprParser(this.input, this.env);

  final String input;
  final Map<String, Object?> env;
  int pos = 0;

  Object? parse() {
    final v = _parseTernary();
    _skipWs();
    if (pos < input.length) {
      throw FormatException('未預期語法字元: ${input.substring(pos)}');
    }
    return v;
  }

  void _skipWs() {
    while (pos < input.length && RegExp(r'\s').hasMatch(input[pos])) {
      pos++;
    }
  }

  bool _match(String token) {
    _skipWs();
    if (input.startsWith(token, pos)) {
      pos += token.length;
      return true;
    }
    return false;
  }

  Object? _parseTernary() {
    final cond = _parseOr();
    if (_match('?')) {
      final trueVal = _parseTernary();
      if (!_match(':')) {
        throw const FormatException('三元運算缺少 :');
      }
      final falseVal = _parseTernary();
      return _isTruthy(cond) ? trueVal : falseVal;
    }
    return cond;
  }

  Object? _parseOr() {
    var left = _parseAnd();
    while (_match('||')) {
      final right = _parseAnd();
      left = _isTruthy(left) ? left : right;
    }
    return left;
  }

  Object? _parseAnd() {
    var left = _parseEquality();
    while (_match('&&')) {
      final right = _parseEquality();
      left = _isTruthy(left) ? right : left;
    }
    return left;
  }

  Object? _parseEquality() {
    var left = _parseComparison();
    while (true) {
      if (_match('===') || _match('==')) {
        final right = _parseComparison();
        left = _equals(left, right);
      } else if (_match('!==') || _match('!=')) {
        final right = _parseComparison();
        left = !_equals(left, right);
      } else {
        break;
      }
    }
    return left;
  }

  Object? _parseComparison() {
    var left = _parseAddSub();
    while (true) {
      if (_match('>=')) {
        left = _toNum(left) >= _toNum(_parseAddSub());
      } else if (_match('<=')) {
        left = _toNum(left) <= _toNum(_parseAddSub());
      } else if (_match('>')) {
        left = _toNum(left) > _toNum(_parseAddSub());
      } else if (_match('<')) {
        left = _toNum(left) < _toNum(_parseAddSub());
      } else {
        break;
      }
    }
    return left;
  }

  Object? _parseAddSub() {
    var left = _parseMulDiv();
    while (true) {
      if (_match('+')) {
        final right = _parseMulDiv();
        if (left is String || right is String) {
          left = '${_toDisplay(left)}${_toDisplay(right)}';
        } else {
          left = _toNum(left) + _toNum(right);
        }
      } else if (_match('-')) {
        final right = _parseMulDiv();
        left = _toNum(left) - _toNum(right);
      } else {
        break;
      }
    }
    return left;
  }

  Object? _parseMulDiv() {
    var left = _parseUnary();
    while (true) {
      if (_match('*')) {
        left = _toNum(left) * _toNum(_parseUnary());
      } else if (_match('/')) {
        final right = _toNum(_parseUnary());
        if (right == 0) throw const FormatException('不可除以 0');
        left = _toNum(left) / right;
      } else if (_match('%')) {
        final right = _toNum(_parseUnary());
        left = _toNum(left) % right;
      } else {
        break;
      }
    }
    return left;
  }

  Object? _parseUnary() {
    if (_match('!')) {
      return !_isTruthy(_parseUnary());
    }
    if (_match('-')) {
      return -_toNum(_parseUnary());
    }
    if (_match('+')) {
      return _toNum(_parseUnary());
    }
    return _parsePostfix();
  }

  Object? _parsePostfix() {
    var val = _parsePrimary();
    while (true) {
      _skipWs();
      if (_match('.toFixed(')) {
        final digits = _toNum(_parseTernary()).round().clamp(0, 8);
        if (!_match(')')) throw const FormatException('toFixed 缺少右括號');
        val = _toNum(val).toStringAsFixed(digits);
      } else {
        break;
      }
    }
    return val;
  }

  Object? _parsePrimary() {
    _skipWs();
    if (pos >= input.length) {
      throw const FormatException('表達式提前結束');
    }

    final ch = input[pos];
    if (ch == '(') {
      pos++;
      final inner = _parseTernary();
      if (!_match(')')) throw const FormatException('缺少右括號 )');
      return inner;
    }

    if (ch == '"' || ch == "'") {
      return _readString(ch);
    }

    final numMatch = RegExp(r'^\d+(?:\.\d+)?').firstMatch(input.substring(pos));
    if (numMatch != null) {
      pos += numMatch.group(0)!.length;
      return double.parse(numMatch.group(0)!);
    }

    final idMatch = RegExp(r'^(?:Math\.)?[A-Za-z_][A-Za-z0-9_]*')
        .firstMatch(input.substring(pos));
    if (idMatch != null) {
      final ident = idMatch.group(0)!;
      pos += ident.length;

      if (ident == 'true') return true;
      if (ident == 'false') return false;
      if (ident == 'null' || ident == 'undefined') return null;

      if (_match('(')) {
        final fnArgs = <Object?>[];
        if (!_match(')')) {
          do {
            fnArgs.add(_parseTernary());
          } while (_match(','));
          if (!_match(')')) throw FormatException('函式 $ident 缺少 )');
        }
        return _callBuiltin(ident, fnArgs);
      }

      if (env.containsKey(ident)) {
        return env[ident];
      }
      throw FormatException('未知變數: $ident');
    }

    throw FormatException('無法解析字元: ${input.substring(pos)}');
  }

  String _readString(String quote) {
    pos++; // skip opening quote
    final buf = StringBuffer();
    while (pos < input.length) {
      final ch = input[pos++];
      if (ch == '\\' && pos < input.length) {
        final next = input[pos++];
        switch (next) {
          case 'n':
            buf.write('\n');
            break;
          case 't':
            buf.write('\t');
            break;
          default:
            buf.write(next);
        }
      } else if (ch == quote) {
        return buf.toString();
      } else {
        buf.write(ch);
      }
    }
    throw const FormatException('字串未閉合');
  }

  Object? _callBuiltin(String name, List<Object?> args) {
    double a(int i) => i < args.length ? _toNum(args[i]) : 0.0;
    switch (name) {
      case 'Math.ceil':
        return a(0).ceilToDouble();
      case 'Math.floor':
        return a(0).floorToDouble();
      case 'Math.round':
        return a(0).roundToDouble();
      case 'Math.abs':
        return a(0).abs();
      case 'Math.sqrt':
        return math.sqrt(a(0));
      case 'Math.pow':
        return math.pow(a(0), a(1)).toDouble();
      case 'Math.max':
        return args.map(_toNum).reduce(math.max);
      case 'Math.min':
        return args.map(_toNum).reduce(math.min);
      case 'Number':
        return a(0);
      case 'String':
        return args.isEmpty ? '' : _toDisplay(args[0]);
      default:
        throw FormatException('未支援函式: $name');
    }
  }

  double _toNum(Object? v) {
    if (v is num) return v.toDouble();
    if (v is bool) return v ? 1.0 : 0.0;
    if (v is String) {
      return double.tryParse(v.trim()) ?? 0.0;
    }
    return 0.0;
  }

  String _toDisplay(Object? v) {
    if (v == null) return '';
    if (v is double && (v - v.roundToDouble()).abs() < 1e-9) {
      return v.round().toString();
    }
    return v.toString();
  }

  bool _isTruthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0 && !v.isNaN;
    if (v is String) return v.isNotEmpty;
    return true;
  }

  bool _equals(Object? a, Object? b) {
    if (a is num && b is num) return (a - b).abs() < 1e-9;
    return a == b;
  }
}
