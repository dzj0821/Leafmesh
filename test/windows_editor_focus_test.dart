import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';
import 'package:flutter_test/flutter_test.dart';

// Mock textures/channels only: no native window or system mouse input.
void main() {
  testWidgets(
    'repeated editor, toolbar, menu and text-field clicks keep input in Flutter',
    (tester) async {
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      const manager = MethodChannel(
        'com.pichillilorenzo/flutter_inappwebview_manager',
      );
      const view = MethodChannel('com.pichillilorenzo/custom_platform_view_77');
      const events = MethodChannel(
        'com.pichillilorenzo/custom_platform_view_77_events',
      );
      var nativeViews = 0;
      messenger.setMockMethodCallHandler(manager, (call) async {
        if (call.method == 'createInAppWebView') {
          nativeViews++;
          return 77;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(view, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        for (final channel in [manager, view, events]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      var formatClicks = 0, menuClicks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: CustomPlatformView()),
                TextButton(
                  onPressed: () => formatClicks++,
                  child: const Text('格式'),
                ),
                PopupMenuButton<bool>(
                  tooltip: '间距',
                  onSelected: (_) => menuClicks++,
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: true, child: Text('有')),
                  ],
                ),
                const TextField(key: ValueKey('other-control')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'setFocus' && c.arguments == true),
        isEmpty,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(80, 80));
      await mouse.moveTo(const Offset(90, 90));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'setFocus' && c.arguments == true),
        isEmpty,
      );
      for (var i = 0; i < 5; i++) {
        calls.clear();
        await mouse.down(const Offset(90, 90));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(
          calls
              .where(
                (c) =>
                    c.method == 'setPointerButton' &&
                    c.arguments['isDown'] == true,
              )
              .length,
          1,
        );
        expect(
          calls
              .where(
                (c) =>
                    c.method == 'setPointerButton' &&
                    c.arguments['isDown'] == false,
              )
              .length,
          1,
        );
        final editorFocus = tester
            .widget<Focus>(
              find.descendant(
                of: find.byType(CustomPlatformView),
                matching: find.byType(Focus),
              ),
            )
            .focusNode;
        expect(FocusManager.instance.primaryFocus, same(editorFocus));
        await tester.tap(find.text('格式'));
        await tester.pumpAndSettle();
        expect(formatClicks, i + 1);
        await tester.tap(find.byTooltip('间距'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('有'));
        await tester.pumpAndSettle();
        expect(menuClicks, i + 1);
        await tester.tap(find.byKey(const ValueKey('other-control')));
        await tester.enterText(find.byType(TextField), 'round $i');
        await tester.pumpAndSettle();
        expect(find.text('round $i'), findsOneWidget);
        // No native HWND handoff on any focus transition.
        expect(calls.where((c) => c.method == 'setFocus'), isEmpty);
      }
      // A native browser focus notification must not steal keyboard ownership
      // back from a Flutter text field. Losing native focus must not loop.
      calls.clear();
      Future<void> nativeFocus(bool focused) async {
        await messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'type': 'focusChanged',
            'value': focused,
          }),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await nativeFocus(true);
      expect(calls.where((c) => c.method == 'releaseInputFocus').length, 1);
      expect(find.text('round 4'), findsOneWidget);
      calls.clear();
      await nativeFocus(false);
      expect(calls.where((c) => c.method == 'releaseInputFocus'), isEmpty);
      await mouse.down(const Offset(90, 90));
      await mouse.up();
      await tester.pumpAndSettle();
      calls.clear();
      await nativeFocus(true);
      expect(calls.where((c) => c.method == 'releaseInputFocus'), isEmpty);
      final editorFocus = tester
          .widget<Focus>(
            find.descendant(
              of: find.byType(CustomPlatformView),
              matching: find.byType(Focus),
            ),
          )
          .focusNode;
      expect(FocusManager.instance.primaryFocus, same(editorFocus));
      await tester.tap(find.byKey(const ValueKey('other-control')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'releaseInputFocus').length, 1);
      calls.clear();
      await mouse.moveTo(const Offset(100, 100));
      // Native input makes Flutter park logical focus on the root scope.
      // Mirroring GotFocus must not re-request the Flutter native view.
      FocusManager.instance.rootScope.requestScopeFocus();
      await tester.pumpAndSettle();
      await nativeFocus(true);
      expect(
        FocusManager.instance.primaryFocus,
        same(FocusManager.instance.rootScope),
      );
      expect(calls.where((c) => c.method == 'releaseInputFocus'), isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        calls.where((c) => c.method == 'setFocus' && c.arguments == true),
        isEmpty,
      );
      expect(nativeViews, 1);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
