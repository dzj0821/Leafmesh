import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/api.dart';
import '../core/models.dart';
import 'repository.dart';

class StorageMigration {
  StorageMigration(this.api, this.supportPath);
  final CoreApi api;
  final String supportPath;

  Future<void> migrate(
    SyncFolder folder,
    String destination, {
    required bool saf,
  }) async {
    final current = FolderStorage.forFolder(folder);
    if (current.root == destination && current.saf == saf) {
      throw StateError('目标与当前目录相同');
    }
    if (!saf && !current.saf) {
      final a = p.normalize(p.absolute(current.root));
      final b = p.normalize(p.absolute(destination));
      if (p.equals(a, b) || p.isWithin(a, b) || p.isWithin(b, a)) {
        throw StateError('迁移目录不能重叠');
      }
    }
    final safeId = sha256
        .convert(utf8.encode(folder.id))
        .toString()
        .substring(0, 24);
    final journal = File(p.join(supportPath, 'migration-$safeId.json'));
    final record = {
      'folder': folder.id,
      'source': current.root,
      'sourceSaf': current.saf,
      'target': destination,
      'targetSaf': saf,
      'wasPaused': folder.paused,
      'phase': 'copying',
      'startedAt': DateTime.now().toIso8601String(),
    };
    await api.pause(folder.id, true);
    await journal.writeAsString(jsonEncode(record), flush: true);
    var switched = false;
    try {
      if (Platform.isAndroid) {
        await FolderStorage.channel.invokeMethod('migrateStorage', {
          'root': current.root,
          'sourceSaf': current.saf,
          'target': destination,
          'targetSaf': saf,
        });
      } else {
        await _copyLocal(current.root, destination);
      }
      record['phase'] = 'verified';
      await journal.writeAsString(jsonEncode(record), flush: true);
      await api.request(
        'PATCH',
        'config/folders/${folder.id}',
        body: {
          'path': destination,
          'filesystemType': saf ? 'leafmeshsaf' : 'basic',
          'fsWatcherEnabled': !saf,
          'rescanIntervalS': saf ? 30 : 300,
          'paused': true,
        },
      );
      switched = true;
      record['phase'] = 'switched';
      await journal.writeAsString(jsonEncode(record), flush: true);
      if (!folder.paused) await api.pause(folder.id, false);
      record['phase'] = 'complete';
      await journal.writeAsString(jsonEncode(record), flush: true);
      // Keep the old copy. Deleting user files is a separate, explicit action.
    } catch (_) {
      if (!switched && !folder.paused) await api.pause(folder.id, false);
      rethrow;
    }
  }

  Future<void> _copyLocal(String source, String target) async {
    final root = await Directory(source).resolveSymbolicLinks();
    final destination = Directory(target);
    await destination.create(recursive: true);
    if (!await destination.list().isEmpty) throw StateError('迁移目标必须为空目录');
    final originals = <String, String>{};
    await for (final entry in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      final relative = p.relative(entry.path, from: root);
      final resolved = await entry.resolveSymbolicLinks();
      if (!p.isWithin(root, resolved)) throw StateError('目录包含外部链接，已停止迁移');
      if (entry is Link) throw StateError('迁移不跟随符号链接');
      final to = p.join(target, relative);
      if (entry is Directory) {
        await Directory(to).create(recursive: true);
      } else if (entry is File) {
        final before = (await sha256.bind(entry.openRead()).first).toString();
        await Directory(p.dirname(to)).create(recursive: true);
        await entry.copy(to);
        final after = (await sha256.bind(File(to).openRead()).first).toString();
        if (before != after) throw StateError('文件校验失败：$relative');
        originals[relative] = before;
        await File(to).setLastModified(await entry.lastModified());
      }
    }
    // External editors can still write to the old folder while the core is paused.
    final observed = <String>{};
    await for (final entry in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      if (entry is File) observed.add(p.relative(entry.path, from: root));
    }
    if (observed.length != originals.length ||
        !observed.containsAll(originals.keys)) {
      throw StateError('迁移期间源目录的文件列表发生变化，原目录仍在使用');
    }
    for (final original in originals.entries) {
      final hash =
          (await sha256.bind(File(p.join(root, original.key)).openRead()).first)
              .toString();
      if (hash != original.value) {
        throw StateError('迁移期间源文件发生变化：${original.key}');
      }
    }
  }
}
