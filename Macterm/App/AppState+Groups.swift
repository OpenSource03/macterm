import Foundation

// MARK: - Linked tab groups

/// Orchestration for *linked groups* — sets of tabs that share one combined
/// split layout (see `TabGroup`). The combined tree physically lives in the
/// group's host tab; other members contribute subtrees tagged via
/// `Pane.originTabID`. Membership is derived from those tags, so the whole
/// scheme survives a persistence round-trip without storing branch ids.
@MainActor
extension AppState {
    // MARK: Lookup / resolution

    /// Locate a tab by id across every workspace.
    func findTab(_ tabID: UUID) -> (workspace: Workspace, tab: TerminalTab)? {
        for ws in workspaces.values {
            if let tab = ws.tabs.first(where: { $0.id == tabID }) { return (ws, tab) }
        }
        return nil
    }

    /// Locate the tab whose split tree actually contains `paneID`. For a linked
    /// group that is always the host tab (which may be in another workspace).
    func findTabContainingPane(_ paneID: UUID) -> (workspace: Workspace, tab: TerminalTab)? {
        for ws in workspaces.values {
            if let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
                return (ws, tab)
            }
        }
        return nil
    }

    /// The tab whose tree should be rendered/mutated for `tab`: the group host
    /// when `tab` is a non-host member, otherwise `tab` itself.
    func renderedTab(for tab: TerminalTab) -> TerminalTab {
        guard let gid = tab.linkedGroupID,
              let group = groups[gid],
              group.hostTabID != tab.id,
              let host = findTab(group.hostTabID)?.tab
        else { return tab }
        return host
    }

    /// The host tab to render for a project's active tab.
    func renderedActiveTab(projectID: UUID) -> TerminalTab? {
        guard let active = workspaces[projectID]?.activeTab else { return nil }
        return renderedTab(for: active)
    }

    /// The group a tab belongs to, if any.
    func group(for tab: TerminalTab) -> TabGroup? {
        tab.linkedGroupID.flatMap { groups[$0] }
    }

    // MARK: Linking

    /// Splice `sourceTabID`'s layout into the combined tree at `targetPaneID`'s
    /// `edge`, creating or extending a linked group. Both tabs keep their
    /// sidebar rows; selecting either renders the combined view.
    func linkTab(_ sourceTabID: UUID, intoPane targetPaneID: UUID, edge: PaneDropEdge) {
        guard let (_, source) = findTab(sourceTabID),
              let (_, host) = findTabContainingPane(targetPaneID),
              source.id != host.id
        else { return }

        // A pane never belongs to two groups: if the source is itself linked,
        // detach it back to a standalone tab first so we move its real tree.
        if source.linkedGroupID != nil {
            unlinkTab(source.id)
        }
        // Re-resolve the host after the possible detach above.
        guard let (_, realHost) = findTabContainingPane(targetPaneID),
              realHost.id != source.id
        else { return }

        let group: TabGroup
        if let gid = realHost.linkedGroupID, let existing = groups[gid] {
            group = existing
        } else {
            let created = TabGroup(hostTabID: realHost.id, colorIndex: nextGroupColorIndex())
            groups[created.id] = created
            realHost.linkedGroupID = created.id
            // The host's existing panes are its own content (origin == nil).
            realHost.splitRoot.assignOriginTab(nil)
            group = created
        }

        let subtree = source.splitRoot
        subtree.assignOriginTab(source.id)
        let (newRoot, seamID) = realHost.splitRoot.splicing(
            subtree: subtree, atPaneID: targetPaneID, edge: edge
        )
        // Target pane vanished between hit-test and drop — abort without
        // half-forming a group.
        guard seamID != nil else {
            if group.memberCount <= 1 { dissolveGroup(group) }
            return
        }
        realHost.splitRoot = newRoot
        group.memberOrder.append(source.id)
        source.linkedGroupID = group.id
        realHost.focusPane(subtree.allPanes().first?.id ?? realHost.focusedPaneID ?? subtree.id)
        if Preferences.shared.autoTilingEnabled { realHost.splitRoot.rebalanced() }
        saveWorkspaces()
    }

    /// Link a multi-selection of tabs (e.g. from the sidebar context menu). The
    /// first tab becomes (or stays) the host; the rest tile in to its right.
    func linkTabs(_ tabIDs: [UUID]) {
        guard tabIDs.count >= 2, let first = findTab(tabIDs[0]) else { return }
        // If the chosen host is itself a dormant member, link onto its real host.
        var host = renderedTab(for: first.tab)
        for sourceID in tabIDs.dropFirst() where sourceID != host.id {
            guard let target = host.focusedPaneID ?? host.splitRoot.allPanes().first?.id else { continue }
            linkTab(sourceID, intoPane: target, edge: .right)
            host = renderedTab(for: host)
        }
    }

    // MARK: Unlinking

    /// Detach a tab from its group, restoring it to a standalone tab. Closing
    /// the host instead dissolves the whole group.
    func unlinkTab(_ tabID: UUID) {
        guard let (_, tab) = findTab(tabID),
              let group = group(for: tab)
        else { return }
        if tabID == group.hostTabID {
            dissolveGroup(group)
        } else {
            detachMember(tabID, from: group)
        }
        saveWorkspaces()
    }

    /// Pull `tabID`'s contributed subtree out of the host tree and hand it back
    /// to the member as its own standalone layout (live surfaces preserved).
    func detachMember(_ tabID: UUID, from group: TabGroup) {
        guard let host = findTab(group.hostTabID)?.tab,
              let (_, member) = findTab(tabID)
        else { return }

        if let subtree = host.splitRoot.topmostSubtree(ownedBy: tabID) {
            host.splitRoot = host.splitRoot.removingNode(id: subtree.id) ?? host.splitRoot
            subtree.assignOriginTab(nil)
            member.splitRoot = subtree
            member.focusedPaneID = subtree.allPanes().first?.id
            repairHostFocus(host)
            if Preferences.shared.autoTilingEnabled { host.splitRoot.rebalanced() }
        }
        member.linkedGroupID = nil
        group.memberOrder.removeAll { $0 == tabID }
        // Nothing left to share — turn the host back into a normal tab.
        if group.memberCount <= 1 { dissolveGroup(group) }
    }

    /// Break a group apart: every non-host member returns to its own standalone
    /// tab; the host becomes a normal tab holding whatever content remains.
    func dissolveGroup(_ group: TabGroup) {
        guard groups[group.id] != nil else { return }
        if let host = findTab(group.hostTabID)?.tab {
            // Detach in reverse link order so later (inner) splices unwind first.
            for memberID in group.memberOrder.reversed() where memberID != group.hostTabID {
                guard let (_, member) = findTab(memberID) else { continue }
                if let subtree = host.splitRoot.topmostSubtree(ownedBy: memberID) {
                    host.splitRoot = host.splitRoot.removingNode(id: subtree.id) ?? host.splitRoot
                    subtree.assignOriginTab(nil)
                    member.splitRoot = subtree
                    member.focusedPaneID = subtree.allPanes().first?.id
                }
                member.linkedGroupID = nil
            }
            host.splitRoot.assignOriginTab(nil)
            host.linkedGroupID = nil
            repairHostFocus(host)
            if Preferences.shared.autoTilingEnabled { host.splitRoot.rebalanced() }
        }
        groups[group.id] = nil
    }

    // MARK: Reconciliation after pane closes

    /// After a pane closed, drop any member that no longer contributes a pane
    /// and close its now-empty row. Collapses the group if only the host is left.
    func reconcileMembership(_ group: TabGroup) {
        guard let host = findTab(group.hostTabID)?.tab else {
            groups[group.id] = nil
            return
        }
        let liveOrigins = Set(host.splitRoot.allPanes().compactMap(\.originTabID))
        for memberID in group.memberOrder where memberID != group.hostTabID {
            guard !liveOrigins.contains(memberID) else { continue }
            if let (mws, member) = findTab(memberID) {
                member.linkedGroupID = nil
                mws.closeTab(memberID)
            }
            group.memberOrder.removeAll { $0 == memberID }
        }
        if group.memberCount <= 1 {
            host.linkedGroupID = nil
            host.splitRoot.assignOriginTab(nil)
            groups[group.id] = nil
        }
        saveWorkspaces()
    }

    /// The combined tree is down to a single pane: hand that pane to its owning
    /// tab as a standalone layout and close every other member's row.
    func collapseGroupToLastPane(_ group: TabGroup) {
        defer { saveWorkspaces() }
        guard let host = findTab(group.hostTabID)?.tab,
              let last = host.splitRoot.allPanes().first
        else {
            groups[group.id] = nil
            return
        }
        let ownerID = last.originTabID ?? host.id
        for memberID in group.memberOrder {
            guard let (mws, member) = findTab(memberID) else { continue }
            member.linkedGroupID = nil
            if memberID == ownerID {
                last.originTabID = nil
                member.splitRoot = .pane(last)
                member.focusedPaneID = last.id
            } else {
                // This member contributed nothing surviving; drop its row. Its
                // own panes were already destroyed as they closed.
                mws.closeTab(memberID)
            }
        }
        groups[group.id] = nil
    }

    /// Dissolve every group with a member in `projectID` so cross-project
    /// members survive the project's removal as standalone tabs.
    func dissolveGroupsTouching(projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        let localTabIDs = Set(ws.tabs.map(\.id))
        for group in groups.values where group.memberOrder.contains(where: localTabIDs.contains) {
            dissolveGroup(group)
        }
    }

    // MARK: Helpers

    /// Next stable accent index for a new group's sidebar coloring.
    func nextGroupColorIndex() -> Int {
        defer { groupColorCounter += 1 }
        return groupColorCounter
    }

    /// Re-home the host's focus/zoom if they pointed into a subtree that was
    /// just detached.
    private func repairHostFocus(_ host: TerminalTab) {
        if let focused = host.focusedPaneID, host.splitRoot.findPane(id: focused) == nil {
            host.focusedPaneID = host.nextFocusAfterClose()
        }
        if let zoomed = host.zoomedPaneID, host.splitRoot.findPane(id: zoomed) == nil {
            host.zoomedPaneID = nil
        }
    }
}
