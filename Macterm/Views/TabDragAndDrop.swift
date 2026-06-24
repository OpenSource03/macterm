import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// In-app drag payload identifying a tab dragged from the sidebar onto a
    /// terminal pane to form (or extend) a linked split group.
    static let mactermTab = UTType(exportedAs: "com.thdxg.macterm.tab")
}

/// Lightweight, `Sendable` identifier for a dragged tab. The real handoff goes
/// through `AppState.draggingTab` (read synchronously on drop); the item
/// provider only needs to advertise the type so panes recognize the drag.
struct TabTransfer: Codable, Hashable {
    let projectID: UUID
    let tabID: UUID

    /// An item provider that advertises `mactermTab` without carrying a real
    /// payload — the payload is read from `AppState.draggingTab`.
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.mactermTab.identifier, visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }
}

extension PaneDropEdge {
    /// The edge a drop at `point` (in a view of `size`) targets: the view is cut
    /// into four triangles meeting at the center, so the nearest edge wins.
    /// Aspect ratio is normalized out so the diagonals stay at the corners.
    static func from(point: CGPoint, in size: CGSize) -> PaneDropEdge {
        let nx = (point.x - size.width / 2) / max(size.width, 1)
        let ny = (point.y - size.height / 2) / max(size.height, 1)
        if abs(nx) >= abs(ny) { return nx < 0 ? .left : .right }
        return ny < 0 ? .top : .bottom
    }

    /// The rectangle, within `size`, that this edge's drop would occupy — used
    /// to draw the live placement preview.
    func previewRect(in size: CGSize) -> CGRect {
        switch self {
        case .left: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

/// Drop target for a terminal pane. Tracks the hovered edge continuously so the
/// pane can show a directional placement preview, and on drop links the dragged
/// tab into the pane on that edge.
///
/// `DropDelegate` callbacks arrive on the main thread; `MainActor.assumeIsolated`
/// lets us touch `AppState` (which owns the dragged-tab handoff) without hopping
/// actors or decoding the provider asynchronously.
struct TabLinkDropDelegate: DropDelegate {
    let appState: AppState
    let paneID: UUID
    let size: CGSize
    @Binding var hoveredEdge: PaneDropEdge?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.mactermTab])
    }

    func dropEntered(info: DropInfo) {
        hoveredEdge = PaneDropEdge.from(point: info.location, in: size)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hoveredEdge = PaneDropEdge.from(point: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        hoveredEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let edge = PaneDropEdge.from(point: info.location, in: size)
        hoveredEdge = nil
        return MainActor.assumeIsolated {
            guard let transfer = appState.draggingTab else { return false }
            appState.draggingTab = nil
            // Dropping a tab onto its own pane is a no-op.
            guard transfer.tabID != paneOwningTabID() else { return false }
            appState.linkTab(transfer.tabID, intoPane: paneID, edge: edge)
            return true
        }
    }

    /// The tab that currently owns this pane, so we can reject a self-drop.
    @MainActor
    private func paneOwningTabID() -> UUID? {
        appState.findTabContainingPane(paneID)?.tab.id
    }
}
