import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../app_controller.dart';
import '../core/models.dart';

Future<void> showFailure(BuildContext context, Object error) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(error.toString()),
      duration: const Duration(seconds: 7),
      showCloseIcon: true,
    ),
  );
}

Future<String?> askText(
  BuildContext context,
  String title, {
  String value = '',
  String? hint,
  String action = '确定',
  bool multiline = false,
}) async {
  final controller = TextEditingController(text: value);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: multiline ? 8 : 1,
          maxLines: multiline ? 16 : 1,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: multiline
              ? null
              : (value) => Navigator.pop(context, value),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(action),
        ),
      ],
    ),
  );
  // Text field routes may animate out for one frame; do not dispose the controller early.
  Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
  return result;
}

Future<void> showMyId(BuildContext context, AppController app) => showDialog(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('配对这台设备'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('在另一台设备添加此 ID，并在两端确认信任。文件夹需要另行授权共享。'),
          const SizedBox(height: 20),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(
              data: app.myId,
              size: 210,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          SelectableText(app.myId, textAlign: TextAlign.center),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      FilledButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: app.myId));
        },
        icon: const Icon(Icons.copy_rounded),
        label: const Text('复制 ID'),
      ),
    ],
  ),
);

Future<void> showPair(
  BuildContext context,
  AppController app, {
  String initialId = '',
  String initialName = '',
}) async {
  final id = TextEditingController(text: initialId);
  final name = TextEditingController(text: initialName);
  String? error;
  bool working = false;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('添加可信设备'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('输入对方 Device ID。对方也需要添加本机 ID，双方确认后才能连接。'),
                const SizedBox(height: 18),
                TextField(
                  controller: id,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Device ID',
                    errorText: error,
                  ),
                ),
                if (Platform.isAndroid)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: working
                          ? null
                          : () async {
                              final scanned = await Navigator.push<String>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const ScanPage(),
                                ),
                              );
                              if (scanned != null) id.text = scanned;
                            },
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: const Text('扫描二维码'),
                    ),
                  ),
                const SizedBox(height: 14),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '设备名称（可选）'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: working ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: working
                ? null
                : () async {
                    setState(() {
                      working = true;
                      error = null;
                    });
                    try {
                      await app.pair(id.text, name.text);
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      setState(() {
                        error = e.toString();
                        working = false;
                      });
                    }
                  },
            child: Text(working ? '正在添加…' : '信任并添加'),
          ),
        ],
      ),
    ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    id.dispose();
    name.dispose();
  });
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool done = false;
  final scanner = MobileScannerController();
  @override
  void dispose() {
    scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描设备二维码')),
    body: MobileScanner(
      controller: scanner,
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          final raw = barcode.rawValue;
          if (raw == null || done) continue;
          try {
            final id = normalizeDeviceId(raw);
            done = true;
            Navigator.pop(context, id);
          } on FormatException {
            /* A camera can see unrelated QR codes. */
          }
        }
      },
    ),
  );
}

Future<void> showAddFolder(
  BuildContext context,
  AppController app, {
  FolderOffer? offer,
}) async {
  final label = TextEditingController(text: offer?.label ?? '');
  final chosen = <String>{...?(offer?.deviceIds)};
  var internal = Platform.isAndroid;
  String? location;
  String? error;
  var working = false;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(offer == null ? '共享文件夹' : '拉取共享文件夹'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: label,
                  decoration: const InputDecoration(labelText: '显示名称'),
                ),
                const SizedBox(height: 16),
                if (Platform.isAndroid)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: internal,
                    onChanged: working
                        ? null
                        : (value) => setState(() {
                            internal = value;
                            location = null;
                          }),
                    title: const Text('由应用管理'),
                    subtitle: Text(
                      internal ? '支持离线；卸载会删除本机文件及未同步内容' : '选择系统目录，卸载应用后文件仍保留',
                    ),
                  ),
                if (!internal)
                  OutlinedButton.icon(
                    onPressed: working
                        ? null
                        : () async {
                            try {
                              final path = Platform.isAndroid
                                  ? await app.pickAndroidDirectory()
                                  : await FilePicker.platform.getDirectoryPath(
                                      dialogTitle: '选择同步目录',
                                    );
                              if (path != null) setState(() => location = path);
                            } catch (e) {
                              setState(() => error = e.toString());
                            }
                          },
                    icon: const Icon(Icons.folder_open_rounded),
                    label: Text(location == null ? '选择本地目录' : '重新选择目录'),
                  ),
                if (location != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      Platform.isAndroid
                          ? Uri.decodeComponent(location!)
                          : location!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  offer == null ? '向哪些已配对设备共享' : '提供此文件夹的设备',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (app.peers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('尚无配对设备。可以先添加文件夹，之后再配置共享。'),
                  ),
                ...app.peers
                    .where(
                      (peer) =>
                          offer == null || offer.deviceIds.contains(peer.id),
                    )
                    .map(
                      (peer) => CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: chosen.contains(peer.id),
                        title: Text(peer.name),
                        subtitle: Text(peer.connectionLabel),
                        onChanged: working
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  chosen.add(peer.id);
                                } else {
                                  chosen.remove(peer.id);
                                }
                              }),
                      ),
                    ),
                if (offer != null) const Text('将保存完整副本，之后的修改和删除会双向同步。请选择空目录。'),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: working ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: working
                ? null
                : () async {
                    if (!internal && location == null) {
                      setState(() => error = '请先选择本地目录');
                      return;
                    }
                    if (offer != null && chosen.isEmpty) {
                      setState(() => error = '至少选择一个提供文件的设备');
                      return;
                    }
                    setState(() {
                      working = true;
                      error = null;
                    });
                    try {
                      await app.addFolder(
                        label: label.text,
                        devices: chosen.toList(),
                        location: location,
                        saf: Platform.isAndroid && !internal,
                        offer: offer,
                      );
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      setState(() {
                        working = false;
                        error = e.toString();
                      });
                    }
                  },
            child: Text(
              working
                  ? '正在添加…'
                  : offer == null
                  ? '开始共享'
                  : '拉取并同步',
            ),
          ),
        ],
      ),
    ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), label.dispose);
}

Future<void> showSharing(
  BuildContext context,
  AppController app,
  SyncFolder folder,
) async {
  final chosen = {...folder.deviceIds}..remove(app.myId);
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('共享“${folder.label}”'),
        content: SizedBox(
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('只向勾选的设备提供此文件夹，对方可以选择接受。'),
              ...app.peers.map(
                (peer) => CheckboxListTile(
                  value: chosen.contains(peer.id),
                  title: Text(peer.name),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      chosen.add(peer.id);
                    } else {
                      chosen.remove(peer.id);
                    }
                  }),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (result == true) {
    try {
      await app.updateSharing(folder, chosen.toList());
    } catch (e) {
      if (context.mounted) await showFailure(context, e);
    }
  }
}
