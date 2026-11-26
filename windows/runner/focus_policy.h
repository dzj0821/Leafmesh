#pragma once
#include <windows.h>

// Never reactivate an inactive window, or replace keyboard focus already held
// by an input descendant (for example WebView2) in the Flutter view's tree.
inline void FocusContentOnActivation(HWND content, WPARAM activation) {
  if (!content || LOWORD(activation) == WA_INACTIVE || HIWORD(activation)) return;
  const HWND focused = GetFocus();
  if (focused != content && !IsChild(content, focused)) SetFocus(content);
}
