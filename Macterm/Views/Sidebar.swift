import SwiftUI

private enum SidebarItem: Hashable {
    case project(UUID)
    case tab(projectID: UUID, tabID: UUID)

    var tabID: UUID? {
        if case let .tab(_, tabID) = self { return tabID }
        return nil
    }
}

struct SidebarContent: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @AppStorage(Preferences.Keys.showNewProjectButton)
    private var showNewProjectButton = true
    @State
    private var expandedProjects: Set<UUID> = []
    @State
    private var selection: Set<SidebarItem> = []

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(projectStore.projects.enumerated()), id: \.element.id) { projectIndex, project in
                let ws = appState.workspaces[project.id]
                let tabs = ws?.tabs ?? []

                DisclosureGroup(isExpanded: Binding(
                    get: { expandedProjects.contains(project.id) },
                    set: { if $0 { expandedProjects.insert(project.id) } else { expandedProjects.remove(project.id) } }
                )) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                        SidebarTabRow(
                            tab: tab,
                            index: tabIndex + 1,
                            isActive: ws?.activeTabID == tab.id && appState.activeProjectID == project.id,
                            moveTargets: projectStore.projects.filter { $0.id != project.id },
                            group: appState.group(for: tab),
                            canLinkSelection: selectedTabIDs.count >= 2 && selectedTabIDs.contains(tab.id),
                            onClose: { appState.closeTab(tab.id, projectID: project.id) },
                            onRename: { newName in
                                tab.customTitle = newName.isEmpty ? nil : newName
                                appState.saveWorkspaces()
                            },
                            onMoveToProject: { destination in
                                appState.moveTab(tab.id, from: project.id, to: destination.id, destPath: destination.path)
                                expandedProjects.insert(destination.id)
                            },
                            onLinkSelection: {
                                appState.linkTabs(selectedTabIDs)
                            },
                            onUnlink: {
                                appState.unlinkTab(tab.id)
                            }
                        )
                        .tag(SidebarItem.tab(projectID: project.id, tabID: tab.id))
                        .onDrag {
                            appState.draggingTab = TabTransfer(projectID: project.id, tabID: tab.id)
                            return TabTransfer(projectID: project.id, tabID: tab.id).itemProvider()
                        }
                    }
                    .onMove { source, destination in
                        appState.workspaces[project.id]?.reorderTabs(fromOffsets: source, toOffset: destination)
                        appState.saveWorkspaces()
                    }
                } label: {
                    SidebarProjectRow(project: project, index: projectIndex + 1) {
                        appState.selectProject(project)
                        appState.createTab(projectID: project.id, projectPath: project.path)
                        expandedProjects.insert(project.id)
                    } onRename: {
                        projectStore.rename(id: project.id, to: $0)
                    } onUnload: {
                        appState.unloadProject(project.id)
                    } onRemove: {
                        expandedProjects.remove(project.id)
                        appState.removeProject(project.id)
                        projectStore.remove(id: project.id)
                    }
                    .tag(SidebarItem.project(project.id))
                }
            }
            .onMove { source, destination in
                projectStore.reorder(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // No background here: the window's NSWindow.backgroundColor (set by
        // WindowAppearance) provides the translucent fill uniformly. Adding
        // another tinted layer here would make the sidebar read darker than
        // the surrounding strip.
        .safeAreaInset(edge: .bottom) {
            if showNewProjectButton {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 0) {
                        Button {
                            openProject()
                        } label: {
                            Label("New Project", systemImage: "plus")
                                .font(.body)
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        // Only a single selection activates a project/tab; a multi-selection is
        // a transient gesture for the context menu (e.g. "Link in Split") and
        // leaves the active tab untouched.
        .onChange(of: selection) { _, items in
            guard items.count == 1, let item = items.first else { return }
            switch item {
            case let .project(projectID):
                guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
                appState.selectProject(project)
            case let .tab(projectID, tabID):
                if let project = projectStore.projects.first(where: { $0.id == projectID }) {
                    appState.selectProject(project)
                    appState.selectTab(tabID, projectID: projectID)
                }
            }
        }
        .onChange(of: appState.activeProjectID) { _, newID in
            if let newID { expandedProjects.insert(newID) }
            syncSelection()
        }
        .onChange(of: activeTabID) {
            syncSelection()
        }
        .onAppear {
            if let id = appState.activeProjectID { expandedProjects.insert(id) }
            syncSelection()
        }
    }

    private var activeTabID: UUID? {
        guard let pid = appState.activeProjectID else { return nil }
        return appState.workspaces[pid]?.activeTabID
    }

    /// Selected tab ids in sidebar (project, then tab) order — the order in
    /// which `linkTabs` should host/tile them.
    private var selectedTabIDs: [UUID] {
        let selected = Set(selection.compactMap(\.tabID))
        guard !selected.isEmpty else { return [] }
        var ordered: [UUID] = []
        for project in projectStore.projects {
            for tab in appState.workspaces[project.id]?.tabs ?? [] where selected.contains(tab.id) {
                ordered.append(tab.id)
            }
        }
        return ordered
    }

    private func syncSelection() {
        guard let pid = appState.activeProjectID,
              let ws = appState.workspaces[pid],
              let tabID = ws.activeTabID
        else {
            selection = appState.activeProjectID.map { [.project($0)] } ?? []
            return
        }
        let desired = SidebarItem.tab(projectID: pid, tabID: tabID)
        // Don't collapse a deliberate multi-selection just because the active
        // tab is already part of it.
        if !selection.contains(desired) { selection = [desired] }
    }

    private func openProject() {
        if let project = appState.openProject(store: projectStore) {
            expandedProjects.insert(project.id)
        }
    }
}

private struct SidebarProjectRow: View {
    let project: Project
    let index: Int
    let onNewTab: () -> Void
    let onRename: (String) -> Void
    let onUnload: () -> Void
    let onRemove: () -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.projectIconSymbol)
    private var projectIconSymbol = "folder"
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @FocusState
    private var focused: Bool

    @ViewBuilder
    private var titleContent: some View {
        if isRenaming {
            TextField("", text: $renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            Text(project.name)
                .lineLimit(1)
        }
    }

    var body: some View {
        Group {
            if projectIconSymbol == Preferences.noIcon {
                titleContent
                    .padding(.leading, 6)
            } else {
                Label {
                    titleContent
                } icon: {
                    SidebarRowIcon(symbol: projectIconSymbol, index: index)
                }
            }
        }
        .contextMenu {
            Button("New Tab", action: onNewTab)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }
            Divider()
            Button("Rename Project") { beginRename() }
            Divider()
            Button("Unload Project", action: onUnload)
                .disabled(!appState.isProjectLoaded(project.id))
            Button("Remove Project", role: .destructive, action: onRemove)
        }
        .task(id: appState.renamingProjectID) {
            if appState.renamingProjectID == project.id { beginRename() }
        }
    }

    private func beginRename() {
        appState.renamingProjectID = nil
        renameText = project.name
        isRenaming = true
    }

    private func commit() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { onRename(text) }
        isRenaming = false
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        isRenaming = false
        appState.restoreFocusToActivePane()
    }
}

private struct SidebarTabRow: View {
    let tab: TerminalTab
    let index: Int
    let isActive: Bool
    let moveTargets: [Project]
    let group: TabGroup?
    let canLinkSelection: Bool
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onMoveToProject: (Project) -> Void
    let onLinkSelection: () -> Void
    let onUnlink: () -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol = "terminal"
    @AppStorage(Preferences.Keys.showTabStatusIndicator)
    private var showTabStatusIndicator = false
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @State
    private var preEditCustomTitle: String?
    @FocusState
    private var focused: Bool

    /// The group's stable accent, used for the stripe and link badge.
    private var groupColor: Color? {
        group.map { MactermTheme.groupAccent($0.colorIndex) }
    }

    @ViewBuilder
    private var titleContent: some View {
        if isRenaming {
            TextField(tab.autoTitle, text: $renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            Text(tab.sidebarTitle)
                .lineLimit(1)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if tabIconSymbol == Preferences.noIcon {
                    Label {
                        titleContent
                    } icon: {
                        if showTabStatusIndicator {
                            TabStatusGlyph(state: displayState, symbol: tabIconSymbol, index: index)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                } else {
                    Label {
                        titleContent
                    } icon: {
                        if showTabStatusIndicator {
                            TabStatusGlyph(state: displayState, symbol: tabIconSymbol, index: index)
                        } else {
                            SidebarRowIcon(symbol: tabIconSymbol, index: index)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // A link badge in the group's accent marks tabs sharing a combined
            // split, mirroring the leading stripe.
            if let groupColor {
                Spacer(minLength: 0)
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(groupColor)
                    .help("Part of a linked split group")
            }
        }
        .overlay(alignment: .leading) {
            if let groupColor {
                Capsule()
                    .fill(groupColor)
                    .frame(width: 2.5)
                    .padding(.vertical, 2)
                    .offset(x: -8)
            }
        }
        .contextMenu {
            Button("Rename Tab") { beginRename() }
            if !moveTargets.isEmpty {
                Menu("Move to Project") {
                    ForEach(moveTargets) { project in
                        Button(project.name) { onMoveToProject(project) }
                    }
                }
            }
            if canLinkSelection {
                Divider()
                Button("Link in Split", systemImage: "rectangle.split.2x1", action: onLinkSelection)
            }
            if group != nil {
                if !canLinkSelection { Divider() }
                Button("Unlink from Group", systemImage: "link.badge.plus", action: onUnlink)
            }
            Divider()
            Button("Close Tab", action: onClose)
        }
        .onChange(of: appState.renamingTabID) { _, id in
            if id == tab.id { beginRename() }
        }
    }

    private func beginRename() {
        appState.renamingTabID = nil
        preEditCustomTitle = tab.customTitle
        renameText = tab.customTitle ?? ""
        isRenaming = true
    }

    private func commit() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        let newCustomTitle: String? = text.isEmpty ? nil : text
        if newCustomTitle != preEditCustomTitle {
            onRename(text)
        }
        isRenaming = false
        appState.restoreFocusToActivePane()
    }

    private var displayState: TerminalExecutionState {
        if tab.executionState == .running { return .running }
        // The tab the user is already looking at never needs an attention
        // indicator; a background tab's `done` checkmark is shown until it's
        // acknowledged. Visiting the tab clears all of its panes via the poll's
        // `acknowledgeFinishedCommandIfActive` (which acknowledges the whole
        // active tab, not just the focused pane, so the persisted state matches
        // what's displayed).
        return isActive ? .idle : tab.executionState
    }

    private func cancelRename() {
        isRenaming = false
        appState.restoreFocusToActivePane()
    }
}

/// The tab icon with a coexisting status indicator (the maintainer's
/// suggestion): the user's chosen icon stays put, and status is additive.
///
/// - `running`: a small spinner replaces the icon (temporary prominence,
///   Xcode-build-navigator style).
/// - `done` (needs attention): the icon with a small solid status dot in the
///   bottom-trailing corner — like the Messages/FaceTime "available" dot. A
///   dot reads as "done/positive" without competing with the icon's identity,
///   and it avoids the heavy, off-platform look of a checkmark glyph badge.
/// - `idle`: the icon as-is.
private struct TabStatusGlyph: View {
    let state: TerminalExecutionState
    let symbol: String
    let index: Int

    var body: some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
                .help("Running")
                .frame(width: 16, height: 16)
        case .done:
            SidebarRowIcon(symbol: symbol, index: index)
                .foregroundStyle(.secondary)
                .overlay(alignment: .bottomTrailing) {
                    // Opaque (not translucent) so it reads clearly over the
                    // icon and the sidebar background. Nested in a background
                    // ring so it stays legible over any icon color.
                    Circle()
                        .fill(.background)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                        )
                        .offset(x: 2.5, y: 2.5)
                }
                .help("Done")
        case .idle:
            SidebarRowIcon(symbol: symbol, index: index)
                .foregroundStyle(.secondary)
                .help("Idle")
        }
    }
}

private struct SidebarRowIcon: View {
    let symbol: String
    let index: Int

    var body: some View {
        if Preferences.numberIconChoices.contains(symbol) {
            NumberGlyph(index: index, variant: symbol)
        } else {
            Image(systemName: symbol)
        }
    }
}

private struct NumberGlyph: View {
    let index: Int
    let variant: String

    var body: some View {
        if variant == Preferences.numberIconPlain {
            Text("\(index)")
                .font(.body.monospacedDigit())
        } else if let suffix = shapeSuffix, (1 ... 50).contains(index) {
            // SF Symbols ships `1.<shape>` through `50.<shape>`; beyond that,
            // fall back to plain digits so we don't render a missing glyph.
            Image(systemName: "\(index).\(suffix)")
        } else {
            Text("\(index)")
                .font(.body.monospacedDigit())
        }
    }

    /// Maps the sentinel token (e.g. `number.circle.fill`) to the suffix used
    /// by the indexed SF Symbol (e.g. `circle.fill` in `1.circle.fill`).
    private var shapeSuffix: String? {
        switch variant {
        case Preferences.numberIconCircleFill: "circle.fill"
        case Preferences.numberIconCircle: "circle"
        case Preferences.numberIconSquareFill: "square.fill"
        case Preferences.numberIconSquare: "square"
        default: nil
        }
    }
}
