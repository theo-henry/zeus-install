import AppKit
import WebKit

/// The app part of "Check for updates" and "Update now" in the settings of a Zeus page (zeus-editor).
///
/// A page posts to `window.webkit.messageHandlers.zeusApp`:
/// - `{type: "app-update-check"}`: the app asks the zeus repo for its app releases (`Updater.listReleases`) and answers
///   in that page with `window.zeusApp.onUpdateEvent({type: "app-update-check", status, version, latest, notes, message?,
///   error?, available})` (the contract of zeus-editor, docs/chat.md). `status` is "current", "available" (the app can
///   install `latest` now), or "error". `version` is the installed version, `latest` the newest app release (or null),
///   and `notes` the release notes of every release newer than `version` (an array). When GitHub does not answer, or
///   when this copy cannot update itself, `status` is "error", `error` is "no-gh", "unreachable", "no-release",
///   "development", or "cannot-update", and `message` says it in words.
/// - `{type: "app-update-apply"}`: the page that asked gets `{type: "app-update-apply", status: "started" | "error",
///   message?}` as soon as the new release is found ("error" when it is not, or when this copy cannot update itself).
///   The app downloads and checks the newest release as at launch, waits until no tab
///   works (a turn, a message on its way, or a start), then shows the loading screen, keeps the tabs (`TabRestore`),
///   ends the sessions, swaps the app, and starts the new copy, which opens the same tabs again.
///   On the way, every chat page and the page that asked get `window.zeusApp.onUpdateEvent` with
///   `{type: "app-update-progress", state: "checking" | "downloading" | "waiting" | "installing", version?, busy?}`
///   (`busy`: the number of tabs that the update waits for), or `{type: "app-update-failed", error, message}`
///   with `error` "up-to-date", "download-failed", "cannot-update", or one of the check errors.
///   When the new copy does not confirm, the old copy is put back and opens the same tabs again, with a message.
final class AppUpdate {
    static let shared = AppUpdate()

    /// The page bridge: `window.zeusApp.update` (see `WebViewHandler.pageBridgeScript`).
    static let pageInfo: [String: Any] = ["version": 1]

    /// The app delegate, which owns the tabs.
    weak var app: AppDelegate?

    private enum Phase: String {
        case idle, checking, downloading, waiting, installing
    }

    private var phase = Phase.idle
    private var version: String?
    private var busyTabs = 0
    /// The page that asked for the update, also a Zeus Editor page.
    private weak var requester: WKWebView?

    /// Returns true when the message was an update message.
    func handle(_ body: Any, from webView: WKWebView?) -> Bool {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return false }
        switch type {
        case "app-update-check":
            check(for: webView)
        case "app-update-apply":
            apply(from: webView)
        default:
            return false
        }
        return true
    }

    // MARK: Check

    private func check(for webView: WKWebView?) {
        Trace.log("app update: check")
        DispatchQueue.global(qos: .userInitiated).async {
            let event = Self.checkEvent(Updater.listReleases(timeout: Updater.pageCheckTimeout))
            DispatchQueue.main.async {
                Trace.log("app update: answer \(event["status"] as? String ?? "-") \(event["latest"] as? String ?? "-") available=\(event["available"] as? Bool ?? false) error=\(event["error"] as? String ?? "-")")
                if let webView { Self.send(event, to: webView) }
            }
        }
    }

    private static func checkEvent(_ list: Updater.ReleaseList) -> [String: Any] {
        let current = Updater.currentVersion
        var event: [String: Any] = ["type": "app-update-check", "status": "current", "version": current, "current": current,
                                    "latest": NSNull(), "notes": [String](), "available": false]
        let releases: [Updater.Release]
        switch list {
        case .failed(let why):
            let error = why == "no gh" ? "no-gh" : "unreachable"
            return failed(&event, error)
        case .releases(let list):
            releases = list
        }
        guard let newest = releases.first else {
            return failed(&event, "no-release")
        }
        event["latest"] = newest.version.description
        guard let installed = Version(current) else {
            return failed(&event, "development")
        }
        let newer = releases.filter { $0.version > installed }
        guard !newer.isEmpty else { return event }
        event["notes"] = newer.map { release in
            let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return notes.isEmpty ? "Zeus \(release.version)" : "Zeus \(release.version)\n\n\(notes)"
        }
        if let reason = Updater.skipReason() {
            Trace.log("app update: cannot update (\(reason))")
            return failed(&event, "cannot-update")
        }
        event["status"] = "available"
        event["available"] = true
        return event
    }

    private static func failed(_ event: inout [String: Any], _ error: String) -> [String: Any] {
        event["status"] = "error"
        event["error"] = error
        event["message"] = message(for: error)
        return event
    }

    private static func message(for error: String) -> String {
        switch error {
        case "no-gh": return "The GitHub CLI (gh) is not installed. Run the Zeus Setup."
        case "unreachable": return "GitHub did not answer. Check the internet connection and your GitHub login (gh auth status)."
        case "no-release": return "The zeus repo has no Zeus app release."
        case "development": return "This is a development build of the Zeus app. It does not update itself."
        case "cannot-update": return "This copy of the Zeus app cannot update itself. Install the new version with the Zeus install line."
        case "up-to-date": return "The Zeus app is on the latest version."
        default: return "The update could not be downloaded or checked. Zeus stays on version \(Updater.currentVersion)."
        }
    }

    // MARK: Apply

    private func apply(from webView: WKWebView?) {
        requester = webView ?? requester
        guard phase == .idle else {
            Trace.log("app update: apply while \(phase.rawValue)")
            reply(["type": "app-update-apply", "status": "started"])
            sendProgress()
            return
        }
        if let reason = Updater.skipReason() {
            Trace.log("app update: cannot update (\(reason))")
            let error = Version(Updater.currentVersion) == nil ? "development" : "cannot-update"
            reply(["type": "app-update-apply", "status": "error", "message": Self.message(for: error)])
            broadcast(["type": "app-update-failed", "error": error, "message": Self.message(for: error)])
            return
        }
        Trace.log("app update: apply")
        phase = .checking
        version = nil
        sendProgress()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Updater.checkAndDownload(timeout: Updater.userCheckTimeout) { version in
                DispatchQueue.main.async {
                    self.version = version
                    self.reply(["type": "app-update-apply", "status": "started"])
                    self.phase = .downloading
                    self.sendProgress()
                }
            }
            DispatchQueue.main.async {
                switch result {
                case .none(let why):
                    Trace.log("app update: none (\(why))")
                    self.phase = .idle
                    let error = why == "up to date" ? "up-to-date" : why == "no gh" ? "no-gh"
                        : why == "no app release" ? "no-release" : why.hasPrefix("no release list") ? "unreachable" : "download-failed"
                    // A page that did not get "started" yet (the release was not found) gets its error here.
                    if self.version == nil { self.reply(["type": "app-update-apply", "status": "error", "message": Self.message(for: error)]) }
                    self.broadcast(["type": "app-update-failed", "error": error, "message": Self.message(for: error)])
                case .ready(let update):
                    self.version = update.version
                    self.waitForIdleTabs(update)
                }
            }
        }
    }

    /// The update waits until no tab works, so that no turn is cut off.
    private func waitForIdleTabs(_ update: Updater.Update) {
        guard let app else { return }
        phase = .waiting
        app.busyTabCount { [weak self] busy in
            guard let self else { return }
            guard busy == 0 else {
                if busy != self.busyTabs {
                    self.busyTabs = busy
                    Trace.log("app update: waiting for \(busy) busy tabs")
                    self.sendProgress()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.waitForIdleTabs(update) }
                return
            }
            self.busyTabs = 0
            self.install(update)
        }
    }

    private func install(_ update: Updater.Update) {
        guard let app else { return }
        phase = .installing
        sendProgress()
        Trace.log("app update: installing \(update.version)")
        app.endTabsForUpdate(to: update.version) { restore in
            guard let restore else {
                self.waitForIdleTabs(update)
                return
            }
            Updater.install(update) { relaunching in
                guard !relaunching else { return }
                // The new copy did not start or confirm: this copy runs on and opens the same tabs again.
                self.phase = .idle
                TabRestore.remove()
                app.reopenAfterFailedUpdate(restore, version: update.version)
            }
        }
    }

    // MARK: Events

    private func sendProgress() {
        var event: [String: Any] = ["type": "app-update-progress", "state": phase.rawValue]
        if let version { event["version"] = version }
        if phase == .waiting { event["busy"] = busyTabs }
        Trace.log("app update: progress \(phase.rawValue)")
        broadcast(event)
    }

    /// To the page that asked, as the answer of its `app-update-apply`.
    private func reply(_ event: [String: Any]) {
        if let requester { Self.send(event, to: requester) }
    }

    /// To every chat page, and to the page that asked (also a Zeus Editor page).
    private func broadcast(_ event: [String: Any]) {
        var pages = app?.chatPages ?? []
        if let requester, !pages.contains(where: { $0 === requester }) { pages.append(requester) }
        pages.forEach { Self.send(event, to: $0) }
    }

    private static func send(_ event: [String: Any], to webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.zeusApp?.onUpdateEvent?.(\(json)); void 0")
    }
}
