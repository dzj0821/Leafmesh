// Run only on the private desktop created by windows_native_focus_checks.py.
// Uses WebView2 composition, native mouse messages and keyboard messages, never
// SetCursorPos, SendInput, mouse_event, keybd_event or SwitchDesktop.
#include <windows.h>
#include <dcomp.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl.h>
#include <WebView2.h>
#include <chrono>
#include <functional>
#include <iostream>
#include <string>
#include "../windows/runner/focus_policy.h"
#include "../native/flutter_inappwebview_windows/windows/utils/composition_input_host.h"

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Callback;
bool legacy = false;
HWND flutter = nullptr;
LRESULT CALLBACK RootProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_ACTIVATE && flutter) {
    if (legacy) SetFocus(flutter);
    else FocusContentOnActivation(flutter, wp);
    return 0;
  }
  return DefWindowProc(hwnd, message, wp, lp);
}

void Check(bool condition, const char* description) {
  if (!condition) throw std::runtime_error(description);
}
void Pump(int millis) {
  const auto end = GetTickCount64()+millis;
  MSG msg;
  do {
    while (PeekMessage(&msg,nullptr,0,0,PM_REMOVE)) {TranslateMessage(&msg);DispatchMessage(&msg);}
    Sleep(1);
  } while (GetTickCount64()<end);
}
void Until(const std::function<bool()>& done) {
  const auto end=GetTickCount64()+30000;
  while (!done()) {Check(GetTickCount64()<end,"WebView2 callback timeout");Pump(5);}
}
std::wstring Js(ICoreWebView2* web, const wchar_t* script) {
  bool done=false;std::wstring result;
  HRESULT hr=web->ExecuteScript(script,Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
    [&](HRESULT status,LPCWSTR json)->HRESULT {if(SUCCEEDED(status)&&json)result=json;done=true;return S_OK;}).Get());
  Check(SUCCEEDED(hr),"ExecuteScript failed");Until([&]{return done;});return result;
}

int wmain(int argc,wchar_t** argv) {
  try {
    Check(argc>=2,"profile argument required");legacy=argc>2;
    wchar_t desktop[256]{};DWORD needed=0;
    GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,desktop,sizeof(desktop),&needed);
    Check(std::wstring(desktop).find(L"LeafmeshFocus_")==0,"Refusing to run on the user desktop");
    Check(SUCCEEDED(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED)),"COM init failed");
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSW cls{};cls.lpfnWndProc=RootProc;cls.hInstance=GetModuleHandle(nullptr);cls.lpszClassName=L"LeafmeshFocusRoot";
    RegisterClassW(&cls);
    HWND root=CreateWindowExW(0,cls.lpszClassName,L"isolated focus test",WS_OVERLAPPEDWINDOW|WS_VISIBLE,
      80,80,900,700,nullptr,nullptr,cls.hInstance,nullptr);
    flutter=CreateWindowExW(0,L"STATIC",L"",WS_CHILD|WS_VISIBLE,0,0,850,600,root,nullptr,cls.hInstance,nullptr);
    HWND host=CreateWindowExW(0,L"STATIC",L"",0,0,0,600,400,flutter,nullptr,cls.hInstance,nullptr);
    SetActiveWindow(root);SetFocus(flutter);
    bool environmentDone=false;HRESULT status=E_FAIL;
    ComPtr<ICoreWebView2Environment> environment;
    Check(SUCCEEDED(CreateCoreWebView2EnvironmentWithOptions(nullptr,argv[1],nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>([&](HRESULT hr,ICoreWebView2Environment* env)->HRESULT {
        status=hr;environment=env;environmentDone=true;return S_OK;}).Get())),"Environment start failed");
    Until([&]{return environmentDone;});Check(SUCCEEDED(status)&&environment,"Environment failed");
    std::cout<<"Environment ready on private desktop"<<std::endl;
    ComPtr<ICoreWebView2Environment3> env3;environment.As(&env3);
    ComPtr<ICoreWebView2CompositionController> composition;
    bool controllerDone=false;
    Check(SUCCEEDED(env3->CreateCoreWebView2CompositionController(host,
      Callback<ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>([&](HRESULT hr,ICoreWebView2CompositionController* c)->HRESULT {
        status=hr;composition=c;controllerDone=true;return S_OK;}).Get())),"Controller start failed");
    Until([&]{return controllerDone;});Check(SUCCEEDED(status)&&composition,"Controller failed");
    ComPtr<ICoreWebView2Controller> controller;composition.As(&controller);
    if(!legacy) Check(SUCCEEDED(flutter_inappwebview_plugin::attachCompositionInput(controller.Get(),flutter)),"Input reparent failed");
    ComPtr<ID3D11Device> d3d;
    Check(SUCCEEDED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&d3d,nullptr,nullptr)),"WARP device failed");
    ComPtr<IDXGIDevice> dxgi;d3d.As(&dxgi);
    ComPtr<IDCompositionDevice2> device;
    ComPtr<IDCompositionDevice> baseDevice;
    HRESULT compositionStatus=DCompositionCreateDevice2(dxgi.Get(),IID_PPV_ARGS(&baseDevice));
    std::cout<<"Composition status="<<std::hex<<compositionStatus<<std::dec<<std::endl;
    Check(SUCCEEDED(compositionStatus),"Composition device failed");
    Check(SUCCEEDED(baseDevice.As(&device)),"Composition device2 interface failed");
    ComPtr<IDCompositionVisual2> visual;Check(SUCCEEDED(device->CreateVisual(&visual)),"Visual failed");
    composition->put_RootVisualTarget(visual.Get());device->Commit();
    ComPtr<ICoreWebView2Controller3> controller3;controller.As(&controller3);
    if(controller3) {controller3->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS);controller3->put_RasterizationScale(1);}
    controller->put_Bounds(RECT{0,56,600,456});controller->put_IsVisible(TRUE);
    ComPtr<ICoreWebView2> web;controller->get_CoreWebView2(&web);
    bool loaded=false;EventRegistrationToken token{};
    web->add_NavigationCompleted(Callback<ICoreWebView2NavigationCompletedEventHandler>([&](ICoreWebView2*,ICoreWebView2NavigationCompletedEventArgs*)->HRESULT {
      loaded=true;return S_OK;}).Get(),&token);
    web->NavigateToString(L"<html><body style='margin:0'><textarea id='body' style='width:500px;height:300px'>fixture</textarea></body></html>");
    Until([&]{return loaded;});Pump(300);
    int checks=0;
    for(int round=0;round<4;round++) {
      SetActiveWindow(root);
      composition->SendMouseInput(COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE,COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE,0,POINT{100,40});
      composition->SendMouseInput(COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOWN,COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_LEFT_BUTTON,0,POINT{100,40});
      composition->SendMouseInput(COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_UP,COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE,0,POINT{100,40});
      Pump(250);
      HWND parent=nullptr;controller->get_ParentWindow(&parent);
      std::cout<<"Round "<<round<<" active="<<GetActiveWindow()<<" root="<<root<<" focus="<<GetFocus()
        <<" foreground="<<GetForegroundWindow()<<" parent="<<parent<<" domFocused="<<(Js(web.Get(),L"document.activeElement.id==='body' && document.hasFocus()") == L"true")<<std::endl;
      Check(GetActiveWindow()==root,"activation left the application root");
      Check(IsChild(flutter,GetFocus()),"browser keyboard focus left Flutter window tree");
      Check(Js(web.Get(),L"document.activeElement.id==='body' && document.hasFocus()") == L"true","editor DOM lost focus");
      const auto before=Js(web.Get(),L"document.querySelector('textarea').value.length");
      PostMessageW(GetFocus(),WM_CHAR,L'X',0);Pump(180);
      const auto after=Js(web.Get(),L"document.querySelector('textarea').value.length");
      Check(std::stoi(after)==std::stoi(before)+1,"native keyboard input did not reach editor");
      checks+=4;
      // Simulate a user choosing an outside Flutter text control, then go back.
      if(!legacy && !GetForegroundWindow()) {
        // A private, noninteractive desktop has no foreground window. The
        // production guard must refuse to reclaim global keyboard focus here.
        const HWND current=GetFocus();
        flutter_inappwebview_plugin::releaseCompositionInput(flutter,true);
        Check(GetFocus()==current,"background release reclaimed focus");checks++;
        SetFocus(flutter); // Explicit simulated selection of an outside control.
      } else if(legacy) SetFocus(flutter);
      else flutter_inappwebview_plugin::releaseCompositionInput(flutter,true);
      Pump(100);
      Check(GetFocus()==flutter,"outside control could not regain keyboard focus");checks++;
    }
    HWND other=CreateWindowExW(0,L"STATIC",L"other test app",WS_OVERLAPPEDWINDOW|WS_VISIBLE,40,40,300,200,nullptr,nullptr,cls.hInstance,nullptr);
    SetActiveWindow(other);SendMessage(root,WM_ACTIVATE,WA_INACTIVE,reinterpret_cast<LPARAM>(other));
    Check(GetActiveWindow()==other,"inactive main window reclaimed activation");checks++;
    flutter_inappwebview_plugin::closeCompositionInput(controller.Get(),host,flutter);
    Check(IsWindow(root)&&IsWindow(flutter)&&!IsWindow(host),"closing the editor destroyed the main view");checks++;
    DestroyWindow(other);DestroyWindow(root);flutter=nullptr;
    std::cout<<"PASS: "<<checks<<" real WebView2 activation, click, keyboard and close checks; no system input"<<std::endl;
    return 0;
  } catch(const std::exception& e) {std::cerr<<"FAIL: "<<e.what()<<std::endl;return 2;}
}
