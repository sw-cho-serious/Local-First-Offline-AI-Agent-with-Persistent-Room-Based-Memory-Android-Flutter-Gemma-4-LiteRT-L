class GpxWaypoint {
  const GpxWaypoint({
    required this.name,
    required this.lat,
    required this.lng,
    this.elevation,
    this.timeIso,
    this.note = '',
    this.kind = 'wpt',
  });

  final String name;
  final double lat;
  final double lng;
  final double? elevation;
  final String? timeIso;
  final String note;
  final String kind;

  String get coordsText => '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
  String get googleMapsUrl => 'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
}

/// Zero-dependency Garmin GPX waypoint/route/track parser.
class GpxParser {
  static final RegExp _pointBlockRegex = RegExp(
    r'<(wpt|rtept|trkpt)\b([^>]*?)(?:/>|>([\s\S]*?)</\1>)',
    caseSensitive: false,
  );
  static final RegExp _latRegex = RegExp(
    r'\blat\s*=\s*"([^"]+)"|\blat\s*=\s*'
    r"'([^']+)'",
    caseSensitive: false,
  );
  static final RegExp _lonRegex = RegExp(
    r'\blon\s*=\s*"([^"]+)"|\blon\s*=\s*'
    r"'([^']+)'",
    caseSensitive: false,
  );

  static List<GpxWaypoint> parse(String xmlContent) {
    final results = <GpxWaypoint>[];
    final seenCoords = <String>{};

    for (final match in _pointBlockRegex.allMatches(xmlContent)) {
      final kind = (match.group(1) ?? 'wpt').toLowerCase();
      final attrs = match.group(2) ?? '';
      final inner = match.group(3) ?? '';

      final latMatch = _latRegex.firstMatch(attrs);
      final lonMatch = _lonRegex.firstMatch(attrs);
      final latStr = latMatch?.group(1) ?? latMatch?.group(2);
      final lonStr = lonMatch?.group(1) ?? lonMatch?.group(2);
      final lat = latStr != null ? double.tryParse(latStr.trim()) : null;
      final lng = lonStr != null ? double.tryParse(lonStr.trim()) : null;
      if (lat == null || lng == null) continue;
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) continue;

      final rawName = _extractTag(inner, 'name');
      final rawEle = _extractTag(inner, 'ele');
      final rawTime = _extractTag(inner, 'time');
      final rawDesc = _extractTag(inner, 'desc');
      final rawCmt = _extractTag(inner, 'cmt');

      final note = [
        if (rawCmt != null && rawCmt.isNotEmpty) rawCmt,
        if (rawDesc != null && rawDesc.isNotEmpty && rawDesc != rawCmt) rawDesc,
      ].join(' / ');

      // Dedupe identical track points while always keeping named waypoints/route points.
      final key = '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
      if (kind == 'trkpt' && (rawName == null || rawName.isEmpty) && seenCoords.contains(key)) {
        continue;
      }
      seenCoords.add(key);

      final defaultName = kind == 'trkpt'
          ? '航跡點 ${results.length + 1}'
          : 'Garmin 航點 ${results.length + 1}';

      results.add(
        GpxWaypoint(
          name: (rawName != null && rawName.isNotEmpty) ? rawName : defaultName,
          lat: lat,
          lng: lng,
          elevation: rawEle != null ? double.tryParse(rawEle) : null,
          timeIso: rawTime,
          note: note,
          kind: kind,
        ),
      );
    }

    return results;
  }

  static String? _extractTag(String xml, String tag) {
    final re = RegExp(
      '<$tag(?:\\s[^>]*)?>([\\s\\S]*?)</$tag>',
      caseSensitive: false,
    );
    final m = re.firstMatch(xml);
    if (m == null) return null;
    var text = m.group(1) ?? '';
    text = text.replaceAll(RegExp(r'^<!\[CDATA\[|\]\]>$'), '');
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .trim();
    return text.isEmpty ? null : text;
  }
}
