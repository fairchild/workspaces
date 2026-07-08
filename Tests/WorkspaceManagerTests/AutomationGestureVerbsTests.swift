import Foundation
import Testing

@testable import WorkspaceManagerCore

/// The gesture-verb layer is where the verbs-=-clicks rule lives. These tests pin the outcome
/// contract and the wrong-PTY guard at the layer boundary using fake gesture closures — no live app
/// — so the enforcement point has its own fast, deterministic coverage. The real-app behavior is
/// verified separately by the api-select smoke (JSONL milestones).
@Suite("AutomationGestureVerbs")
@MainActor
struct AutomationGestureVerbsTests {
    private func target(
        _ id: UUID, name: String = "ws", isArchived: Bool = false
    )
        -> AutomationGestureVerbs.WorkspaceTarget
    {
        AutomationGestureVerbs.WorkspaceTarget(workspaceID: id, name: name, isArchived: isArchived)
    }

    @Test("select resolves and drives the gesture, returning the completed effect")
    func selectCompleted() {
        let id = UUID()
        let surface = UUID()
        var performed: [UUID] = []
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { [id] in $0 == id ? self.target(id) : nil },
            performSelection: { t in
                performed.append(t.workspaceID)
                return AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: t.workspaceID,
                    attachedSurfaceID: surface,
                    attachedTerminal: true
                )
            }
        )

        let outcome = verbs.selectWorkspace(id)

        // The gesture ran exactly once, for the resolved workspace.
        #expect(performed == [id])
        guard case .completed(let effect) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(effect.selectedWorkspaceID == id)
        #expect(effect.attachedTerminal)
        #expect(effect.attachedSurfaceID == surface)
    }

    @Test("select of an unknown id is notFound and never drives the gesture")
    func selectNotFound() {
        var performCount = 0
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                performCount += 1
                return AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            }
        )

        let outcome = verbs.selectWorkspace(UUID())

        #expect(outcome == .notFound)
        // Fail closed: an unresolvable id never touches the selection gesture.
        #expect(performCount == 0)
    }

    @Test("selecting an archived workspace completes without a terminal attach")
    func selectArchivedCompletesWithoutTerminal() {
        let id = UUID()
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { [id] in $0 == id ? self.target(id, isArchived: true) : nil },
            performSelection: { _ in
                // The real archived path navigates to the repo overview: selection does not land on
                // the workspace and no terminal attaches.
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            }
        )

        guard case .completed(let effect) = verbs.selectWorkspace(id) else {
            Issue.record("expected .completed for an archived selection")
            return
        }
        #expect(!effect.attachedTerminal)
        #expect(effect.attachedSurfaceID == nil)
    }

    /// Wrong-PTY regression: selecting workspace A then writing input must land in A's PTY. At this
    /// layer that reduces to: each select drives the gesture for the *requested* workspace, and the
    /// effect reports that workspace's own attached surface — never a stale one cached from a prior
    /// select. The fake gesture models a tile tree by making the selected workspace's surface the
    /// active one; the active surface is where a following input goes.
    @Test("selecting workspace A then workspace B routes input to each workspace's own PTY")
    func selectingWorkspaceAThenInputLandsInASPTY() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let surfaceForWorkspace = [workspaceA: surfaceA, workspaceB: surfaceB]

        // The single mutable "active PTY" the next input would target.
        var activeSurface: UUID?

        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { id in
                surfaceForWorkspace[id] != nil ? self.target(id) : nil
            },
            performSelection: { t in
                // Driving the real selection gesture activates the workspace's own surface.
                let surface = surfaceForWorkspace[t.workspaceID]
                activeSurface = surface
                return AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: t.workspaceID,
                    attachedSurfaceID: surface,
                    attachedTerminal: surface != nil
                )
            }
        )

        // Select A: A's surface is now the active PTY, so input lands in A.
        guard case .completed(let effectA) = verbs.selectWorkspace(workspaceA) else {
            Issue.record("expected .completed selecting A")
            return
        }
        #expect(effectA.attachedSurfaceID == surfaceA)
        #expect(activeSurface == surfaceA)

        // Select B: the active PTY switches to B — no stale A surface left live to misroute input.
        guard case .completed(let effectB) = verbs.selectWorkspace(workspaceB) else {
            Issue.record("expected .completed selecting B")
            return
        }
        #expect(effectB.attachedSurfaceID == surfaceB)
        #expect(activeSurface == surfaceB)
        #expect(activeSurface != surfaceA)
    }
}
