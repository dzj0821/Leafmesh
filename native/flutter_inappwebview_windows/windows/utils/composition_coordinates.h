// Leafmesh: map composition-host origins without guessing title-bar dimensions.
#pragma once
#include <windows.h>
#include <cmath>
#include <cstddef>

namespace flutter_inappwebview_plugin {
  inline RECT compositionViewBounds(double x, double y, size_t width,
      size_t height, double scale) {
    const LONG left=static_cast<LONG>(std::lround(x*scale));
    const LONG top=static_cast<LONG>(std::lround(y*scale));
    return RECT{left,top,left+static_cast<LONG>(width*scale),
      top+static_cast<LONG>(height*scale)};
  }
  inline bool positionCompositionHost(HWND flutterWindow, HWND host,
    double x, double y, double scale)
  {
    if (!flutterWindow || !host || !std::isfinite(x) || !std::isfinite(y) ||
      !std::isfinite(scale) || scale <= 0) return false;
    POINT origin{ static_cast<LONG>(std::lround(x * scale)),
      static_cast<LONG>(std::lround(y * scale)) };
    if (!ClientToScreen(flutterWindow, &origin)) return false;
    // Owned top-level hosts use screen coordinates; child hosts use their
    // parent's client coordinates. Do not change ownership to transfer focus.
    if (GetWindowLongPtr(host, GWL_STYLE) & WS_CHILD) {
      if (!ScreenToClient(GetParent(host), &origin)) return false;
    }
    return SetWindowPos(host, nullptr, origin.x, origin.y, 0, 0,
      SWP_NOZORDER | SWP_NOSIZE | SWP_NOACTIVATE) != FALSE;
  }
}
