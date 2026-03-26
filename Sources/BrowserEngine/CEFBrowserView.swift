import AppKit
import Combine
import Bonsplit

/// Hosts a CEF browser in Alloy windowed mode.
/// CEF creates its own NSView as a child of this view.
/// Native input, context menus, IME, drag-and-drop all handled by CEF.
final class CEFBrowserView: NSView {

    private var browserHandle: cef_bridge_browser_t?
    private var callbacksStorage: cef_bridge_client_callbacks?
    private var cefChildView: NSView?
    private var destroyed = false

    private var pendingURL: String?
    private var browserCreationAttempted = false

    @Published private(set) var currentURL: String = ""
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { destroyBrowser() }

    // MARK: - Browser Lifecycle

    func createBrowser(initialURL: String) {
        guard CEFRuntime.shared.isInitialized else { return }
        guard browserHandle == nil, !browserCreationAttempted else { return }
        pendingURL = initialURL
        if bounds.width > 0, bounds.height > 0, window != nil {
            createBrowserNow()
        }
    }

    private func createBrowserNow() {
        guard pendingURL != nil, !browserCreationAttempted else { return }
        browserCreationAttempted = true
#if DEBUG
        dlog("cef.alloy.create bounds=\(bounds)")
#endif
        // Delay to let CEF finish internal init
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.createBrowserImmediate()
        }
    }

    private func createBrowserImmediate() {
        guard let url = pendingURL, !destroyed else { return }

        var callbacks = cef_bridge_client_callbacks()
        let ud = Unmanaged.passRetained(self).toOpaque()
        callbacks.user_data = ud

        callbacks.on_title_change = { _, title, ud in
            guard let ud, let title else { return }
            let s = String(cString: title)
            DispatchQueue.main.async {
                let v = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
                guard !v.destroyed else { return }
                v.currentTitle = s
            }
        }
        callbacks.on_url_change = { _, url, ud in
            guard let ud, let url else { return }
            let s = String(cString: url)
            DispatchQueue.main.async {
                let v = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
                guard !v.destroyed else { return }
                v.currentURL = s
            }
        }
        callbacks.on_loading_state_change = { _, loading, back, fwd, ud in
            guard let ud else { return }
            DispatchQueue.main.async {
                let v = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
                guard !v.destroyed else { return }
                v.isLoading = loading
                v.canGoBack = back
                v.canGoForward = fwd
            }
        }

        callbacksStorage = callbacks

        let parentPtr = Unmanaged.passUnretained(self).toOpaque()
        let w = Int32(bounds.width)
        let h = Int32(bounds.height)

        browserHandle = withUnsafePointer(to: &callbacksStorage!) { ptr in
            cef_bridge_browser_create(url, parentPtr, w, h, ptr)
        }

#if DEBUG
        dlog("cef.alloy.browser handle=\(browserHandle != nil ? "ok" : "NULL")")
#endif
        guard browserHandle != nil else { return }

        // Poll for CEF's child NSView
        pollForChild()
        pendingURL = nil
    }

    private var pollCount = 0

    private func pollForChild() {
        pollCount += 1
        if let child = subviews.first(where: { $0 !== cefChildView }) {
            child.frame = bounds
            child.autoresizingMask = [.width, .height]
            cefChildView = child
#if DEBUG
            dlog("cef.alloy.childFound polls=\(pollCount)")
#endif
            return
        }
        if pollCount < 100 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pollForChild()
            }
        }
    }

    func destroyBrowser() {
        guard !destroyed else { return }
        destroyed = true

        // Remove CEF's child view from hierarchy FIRST to prevent
        // AppKit from accessing it after CEF destroys it.
        for sub in subviews {
            sub.removeFromSuperview()
        }
        cefChildView = nil

        // Now destroy the CEF browser
        let handle = browserHandle
        browserHandle = nil

        // Release the retained self reference
        if let cbs = callbacksStorage, let ud = cbs.user_data {
            Unmanaged<CEFBrowserView>.fromOpaque(ud).release()
        }
        callbacksStorage = nil

        // Destroy CEF browser LAST, after all references are cleared
        if let h = handle {
            cef_bridge_browser_destroy(h)
        }
    }

    // MARK: - Navigation

    func loadURL(_ s: String) { if let h = browserHandle { cef_bridge_browser_load_url(h, s) } }
    func goBack() { if let h = browserHandle { cef_bridge_browser_go_back(h) } }
    func goForward() { if let h = browserHandle { cef_bridge_browser_go_forward(h) } }
    func reload() { if let h = browserHandle { cef_bridge_browser_reload(h) } }
    func stopLoading() { if let h = browserHandle { cef_bridge_browser_stop(h) } }
    func showDevTools() { if let h = browserHandle { cef_bridge_browser_show_devtools(h) } }
    func closeDevTools() { if let h = browserHandle { cef_bridge_browser_close_devtools(h) } }

    func notifyHidden(_ hidden: Bool) { if let h = browserHandle { cef_bridge_browser_set_hidden(h, hidden) } }
    func notifyResized() { if let h = browserHandle { cef_bridge_browser_notify_resized(h) } }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, bounds.width > 0, bounds.height > 0, pendingURL != nil {
            createBrowserNow()
        }
    }

    override func layout() {
        super.layout()
        if pendingURL != nil, !browserCreationAttempted,
           bounds.width > 0, bounds.height > 0, window != nil {
            createBrowserNow()
        }
        cefChildView?.frame = bounds
        notifyResized()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cefChildView?.frame = bounds
        notifyResized()
    }
}
