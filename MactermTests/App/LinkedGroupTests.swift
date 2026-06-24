import Foundation
@testable import Macterm
import Testing

/// Integration coverage for linked tab groups, driven through `AppState` the
/// same way the UI drives them (link/unlink, close, cross-project).
@MainActor
struct LinkedGroupTests {
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        return AppState(workspaceStore: WorkspaceStore(fileURL: tmp))
    }

    @discardableResult
    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        let project = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(project)
        return project
    }

    // MARK: - Linking

    @Test
    func linkTab_forms_group_keeping_both_rows() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let ws = try #require(state.workspaces[project.id])
        let host = try #require(ws.activeTab)
        let hostPane = try #require(host.focusedPaneID)
        let member = ws.createTab(projectPath: "/tmp")

        state.linkTab(member.id, intoPane: hostPane, edge: .right)

        let groupID = try #require(host.linkedGroupID)
        let group = try #require(state.groups[groupID])
        #expect(member.linkedGroupID == groupID)
        #expect(group.hostTabID == host.id)
        #expect(group.memberOrder == [host.id, member.id])
        // Combined tree lives in the host; both sidebar rows survive.
        #expect(host.splitRoot.allPanes().count == 2)
        #expect(ws.tabs.count == 2)
        // A member renders the host's combined tree.
        #expect(state.renderedTab(for: member) === host)
        #expect(state.renderedTab(for: host) === host)
    }

    @Test
    func linkTab_tags_member_panes_with_origin() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let ws = try #require(state.workspaces[project.id])
        let host = try #require(ws.activeTab)
        let hostPane = try #require(host.focusedPaneID)
        let member = ws.createTab(projectPath: "/tmp")
        let memberPaneID = try #require(member.focusedPaneID)

        state.linkTab(member.id, intoPane: hostPane, edge: .bottom)

        let spliced = try #require(host.splitRoot.findPane(id: memberPaneID))
        #expect(spliced.originTabID == member.id)
    }

    @Test
    func linkTabs_multiselection_tiles_into_host() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let ws = try #require(state.workspaces[project.id])
        let t1 = try #require(ws.activeTab)
        let t2 = ws.createTab(projectPath: "/tmp")
        let t3 = ws.createTab(projectPath: "/tmp")

        state.linkTabs([t1.id, t2.id, t3.id])

        let groupID = try #require(t1.linkedGroupID)
        let group = try #require(state.groups[groupID])
        #expect(group.memberOrder == [t1.id, t2.id, t3.id])
        #expect(t1.splitRoot.allPanes().count == 3)
    }

    // MARK: - Unlinking

    @Test
    func unlinkTab_restores_member_and_dissolves_pair() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let ws = try #require(state.workspaces[project.id])
        let host = try #require(ws.activeTab)
        let hostPane = try #require(host.focusedPaneID)
        let member = ws.createTab(projectPath: "/tmp")
        state.linkTab(member.id, intoPane: hostPane, edge: .right)

        state.unlinkTab(member.id)

        #expect(member.linkedGroupID == nil)
        #expect(host.linkedGroupID == nil) // only the host remained → group dissolved
        #expect(state.groups.isEmpty)
        #expect(host.splitRoot.allPanes().count == 1)
        #expect(member.splitRoot.allPanes().count == 1)
        // Detached panes lose their origin tag.
        #expect(host.splitRoot.allPanes().allSatisfy { $0.originTabID == nil })
        #expect(member.splitRoot.allPanes().allSatisfy { $0.originTabID == nil })
    }

    @Test
    func closing_host_dissolves_group_and_keeps_members() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let ws = try #require(state.workspaces[project.id])
        let host = try #require(ws.activeTab)
        let hostPane = try #require(host.focusedPaneID)
        let member = ws.createTab(projectPath: "/tmp")
        state.linkTab(member.id, intoPane: hostPane, edge: .right)

        state.closeTab(host.id, projectID: project.id)

        #expect(state.groups.isEmpty)
        #expect(member.linkedGroupID == nil)
        #expect(ws.tabs.contains { $0.id == member.id })
        #expect(!ws.tabs.contains { $0.id == host.id })
        #expect(member.splitRoot.allPanes().count == 1)
    }

    // MARK: - Pane close reconciliation

    @Test
    func closing_members_last_pane_drops_it_from_group() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let ws = try #require(state.workspaces[project.id])
        let host = try #require(ws.activeTab)
        let hostPane = try #require(host.focusedPaneID)
        let member = ws.createTab(projectPath: "/tmp")
        let memberPaneID = try #require(member.focusedPaneID)
        state.linkTab(member.id, intoPane: hostPane, edge: .right)

        state.closePane(memberPaneID, projectID: project.id)

        #expect(!ws.tabs.contains { $0.id == member.id })
        #expect(host.linkedGroupID == nil) // host alone → group gone
        #expect(host.splitRoot.allPanes().count == 1)
    }

    // MARK: - Cross-project

    @Test
    func group_can_span_projects() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let host = try #require(state.workspaces[p1.id]?.activeTab)
        let hostPane = try #require(host.focusedPaneID)
        let member = try #require(state.workspaces[p2.id]?.activeTab)
        let memberPaneID = try #require(member.focusedPaneID)

        state.linkTab(member.id, intoPane: hostPane, edge: .bottom)

        #expect(host.splitRoot.allPanes().count == 2)
        // Selecting the member's project still renders the host's combined tree.
        #expect(state.renderedActiveTab(projectID: p2.id) === host)
        // The spliced pane keeps its own project identity.
        let spliced = try #require(host.splitRoot.findPane(id: memberPaneID))
        #expect(spliced.projectID == p2.id)
    }

    @Test
    func removing_a_project_detaches_cross_project_members() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let host = try #require(state.workspaces[p1.id]?.activeTab)
        let hostPane = try #require(host.focusedPaneID)
        let member = try #require(state.workspaces[p2.id]?.activeTab)
        state.linkTab(member.id, intoPane: hostPane, edge: .right)

        // Removing the host's project should detach the member back to p2.
        state.removeProject(p1.id)

        #expect(state.groups.isEmpty)
        #expect(member.linkedGroupID == nil)
        #expect(member.splitRoot.allPanes().count == 1)
        #expect(state.workspaces[p2.id]?.tabs.contains { $0.id == member.id } == true)
    }
}
