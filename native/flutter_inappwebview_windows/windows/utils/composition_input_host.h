// Leafmesh: put WebView2 input in the real Flutter window tree, without adding
// a visible native overlay or moving focus on each pointer-down.
#pragma once
#include <windows.h>
#include <WebView2.h>
#include <cwchar>

namespace flutter_inappwebview_plugin {
#ifdef _DEBUG
  inline bool isolatedInputTestDesktop() {
    wchar_t enabled[4]{};wchar_t name[256]{};DWORD length=0;
    return GetEnvironmentVariableW(L"LEAFMESH_ISOLATED_TEST_DESKTOP",enabled,4)>0 &&
      GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,name,sizeof(name),&length) &&
      wcsncmp(name,L"LeafmeshFocus_",14)==0;
  }
#endif
  inline bool inputForegroundOwnedBy(HWND flutter) {
    const HWND root=GetAncestor(flutter,GA_ROOT);
    if(GetForegroundWindow()==root) return true;
#ifdef _DEBUG
    // A noninteractive test desktop has no foreground window. Model foreground
    // using its active window, only in a verified private test desktop/debug build.
    if(!GetForegroundWindow() && isolatedInputTestDesktop()) return GetActiveWindow()==root;
#endif
    return false;
  }
  inline HRESULT attachCompositionInput(ICoreWebView2Controller* controller, HWND flutter) {
    return controller && flutter ? controller->put_ParentWindow(flutter) : E_INVALIDARG;
  }

  inline void releaseCompositionInput(HWND flutter, bool controllerHasFocus) {
    if (!flutter || !controllerHasFocus) return;
    const HWND focused = GetFocus();
    if (inputForegroundOwnedBy(flutter) &&
        focused != flutter && IsChild(flutter, focused)) SetFocus(flutter);
  }

  inline void closeCompositionInput(ICoreWebView2Controller* controller,
      HWND ownedHost, HWND flutter) {
    if (controller) controller->Close();
    // ParentWindow is now Flutter. Only the original, separately owned host
    // may be destroyed; never destroy the controller's current parent.
    if (ownedHost && ownedHost != flutter && IsWindow(ownedHost)) DestroyWindow(ownedHost);
  }
}
