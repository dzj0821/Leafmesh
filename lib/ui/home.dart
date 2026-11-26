import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import '../app_controller.dart';
import '../build_info.dart';
import '../core/models.dart';
import '../storage/migration.dart';
import '../storage/repository.dart';
import 'dialogs.dart';
import 'editor_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app});
  final AppController app;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, WindowListener {
  final scaffold = GlobalKey<ScaffoldState>();
  int section = 0;
  bool closing = false;
  AppController get app => widget.app;
  bool get mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  String _sectionTitle(int value) => switch (value) {
    1 => '设备与配对',
    2 => '可拉取的文件夹',
    3 => '设置',
    _ => app.selected?.label ?? 'Leafmesh',
  };

  Widget _sectionBody(int value) => switch (value) {
    1 => _devices(),
    2 => _offers(),
    3 => _settings(),
    _ =>
      app.selected == null
          ? _empty()
          : FileBrowser(
              key: ValueKey('${app.selected!.id}:${app.selected!.path}'),
              app: app,
              folder: app.selected!,
            ),
  };

  void _openSection(int value, {required bool drawer}) {
    if (!drawer && !mobile) {
      setState(() => section = value);
      return;
    }
    final navigator = Navigator.of(context);
    if (drawer) navigator.pop();
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: switch (value) {
              1 => '/devices',
              2 => '/incoming-folders',
              _ => '/settings',
            },
          ),
          builder: (routeContext) => Scaffold(
            appBar: AppBar(
              title: Text(_sectionTitle(value)),
              leading: BackButton(
                onPressed: () => Navigator.of(routeContext).pop(),
              ),
            ),
            body: AnimatedBuilder(
              animation: app,
              builder: (_, _) => Column(
                children: [
                  if (app.busy) const LinearProgressIndicator(minHeight: 2),
                  Expanded(child: _sectionBody(value)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !app.starting) {
      unawaited(app.refresh());
    }
  }

  @override
  void onWindowClose() async {
    if (closing) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('让文件继续同步？'),
        content: const Text('最小化后继续运行；退出会停止本机同步，其他在线设备不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'exit'),
            child: const Text('退出'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'minimize'),
            child: const Text('最小化并继续'),
          ),
        ],
      ),
    );
    if (choice == 'minimize') {
      await windowManager.minimize();
    }
    if (choice == 'exit') {
      closing = true;
      try {
        await app.prepareForUpdate();
        await app.shutdown();
        await windowManager.destroy();
      } catch (error) {
        closing = false;
        if (mounted) await showFailure(context, error);
      }
    }
  }

  Widget _sidebar({bool drawer = false}) => SafeArea(
    child: SizedBox(
      width: drawer ? 300 : 258,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.spa_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 30,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Leafmesh',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 5, bottom: 30),
              child: Text(
                '文件相连，灵感随行',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Text('共享文件夹', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (app.folders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        '添加一个文件夹，\n让文件在设备间流动。',
                        style: TextStyle(height: 1.8),
                      ),
                    ),
                  ...app.folders.map(
                    (folder) => Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        selected: section == 0 && folder.id == app.selected?.id,
                        selectedTileColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          folder.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(folder.stateLabel),
                        onTap: () {
                          app.select(folder.id);
                          setState(() => section = 0);
                          if (drawer) Navigator.pop(context);
                        },
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: app.online && !app.busy
                        ? () => showAddFolder(context, app)
                        : null,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('共享文件夹'),
                  ),
                ],
              ),
            ),
            const Divider(height: 32),
            ListTile(
              selected: section == 1,
              leading: const Icon(Icons.devices_rounded),
              title: const Text('设备与配对'),
              trailing: app.pendingDevices.isNotEmpty
                  ? Badge(label: Text('${app.pendingDevices.length}'))
                  : null,
              onTap: () => _openSection(1, drawer: drawer),
            ),
            ListTile(
              selected: section == 2,
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('可拉取的文件夹'),
              trailing: app.offers.isNotEmpty
                  ? Badge(label: Text('${app.offers.length}'))
                  : null,
              onTap: () => _openSection(2, drawer: drawer),
            ),
            ListTile(
              selected: section == 3,
              leading: const Icon(Icons.tune_rounded),
              title: const Text('设置与许可'),
              onTap: () => _openSection(3, drawer: drawer),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  app.online
                      ? Icons.check_circle_outline_rounded
                      : Icons.cloud_off_outlined,
                  size: 16,
                  color: app.online
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    app.online ? '本机同步核心已连接' : '同步核心未连接',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) {
      if (app.starting) {
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.spa_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 24),
                const Text('正在准备你的文件空间'),
                const SizedBox(height: 18),
                const SizedBox(width: 150, child: LinearProgressIndicator()),
              ],
            ),
          ),
        );
      }
      if (app.myId.isEmpty) {
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sync_problem_rounded, size: 48),
                    const SizedBox(height: 20),
                    Text(
                      '同步核心未能启动',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(app.error ?? '请重试启动'),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: app.initialize,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return LayoutBuilder(
        builder: (context, bounds) {
          final wide = bounds.maxWidth >= 850;
          return PopScope(
            canPop: (wide && !mobile) || section == 0,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && section != 0 && (!wide || mobile)) {
                setState(() => section = 0);
              }
            },
            child: Scaffold(
              key: scaffold,
              endDrawer: wide ? null : Drawer(child: _sidebar(drawer: true)),
              appBar: wide
                  ? null
                  : AppBar(
                      leading: section == 0
                          ? null
                          : BackButton(
                              onPressed: () => setState(() => section = 0),
                            ),
                      title: Text(_sectionTitle(section)),
                      actions: [
                        IconButton(
                          tooltip: '切换文件夹',
                          onPressed: () =>
                              scaffold.currentState?.openEndDrawer(),
                          icon: const Icon(Icons.folder_open_outlined),
                        ),
                      ],
                    ),
              body: Row(
                children: [
                  if (wide) _sidebar(),
                  if (wide) const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        if (app.busy)
                          const LinearProgressIndicator(minHeight: 2),
                        if (!app.online)
                          MaterialBanner(
                            content: Text(app.error ?? '正在重新连接同步核心，本地文件仍可离线使用'),
                            actions: [
                              TextButton(
                                onPressed: app.refresh,
                                child: const Text('重试连接'),
                              ),
                            ],
                          ),
                        Expanded(child: _sectionBody(section)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_copy_outlined,
            size: 66,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text('把文件放在身边', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          const Text(
            '从电脑共享一个文件夹，或配对设备后拉取文件。\n文件留在你的设备上，也能随时记录新的想法。',
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.8),
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => showAddFolder(context, app),
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加文件夹'),
              ),
              OutlinedButton.icon(
                onPressed: () => showPair(context, app),
                icon: const Icon(Icons.devices_rounded),
                label: const Text('配对设备'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _section(
    String title,
    String subtitle,
    List<Widget> content, {
    Widget? action,
  }) => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.7),
        ),
        const SizedBox(height: 28),
        ...content,
      ],
    ),
  );

  Widget _devices() => _section(
    '让设备相连',
    '通过 Syncthing Device ID 配对。两端确认信任后，分别选择要共享的文件夹。',
    [
      Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(18),
          leading: const Icon(Icons.qr_code_rounded, size: 30),
          title: const Text('这台设备的配对码'),
          subtitle: Text(
            app.myId,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showMyId(context, app),
        ),
      ),
      const SizedBox(height: 24),
      if (app.pendingDevices.isNotEmpty) ...[
        Text('收到配对请求', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        ...app.pendingDevices.entries.map(
          (e) => Card(
            child: ListTile(
              leading: const Icon(Icons.person_add_outlined),
              title: Text((e.value as Map)['name'] as String? ?? '新设备'),
              subtitle: Text(e.key, maxLines: 2),
              trailing: TextButton(
                onPressed: () => showPair(
                  context,
                  app,
                  initialId: e.key,
                  initialName: (e.value as Map)['name'] as String? ?? '',
                ),
                child: const Text('查看并配对'),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
      Text('已配对设备', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      if (app.peers.isEmpty) const Text('还没有配对设备。添加对方的 ID，即可开始。'),
      ...app.peers.map(
        (peer) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Icon(
                peer.connected
                    ? Icons.devices_rounded
                    : Icons.devices_other_rounded,
              ),
              title: Text(peer.name),
              subtitle: Text(
                '${peer.connectionLabel}\n${peer.id}',
                maxLines: 3,
              ),
              isThreeLine: true,
              trailing: Icon(
                peer.connected ? Icons.link_rounded : Icons.link_off_rounded,
                color: peer.connected
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            ),
          ),
        ),
      ),
    ],
    action: FilledButton.icon(
      onPressed: () => showPair(context, app),
      icon: const Icon(Icons.add_rounded),
      label: const Text('添加'),
    ),
  );

  Widget _offers() => _section(
    '可拉取的文件夹',
    '这里只显示已配对设备授权给本机的文件夹。拉取后保存完整副本，修改和删除双向同步。',
    [
      if (app.offers.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('暂时没有待接受的共享。请在另一台设备选择文件夹，并向本机共享。'),
          ),
        ),
      ...app.offers.map(
        (offer) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(18),
              leading: const Icon(Icons.drive_folder_upload_outlined),
              title: Text(offer.label),
              subtitle: Text('${offer.deviceIds.length} 台设备提供 · ${offer.id}'),
              trailing: FilledButton(
                onPressed: () => showAddFolder(context, app, offer: offer),
                child: const Text('拉取'),
              ),
            ),
          ),
        ),
      ),
    ],
    action: IconButton(
      onPressed: app.refresh,
      tooltip: '刷新',
      icon: const Icon(Icons.refresh_rounded),
    ),
  );

  Widget _settings() =>
      _section('为自己的节奏而设', 'Leafmesh 将文件保存在本机，以 Syncthing 在可信设备之间同步。', [
        Card(
          child: ListTile(
            title: const Text('应用版本'),
            subtitle: const SelectableText(BuildInfo.version),
          ),
        ),
        const SizedBox(height: 12),
        if (Platform.isAndroid)
          Card(
            child: SwitchListTile.adaptive(
              value: app.background,
              title: const Text('后台继续同步'),
              subtitle: const Text('启用后显示系统通知；受系统限制时，下次打开会补同步。'),
              onChanged: (value) async {
                try {
                  await app.setBackground(value);
                } catch (e) {
                  if (mounted) await showFailure(context, e);
                }
              },
            ),
          ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('正文两侧间距'),
                const SizedBox(height: 8),
                const Text('有间距时正文居中，左右留白相同；无间距时铺满正文区域。'),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('无')),
                    ButtonSegment(value: true, label: Text('有')),
                  ],
                  selected: {app.editorMargins},
                  onSelectionChanged: (values) =>
                      app.setEditorMargins(values.single),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: const Text('同步核心'),
            subtitle: Text('Syncthing ${app.coreVersion} · 原生 P2P 与加密中继'),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: const Text('本机忽略规则'),
            subtitle: const Text('每个文件夹的菜单中编辑 .stignore；规则不在设备间同步。'),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: const Text('应用数据目录'),
            subtitle: SelectableText(app.supportPath),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: const Text('开源许可'),
            subtitle: const Text('Syncthing · Flutter · CodeMirror'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Leafmesh',
              applicationVersion: BuildInfo.version,
            ),
          ),
        ),
      ]);
}

class FileBrowser extends StatefulWidget {
  const FileBrowser({super.key, required this.app, required this.folder});
  final AppController app;
  final SyncFolder folder;
  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  String directory = '', query = '';
  bool loading = true;
  String? error;
  List<FileEntry> entries = [];
  Timer? reloadTimer;
  StreamSubscription<Json>? changes;
  late final storage = FolderStorage.forFolder(widget.folder);
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    changes = widget.app.fileChanges.stream.listen((event) {
      if ((event['data'] as Map?)?['folder'] == widget.folder.id) {
        reloadTimer?.cancel();
        reloadTimer = Timer(
          const Duration(milliseconds: 400),
          () => unawaited(_load()),
        );
      }
    });
  }

  @override
  void didUpdateWidget(FileBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folder.path != widget.folder.path) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    reloadTimer?.cancel();
    unawaited(changes?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await storage.list(directory);
      if (mounted) {
        setState(() {
          entries = result;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString();
        });
      }
    }
  }

  Future<void> _open(FileEntry entry) async {
    if (widget.app.busy) return;
    if (entry.isDirectory) {
      setState(() {
        directory = entry.relativePath;
        loading = true;
      });
      await _load();
      return;
    }
    if (entry.isText) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              EditorPage(app: widget.app, folder: widget.folder, entry: entry),
        ),
      );
      await _load();
    } else if (entry.isImage) {
      try {
        final bytes = await storage.readBytes(entry.relativePath);
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              child: Stack(
                children: [
                  InteractiveViewer(child: Image.memory(bytes)),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) await showFailure(context, e);
      }
    } else {
      if (Platform.isAndroid) {
        try {
          await FolderStorage.channel.invokeMethod('storageOpen', {
            'root': storage.root,
            'path': entry.relativePath,
            'saf': storage.saf,
          });
        } catch (e) {
          if (mounted) await showFailure(context, e);
        }
      } else {
        if (!await launchUrl(
          Uri.file(p.join(widget.folder.path, entry.relativePath)),
        )) {
          if (mounted) await showFailure(context, '没有找到可以打开此文件的应用');
        }
      }
    }
  }

  Future<void> _goUp() async {
    if (directory.isEmpty) return;
    setState(() {
      final parent = p.posix.dirname(directory);
      directory = parent == '.' ? '' : parent;
    });
    await _load();
  }

  Future<void> _new(bool folder) async {
    if (widget.app.busy) return;
    final value = await askText(
      context,
      folder ? '新建文件夹' : '新建笔记',
      value: folder ? '' : '新的灵感.md',
      action: '创建',
    );
    if (value == null) return;
    try {
      FolderStorage.validateName(value);
      final relative = p.posix.join(directory, value);
      if (folder) {
        await storage.mkdir(relative);
      } else {
        await storage.saveText(relative, '', expectedHash: null);
      }
      await _load();
      unawaited(widget.app.api.scan(widget.folder.id).catchError((_) {}));
      if (!folder && mounted) {
        await _open(entries.firstWhere((e) => e.relativePath == relative));
      }
    } catch (e) {
      if (mounted) await showFailure(context, e);
    }
  }

  Future<void> _compareConflict(FileEntry entry) async {
    final original = entry.relativePath.replaceFirst(
      RegExp(r'\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Za-z0-9]+'),
      '',
    );
    if (original == entry.relativePath) {
      await showFailure(context, '无法识别原文件名，请保留两份并手动处理');
      return;
    }
    try {
      final current = await storage.readText(original);
      final conflict = await storage.readText(entry.relativePath);
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择保留的内容'),
          content: SizedBox(
            width: 800,
            height: 440,
            child: LayoutBuilder(
              builder: (context, bounds) {
                Widget panel(String title, String value) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Divider(),
                        Expanded(
                          child: SingleChildScrollView(
                            child: SelectableText(value),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
                final children = [
                  panel('当前文件', current.text),
                  panel('冲突副本', conflict.text),
                ];
                return bounds.maxWidth < 550
                    ? Column(children: children)
                    : Row(children: children);
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('保留两份'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'current'),
              child: const Text('仅保留当前文件'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'conflict'),
              child: const Text('使用冲突副本'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      if (choice == 'conflict') {
        await storage.saveText(
          original,
          conflict.text,
          expectedHash: current.hash,
        );
      } else if ((await storage.readText(original)).hash != current.hash) {
        throw const DiskChangedException('当前文件又有更新，已保留两份，请重新查看');
      }
      if ((await storage.readText(entry.relativePath)).hash != conflict.hash) {
        throw const DiskChangedException('冲突副本又有更新，已保留，请重新查看');
      }
      await storage.delete(entry.relativePath, directory: false);
      await _load();
      await widget.app.api.scan(widget.folder.id);
    } catch (error) {
      if (mounted) await showFailure(context, error);
    }
  }

  Future<void> _rename(FileEntry entry) async {
    if (widget.app.busy) return;
    final name = await askText(context, '重命名', value: entry.name);
    if (name == null || name == entry.name) return;
    try {
      FolderStorage.validateName(name);
      await storage.rename(
        entry.relativePath,
        p.posix.join(directory, name),
        directory: entry.isDirectory,
      );
      await _load();
      await widget.app.api.scan(widget.folder.id);
    } catch (e) {
      if (mounted) await showFailure(context, e);
    }
  }

  Future<void> _delete(FileEntry entry) async {
    if (widget.app.busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除“${entry.name}”？'),
        content: const Text('此删除会同步到共享此文件夹的其他设备。文件夹必须为空才能删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除并同步'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await storage.delete(entry.relativePath, directory: entry.isDirectory);
      await _load();
      await widget.app.api.scan(widget.folder.id);
    } catch (e) {
      if (mounted) await showFailure(context, e);
    }
  }

  Future<void> _ignores() async {
    try {
      final current = await widget.app.readIgnores(widget.folder.id);
      if (!mounted) return;
      final text = await askText(
        context,
        '本机 .stignore',
        value: current,
        multiline: true,
        hint: '// 每行一个规则，首次匹配生效\n*.tmp\nnode_modules\n!keep.txt',
        action: '保存本机规则',
      );
      if (text != null) await widget.app.saveIgnores(widget.folder.id, text);
    } catch (e) {
      if (mounted) await showFailure(context, e);
    }
  }

  Future<void> _migrate() async {
    final internal = Platform.isAndroid
        ? await showDialog<bool>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('迁移到哪里？'),
              children: [
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('应用内部目录（卸载会删除）'),
                ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('系统选择的本地目录'),
                ),
              ],
            ),
          )
        : false;
    if (internal == null) return;
    String? target;
    final saf = Platform.isAndroid && !internal;
    if (internal) {
      target = await widget.app.managedPath(
        '${widget.folder.id}-migration-${DateTime.now().microsecondsSinceEpoch}',
      );
    } else {
      target = saf
          ? await widget.app.pickAndroidDirectory()
          : await FilePicker.platform.getDirectoryPath(
              dialogTitle: '选择空的迁移目标目录',
            );
    }
    if (target == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('迁移本机副本'),
        content: const Text('同步会暂停，文件复制并校验后恢复。旧副本保留。迁移时请不要用其他编辑器修改源目录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始迁移'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.app.perform(
        () => StorageMigration(
          widget.app.api,
          widget.app.supportPath,
        ).migrate(widget.folder, target!, saf: saf),
      );
      if (mounted) await showFailure(context, '迁移完成，旧副本已保留');
    } catch (e) {
      if (mounted) await showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = entries
        .where((e) => e.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 16, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.folder.label,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${widget.folder.stateLabel} · ${entries.length} 个项目',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新文件列表',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
              PopupMenuButton<String>(
                tooltip: '文件夹设置',
                onSelected: (value) async {
                  try {
                    switch (value) {
                      case 'share':
                        await showSharing(context, widget.app, widget.folder);
                      case 'ignore':
                        await _ignores();
                      case 'pause':
                        await widget.app.togglePause(widget.folder);
                      case 'scan':
                        await widget.app.api.scan(widget.folder.id);
                      case 'migrate':
                        await _migrate();
                    }
                  } catch (e) {
                    if (context.mounted) await showFailure(context, e);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'share', child: Text('共享到设备')),
                  const PopupMenuItem(value: 'ignore', child: Text('本机忽略规则')),
                  PopupMenuItem(
                    value: 'pause',
                    child: Text(widget.folder.paused ? '恢复同步' : '暂停同步'),
                  ),
                  const PopupMenuItem(value: 'scan', child: Text('立即扫描')),
                  const PopupMenuItem(value: 'migrate', child: Text('迁移本机存储')),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: '搜索当前目录',
                    prefixIcon: Icon(Icons.search_rounded),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => query = value),
                ),
              ),
              const SizedBox(width: 10),
              PopupMenuButton<bool>(
                tooltip: '新建',
                onSelected: _new,
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: false,
                    child: Text('新建 Markdown 笔记'),
                  ),
                  const PopupMenuItem(value: true, child: Text('新建文件夹')),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.add_rounded),
                ),
              ),
            ],
          ),
        ),
        Tooltip(
          message: directory.isEmpty ? '已在根目录' : '返回上一级',
          child: InkWell(
            key: const ValueKey('parent-directory-row'),
            onTap: directory.isEmpty ? null : _goUp,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        size: 18,
                        color: directory.isEmpty
                            ? Theme.of(context).disabledColor
                            : null,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        directory.isEmpty ? '全部文件' : directory,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('$error\n请检查目录是否可用或重新授予访问权限。'),
                  ),
                )
              : visible.isEmpty
              ? Center(
                  child: Text(query.isEmpty ? '这里还没有文件，写下第一个想法吧。' : '没有匹配的文件'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 2),
                    itemBuilder: (context, index) {
                      final entry = visible[index];
                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        leading: Icon(
                          entry.isDirectory
                              ? Icons.folder_outlined
                              : entry.isConflict
                              ? Icons.difference_outlined
                              : entry.isMarkdown
                              ? Icons.article_outlined
                              : entry.isImage
                              ? Icons.image_outlined
                              : Icons.insert_drive_file_outlined,
                          color: entry.isDirectory
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          entry.isConflict
                              ? '同步冲突副本 · 内容已保留'
                              : entry.isDirectory
                              ? '文件夹'
                              : readableBytes(entry.size),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) => switch (value) {
                            'rename' => _rename(entry),
                            'compare' => _compareConflict(entry),
                            _ => _delete(entry),
                          },
                          itemBuilder: (_) => [
                            if (entry.isConflict && entry.isText)
                              const PopupMenuItem(
                                value: 'compare',
                                child: Text('比较并处理冲突'),
                              ),
                            const PopupMenuItem(
                              value: 'rename',
                              child: Text('重命名'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除'),
                            ),
                          ],
                        ),
                        onTap: () => _open(entry),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
