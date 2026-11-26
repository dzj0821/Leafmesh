import 'dart:io';
import 'dart:convert';
import 'package:leafmesh/storage/repository.dart';
import 'package:leafmesh/core/models.dart';

Future<void> main() async {
  var passed = 0;
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    passed++;
    stdout.writeln('PASS $name');
  }

  final root = await Directory.systemTemp.createTemp('leafmesh-storage-check-');
  final storage = FolderStorage(root.path);
  try {
    for (final path in [
      '../secret',
      '/root',
      r'C:\Windows',
      'C:outside',
      r'folder\file',
      'a/../b',
      'a//b',
      '',
    ]) {
      var rejected = false;
      try {
        FolderStorage.validateRelative(path);
      } on FormatException {
        rejected = true;
      }
      check(rejected, 'reject invalid path ${jsonEncode(path)}');
    }
    for (final name in [
      'CON',
      'com1.md',
      'x?',
      'bad.',
      '.stfolder',
      '../bad',
    ]) {
      var rejected = false;
      try {
        FolderStorage.validateName(name);
      } on FormatException {
        rejected = true;
      }
      check(rejected, 'reject reserved name ${jsonEncode(name)}');
    }
    await storage.saveText('note.md', '# hello\n\n中文内容', expectedHash: null);
    final snapshot = await storage.readText('note.md');
    check(snapshot.text.contains('中文'), 'UTF-8 roundtrip');
    await storage.saveText(
      'note.md',
      'local edit',
      expectedHash: snapshot.hash,
    );
    var conflicted = false;
    try {
      await storage.saveText(
        'note.md',
        'stale edit',
        expectedHash: snapshot.hash,
      );
    } on DiskChangedException {
      conflicted = true;
    }
    check(
      conflicted && (await storage.readText('note.md')).text == 'local edit',
      'stale writer does not overwrite newer content',
    );
    await File('${root.path}/note.md').delete();
    var deleted = false;
    try {
      await storage.saveText(
        'note.md',
        'resurrect',
        expectedHash: snapshot.hash,
      );
    } on DiskChangedException {
      deleted = true;
    }
    check(
      deleted && !await File('${root.path}/note.md').exists(),
      'deleted file is not silently resurrected',
    );
    await storage.mkdir('nested');
    await storage.saveText('nested/keep.md', 'keep', expectedHash: null);
    var nonempty = false;
    try {
      await storage.delete('nested', directory: true);
    } on FileSystemException {
      nonempty = true;
    }
    check(
      nonempty && await File('${root.path}/nested/keep.md').exists(),
      'nonempty directories are not recursively deleted',
    );
    await storage.rename('nested/keep.md', 'nested/moved.md', directory: false);
    check(
      await File('${root.path}/nested/moved.md').exists(),
      'rename within root',
    );
    final drafts = DraftStore('${root.path}/drafts');
    await drafts.save('folder-a', 'notes/test.md', 'draft', 'base');
    check(
      (await drafts.load('folder-a', 'notes/test.md'))?['text'] == 'draft',
      'draft recovery',
    );
    check(
      await drafts.load('folder-b', 'notes/test.md') == null,
      'drafts are isolated by folder',
    );
    await drafts.remove('folder-a', 'notes/test.md');
    check(
      await drafts.load('folder-a', 'notes/test.md') == null,
      'draft cleanup',
    );
    stdout.writeln('Storage checks: $passed passed.');
  } finally {
    // The only recursive removal is our own uniquely-created temp test directory.
    final resolved = await root.resolveSymbolicLinks();
    if (Directory(resolved).parent.path == Directory.systemTemp.path &&
        root.path.contains('leafmesh-storage-check-')) {
      await root.delete(recursive: true);
    }
  }
}
