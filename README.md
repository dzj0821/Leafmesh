# Leafmesh

Leafmesh 是面向 Windows / Android 的本地优先文件与 Markdown 笔记应用。
名称中的 Leaf 对应笔记与灵感，mesh 对应可信设备间的分布式同步。

项目目录：`E:\Projects\Leafmesh`。原始工作区副本保留，迁入时已逐文件校验。

## 当前实现

- Flutter 文件主页：Windows 文件夹侧栏、手机右侧滑出列表、当前目录搜索、创建、重命名、删除。
- Syncthing v2.1.7 核心控制：Device ID / 二维码配对、待接受共享、逐文件夹授权、状态与事件、暂停和扫描。
- 完整双向副本；使用 Syncthing 的版本、内容块、删除和冲突机制。
- 各设备独立的 `.stignore`；提供本机编辑入口，不同步或统一规则。
- 本地打包的 CodeMirror 编辑器：Markdown 实时预览、源码切换、键盘上方格式栏和相对路径图片。
- 正文两侧间距可选无 / 有，偏好保存在本机；有间距时正文居中且左右对称。
- 草稿恢复、写入前版本校验、远端更新提示、文本冲突对比和保留版本。
- Windows 核心进程托管；最小化后继续同步，正常退出时停止本机核心。
- Android Go 核心桥接、SAF 目录适配、用户主动开启的后台服务及超时处理。
- 两种 Android 存储的迁移：暂停、复制、校验、切换绑定；保留旧副本。

详细行为见 [SPEC.md](SPEC.md)。本期不发布 macOS / iOS。

## 验证状态与限制

已完成 Windows 发布构建与 Android arm64 AAR / APK 编译。当前为 0.1.8 开发预览，入口见 [QUICKSTART.md](QUICKSTART.md)。

已运行：Dart 文件与草稿检查（22 项）、实际 REST API 检查（10 项）、三节点真实 Syncthing 集成测试、Windows 图形界面集成测试，以及 Go 桥接的路径和嵌入核心启动/停止测试。
静态分析无问题，编辑器资源离线打包。最终验证记录见 [TESTING.md](TESTING.md)。

Android 尚无连接的测试手机，未完成真机配对、输入法、跨网与存储迁移验证。
SAF 目录监听与替换语义不同于普通文件系统，必须经过真机中断/恢复测试；不承诺锁屏后始终在线。
Windows 目前通过最小化保持运行，尚未提供托盘图标，也未配置 Windows 代码签名。Android 使用固定 Release 签名。

## 工程结构

| 目录 | 用途 |
| --- | --- |
| `lib/` | Flutter 界面、核心 API、文件操作、草稿和迁移 |
| `editor/` | 离线 CodeMirror 编辑器源码与构建 |
| `assets/core/` | 校验过的 Syncthing 可执行文件和许可证 |
| `native/bridge/` | 自行编写的 Go 嵌入与 SAF 文件系统桥接 |
| `native/flutter_inappwebview_windows/` | 保留许可证的 Windows WebView 焦点修订版 |
| `android/` | Kotlin 生命周期、目录授权、SAF、迁移与通知服务 |
| `windows/` | 官方 Flutter Windows runner 模板 |
| `tool/` | 工具准备、构建与实际检查脚本 |

## 准备工具

需要 Python、Git、Node.js，以及对应平台的编译环境。
Windows 构建需要 Visual Studio 的“使用 C++ 的桌面开发”组件；Android 需要 JDK 17+、SDK 和 NDK，并由使用者完成 SDK 许可确认。

```powershell
python tool/bootstrap.py --flutter --core --go
python tool/run.py flutter pub get
python tool/run.py npm --prefix editor install --ignore-scripts --offline=false --cache tool/cache/npm
python tool/build_editor.py
```

工具安装在临时的项目专用缓存，支持 `LEAFMESH_TOOLS` 指定位置，不修改系统 PATH。
下载器默认直接连接，必要时可通过 `LEAFMESH_DOWNLOAD_PROXY` 指定下载代理。
Go 模块代理可通过 `LEAFMESH_GOPROXY` 指定，仍使用模块校验机制。

## 构建 Windows

```powershell
python tool/build_windows.py
```

脚本调用标准 Flutter 发布构建，成功后将 runner、Flutter 资源和核心打包为 `dist/Leafmesh-0.1.3-windows-x64.zip`；文件名随 `pubspec.yaml` 中的版本名更新。
同时更新固定解压目录 `dist/windows-portable`，可直接运行其中的 `leafmesh.exe`；后续 Windows 发布构建继续更新此目录。
若只需从现有 ZIP 恢复或更新解压目录，运行 `python tool/publish_windows.py`。如果该目录中的 Leafmesh 正在运行，脚本会让应用保存文件或草稿并正常退出，更新后以同一用户重新启动。
开发调试使用 `python tool/run.py flutter run -d windows`。

## 构建 Android

可运行 `python tool/setup_android.py` 准备便携 JDK 与 SDK 工具，再查看 `--help` 安装平台包并完成 SDK 许可确认；也可使用已有 `JAVA_HOME` / `ANDROID_HOME` 与 NDK。

```powershell
python tool/build_android.py --apk
```

Go 桥接构建使用固定的 Syncthing 源码标签，启用 `noassets`，不打包上游 Web GUI。
生成的 `leafmeshbridge.aar` 供 Kotlin 同进程加载，不通过 Android 子进程运行同步核心。
Android release 构建使用专用 RSA-4096 Release 签名，并校验 `android/release-certificate.sha256` 中锁定的证书指纹。
密钥及密码配置保存在 `%USERPROFILE%\.leafmesh\signing\android`，不包含在源码或交付包中。更换机器时应恢复此目录，或通过 `LEAFMESH_ANDROID_SIGNING_PROPERTIES` 指定恢复后的 `release.properties`。
缺失密钥或证书不符会停止 Release 打包。签名管理及备份说明见 [ANDROID_SIGNING.md](ANDROID_SIGNING.md)。
这些脚本不安装 APK、不注册系统服务、不自动接受许可。

## 检查命令

```powershell
python tool/run.py flutter analyze
python tool/run.py dart tool/storage_checks.dart
python tool/core_integration.py
python tool/api_integration.py
python tool/run.py flutter test
python tool/build_android.py --check
```

`dart pub get` 供受限环境下恢复依赖；完整平台构建仍需运行 `flutter pub get` 生成插件注册信息。
核心集成测试启动三个隔离的本地节点，关闭外部发现与中继，结束后关闭进程并保留日志用于检查。

## 开源组件

Syncthing 核心采用 MPL-2.0；编辑器依赖许可证随离线资源打包。
原生桥接自行编写，没有复制 GPL 授权的 Android 包装应用代码。
详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
