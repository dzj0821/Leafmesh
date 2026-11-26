import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/api.dart';
import 'core/engine.dart';
import 'core/models.dart';
import 'storage/repository.dart';

class AppController extends ChangeNotifier {
  AppController({this.supportPathOverride});
  final String? supportPathOverride;
  final Set<Future<void> Function()> documentFlushers = {};
  late EngineHost host;
  late CoreApi api;
  late SharedPreferences preferences;
  late DraftStore drafts;
  String supportPath = '';
  bool starting = true;
  bool busy = false;
  bool online = false;
  bool editorMargins = true;
  String? error;
  String myId = '';
  String coreVersion = '';
  List<SyncFolder> folders = [];
  List<PeerDevice> peers = [];
  List<FolderOffer> offers = [];
  Json pendingDevices = {};
  String? selectedId;
  StreamSubscription<Json>? _events;
  Timer? _refreshTimer;
  Timer? _eventTimer;
  bool _refreshing = false;
  bool _disposed = false;
  final StreamController<Json> fileChanges = StreamController.broadcast();
  SyncFolder? get selected {
    for (final folder in folders) {
      if (folder.id == selectedId) return folder;
    }
    return folders.isEmpty ? null : folders.first;
  }

  bool get background => preferences.getBool('background') ?? false;

  Future<void> setEditorMargins(bool value) async {
    await preferences.setBool('editorMargins', value);
    editorMargins = value;
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    starting = true;
    error = null;
    notifyListeners();
    try {
      supportPath =
          supportPathOverride ?? (await getApplicationSupportDirectory()).path;
      preferences = await SharedPreferences.getInstance();
      editorMargins = preferences.getBool('editorMargins') ?? true;
      selectedId = preferences.getString('selectedFolder');
      drafts = DraftStore(p.join(supportPath, 'drafts'));
      host = EngineHost(supportPath);
      api = await host.start();
      if (Platform.isAndroid && (preferences.getBool('background') ?? false)) {
        try {
          await host.setBackground(true);
        } catch (_) {
          await preferences.setBool('background', false);
        }
      }
      final info = await api.get('system/status');
      myId = info['myID'] as String;
      coreVersion = (await api.get('system/version'))['version'] as String;
      await refresh();
      _events = api.events().listen(_onEvent);
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(refresh()),
      );
      online = true;
    } catch (e) {
      error = e.toString();
    } finally {
      starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    try {
      final values = await Future.wait([
        api.list('config/folders'),
        api.list('config/devices'),
        api.get('system/connections'),
        api.get('cluster/pending/folders'),
        api.get('cluster/pending/devices'),
      ]);
      final connections = (values[2] as Json)['connections'] as Map? ?? {};
      peers = (values[1] as List)
          .map(
            (e) => PeerDevice(
              Json.from(e as Map),
              Json.from(connections[e['deviceID']] as Map? ?? {}),
            ),
          )
          .where((d) => d.id != myId)
          .toList();
      final newFolders = <SyncFolder>[];
      for (final raw in values[0] as List) {
        final config = Json.from(raw as Map);
        Json status;
        try {
          status = await api.get('db/status', query: {'folder': config['id']});
        } catch (_) {
          status = {'state': config['paused'] == true ? 'paused' : 'error'};
        }
        newFolders.add(SyncFolder(config, status));
      }
      folders = newFolders;
      final offered = values[3] as Json;
      offers = offered.entries
          .map((e) {
            final by = Json.from((e.value as Map)['offeredBy'] as Map? ?? {});
            final usable = by.entries
                .where(
                  (item) =>
                      (item.value as Map)['receiveEncrypted'] != true &&
                      (item.value as Map)['remoteEncrypted'] != true,
                )
                .toList();
            return FolderOffer(
              e.key,
              usable.isEmpty
                  ? e.key
                  : ((usable.first.value as Map)['label'] as String? ?? e.key),
              usable.map((e) => e.key).toList(),
            );
          })
          .where((e) => e.deviceIds.isNotEmpty)
          .toList();
      pendingDevices = values[4] as Json;
      if (selectedId == null || !folders.any((f) => f.id == selectedId)) {
        selectedId = folders.isEmpty ? null : folders.first.id;
      }
      online = true;
      error = null;
    } catch (e) {
      online = false;
      error = e.toString();
    } finally {
      _refreshing = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _onEvent(Json event) {
    if (_disposed) return;
    final type = event['type'];
    if (type == 'ConnectionError') {
      online = false;
      notifyListeners();
      return;
    }
    online = true;
    if (type == 'FolderSummary') {
      final data = Json.from(event['data'] as Map);
      folders = folders
          .map(
            (folder) => folder.id == data['folder']
                ? folder.withStatus(Json.from(data['summary'] as Map))
                : folder,
          )
          .toList();
      notifyListeners();
    }
    if (type == 'StateChanged' || type == 'ItemFinished') {
      fileChanges.add(event);
    }
    if (_eventTimer?.isActive != true) {
      _eventTimer = Timer(
        const Duration(milliseconds: 700),
        () => unawaited(refresh()),
      );
    }
  }

  Future<void> select(String id) async {
    selectedId = id;
    await preferences.setString('selectedFolder', id);
    notifyListeners();
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) throw StateError('另一个操作正在进行');
    busy = true;
    notifyListeners();
    try {
      await action();
      await refresh();
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> pair(String id, String name) =>
      perform(() => api.pair(id, name));

  Future<String> managedPath(String id) async {
    final safeId = sha256.convert(utf8.encode(id)).toString().substring(0, 24);
    final target = Directory(p.join(supportPath, 'folders', safeId));
    await target.create(recursive: true);
    return target.path;
  }

  Future<void> addFolder({
    required String label,
    required List<String> devices,
    String? location,
    bool saf = false,
    FolderOffer? offer,
  }) => perform(() async {
    final id =
        offer?.id ??
        'qj-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0xFFFFFF).toRadixString(16)}';
    final path = location ?? await managedPath(id);
    if (saf) {
      final items = await FolderStorage(path, saf: true).list('');
      if (offer != null && items.isNotEmpty) {
        throw StateError('接受共享时请选择空目录，避免将已有内容意外合并');
      }
    } else {
      final absolute = p.normalize(p.absolute(path));
      for (final existing in folders.where(
        (e) => e.config['filesystemType'] != 'leafmeshsaf',
      )) {
        final other = p.normalize(p.absolute(existing.path));
        if (p.equals(absolute, other) ||
            p.isWithin(absolute, other) ||
            p.isWithin(other, absolute)) {
          throw StateError('该目录与现有共享文件夹重叠');
        }
      }
      if (p.equals(absolute, supportPath) ||
          p.isWithin(absolute, supportPath) ||
          p.isWithin(p.join(supportPath, 'core'), absolute)) {
        throw StateError('不能共享应用配置或核心数据目录');
      }
      final directory = Directory(path);
      if (!await directory.exists()) throw StateError('目录不存在');
      if (offer != null && await directory.list().isEmpty == false) {
        throw StateError('接受共享时请选择空目录');
      }
    }
    final config = await api.get('config/defaults/folder');
    config.addAll({
      'id': id,
      'label': label.trim().isEmpty ? id : label.trim(),
      'path': path,
      'filesystemType': saf ? 'leafmeshsaf' : 'basic',
      'type': 'sendreceive',
      'paused': false,
      'rescanIntervalS': saf ? 30 : 300,
      'fsWatcherEnabled': !saf,
      'fsWatcherDelayS': 1,
      'ignorePerms': Platform.isAndroid,
      'devices': {myId, ...devices}.map((id) => {'deviceID': id}).toList(),
    });
    await api.request('POST', 'config/folders', body: config);
    selectedId = id;
    await preferences.setString('selectedFolder', id);
  });

  Future<void> updateSharing(SyncFolder folder, List<String> deviceIds) =>
      perform(() async {
        await api.request(
          'PATCH',
          'config/folders/${folder.id}',
          body: {
            'devices': {
              myId,
              ...deviceIds,
            }.map((id) => {'deviceID': id}).toList(),
          },
        );
      });

  Future<void> togglePause(SyncFolder folder) =>
      perform(() => api.pause(folder.id, !folder.paused));
  Future<String> readIgnores(String id) async {
    final result = await api.get('db/ignores', query: {'folder': id});
    return (result['ignore'] as List? ?? []).join('\n');
  }

  Future<void> saveIgnores(String id, String value) => perform(() async {
    final response = await api.request(
      'POST',
      'db/ignores',
      query: {'folder': id},
      body: {'ignore': const LineSplitter().convert(value)},
    );
    if (response is Map &&
        response['error'] is String &&
        (response['error'] as String).isNotEmpty) {
      throw StateError(response['error'] as String);
    }
  });

  Future<void> setBackground(bool value) async {
    await host.setBackground(value);
    await preferences.setBool('background', value);
    notifyListeners();
  }

  Future<String?> pickAndroidDirectory() async {
    final raw = await FolderStorage.channel.invokeMethod<String>(
      'pickDirectory',
    );
    return raw == null ? null : Uri.encodeComponent(raw);
  }

  Future<void> shutdown() async {
    _refreshTimer?.cancel();
    _eventTimer?.cancel();
    await _events?.cancel();
    await host.stop();
  }

  Future<void> prepareForUpdate() async {
    if (busy) throw StateError('文件操作尚未完成，暂不能退出更新。');
    for (final flush in List.of(documentFlushers)) {
      await flush();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _eventTimer?.cancel();
    unawaited(_events?.cancel());
    unawaited(fileChanges.close());
    super.dispose();
  }
}
