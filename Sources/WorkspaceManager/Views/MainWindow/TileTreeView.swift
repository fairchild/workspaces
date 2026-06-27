import AppKit
import SwiftUI
import WorkspaceManagerCore

/// Renders a tab's `TileTreeState` recursively: every `.split` becomes a draggable two-pane divider,
/// every `.tile` resolves to its `HostTerminalSession` and renders the persistent terminal surface.
/// Surfaces are owned by the `TileID`-keyed `SurfaceStore` — the tree only arranges them, so growing
/// or rebalancing the layout never re-creates a live terminal.
struct TileTreeView: View {
    let tree: TileTreeState
    let resolveSession: (TileID) -> HostTerminalSession?
    let surfaceStore: SurfaceStore
    let onSetSplitRatio: (SplitID, CGFloat) -> Void
    var onCloseConfirmationRequired: ((UUID) -> Void)?
    var onTerminalProcessExit: ((UUID) -> Void)?
    var contextMenuProvider: ((HostTerminalSession) -> NSMenu?)?

    var body: some View {
        node(tree.root)
    }

    // Recursion crosses an opaque-type boundary, so each node is type-erased. The tree is shallow
    // (one node per visible pane) and the leaves are heavyweight terminals, so the wrapper is free.
    private func node(_ node: TileTree) -> AnyView {
        switch node {
        case .tile(let tileID):
            return AnyView(tile(tileID))
        case .split(let id, let axis, let ratio, let first, let second):
            let paneAxis = axis.paneAxis
            return AnyView(
                HostTerminalTwoPaneSplitView(
                    axis: paneAxis,
                    fraction: CGFloat(ratio),
                    onFractionChanged: { onSetSplitRatio(id, $0) }
                ) {
                    self.node(first)
                } trailing: {
                    self.node(second)
                }
            )
        }
    }

    @ViewBuilder
    private func tile(_ tileID: TileID) -> some View {
        if let session = resolveSession(tileID) {
            HostTerminalPaneView(
                tileID: tileID,
                session: session,
                surfaceStore: surfaceStore,
                onCloseConfirmationRequired: onCloseConfirmationRequired,
                onTerminalProcessExit: onTerminalProcessExit,
                contextMenuProvider: contextMenuProvider
            )
            .id(session.id)
        } else {
            // A leaf with no session binding is a transient inconsistency; fill the slot rather than
            // collapse the geometry so neighboring panes keep their sizes until the next snapshot. This
            // must stay transient — Phase 5's `SurfaceStore.sync` eviction should ensure an unbound tile
            // never survives a snapshot restore, so this placeholder is never persistently visible.
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// One terminal pane: the command-status sliver above its persistent terminal surface. The pane fills
/// whatever width/height its enclosing split allocates — it imposes no hard minimum, so deeply nested
/// splits stay bordered instead of overflowing into their neighbors. The split divider's
/// `constrainedFraction` is what keeps a pane from being crushed to nothing.
struct HostTerminalPaneView: View {
    @EnvironmentObject private var commandStatusRegistry: LastCommandStatusRegistry

    let tileID: TileID
    let session: HostTerminalSession
    let surfaceStore: SurfaceStore
    var onCloseConfirmationRequired: ((UUID) -> Void)?
    var onTerminalProcessExit: ((UUID) -> Void)?
    var contextMenuProvider: ((HostTerminalSession) -> NSMenu?)?

    var body: some View {
        VStack(spacing: 0) {
            TerminalCommandStatusSliver(
                status: commandStatusRegistry.statusByTerminalSession[session.id]
            )

            PersistentHostTerminalContainerView(
                tileID: tileID,
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
