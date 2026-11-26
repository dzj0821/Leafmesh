import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import 'native_bridge.dart';

/// Shared filesystem contract. Android's document URI stays opaque to Dart.
class FolderStorage {
  FolderStorage(this.root, {this.saf = false});
  factory FolderStorage.forFolder(SyncFolder folder) => FolderStorage(
    folder.path,
    saf: folder.config['filesystemType'] == 'leafmeshsaf',
  );
  final String root;
  final bool saf;
  static const channel = NativeBridge();

  static String validateRelative(String value, {bool allowRoot = false}) {
    if ((value.isEmpty || value == '.') && allowRoot) return '';
    if (value.isEmpty ||
        value.contains('\u0000') ||
        p.posix.isAbsolute(value) ||
        p.windows.isAbsolute(value) ||
        value.contains('\\') ||
        value.contains(':') ||
        value.split('/').any((s) => s == '..' || s == '.' || s.isEmpty)) {
      throw const FormatException('文件路径必须位于当前共享文件夹内');
    }
    return value;
  }

  static void validateName(String name) {
    validateRelative(name);
    if (name.contains('/') ||
        RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(name) ||
        name.endsWith('.') ||
        name.endsWith(' ') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(name) ||
        name == '.stfolder' ||
        name == '.stversions' ||
        name.startsWith('.syncthing.')) {
      throw const FormatException('文件名无效，或被同步核心保留');
    }
  }

  Future<String> _localPath(
    String relative, {
    bool allowMissing = false,
  }) async {
    validateRelative(relative, allowRoot: true);
    final canonicalRoot = await Directory(root).resolveSymbolicLinks();
    var current = canonicalRoot;
    final parts = relative.isEmpty ? <String>[] : relative.split('/');
    for (var i = 0; i < parts.length; i++) {
      current = p.join(current, parts[i]);
      final kind = await FileSystemEntity.type(current, followLinks: false);
      if (kind == FileSystemEntityType.notFound) {
        if (!allowMissing) throw FileSystemException('文件不存在', relative);
        current = p.joinAll([current, ...parts.skip(i + 1)]);
        break;
      }
      final resolved = await (kind == FileSystemEntityType.directory
          ? Directory(current).resolveSymbolicLinks()
          : File(current).resolveSymbolicLinks());
      if (resolved != canonicalRoot && !p.isWithin(canonicalRoot, resolved)) {
        throw const FileSystemException('不允许访问共享文件夹以外的链接目标');
      }
      if (kind == FileSystemEntityType.link) {
        throw const FileSystemException('不跟随符号链接');
      }
      current = resolved;
    }
    return current;
  }

  Future<T?> _invoke<T>(String method, Json values) =>
      channel.invokeMethod<T>(method, {'root': root, ...values});

  Future<List<FileEntry>> list(String relative) async {
    validateRelative(relative, allowRoot: true);
    final entries = <FileEntry>[];
    if (saf) {
      final result =
          await _invoke<List>('storageList', {'path': relative}) ?? [];
      for (final raw in result) {
        final item = Map<String, dynamic>.from(raw as Map);
        entries.add(
          FileEntry(
            item['path'] as String,
            item['directory'] == true,
            (item['size'] as num?)?.toInt() ?? 0,
            DateTime.fromMillisecondsSinceEpoch(
              (item['modified'] as num?)?.toInt() ?? 0,
            ),
          ),
        );
      }
    } else {
      final directory = Directory(await _localPath(relative));
      await for (final item in directory.list(followLinks: false)) {
        final type = await FileSystemEntity.type(item.path, followLinks: false);
        if (type != FileSystemEntityType.directory &&
            type != FileSystemEntityType.file) {
          continue;
        }
        final stat = await item.stat();
        entries.add(
          FileEntry(
            p.posix.join(relative, p.basename(item.path)),
            type == FileSystemEntityType.directory,
            stat.size,
            stat.modified,
          ),
        );
      }
    }
    entries.removeWhere(
      (e) =>
          e.name == '.stfolder' ||
          e.name == '.stversions' ||
          e.name.startsWith('.syncthing.'),
    );
    entries.sort(
      (a, b) => a.isDirectory != b.isDirectory
          ? (a.isDirectory ? -1 : 1)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return entries;
  }

  Future<Uint8List> readBytes(String relative) async {
    validateRelative(relative);
    if (saf) {
      return (await _invoke<Uint8List>('storageRead', {'path': relative}))!;
    }
    final file = File(await _localPath(relative));
    if (await file.length() > 16 * 1024 * 1024) {
      throw const FileSystemException('文件超过 16 MiB，请使用外部应用打开');
    }
    return file.readAsBytes();
  }

  Future<DocumentSnapshot> readText(String relative) async {
    final bytes = await readBytes(relative);
    final text = utf8.decode(
      bytes,
    ); // Invalid encoding is reported, never silently rewritten.
    if (text.contains('\u0000')) throw const FormatException('此文件包含二进制内容');
    return DocumentSnapshot(text, sha256.convert(bytes).toString());
  }

  Future<String> saveText(
    String relative,
    String text, {
    required String? expectedHash,
  }) async {
    validateRelative(relative);
    final data = utf8.encode(text);
    if (saf) {
      await _invoke<void>('storageWrite', {
        'path': relative,
        'bytes': Uint8List.fromList(data),
        'expectedHash': expectedHash,
        'createOnly': expectedHash == null,
      });
    } else {
      final target = File(await _localPath(relative, allowMissing: true));
      if (await target.exists()) {
        final actual = sha256.convert(await target.readAsBytes()).toString();
        if (expectedHash == null || actual != expectedHash) {
          throw const DiskChangedException('文件已被其他设备或程序修改。你的草稿已保留，请先处理差异。');
        }
      } else if (expectedHash != null) {
        throw const DiskChangedException('文件已被删除。你的草稿已保留，可另存为新文件。');
      }
      // Syncthing ignores its own temporary filename convention.
      final temp = File(
        p.join(
          p.dirname(target.path),
          '.syncthing.leafmesh-${DateTime.now().microsecondsSinceEpoch}.tmp',
        ),
      );
      try {
        await temp.writeAsBytes(data, flush: true);
        // Check again after staging, immediately before replacement.
        if (await target.exists()) {
          if (expectedHash == null ||
              sha256.convert(await target.readAsBytes()).toString() !=
                  expectedHash) {
            throw const DiskChangedException('写入期间检测到远端修改，已停止保存并保留草稿。');
          }
        } else if (expectedHash != null) {
          throw const DiskChangedException('写入期间文件被删除，已保留草稿。');
        }
        await temp.rename(target.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }
    return sha256.convert(data).toString();
  }

  Future<void> mkdir(String relative) async {
    validateRelative(relative);
    if (saf) {
      await _invoke<void>('storageMkdir', {'path': relative});
    } else {
      final target = await _localPath(relative, allowMissing: true);
      if (await FileSystemEntity.type(target) !=
          FileSystemEntityType.notFound) {
        throw StateError('同名项目已存在');
      }
      await Directory(target).create();
    }
  }

  Future<void> rename(String from, String to, {required bool directory}) async {
    validateRelative(from);
    validateRelative(to);
    if (saf) {
      await _invoke<void>('storageRename', {'path': from, 'target': to});
    } else {
      final oldPath = await _localPath(from);
      final newPath = await _localPath(to, allowMissing: true);
      if (await FileSystemEntity.type(newPath) !=
          FileSystemEntityType.notFound) {
        throw StateError('同名项目已存在');
      }
      if (directory) {
        await Directory(oldPath).rename(newPath);
      } else {
        await File(oldPath).rename(newPath);
      }
    }
  }

  Future<void> delete(String relative, {required bool directory}) async {
    validateRelative(relative);
    if (saf) {
      await _invoke<void>('storageDelete', {'path': relative});
    } else {
      final path = await _localPath(relative);
      // Do not recursively delete arbitrary trees; directories must be empty.
      if (directory) {
        await Directory(path).delete();
      } else {
        await File(path).delete();
      }
    }
  }
}

class DraftStore {
  DraftStore(this.directory);
  final String directory;
  String _key(String folder, String file) =>
      sha256.convert(utf8.encode('$folder\u0000$file')).toString();
  Future<File> _file(String folder, String file) async {
    await Directory(directory).create(recursive: true);
    return File(p.join(directory, '${_key(folder, file)}.json'));
  }

  Future<Json?> load(String folder, String file) async {
    final target = await _file(folder, file);
    if (!await target.exists()) return null;
    return Json.from(jsonDecode(await target.readAsString()) as Map);
  }

  Future<void> save(
    String folder,
    String file,
    String text,
    String baseHash,
  ) async {
    final target = await _file(folder, file);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'folder': folder,
        'file': file,
        'text': text,
        'baseHash': baseHash,
        'savedAt': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
    await temporary.rename(target.path);
  }

  Future<void> remove(String folder, String file) async {
    final target = await _file(folder, file);
    if (await target.exists()) await target.delete();
  }
}
