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
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AppIconMark(size: 22)
                        Text("\(context.state.totalCount)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Palette.accent)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusDots(sessions: context.state.sessions)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionList(state: context.state, limit: 3, font: .footnote)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                }
            } compactLeading: {
                AppIconMark(size: 23)
            } compactTrailing: {
                Text("\(context.state.totalCount)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.accent)
            } minimal: {
                AppIconMark(size: 23)
            }
        }
    }
}
