import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CompressedImageResult {
  const CompressedImageResult({
    required this.bytes,
    required this.savedPath,
    required this.width,
    required this.height,
    required this.estimatedTokens,
  });

  final Uint8List bytes;
  final String savedPath;
  final int width;
  final int height;
  final int estimatedTokens;
}

/// Compresses field photos so their longest edge is <= 1568px JPEG (~256-512
/// Gemma vision tokens) before persisting or feeding into the 4B runtime.
class ImageCompressor {
  static const int maxEdgePx = 1568;
  static const int jpegQuality = 82;

  static Future<CompressedImageResult> compressAndSave(String sourcePath) async {
    final sourceBytes = await File(sourcePath).readAsBytes();
    final compressed = compressBytes(sourceBytes);

    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory(p.join(appDir.path, 'xiaoliu_photos'));
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }

    final fileName = 'img_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final targetPath = p.join(photosDir.path, fileName);
    await File(targetPath).writeAsBytes(compressed.bytes, flush: true);

    return CompressedImageResult(
      bytes: compressed.bytes,
      savedPath: targetPath,
      width: compressed.width,
      height: compressed.height,
      estimatedTokens: compressed.estimatedTokens,
    );
  }

  /// Pure byte-level resize/compress helper, safe for unit tests without path_provider.
  static ({Uint8List bytes, int width, int height, int estimatedTokens})
  compressBytes(Uint8List sourceBytes) {
    final decoded = img.decodeImage(sourceBytes);
    if (decoded == null) {
      throw const FormatException('無法解析圖片格式');
    }

    final oriented = img.bakeOrientation(decoded);
    final longEdge = oriented.width > oriented.height
        ? oriented.width
        : oriented.height;

    final resized = longEdge > maxEdgePx
        ? (oriented.width >= oriented.height
            ? img.copyResize(oriented, width: maxEdgePx)
            : img.copyResize(oriented, height: maxEdgePx))
        : oriented;

    final encoded = Uint8List.fromList(
      img.encodeJpg(resized, quality: jpegQuality),
    );

    // Gemma 4 visual encoding uses ~256-512 tokens depending on resolution.
    final areaRatio = (resized.width * resized.height) / (maxEdgePx * maxEdgePx);
    final estTokens = (256 + (256 * areaRatio)).round().clamp(256, 512);

    return (
      bytes: encoded,
      width: resized.width,
      height: resized.height,
      estimatedTokens: estTokens,
    );
  }
}
