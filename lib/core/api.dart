import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'models.dart';

class CoreApiException implements Exception {
  CoreApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'Syncthing ($status)：$message';
}

class CoreApi {
  CoreApi(this.port, this.apiKey, {http.Client? client})
    : _client = client ?? IOClient(HttpClient()..findProxy = (_) => 'DIRECT');
  final int port;
  final String apiKey;
  final http.Client _client;
  bool _closed = false;
  final Set<void Function()> _stopEvents = {};

  Future<dynamic> request(
    String method,
    String path, {
    Json? query,
    Object? body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (_closed) throw StateError('同步核心连接已关闭');
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/rest/$path',
      queryParameters: query?.map((k, v) => MapEntry(k, '$v')),
    );
    final req = http.Request(method, uri);
    req.headers['X-API-Key'] = apiKey;
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(req).timeout(timeout),
    ).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      throw CoreApiException(
        response.statusCode,
        text.length > 500 ? text.substring(0, 500) : text,
      );
    }
    if (response.bodyBytes.isEmpty) return null;
    final text = utf8.decode(response.bodyBytes);
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  Future<Json> get(String path, {Json? query}) async =>
      Map<String, dynamic>.from(
        await request('GET', path, query: query) as Map,
      );

  Future<List<dynamic>> list(String path, {Json? query}) async =>
      (await request('GET', path, query: query) as List?) ?? [];

  Future<void> pair(String input, String name) async {
    final id = normalizeDeviceId(input);
    // Let the actual core check the Luhn32 check digits too.
    await get('svc/deviceid', query: {'id': id});
    final existing = await list('config/devices');
    if (existing.any((e) => e['deviceID'] == id)) {
      throw StateError('该设备已经在列表中');
    }
    final device = await get('config/defaults/device');
    device.addAll({
      'deviceID': id,
      'name': name.trim(),
      'addresses': ['dynamic'],
      'introducer': false,
      'autoAcceptFolders': false,
    });
    await request('POST', 'config/devices', body: device);
  }

  Future<void> scan(String id, {String? sub}) async {
    await request('POST', 'db/scan', query: {'folder': id, 'sub': ?sub});
  }

  Future<void> pause(String id, bool value) async {
    await request('PATCH', 'config/folders/$id', body: {'paused': value});
  }

  Stream<Json> events() {
    final eventApi = CoreApi(port, apiKey);
    late StreamController<Json> stream;
    var stopped = false;
    Timer? retry;
    Completer<void>? sleeping;
    void stop() {
      stopped = true;
      eventApi.close();
      retry?.cancel();
      if (sleeping != null && !sleeping!.isCompleted) sleeping!.complete();
      _stopEvents.remove(stop);
    }

    Future<void> pump() async {
      var since = 0;
      var delay = 1;
      try {
        while (!_closed && !stopped) {
          try {
            final result = await eventApi.request(
              'GET',
              'events',
              query: {
                'since': since,
                'timeout': 20,
                'events':
                    'StateChanged,FolderSummary,DeviceConnected,DeviceDisconnected,FolderCompletion,FolderErrors,PendingDevicesChanged,PendingFoldersChanged,ConfigSaved,ItemFinished',
              },
              timeout: const Duration(seconds: 28),
            );
            if (stopped) break;
            for (final event in (result as List? ?? [])) {
              final item = Json.from(event as Map);
              since = (item['id'] as num).toInt();
              stream.add(item);
            }
            delay = 1;
          } catch (error) {
            if (_closed || stopped) break;
            stream.add({
              'type': 'ConnectionError',
              'data': {'message': error.toString()},
            });
            since = 0;
            sleeping = Completer<void>();
            retry = Timer(Duration(seconds: delay), () => sleeping?.complete());
            await sleeping!.future;
            sleeping = null;
            delay = (delay * 2).clamp(1, 20);
          }
        }
      } finally {
        stop();
        await stream.close();
      }
    }

    stream = StreamController<Json>(
      onListen: () => unawaited(pump()),
      onCancel: stop,
    );
    _stopEvents.add(stop);
    return stream.stream;
  }

  void close() {
    _closed = true;
    for (final stop in _stopEvents.toList()) {
      stop();
    }
    _client.close();
  }
}
