// Minimal Chromium browser demo.
// Loads the cmux_chromium_bridge dylib and embeds Chromium's NSView.

import AppKit

// Bridge function types
typealias CreateBrowserFn = @convention(c) (UnsafePointer<CChar>?, Int32, Int32) -> UnsafeMutableRawPointer?
typealias GetNSViewFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
typealias NavigateFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
typealias VoidFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

class BrowserWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var browserHandle: UnsafeMutableRawPointer?
    var navigate: NavigateFn?
    var goBack: VoidFn?
    var goForward: VoidFn?
    var reload: VoidFn?

    init(bridge: UnsafeMutableRawPointer) {
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "cmux Chromium Demo"
        window.contentView?.wantsLayer = true

        super.init()
        window.delegate = self

        // Load functions
        guard let createBrowser = dlsym(bridge, "cmux_chromium_create_browser"),
              let getNSView = dlsym(bridge, "cmux_chromium_get_nsview") else {
            print("Failed to load bridge functions")
            return
        }

        self.navigate = unsafeBitCast(dlsym(bridge, "cmux_chromium_navigate"), to: NavigateFn.self)
        self.goBack = unsafeBitCast(dlsym(bridge, "cmux_chromium_go_back"), to: VoidFn.self)
        self.goForward = unsafeBitCast(dlsym(bridge, "cmux_chromium_go_forward"), to: VoidFn.self)
        self.reload = unsafeBitCast(dlsym(bridge, "cmux_chromium_reload"), to: VoidFn.self)

        let create = unsafeBitCast(createBrowser, to: CreateBrowserFn.self)
        let getView = unsafeBitCast(getNSView, to: GetNSViewFn.self)

        // Create browser
        let url = "https://example.com"
        browserHandle = url.withCString { create($0, 1200, 800) }

        guard let handle = browserHandle,
              let viewPtr = getView(handle) else {
            print("Failed to create browser")
            return
        }

        // Get the NSView and embed it
        let webView = Unmanaged<NSView>.fromOpaque(viewPtr).takeUnretainedValue()
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)

        print("Browser created, NSView embedded")
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

// App delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var browserWindow: BrowserWindow?
    var bridge: UnsafeMutableRawPointer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bridge dylib
        let dylibPath = ProcessInfo.processInfo.environment["CHROMIUM_BRIDGE_PATH"]
            ?? "\(NSHomeDirectory())/chromium/src/out/Release/libcmux_chromium_bridge.dylib"

        print("Loading bridge: \(dylibPath)")
        bridge = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL)
        guard let bridge else {
            print("dlopen failed: \(String(cString: dlerror()))")
            return
        }
        print("Bridge loaded")

        browserWindow = BrowserWindow(bridge: bridge)
        browserWindow?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
