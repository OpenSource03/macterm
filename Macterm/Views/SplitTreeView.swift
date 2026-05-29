import AppKit
import SwiftUI

/// Recursively renders a split tree as nested split views or a single terminal pane.
struct SplitTreeView: View {
    let node: SplitNode
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
    let isActiveProject: Bool
    let projectID: UUID
    let isSplit: Bool
    let onFocusPane: (UUID) -> Void
    let onSplit: (UUID, SplitDirection) -> Void
    let onClosePane: (UUID) -> Void
    let onToggleZoom: (UUID) -> Void

    init(
        node: SplitNode,
        focusedPaneID: UUID?,
        zoomedPaneID: UUID? = nil,
        isActiveProject: Bool,
        projectID: UUID,
        isSplit: Bool = false,
        onFocusPane: @escaping (UUID) -> Void,
        onSplit: @escaping (UUID, SplitDirection) -> Void,
        onClosePane: @escaping (UUID) -> Void,
        onToggleZoom: @escaping (UUID) -> Void = { _ in }
    ) {
        self.node = node
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
        self.isActiveProject = isActiveProject
        self.projectID = projectID
        self.isSplit = isSplit
        self.onFocusPane = onFocusPane
        self.onSplit = onSplit
        self.onClosePane = onClosePane
        self.onToggleZoom = onToggleZoom
    }

    var body: some View {
        switch node {
        case let .pane(pane):
            let isFocused = focusedPaneID == pane.id && isActiveProject
            TerminalPane(
                pane: pane,
                focused: isFocused,
                isZoomed: zoomedPaneID == pane.id,
                onFocus: { onFocusPane(pane.id) },
                onProcessExit: { onClosePane(pane.id) },
                onSplitRequest: { dir, _ in onSplit(pane.id, dir) },
                onZoomRequest: { onToggleZoom(pane.id) }
            )
            .overlay {
                PaneFocusOverlay(isFocused: isFocused, isSplit: isSplit)
            }

        case let .split(branch):
            SplitDividerView(branch: branch) {
                SplitTreeView(
                    node: branch.first,
                    focusedPaneID: focusedPaneID,
                    zoomedPaneID: zoomedPaneID,
                    isActiveProject: isActiveProject,
                    projectID: projectID,
                    isSplit: true,
                    onFocusPane: onFocusPane,
                    onSplit: onSplit,
                    onClosePane: onClosePane,
                    onToggleZoom: onToggleZoom
                )
                .id(branch.first.id)
            } second: {
                SplitTreeView(
                    node: branch.second,
                    focusedPaneID: focusedPaneID,
                    zoomedPaneID: zoomedPaneID,
                    isActiveProject: isActiveProject,
                    projectID: projectID,
                    isSplit: true,
                    onFocusPane: onFocusPane,
                    onSplit: onSplit,
                    onClosePane: onClosePane,
                    onToggleZoom: onToggleZoom
                )
                .id(branch.second.id)
            }
        }
    }
}

/// Focus affordance drawn on top of a pane that lives inside a split: a crisp
/// accent ring on the active pane plus a gentle dim on the inactive ones. This
/// is purely an overlay, so it never alters the pane's frame — changing the
/// frame would resize the underlying ghostty surface.
private struct PaneFocusOverlay: View {
    let isFocused: Bool
    let isSplit: Bool

    var body: some View {
        ZStack {
            // Subtle dim on inactive panes for depth and contrast against the
            // focused one. Kept light so unfocused output stays readable.
            Rectangle()
                .fill(Color.black)
                .opacity(!isFocused && isSplit ? 0.14 : 0)

            // Accent ring on the active pane. `strokeBorder` insets the stroke
            // so it draws inside the pane's bounds and isn't clipped at edges.
            Rectangle()
                .strokeBorder(MactermTheme.accent, lineWidth: 2)
                .opacity(isFocused && isSplit ? 0.9 : 0)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// A resizable split container with a draggable divider.
struct SplitDividerView<First: View, Second: View>: View {
    let branch: SplitBranch
    @ViewBuilder
    let first: First
    @ViewBuilder
    let second: Second

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let h = branch.direction == .horizontal
            let total = h ? geo.size.width : geo.size.height
            let firstSize = max(0, total * branch.ratio - 0.5)
            let secondSize = max(0, total * (1 - branch.ratio) - 0.5)
            let layout = h ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            let active = isHovering || isDragging

            layout {
                first.frame(width: h ? firstSize : nil, height: h ? nil : firstSize)

                // The divider occupies a 1pt slot in layout. The visible line is
                // drawn inside that slot but is free to thicken and recolor on
                // hover/drag without overflowing into — and so shifting — the
                // panes on either side.
                Rectangle()
                    .fill(active ? MactermTheme.accent : MactermTheme.border)
                    .frame(
                        width: h ? (active ? 2 : 1) : nil,
                        height: h ? nil : (active ? 2 : 1)
                    )
                    .frame(width: h ? 1 : nil, height: h ? nil : 1)
                    .overlay {
                        // Generous invisible hit target makes the hairline easy
                        // to grab; it overflows the 1pt slot but doesn't paint.
                        Color.clear
                            .frame(width: h ? 10 : nil, height: h ? nil : 10)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { v in
                                        isDragging = true
                                        let pos = h ? v.location.x : v.location.y
                                        let origin = h ? v.startLocation.x : v.startLocation.y
                                        let newPos = total * branch.ratio + (pos - origin)
                                        branch.ratio = min(max(newPos / total, 0.15), 0.85)
                                    }
                                    .onEnded { _ in isDragging = false }
                            )
                            .onHover { on in
                                isHovering = on
                                if on {
                                    (h ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                    }
                    .animation(.easeOut(duration: 0.1), value: active)

                second.frame(width: h ? secondSize : nil, height: h ? nil : secondSize)
            }
        }
    }
}
