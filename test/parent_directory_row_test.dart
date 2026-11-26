import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leafmesh/app_controller.dart';
import 'package:leafmesh/core/models.dart';
import 'package:leafmesh/ui/home.dart';

/// All pointer events stay inside the headless Flutter test view.
void main() {
  testWidgets(
    'parent row text and blank space navigate up; root stays disabled',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('leafmesh-parent-row-'),
      ))!;
      final branch = Directory('${root.path}/branch');
      final leaf = Directory('${branch.path}/leaf');
      final files = [
        File('${root.path}/root-marker.txt'),
        File('${branch.path}/branch-marker.txt'),
        File('${leaf.path}/leaf-marker.txt'),
      ];
      await tester.runAsync(() async {
        await branch.create();
        await leaf.create();
        for (final file in files) {
          await file.writeAsString('fixture');
        }
      });
      final app = AppController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await tester.runAsync(() async {
          for (final file in files) {
            await file.delete();
          }
          await leaf.delete();
          await branch.delete();
          await root.delete();
        });
        await tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(390, 800));
      final folder = SyncFolder({
        'id': 'fixture',
        'label': 'Folder',
        'path': root.path,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileBrowser(app: app, folder: folder),
          ),
        ),
      );

      Future<void> waitFor(String name) async {
        for (var i = 0; i < 50; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.text(name).evaluate().isNotEmpty) return;
        }
        fail('Directory did not show $name');
      }

      await waitFor('root-marker.txt');
      await tester.tap(find.text('branch'));
      await waitFor('branch-marker.txt');
      await tester.tap(find.text('leaf'));
      await waitFor('leaf-marker.txt');
      final row = find.byKey(const ValueKey('parent-directory-row'));
      final bounds = tester.getRect(row);
      await tester.tapAt(Offset(bounds.right - 8, bounds.center.dy));
      await waitFor('branch-marker.txt');
      expect(find.text('leaf-marker.txt'), findsNothing);
      await tester.tap(find.text('branch'));
      await waitFor('root-marker.txt');
      expect(find.text('全部文件'), findsOneWidget);
      final rootBounds = tester.getRect(row);
      await tester.tapAt(Offset(rootBounds.right - 8, rootBounds.center.dy));
      await tester.pump();
      expect(find.text('root-marker.txt'), findsOneWidget);
      expect(find.text('branch-marker.txt'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
