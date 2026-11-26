# 第三方组件

Leafmesh使用 Syncthing 核心，版权属于 Syncthing Authors，许可证为 MPL-2.0。
核心源码及发行版本：https://github.com/syncthing/syncthing/tree/v2.1.7
安装包须附带核心发行包中的 LICENSE.txt 和 AUTHORS.txt。
如修改 MPL 覆盖的源码，发行时应提供对应源码和修改记录。

编辑器使用 CodeMirror 6（MIT）和 Markdown 相关依赖，其版权与完整许可证由
editor 构建脚本收集进 assets/editor/THIRD_PARTY_LICENSES.txt。

Android 桥接自行编写，不复制 GPL 授权的 Android 包装应用代码。
Flutter 依赖的许可证可在应用“关于 / 开源许可”页查看。

Windows WebView 使用 flutter_inappwebview_windows 0.6.0 的本地焦点修订版，
采用 Apache-2.0 许可证；源码、原许可证及修改说明保留在
native/flutter_inappwebview_windows 中。
