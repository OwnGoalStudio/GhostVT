//
//  AlertCardView.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// One action on an alert card. Titles arrive as `String.LocalizationValue`,
/// so a call site's string literal stays a localization key implicitly — the
/// same contract SwiftUI's `.alert` gave those literals via
/// `LocalizedStringKey`. Passing a `String` variable will not compile, which
/// is the point: an unlocalized title has to say so with `verbatim:`.
struct AlertAction: Identifiable {
    let id = UUID()
    let title: String
    let kind: AlertButtonStyle.Kind
    let handler: () -> Void

    init(
        _ title: String.LocalizationValue,
        kind: AlertButtonStyle.Kind = .normal,
        handler: @escaping () -> Void = {}
    ) {
        self.init(verbatim: String(localized: title), kind: kind, handler: handler)
    }

    init(
        verbatim title: String,
        kind: AlertButtonStyle.Kind = .normal,
        handler: @escaping () -> Void = {}
    ) {
        self.title = title
        self.kind = kind
        self.handler = handler
    }
}

/// The app's one alert design, a SwiftUI rendition of Lakr233/AlertController:
/// centered material card, app-icon header, and a button row whose emphasized
/// action fills with its tint. Shown inline by `SessionStatusOverlay` and
/// presented modally by `AlertViewController` — the design lives here so both
/// stay the same card.
///
/// Title and message are already-resolved strings; localize at the call site
/// (`String(localized:)` or the `AlertAction` initializer above) so literals
/// keep their catalog keys.
struct AlertCardView: View {
    let title: String
    let message: String
    let actions: [AlertAction]

    var body: some View {
        VStack(spacing: DS.Padding.l) {
            Image("AlertIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))

            Text(title)
                .font(DS.Font.title)
                .multilineTextAlignment(.center)

            if !message.isEmpty {
                Text(message)
                    .font(DS.Font.detail)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
            }

            HStack(spacing: DS.Padding.s) {
                ForEach(actions) { action in
                    Button(action: action.handler) {
                        Text(action.title)
                    }
                    .buttonStyle(AlertButtonStyle(kind: action.kind))
                }
            }
        }
        .padding(DS.Padding.l)
        .frame(maxWidth: 350)
        .background(.regularMaterial)
        .background(Color(UIColor.systemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// AlertController's button, translated: full-width rounded rectangle with a
/// 1pt border; the emphasized kinds fill with their tint and speak semibold,
/// the normal one stays clear with accent-colored text. Destructive is the
/// accent treatment in red, standing in for `UIAlertAction`'s `.destructive`.
struct AlertButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case accent
        case destructive
    }

    let kind: Kind

    private var tint: Color {
        kind == .destructive ? .red : .accentColor
    }

    private var isFilled: Bool {
        kind != .normal
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isFilled ? DS.Font.controlEmphasis : DS.Font.body)
            .foregroundColor(isFilled ? .white : .accentColor)
            .padding(DS.Padding.s)
            .frame(maxWidth: .infinity)
            .background(isFilled ? tint : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(tint, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
