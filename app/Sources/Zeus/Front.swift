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
        guard !background, !QuietWindows.isOn else { return }
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

    /// The window is out of view: other windows cover it, it is minimized, or another tab of its window shows.
    /// In the background, the windows of other apps cover the test windows, so only a minimized window or
    /// another tab counts, as for a window in front.
    static func isOutOfView(_ window: NSWindow) -> Bool {
        guard background else { return !window.occlusionState.contains(.visible) }
        if window.isMiniaturized { return true }
        if let selected = window.tabGroup?.selectedWindow, selected !== window { return true }
        return false
    }

    static func show(_ window: NSWindow?) {
        guard let window else { return }
        QuietWindows.place(window)
        if background {
            putBack(window, among: NSApp.orderedWindows)
        } else if QuietWindows.isOn {
            window.orderFront(nil)   // In front of the app's own windows only, without the focus.
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// AppKit puts a window above the windows of other apps when a sheet begins or ends on it,
    /// also when the app is not active. In the background, the window goes back after each.
    static func beginSheet(_ alert: NSAlert, for window: NSWindow,
                           completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard background else {
            alert.beginSheetModal(for: window, completionHandler: completion)
            return
        }
        // Without the sheet: the sheet is not yet marked as a sheet when beginSheetModal returns.
        let windows = NSApp.orderedWindows
        alert.beginSheetModal(for: window) { response in
            putBack(window, among: windows)
            completion(response)
        }
        putBack(window, among: windows)
    }

    /// In front of the other Zeus windows, as without the switch, but behind the windows of other apps.
    private static func putBack(_ window: NSWindow, among windows: [NSWindow]) {
        if let top = windows.first(where: { $0 !== window && $0.isVisible }) {
            window.order(.above, relativeTo: top.windowNumber)
        } else {
            window.orderBack(nil)
        }
    }
}
