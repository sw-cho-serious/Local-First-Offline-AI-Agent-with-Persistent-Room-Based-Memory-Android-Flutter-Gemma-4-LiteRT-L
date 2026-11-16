import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../engine/gemma_litert_engine.dart';
import '../widgets/spirit_avatar.dart';

class SetupGateScreen extends StatefulWidget {
  const SetupGateScreen({
    super.key,
    required this.engine,
    required this.onReadyToEnterHome,
  });

  final GemmaLiteRtEngine engine;
  final VoidCallback onReadyToEnterHome;

  @override
  State<SetupGateScreen> createState() => _SetupGateScreenState();
}

class _SetupGateScreenState extends State<SetupGateScreen> {
  bool _busy = false;
  int _progress = 0;
  String _statusText = '尚未在手機 Download 目錄偵測到 gemma-4-E4B-it.litertlm (3.7 GB)';

  Future<void> _pickLocalFile() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '選取 gemma-4-E4B-it.litertlm',
      type: FileType.any,
    );
    final path = picked?.path;
    if (path == null) return;

    setState(() {
      _busy = true;
      _statusText = '正在掛載模型並初始化 LiteRT-LM 單例引擎...';
    });
    try {
      await widget.engine.installFromFilePath(path);
      if (mounted) widget.onReadyToEnterHome();
    } catch (e) {
      setState(() {
        _busy = false;
        _statusText = '載入失敗：$e';
      });
    }
  }

  Future<void> _downloadCatalog() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _statusText = '正在從官方 Catalog 下載 Gemma-4-E4B-it.litertlm...';
    });
    try {
      await widget.engine.installFromCatalog(
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progress = p;
              _statusText = '下載中：$p%';
            });
          }
        },
      );
      if (mounted) widget.onReadyToEnterHome();
    } catch (e) {
      setState(() {
        _busy = false;
        _statusText = '下載失敗：$e';
      });
    }
  }

  void _enterFallbackPreview() {
    widget.engine.enableFallbackMode();
    widget.onReadyToEnterHome();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111317),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SpiritAvatar(
                    colorHex: '#3A4150',
                    state: _busy ? SpiritState.working : SpiritState.waiting,
                    size: 86,
                    isMain: true,
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'HAKO • KODARI 離線戰地分身',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '請匯入本機 gemma-4-E4B-it.litertlm（放進 /sdcard/Download/ 下次開啟就會一秒直達大廳）。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF), height: 1.5),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF16191F),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          _statusText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12.5, color: Color(0xFFD1D5DB)),
                        ),
                        if (_busy) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: _progress > 0 ? _progress / 100.0 : null,
                            color: const Color(0xFFF59E0B),
                            backgroundColor: const Color(0xFF262930),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.folder_open),
                      label: const Text('手動選取本機 .litertlm 檔案'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        foregroundColor: const Color(0xFF111317),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _busy ? null : _pickLocalFile,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('從官方下載 Gemma-4-E4B-it (3.7 GB)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFE5E7EB),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _busy ? null : _downloadCatalog,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: _busy ? null : _enterFallbackPreview,
                    child: const Text(
                      '先用「離線查表 / 預覽模式」進首頁 →',
                      style: TextStyle(color: Color(0xFFFCD34D), fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
