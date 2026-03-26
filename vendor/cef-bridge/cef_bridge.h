// CEF bridge: Alloy windowed mode.
// CEF creates its own NSView as a child of parent_view.
// Native input handling, context menus, IME, drag-and-drop.
#ifndef CEF_BRIDGE_H
#define CEF_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>

#define CEF_BRIDGE_OK             0
#define CEF_BRIDGE_ERR_NOT_INIT  -1
#define CEF_BRIDGE_ERR_INVALID   -2
#define CEF_BRIDGE_ERR_FAILED    -3

typedef void* cef_bridge_browser_t;

// Callbacks
typedef void (*cef_bridge_title_callback)(cef_bridge_browser_t browser, const char* title, void* ud);
typedef void (*cef_bridge_url_callback)(cef_bridge_browser_t browser, const char* url, void* ud);
typedef void (*cef_bridge_loading_state_callback)(cef_bridge_browser_t browser, bool loading, bool back, bool fwd, void* ud);

typedef struct {
    cef_bridge_title_callback         on_title_change;
    cef_bridge_url_callback           on_url_change;
    cef_bridge_loading_state_callback on_loading_state_change;
    void*                             user_data;
} cef_bridge_client_callbacks;

// Lifecycle
int cef_bridge_initialize(const char* framework_path, const char* helper_path, const char* cache_root);
void cef_bridge_do_message_loop_work(void);
void cef_bridge_shutdown(void);
bool cef_bridge_is_initialized(void);

// Browser (Alloy windowed mode)
cef_bridge_browser_t cef_bridge_browser_create(
    const char* initial_url,
    void* parent_view,  // NSView*
    int width, int height,
    const cef_bridge_client_callbacks* callbacks
);
void cef_bridge_browser_destroy(cef_bridge_browser_t browser);

// Navigation
int cef_bridge_browser_load_url(cef_bridge_browser_t browser, const char* url);
int cef_bridge_browser_go_back(cef_bridge_browser_t browser);
int cef_bridge_browser_go_forward(cef_bridge_browser_t browser);
int cef_bridge_browser_reload(cef_bridge_browser_t browser);
int cef_bridge_browser_stop(cef_bridge_browser_t browser);

// DevTools
int cef_bridge_browser_show_devtools(cef_bridge_browser_t browser);
int cef_bridge_browser_close_devtools(cef_bridge_browser_t browser);

// Visibility
void cef_bridge_browser_set_hidden(cef_bridge_browser_t browser, bool hidden);
void cef_bridge_browser_notify_resized(cef_bridge_browser_t browser);

// Utility
void cef_bridge_free_string(char* str);
char* cef_bridge_get_version(void);

#ifdef __cplusplus
}
#endif
#endif
