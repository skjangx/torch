// CEF bridge: Alloy windowed mode.
// CEF creates a real NSView with native input, context menus, IME.

#include "cef_bridge.h"
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <signal.h>
#include <execinfo.h>
#include <unistd.h>

#ifdef CEF_BRIDGE_HAS_CEF

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/wrapper/cef_library_loader.h"

struct BridgeBrowser;

class BridgeClient : public CefClient,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefDisplayHandler,
                     public CefKeyboardHandler {
public:
    explicit BridgeClient(const cef_bridge_client_callbacks* cbs)
        : callbacks_(*cbs) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
        if (callbacks_.on_title_change) {
            std::string t = title.ToString();
            callbacks_.on_title_change(owner_, t.c_str(), callbacks_.user_data);
        }
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        if (frame->IsMain() && callbacks_.on_url_change) {
            std::string u = url.ToString();
            callbacks_.on_url_change(owner_, u.c_str(), callbacks_.user_data);
        }
    }

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading,
                              bool canGoBack, bool canGoForward) override {
        if (callbacks_.on_loading_state_change)
            callbacks_.on_loading_state_change(owner_, isLoading, canGoBack, canGoForward, callbacks_.user_data);
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       int popup_id, const CefString& target_url,
                       const CefString& target_frame_name,
                       WindowOpenDisposition, bool, const CefPopupFeatures&,
                       CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                       CefRefPtr<CefDictionaryValue>&, bool*) override {
        return true;
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        cef_browser_ = browser;
        fprintf(stderr, "[CEF] OnAfterCreated hwnd=%p\n", browser->GetHost()->GetWindowHandle());
        fflush(stderr);
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override { cef_browser_ = nullptr; }

    bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent& event,
                       CefEventHandle, bool* is_keyboard_shortcut) override {
        if (event.modifiers & EVENTFLAG_COMMAND_DOWN) *is_keyboard_shortcut = true;
        return false;
    }

    void SetOwner(cef_bridge_browser_t o) { owner_ = o; }
    CefRefPtr<CefBrowser> GetBrowser() { return cef_browser_; }

private:
    cef_bridge_client_callbacks callbacks_;
    cef_bridge_browser_t owner_ = nullptr;
    CefRefPtr<CefBrowser> cef_browser_;
    IMPLEMENT_REFCOUNTING(BridgeClient);
};

class BridgeApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> cmd) override {
        cmd->AppendSwitch("use-mock-keychain");
        cmd->AppendSwitch("single-process");
    }
private:
    IMPLEMENT_REFCOUNTING(BridgeApp);
};

struct BridgeBrowser { CefRefPtr<BridgeClient> client; };
static bool g_initialized = false;

static char* bridge_strdup(const char* s) {
    if (!s) return nullptr;
    size_t len = strlen(s) + 1;
    char* c = (char*)malloc(len);
    if (c) memcpy(c, s, len);
    return c;
}

int cef_bridge_initialize(const char* fp, const char* hp, const char* cr) {
    if (g_initialized) return CEF_BRIDGE_OK;
    if (!fp || !hp || !cr) return CEF_BRIDGE_ERR_INVALID;

    static CefScopedLibraryLoader ll;
    if (!ll.LoadInMain()) return CEF_BRIDGE_ERR_FAILED;

    CefMainArgs ma(0, nullptr);
    CefSettings s;
    s.no_sandbox = true;
    s.external_message_pump = true;
    s.multi_threaded_message_loop = false;
    s.persist_session_cookies = false;
    CefString(&s.framework_dir_path) = std::string(fp) + "/Chromium Embedded Framework.framework";
    CefString(&s.browser_subprocess_path) = hp;
    CefString(&s.cache_path) = cr;

    fprintf(stderr, "[CEF] Init...\n"); fflush(stderr);
    if (!CefInitialize(ma, s, new BridgeApp(), nullptr)) {
        fprintf(stderr, "[CEF] Init FAILED\n"); return CEF_BRIDGE_ERR_FAILED;
    }
    fprintf(stderr, "[CEF] Init OK\n"); fflush(stderr);
    g_initialized = true;
    return CEF_BRIDGE_OK;
}

void cef_bridge_do_message_loop_work(void) { if (g_initialized) CefDoMessageLoopWork(); }
void cef_bridge_shutdown(void) { if (g_initialized) { CefShutdown(); g_initialized = false; } }
bool cef_bridge_is_initialized(void) { return g_initialized; }

cef_bridge_browser_t cef_bridge_browser_create(
    const char* url, void* parent, int w, int h,
    const cef_bridge_client_callbacks* cbs
) {
    if (!g_initialized || !cbs || !parent) return nullptr;
    auto* bb = new BridgeBrowser();
    bb->client = new BridgeClient(cbs);
    bb->client->SetOwner(bb);

    CefWindowInfo wi;
    wi.parent_view = parent;
    wi.bounds = {0, 0, w, h};
    wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    CefBrowserSettings bs;

    std::string u = url ? url : "about:blank";
    fprintf(stderr, "[CEF] Create %dx%d url=%s\n", w, h, u.c_str()); fflush(stderr);

    bool ok = CefBrowserHost::CreateBrowser(wi, bb->client, u, bs, nullptr, nullptr);
    fprintf(stderr, "[CEF] Create=%d\n", ok); fflush(stderr);
    if (!ok) { delete bb; return nullptr; }
    return bb;
}

void cef_bridge_browser_destroy(cef_bridge_browser_t b) {
    if (!b) return;
    auto* bb = static_cast<BridgeBrowser*>(b);
    if (auto br = bb->client->GetBrowser()) {
        br->GetHost()->CloseBrowser(true);
        // Don't delete bb here. OnBeforeClose will clear the browser ref.
        // The BridgeBrowser leaks intentionally to avoid use-after-free
        // in single-process mode where CloseBrowser is synchronous.
    } else {
        delete bb;
    }
}

#define GB(b) if (!g_initialized||!b) return CEF_BRIDGE_ERR_NOT_INIT; \
    auto*bb_=static_cast<BridgeBrowser*>(b); auto b_=bb_->client->GetBrowser(); \
    if(!b_) return CEF_BRIDGE_ERR_FAILED;

int cef_bridge_browser_load_url(cef_bridge_browser_t b, const char* u) { GB(b); b_->GetMainFrame()->LoadURL(u); return 0; }
int cef_bridge_browser_go_back(cef_bridge_browser_t b) { GB(b); b_->GoBack(); return 0; }
int cef_bridge_browser_go_forward(cef_bridge_browser_t b) { GB(b); b_->GoForward(); return 0; }
int cef_bridge_browser_reload(cef_bridge_browser_t b) { GB(b); b_->Reload(); return 0; }
int cef_bridge_browser_stop(cef_bridge_browser_t b) { GB(b); b_->StopLoad(); return 0; }
int cef_bridge_browser_show_devtools(cef_bridge_browser_t b) {
    GB(b); CefWindowInfo wi; CefBrowserSettings bs;
    b_->GetHost()->ShowDevTools(wi,nullptr,bs,CefPoint()); return 0;
}
int cef_bridge_browser_close_devtools(cef_bridge_browser_t b) { GB(b); b_->GetHost()->CloseDevTools(); return 0; }

void cef_bridge_browser_set_hidden(cef_bridge_browser_t b, bool h) {
    if(!g_initialized||!b)return; auto*bb=static_cast<BridgeBrowser*>(b);
    if(auto br=bb->client->GetBrowser()) br->GetHost()->WasHidden(h);
}
void cef_bridge_browser_notify_resized(cef_bridge_browser_t b) {
    if(!g_initialized||!b)return; auto*bb=static_cast<BridgeBrowser*>(b);
    if(auto br=bb->client->GetBrowser()) br->GetHost()->WasResized();
}

void cef_bridge_free_string(char* s) { free(s); }
char* cef_bridge_get_version(void) { return bridge_strdup("alloy-146"); }

#else

static char* bridge_strdup(const char* s) {
    if (!s) return nullptr; size_t l=strlen(s)+1;
    char*c=(char*)malloc(l); if(c)memcpy(c,s,l); return c;
}
int cef_bridge_initialize(const char*a,const char*b,const char*c){return-1;}
void cef_bridge_do_message_loop_work(void){}
void cef_bridge_shutdown(void){}
bool cef_bridge_is_initialized(void){return false;}
cef_bridge_browser_t cef_bridge_browser_create(const char*u,void*p,int w,int h,const cef_bridge_client_callbacks*c){return nullptr;}
void cef_bridge_browser_destroy(cef_bridge_browser_t b){}
int cef_bridge_browser_load_url(cef_bridge_browser_t b,const char*u){return-1;}
int cef_bridge_browser_go_back(cef_bridge_browser_t b){return-1;}
int cef_bridge_browser_go_forward(cef_bridge_browser_t b){return-1;}
int cef_bridge_browser_reload(cef_bridge_browser_t b){return-1;}
int cef_bridge_browser_stop(cef_bridge_browser_t b){return-1;}
int cef_bridge_browser_show_devtools(cef_bridge_browser_t b){return-1;}
int cef_bridge_browser_close_devtools(cef_bridge_browser_t b){return-1;}
void cef_bridge_browser_set_hidden(cef_bridge_browser_t b,bool h){}
void cef_bridge_browser_notify_resized(cef_bridge_browser_t b){}
void cef_bridge_free_string(char*s){free(s);}
char* cef_bridge_get_version(void){return bridge_strdup("stub");}

#endif

static void crash_handler(int sig) {
    void*bt[30]; int n=backtrace(bt,30);
    backtrace_symbols_fd(bt,n,STDERR_FILENO);
    _exit(128+sig);
}
__attribute__((constructor)) static void install_crash_handlers(void) {
    signal(SIGSEGV,crash_handler); signal(SIGBUS,crash_handler); signal(SIGABRT,crash_handler);
}
