import Foundation

/// A *linked group* of tabs that share one combined split layout.
///
/// The combined tree physically lives in the **host tab's** `splitRoot`; each
/// other member's panes are spliced into that tree (tagged with the member's
/// id via `Pane.originTabID`). Every member tab keeps its sidebar row, and
/// selecting any member renders the same host tree — so the group reads as one
/// side-by-side view from any of its tabs. Members may live in different
/// projects/workspaces; the group spans them.
///
/// Focus and zoom are not stored here: they already live on the host tab, which
/// owns the tree.
@MainActor @Observable
final class TabGroup: Identifiable {
    let id: UUID
    /// The tab whose `splitRoot` holds the combined tree.
    var hostTabID: UUID
    /// All member tab ids in sidebar order, host included.
    var memberOrder: [UUID]
    /// Stable index into the sidebar group-accent palette.
    let colorIndex: Int

    init(id: UUID = UUID(), hostTabID: UUID, colorIndex: Int) {
        self.id = id
        self.hostTabID = hostTabID
        memberOrder = [hostTabID]
        self.colorIndex = colorIndex
    }

    var memberCount: Int { memberOrder.count }

    func contains(_ tabID: UUID) -> Bool {
        memberOrder.contains(tabID)
    }
}
