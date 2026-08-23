//
//  SidebarPinController.swift
//  WorkspaceManager
//
//  Pin bookkeeping for the sidebar's Pinned section: which workspaces belong to it, in
//  what order, and the 0…n renumbering that keeps that order contiguous through every
//  pin, unpin, reorder, archive, and delete. Pure — the caller owns the save.
//

import Foundation
import WorkspaceManagerCore

struct SidebarPinController {
    /// The pinned workspaces in display order. `pinOrder` is read as a ranking rather than
    /// as an index, so a store carrying gaps or duplicates — an older build, a mutation that
    /// never reached disk — still yields one stable order instead of an arbitrary one.
    /// Archived rows are excluded here as well as at archive time: provider status sync can
    /// archive a workspace without passing through `unpin`.
    func pinnedWorkspaces(in workspaces: [Workspace]) -> [Workspace] {
        workspaces
            .filter { $0.isPinned && $0.status != .archived }
            .sorted(by: isOrderedBefore)
    }

    /// `pinOrder` of every workspace a mutation may touch, keyed by id, so a failed save
    /// restores exactly those values rather than rolling back the whole model context.
    func pinOrderSnapshot(of workspaces: [Workspace]) -> [UUID: Int?] {
        Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.pinOrder) })
    }

    func restore(_ snapshot: [UUID: Int?], in workspaces: [Workspace]) {
        for workspace in workspaces {
            if let order = snapshot[workspace.id] {
                workspace.pinOrder = order
            }
        }
    }

    /// Whether a workspace can enter the Pinned section. Archived work cannot: the section
    /// is a shortcut to live work, and archiving is what takes a workspace out of it.
    func isPinnable(_ workspace: Workspace) -> Bool {
        workspace.status != .archived
    }

    /// Appends to the end of the Pinned section. An already-pinned workspace keeps its place,
    /// and one that cannot be pinned stays out — the invariant holds here rather than at each
    /// affordance that offers the verb.
    @discardableResult
    func pin(_ workspace: Workspace, in workspaces: [Workspace]) -> [Workspace] {
        if !workspace.isPinned, isPinnable(workspace) {
            workspace.pinOrder = (workspaces.compactMap(\.pinOrder).max() ?? -1) + 1
        }
        return renumber(in: workspaces)
    }

    /// Drops a workspace out of the Pinned section and closes the gap it leaves. Also the
    /// archive and delete path: an archived or deleted row is no longer live work to return to.
    @discardableResult
    func unpin(_ workspace: Workspace, in workspaces: [Workspace]) -> [Workspace] {
        workspace.pinOrder = nil
        return renumber(in: workspaces)
    }

    /// Rewrites `pinOrder` to 0…n over the current pinned set. Every mutation ends here, so
    /// what reaches the store is contiguous and the display order is what was persisted.
    @discardableResult
    func renumber(in workspaces: [Workspace]) -> [Workspace] {
        numberInPlace(pinnedWorkspaces(in: workspaces))
    }

    /// Shifts a pinned workspace `offset` places within the Pinned section. A workspace the
    /// section does not hold, and a destination outside it, leave the store untouched — the
    /// affordance offers the verb and the invariant lives here.
    @discardableResult
    func move(_ workspace: Workspace, by offset: Int, in workspaces: [Workspace]) -> [Workspace] {
        var pinned = pinnedWorkspaces(in: workspaces)
        guard let index = pinned.firstIndex(where: { $0.id == workspace.id }) else { return pinned }

        let destination = index + offset
        guard pinned.indices.contains(destination) else { return pinned }

        pinned.insert(pinned.remove(at: index), at: destination)
        return numberInPlace(pinned)
    }

    /// Whether `move(_:by:in:)` would change anything — what disables Move Up on the first
    /// pinned row and Move Down on the last.
    func canMove(_ workspace: Workspace, by offset: Int, in workspaces: [Workspace]) -> Bool {
        let pinned = pinnedWorkspaces(in: workspaces)
        guard offset != 0, let index = pinned.firstIndex(where: { $0.id == workspace.id }) else {
            return false
        }
        return pinned.indices.contains(index + offset)
    }

    @discardableResult
    private func numberInPlace(_ pinned: [Workspace]) -> [Workspace] {
        for (index, workspace) in pinned.enumerated() where workspace.pinOrder != index {
            workspace.pinOrder = index
        }
        return pinned
    }

    private func isOrderedBefore(_ lhs: Workspace, _ rhs: Workspace) -> Bool {
        let lhsOrder = lhs.pinOrder ?? .max
        let rhsOrder = rhs.pinOrder ?? .max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }

        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}
