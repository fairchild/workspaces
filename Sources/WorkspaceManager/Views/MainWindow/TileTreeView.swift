import AppKit
import SwiftUI
import WorkspaceManagerCore

/// Renders a tab's `TileTreeState` recursively: every `.split` becomes a draggable two-pane divider,
/// every `.tile` resolves to its `HostTerminalSession` and renders the persistent terminal surface.
/// Surface persistence stays session-keyed (`HostTerminalSurfaceStore`) — the tree only arranges them,
/// so growing or rebalancing the layout never re-creates a live terminal.
struct TileTreeView: View {
    let tree: TileTreeState
    let resolveSession: (TileID) -> HostTerminalSession?
    let surfaceStore: HostTerminalSurfaceStore
    let onSetSplitRatio: (SplitID, CGFloat) -> Void
    var onCloseConfirmationRequired: ((UUID) -> Void)?
    var onTerminalProcessExit: ((UUID) -> Void)?
    var contextMenuProvider: ((HostTerminalSession) -> NSMenu?)?

    var body: some View {
        node(tree.root, enclosingAxis: nil)
    }

    // Recursion crosses an opaque-type boundary, so each node is type-erased. The tree is shallow
    // (one node per visible pane) and the leaves are heavyweight terminals, so the wrapper is free.
    private func node(
        _ node: TileTree,
        enclosingAxis: HostTerminalStateStore.SplitPaneLayout.Axis?
    ) -> AnyView {
        switch node {
        case .tile(let tileID):
            return AnyView(tile(tileID, minAxis: enclosingAxis))
        case .split(let id, let axis, let ratio, let first, let second):
            let paneAxis = axis.paneAxis
            return AnyView(
                HostTerminalTwoPaneSplitView(
                    axis: paneAxis,
                    fraction: CGFloat(ratio),
                    onFractionChanged: { onSetSplitRatio(id, $0) }
                ) {
                    self.node(first, enclosingAxis: paneAxis)
                } trailing: {
                    self.node(second, enclosingAxis: paneAxis)
                }
            )
        }
    }

    @ViewBuilder
    private func tile(
        _ tileID: TileID,
        minAxis: HostTerminalStateStore.SplitPaneLayout.Axis?
    ) -> some View {
        if let session = resolveSession(tileID) {
            HostTerminalPaneView(
                session: session,
                minAxis: minAxis,
                surfaceStore: surfaceStore,
                onCloseConfirmationRequired: onCloseConfirmationRequired,
                onTerminalProcessExit: onTerminalProcessExit,
                contextMenuProvider: contextMenuProvider
            )
            .id(session.id)
        } else {
            // A leaf with no session binding is a transient inconsistency; fill the slot rather than
            // collapse the geometry so neighboring panes keep their sizes until the next snapshot.
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// One terminal pane: the command-status sliver above its persistent terminal surface. `minAxis`
/// sets the pane's minimum along its enclosing split's axis so a divider can't crush it to nothing.
struct HostTerminalPaneView: View {
    @EnvironmentObject private var commandStatusRegistry: LastCommandStatusRegistry

    let session: HostTerminalSession
    let minAxis: HostTerminalStateStore.SplitPaneLayout.Axis?
    let surfaceStore: HostTerminalSurfaceStore
    var onCloseConfirmationRequired: ((UUID) -> Void)?
    var onTerminalProcessExit: ((UUID) -> Void)?
    var contextMenuProvider: ((HostTerminalSession) -> NSMenu?)?

    var body: some View {
        VStack(spacing: 0) {
            TerminalCommandStatusSliver(
                status: commandStatusRegistry.statusByTerminalSession[session.id]
            )

            PersistentHostTerminalContainerView(
                session: session,
                surfaceStore: surfaceStore,
                onProcessExit: {
                    onTerminalProcessExit?(session.id)
                },
                onCloseConfirmationRequired: {
                    onCloseConfirmationRequired?(session.id)
                },
                contextMenuProvider: {
                    contextMenuProvider?(session)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: minAxis == .leadingTrailing ? 240 : nil,
            minHeight: minAxis == .topBottom ? 160 : nil
        )
    }
}

extension SplitAxis {
    /// Bridges the Core arrangement axis to the view-layer geometry axis.
    var paneAxis: HostTerminalStateStore.SplitPaneLayout.Axis {
        switch self {
        case .leadingTrailing: return .leadingTrailing
        case .topBottom: return .topBottom
        }
    }
}

/// Content-agnostic split geometry: two child builders divided along `axis` with `first` taking
/// `fraction` of the length, and a draggable divider that reports new fractions. Knows nothing about
/// terminals — `TileTreeView` supplies the children and binds the drag to a specific `SplitID`.
struct HostTerminalTwoPaneSplitView<Leading: View, Trailing: View>: View {
    private static var dividerThickness: CGFloat { 10 }

    let axis: HostTerminalStateStore.SplitPaneLayout.Axis
    let fraction: CGFloat
    let onFractionChanged: ((CGFloat) -> Void)?
    let leading: Leading
    let trailing: Trailing

    @State private var dragStartFraction: CGFloat?

    init(
        axis: HostTerminalStateStore.SplitPaneLayout.Axis,
        fraction: CGFloat,
        onFractionChanged: ((CGFloat) -> Void)?,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.axis = axis
        self.fraction = fraction
        self.onFractionChanged = onFractionChanged
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GeometryReader { geometry in
            let totalLength = axis == .leadingTrailing ? geometry.size.width : geometry.size.height
            let availableLength = max(totalLength - Self.dividerThickness, 0)
            let actualFraction = constrainedFraction(
                HostTerminalStateStore.clampedSplitFraction(fraction),
                availableLength: availableLength
            )
            let leadingLength = availableLength * actualFraction

            if axis == .leadingTrailing {
                HStack(spacing: 0) {
                    leading
                        .frame(width: leadingLength)

                    divider(length: availableLength, currentFraction: actualFraction)

                    trailing
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    leading
                        .frame(height: leadingLength)

                    divider(length: availableLength, currentFraction: actualFraction)

                    trailing
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func divider(length: CGFloat, currentFraction: CGFloat) -> some View {
        let gesture = DragGesture(minimumDistance: 1)
            .onChanged { value in
                let baseline = dragStartFraction ?? currentFraction
                if dragStartFraction == nil {
                    dragStartFraction = baseline
                }

                let translation = axis == .leadingTrailing ? value.translation.width : value.translation.height
                let nextFraction = constrainedFraction(
                    baseline + (translation / max(length, 1)),
                    availableLength: length
                )
                onFractionChanged?(nextFraction)
            }
            .onEnded { _ in
                dragStartFraction = nil
            }

        if axis == .leadingTrailing {
            Color.clear
                .frame(width: Self.dividerThickness)
                .overlay(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                )
                .contentShape(Rectangle())
                .gesture(gesture)
        } else {
            Color.clear
                .frame(height: Self.dividerThickness)
                .overlay(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                )
                .contentShape(Rectangle())
                .gesture(gesture)
        }
    }

    private func constrainedFraction(_ proposed: CGFloat, availableLength: CGFloat) -> CGFloat {
        guard availableLength > 0 else {
            return HostTerminalStateStore.defaultSplitFraction
        }

        let minimumPaneLength: CGFloat = axis == .leadingTrailing ? 240 : 160
        let effectiveMinimumPaneLength = min(minimumPaneLength, availableLength / 2)
        let minimumFraction = effectiveMinimumPaneLength / availableLength
        let maximumFraction = 1 - minimumFraction
        let clampedFraction = HostTerminalStateStore.clampedSplitFraction(proposed)

        return min(max(clampedFraction, minimumFraction), maximumFraction)
    }
}
