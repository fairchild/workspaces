import AppKit
import SwiftUI
import WorkspaceManagerCore

struct HostTerminalSessionStack: View {
    @EnvironmentObject private var commandStatusRegistry: LastCommandStatusRegistry

    let sessions: [HostTerminalSession]
    let activeSessionID: UUID?
    let splitSession: HostTerminalSession?
    let splitLayout: HostTerminalStateStore.SplitPaneLayout?
    let splitFraction: CGFloat?
    let surfaceStore: HostTerminalSurfaceStore
    let tabTitleOverrides: [UUID: String]
    let onSplitFractionChanged: ((CGFloat) -> Void)?
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onCloseConfirmationRequired: ((UUID) -> Void)?
    var onTerminalProcessExit: ((UUID) -> Void)?
    var contextMenuProvider: ((HostTerminalSession) -> NSMenu?)?

    private var activeSession: HostTerminalSession? {
        guard let activeSessionID else { return sessions.last }
        return sessions.first(where: { $0.id == activeSessionID }) ?? sessions.last
    }

    private var resolvedSplitLayout: HostTerminalStateStore.SplitPaneLayout {
        splitLayout ?? .defaultTrailing
    }

    @ViewBuilder
    private func paneView(
        for session: HostTerminalSession,
        axis: HostTerminalStateStore.SplitPaneLayout.Axis
    ) -> some View {
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
            minWidth: axis == .leadingTrailing ? 240 : nil,
            minHeight: axis == .topBottom ? 160 : nil
        )
    }

    var body: some View {
        if let activeSession {
            VStack(spacing: 0) {
                if sessions.count > 1 {
                    TerminalTabStrip(
                        sessions: sessions,
                        activeSessionID: activeSession.id,
                        titleForSession: tabTitle(for:),
                        onSelectTab: onSelectTab,
                        onCloseTab: onCloseTab
                    )
                }

                if let splitSession {
                    HostTerminalTwoPaneSplitView(
                        axis: resolvedSplitLayout.axis,
                        fraction: splitFraction ?? HostTerminalStateStore.defaultSplitFraction,
                        onFractionChanged: onSplitFractionChanged
                    ) {
                        if resolvedSplitLayout.splitBeforePrimary {
                            paneView(for: splitSession, axis: resolvedSplitLayout.axis)
                        } else {
                            paneView(for: activeSession, axis: resolvedSplitLayout.axis)
                        }
                    } trailing: {
                        if resolvedSplitLayout.splitBeforePrimary {
                            paneView(for: activeSession, axis: resolvedSplitLayout.axis)
                        } else {
                            paneView(for: splitSession, axis: resolvedSplitLayout.axis)
                        }
                    }
                } else {
                    paneView(for: activeSession, axis: .leadingTrailing)
                }
            }
        }
    }

    private func tabTitle(for session: HostTerminalSession) -> String {
        tabTitleOverrides[session.id] ?? surfaceStore.displayTitle(for: session)
    }
}

private struct TerminalTabStrip: View {
    let sessions: [HostTerminalSession]
    let activeSessionID: UUID
    let titleForSession: (HostTerminalSession) -> String
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessions) { session in
                    tabButton(for: session)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tabButton(for session: HostTerminalSession) -> some View {
        let isActive = session.id == activeSessionID
        return HStack(spacing: 6) {
            Button {
                onSelectTab?(session.id)
            } label: {
                Text(titleForSession(session))
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(titleForSession(session))

            Button {
                onCloseTab?(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Close Tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color(nsColor: .selectedControlColor).opacity(0.26) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 1)
        }
    }
}

private struct HostTerminalTwoPaneSplitView<Leading: View, Trailing: View>: View {
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
