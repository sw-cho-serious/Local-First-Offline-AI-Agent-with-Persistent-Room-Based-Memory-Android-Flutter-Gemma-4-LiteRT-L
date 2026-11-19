import '../data/database_helper.dart';
import '../data/models.dart';
import 'native_actions.dart';

/// V2 Batch 2: Zero-compute local routine scheduler (once / daily / weekly / cron)
/// with deterministic "next 3 trigger times" preview. Never wakes the 4B LLM.
class RoutineScheduler {
  static const List<String> _weekdaysZh = ['一', '二', '三', '四', '五', '六', '日'];

  static List<DateTime> computeNextOccurrences(
    RoutineRecord routine, {
    DateTime? from,
    int count = 3,
  }) {
    final base = from ?? DateTime.now();
    if (count <= 0) return const [];

    switch (routine.mode) {
      case 'once':
        final dt = _parseOnceDateTime(routine.timeSpec, base);
        if (dt == null || !dt.isAfter(base)) return const [];
        return [dt];

      case 'daily':
        final (hour, minute) = _parseHourMinute(routine.timeSpec);
        final out = <DateTime>[];
        var candidate = DateTime(base.year, base.month, base.day, hour, minute);
        if (!candidate.isAfter(base)) {
          candidate = candidate.add(const Duration(days: 1));
        }
        for (var i = 0; i < count; i++) {
          out.add(candidate.add(Duration(days: i)));
        }
        return out;

      case 'weekly':
        final (hour, minute) = _parseHourMinute(routine.timeSpec);
        final allowedDays = routine.weekdays.toSet();
        final out = <DateTime>[];
        for (var offset = 0; offset < 60 && out.length < count; offset++) {
          final day = DateTime(base.year, base.month, base.day, hour, minute)
              .add(Duration(days: offset));
          if (day.isAfter(base) && allowedDays.contains(day.weekday)) {
            out.add(day);
          }
        }
        return out;

      case 'cron':
        return _computeCronOccurrences(routine.timeSpec, base, count);

      default:
        return const [];
    }
  }

  static List<String> formatNextOccurrencesPreview(
    RoutineRecord routine, {
    DateTime? from,
    int count = 3,
  }) {
    final dates = computeNextOccurrences(routine, from: from, count: count);
    if (dates.isEmpty) return const ['（已過期或無未來排程時間）'];
    return dates.map(formatCompactDateTime).toList();
  }

  static String formatCompactDateTime(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final w = _weekdaysZh[dt.weekday - 1];
    return '${dt.month}/${dt.day} ($w) $hh:$mm';
  }

  static Future<int> syncEnabledRoutinesToSystem(DatabaseHelper db) async {
    final routines = await db.getRoutines(onlyEnabled: true);
    var scheduledCount = 0;
    final now = DateTime.now();
    for (final routine in routines) {
      final nextList = computeNextOccurrences(routine, from: now, count: 1);
      if (nextList.isEmpty) continue;
      await NativeActions.scheduleReminder(
        title: '⏰ ${routine.title}',
        body: routine.body.isEmpty ? 'KODARI 零算力日常排程提醒' : routine.body,
        triggerTime: nextList.first,
      );
      scheduledCount++;
    }
    return scheduledCount;
  }

  static (int, int) _parseHourMinute(String spec) {
    final m = RegExp(r'(\d{1,2})\s*[:：點時]\s*(\d{1,2})?').firstMatch(spec.trim());
    if (m != null) {
      final h = (int.tryParse(m.group(1)!) ?? 8).clamp(0, 23);
      final min = (int.tryParse(m.group(2) ?? '0') ?? 0).clamp(0, 59);
      return (h, min);
    }
    return (8, 0);
  }

  static DateTime? _parseOnceDateTime(String spec, DateTime base) {
    final s = spec.trim();
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso;
    final mDate = RegExp(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})\s+(\d{1,2}):(\d{1,2})').firstMatch(s);
    if (mDate != null) {
      return DateTime(
        int.parse(mDate.group(1)!),
        int.parse(mDate.group(2)!),
        int.parse(mDate.group(3)!),
        int.parse(mDate.group(4)!).clamp(0, 23),
        int.parse(mDate.group(5)!).clamp(0, 59),
      );
    }
    final (h, min) = _parseHourMinute(s);
    var dt = DateTime(base.year, base.month, base.day, h, min);
    if (!dt.isAfter(base)) {
      dt = dt.add(const Duration(days: 1));
    }
    return dt;
  }

  static List<DateTime> _computeCronOccurrences(
    String expr,
    DateTime from,
    int count,
  ) {
    final parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length < 5) return const [];

    final minutes = _expandCronField(parts[0], 0, 59);
    final hours = _expandCronField(parts[1], 0, 23);
    final days = _expandCronField(parts[2], 1, 31);
    final months = _expandCronField(parts[3], 1, 12);
    final rawDows = _expandCronField(parts[4], 0, 7);
    if (minutes.isEmpty || hours.isEmpty || days.isEmpty || months.isEmpty || rawDows.isEmpty) {
      return const [];
    }
    // Map Cron Sunday (0 or 7) -> Dart DateTime.sunday (7)
    final dows = rawDows.map((d) => d == 0 ? 7 : d).toSet();
    final domWildcard = parts[2].trim() == '*';
    final dowWildcard = parts[4].trim() == '*';

    final out = <DateTime>[];
    final sortedHours = hours.toList()..sort();
    final sortedMinutes = minutes.toList()..sort();

    // Scan up to 366 days ahead efficiently (iterating days × matched hours × minutes)
    for (var dayOffset = 0; dayOffset < 366 && out.length < count; dayOffset++) {
      final date = DateTime(from.year, from.month, from.day).add(Duration(days: dayOffset));
      if (!months.contains(date.month)) continue;

      final domMatch = days.contains(date.day);
      final dowMatch = dows.contains(date.weekday);
      final dayOk = (domWildcard && dowWildcard) ||
          (domWildcard && dowMatch) ||
          (dowWildcard && domMatch) ||
          (!domWildcard && !dowWildcard && (domMatch || dowMatch));
      if (!dayOk) continue;

      for (final h in sortedHours) {
        if (out.length >= count) break;
        for (final m in sortedMinutes) {
          final candidate = DateTime(date.year, date.month, date.day, h, m);
          if (candidate.isAfter(from)) {
            out.add(candidate);
            if (out.length >= count) break;
          }
        }
      }
    }
    return out;
  }

  static Set<int> _expandCronField(String field, int minVal, int maxVal) {
    final result = <int>{};
    final f = field.trim();
    if (f.isEmpty) return result;

    for (final segment in f.split(',')) {
      final part = segment.trim();
      if (part.isEmpty) continue;

      var step = 1;
      var rangeExpr = part;
      if (part.contains('/')) {
        final slashParts = part.split('/');
        rangeExpr = slashParts[0];
        step = (int.tryParse(slashParts[1]) ?? 1).clamp(1, maxVal - minVal + 1);
      }

      if (rangeExpr == '*') {
        for (var v = minVal; v <= maxVal; v += step) {
          result.add(v);
        }
      } else if (rangeExpr.contains('-')) {
        final bounds = rangeExpr.split('-');
        final start = (int.tryParse(bounds[0]) ?? minVal).clamp(minVal, maxVal);
        final end = (int.tryParse(bounds[1]) ?? maxVal).clamp(minVal, maxVal);
        for (var v = start; v <= end; v += step) {
          result.add(v);
        }
      } else {
        final exact = int.tryParse(rangeExpr);
        if (exact != null && exact >= minVal && exact <= maxVal) {
          result.add(exact);
        }
      }
    }
    return result;
  }
}
