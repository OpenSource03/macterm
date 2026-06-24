import Foundation
@testable import Macterm
import Testing

/// Tree surgery used by linked groups: splicing a subtree next to a pane,
/// looking up / removing nodes by id, and origin-tag based subtree extraction.
@MainActor
struct SplitNodeSpliceTests {
    /// Merge two name→id maps from separate `build` calls so a spliced result
    /// can be rendered with both halves' names.
    private func merged(_ a: [String: UUID], _ b: [String: UUID]) -> [String: UUID] {
        a.merging(b) { lhs, _ in lhs }
    }

    // MARK: - Splice edges

    @Test
    func splice_right_places_subtree_after_pane() throws {
        let (tree, ids) = build(pane("a"))
        let (sub, subIDs) = build(pane("b"))
        let (root, seam) = try tree.splicing(subtree: sub, atPaneID: #require(ids["a"]), edge: .right)
        #expect(seam != nil)
        #expect(render(root, ids: merged(ids, subIDs)) == "H(a, b)")
    }

    @Test
    func splice_left_places_subtree_before_pane() throws {
        let (tree, ids) = build(pane("a"))
        let (sub, subIDs) = build(pane("b"))
        let (root, _) = try tree.splicing(subtree: sub, atPaneID: #require(ids["a"]), edge: .left)
        #expect(render(root, ids: merged(ids, subIDs)) == "H(b, a)")
    }

    @Test
    func splice_bottom_makes_vertical_split() throws {
        let (tree, ids) = build(pane("a"))
        let (sub, subIDs) = build(pane("b"))
        let (root, _) = try tree.splicing(subtree: sub, atPaneID: #require(ids["a"]), edge: .bottom)
        #expect(render(root, ids: merged(ids, subIDs)) == "V(a, b)")
    }

    @Test
    func splice_top_makes_vertical_split_with_subtree_first() throws {
        let (tree, ids) = build(pane("a"))
        let (sub, subIDs) = build(pane("b"))
        let (root, _) = try tree.splicing(subtree: sub, atPaneID: #require(ids["a"]), edge: .top)
        #expect(render(root, ids: merged(ids, subIDs)) == "V(b, a)")
    }

    @Test
    func splice_into_deep_pane_of_nested_tree() throws {
        let (tree, ids) = build(H(pane("l"), V(pane("r1"), pane("r2"))))
        let (sub, subIDs) = build(pane("x"))
        let (root, seam) = try tree.splicing(subtree: sub, atPaneID: #require(ids["r2"]), edge: .right)
        #expect(seam != nil)
        #expect(render(root, ids: merged(ids, subIDs)) == "H(l, V(r1, H(r2, x)))")
    }

    @Test
    func splice_unknown_pane_returns_nil_seam() {
        let (tree, ids) = build(pane("a"))
        let (sub, _) = build(pane("b"))
        let (_, seam) = tree.splicing(subtree: sub, atPaneID: UUID(), edge: .right)
        #expect(seam == nil)
        _ = ids
    }

    @Test
    func splice_subtree_preserves_subtree_topology() throws {
        let (tree, ids) = build(pane("a"))
        let (sub, subIDs) = build(V(pane("x"), pane("y")))
        let (root, _) = try tree.splicing(subtree: sub, atPaneID: #require(ids["a"]), edge: .right)
        #expect(render(root, ids: merged(ids, subIDs)) == "H(a, V(x, y))")
    }

    // MARK: - Node lookup / removal

    @Test
    func node_withID_finds_panes_and_branches() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        #expect(try tree.node(withID: #require(ids["a"]))?.id == ids["a"])
        // The root branch id resolves to the whole tree.
        #expect(tree.node(withID: tree.id)?.id == tree.id)
        #expect(tree.node(withID: UUID()) == nil)
    }

    @Test
    func removingNode_promotes_sibling() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let bID = try #require(ids["b"])
        let result = try #require(tree.removingNode(id: bID))
        #expect(render(result, ids: ids) == "a")
    }

    @Test
    func removingNode_removes_a_whole_branch() throws {
        let (tree, ids) = build(H(pane("l"), V(pane("r1"), pane("r2"))))
        guard case let .split(root) = tree else { Issue.record("expected split")
            return
        }
        let innerID = root.second.id
        let result = try #require(tree.removingNode(id: innerID))
        #expect(render(result, ids: ids) == "l")
    }

    // MARK: - Origin tagging / extraction

    @Test
    func assignOriginTab_tags_every_pane() {
        let (tree, _) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let tab = UUID()
        tree.assignOriginTab(tab)
        #expect(tree.allPanes().allSatisfy { $0.originTabID == tab })
        #expect(tree.isOwned(by: tab))
    }

    @Test
    func topmostSubtree_returns_the_members_region() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        guard case let .split(root) = tree else { Issue.record("expected split")
            return
        }
        // Tag the V(b, c) subtree as the member's contribution.
        let member = UUID()
        root.second.assignOriginTab(member)

        let subtree = try #require(tree.topmostSubtree(ownedBy: member))
        #expect(render(subtree, ids: ids) == "V(b, c)")
    }

    @Test
    func topmostSubtree_nil_when_no_panes_match() {
        let (tree, _) = build(H(pane("a"), pane("b")))
        #expect(tree.topmostSubtree(ownedBy: UUID()) == nil)
    }

    @Test
    func isOwned_false_for_mixed_origins() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let member = UUID()
        try tree.findPane(id: #require(ids["a"]))?.originTabID = member
        #expect(!tree.isOwned(by: member))
    }
}
