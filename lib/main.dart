import 'dart:async';

import 'package:flutter/material.dart';

import 'data/database_helper.dart';
import 'data/models.dart';
import 'engine/gemma_litert_engine.dart';
import 'sync/cloud_sync_service.dart';
import 'tools/native_actions.dart';
import 'tools/tool_registry.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/setup_gate_screen.dart';
import 'ui/widgets/spirit_avatar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final db = DatabaseHelper.instance;
  final syncService = CloudSyncService(db);
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
      await NativeActions.initialize();
    } catch (e) {
      debugPrint('[Boot] NativeActions.initialize error: $e');
    }

    try {
      await widget.db.seedIfNeeded();
    } catch (e) {
      debugPrint('[Boot] seedIfNeeded error: $e');
    }

    unawaited(widget.syncService.syncOnStartupIfConfigured());

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

class _BootSplashScreen extends StatefulWidget {
  const _BootSplashScreen();

  @override
  State<_BootSplashScreen> createState() => _BootSplashScreenState();
}

class _BootSplashScreenState extends State<_BootSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _bounce;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _bounce = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111317),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _bounce,
              builder: (context, child) {
                final dy = -14.0 * _bounce.value;
                final shadowScale = 1.0 - (0.28 * _bounce.value);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.translate(
                      offset: Offset(0, dy),
                      child: child,
                    ),
                    const SizedBox(height: 6),
                    Transform.scale(
                      scaleX: shadowScale,
                      scaleY: shadowScale,
                      child: Container(
                        width: 44,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ],
                );
              },
              child: const SpiritAvatar(
                colorHex: '#3A4150',
                state: SpiritState.idle,
                size: 78,
                isMain: true,
                accessory: 'main',
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '正在喚醒 KODARI…',
              style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
