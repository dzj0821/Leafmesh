import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic Flutter events only; never moves the system mouse.
void main() {
  for (final scale in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('current local pointer coordinates at $scale display scaling', (
      tester,
    ) async {
      tester.view.devicePixelRatio = scale;
      tester.view.physicalSize = Size(1200 * scale, 900 * scale);
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      const manager = MethodChannel(
        'com.pichillilorenzo/flutter_inappwebview_manager',
      );
      const channel = MethodChannel(
        'com.pichillilorenzo/custom_platform_view_91',
      );
      const events = MethodChannel(
        'com.pichillilorenzo/custom_platform_view_91_events',
      );
      messenger.setMockMethodCallHandler(
        manager,
        (call) async => call.method == 'createInAppWebView' ? 91 : null,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        for (final c in [manager, channel, events]) {
          messenger.setMockMethodCallHandler(c, null);
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var top = 72.0;
      late StateSetter relayout;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                relayout = setState;
                return Padding(
                  padding: EdgeInsets.only(left: 180, top: top),
                  child: const CustomPlatformView(),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(190, 90));
      await mouse.moveTo(const Offset(200, 100));
      await tester.pumpAndSettle();
      // Change the editor origin without delivering a new hover event.
      relayout(() => top = 152);
      await tester.pumpAndSettle();
      calls.clear();
      await mouse.down(const Offset(215.5, 236.25));
      await tester.pump();
      final down = calls.indexWhere(
        (c) => c.method == 'setPointerButton' && c.arguments['isDown'] == true,
      );
      final move = calls.lastIndexWhere((c) => c.method == 'setCursorPos');
      expect(move, greaterThanOrEqualTo(0));
      expect(move, lessThan(down));
      expect(calls[move].arguments, [35.5, 84.25]);
      final size = calls.indexWhere((c) => c.method == 'setSize');
      expect(size, greaterThanOrEqualTo(0));
      expect(size, lessThan(move));
      expect(calls[size].arguments[2], scale);
      final position = calls.firstWhere((c) => c.method == 'setPosition');
      expect(position.arguments, [180.0, 152.0, scale]);
      await mouse.moveTo(const Offset(221.5, 249.75));
      await tester.pump();
      calls.clear();
      await mouse.up();
      await tester.pumpAndSettle();
      final up = calls.indexWhere(
        (c) => c.method == 'setPointerButton' && c.arguments['isDown'] == false,
      );
      final latest = calls.lastIndexWhere((c) => c.method == 'setCursorPos');
      expect(latest, greaterThanOrEqualTo(0));
      expect(latest, lessThan(up));
      expect(calls[latest].arguments, [41.5, 97.75]);
      expect(calls.where((c) => c.method == 'setFocus'), isEmpty);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
