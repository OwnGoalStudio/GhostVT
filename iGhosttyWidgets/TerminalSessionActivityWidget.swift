//
//  TerminalSessionActivityWidget.swift
//  iGhosttyWidgets
//

import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + Lock Screen presentation of the running terminal sessions.
///
/// The expanded island puts every word in the bottom region: it is the only
/// one wide enough for a path, and the center region sits under whatever else
/// the system (or a tweak) draws beside the camera, where text collides.
struct TerminalSessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TerminalSessionAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // Icon left, count right — the expanded island is the
                // compact one opened up, so the corners keep their roles.
                // The per-row dots below carry the status; a second dot
                // summary up here said the same thing, uglier.
                DynamicIslandExpandedRegion(.leading) {
                    AppIconMark(size: 26)
                        .padding(.leading, Spacing.tight)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.countLabel)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .fontDesign(.rounded)
                        .foregroundStyle(Palette.accent)
                        .contentTransition(.numericText())
                        .padding(.trailing, Spacing.tight)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionList(state: context.state, font: .footnote)
                        .fontDesign(.rounded)
                        .padding(.horizontal, Spacing.tight)
                        .padding(.top, Spacing.tight)
                }
            } compactLeading: {
                AppIconMark(size: 23)
            } compactTrailing: {
                Text(context.state.countLabel)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .fontDesign(.rounded)
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.numericText())
            } minimal: {
                AppIconMark(size: 23)
            }
        }
    }
}
