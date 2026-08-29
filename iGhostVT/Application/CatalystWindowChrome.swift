//
//  CatalystWindowChrome.swift
//  iGhostVT
//

import UIKit

#if targetEnvironment(macCatalyst)
    import ObjectiveC

    /// The Mac window's dressing: the title bar is hidden (`SceneDelegate`)
    /// and the app draws up to the window's top edge, so the top bar is the
    /// title bar. `install()` hooks the point where UIKit's AppKit side has
    /// just built the `NSWindow` for a scene
    /// (`UINSApplicationDelegate didCreateUIScene:transitionContext:`) to
    /// place the traffic lights on that bar. The window carries no
    /// behind-window blur: the sidebar is the terminal's background colour.
    ///
    /// All AppKit is reached through the ObjC runtime: a Catalyst target
    /// cannot import it. Every step is guarded, so an AppKit that no longer
    /// answers leaves the window plain instead of crashing.
    enum CatalystWindowChrome {
        /// UIKit points per screen point. A Catalyst app in the iPad idiom
        /// is drawn at 77%, so a distance measured on the screen — where
        /// AppKit places the traffic lights — is longer in the app's own
        /// coordinates; the Mac idiom draws 1:1.
        @MainActor private static let pointsPerScreenPoint: CGFloat =
            UIDevice.current.userInterfaceIdiom == .mac ? 1 : 1 / 0.77

        /// The strip the traffic lights live in once the title bar is
        /// hidden — the top bar's height, because the lights are moved to
        /// its vertical centre (`positionWindowControls`), so the sidebar's
        /// list starts level with the terminal under the bar.
        @MainActor static let titleBarHeight: CGFloat = TabStripBar.height

        /// The lights' height and their standard distance from the top of a
        /// window without a title bar, in screen points.
        private static let windowControlsHeight: CGFloat = 16

        /// Where the traffic lights end: three 16pt buttons from x = 8, 7pt
        /// apart, so 70 screen points in. Content beside them adds its own
        /// gap — the top bar the same 8pt it keeps between its controls.
        @MainActor static let windowControlsEnd: CGFloat = 70 * pointsPerScreenPoint

        static func install() {
            guard let delegateClass = NSClassFromString("UINSApplicationDelegate") else { return }
            let selector = sel_registerName("didCreateUIScene:transitionContext:")
            guard let method = class_getInstanceMethod(delegateClass, selector) else { return }
            let original = method_getImplementation(method)
            typealias Original = @convention(c) (AnyObject, Selector, UIScene, AnyObject) -> Void
            let block: @convention(block) (AnyObject, UIScene, AnyObject) -> Void = { target, scene, context in
                unsafeBitCast(original, to: Original.self)(target, selector, scene, context)
                guard let nsWindow = hostWindow(for: scene) else { return }
                positionWindowControls(in: nsWindow)
                // AppKit tiles the title bar again on every resize, putting
                // the lights back where a title bar would want them.
                NotificationCenter.default.addObserver(
                    forName: Notification.Name("NSWindowDidResizeNotification"),
                    object: nsWindow,
                    queue: .main
                ) { notification in
                    guard let window = notification.object as? NSObject else { return }
                    positionWindowControls(in: window)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block as Any))
        }

        /// The `NSWindow` (a `UINSWindow`) AppKit built for the scene.
        private static func hostWindow(for scene: UIScene) -> NSObject? {
            guard let windowScene = scene as? UIWindowScene,
                  let uiWindow = windowScene.windows.first,
                  let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let app = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject,
                  let delegate = app.perform(NSSelectorFromString("delegate"))?.takeUnretainedValue() as? NSObject
            else { return nil }
            let hostWindow = sel_registerName("hostWindowForUIWindow:")
            guard delegate.responds(to: hostWindow),
                  let proxy = delegate.perform(hostWindow, with: uiWindow)?.takeUnretainedValue() as? NSObject,
                  proxy.responds(to: NSSelectorFromString("attachedWindow")),
                  let nsWindow = proxy.perform(NSSelectorFromString("attachedWindow"))?.takeUnretainedValue() as? NSObject,
                  let windowClass = NSClassFromString("UINSWindow"), nsWindow.isKind(of: windowClass)
            else { return nil }
            return nsWindow
        }

        /// Centres the close, minimize, and zoom buttons on the top bar. With
        /// no title bar AppKit leaves them at a title bar's height, a few
        /// points above the bar's own controls; the bar is the title bar now.
        private static func positionWindowControls(in nsWindow: NSObject) {
            typealias StandardButton = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<AnyObject>?
            typealias SetOrigin = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let buttonSelector = NSSelectorFromString("standardWindowButton:")
            let originSelector = NSSelectorFromString("setFrameOrigin:")
            guard nsWindow.responds(to: buttonSelector) else { return }
            let standardButton = unsafeBitCast(nsWindow.method(for: buttonSelector), to: StandardButton.self)
            // Called on the main thread (AppKit's window hook and its resize
            // notification, delivered on the main queue), which the metrics
            // require.
            let topInset = MainActor.assumeIsolated {
                (titleBarHeight / 2) / pointsPerScreenPoint - windowControlsHeight / 2
            }
            for kind in 0 ... 2 { // close, miniaturize, zoom
                guard let button = standardButton(nsWindow, buttonSelector, kind)?.takeUnretainedValue() as? NSObject,
                      let frame = (button.value(forKey: "frame") as? NSValue)?.cgRectValue,
                      let superview = button.value(forKey: "superview") as? NSObject,
                      let bounds = (superview.value(forKey: "bounds") as? NSValue)?.cgRectValue
                else { continue }
                let flipped = (superview.value(forKey: "flipped") as? Bool) ?? false
                let y = flipped ? topInset : bounds.height - topInset - frame.height
                let setOrigin = unsafeBitCast(button.method(for: originSelector), to: SetOrigin.self)
                setOrigin(button, originSelector, CGPoint(x: frame.origin.x, y: y))
            }
        }
    }

    extension UIResponder {
        /// Hands the mouse event UIKit is currently delivering to AppKit as a
        /// window drag, so the chrome behaves like a title bar. Only useful
        /// from inside a touch callback: `NSApp.currentEvent` is that press.
        func dispatchTouchAsWindowMovement() {
            guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let app = appClass.value(forKey: "sharedApplication") as? NSObject,
                  let event = app.value(forKey: "currentEvent") as? NSObject,
                  let window = event.value(forKey: "window") as? NSObject
            else { return }
            window.perform(NSSelectorFromString("performWindowDragWithEvent:"), with: event)
        }
    }
#endif
