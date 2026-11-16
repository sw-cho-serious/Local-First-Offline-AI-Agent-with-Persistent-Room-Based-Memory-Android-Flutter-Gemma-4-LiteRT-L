/// Lightweight local token estimator for Gemma 4 (3,072-token context budget).
class TokenEstimator {
  static const int maxContextTokens = 3072;

  /// Estimates tokens without model compute:
  /// - CJK / non-ASCII chars ~= 1.8 tokens/char
  /// - ASCII chars ~= 0.35 tokens/char
  static int estimateTextTokens(String text) {
    if (text.isEmpty) return 0;
    var nonAscii = 0;
    var ascii = 0;
    for (final code in text.runes) {
      if (code <= 0x7F) {
        ascii++;
      } else {
        nonAscii++;
      }
    }
    return (nonAscii * 1.8 + ascii * 0.35).round();
  }

  /// Estimates active prompt context tokens (Traits + room notes + summary + replay messages + images).
  static int estimateContextTokens({
    required Iterable<String> traitTexts,
    required String roomNotes,
    required String rollingSummary,
    required Iterable<({String content, bool hasImage})> activeMessages,
  }) {
    var total = 220; // System framing & tool schema overhead
    for (final t in traitTexts) {
      total += estimateTextTokens(t);
    }
    total += estimateTextTokens(roomNotes);
    total += estimateTextTokens(rollingSummary);
    for (final m in activeMessages) {
      total += estimateTextTokens(m.content);
      if (m.hasImage) total += 400;
    }
    return total;
  }

  static String formatCompact(int tokens) {
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}k';
    }
    return '$tokens';
  }
}
