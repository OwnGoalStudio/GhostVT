//
//  TerminalSelectionSheet.swift
//  iGhostty
//

import GhosttyTerminal
import SwiftUI
import UIKit

/// The long-press selection page: the viewport text in a native text view,
/// pre-selected at the pressed word, so the system's selection handles,
/// magnifier, and copy menu all work on terminal content.
struct TerminalSelectionSheet: View {
    let text: String
    let anchorRange: NSRange?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            SelectionTextView(text: text, anchorRange: anchorRange)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .mediumLargeDetents()
    }
}

private struct SelectionTextView: UIViewRepresentable {
    let text: String
    let anchorRange: NSRange?

    func makeUIView(context _: Context) -> AnchoredSelectionTextView {
        let view = AnchoredSelectionTextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.text = text
        view.pendingAnchorRange = anchorRange
        return view
    }

    func updateUIView(_: AnchoredSelectionTextView, context _: Context) {}
}

/// Applies the anchor selection once the view is actually on screen — a
/// representable's `makeUIView` runs before the sheet is presented, where
/// `becomeFirstResponder` and `selectedRange` are still no-ops.
final class AnchoredSelectionTextView: UITextView {
    var pendingAnchorRange: NSRange?
    private var didApplyAnchor = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !didApplyAnchor else { return }
        didApplyAnchor = true
        DispatchQueue.main.async { [weak self] in
            self?.applyAnchorSelection()
        }
    }

    private func applyAnchorSelection() {
        becomeFirstResponder()
        let length = (text as NSString).length
        if let range = pendingAnchorRange, NSMaxRange(range) <= length {
            selectedRange = range
            scrollRangeToVisible(range)
        } else {
            selectAll(nil)
        }
    }
}

private extension View {
    /// `presentationDetents` arrived in iOS 16; earlier systems just get the
    /// regular full-height sheet.
    @ViewBuilder
    func mediumLargeDetents() -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.medium, .large])
        } else {
            self
        }
    }
}
