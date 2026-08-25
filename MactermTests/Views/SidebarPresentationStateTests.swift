import Foundation
@testable import Macterm
import Testing

@MainActor
struct SidebarPresentationStateTests {
    @Test
    func completing_rename_returns_one_shared_draft_and_clears_it() {
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft", originalCustomTitle: "old")
        state.renameText = "final"

        let result = state.completeRename(.tab(tabID))
        #expect(result?.text == "final")
        #expect(result?.originalCustomTitle == "old")
        #expect(state.renameTarget == nil)
    }

    @Test
    func unrelated_row_cannot_consume_the_shared_rename_draft() {
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft")

        #expect(state.completeRename(.project(UUID())) == nil)
        #expect(state.isRenaming(.tab(tabID)))
        #expect(state.renameText == "draft")
    }

    @Test
    func ordinary_overlay_dismissal_discards_the_rename_draft() {
        let state = SidebarPresentationState()
        state.beginRename(.tab(UUID()), text: "draft")

        state.discardRename()

        #expect(state.renameTarget == nil)
        #expect(state.renameText.isEmpty)
    }

    @Test
    func selection_and_expansion_live_on_the_shared_state() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabID = UUID()

        state.expandedProjects.insert(projectID)
        state.selection = [.tab(projectID: projectID, tabID: tabID)]
        state.scrollPosition = .tab(projectID: projectID, tabID: tabID)

        #expect(state.expandedProjects == [projectID])
        #expect(state.selection == [.tab(projectID: projectID, tabID: tabID)])
        #expect(state.scrollPosition == .tab(projectID: projectID, tabID: tabID))
    }
}
