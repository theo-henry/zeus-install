import Foundation

/// The phase of the app and the phase of its quit, in one value. `AppDelegate` owns the one copy; `AppUpdate` changes
/// the update steps through it. Each change is an event, and an event that is not legal in the current phase changes
/// nothing and returns `false` (or an `ignored` answer), so that a late callback cannot put the app in a wrong state.
///
/// `Question` is the window of the quit question (`NSWindow` in the app; a test type in app/test/lifecycle).
///
/// App phase:
///
/// | From                     | Event                | To                       |
/// |--------------------------|----------------------|--------------------------|
/// | launching                | launchUpdateStarted  | launchUpdate             |
/// | launching, launchUpdate  | zeusStarted          | running(nil)             |
/// | running(nil)             | updateCheckStarted   | running(checking)        |
/// | running(checking)        | updateFound          | running(downloading)     |
/// | running(checking, downloading) | updateNone     | running(nil)             |
/// | running(checking, downloading) | updateReady    | running(waiting)         |
/// | running(waiting)         | installStarted       | running(installing)      |
/// | running(installing)      | tabsBusyAgain        | running(waiting)         |
/// | running(installing)      | installFailed        | running(nil)             |
///
/// An update that relaunches the app ends in `launchUpdate` or `running(installing)`: the app quits there.
///
/// Quit phase:
///
/// | From                         | Event                                   | To            |
/// |------------------------------|-----------------------------------------|---------------|
/// | idle                         | terminate (user, sessions run)          | checkingTabs  |
/// | idle, checkingTabs, asking   | terminate (macOS, sessions run)         | stopping      |
/// | checkingTabs                 | tabsChecked (no unsafe tab or window)   | approved      |
/// | checkingTabs                 | tabsChecked (unsafe tab in a window)    | asking        |
/// | asking                       | answered (Quit Anyway)                  | approved      |
/// | asking                       | answered (Cancel)                       | idle          |
/// | asking                       | questionWindowClosed                    | idle          |
/// | idle, checkingTabs, asking   | approve (power off, test action)        | approved      |
/// | approved                     | terminate (sessions run)                | stopping      |
/// | any but lockingVault         | terminate (no session, EU vault mounted)| lockingVault  |
///
/// `stopping` and `lockingVault` end only when the app quits.
struct AppLifecycle<Question: AnyObject> {
    private(set) var app = AppPhase.launching
    private(set) var quit = QuitPhase<Question>.idle

    // MARK: App phase

    /// Applies an event of the app phase. Returns false, and changes nothing, when the event is not legal now.
    @discardableResult
    mutating func apply(_ event: AppEvent) -> Bool {
        guard let next = app.next(event) else { return false }
        app = next
        return true
    }

    // MARK: Quit phase

    /// What `applicationShouldTerminate` does.
    enum TerminateDecision: Equatable {
        /// `.terminateNow`.
        case now
        /// `.terminateLater`, then lock the EU vault and reply.
        case lockVault
        /// `.terminateLater`, then end the quit question (when one shows), stop every session, lock the vault, and reply.
        case stopSessions(endQuestion: Question?)
        /// `.terminateLater`: a stop or a vault lock that runs replies.
        case wait
        /// `.terminateCancel`, then check the tabs (`tabsChecked` gives the result).
        case checkTabs
        /// `.terminateCancel`: the tab check or the quit question still runs.
        case cancel

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.now, .now), (.lockVault, .lockVault), (.wait, .wait), (.checkTabs, .checkTabs), (.cancel, .cancel):
                return true
            case let (.stopSessions(left), .stopSessions(right)):
                return left === right
            default:
                return false
            }
        }
    }

    /// A terminate request of AppKit. `byMacOS`: macOS logs out, restarts, or shuts down (the quit asks nothing).
    mutating func terminate(sessionsAlive: Bool, vaultMounted: Bool, byMacOS: Bool) -> TerminateDecision {
        guard sessionsAlive else {
            // The EU vault locks when the app quits (EUVault).
            if quit == .lockingVault { return .wait }
            guard vaultMounted else { return .now }
            quit = .lockingVault
            return .lockVault
        }
        switch quit {
        case .stopping, .lockingVault:
            return .wait
        case .approved:
            quit = .stopping
            return .stopSessions(endQuestion: nil)
        case .idle where byMacOS, .checkingTabs where byMacOS:
            quit = .stopping
            return .stopSessions(endQuestion: nil)
        case let .asking(window) where byMacOS:
            quit = .stopping
            return .stopSessions(endQuestion: window)
        case .idle:
            quit = .checkingTabs
            return .checkTabs
        case .checkingTabs, .asking:
            return .cancel
        }
    }

    /// The answer of a quit step.
    enum QuitStep: Equatable {
        /// The quit is approved: end this question (when one shows), then terminate again.
        case approved(endQuestion: Question?)
        /// Show the quit question on this window.
        case ask(Question)
        /// The quit ends: nothing more to do (a question that still shows ends with it).
        case cancelled
        /// The event is late or not legal now: do nothing.
        case ignored

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.cancelled, .cancelled), (.ignored, .ignored):
                return true
            case let (.approved(left), .approved(right)):
                return left === right
            case let (.ask(left), .ask(right)):
                return left === right
            default:
                return false
            }
        }
    }

    /// The tab check of a user quit ended. `unsafeWindow`: the window of the first tab that is not safe to close, or nil
    /// when every tab is safe (or that tab has no window).
    mutating func tabsChecked(unsafeWindow: Question?) -> QuitStep {
        guard quit == .checkingTabs else { return .ignored }
        guard let window = unsafeWindow else {
            quit = .approved
            return .approved(endQuestion: nil)
        }
        quit = .asking(window)
        return .ask(window)
    }

    /// The user answered the quit question on this window.
    mutating func answered(quitAnyway: Bool, on window: Question) -> QuitStep {
        guard case let .asking(asked) = quit, asked === window else { return .ignored }
        if quitAnyway {
            quit = .approved
            return .approved(endQuestion: nil)
        }
        quit = .idle
        return .cancelled
    }

    /// The window of the quit question closes (its last tab closed). AppKit does not call the completion handler of a
    /// sheet whose window closes, and keeps the sheet attached, so the quit ends here.
    mutating func questionWindowClosed(_ window: Question) -> QuitStep {
        guard case let .asking(asked) = quit, asked === window else { return .ignored }
        quit = .idle
        return .cancelled
    }

    /// Approves the quit without the question: macOS warns that it powers off while the user quit checks or asks, or
    /// a test action quits.
    mutating func approve() -> QuitStep {
        switch quit {
        case .idle, .checkingTabs:
            quit = .approved
            return .approved(endQuestion: nil)
        case let .asking(window):
            quit = .approved
            return .approved(endQuestion: window)
        case .approved, .stopping, .lockingVault:
            return .ignored
        }
    }
}

/// What runs in the app.
enum AppPhase: Equatable, CustomStringConvertible {
    /// From the launch to the start of Zeus: the app confirms a pending update or moves itself to Applications.
    case launching
    /// The update check at launch runs (and installs an update): only its loading screen shows.
    case launchUpdate
    /// Zeus runs. `update`: the step of the update from the settings of a page (`AppUpdate`), nil when none runs.
    case running(update: UpdateStep?)

    /// No Zeus session starts, and only the loading screen of the update shows.
    var blocksSessions: Bool { self == .launchUpdate || self == .running(update: .installing) }

    /// The step of the update from the settings of a page, nil when none runs.
    var updateStep: UpdateStep? {
        if case let .running(step) = self { return step }
        return nil
    }

    var description: String {
        switch self {
        case .launching: return "launching"
        case .launchUpdate: return "launch-update"
        case let .running(step): return step.map { "running/\($0.rawValue)" } ?? "running"
        }
    }

    fileprivate func next(_ event: AppEvent) -> AppPhase? {
        switch (self, event) {
        case (.launching, .launchUpdateStarted): return .launchUpdate
        case (.launching, .zeusStarted), (.launchUpdate, .zeusStarted): return .running(update: nil)
        case (.running(nil), .updateCheckStarted): return .running(update: .checking)
        case (.running(.checking), .updateFound): return .running(update: .downloading)
        case (.running(.checking), .updateNone), (.running(.downloading), .updateNone): return .running(update: nil)
        case (.running(.checking), .updateReady), (.running(.downloading), .updateReady): return .running(update: .waiting)
        case (.running(.waiting), .installStarted): return .running(update: .installing)
        case (.running(.installing), .tabsBusyAgain): return .running(update: .waiting)
        case (.running(.installing), .installFailed): return .running(update: nil)
        default: return nil
        }
    }
}

/// The steps of an update from the settings of a page. The raw value is the `state` of `app-update-progress`.
enum UpdateStep: String {
    case checking, downloading, waiting, installing
}

enum AppEvent: String {
    /// The update check at launch starts.
    case launchUpdateStarted
    /// Zeus starts: the setup, the restored tabs, or a first tab can open.
    case zeusStarted
    /// "Update now" in the settings of a page.
    case updateCheckStarted
    /// The new release is found; it downloads.
    case updateFound
    /// No update: up to date, or the check or download failed.
    case updateNone
    /// The update is downloaded and checked; it waits until no tab works.
    case updateReady
    /// No tab works: the tabs are kept and the sessions end.
    case installStarted
    /// A tab started to work before the windows were hidden: the update waits again.
    case tabsBusyAgain
    /// The new copy did not start: this copy runs on and opens the same tabs again.
    case installFailed
}

/// The quit of the app.
enum QuitPhase<Question: AnyObject>: Equatable, CustomStringConvertible {
    /// No quit runs.
    case idle
    /// A user quit asks each tab if it is safe to close.
    case checkingTabs
    /// The quit question shows as a sheet on this window.
    case asking(Question)
    /// The quit is approved: the next terminate stops every session.
    case approved
    /// The sessions stop; the EU vault locks after them, and then the app quits.
    case stopping
    /// No session runs, and the quit waits for the EU vault to lock.
    case lockingVault

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checkingTabs, .checkingTabs), (.approved, .approved), (.stopping, .stopping),
             (.lockingVault, .lockingVault):
            return true
        case let (.asking(left), .asking(right)):
            return left === right
        default:
            return false
        }
    }

    /// A user quit checks the tabs or asks: a power-off warning approves it.
    var isUserQuit: Bool {
        switch self {
        case .checkingTabs, .asking: return true
        case .idle, .approved, .stopping, .lockingVault: return false
        }
    }

    var description: String {
        switch self {
        case .idle: return "idle"
        case .checkingTabs: return "checking-tabs"
        case .asking: return "asking"
        case .approved: return "approved"
        case .stopping: return "stopping"
        case .lockingVault: return "locking-vault"
        }
    }
}
