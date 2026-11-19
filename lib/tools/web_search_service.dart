import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class WebSearchSource {
  const WebSearchSource({
    required this.title,
    required this.url,
    this.snippet = '',
    this.domain = '',
  });

  final String title;
  final String url;
  final String snippet;
  final String domain;

  Map<String, dynamic> toMap() => {
        'title': title,
        'url': url,
        'snippet': snippet,
        'domain': effectiveDomain,
      };

  String get effectiveDomain {
    if (domain.trim().isNotEmpty) return domain.trim();
    try {
      final host = Uri.parse(url).host.trim();
      return host.startsWith('www.') ? host.substring(4) : host;
    } catch (_) {
      return '';
    }
  }

  factory WebSearchSource.fromMap(Map<String, dynamic> map) {
    final url = (map['url'] ?? '').toString().trim();
    var dom = (map['domain'] ?? '').toString().trim();
    if (dom.isEmpty && url.isNotEmpty) {
      try {
        final host = Uri.parse(url).host;
        dom = host.startsWith('www.') ? host.substring(4) : host;
      } catch (_) {}
    }
    return WebSearchSource(
      title: (map['title'] ?? '外部來源').toString().trim(),
      url: url,
      snippet: (map['snippet'] ?? '').toString().trim(),
      domain: dom,
    );
  }
}

class WebSearchOutcome {
  const WebSearchOutcome({
    required this.ok,
    required this.query,
    this.usedPeerFallback = false,
    this.peerName,
    required this.summaryText,
    this.sources = const [],
    this.error,
  });

  final bool ok;
  final String query;
  final bool usedPeerFallback;
  final String? peerName;
  final String summaryText;
  final List<WebSearchSource> sources;
  final String? error;
}

/// Phase 2 / V2.0 Batch 1:
/// - Keyless web search via DuckDuckGo HTML / Lite endpoints.
/// - Direct HTTP Peer consultation (`consult_peer`) via GAS Web App or custom Tailscale/HTTP endpoint.
/// - Automatic fallback from failed/blocked DuckDuckGo queries into `consultPeer`.
class WebSearchService {
  static const String prefPeerEndpointKey = 'hako_peer_endpoint_url';
  static const String _prefGasUrlKey = 'hako_gas_webapp_url';
  static const String _prefGasTokenKey = 'hako_gas_sync_token';

  static Future<String> getConfiguredPeerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final custom = (prefs.getString(prefPeerEndpointKey) ?? '').trim();
    if (custom.isNotEmpty) return custom;
    return (prefs.getString(_prefGasUrlKey) ?? '').trim();
  }

  static Future<void> savePeerEndpointUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefPeerEndpointKey, url.trim());
  }

  static Future<WebSearchOutcome> searchWithFallback({
    required String query,
    String contextText = '',
    String roomId = 'main',
    http.Client? client,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      return const WebSearchOutcome(
        ok: false,
        query: '',
        summaryText: '請輸入要查詢的關鍵字或問題。',
        error: 'empty query',
      );
    }

    final httpClient = client ?? http.Client();
    final ownClient = client == null;
    String? failReason;

    try {
      final ddgUri = Uri.parse(
        'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(cleanQuery)}&kl=tw-tzh',
      );
      final response = await httpClient.get(
        ddgUri,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
        },
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final html = utf8.decode(response.bodyBytes, allowMalformed: true);
        if (html.contains('anomaly-modal') || html.contains('If this error persists')) {
          failReason = 'DuckDuckGo 觸發反爬蟲驗證';
        } else {
          final sources = parseDuckDuckGoHtml(html).take(4).toList();
          if (sources.isNotEmpty) {
            final summaryBuf = StringBuffer();
            for (var i = 0; i < sources.length; i++) {
              final s = sources[i];
              summaryBuf.writeln('${i + 1}. ${s.title} (${s.effectiveDomain})');
              if (s.snippet.isNotEmpty) {
                summaryBuf.writeln('   ${s.snippet}');
              }
            }
            return WebSearchOutcome(
              ok: true,
              query: cleanQuery,
              usedPeerFallback: false,
              summaryText: summaryBuf.toString().trim(),
              sources: sources,
            );
          }
          failReason = 'DuckDuckGo 未解析到有效結果';
        }
      } else {
        failReason = 'DuckDuckGo HTTP ${response.statusCode}';
      }
    } catch (e) {
      failReason = 'DuckDuckGo 連線失敗 ($e)';
    } finally {
      if (ownClient) {
        httpClient.close();
      }
    }

    // Automatic fallback to HTTP direct peer (`consult_peer`) if search failed or blocked.
    final peerOutcome = await consultPeer(
      query: cleanQuery,
      contextText: contextText,
      roomId: roomId,
      fallbackReason: failReason,
      client: client,
    );

    if (peerOutcome.ok) {
      return peerOutcome;
    }

    return WebSearchOutcome(
      ok: false,
      query: cleanQuery,
      usedPeerFallback: true,
      peerName: peerOutcome.peerName,
      summaryText: '本地聯網搜尋失敗（$failReason），轉呼叫同伴支援也尚未成功：${peerOutcome.error ?? peerOutcome.summaryText}',
      error: '$failReason | ${peerOutcome.error ?? ''}',
    );
  }

  static Future<WebSearchOutcome> consultPeer({
    required String query,
    String contextText = '',
    String roomId = 'main',
    String? fallbackReason,
    http.Client? client,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      return const WebSearchOutcome(
        ok: false,
        query: '',
        usedPeerFallback: true,
        summaryText: '請告訴我要請 Spark 參謀／同伴幫你查什麼。',
        error: 'empty query',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final customEndpoint = (prefs.getString(prefPeerEndpointKey) ?? '').trim();
    final gasUrl = (prefs.getString(_prefGasUrlKey) ?? '').trim();
    final syncToken = (prefs.getString(_prefGasTokenKey) ?? '').trim();
    final targetUrl = customEndpoint.isNotEmpty ? customEndpoint : gasUrl;

    if (targetUrl.isEmpty) {
      return WebSearchOutcome(
        ok: false,
        query: cleanQuery,
        usedPeerFallback: true,
        summaryText: '尚未設定 GAS Web App 或 Peer HTTP 網址（請先點上方 ☁️ 綁定 GAS 網址，即可一鍵直連雲端參謀）。',
        error: 'missing peer endpoint',
      );
    }

    final httpClient = client ?? http.Client();
    final ownClient = client == null;

    try {
      final uri = Uri.parse(targetUrl);
      final bodyMap = <String, dynamic>{
        'action': 'consult_peer',
        'token': syncToken,
        'query': cleanQuery,
        'context': contextText,
        'room_id': roomId,
        if (fallbackReason != null && fallbackReason.isNotEmpty)
          'fallback_reason': fallbackReason,
      };

      final decoded = await _postJsonWithGasRedirect(httpClient, uri, bodyMap);
      if (decoded['ok'] != true) {
        final err = (decoded['error'] ?? decoded['message'] ?? 'Peer 回傳失敗').toString();
        return WebSearchOutcome(
          ok: false,
          query: cleanQuery,
          usedPeerFallback: true,
          summaryText: '同伴支援回傳異常：$err',
          error: err,
        );
      }

      final reply = (decoded['reply'] ?? decoded['text'] ?? '').toString().trim();
      final peerName = (decoded['peer'] ?? 'Spark 參謀').toString().trim();
      final rawSources = decoded['sources'];
      final sources = <WebSearchSource>[];
      if (rawSources is List) {
        for (final item in rawSources) {
          if (item is Map) {
            final src = WebSearchSource.fromMap(Map<String, dynamic>.from(item));
            if (src.url.isNotEmpty) sources.add(src);
          }
        }
      }

      return WebSearchOutcome(
        ok: true,
        query: cleanQuery,
        usedPeerFallback: true,
        peerName: peerName,
        summaryText: reply.isEmpty ? '已連線 $peerName，但沒有回傳文字內容。' : reply,
        sources: sources,
      );
    } catch (e) {
      return WebSearchOutcome(
        ok: false,
        query: cleanQuery,
        usedPeerFallback: true,
        summaryText: 'HTTP 直連同伴失敗：$e',
        error: e.toString(),
      );
    } finally {
      if (ownClient) {
        httpClient.close();
      }
    }
  }

  static Future<Map<String, dynamic>> _postJsonWithGasRedirect(
    http.Client client,
    Uri uri,
    Map<String, dynamic> body,
  ) async {
    final res = await client
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 25));

    if (res.statusCode == 302 || res.statusCode == 301 || res.statusCode == 307) {
      final loc = res.headers['location'];
      if (loc != null && loc.isNotEmpty) {
        final redirected = await client
            .get(Uri.parse(loc))
            .timeout(const Duration(seconds: 25));
        if (redirected.statusCode >= 200 && redirected.statusCode < 300) {
          return jsonDecode(utf8.decode(redirected.bodyBytes)) as Map<String, dynamic>;
        }
        throw Exception('GAS redirect HTTP ${redirected.statusCode}');
      }
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw Exception('HTTP ${res.statusCode}');
  }

  /// Pure parser for DuckDuckGo HTML (`/html/`) and Lite (`/lite/`) search pages.
  static List<WebSearchSource> parseDuckDuckGoHtml(String html) {
    final results = <WebSearchSource>[];
    final seenUrls = <String>{};

    // Match `<a ... class="result__a" href="...">Title</a>`
    final linkRegex = RegExp(
      r'''<a[^>]*class=["'][^"']*result__a[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>''',
      caseSensitive: false,
      dotAll: true,
    );
    final snippetRegex = RegExp(
      r'''<a[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</a>|<div[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</div>''',
      caseSensitive: false,
      dotAll: true,
    );

    final links = linkRegex.allMatches(html).toList();
    final snippets = snippetRegex.allMatches(html).toList();

    for (var i = 0; i < links.length; i++) {
      final match = links[i];
      final rawHref = _decodeHtmlEntities(match.group(1) ?? '');
      final cleanUrl = _resolveDuckDuckGoRedirect(rawHref);
      if (cleanUrl.isEmpty ||
          cleanUrl.contains('duckduckgo.com/y.js') ||
          seenUrls.contains(cleanUrl)) {
        continue;
      }
      final title = _stripHtml(match.group(2) ?? '');
      if (title.isEmpty) continue;

      var snippet = '';
      if (i < snippets.length) {
        snippet = _stripHtml(snippets[i].group(1) ?? snippets[i].group(2) ?? '');
      }

      seenUrls.add(cleanUrl);
      results.add(WebSearchSource.fromMap({
        'title': title,
        'url': cleanUrl,
        'snippet': snippet,
      }));
    }

    // Fallback pattern for DuckDuckGo Lite (`class="result-link"`)
    if (results.isEmpty) {
      final liteRegex = RegExp(
        r'''<a[^>]*rel=["']nofollow["'][^>]*href=["']([^"']+)["'][^>]*class=["'][^"']*result-link[^"']*["'][^>]*>(.*?)</a>''',
        caseSensitive: false,
        dotAll: true,
      );
      for (final match in liteRegex.allMatches(html)) {
        final rawHref = _decodeHtmlEntities(match.group(1) ?? '');
        final cleanUrl = _resolveDuckDuckGoRedirect(rawHref);
        final title = _stripHtml(match.group(2) ?? '');
        if (cleanUrl.isNotEmpty && title.isNotEmpty && !seenUrls.contains(cleanUrl)) {
          seenUrls.add(cleanUrl);
          results.add(WebSearchSource.fromMap({'title': title, 'url': cleanUrl}));
        }
      }
    }

    return results;
  }

  static String _resolveDuckDuckGoRedirect(String rawHref) {
    var href = rawHref.trim();
    if (href.startsWith('//')) {
      href = 'https:$href';
    }
    try {
      final uri = Uri.parse(href);
      final uddg = uri.queryParameters['uddg'];
      if (uddg != null && uddg.trim().isNotEmpty) {
        return uddg.trim();
      }
      if (href.startsWith('http://') || href.startsWith('https://')) {
        return href;
      }
    } catch (_) {}
    return '';
  }

  static String _stripHtml(String raw) {
    final noTags = raw.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return _decodeHtmlEntities(noTags).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _decodeHtmlEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
  }
}
