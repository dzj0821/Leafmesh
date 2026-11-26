import 'package:path/path.dart' as p;

typedef Json = Map<String, dynamic>;

class SyncFolder {
  SyncFolder(this.config, [this.status = const {}]);
  final Json config;
  final Json status;
  String get id => config['id'] as String;
  String get label => (config['label'] as String?)?.isNotEmpty == true
      ? config['label'] as String
      : id;
  String get path => config['path'] as String;
  bool get paused => config['paused'] == true;
  String get state =>
      paused ? 'paused' : status['state'] as String? ?? 'unknown';
  int get needBytes => (status['needBytes'] as num?)?.toInt() ?? 0;
  int get needItems => (status['needTotalItems'] as num?)?.toInt() ?? 0;
  List<String> get deviceIds => (config['devices'] as List? ?? [])
      .map((e) => (e as Map)['deviceID'] as String)
      .toList();
  String get stateLabel => switch (state) {
    'idle' => needItems > 0 ? '等待同步' : '已同步',
    'scanning' || 'scan-waiting' => '正在扫描',
    'syncing' || 'sync-waiting' => '正在同步',
    'paused' => '已暂停',
    'error' || 'stopped' => '需要处理',
    _ => '正在连接',
  };
  SyncFolder withStatus(Json value) => SyncFolder(config, value);
}

class PeerDevice {
  PeerDevice(this.config, this.connection);
  final Json config;
  final Json connection;
  String get id => config['deviceID'] as String;
  String get name => (config['name'] as String?)?.isNotEmpty == true
      ? config['name'] as String
      : '${id.substring(0, 7)}…';
  bool get connected => connection['connected'] == true;
  bool get paused => config['paused'] == true;
  String get connectionLabel {
    if (paused) return '已暂停';
    if (!connected) return '离线';
    final kind = (connection['type'] as String? ?? '').toLowerCase();
    return kind.contains('relay') ? '加密中继' : '直接连接';
  }
}

class FolderOffer {
  FolderOffer(this.id, this.label, this.deviceIds);
  final String id;
  final String label;
  final List<String> deviceIds;
}

class FileEntry {
  FileEntry(this.relativePath, this.isDirectory, this.size, this.modified);
  final String relativePath;
  final bool isDirectory;
  final int size;
  final DateTime modified;
  String get name => p.basename(relativePath);
  bool get isConflict => name.contains('.sync-conflict-');
  bool get isMarkdown =>
      {'.md', '.markdown', '.mdown'}.contains(p.extension(name).toLowerCase());
  bool get isImage => {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  }.contains(p.extension(name).toLowerCase());
  bool get isText =>
      isMarkdown ||
      {
        '.txt',
        '.nani',
        '.json',
        '.yaml',
        '.yml',
        '.toml',
        '.csv',
        '.log',
        '.xml',
        '.html',
        '.css',
        '.js',
        '.ts',
        '.dart',
        '.py',
        '.go',
        '.sh',
        '.ini',
        '.conf',
      }.contains(p.extension(name).toLowerCase()) ||
      name == '.stignore';
}

class DocumentSnapshot {
  const DocumentSnapshot(this.text, this.hash);
  final String text;
  final String hash;
}

class DiskChangedException implements Exception {
  const DiskChangedException(this.message);
  final String message;
  @override
  String toString() => message;
}

String normalizeDeviceId(String input) {
  var value = input.trim();
  if (value.toLowerCase().startsWith('syncthing://')) {
    final uri = Uri.parse(value);
    value =
        uri.queryParameters['device'] ?? uri.queryParameters['id'] ?? uri.host;
  }
  value = value.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (!RegExp(r'^[A-Z2-7]{56}$').hasMatch(value)) {
    throw const FormatException('Device ID 应为 56 位字母和数字，可直接粘贴完整 ID。');
  }
  return List.generate(8, (i) => value.substring(i * 7, i * 7 + 7)).join('-');
}

String readableBytes(int size) {
  if (size < 1024) return '$size B';
  if (size < 1048576) return '${(size / 1024).toStringAsFixed(1)} KB';
  if (size < 1073741824) return '${(size / 1048576).toStringAsFixed(1)} MB';
  return '${(size / 1073741824).toStringAsFixed(1)} GB';
}
