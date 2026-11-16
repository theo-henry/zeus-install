import AppKit

/// Test runs only (debug builds): with ZEUS_APP_QUIET_WINDOWS=1 the app never takes the focus from the consultant's other apps
/// and puts its windows on one fixed screen (ZEUS_APP_TEST_SCREEN, 1-based, default 1), not on the screen of the mouse.
/// `Front` applies it to every window that the app shows.
enum QuietWindows {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ZEUS_APP_QUIET_WINDOWS"] == "1"
        #else
        return false
        #endif
    }()

    private static var screen: NSScreen? {
        let index = Int(ProcessInfo.processInfo.environment["ZEUS_APP_TEST_SCREEN"] ?? "1") ?? 1
        let screens = NSScreen.screens
        return screens.isEmpty ? nil : screens[min(max(index, 1), screens.count) - 1]
    }

    /// In a quiet test run, moves the window to the middle of the test screen when it is on another screen.
    static func place(_ window: NSWindow) {
        guard isOn, let screen, window.screen != screen else { return }
        var frame = window.frame
        let area = screen.visibleFrame
        frame.origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        window.setFrame(frame, display: false)
    }
}
