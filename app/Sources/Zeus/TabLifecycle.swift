import Foundation

/// The lifecycle of one chat tab (`ChatTab`): the phase of the tab's chat, the close that the user asked for, and the
/// mode switch that the app runs on the tab. The tab owns the only value of it, and each reader asks it: the loading
/// screen, the hand-over, Settings…, the close check, the quit and update checks, the mode switch, and the tab snapshot.
///
/// Phases and transitions (each other transition is refused):
///
///     starting ──chatURL──▶ loading(page) ──handOverStarts──▶ handingOver(page) ──handOverEnds──▶ showing(page)
///        │  └──chatURL, a kept session to resume──▶ resuming(url) ──resumed──▶ loading(page)
///        └──startFailed──▶ failed ──signInStarts──▶ signingIn ──signInEnds──▶ failed
///     each phase except closed ──restart (a mode switch: a new session in the tab)──▶ starting
///     each phase except closed ──close──▶ closed
///     loading, handingOver, showing ──pageLoaded(url of the page)──▶ the same phase, with the page loaded
///
/// `epoch` increases with each phase change. An async callback (a timer, a script answer, the end of a resume or of a
/// sign-in) keeps the epoch of the moment it was made and acts only while the epoch is the same. So a callback of an
/// earlier phase, or of the session before a mode switch, can not act on the tab.
///
/// The close request has its own number: a close check goes on across a phase change, such as the end of a hand-over,
/// and ends only with a cancel, a restart, or the close.
///
/// It is pure Foundation code (no AppKit, no WebKit), so that a unit test compiles it alone (app/test/tab-lifecycle).
struct TabLifecycle: Equatable {
    /// The chat page of the session, and whether it has loaded.
    struct Page: Equatable {
        var url: URL
        var loaded = false
    }

    enum Phase: Equatable {
        /// `zeus` starts. The loading screen shows.
        case starting
        /// The session runs, and Claude Code resumes the kept session of the tab (an update from the settings) before
        /// the chat page loads. The loading screen shows.
        case resuming(URL)
        /// The chat page loads behind the loading screen.
        case loading(Page)
        /// The loading screen goes away: at once, or with the globe that moves to the chat page.
        case handingOver(Page)
        /// The chat page shows.
        case showing(Page)
        /// `zeus` stopped before the chat page opened. The tab shows the status page.
        case failed
        /// EU mode: the Google sign-in runs in the terminal panel after a failed start. The status page stays.
        case signingIn
        /// The tab closed and its session ended.
        case closed

        var name: String {
            switch self {
            case .starting: return "starting"
            case .resuming: return "resuming"
            case .loading: return "loading"
            case .handingOver: return "handingOver"
            case .showing: return "showing"
            case .failed: return "failed"
            case .signingIn: return "signingIn"
            case .closed: return "closed"
            }
        }

        /// The chat page, in the phases that have one.
        var page: Page? {
            switch self {
            case let .loading(page), let .handingOver(page), let .showing(page): return page
            default: return nil
            }
        }
    }

    enum Event: Equatable {
        /// The session gave its chat page. `resume`: the tab has a kept session to resume first.
        case chatURL(URL, resume: Bool)
        /// The kept session resumed (or could not): the chat page loads.
        case resumed
        /// The chat page with this URL has loaded.
        case pageLoaded(URL)
        case handOverStarts
        case handOverEnds
        case startFailed
        case signInStarts
        case signInEnds
        /// A mode switch gives the tab a new session.
        case restart
        case close
    }

    /// What the phase alone tells a close, a quit, a mode switch, and an update, before they ask the chat page.
    /// All four use the same answer: a tab where Zeus starts is not safe to close ("starting", the reason that the chat
    /// page itself gives while Claude Code starts). A start can update the Zeus checkout or resume a kept session, and
    /// a resuming tab still has the unsent text that the update kept; ending it then can leave that work half done.
    enum Activity: Equatable {
        /// No session runs: the start failed, or the tab closed. Safe to close.
        case noSession
        /// `zeus` starts, resumes the kept session, or its chat page has not loaded yet: there is no chat page to ask.
        /// Not safe to close: "starting".
        case starting
        /// The chat page knows if Zeus works or has unsent text: ask it.
        case chat
    }

    /// A close that the user asked for, while the app asks the chat if the tab is safe to close.
    enum CloseRequest: Equatable {
        case none
        /// The app asks the chat page, again every 0.5 s, until it is safe to close.
        case checking(id: Int, since: Date)
        /// The chat said why the tab is not safe to close: the banner shows it and offers Close anyway. The app goes on
        /// asking, and closes the tab when the chat says that it is safe.
        case deferred(id: Int, reason: String, since: Date)

        var id: Int? {
            switch self {
            case .none: return nil
            case let .checking(id, _), let .deferred(id, _, _): return id
            }
        }

        var reason: String? {
            if case let .deferred(_, reason, _) = self { return reason }
            return nil
        }
    }

    /// The next step of a close request after an answer of the chat.
    enum CloseStep: Equatable {
        /// The answer is of a close request that ended (cancelled, restarted, closed).
        case stale
        /// Safe to close: the tab closes.
        case close
        /// Not safe yet, and the banner stays as it is: ask again.
        case wait
        /// Not safe, for this new reason: the banner shows it and offers Close anyway; ask again.
        case show(String)
    }

    /// How long the app waits for a chat that cannot answer the close check before it offers to close anyway.
    static let closeCheckLimit: TimeInterval = 3

    private(set) var phase: Phase = .starting
    private(set) var epoch = 0
    private(set) var close = CloseRequest.none
    /// Settings… came before the chat page had loaded: the settings open when it has loaded.
    private(set) var settingsWanted = false
    /// The app switches the mode of the tab now (from the question to the new session): no other switch starts.
    private(set) var isSwitching = false
    private var lastCloseID = 0

    // MARK: Transitions

    /// The phase after `event`, or nil when the transition is not legal.
    static func next(_ phase: Phase, _ event: Event) -> Phase? {
        switch (phase, event) {
        case let (.starting, .chatURL(url, resume)):
            return resume ? .resuming(url) : .loading(Page(url: url))
        case let (.resuming(url), .resumed):
            return .loading(Page(url: url))
        case let (.loading(page), .pageLoaded(url)) where page.url == url:
            return .loading(Page(url: url, loaded: true))
        case let (.handingOver(page), .pageLoaded(url)) where page.url == url:
            return .handingOver(Page(url: url, loaded: true))
        case let (.showing(page), .pageLoaded(url)) where page.url == url:
            return .showing(Page(url: url, loaded: true))
        case let (.loading(page), .handOverStarts):
            return .handingOver(page)
        case let (.handingOver(page), .handOverEnds):
            return .showing(page)
        case (.starting, .startFailed):
            return .failed
        case (.failed, .signInStarts):
            return .signingIn
        case (.signingIn, .signInEnds):
            return .failed
        case (.closed, .restart), (.closed, .close):
            return nil
        case (_, .restart):
            return .starting
        case (_, .close):
            return .closed
        default:
            return nil
        }
    }

    /// Applies `event`. Returns false, and changes nothing, when the transition is not legal.
    @discardableResult
    mutating func apply(_ event: Event) -> Bool {
        guard let next = Self.next(phase, event) else { return false }
        if next.name != phase.name { epoch += 1 }
        phase = next
        switch event {
        case .restart, .close:
            // A close request of the old session ends: the tab stays open with the new session, or it closed.
            close = .none
            settingsWanted = false
        case .startFailed:
            // No chat page comes. A close request goes on: its next check finds no session and closes the tab.
            settingsWanted = false
        default:
            break
        }
        return true
    }

    /// A callback made at `epoch` may act on the tab.
    func isCurrent(_ epoch: Int) -> Bool { epoch == self.epoch && phase != .closed }

    // MARK: Readers

    var page: Page? { phase.page }

    var activity: Activity {
        switch phase {
        case .starting, .resuming: return .starting
        case let .loading(page): return page.loaded ? .chat : .starting
        case .handingOver, .showing: return .chat
        case .failed, .signingIn, .closed: return .noSession
        }
    }

    /// The loading screen shows the start status ("Starting Zeus…", "Checking for updates…").
    var showsStartStatus: Bool { phase == .starting }

    /// The chat page can open its settings now (it has loaded once; a reload in progress is the caller's check).
    var canOpenSettings: Bool { page?.loaded == true }

    // MARK: Settings…

    /// Settings… came before the chat page could open them. Returns false for a closed tab.
    @discardableResult
    mutating func wantSettings() -> Bool {
        guard phase != .closed else { return false }
        settingsWanted = true
        return true
    }

    /// The chat page has loaded: true once when Settings… waited for it.
    mutating func takeSettingsWish() -> Bool {
        guard settingsWanted, canOpenSettings else { return false }
        settingsWanted = false
        return true
    }

    // MARK: Mode switch

    /// Returns false when the tab closed or a switch already runs.
    mutating func beginSwitch() -> Bool {
        guard phase != .closed, !isSwitching else { return false }
        isSwitching = true
        return true
    }

    mutating func endSwitch() { isSwitching = false }

    // MARK: Close request

    /// Starts a close request. Returns its number, or nil when the tab closed or a close request already runs.
    mutating func requestClose(now: Date) -> Int? {
        guard phase != .closed, close == .none else { return nil }
        lastCloseID += 1
        close = .checking(id: lastCloseID, since: now)
        return lastCloseID
    }

    /// The close request with this number still runs.
    func closeRuns(_ id: Int) -> Bool { phase != .closed && close.id == id }

    /// The chat answered close request `id`: nil when it is safe to close, else the reason. A chat that cannot answer
    /// ("unavailable") gets `closeCheckLimit` seconds after the request before the banner offers Close anyway.
    mutating func closeAnswer(id: Int, reason: String?, now: Date) -> CloseStep {
        guard closeRuns(id) else { return .stale }
        guard let reason else { return .close }
        let since: Date
        switch close {
        case let .checking(_, start), let .deferred(_, _, start): since = start
        case .none: return .stale
        }
        let waiting = reason == "unavailable" && now.timeIntervalSince(since) < Self.closeCheckLimit
        guard !waiting, reason != close.reason else { return .wait }
        close = .deferred(id: id, reason: reason, since: since)
        return .show(reason)
    }

    /// Ends the close request. Returns false when none ran.
    @discardableResult
    mutating func cancelClose() -> Bool {
        guard close != .none else { return false }
        close = .none
        return true
    }
}
