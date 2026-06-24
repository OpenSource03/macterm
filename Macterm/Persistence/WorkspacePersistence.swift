import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "WorkspacePersistence")

// MARK: - File envelope

/// Current schema version. Bump when the snapshot types change shape.
/// Adding an optional field does NOT require a bump — Codable decodes
/// missing fields as nil / default. Removing or renaming fields does.
private let currentSchemaVersion = 4

/// Top-level on-disk representation. Wraps the workspace array so we can
/// evolve the file format (add fields, do migrations) without renaming the
/// file. Readers that encounter the old bare-array format still work.
struct WorkspacesFile: Codable {
    var version: Int
    var workspaces: [WorkspaceSnapshot]
    /// Linked tab groups. Optional so older files (and the bare-array fallback)
    /// decode as ungrouped. Groups live at file scope because their members can
    /// span projects/workspaces.
    var groups: [GroupSnapshot]?
}

/// A linked group's persisted shape. Membership of the combined tree is carried
/// by `Pane.originTabID` tags inside the host tab's snapshot, so this only needs
/// the host, member order, and accent.
struct GroupSnapshot: Codable {
    let id: UUID
    let hostTabID: UUID
    let memberOrder: [UUID]
    let colorIndex: Int
}

// MARK: - Snapshot types

struct WorkspaceSnapshot: Codable {
    let projectID: UUID
    let activeTabID: UUID?
    let tabs: [TabSnapshot]
}

struct TabSnapshot: Codable {
    let id: UUID
    let customTitle: String?
    let focusedPaneID: UUID?
    let splitRoot: SplitNodeSnapshot
}

indirect enum SplitNodeSnapshot: Codable {
    case pane(PaneSnapshot)
    case split(SplitBranchSnapshot)

    private enum CodingKeys: String, CodingKey { case type, pane, split }
    private enum NodeType: String, Codable { case pane, split }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(NodeType.self, forKey: .type) {
        case .pane: self = try .pane(c.decode(PaneSnapshot.self, forKey: .pane))
        case .split: self = try .split(c.decode(SplitBranchSnapshot.self, forKey: .split))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(p):
            try c.encode(NodeType.pane, forKey: .type)
            try c.encode(p, forKey: .pane)
        case let .split(b):
            try c.encode(NodeType.split, forKey: .type)
            try c.encode(b, forKey: .split)
        }
    }
}

struct PaneSnapshot: Codable {
    let id: UUID
    let projectPath: String
    /// Whether the pane was left in the "done / needs attention" state when the
    /// app last quit, so the green checkmark survives a restart until the user
    /// acknowledges it. Only `.done` is worth persisting: `.running` can't
    /// outlive the shell process, and `.idle` is the default. Optional so older
    /// snapshots (without the field) decode as nil / idle.
    var needsAttention: Bool?
    /// The pane's own project identity. Optional (older files predate it); when
    /// absent, restore falls back to the enclosing workspace's project. Lets a
    /// linked group's combined tree keep panes from several projects distinct.
    var projectID: UUID?
    /// The member tab this pane was contributed by inside a linked group's
    /// combined tree (`nil` for the host's own panes). Drives group restore.
    var originTabID: UUID?
    // No `title`: the tab name is derived live from the pane's foreground
    // process, so there's nothing per-pane to persist. (An older snapshot's
    // `title` key is harmlessly ignored on decode.)
}

struct SplitBranchSnapshot: Codable {
    let direction: SplitDirection
    let ratio: Double
    let first: SplitNodeSnapshot
    let second: SplitNodeSnapshot
}

// MARK: - Persistence

/// Result of loading the on-disk state: the per-project workspace snapshots plus
/// any linked tab groups (file-scoped, since groups can span projects).
struct LoadedWorkspaces {
    var workspaces: [WorkspaceSnapshot]
    var groups: [GroupSnapshot]
}

final class WorkspaceStore {
    private let fileURL: URL

    init(fileURL: URL = FileStorage.fileURL(filename: "workspaces_v3.json")) {
        self.fileURL = fileURL
    }

    func load() -> LoadedWorkspaces {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LoadedWorkspaces(workspaces: [], groups: [])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            // Try the envelope format first (version + workspaces + groups).
            if let file = try? decoder.decode(WorkspacesFile.self, from: data) {
                let migrated = migrate(file)
                return LoadedWorkspaces(workspaces: migrated.workspaces, groups: migrated.groups ?? [])
            }
            // Fallback: pre-envelope format where the file was a bare array
            // of WorkspaceSnapshot. Upgrade on next save.
            let bare = try clearPersistedAttention(in: decoder.decode([WorkspaceSnapshot].self, from: data))
            return LoadedWorkspaces(workspaces: bare, groups: [])
        } catch {
            logger.error("Failed to load workspaces: \(error)")
            return LoadedWorkspaces(workspaces: [], groups: [])
        }
    }

    func save(workspaces: [WorkspaceSnapshot], groups: [GroupSnapshot]) {
        do {
            let file = WorkspacesFile(version: currentSchemaVersion, workspaces: workspaces, groups: groups)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save workspaces: \(error)")
        }
    }

    /// Apply any needed in-memory migrations.
    private func migrate(_ file: WorkspacesFile) -> WorkspacesFile {
        if file.version < 4 {
            // v3 could persist spurious completion checkmarks for tabs that had
            // already been visually cleared. Drop the old attention bits once;
            // v4+ saves them only after the false-start and clear/save fixes.
            logger.info("Migrating workspaces v\(file.version, privacy: .public)→4: clearing persisted attention bits")
            return WorkspacesFile(version: 4, workspaces: clearPersistedAttention(in: file.workspaces), groups: file.groups)
        }
        return file
    }

    private func clearPersistedAttention(in snapshots: [WorkspaceSnapshot]) -> [WorkspaceSnapshot] {
        snapshots.map { ws in
            WorkspaceSnapshot(
                projectID: ws.projectID,
                activeTabID: ws.activeTabID,
                tabs: ws.tabs.map { tab in
                    TabSnapshot(
                        id: tab.id,
                        customTitle: tab.customTitle,
                        focusedPaneID: tab.focusedPaneID,
                        splitRoot: clearPersistedAttention(in: tab.splitRoot)
                    )
                }
            )
        }
    }

    private func clearPersistedAttention(in node: SplitNodeSnapshot) -> SplitNodeSnapshot {
        switch node {
        case var .pane(p):
            p.needsAttention = nil
            return .pane(p)
        case let .split(b):
            return .split(SplitBranchSnapshot(
                direction: b.direction,
                ratio: b.ratio,
                first: clearPersistedAttention(in: b.first),
                second: clearPersistedAttention(in: b.second)
            ))
        }
    }
}

// MARK: - Snapshot / Restore

@MainActor
enum WorkspaceSerializer {
    static func snapshot(
        _ workspaces: [UUID: Workspace],
        groups: [UUID: TabGroup] = [:]
    ) -> (workspaces: [WorkspaceSnapshot], groups: [GroupSnapshot]) {
        let workspaceSnaps = workspaces.values.map { ws in
            WorkspaceSnapshot(
                projectID: ws.projectID,
                activeTabID: ws.activeTabID,
                tabs: ws.tabs.map { tab in
                    TabSnapshot(
                        id: tab.id,
                        customTitle: tab.customTitle,
                        focusedPaneID: tab.focusedPaneID,
                        splitRoot: snapshotNode(tab.splitRoot)
                    )
                }
            )
        }
        let groupSnaps = groups.values.map { group in
            GroupSnapshot(
                id: group.id,
                hostTabID: group.hostTabID,
                memberOrder: group.memberOrder,
                colorIndex: group.colorIndex
            )
        }
        return (workspaceSnaps, groupSnaps)
    }

    static func restore(from snapshots: [WorkspaceSnapshot], validIDs: Set<UUID>) -> [Workspace] {
        snapshots.compactMap { snap in
            guard validIDs.contains(snap.projectID) else { return nil }
            let tabs = snap.tabs.map { t in
                let root = restoreNode(t.splitRoot, fallbackProjectID: snap.projectID)
                let focused = t.focusedPaneID.flatMap { root.findPane(id: $0)?.id } ?? root.allPanes().first?.id
                return TerminalTab(id: t.id, splitRoot: root, focusedPaneID: focused, customTitle: t.customTitle)
            }
            guard !tabs.isEmpty else { return nil }
            return Workspace(projectID: snap.projectID, tabs: tabs, activeTabID: snap.activeTabID)
        }
    }

    /// Rebuild linked groups from their snapshots, wiring each member's
    /// `linkedGroupID` and re-homing non-host members onto the host's combined
    /// tree (sharing the live panes via `originTabID` tags). Returns the groups
    /// and the next free accent index. Members or hosts that no longer resolve
    /// are dropped so a partial/corrupt file degrades to ungrouped tabs.
    static func restoreGroups(
        _ snapshots: [GroupSnapshot],
        into workspaces: [UUID: Workspace]
    ) -> (groups: [UUID: TabGroup], nextColorIndex: Int) {
        var tabByID: [UUID: TerminalTab] = [:]
        for ws in workspaces.values {
            for tab in ws.tabs {
                tabByID[tab.id] = tab
            }
        }

        var groups: [UUID: TabGroup] = [:]
        var maxColorIndex = -1
        for snap in snapshots {
            guard let host = tabByID[snap.hostTabID] else { continue }
            let group = TabGroup(id: snap.id, hostTabID: snap.hostTabID, colorIndex: snap.colorIndex)
            group.memberOrder = [snap.hostTabID]
            host.linkedGroupID = snap.id

            for memberID in snap.memberOrder where memberID != snap.hostTabID {
                guard let member = tabByID[memberID],
                      let subtree = host.splitRoot.topmostSubtree(ownedBy: memberID)
                else { continue }
                member.linkedGroupID = snap.id
                member.splitRoot = subtree
                member.focusedPaneID = subtree.allPanes().first?.id
                group.memberOrder.append(memberID)
            }

            if group.memberCount >= 2 {
                groups[snap.id] = group
                maxColorIndex = max(maxColorIndex, snap.colorIndex)
            } else {
                // Nothing valid to link to — leave the host as a normal tab.
                host.linkedGroupID = nil
                host.splitRoot.assignOriginTab(nil)
            }
        }
        return (groups, maxColorIndex + 1)
    }

    static func snapshotNode(_ node: SplitNode) -> SplitNodeSnapshot {
        switch node {
        case let .pane(p):
            // Prefer the shell's live cwd over the pane's original project
            // path so reopening the app lands each pane back in the directory
            // the user had navigated to. Falls back to projectPath when the
            // surface hasn't reported a pwd yet.
            let path = p.nsView?.currentPwd ?? p.projectPath
            let needsAttention = p.executionState == .done
            return .pane(PaneSnapshot(
                id: p.id,
                projectPath: path,
                needsAttention: needsAttention,
                projectID: p.projectID,
                originTabID: p.originTabID
            ))
        case let .split(b):
            return .split(SplitBranchSnapshot(
                direction: b.direction,
                ratio: Double(b.ratio),
                first: snapshotNode(b.first),
                second: snapshotNode(b.second)
            ))
        }
    }

    private static func restoreNode(_ snap: SplitNodeSnapshot, fallbackProjectID: UUID) -> SplitNode {
        switch snap {
        case let .pane(p):
            let pane = Pane(projectPath: p.projectPath, projectID: p.projectID ?? fallbackProjectID)
            if p.needsAttention == true {
                pane.restoreNeedsAttention()
            }
            pane.originTabID = p.originTabID
            return .pane(pane)
        case let .split(b):
            return .split(SplitBranch(
                direction: b.direction,
                ratio: CGFloat(b.ratio),
                first: restoreNode(b.first, fallbackProjectID: fallbackProjectID),
                second: restoreNode(b.second, fallbackProjectID: fallbackProjectID)
            ))
        }
    }
}
