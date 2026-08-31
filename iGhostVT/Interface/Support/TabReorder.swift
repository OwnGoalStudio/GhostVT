//
//  TabReorder.swift
//  iGhostVT
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Drag-to-reorder for the tab list, shared by the sidebar's rows and the
/// strip's chips. The row under the pointer takes the dragged tab's slot as
/// the drag passes over it (`dropEntered`), so the list reorders live and
/// the drop itself only ends the gesture.
///
/// Built on `onDrag`/`onDrop` rather than `List.onMove` because neither
/// presentation is a `List`, and rather than `draggable`/`dropDestination`
/// because those are iOS 16. iPad and the Mac only: a drag needs a pointer
/// or a lift, and on the phone a long press on a tab is its context menu.
enum TabReorder {
    /// The drag item's own type, visible to this process alone. A tab
    /// dragged over the terminal must not paste as text, and a type that
    /// conforms to nothing is what `TerminalDropDelegate` refuses.
    static let itemType = UTType(exportedAs: "wiki.qaq.ighostvt.tab")

    static var isSupported: Bool {
        #if targetEnvironment(macCatalyst)
            return true
        #else
            return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    /// The token a drag carries. Reordering reads the tab from
    /// `DraggedTab` instead — `dropEntered` is synchronous and an item
    /// provider only loads asynchronously — so the payload is an id for
    /// form's sake, and the drag's identity is what it registers as.
    static func itemProvider(for tab: TerminalTab) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(tab.id.uuidString.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: itemType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }
}

/// The tab a drag started from, held by the list that shows it. One drag
/// at a time per list is all the system allows, so one slot suffices.
@MainActor
final class DraggedTab: ObservableObject {
    /// Not published: the views read it only from drop callbacks, and a
    /// redraw of every row at each `dropEntered` would fight the move
    /// animation.
    var tab: TerminalTab?
}

/// What travels under the finger. The system's default is a snapshot of
/// the source view, and a chip or row that is not the active one has no
/// background of its own — the snapshot came up as a blank grey slab. So
/// the preview is drawn on purpose: the tab's dot and name on an opaque
/// card in the source's own shape, sized to the source.
struct TabDragPreview: View {
    enum Style {
        /// The strip's capsule: one line, the chip's height.
        case chip
        /// The sidebar's card: title over the secondary line.
        case row
    }

    @ObservedObject var tab: TerminalTab
    let style: Style
    let width: CGFloat

    var body: some View {
        Group {
            switch style {
            case .chip:
                HStack(spacing: DS.Padding.xs) {
                    ObservedStatusDot(store: tab.store, font: .label)
                    Text(tab.displayTitle)
                        .font(DS.Font.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Padding.m)
                .frame(width: width, height: 32)
                .background(Capsule().fill(Color(uiColor: .systemBackground)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            case .row:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Padding.s) {
                        ObservedStatusDot(store: tab.store, font: .labelEmphasis)
                        Text(tab.displayTitle)
                            .font(DS.Font.labelEmphasis)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(tab.secondaryTitle)
                        .font(DS.Font.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Padding.m)
                .padding(.vertical, DS.Padding.s)
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .fill(Color(uiColor: .systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .foregroundColor(.primary)
    }
}

extension View {
    /// Makes this presentation of `tab` a drag source and a drop slot.
    /// Applied outside the context menu, so the lift that opens the menu
    /// is also the one that starts the drag.
    @ViewBuilder
    func tabReorderable(
        _ tab: TerminalTab,
        in tabManager: TabManager,
        dragged: DraggedTab,
        preview: TabDragPreview.Style,
        width: CGFloat
    ) -> some View {
        if TabReorder.isSupported {
            onDrag {
                dragged.tab = tab
                return TabReorder.itemProvider(for: tab)
            } preview: {
                TabDragPreview(tab: tab, style: preview, width: width)
            }
            .onDrop(
                of: [TabReorder.itemType],
                delegate: TabReorderSlotDelegate(tab: tab, tabManager: tabManager, dragged: dragged)
            )
        } else {
            self
        }
    }

    /// The list's own drop: a release over its padding, or over a control
    /// that is not a tab, still ends the drag where the tab already sits
    /// instead of springing the preview back to where it started.
    @ViewBuilder
    func tabReorderContainer(dragged: DraggedTab) -> some View {
        if TabReorder.isSupported {
            onDrop(of: [TabReorder.itemType], delegate: TabReorderEndDelegate(dragged: dragged))
        } else {
            self
        }
    }
}

private struct TabReorderSlotDelegate: DropDelegate {
    let tab: TerminalTab
    let tabManager: TabManager
    let dragged: DraggedTab

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TabReorder.itemType])
    }

    func dropEntered(info _: DropInfo) {
        guard let moving = dragged.tab, moving.id != tab.id else { return }
        tabManager.moveTab(moving, toSlotOf: tab)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragged.tab = nil
        return true
    }
}

private struct TabReorderEndDelegate: DropDelegate {
    let dragged: DraggedTab

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TabReorder.itemType])
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragged.tab = nil
        return true
    }
}
