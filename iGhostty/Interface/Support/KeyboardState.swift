import Combine
import SwiftUI
import UIKit

/// Tracks software keyboard visibility so the Safari-style bottom bar can
/// step aside while typing.
@MainActor
final class KeyboardState: ObservableObject {
    @Published private(set) var isVisible = false

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
        center.publisher(for: UIResponder.keyboardWillShowNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.isVisible = true
                }
            }
            .store(in: &cancellables)
        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.isVisible = false
                }
            }
            .store(in: &cancellables)
    }
}
