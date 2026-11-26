# Leafmesh 0.1.8 验证记录

本轮日期：2026-11-10。环境：Windows 11 x64；Flutter 3.47.9 / Dart 3.13.7；Syncthing v2.1.7；Android API 36 / NDK 28.2，最低 API 29。表中的同步及旧原生集成检查为历史记录。

## 已通过

| 检查 | 结果 |
| --- | --- |
| Flutter 静态分析 | 无问题 |
| Dart 文件与草稿 | 22 项，包括路径越界、Windows 驱动器相对路径、保留文件名、UTF-8、旧版本覆盖保护、删除文件保护、草稿隔离 |
| 实际 REST / Event API | 10 项，包括认证、Device ID 校验、防重复配对、显式共享默认值、长轮询及时取消、关闭客户端与独立管理请求 |
| 三个真实 Syncthing 节点 | 初次同步、2 MiB 哈希一致、每机独立忽略规则、原始节点离线后的副本同步、重新上线追赶、并发冲突保留、删除传播 |
| Windows 原生界面集成（0.1.1 历史记录） | 启动真实核心、文件列表、本机忽略规则、新建 Markdown、原生 WebView 加载离线 CodeMirror、标题与加粗自动保存、源码切换、关闭核心 |
| 手机返回导航（无窗口测试） | 6 项：设置、设备、拉取页的系统返回，许可逐级返回与标题栏返回，Android 宽屏布局，抽屉优先关闭；不控制系统鼠标、不激活桌面窗口 |
| 目录返回栏（无窗口测试） | 实际临时目录验证点击整行右侧空白、路径文字均返回上一级，根目录点击不越界；合计 7 项无窗口测试通过 |
| Markdown 标题显示 | 实际 WebView 验证首次打开的一级至六级标题、前导缩进 / 空格 / 制表符 / 末尾标记、聚焦与失焦、源码模式；无额外下划线，链接下划线保留，Markdown 原文不变 |
| Go 桥接 | Windows 嵌入核心启动 / API / 停止、路径边界；Android arm64 编译与 gomobile AAR 生成 |
| 发布构建 | Windows x64 Release 与 Android arm64 APK 已生成 |
| Android 包检查 | 固定 Release 证书、仅 arm64、ZIP 16 KiB 对齐、Go 原生库 LOAD 段 16 KiB 对齐；两端编辑器与当前源码一致 |
| Release 签名保护 | 重复初始化复用原证书；旧 Debug APK 被指纹校验拒绝；Gradle 在密钥缺失时停止；APK / ZIP 未含私钥或密码 |

当前 Android 为 `0.1.8`（内部 versionCode 11），Release 证书 SHA-256：`1ab0538ba7b59d5efba7eece1c5c0f821254d01204863b4f5cfa0758b442d60f`。证书与备份说明见 [ANDROID_SIGNING.md](ANDROID_SIGNING.md)。

### 0.1.8 Flutter 逻辑焦点回抢导致正文不能输入

本轮新增实际 Flutter EditorPage + 原生 WebView2 + 包内 CodeMirror 的编辑器链路集成测试。
只在私有 Windows 桌面执行；主程序在创建窗口前核对测试桌面名，调试输入接口也再次核对，
不调用 SwitchDesktop、SetCursorPos 或系统 SendInput。
不启动同步核心：扫描 API 使用测试响应，文件 / 草稿存储和自动保存则使用真实临时文件。

0.1.7 的同一测试首次点击失败：网页先获得焦点，约 34ms 后 document.hasFocus 变为 false，
原生键盘焦点回到 FLUTTERVIEW；实际 WM_CHAR 输入没有改变文档，也没有落盘。
Flutter 逻辑焦点记录为“编辑器节点 → Root Focus Scope → 编辑器节点”。
原因是 Native GotFocus 回调再次 requestFocus，触发 Flutter View Scope 的 requestViewFocusChange，
把刚交给浏览器子窗口的键盘焦点抢回 Flutter 原生视图。
0.1.7 的纯 Win32 / WebView2 测试没有 Flutter View Scope，因而无法发现这一层回抢。

0.1.8 不再从 Native GotFocus 反向请求 Flutter 逻辑焦点；仅在浏览器尚未持有键盘时，
在分发原生点击之前同步完成 Flutter 焦点切换和其他文本框的输入连接清理。
浏览器持有键盘时 Flutter 将逻辑焦点停放在 Root Focus Scope 是正常状态，不能为此强行恢复。

同一集成测试修复后通过：首次点击、外部 TextField 切回、再次点击正文三轮均保持编辑状态；
每轮输入后自动保存，再不点击正文继续输入，最后点击加粗按钮后继续输入。
7 个原生键盘字符均进入 CodeMirror 并写入真实文件，自动保存之后网页仍保持焦点。
无窗口回归另断言 Root Focus Scope 停放状态收到 Native GotFocus 不会重发 Flutter 焦点请求。

调试输入 / 状态探针只编译进 Debug，且要求测试环境标志与私有桌面名同时成立。
私有桌面没有系统前台窗口，Debug 测试以该桌面的活动窗口模拟前台判断；Release 不包含此替代逻辑。
交付包检查拒绝包含调试探针字符串的主程序或原生 DLL。

复现命令为 `python tool/run_editor_input_integration.py`，不能在用户桌面直接启动此测试。
本测试覆盖实际编辑器输入和落盘，不等同于 Android 实机输入法或完整同步端到端测试。

### 0.1.7 原生窗口激活与正文键盘焦点

0.1.6 包内 native DLL 已更新，但其 WebView2 输入父窗口仍是独立隐藏宿主。
真实 WebView2 的 SendMouseInput 会把输入焦点交给浏览器窗口；输入窗口在主窗口树外时，
活动顶层窗口变成隐藏宿主，应用标题栏失活。runner 还在 WA_INACTIVE 消息里无条件 SetFocus，
这是坐标 / HTML / 模拟平台通道测试无法覆盖的另一条原生窗口路径。

0.1.7 将 WebView2 Controller.ParentWindow 直接设为实际 Flutter 原生视图；不叠加可见原生窗口，
不在每次指针按下时调用 MoveFocus。Bounds 原点保留正文相对 Flutter 的偏移，避免重现坐标问题。
主窗口只在激活且当前输入焦点不在视图树内时恢复 Flutter 焦点；失活时不抢回。
原生浏览器焦点通知只同步 Flutter 的逻辑焦点，其他 Flutter 文本框获得焦点时才释放浏览器键盘焦点。
保存原始宿主句柄用于销毁，先关闭 Controller，再销毁原始宿主；不得销毁已变成 Flutter 的 ParentWindow。

新增私有 Win32 桌面测试（真实 STARTUPINFOW.lpDesktop，绝不调用 SwitchDesktop），
使用实际 WebView2 CompositionController、鼠标消息和 WM_CHAR，不调用系统 SendInput 或 SetCursorPos。
测试程序启动时检查桌面名，若运行在用户桌面就立即退出，不创建任何测试窗口。
同一测试中旧模型首次点击即失败：GetActiveWindow 变为隐藏宿主；修复模型保持主窗口活动，
连续点击四轮、原生键盘输入、其他控件取回键盘焦点、后台不抢焦点、其他窗口激活及关闭编辑器共 26 项检查通过。
非交互私有桌面的 GetForegroundWindow 为空，释放焦点函数在此状态拒绝操作；
测试核对这一保护后，再以显式模拟控件选择的 SetFocus 验证键盘可交回 Flutter。
这里测的是真实 WebView2 + Win32 集成，尚不是整个 Flutter 应用的端到端桌面测试。
13 项无窗口 Flutter 回归还覆盖 native focusChanged 通知、外部 TextField 释放和无焦点回抢循环。
原有 128 个真实浏览器命中场景、72 组原生坐标及 52 项编辑器断言继续通过。

参考：[插件作者对隐藏 HWND 焦点切换的说明](https://github.com/MicrosoftEdge/WebView2Feedback/issues/4944)，
[同类实现将输入父窗口放回 Flutter 视图树](https://github.com/omar-hanafy/webview_flutter_windows/blob/main/windows/webview.cc)。

### 0.1.6 点击与光标纵向偏移

无界面的 Chrome 通过 CDP 对字形实际位置发送页面内点击，没有控制系统鼠标。
修复前，128 个场景中 68 个失败：Markdown 标题的 CSS margin 不参与 CodeMirror 行高模型，
造成正文点击落到其他行；切换留白但选区不变时，光标层还可能保留旧坐标。
标题改用 padding，横向留白设在 cm-line，切换留白显式重测选区后，128 个场景全部通过。
覆盖 390 / 1200px 宽度，100% / 125% / 150% / 200% DPR，Markdown / 纯文本以及无 / 有间距。
断言同时比较实际字符位置、文档选区和屏幕光标，不将仅选区正确视为验证通过。

原生宿主定位改为 ClientToScreen，移除重复减去标题栏高度的估算。
真实 Win32 隐藏窗口执行 72 组检查：不同窗口位置（包括负屏幕坐标）、缩放及宿主类型，
全部保持宿主原点与 Flutter 正文位置一致，不显示或激活测试窗口。
Flutter 模拟通道另覆盖四档 DPR：布局变动后无悬停直接点击、抬起坐标，以及尺寸 / 缩放消息先于按键。

运行窗口结构及包内 DLL 哈希还确认：0.1.5 实际复用了 0.1.4 的原生 DLL。
原因是回退 native 源码时保留了旧时间戳，MSBuild 没有重新编译。
构建脚本新增按内容变更刷新 native 输入时间戳、拒绝已知错误 DLL、编译中源文件变化时停止发布；
windows-build.json 记录输入与 DLL 哈希，包检查核对编译输入、ZIP 中实际 DLL 和当前源码。

浏览器与隐藏窗口检查仍不是用户桌面中完整 WebView2 交互链的实机验证。

### 0.1.5 Windows 连续点击回归修复

用户报告 0.1.4 在光标稳定闪烁后，只能在切换焦点时响应一次，随后各区域点击失效。
该版本增加了原生 MoveFocus / SetFocus，以及将隐藏 composition 宿主改为 WS_CHILD 的修改。
MoveFocus 会使 Flutter 原生视图收到 WM_KILLFOCUS；同时原定位代码使用屏幕坐标，改为子窗口后产生重复偏移。
本轮只读窗口快照确认了隐藏宿主及重复偏移，没有控制系统鼠标或激活测试窗口。

0.1.5 源码恢复这两处原生文件至插件 0.6.0 上游版本，移除 Dart 对原生 setFocus 的调用；
其包内 DLL 未实际重编译的问题在 0.1.6 排查中发现并更正，见上一节。
保留关闭初始自动聚焦、移除延迟抢焦点，以及编辑器组件 / DOM 不重复重建的修复。
正文的 Flutter 焦点请求放在当前点击分发后的微任务中，避免其他文本框的外部点击处理将它清除。
回归测试连续五轮点击正文、格式按钮、间距菜单、其他文本框，验证每轮 down / up 配对、控件响应，
原生编辑器只创建一次，所有焦点切换均不触发隐藏 HWND 的焦点交接。
这些是模拟平台通道测试，不能替代真实 Windows 输入分发检查；本轮没有声称已实机复现或验证完整点击链。

正文宽度、居中、留白的 CSS 提高了选择器优先级，避免被 CodeMirror 基础样式覆盖。
无间距时两侧为零；有间距时窄屏两侧各 24px，宽屏居中并限制阅读宽度。
Chrome 无界面模式在 390px / 1200px 两种正文宽度执行 52 项断言，包括两侧对称、
重复加载保留 DOM / 焦点 / 选区、切换边距保留撤销历史、远端刷新与 nani 纯文本。
Flutter 使用模拟通道验证连续多控件点击、悬停不抢焦点，以及边距偏好持久化。

0.1.1 增加 `.nani` 纯文本打开的实际界面检查，以及加载中的编辑器指纹与应用版本一致的检查。版本名、文件名、设置页与发布清单统一取自 `pubspec.yaml`。
Windows 更新前会先通过本机带随机密钥的更新接口，等待编辑器保存文件或草稿、停止核心后再退出；界面集成测试检查了退出前刷新、未授权请求拒绝及正常更新握手。

### Android 标题显示排查

核对之前的 Android APK：其中的编辑器 HTML 与当时已修复的 Windows 源码完全相同。因此不能归因于修复文件未打包。旧版的应用内版本和 APK 文件名固定为 0.1.0，编辑器从固定文件 URL 加载且采用平台默认缓存策略，均不利于识别旧安装或旧资源。

0.1.1 改为从当前安装包读取 HTML 字符串直接加载，关闭 WebView 缓存，并以版本和内容生成的编辑器指纹进行运行时校验；不匹配时回退纯文本。Android 明确关闭初始自动聚焦，避免首次打开就将首行识别为编辑态。

当前没有 ADB 连接的手机，无法确认用户手机实际安装的版本或 WebView 缓存内容，也未将缓存原因宣称为已实机证实。Android 真机效果仍需验证。

编辑器构建现在使用回调嵌入脚本，防止 JavaScript 中的 `$&` 等内容被字符串替换误解释；构建时检查语法与占位符。原生界面测试覆盖此前发现的格式按钮未落盘问题，以及行首格式操作后的光标位置。

## 待真机与外网验证

当前没有连接的 Android 测试设备。下列行为已经实现，但本次没有实机验证：

- Android 安装启动、二维码相机授权、中文输入法组合输入、格式栏与键盘位置。
- Windows / Android 之间的配对与实际文件传输。
- SAF 双向迁移、授权撤回、空间不足、写入中断与重启恢复。
- Android 锁屏与后台服务时限、Wi-Fi / 流量切换。
- 跨运营商、UDP 受限与中继网络；大型文件断点恢复的端到端体验。

Windows 使用最小化保持同步，尚无托盘图标；Windows 文件未作生产代码签名，Android 使用独立 Release 签名。macOS / iOS 本期不构建。

## 复现

```powershell
python tool/run.py flutter analyze --no-pub
python tool/run.py dart tool/storage_checks.dart
python tool/core_integration.py
python tool/api_integration.py
python tool/run.py flutter test
python tool/editor_headless_checks.py
python tool/editor_pointer_checks.py
python tool/native_geometry_checks.py
python tool/windows_native_focus_checks.py
python tool/run_editor_input_integration.py
python tool/build_android.py --check
python tool/build_windows.py
python tool/build_android.py --apk
python tool/verify_packages.py
```

最后一项审计两个交付包的完整性、核心与编辑器资源、Android ABI 和 Windows 运行库，输出 `dist/SHA256SUMS.txt` 与 `package-manifest.json`。它不等同于安装或真机验证。

默认检查只运行 `test/` 中的无窗口测试。旧原生桌面集成测试标记为仅可在独立测试桌面显式启用，本次未执行。Windows 自动更新仅走本机保存退出接口，已去除旧版桌面控件自动化回退。
