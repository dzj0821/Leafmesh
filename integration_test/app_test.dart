// Interactive native test: only on an isolated test desktop, never the user desktop.
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:leafmesh/app_controller.dart';
import 'package:leafmesh/main.dart';
import 'package:leafmesh/build_info.dart';
import 'package:leafmesh/desktop_updates.dart';
import 'package:leafmesh/ui/editor_page.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:window_manager/window_manager.dart';

Future<InAppWebViewController> waitForEditor(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    final dynamic state = tester.state(find.byType(EditorPage));
    final web = state.web as InAppWebViewController?;
    if (web != null &&
        await web.evaluateJavascript(
              source: '!!document.querySelector(".cm-content")',
            ) ==
            true) {
      expect(
        await web.evaluateJavascript(source: 'window.leafmesh.build'),
        BuildInfo.editorBuild,
        reason:
            'The native WebView must use the editor bundled with this exact app release',
      );
      return web;
    }
  }
  fail('The native WebView did not load the current bundled editor');
}

Future<void> checkHeadingPreview(
  WidgetTester tester,
  InAppWebViewController web,
) async {
  const markdown =
      '# 一级标题\n\n  ##\t二级标题\n\n###   三级标题  ###  \n\n#### 四级标题\n\n##### 五级标题\n\n###### 六级标题\n\n[链接](https://example.com)';
  final load =
      'window.leafmesh.load(${jsonEncode({'text': markdown, 'markdown': true, 'source': false})})';
  await web.evaluateJavascript(source: load);
  await tester.pump(const Duration(milliseconds: 400));
  final snapshot =
      jsonDecode(
            await web.evaluateJavascript(
                  source: '''JSON.stringify({
    headings:[...document.querySelectorAll('.qj-heading')].map(line=>({
      text:line.textContent,
      underlined:[line,...line.querySelectorAll('*')].some(el=>getComputedStyle(el).textDecorationLine.includes('underline'))
    })),
    linkUnderlined:[...document.querySelectorAll('.qj-link')].some(el=>getComputedStyle(el).textDecorationLine.includes('underline'))
  })''',
                )
                as String,
          )
          as Map;
  final headings = snapshot['headings'] as List;
  expect(
    headings.map((line) => line['text']).toList(),
    ['一级标题', '二级标题', '三级标题', '四级标题', '五级标题', '六级标题'],
    reason:
        'First render must hide complete heading delimiters including spaces and tabs',
  );
  expect(
    headings.every((line) => line['underlined'] == false),
    isTrue,
    reason: 'Heading highlighting must not introduce underlines',
  );
  expect(
    snapshot['linkUnderlined'],
    isTrue,
    reason: 'Links keep their own underline style',
  );
  expect(
    await web.evaluateJavascript(source: 'window.leafmesh.text()'),
    markdown,
  );

  await windowManager.show();
  await windowManager.focus();
  await tester.tap(find.byType(InAppWebView));
  await tester.pump(const Duration(milliseconds: 300));
  await web.evaluateJavascript(source: '$load; window.leafmesh.focus()');
  String? firstLine;
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    firstLine =
        await web.evaluateJavascript(
              source: 'document.querySelector(".qj-heading")?.textContent',
            )
            as String?;
    if (firstLine == '# 一级标题') break;
  }
  final focusDiagnostic = await web.evaluateJavascript(
    source:
        '''JSON.stringify({documentFocused:document.hasFocus(),active:document.activeElement?.className,selection:window.getSelection()?.anchorNode?.parentElement?.className})''',
  );
  expect(
    firstLine,
    '# 一级标题',
    reason: 'Focused heading reveals editable Markdown: $focusDiagnostic',
  );
  await web.evaluateJavascript(
    source: 'document.querySelector(".cm-content").blur()',
  );
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    firstLine =
        await web.evaluateJavascript(
              source: 'document.querySelector(".qj-heading")?.textContent',
            )
            as String?;
    if (firstLine == '一级标题') break;
  }
  expect(
    firstLine,
    '一级标题',
    reason: 'Blur restores preview without leftover delimiters or spaces',
  );
  expect(
    await web.evaluateJavascript(source: 'window.leafmesh.text()'),
    markdown,
  );
  await web.evaluateJavascript(source: 'window.leafmesh.command("source")');
  await tester.pump(const Duration(milliseconds: 200));
  expect(
    await web.evaluateJavascript(
      source: 'document.querySelector(".cm-line").textContent',
    ),
    '# 一级标题',
  );
  await web.evaluateJavascript(
    source: 'window.leafmesh.load({text:"",markdown:true,source:false})',
  );
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real core, file list, editor autosave and local ignores', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    final profile = await Directory.systemTemp.createTemp('leafmesh-ui-check-');
    final files = await Directory('${profile.path}/notes').create();
    await File(
      '${files.path}/welcome.md',
    ).writeAsString('# Leafmesh\n\n真实文件测试。');
    const nani = '# 背景\n@back Garden\n角色: 纯文本，保留原始脚本。\n';
    await File('${files.path}/story.nani').writeAsString(nani);
    final controller = AppController(
      supportPathOverride: '${profile.path}/profile',
    );
    addTearDown(controller.shutdown);
    await tester.pumpWidget(LeafmeshApp(controller: controller));
    final startup = DateTime.now().add(const Duration(seconds: 60));
    while (controller.starting && DateTime.now().isBefore(startup)) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(controller.error, isNull);
    expect(controller.myId, isNotEmpty);
    expect(find.text('把文件放在身边'), findsOneWidget);
    await controller.addFolder(
      label: '界面集成测试',
      devices: [],
      location: files.path,
    );
    for (var i = 0; i < 30 && find.text('welcome.md').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('welcome.md'), findsOneWidget);
    expect(find.text('story.nani'), findsOneWidget);
    await controller.saveIgnores(controller.selected!.id, '*.private\n');
    expect(
      await controller.readIgnores(controller.selected!.id),
      contains('*.private'),
    );
    expect(File('${files.path}/.stignore').existsSync(), isTrue);
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建 Markdown 笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'integration-note.md');
    await tester.tap(find.text('创建'));
    for (
      var i = 0;
      i < 30 && !File('${files.path}/integration-note.md').existsSync();
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(File('${files.path}/integration-note.md').existsSync(), isTrue);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('integration-note.md'), findsWidgets);
    final editor = await waitForEditor(tester);
    await checkHeadingPreview(tester, editor);
    expect(await File('${files.path}/integration-note.md').readAsString(), '');
    await tester.tap(find.byTooltip('标题'));
    final note = File('${files.path}/integration-note.md');
    for (var i = 0; i < 50 && await note.readAsString() != '# '; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      await note.readAsString(),
      '# ',
      reason: 'Native WebView toolbar edits must autosave to the real file',
    );
    await tester.tap(find.byTooltip('Markdown 源码'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('实时预览'), findsOneWidget);
    await tester.tap(find.byTooltip('加粗'));
    for (var i = 0; i < 50 && await note.readAsString() != '# ****'; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(await note.readAsString(), '# ****');
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('story.nani'));
    final plainEditor = await waitForEditor(tester);
    expect(
      await plainEditor.evaluateJavascript(source: 'window.leafmesh.text()'),
      nani,
    );
    expect(
      await plainEditor.evaluateJavascript(
        source: 'document.querySelectorAll(".qj-heading").length',
      ),
      0,
    );
    expect(find.byTooltip('Markdown 源码'), findsNothing);
    await plainEditor.evaluateJavascript(
      source: 'window.leafmesh.command("heading")',
    );
    await controller.prepareForUpdate();
    expect(await File('${files.path}/story.nani').readAsString(), '# $nani');
    var exitedForUpdate = false;
    final updates = DesktopUpdates(
      directory: profile.path,
      prepare: () async {
        await controller.prepareForUpdate();
        await controller.shutdown();
      },
      exit: () async {
        exitedForUpdate = true;
      },
    );
    await updates.start();
    final info = jsonDecode(await updates.descriptor.readAsString()) as Map;
    final client = HttpClient();
    final unauthorized = await client.post(
      '127.0.0.1',
      info['port'] as int,
      '/prepare-update',
    );
    expect((await unauthorized.close()).statusCode, HttpStatus.forbidden);
    final request = await client.post(
      '127.0.0.1',
      info['port'] as int,
      '/prepare-update',
    );
    request.headers.set('X-Leafmesh-Update-Key', info['token']);
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    await response.drain<void>();
    client.close(force: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(exitedForUpdate, isTrue);
    await updates.close();
    await controller.shutdown();
    await tester.pumpWidget(const SizedBox.shrink());
    // Keep profile and file fixtures to inspect if the native editor fails.
  }, skip: !const bool.fromEnvironment('LEAFMESH_ISOLATED_DESKTOP_TESTS'));
}
