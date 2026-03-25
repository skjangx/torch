import SwiftUI

// MARK: - Main View

struct PaperLayoutView<Content: View, EmptyContent: View>: View {
    @Bindable private var controller: PaperLayoutController
    private let contentBuilder: (PaperTab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent

    init(
        controller: PaperLayoutController,
        @ViewBuilder content: @escaping (PaperTab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width
            let viewportHeight = geometry.size.height

            ZStack(alignment: .topLeading) {
                // Canvas: all panes laid out horizontally
                HStack(spacing: 0) {
                    ForEach(controller.panes) { pane in
                        let resolvedWidth = (pane.width <= 0 || pane.width == .infinity)
                            ? viewportWidth
                            : pane.width
                        PaperPaneContainerView(
                            pane: pane,
                            controller: controller,
                            contentBuilder: contentBuilder,
                            emptyPaneBuilder: emptyPaneBuilder
                        )
                        .frame(width: resolvedWidth, height: viewportHeight)
                    }
                }
                .offset(x: -controller.viewportOffset)
                .animation(
                    controller.configuration.appearance.enableAnimations
                        ? .easeInOut(duration: controller.configuration.appearance.animationDuration)
                        : nil,
                    value: controller.viewportOffset
                )

                // Resize handles between panes
                ForEach(0..<max(0, controller.panes.count - 1), id: \.self) { index in
                    PaperResizeHandle(
                        controller: controller,
                        leftPaneIndex: index
                    )
                    .position(
                        x: controller.paneXOffset(at: index + 1) - controller.viewportOffset,
                        y: viewportHeight / 2
                    )
                    .frame(height: viewportHeight)
                }
            }
            .clipped()
            .onAppear {
                controller.viewportWidth = viewportWidth
                controller.viewportHeight = viewportHeight
                resolveInitialPaneWidths()
            }
            .onChange(of: geometry.size) { _, newSize in
                let oldWidth = controller.viewportWidth
                controller.viewportWidth = newSize.width
                controller.viewportHeight = newSize.height

                // Scale pane widths proportionally when the viewport resizes.
                // This keeps panes from overflowing or underflowing the viewport
                // after a window resize.
                if oldWidth > 0 && !controller.panes.isEmpty {
                    let scale = newSize.width / oldWidth
                    for pane in controller.panes {
                        pane.width = max(
                            pane.width * scale,
                            controller.configuration.appearance.minimumPaneWidth
                        )
                    }
                    // Also scale viewport offset to keep the same relative scroll position
                    controller.viewportOffset *= scale
                }
            }
            // Trackpad gesture scrolling will be added in a follow-up.
            // Keyboard navigation (Cmd+Opt+Arrow) works for now.
        }
    }

    /// Resolve panes that used a placeholder width (e.g., fullscreen initial pane).
    private func resolveInitialPaneWidths() {
        for pane in controller.panes {
            if pane.width <= 0 || pane.width == .infinity {
                pane.width = controller.viewportWidth
            }
        }
    }
}

// MARK: - Convenience initializer (default empty view)

extension PaperLayoutView where EmptyContent == DefaultPaperEmptyPaneView {
    init(
        controller: PaperLayoutController,
        @ViewBuilder content: @escaping (PaperTab, PaneID) -> Content
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = { _ in DefaultPaperEmptyPaneView() }
    }
}

struct DefaultPaperEmptyPaneView: View {
    init() {}
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Open Tabs")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pane Container

private struct PaperPaneContainerView<Content: View, EmptyContent: View>: View {
    let pane: PaperPane
    let controller: PaperLayoutController
    let contentBuilder: (PaperTab, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent

    var body: some View {
        ZStack {
            if pane.tabs.isEmpty {
                emptyPaneBuilder(pane.id)
            } else if controller.configuration.contentViewLifecycle == .keepAllAlive {
                // Keep all tab views alive, show selected
                ForEach(pane.tabs, id: \.id) { tabItem in
                    let tab = PaperTab(from: tabItem)
                    let isSelected = tabItem.id == pane.selectedTabId
                    contentBuilder(tab, pane.id)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                }
            } else {
                // Only render selected tab
                if let selectedItem = pane.selectedTab {
                    let tab = PaperTab(from: selectedItem)
                    contentBuilder(tab, pane.id)
                }
            }
        }
        .overlay(alignment: .trailing) {
            // Thin separator line between panes (except last)
            if controller.panes.last?.id != pane.id && controller.panes.count > 1 {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1)
            }
        }
    }
}

// MARK: - Resize Handle

private struct PaperResizeHandle: View {
    let controller: PaperLayoutController
    let leftPaneIndex: Int

    @State private var isDragging = false
    @State private var dragStartWidths: (left: CGFloat, right: CGFloat) = (0, 0)

    private let handleWidth: CGFloat = 6

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: handleWidth)
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            let leftPane = controller.panes[leftPaneIndex]
                            let rightPane = controller.panes[leftPaneIndex + 1]
                            dragStartWidths = (leftPane.width, rightPane.width)
                        }

                        let delta = value.translation.width
                        let minWidth = controller.configuration.appearance.minimumPaneWidth

                        let newLeftWidth = max(minWidth, dragStartWidths.left + delta)
                        let newRightWidth = max(minWidth, dragStartWidths.right - delta)

                        // Only apply if both panes stay above minimum
                        if newLeftWidth >= minWidth && newRightWidth >= minWidth {
                            controller.panes[leftPaneIndex].width = newLeftWidth
                            controller.panes[leftPaneIndex + 1].width = newRightWidth
                        }

                        controller.notifyGeometryChange(isDragging: true)
                    }
                    .onEnded { _ in
                        isDragging = false
                        controller.notifyGeometryChange()
                    }
            )
    }
}

// MARK: - Cursor Extension

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
