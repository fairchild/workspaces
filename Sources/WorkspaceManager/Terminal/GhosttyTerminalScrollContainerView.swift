//
//  GhosttyTerminalScrollContainerView.swift
//  WorkspaceManager
//

import AppKit

/// Wraps the raw Ghostty surface in an AppKit scroll view so embedded terminals
/// expose native scrollbar position without replacing Ghostty's scrollback model.
@MainActor
final class GhosttyTerminalScrollContainerView: NSView {
    let surfaceView: GhosttySurfaceView

    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    private var scrollbarState: GhosttyScrollbarState?

    init(surfaceView: GhosttySurfaceView) {
        self.surfaceView = surfaceView

        super.init(frame: .zero)

        configureScrollView()
        surfaceView.onScrollbarStateChange = { [weak self] state in
            self?.applyScrollbarState(state)
        }

        if let state = surfaceView.latestScrollbarState {
            scrollbarState = state
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(surfaceView)
        return true
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        documentView.frame.size.width = scrollView.contentSize.width
        surfaceView.frame.size = scrollView.contentSize
        synchronizeScrollViewPosition()
        synchronizeSurfacePosition()
    }

    func updateContextMenuProvider(_ provider: (() -> NSMenu?)?) {
        surfaceView.contextMenuProvider = provider
    }

    // MARK: - Setup

    private func configureScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false

        documentView.frame = bounds
        documentView.addSubview(surfaceView)
        scrollView.documentView = documentView
        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.synchronizeSurfacePosition()
                }
            })

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isLiveScrolling = true
                }
            })

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isLiveScrolling = false
                }
            })

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.sendDraggedScrollbarPosition()
                }
            })
    }

    // MARK: - Synchronization

    private func applyScrollbarState(_ state: GhosttyScrollbarState) {
        guard scrollbarState != state else { return }
        scrollbarState = state
        synchronizeScrollViewPosition()
        scrollView.flashScrollers()
    }

    private func synchronizeScrollViewPosition() {
        let contentHeight = scrollView.contentSize.height
        documentView.frame.size.height = GhosttyScrollPositionMapper.documentHeight(
            contentHeight: contentHeight,
            state: scrollbarState
        )

        if !isLiveScrolling, let state = scrollbarState {
            let offsetY = GhosttyScrollPositionMapper.contentOffsetY(
                contentHeight: contentHeight,
                state: state
            )
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
            lastSentRow = Int(min(state.offset, state.maxOffset))
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
        synchronizeSurfacePosition()
    }

    private func synchronizeSurfacePosition() {
        surfaceView.frame.origin = scrollView.contentView.documentVisibleRect.origin
    }

    private func sendDraggedScrollbarPosition() {
        let contentHeight = scrollView.contentSize.height
        let documentHeight = documentView.frame.height
        guard
            let row = GhosttyScrollPositionMapper.row(
                visibleRect: scrollView.contentView.documentVisibleRect,
                documentHeight: documentHeight,
                contentHeight: contentHeight,
                state: scrollbarState
            ),
            row != lastSentRow
        else {
            return
        }

        lastSentRow = row
        surfaceView.scrollToRow(row)
    }
}
