import AppKit
import WorkspaceManagerCore

/// The seam between the generic tile-tree layout and the concrete content a tile renders.
///
/// A `Surface` is a renderable main-content unit of one kind (Terminal / Web), bound 1:1 to a
/// `TileID`. It vends an AppKit `NSView` (both current leaves are AppKit views wrapped in
/// `NSViewRepresentable`, so an `NSView` preserves the store-owned, reused-across-update persistence
/// the terminal and web paths already rely on). Kind-specific coupling — agent registry, OSC routing,
/// command status, local state for terminals — lives inside the conformer, never on this protocol;
/// that asymmetry (a `WebSurface` carries none of it) is what validates the abstraction.
@MainActor
protocol Surface: AnyObject {
    var kind: SurfaceKind { get }
    var tileID: TileID { get }

    /// The content view to mount for this tile. Store-owned and reused across render updates, so
    /// repeated calls return the same instance.
    func makeContentView() -> NSView

    /// Human-readable title for tab strips / window subtitles.
    var displayTitle: String { get }

    /// Make this surface's content the first responder.
    func focus()

    /// Relinquish first-responder if currently held.
    func resignFocus()

    /// USER intent to close (Cmd+W / close button). The terminal honors its close-confirmation /
    /// process-alive checks here; this is distinct from `tearDown`, which is unconditional eviction.
    func requestClose()

    /// STORE eviction: the surface is being removed from the tree. The terminal releases its
    /// libghostty surface; the web view releases per its deferred-release policy. Conflating this
    /// with `requestClose` would skip the terminal close confirmation or leak the surface.
    func tearDown()
}

/// The kind of content a `Surface` renders. `repoOverview` arrives with main-content unification.
enum SurfaceKind: Equatable, Sendable {
    case terminal
    case web
}
