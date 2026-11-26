import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leafmesh/app_controller.dart';
import 'package:leafmesh/ui/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'editor margin selection persists and settings show saved value',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final app = AppController()
        ..preferences = prefs
        ..starting = false
      ..online = true
      ..myId = 'preferences-fixture';
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(MaterialApp(home: HomePage(app: app)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('切换文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置与许可'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
            .selected,
        {true},
      );
      await tester.tap(find.text('无'));
      await tester.pumpAndSettle();
      expect(app.editorMargins, isFalse);
      expect(prefs.getBool('editorMargins'), isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('切换文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置与许可'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
            .selected,
        {false},
      );
      await tester.tap(find.text('有'));
      await tester.pumpAndSettle();
      expect(prefs.getBool('editorMargins'), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.binding.setSurfaceSize(null);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
