//
//  SidebarChrome.swift
//  WorkspaceManager
//
//  The sidebar's styling vocabulary in one place: the sizes, indents, radii, tones, and
//  type styles its rows, badges, hover chips, and info card share. Every value mirrors what
//  the sidebar already renders, so a change here moves the whole surface at once.
//

import SwiftUI

/// Styling tokens for the sidebar tree and the surfaces that hang off it.
///
/// Radii vary by element as rendered today — rows 5, web rows 6, hover chips 7, the info
/// card 10 — and the near-duplicate secondary tones are likewise distinct. They sit side by
/// side here so that unifying them stays a deliberate choice rather than a drift.
enum SidebarChrome {
    /// Fixed sizes: the tree's columns, the controls that sit in them, and row insets.
    enum Metrics {
        /// Width reserved for a row's leading glyph, so labels line up down the tree.
        static let iconColumn: CGFloat = 18
        static let disclosureWidth: CGFloat = 12
        static let disclosureHeight: CGFloat = 14
        /// Side of the square hover chips — the repo "+" menu and the workspace pin star —
        /// and of the placeholders holding their space while a row is not hovered.
        static let hoverActionSide: CGFloat = 22
        /// Diameter of the session-activity dot.
        static let activityDot: CGFloat = 7
        /// Side of the square menu buttons that sit inline in a section header.
        static let headerActionSide: CGFloat = 18
        static let rowMinHeight: CGFloat = 34

        static let rowHorizontalPadding: CGFloat = 8
        /// Repo rows sit tighter than the leaf rows beneath them.
        static let repoRowVerticalPadding: CGFloat = 2
        static let rowVerticalPadding: CGFloat = 4

        /// Gap between a row's top-level parts: disclosure, label, hover action.
        static let rowSpacing: CGFloat = 10
        /// Gap between a row's glyph and its label.
        static let rowContentSpacing: CGFloat = 8

        static let cardWidth: CGFloat = 260
        static let cardPadding: CGFloat = 14
    }

    /// Leading insets that place a row in the tree.
    enum Indent {
        /// One level under a repo: nested workspaces and repo-scoped web sources.
        static let nestedRow: CGFloat = 18
        /// A workspace row's second line — status message or note — clearing the glyph column.
        static let rowSecondLine: CGFloat = 24
        /// Rows that head or trail a repo's children: the archived section, creation progress.
        static let repoSubheader: CGFloat = 28
        /// A web source under an expanded workspace, one level below `nestedRow`.
        static let workspaceChildRow: CGFloat = 42
    }

    enum Radius {
        static let row: CGFloat = 5
        static let webSourceRow: CGFloat = 6
        static let hoverAction: CGFloat = 7
        static let statusBadge: CGFloat = 3
        static let card: CGFloat = 10
    }

    /// Background tones. Semantic colors only, so the sidebar follows appearance and accent.
    enum Fill {
        static let rowSelection = Color.accentColor.opacity(0.1)
        static let hoverAction = Color.secondary.opacity(0.08)

        /// A collapsed repo's badge carries the subtree, so it reads a shade stronger.
        static let workspaceCountBadgeCollapsed = Color.secondary.opacity(0.1)
        static let workspaceCountBadgeExpanded = Color.secondary.opacity(0.06)
        static let paneCountBadgeActive = Color.secondary.opacity(0.16)
        static let paneCountBadgeIdle = Color.secondary.opacity(0.1)

        static let statusBadgeProvisioning = Color.blue.opacity(0.2)
        static let statusBadgeStopped = Color.orange.opacity(0.2)
        static let statusBadgeArchived = Color.secondary.opacity(0.2)

        /// Opaque backing for chrome layered over the list: the footer bar and the hover card.
        static let surface = Color(nsColor: .windowBackgroundColor)
    }

    /// Label and glyph tones that sit a step quieter than `.secondary` alone.
    enum Foreground {
        static let quietSecondary = Color.secondary.opacity(0.82)
        static let emphasizedSecondary = Color.secondary.opacity(0.95)
    }

    enum Stroke {
        static let hoverAction = Color.secondary.opacity(0.08)
        static let hoverActionWidth: CGFloat = 1
        static let card = Color(nsColor: .separatorColor).opacity(0.55)
        static let cardWidth: CGFloat = 0.5
    }

    enum TypeStyle {
        /// Row titles carry weight when the row is selected or its session is active.
        static func rowTitle(emphasized: Bool) -> Font {
            .callout.weight(emphasized ? .semibold : .regular)
        }

        /// A repo name heads a group, so it stays bold whatever the row's state — selection
        /// reads from the row fill and session activity from the dot.
        static let repoTitle = Font.callout.weight(.semibold)

        /// Monospaced digits keep a count capsule from twitching as its number changes.
        static let countBadge = Font.caption2.weight(.medium).monospacedDigit()
        static let hoverActionGlyph = Font.system(size: 11, weight: .semibold)
        /// Glyphs of the menus that sit inline in a section header.
        static let headerActionGlyph = Font.caption.weight(.semibold)
    }

    /// The identity glyph that heads a repo row: a small rounded square carrying the repo's
    /// initial over a hue derived from its name, so a repo wears the same color everywhere it
    /// appears and from one launch to the next.
    enum RepoGlyph {
        static let side: CGFloat = 16
        static let radius: CGFloat = 4
        static let monogramFont = Font.system(size: 10, weight: .semibold, design: .rounded)
        static let monogramColor = Color.white
        /// Hue is the only thing that varies: holding saturation and brightness fixed gives
        /// every repo's color the same weight. These two are set a step below full — dark
        /// enough that white holds up over the yellow-green band, bright enough to carry
        /// against a dark sidebar.
        static let saturation: Double = 0.52
        static let brightness: Double = 0.66
        /// A name with no character to abbreviate gets a neutral glyph rather than a hue that
        /// would read as an identity it doesn't carry.
        static let placeholderMonogram = "?"
        static let placeholderFill = Color.secondary

        /// Hue in `[0, 1)` for a repo name, from FNV-1a over its NFC-normalized UTF-8.
        ///
        /// Deliberately not `Hasher`: that one is seeded per process, so the sidebar would
        /// repaint every repo on relaunch. This hash is fixed for all time. Canonical
        /// normalization first, so spellings Swift already treats as the same string
        /// ("é" vs "e" + combining accent) wear the same color.
        static func hue(for name: String) -> Double {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in name.precomposedStringWithCanonicalMapping.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return Double(hash % 3600) / 3600
        }

        /// The single character the glyph shows: the name's first non-blank one, uppercased.
        static func monogram(for name: String) -> String {
            guard let first = name.first(where: { !$0.isWhitespace }) else {
                return placeholderMonogram
            }
            return String(first.uppercased().prefix(1))
        }

        static func fill(for name: String) -> Color {
            guard name.contains(where: { !$0.isWhitespace }) else { return placeholderFill }
            return Color(hue: hue(for: name), saturation: saturation, brightness: brightness)
        }
    }
}
