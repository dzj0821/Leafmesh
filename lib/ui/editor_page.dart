import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import '../app_controller.dart';
import '../build_info.dart';
import '../core/models.dart';
import '../storage/repository.dart';
import 'dialogs.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.app,
    required this.folder,
    required this.entry,
  });
  final AppController app;
  final SyncFolder folder;
  final FileEntry entry;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late final storage = FolderStorage.forFolder(widget.folder);
  InAppWebViewController? web;
  // Retain the platform widget/controller across save-status rebuilds.
  Widget? editorSurface;
  final fallback = TextEditingController();
  String text = '';
  String? editorHtml;
  String hash = '';
  String? message;
  bool loaded = false, dirty = false, blocked = false, saving = false;
  bool webFailed = false, source = false, canPop = false, composing = false;
  Future<void> queue = Future.value();
  Timer? saveTimer;
  StreamSubscription<Json>? changes;
  String get relative => widget.entry.relativePath;

  @override
  void initState() {
    super.initState();
    widget.app.documentFlushers.add(_flushForUpdate);
    widget.app.addListener(_preferencesChanged);
    unawaited(_load());
    changes = widget.app.fileChanges.stream.listen((event) {
      final data = event['data'] as Map? ?? {};
      if (data['folder'] == widget.folder.id &&
          (data['item'] == relative || event['type'] == 'StateChanged')) {
        unawaited(_checkRemote());
      }
    });
  }

  Future<void> _load() async {
    try {
      final snapshot = await storage.readText(relative);
      final draft = await widget.app.drafts.load(widget.folder.id, relative);
      hash = snapshot.hash;
      text = snapshot.text;
      if (draft != null && draft['text'] != snapshot.text) {
        text = draft['text'] as String;
        dirty = true;
        blocked = draft['baseHash'] != snapshot.hash;
        message = blocked ? '已恢复草稿；磁盘文件也有更新，请先处理差异。' : '已恢复上次未完成的草稿';
      } else if (draft != null) {
        await widget.app.drafts.remove(widget.folder.id, relative);
      }
      fallback.text = text;
      try {
        editorHtml = await rootBundle.loadString(
          'assets/editor/editor.html',
          cache: false,
        );
        if (!editorHtml!.contains(
          'window.LEAFMESH_EDITOR_BUILD=${jsonEncode(BuildInfo.editorBuild)};',
        )) {
          throw StateError('编辑器资源与应用版本不一致');
        }
      } catch (_) {
        webFailed = true;
        message = '编辑器资源与应用版本不一致，已切换为纯文本；请更新到完整安装包。';
      }
      if (!mounted) return;
      setState(() => loaded = true);
      await _loadWeb();
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    }
  }

  Future<void> _loadWeb() async {
    if (!loaded || web == null || webFailed) return;
    final actualBuild = await web!.evaluateJavascript(
      source: 'window.leafmesh?.build',
    );
    if (actualBuild != BuildInfo.editorBuild) {
      if (mounted) {
        setState(() {
          webFailed = true;
          message = '编辑器加载版本不一致，已切换为纯文本；请重新打开文档。';
        });
      }
      return;
    }
    await web!.evaluateJavascript(
      source:
          'window.leafmesh?.configure(${jsonEncode({'margins': widget.app.editorMargins})})',
    );
    await web!.evaluateJavascript(
      source:
          'window.leafmesh?.load(${jsonEncode({'text': text, 'markdown': widget.entry.isMarkdown, 'source': source})})',
    );
  }

  void _preferencesChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(
      web?.evaluateJavascript(
        source:
            'window.leafmesh?.configure(${jsonEncode({'margins': widget.app.editorMargins})})',
      ),
    );
  }

  void _changed(String value, bool isComposing) {
    if (!loaded || value == text && composing == isComposing) return;
    text = value;
    dirty = true;
    composing = isComposing;
    if (mounted) setState(() {});
    queue = queue
        .catchError((_) {})
        .then(
          (_) => widget.app.drafts.save(widget.folder.id, relative, text, hash),
        );
    saveTimer?.cancel();
    if (!isComposing && !blocked) {
      saveTimer = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(_save()),
      );
    }
  }

  Future<void> _save() async {
    saveTimer?.cancel();
    final next = queue.catchError((_) {}).then((_) async {
      if (!dirty || blocked || !loaded || composing) return;
      final savingText = text;
      if (mounted) setState(() => saving = true);
      try {
        await widget.app.drafts.save(
          widget.folder.id,
          relative,
          savingText,
          hash,
        );
        hash = await storage.saveText(relative, savingText, expectedHash: hash);
        dirty = text != savingText;
        if (dirty) {
          await widget.app.drafts.save(widget.folder.id, relative, text, hash);
        } else {
          await widget.app.drafts.remove(widget.folder.id, relative);
        }
        message = null;
        unawaited(
          widget.app.api
              .scan(widget.folder.id, sub: relative)
              .catchError((_) {}),
        );
      } catch (e) {
        blocked = true;
        message = e.toString();
      } finally {
        if (mounted) setState(() => saving = false);
      }
    });
    queue = next;
    await next;
  }

  Future<void> _checkRemote() async {
    if (!loaded || saving) return;
    try {
      final snapshot = await storage.readText(relative);
      if (snapshot.hash == hash) return;
      if (dirty) {
        await widget.app.drafts.save(widget.folder.id, relative, text, hash);
        if (mounted) {
          setState(() {
            blocked = true;
            message = '文件已在其他设备或程序中更新。你的输入保存在草稿中。';
          });
        }
      } else {
        hash = snapshot.hash;
        text = snapshot.text;
        fallback.text = text;
        await _loadWeb();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          blocked = true;
          message = '文件暂时无法读取：$e。当前草稿已保留。';
        });
      }
    }
  }

  Future<void> _compare() async {
    try {
      final snapshot = await storage.readText(relative);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('草稿与当前文件'),
          content: SizedBox(
            width: 820,
            height: 460,
            child: LayoutBuilder(
              builder: (context, box) {
                final parts = [
                  Expanded(child: _comparison('你的草稿', text)),
                  Expanded(child: _comparison('磁盘文件', snapshot.text)),
                ];
                return box.maxWidth < 560
                    ? Column(children: parts)
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: parts,
                      );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) await showFailure(context, e);
    }
  }

  Widget _comparison(String title, String content) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const Divider(),
        Expanded(child: SingleChildScrollView(child: SelectableText(content))),
      ],
    ),
  );

  Future<void> _saveCopy() async {
    final extension = p.extension(relative);
    final name =
        '${p.basenameWithoutExtension(relative)}-草稿-${DateTime.now().millisecondsSinceEpoch}$extension';
    final target = p.posix.join(
      p.posix.dirname(relative) == '.' ? '' : p.posix.dirname(relative),
      name,
    );
    try {
      await queue;
      await storage.saveText(target, text, expectedHash: null);
      await widget.app.drafts.remove(widget.folder.id, relative);
      if (mounted) {
        setState(() {
          dirty = false;
          message = '草稿已另存为 $name';
        });
        await showFailure(context, '已另存为 $name，原文件未覆盖');
      }
      await widget.app.api.scan(widget.folder.id);
    } catch (e) {
      if (mounted) await showFailure(context, e);
    }
  }

  Future<void> _reload() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('使用磁盘文件？'),
        content: const Text('当前草稿将被丢弃。如需保留，请先选择“另存草稿”。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('丢弃草稿并重新加载'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await queue;
    await widget.app.drafts.remove(widget.folder.id, relative);
    blocked = false;
    dirty = false;
    await _load();
  }

  Future<void> _back() async {
    if (composing && web != null) {
      final current = await web!.evaluateJavascript(
        source: 'window.leafmesh?.text()',
      );
      if (current is String) text = current;
      composing = false;
    }
    await _save();
    await queue;
    if (!mounted) return;
    setState(() => canPop = true);
    Navigator.pop(context);
  }

  Future<void> _flushForUpdate() async {
    if (!loaded) return;
    if (web != null && !webFailed) {
      final current = await web!.evaluateJavascript(
        source: 'window.leafmesh?.text()',
      );
      if (current is String && current != text) _changed(current, false);
    }
    composing = false;
    await _save();
    await queue;
    if (dirty) {
      await widget.app.drafts.save(widget.folder.id, relative, text, hash);
    }
  }

  @override
  void dispose() {
    widget.app.documentFlushers.remove(_flushForUpdate);
    widget.app.removeListener(_preferencesChanged);
    saveTimer?.cancel();
    unawaited(changes?.cancel());
    fallback.dispose();
    super.dispose();
  }

  Widget _createEditorSurface() => InAppWebView(
    initialData: InAppWebViewInitialData(
      data: editorHtml!,
      mimeType: 'text/html',
      encoding: 'utf-8',
    ),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      transparentBackground: true,
      disableContextMenu: false,
      supportZoom: false,
      isInspectable: false,
      cacheEnabled: false,
      cacheMode: CacheMode.LOAD_NO_CACHE,
      needInitialFocus: false,
    ),
    onWebViewCreated: (controller) {
      web = controller;
      controller.addJavaScriptHandler(
        handlerName: 'editorImage',
        callback: (args) async {
          try {
            final raw = (args.first as Map)['path'] as String;
            final uri = Uri.parse(raw);
            if (uri.hasScheme || uri.hasAuthority || raw.startsWith('/')) {
              return null;
            }
            final imagePath = p.posix.normalize(
              p.posix.join(
                p.posix.dirname(relative),
                Uri.decodeComponent(uri.path),
              ),
            );
            FolderStorage.validateRelative(imagePath);
            final mime = switch (p.extension(imagePath).toLowerCase()) {
              '.png' => 'image/png',
              '.jpg' || '.jpeg' => 'image/jpeg',
              '.gif' => 'image/gif',
              '.webp' => 'image/webp',
              '.bmp' => 'image/bmp',
              _ => null,
            };
            if (mime == null) return null;
            final bytes = await storage.readBytes(imagePath);
            if (bytes.length > 4 * 1024 * 1024) return null;
            return {'mime': mime, 'data': base64Encode(bytes)};
          } catch (_) {
            return null;
          }
        },
      );
      controller.addJavaScriptHandler(
        handlerName: 'editorChange',
        callback: (args) {
          if (args.isNotEmpty) {
            final value = Json.from(args.first as Map);
            _changed(value['text'] as String, value['composing'] == true);
          }
          return null;
        },
      );
      controller.addJavaScriptHandler(
        handlerName: 'editorBlur',
        callback: (_) {
          unawaited(_save());
          return null;
        },
      );
    },
    onLoadStop: (_, _) => _loadWeb(),
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame == true && mounted) {
        setState(() {
          webFailed = true;
          message = '预览组件无法加载，已切换为纯文本编辑：${error.description}';
        });
      }
    },
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_back());
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _back,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.entry.name),
            Text(
              '${widget.folder.label} · ${saving
                  ? "保存中"
                  : blocked
                  ? "草稿已保留"
                  : dirty
                  ? "待保存"
                  : "已保存到本机"}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          PopupMenuButton<bool>(
            tooltip: '正文两侧间距',
            icon: const Icon(Icons.horizontal_distribute_rounded),
            onSelected: widget.app.setEditorMargins,
            itemBuilder: (_) => [
              for (final value in [false, true])
                CheckedPopupMenuItem<bool>(
                  value: value,
                  checked: widget.app.editorMargins == value,
                  child: Text('正文两侧间距：${value ? "有" : "无"}'),
                ),
            ],
          ),
          if (widget.entry.isMarkdown)
            IconButton(
              tooltip: source ? '实时预览' : 'Markdown 源码',
              onPressed: () {
                setState(() => source = !source);
                web?.evaluateJavascript(
                  source: 'window.leafmesh?.command("source")',
                );
              },
              icon: Icon(source ? Icons.preview_rounded : Icons.code_rounded),
            ),
          IconButton(
            tooltip: '立即保存',
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (message != null)
            MaterialBanner(
              content: Text(message!),
              actions: blocked
                  ? [
                      TextButton(
                        onPressed: _compare,
                        child: const Text('查看差异'),
                      ),
                      TextButton(
                        onPressed: _saveCopy,
                        child: const Text('另存草稿'),
                      ),
                      TextButton(onPressed: _reload, child: const Text('重新加载')),
                    ]
                  : [
                      TextButton(
                        onPressed: () => setState(() => message = null),
                        child: const Text('知道了'),
                      ),
                    ],
            ),
          Expanded(
            child: !loaded
                ? Center(
                    child: message == null
                        ? const CircularProgressIndicator()
                        : Text(message!),
                  )
                : webFailed
                ? Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: 20,
                      horizontal: widget.app.editorMargins ? 24 : 0,
                    ),
                    child: TextField(
                      controller: fallback,
                      expands: true,
                      minLines: null,
                      maxLines: null,
                      onChanged: (value) =>
                          _changed(value, fallback.value.composing.isValid),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                      ),
                      style: const TextStyle(fontSize: 16, height: 1.8),
                    ),
                  )
                : (editorSurface ??= _createEditorSurface()),
          ),
          if (loaded && !webFailed)
            SafeArea(
              top: false,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final item in const [
                        ('heading', '标题', Icons.title_rounded),
                        ('bold', '加粗', Icons.format_bold_rounded),
                        ('italic', '斜体', Icons.format_italic_rounded),
                        ('list', '列表', Icons.format_list_bulleted_rounded),
                        ('task', '任务', Icons.check_box_outlined),
                        ('quote', '引用', Icons.format_quote_rounded),
                        ('code', '代码', Icons.code_rounded),
                        ('link', '链接', Icons.link_rounded),
                        ('image', '图片', Icons.image_outlined),
                        ('undo', '撤销', Icons.undo_rounded),
                        ('redo', '重做', Icons.redo_rounded),
                      ])
                        IconButton(
                          tooltip: item.$2,
                          onPressed: () => web?.evaluateJavascript(
                            source:
                                'window.leafmesh?.command(${jsonEncode(item.$1)})',
                          ),
                          icon: Icon(item.$3),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
