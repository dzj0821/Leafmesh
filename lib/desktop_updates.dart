import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'build_info.dart';

/// Local updater handshake: flush documents and stop the core before exiting.
class DesktopUpdates {
  DesktopUpdates({required this.prepare, required this.exit, String? directory})
    : directory = directory ?? p.dirname(Platform.resolvedExecutable);
  final Future<void> Function() prepare;
  final Future<void> Function() exit;
  final String directory;
  HttpServer? _server;
  bool _closing = false;
  final _token = base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  late final descriptor = File(p.join(directory, '.leafmesh-update-$pid.json'));

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      request.response.persistentConnection = false;
      if (request.headers.value('X-Leafmesh-Update-Key') != _token) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/prepare-update') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (_closing) {
        request.response.statusCode = HttpStatus.conflict;
        await request.response.close();
        return;
      }
      _closing = true;
      try {
        await prepare();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ready': true, 'pid': pid}));
        await request.response.close();
      } catch (_) {
        _closing = false;
        request.response.statusCode = HttpStatus.conflict;
        request.response.write('应用仍在保存文档或迁移文件，暂不能退出更新。');
        await request.response.close();
        return;
      }
      await close();
      await exit();
    });
    await descriptor.writeAsString(
      jsonEncode({
        'pid': pid,
        'executable': Platform.resolvedExecutable,
        'port': _server!.port,
        'token': _token,
        'version': BuildInfo.version,
      }),
      flush: true,
    );
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (await descriptor.exists()) await descriptor.delete();
  }
}
