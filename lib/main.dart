import 'dart:async';

import 'package:flutter/material.dart';

import 'data/database_helper.dart';
import 'engine/gemma_litert_engine.dart';
import 'sync/cloud_sync_service.dart';
import 'tools/native_actions.dart';
import 'tools/tool_registry.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/setup_gate_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NativeActions.initialize();

  final db = DatabaseHelper.instance;
  await db.seedIfNeeded();

  final syncService = CloudSyncService(db);
  unawaited(syncService.syncOnStartupIfConfigured());

  final tools = ToolRegistry(db);
  final engine = GemmaLiteRtEngine(db: db, toolRegistry: tools);

  runApp(XiaoLiuApp(db: db, engine: engine, syncService: syncService));
}

class XiaoLiuApp extends StatefulWidget {
  const XiaoLiuApp({
    super.key,
    required this.db,
    required this.engine,
    required this.syncService,
  });

  final DatabaseHelper db;
  final GemmaLiteRtEngine engine;
  final CloudSyncService syncService;

  @override
  State<XiaoLiuApp> createState() => _XiaoLiuAppState();
}

class _XiaoLiuAppState extends State<XiaoLiuApp> {
  bool _booting = true;
  bool _showHome = false;

  @override
  void initState() {
    super.initState();
    _silentBootstrap();
  }

  Future<void> _silentBootstrap() async {
    try {
      await widget.engine.initializeEngine();
    } catch (e) {
      debugPrint('[Boot] initializeEngine error: $e');
    }
    if (!mounted) return;
    setState(() {
      _booting = false;
      _showHome = widget.engine.isModelReady;
    });
  }

  @override
  void dispose() {
    widget.syncService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HAKO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF111317),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFF59E0B),
          surface: Color(0xFF16191F),
        ),
      ),
      home: _booting
          ? const _BootSplashScreen()
          : (_showHome
              ? HomeScreen(
                  db: widget.db,
                  engine: widget.engine,
                  syncService: widget.syncService,
                )
              : SetupGateScreen(
                  engine: widget.engine,
                  onReadyToEnterHome: () => setState(() => _showHome = true),
                )),
    );
  }
}

class _BootSplashScreen extends StatelessWidget {
  const _BootSplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF111317),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFF59E0B)),
            SizedBox(height: 16),
            Text(
              '正在喚醒 KODARI…',
              style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
