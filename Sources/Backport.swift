import SwiftUI

// Centralized backports for newer SwiftUI APIs we want to use when available.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }

    @ViewBuilder
    func safeHelp(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            self.help(text)
        }
    }

    /// AppKit-backed tooltip that works when SwiftUI's .help() is blocked.
    /// Uses .overlay() to place NSView in front of gesture-handling parents.
    /// The NSView returns nil from hitTest so clicks/drags pass through to SwiftUI.
    func appKitTooltip(_ text: String?) -> some View {
        self.overlay(AppKitTooltipView(tooltip: text))
    }
}

/// NSViewRepresentable that creates a frontmost tooltip region.
/// Tooltip works via AppKit's internal tracking areas, independent of hit testing.
private struct AppKitTooltipView: NSViewRepresentable {
    let tooltip: String?

    func makeNSView(context: Context) -> TooltipNSView {
        let view = TooltipNSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: TooltipNSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

/// Custom NSView that shows tooltips but passes all events through.
private class TooltipNSView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Return nil so all mouse events pass through to SwiftUI beneath.
    /// Tooltip still works because AppKit uses internal tracking areas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Custom Styled Tooltip

/// Custom tooltip with configurable delay and styled appearance.
/// Shows a dark floating window with title and optional path.
extension View {
    /// Styled tooltip with 400ms delay, matching sidebar aesthetic.
    func styledTooltip(title: String, path: String? = nil, delay: TimeInterval = 0.4) -> some View {
        self.overlay(StyledTooltipView(title: title, path: path, delay: delay))
    }
}

/// NSViewRepresentable that tracks mouse and shows custom tooltip window.
private struct StyledTooltipView: NSViewRepresentable {
    let title: String
    let path: String?
    let delay: TimeInterval

    func makeNSView(context: Context) -> StyledTooltipTrackingView {
        let view = StyledTooltipTrackingView()
        view.title = title
        view.path = path
        view.delay = delay
        return view
    }

    func updateNSView(_ nsView: StyledTooltipTrackingView, context: Context) {
        nsView.title = title
        nsView.path = path
        nsView.delay = delay
    }
}

/// NSView that uses tracking area to detect hover and show custom tooltip.
private class StyledTooltipTrackingView: NSView {
    var title: String = ""
    var path: String?
    var delay: TimeInterval = 0.4

    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?
    private var isShowingTooltip = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil // Pass all events through
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.showTooltip()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hideTooltip()
    }

    private func showTooltip() {
        guard !isShowingTooltip, let window = self.window else { return }
        isShowingTooltip = true

        // Get position below the view
        let viewFrameInWindow = convert(bounds, to: nil)
        let viewFrameOnScreen = window.convertToScreen(viewFrameInWindow)

        TooltipWindowController.shared.show(
            title: title,
            path: path,
            below: viewFrameOnScreen,
            leftOffset: 10
        )
    }

    private func hideTooltip() {
        isShowingTooltip = false
        TooltipWindowController.shared.hide()
    }

    deinit {
        hoverTimer?.invalidate()
        if isShowingTooltip {
            TooltipWindowController.shared.hide()
        }
    }
}

/// Singleton controller for the custom tooltip window.
private class TooltipWindowController {
    static let shared = TooltipWindowController()

    private var tooltipWindow: NSWindow?
    private var hostingView: NSHostingView<TooltipContentView>?

    private init() {}

    func show(title: String, path: String?, below rect: NSRect, leftOffset: CGFloat) {
        hide() // Clean up any existing

        let content = TooltipContentView(title: title, path: path)
        let hosting = NSHostingView(rootView: content)
        hosting.frame.size = hosting.fittingSize

        let window = NSWindow(
            contentRect: NSRect(
                x: rect.minX + leftOffset,
                y: rect.minY - hosting.frame.height - 4,
                width: hosting.frame.width,
                height: hosting.frame.height
            ),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false // We draw our own shadow
        window.contentView = hosting
        window.ignoresMouseEvents = true
        window.orderFront(nil)

        tooltipWindow = window
        hostingView = hosting
    }

    func hide() {
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
        hostingView = nil
    }
}

/// SwiftUI view for tooltip content with styled appearance.
private struct TooltipContentView: View {
    let title: String
    let path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            if let path = path, !path.isEmpty {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Color(red: 0.165, green: 0.18, blue: 0.22)) // #2a2e38
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.5), radius: 9, x: 0, y: 6)
    }
}

extension Scene {
    var backport: Backport<Self> { Backport(content: self) }
}

/// Result type for backported onKeyPress handler
enum BackportKeyPressResult {
    case handled
    case ignored
}

extension Backport where Content: View {
    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        #if canImport(AppKit)
        if #available(macOS 15, *) {
            return content.pointerStyle(style?.official)
        } else {
            return content
        }
        #else
        return content
        #endif
    }

    /// Backported onKeyPress that works on macOS 14+ and is a no-op on macOS 13.
    func onKeyPress(_ key: KeyEquivalent, action: @escaping (EventModifiers) -> BackportKeyPressResult) -> some View {
        #if canImport(AppKit)
        if #available(macOS 14, *) {
            return content.onKeyPress(key, phases: [.down, .repeat], action: { keyPress in
                switch action(keyPress.modifiers) {
                case .handled: return .handled
                case .ignored: return .ignored
                }
            })
        } else {
            return content
        }
        #else
        return content
        #endif
    }
}

enum BackportPointerStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight

    #if canImport(AppKit)
    @available(macOS 15, *)
    var official: PointerStyle {
        switch self {
        case .default: return .default
        case .grabIdle: return .grabIdle
        case .grabActive: return .grabActive
        case .horizontalText: return .horizontalText
        case .verticalText: return .verticalText
        case .link: return .link
        case .resizeLeft: return .frameResize(position: .trailing, directions: [.inward])
        case .resizeRight: return .frameResize(position: .leading, directions: [.inward])
        case .resizeUp: return .frameResize(position: .bottom, directions: [.inward])
        case .resizeDown: return .frameResize(position: .top, directions: [.inward])
        case .resizeUpDown: return .frameResize(position: .top)
        case .resizeLeftRight: return .frameResize(position: .trailing)
        }
    }
    #endif
}
