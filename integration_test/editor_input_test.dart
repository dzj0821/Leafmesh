// Actual Flutter + native WebView2 + shipped CodeMirror, private desktop only.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leafmesh/app_controller.dart';
import 'package:leafmesh/core/api.dart';
import 'package:leafmesh/core/models.dart';
import 'package:leafmesh/storage/repository.dart';
import 'package:leafmesh/ui/editor_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('click actual editor, retain focus, type native characters and save', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp(
      'leafmesh-editor-input-',
    );
    final file = File('${directory.path}/focus.md');
    await file.writeAsString(
      '# Focus fixture\n\nAlpha beta gamma\n\nSecond body line',
    );
    final app = AppController()
      ..preferences = await SharedPreferences.getInstance()
      ..drafts = DraftStore('${directory.path}/drafts')
      ..api = CoreApi(
        1,
        'test',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
    final folder = SyncFolder({
      'id': 'focus-fixture',
      'label': 'fixture',
      'path': directory.path,
    });
    final focusTrace = <String>[];
    void traceFocus() {
      focusTrace.add(
        '${DateTime.now().toIso8601String()}: ${FocusManager.instance.primaryFocus}',
      );
    }

    FocusManager.instance.addListener(traceFocus);
    addTearDown(() => FocusManager.instance.removeListener(traceFocus));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: EditorPage(
                  app: app,
                  folder: folder,
                  entry: FileEntry('focus.md', false, 0, DateTime.now()),
                ),
              ),
              const TextField(key: ValueKey('outside-input')),
            ],
          ),
        ),
      ),
    );
    InAppWebViewController? web;
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 150));
      final dynamic state = tester.state(find.byType(EditorPage));
      web = state.web as InAppWebViewController?;
      if (web != null &&
          await web.evaluateJavascript(
                source: '!!document.querySelector(".cm-content")',
              ) ==
              true) {
        break;
      }
    }
    expect(web, isNotNull);
    final surface = MethodChannel(
      'com.pichillilorenzo/custom_platform_view_${web!.getViewId()}',
    );
    // This native method refuses to run unless _DEBUG and the process is on
    // a LeafmeshFocus_* desktop. No typing is sent to the user desktop.
    final initial = await surface.invokeMapMethod<String, dynamic>(
      'debugInputState',
    );
    debugPrint('INITIAL: $initial');
    await windowManager.show();
    await windowManager.focus();
    await web.evaluateJavascript(
      source: '''window.inputTrace=[];
      for(const type of ['focus','blur','focusin','focusout','keydown','beforeinput','input'])
        addEventListener(type,event=>inputTrace.push({type,active:document.activeElement?.className,
          focused:document.hasFocus(),time:performance.now()}),true);''',
    );
    for (var round = 0; round < 3; round++) {
      if (round == 1) {
        await tester.tap(find.byKey(const ValueKey('outside-input')));
        await tester.enterText(
          find.byKey(const ValueKey('outside-input')),
          'outside',
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      final target =
          jsonDecode(
                await web.evaluateJavascript(
                      source: '''JSON.stringify((()=>{
        const line=document.querySelectorAll('.cm-line')[2];const rect=line.getBoundingClientRect();
        const range=document.createRange();range.selectNodeContents(line);const text=range.getBoundingClientRect();
        return {x:text.left+24,y:(text.top+text.bottom)/2};})())''',
                    )
                    as String,
              )
              as Map;
      final origin = tester.getTopLeft(find.byType(InAppWebView));
      final point =
          origin +
          Offset(
            (target['x'] as num).toDouble(),
            (target['y'] as num).toDouble(),
          );
      final before =
          await web.evaluateJavascript(source: 'window.leafmesh.text()')
              as String;
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 350));
      final dom = await web.evaluateJavascript(
        source: '''JSON.stringify({focused:document.hasFocus(),
        active:document.activeElement?.className,editorFocused:document.querySelector('.cm-content')?.cmTile.root.view.hasFocus,
        selection:window.getSelection()?.toString(),events:inputTrace})''',
      );
      final native = await surface.invokeMapMethod<String, dynamic>(
        'debugInputState',
      );
      debugPrint('ROUND $round DOM: $dom NATIVE: $native FLUTTER: $focusTrace');
      await surface.invokeMethod('debugTypeText', 'Z');
      await tester.pump(const Duration(milliseconds: 700));
      final after =
          await web.evaluateJavascript(source: 'window.leafmesh.text()')
              as String;
      debugPrint(
        'ROUND $round BEFORE: $before AFTER: $after FILE: ${await file.readAsString()}',
      );
      expect(native?['rootActive'], true);
      expect(
        jsonDecode(dom as String)['editorFocused'],
        true,
        reason: 'Click must leave actual CodeMirror editable',
      );
      expect(
        after.length,
        before.length + 1,
        reason: 'Native keyboard character must enter the actual editor',
      );
      expect(
        await file.readAsString(),
        after,
        reason:
            'The typed character must reach the real document, not just a focus flag',
      );
      expect(
        await web.evaluateJavascript(source: 'document.hasFocus()'),
        true,
        reason: 'Autosave/status rebuild must not end editing',
      );
      await surface.invokeMethod('debugTypeText', 'Q');
      await tester.pump(const Duration(milliseconds: 700));
      final continuous =
          await web.evaluateJavascript(source: 'window.leafmesh.text()')
              as String;
      expect(
        continuous.length,
        after.length + 1,
        reason: 'Typing must continue without another click',
      );
      expect(await file.readAsString(), continuous);
    }
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump(const Duration(milliseconds: 200));
    final formatted =
        await web.evaluateJavascript(source: 'window.leafmesh.text()')
            as String;
    debugPrint(
      'AFTER FORMAT DOM: ${await web.evaluateJavascript(source: 'JSON.stringify({focused:document.hasFocus(),active:document.activeElement?.className})')}',
    );
    debugPrint(
      'AFTER FORMAT NATIVE: ${await surface.invokeMapMethod<String, dynamic>('debugInputState')}',
    );
    await surface.invokeMethod('debugTypeText', 'K');
    await tester.pump(const Duration(milliseconds: 700));
    final typedAfterFormat =
        await web.evaluateJavascript(source: 'window.leafmesh.text()')
            as String;
    expect(
      typedAfterFormat.length,
      formatted.length + 1,
      reason: 'Format toolbar must return to actual editing',
    );
    expect(await file.readAsString(), typedAfterFormat);
    expect(await web.evaluateJavascript(source: 'document.hasFocus()'), true);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    app.api.close();
    app.dispose();
  }, skip: !const bool.fromEnvironment('LEAFMESH_ISOLATED_DESKTOP_TESTS'));
}
