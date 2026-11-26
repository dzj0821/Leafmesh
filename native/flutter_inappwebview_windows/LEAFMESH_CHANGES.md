# Leafmesh Windows input patch

Based on flutter_inappwebview_windows 0.6.0 (Apache-2.0, see LICENSE).
The local dependency override contains the following input fixes:

- Disable initial autofocus and remove the delayed focus retry. Pointer-down
  completes Flutter input teardown synchronously before native mouse dispatch,
  only if the browser does not already own the keyboard. No delayed focus request.
- In 0.1.7, WebView2's input ParentWindow is the real Flutter view, not the
  independently hidden composition host. No visible overlay is added.
- Native GotFocus/LostFocus track keyboard ownership without requesting Flutter
  logical focus. Flutter's View Scope parks focus when a browser child owns the
  keyboard; restoring logical focus there requests native view focus and steals
  the keyboard back. Genuine external Flutter text inputs can release browser
  keyboard focus; view/window unfocus cannot.
- The runner does not focus its content on WA_INACTIVE or replace focus already
  held by an input descendant. There is no per-click native MoveFocus call.
- Controller bounds include the editor's offset within Flutter. The original
  separately owned host is tracked and destroyed only after Controller.Close;
  the reparented Flutter view is never treated as an owned host.

The 0.1.4 native MoveFocus/WS_CHILD changes were withdrawn in 0.1.5 after the
user reported that clicks stopped working. The headless channel-order test did
not cover native window dispatch and was insufficient evidence of a fix.

The independent editor fixes remain: retain the WebView widget and editable DOM
across status rebuilds and idempotent loads; layout changes do not reload text.

0.1.6 also fixes composition-host positioning with ClientToScreen, replacing
the estimated title-bar subtraction. Pointer down/up carry their current local
coordinates, size/scale updates precede input, and display metrics come from
the widget's Flutter view. No native focus handoff is added.

0.1.5 originally reused the 0.1.4 native DLL because restored native files kept
older timestamps. The Windows builder now invalidates changed native inputs
by content, rejects the known bad DLL, and records the compiled input/DLL audit.
It stops publication if source files change during compilation.

Validation includes headless Flutter widgets and a real WebView2 composition
test on a private Windows desktop that is never switched to. The old model
fails activation on its first click; the fixed model passes click/keyboard,
activation and teardown checks. No system mouse input is used.

0.1.8 adds the actual Flutter EditorPage/CodeMirror integration fixture. Before
the fix, a native focus event caused View Scope to return focus to FLUTTERVIEW
and typing failed. The fixed fixture verifies actual native characters, repeated
clicks, outside-input handoff, toolbar formatting and real file autosave. Debug
probes and a private-desktop-only foreground model are excluded from Release.

References (implementation written for Leafmesh, not copied from a different plugin):
https://github.com/MicrosoftEdge/WebView2Feedback/issues/4944
https://github.com/omar-hanafy/webview_flutter_windows/blob/main/windows/webview.cc
