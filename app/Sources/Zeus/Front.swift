import AppKit
import WebKit

/// Brings the app and its windows to the front.
/// With ZEUS_APP_TEST_BACKGROUND=1 (debug builds only), the app never activates and puts its windows
/// behind the windows of other apps, so tests do not come in front of the user's work.
enum Front {
    static let background: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ZEUS_APP_TEST_BACKGROUND"] == "1"
        #else
        return false
        #endif
    }()

    static func activate() {
        guard !background else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// WebKit slows down a page in a window that other windows cover. In the background, the pages
    /// must run as in front, so that the tests see the same timing.
    static func prepare(_ webView: WKWebView) {
        guard background else { return }
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(webView, selector, false)
    }

    static func show(_ window: NSWindow?) {
        guard let window else { return }
        if background {
            // In front of the other Zeus windows, as without the switch, but behind the windows of other apps.
            if let top = NSApp.orderedWindows.first(where: { $0 !== window && $0.isVisible }) {
                window.order(.above, relativeTo: top.windowNumber)
            } else {
                window.orderBack(nil)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
