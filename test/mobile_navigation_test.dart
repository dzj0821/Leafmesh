import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leafmesh/app_controller.dart';
import 'package:leafmesh/ui/home.dart';

/// Headless widget tests: no native window, mouse, keyboard or sync engine.
void main() {
  void mobileTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(
      name,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  Future<AppController> openHome(
    WidgetTester tester, {
    double width = 390,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 844));
    final app = AppController()
      ..starting = false
      ..online = true
      ..myId = 'navigation-fixture'
      ..coreVersion = 'fixture';
    await tester.pumpWidget(MaterialApp(home: HomePage(app: app)));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    return app;
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byTooltip('切换文件夹'));
    await tester.pumpAndSettle();
  }

  for (final entry in <String, String>{
    '设置与许可': '设置',
    '设备与配对': '设备与配对',
    '可拉取的文件夹': '可拉取的文件夹',
  }.entries) {
    mobileTest('${entry.value}: system back returns to shared-folder home', (
      tester,
    ) async {
      await openHome(tester);
      var exitRequests = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') exitRequests++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await openDrawer(tester);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, entry.value), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('把文件放在身边'), findsOneWidget);
      expect(exitRequests, 0);
    });
  }

  mobileTest(
    'settings app-bar back and nested licenses each return one level',
    (tester) async {
      await openHome(tester);
      await openDrawer(tester);
      await tester.tap(find.text('设置与许可'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开源许可'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('把文件放在身边'), findsOneWidget);
    },
  );

  mobileTest('wide Android layout still treats settings as a secondary route', (
    tester,
  ) async {
    await openHome(tester, width: 1100);
    await tester.tap(find.text('设置与许可'));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('把文件放在身边'), findsOneWidget);
  });

  mobileTest('system back closes the folder drawer before leaving home', (
    tester,
  ) async {
    await openHome(tester);
    await openDrawer(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('把文件放在身边'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    expect(
      tester.state<ScaffoldState>(find.byType(Scaffold)).isEndDrawerOpen,
      isFalse,
    );
  });
}
