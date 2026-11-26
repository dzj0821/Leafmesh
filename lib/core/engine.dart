import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'api.dart';

class EngineHost {
  EngineHost(this.supportPath);
  final String supportPath;
  static const _channel = MethodChannel('app.leafmesh/platform');
  Process? _process;
  IOSink? _log;
  CoreApi? api;
  final List<String> recentLog = [];
  bool running = false;

  Future<CoreApi> start() async {
    if (running && api != null) return api!;
    await Directory(supportPath).create(recursive: true);
    final secretFile = File(p.join(supportPath, 'core-secret.json'));
    String key;
    if (await secretFile.exists()) {
      key =
          (jsonDecode(await secretFile.readAsString()) as Map)['key'] as String;
    } else {
      key = base64UrlEncode(
        List.generate(32, (_) => Random.secure().nextInt(256)),
      );
      await secretFile.writeAsString(jsonEncode({'key': key}), flush: true);
    }
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var port = socket.port;
    await socket.close();
    if (Platform.isAndroid) {
      final activePort = await _channel.invokeMethod<num>('startCore', {
        'home': p.join(supportPath, 'core'),
        'port': port,
        'key': key,
      });
      port = activePort?.toInt() ?? port;
    } else if (Platform.isWindows) {
      final binary = await _windowsBinary();
      final home = p.join(supportPath, 'core');
      await Directory(home).create(recursive: true);
      if (!await File(p.join(home, 'config.xml')).exists()) {
        final result = await Process.run(
          binary,
          ['generate', '--home=$home'],
          environment: {'STNOUPGRADE': '1'},
          runInShell: false,
        );
        if (result.exitCode != 0) {
          throw StateError('初始化同步核心失败：${result.stderr} ${result.stdout}');
        }
      }
      final logFile = File(p.join(supportPath, 'core.log'));
      if (await logFile.exists() && await logFile.length() > 4 * 1024 * 1024) {
        await logFile.copy('${logFile.path}.previous');
        await logFile.writeAsString('');
      }
      _log = logFile.openWrite(mode: FileMode.append);
      _process = await Process.start(
        binary,
        [
          'serve',
          '--home=$home',
          '--no-browser',
          '--no-restart',
          '--no-upgrade',
          '--log-file=-',
        ],
        environment: {
          'STGUIADDRESS': 'http://127.0.0.1:$port',
          'STGUIAPIKEY': key,
          'STNOUPGRADE': '1',
          'STVERSIONEXTRA': 'leafmesh',
        },
        mode: ProcessStartMode.normal,
        runInShell: false,
      );
      void consume(String line) {
        final redacted = line.replaceAll(key, '[redacted]');
        recentLog.add(redacted);
        if (recentLog.length > 40) recentLog.removeAt(0);
        _log?.writeln(redacted);
      }

      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(consume);
      _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(consume);
      unawaited(
        _process!.exitCode.then((_) {
          running = false;
        }),
      );
    } else {
      throw UnsupportedError('本期仅支持 Windows 和 Android');
    }
    final candidate = CoreApi(port, key);
    for (var i = 0; i < 120; i++) {
      try {
        await candidate.get('system/ping');
        api = candidate;
        running = true;
        // The host application owns updates; never let the embedded core replace itself.
        await candidate.request(
          'PATCH',
          'config/options',
          body: {
            'startBrowser': false,
            'autoUpgradeIntervalH': 0,
            'urAccepted': -1,
          },
        );
        return candidate;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    candidate.close();
    await stop();
    throw StateError('同步核心未能启动。${recentLog.take(5).join('\n')}');
  }

  Future<String> _windowsBinary() async {
    final candidates = [
      p.join(p.dirname(Platform.resolvedExecutable), 'core', 'syncthing.exe'),
      p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'assets',
        'core',
        'syncthing.exe',
      ),
      p.join(Directory.current.path, 'assets', 'core', 'syncthing.exe'),
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    // Asset extraction also supports nonstandard development working directories.
    try {
      final bytes = await rootBundle.load('assets/core/syncthing.exe');
      final target = File(p.join(supportPath, 'syncthing.exe'));
      await target.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return target.path;
    } catch (_) {
      throw StateError(
        '安装包缺少 Syncthing 核心。开发环境请运行 python tool/bootstrap.py --core。',
      );
    }
  }

  Future<void> setBackground(bool enabled) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('setBackground', {'enabled': enabled});
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('stopCore');
    } else if (_process != null) {
      try {
        await api?.request('POST', 'system/shutdown');
      } catch (_) {
        /* already stopped */
      }
      try {
        await _process!.exitCode.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        _process!.kill();
      }
      _process = null;
    }
    api?.close();
    api = null;
    final log = _log;
    _log = null;
    await log?.close();
    running = false;
  }
}
