// Real Win32 coordinate checks using hidden windows; no focus or input APIs.
#include <windows.h>
#include <cmath>
#include <iostream>
#include "../native/flutter_inappwebview_windows/windows/utils/composition_coordinates.h"

int main() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  int checks = 0;
  for (POINT screen : {POINT{100, 70}, POINT{-900, 150}, POINT{120, -450}}) {
    HWND root = CreateWindowExW(0, L"STATIC", L"geometry-test-hidden", WS_OVERLAPPEDWINDOW,
      screen.x, screen.y, 900, 700, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
    HWND flutter = CreateWindowExW(0, L"STATIC", L"", WS_CHILD,
      7, 11, 800, 600, root, nullptr, GetModuleHandle(nullptr), nullptr);
    for (DWORD style : {DWORD{0}, DWORD{WS_CHILD}}) {
      HWND host = CreateWindowExW(0, L"STATIC", L"", style,
        0, 0, 500, 400, flutter, nullptr, GetModuleHandle(nullptr), nullptr);
      for (double scale : {1.0, 1.25, 1.5, 2.0}) {
        for (POINT offset : {POINT{0, 56}, POINT{250, 100}, POINT{24, 96}}) {
          if (!flutter_inappwebview_plugin::positionCompositionHost(flutter, host,
              offset.x, offset.y, scale)) return 1;
          POINT expected{LONG(std::lround(offset.x*scale)), LONG(std::lround(offset.y*scale))};
          ClientToScreen(flutter, &expected);
          RECT actual{};
          GetWindowRect(host, &actual);
          if (actual.left != expected.x || actual.top != expected.y) {
            std::cerr << "coordinate mismatch: " << actual.left << "," << actual.top
              << " expected " << expected.x << "," << expected.y << std::endl;
            return 2;
          }
          if (IsWindowVisible(root) || IsWindowVisible(host)) return 3;
          // A controller parented directly to Flutter uses an inset Bounds
          // origin, while composition input remains local to the WebView.
          const auto bounds=flutter_inappwebview_plugin::compositionViewBounds(
            offset.x,offset.y,500,400,scale);
          POINT inputOrigin{bounds.left,bounds.top};
          ClientToScreen(flutter,&inputOrigin);
          if(inputOrigin.x!=expected.x||inputOrigin.y!=expected.y||
              bounds.right-bounds.left!=LONG(500*scale)||
              bounds.bottom-bounds.top!=LONG(400*scale)) return 4;
          checks++;
        }
      }
      DestroyWindow(host);
    }
    DestroyWindow(flutter);
    DestroyWindow(root);
  }
  std::cout << "PASS: " << checks << " native coordinate cases; no visible windows or mouse input" << std::endl;
}
