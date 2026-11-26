import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'app_controller.dart';
import 'ui/home.dart';
import 'storage/native_bridge.dart';
import 'desktop_updates.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NativeBridge.handler = (method, values) =>
      const MethodChannel('app.leafmesh/platform').invokeMethod(method, values);
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Syncthing',
    ], await rootBundle.loadString('assets/core/LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      'CodeMirror and editor dependencies',
    ], await rootBundle.loadString('assets/editor/THIRD_PARTY_LICENSES.txt'));
  });
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Leafmesh · 文件与灵感',
        size: Size(1140, 780),
        minimumSize: Size(720, 540),
        center: true,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  runApp(const LeafmeshApp());
}

class LeafmeshApp extends StatefulWidget {
  const LeafmeshApp({super.key, this.controller});
  final AppController? controller;
  @override
  State<LeafmeshApp> createState() => _LeafmeshAppState();
}

class _LeafmeshAppState extends State<LeafmeshApp> {
  late final app = widget.controller ?? AppController();
  DesktopUpdates? updates;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await app.initialize();
    if (Platform.isWindows &&
        mounted &&
        app.error == null &&
        widget.controller == null) {
      updates = DesktopUpdates(
        prepare: () async {
          await app.prepareForUpdate();
          await app.shutdown();
        },
        exit: windowManager.destroy,
      );
      try {
        await updates!.start();
      } catch (_) {
        await updates!.close();
      }
    }
  }

  @override
  void dispose() {
    updates?.close();
    app.dispose();
    super.dispose();
  }

  ThemeData theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff27766c),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xfff7f8f6)
        : const Color(0xff121917),
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'sans-serif',
    ],
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      filled: true,
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Leafmesh',
    debugShowCheckedModeBanner: false,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    home: HomePage(app: app),
  );
}
