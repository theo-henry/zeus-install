import Foundation

// Unit test of TabLifecycle (app/Sources/Zeus/TabLifecycle.swift): the phases of a chat tab, the legal transitions, the
// epoch that stops a callback of an earlier phase, the close request, Settings…, and the mode switch. No WebKit.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  PASS \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias Phase = TabLifecycle.Phase
typealias Event = TabLifecycle.Event
typealias Page = TabLifecycle.Page

let url = URL(string: "http://127.0.0.1:4100/chat/100#k=token")!
let other = URL(string: "http://127.0.0.1:4200/chat/200#k=token")!
let page = Page(url: url)
let loaded = Page(url: url, loaded: true)

/// A lifecycle that the legal events brought to `phase`.
func lifecycle(_ phase: Phase) -> TabLifecycle {
    var tab = TabLifecycle()
    let path: [Event]
    switch phase {
    case .starting: path = []
    case .resuming: path = [.chatURL(url, resume: true)]
    case .loading(let page): path = [.chatURL(url, resume: false)] + (page.loaded ? [.pageLoaded(url)] : [])
    case .handingOver(let page): path = [.chatURL(url, resume: false), .handOverStarts] + (page.loaded ? [.pageLoaded(url)] : [])
    case .showing(let page): path = [.chatURL(url, resume: false), .handOverStarts, .handOverEnds] + (page.loaded ? [.pageLoaded(url)] : [])
    case .failed: path = [.startFailed]
    case .signingIn: path = [.startFailed, .signInStarts]
    case .closed: path = [.close]
    }
    for event in path { precondition(tab.apply(event), "setup of \(phase.name): \(event) refused") }
    precondition(tab.phase == phase, "setup of \(phase.name)")
    return tab
}

let allPhases: [Phase] = [.starting, .resuming(url), .loading(page), .loading(loaded), .handingOver(page), .handingOver(loaded),
                          .showing(page), .showing(loaded), .failed, .signingIn, .closed]
let allEvents: [Event] = [.chatURL(url, resume: false), .chatURL(url, resume: true), .resumed, .pageLoaded(url), .pageLoaded(other),
                          .handOverStarts, .handOverEnds, .startFailed, .signInStarts, .signInEnds, .restart, .close]

print("Legal transitions")
typealias Row = (String, Phase, Event, Phase)
let legal: [Row] = [
    ("starting: the chat URL comes, the page loads", .starting, .chatURL(url, resume: false), .loading(page)),
    ("starting: the chat URL comes with a kept session, it resumes first", .starting, .chatURL(url, resume: true), .resuming(url)),
    ("starting: zeus stops before the chat page", .starting, .startFailed, .failed),
    ("resuming: the session resumed, the page loads", .resuming(url), .resumed, .loading(page)),
    ("loading: the page has loaded", .loading(page), .pageLoaded(url), .loading(loaded)),
    ("loading, loaded: the page loads again (a reload before the hand-over)", .loading(loaded), .pageLoaded(url), .loading(loaded)),
    ("handingOver, loaded: the page loads again", .handingOver(loaded), .pageLoaded(url), .handingOver(loaded)),
    ("loading: the hand-over starts (chat-ready, the page-load timer, or a page that failed)", .loading(page), .handOverStarts,
     .handingOver(page)),
    ("loading, loaded: the hand-over starts", .loading(loaded), .handOverStarts, .handingOver(loaded)),
    ("handingOver: the page loads during the hand-over (chat-ready came first)", .handingOver(page), .pageLoaded(url),
     .handingOver(loaded)),
    ("handingOver: the loading screen leaves", .handingOver(loaded), .handOverEnds, .showing(loaded)),
    ("handingOver: a page that failed to load leaves the loading screen too", .handingOver(page), .handOverEnds, .showing(page)),
    ("showing: a reload of the page has loaded", .showing(loaded), .pageLoaded(url), .showing(loaded)),
    ("showing: the page of a failed load loads later", .showing(page), .pageLoaded(url), .showing(loaded)),
    ("failed: the Google sign-in starts", .failed, .signInStarts, .signingIn),
    ("signingIn: the sign-in ends", .signingIn, .signInEnds, .failed),
]
var legalPairs: [(Phase, Event)] = []
for (name, phase, event, expected) in legal {
    check(name, TabLifecycle.next(phase, event) == expected)
    legalPairs.append((phase, event))
}
for phase in allPhases where phase != .closed {
    check("\(phase.name)\(phase.page?.loaded == true ? " (loaded)" : ""): a mode switch restarts the tab", TabLifecycle.next(phase, .restart) == .starting)
    check("\(phase.name)\(phase.page?.loaded == true ? " (loaded)" : ""): the tab closes", TabLifecycle.next(phase, .close) == .closed)
    legalPairs.append((phase, .restart))
    legalPairs.append((phase, .close))
}

print("Each other transition is refused")
var refused = 0
var wronglyLegal: [String] = []
for phase in allPhases {
    for event in allEvents where !legalPairs.contains(where: { $0.0 == phase && $0.1 == event }) {
        if let next = TabLifecycle.next(phase, event) { wronglyLegal.append("\(phase.name) + \(event) -> \(next.name)") } else { refused += 1 }
    }
}
check("\(refused) other pairs of a phase and an event are refused\(wronglyLegal.isEmpty ? "" : ": " + wronglyLegal.joined(separator: ", "))",
      wronglyLegal.isEmpty && refused > 0)
check("refused: a second chat URL while the page loads", TabLifecycle.next(.loading(page), .chatURL(other, resume: false)) == nil)
check("refused: the page of another URL (the old page after a switch)", TabLifecycle.next(.loading(page), .pageLoaded(other)) == nil)
check("refused: a second hand-over (the timer and chat-ready both fire)", TabLifecycle.next(.handingOver(page), .handOverStarts) == nil)
check("refused: a hand-over before the chat page exists", TabLifecycle.next(.starting, .handOverStarts) == nil)
check("refused: a hand-over while the session resumes", TabLifecycle.next(.resuming(url), .handOverStarts) == nil)
check("refused: a hand-over after a failed start (no loading screen)", TabLifecycle.next(.failed, .handOverStarts) == nil)
check("refused: a hand-over in a tab that shows its chat (a reload sends chat-ready again)",
      TabLifecycle.next(.showing(loaded), .handOverStarts) == nil)
check("refused: a sign-in while the chat runs", TabLifecycle.next(.showing(loaded), .signInStarts) == nil)
check("refused: a second sign-in while one runs", TabLifecycle.next(.signingIn, .signInStarts) == nil)
check("refused: a failed start after the chat URL (zeus then ends, it does not fail)", TabLifecycle.next(.loading(page), .startFailed) == nil)
check("refused: anything after the close", allEvents.allSatisfy { TabLifecycle.next(.closed, $0) == nil })

print("The epoch")
var tab = TabLifecycle()
var epochs = [tab.epoch]
for event: Event in [.chatURL(url, resume: false), .handOverStarts, .handOverEnds] {
    tab.apply(event)
    epochs.append(tab.epoch)
}
check("each phase change increases the epoch", zip(epochs, epochs.dropFirst()).allSatisfy { $0 < $1 })
let before = tab.epoch
tab.apply(.pageLoaded(url))
check("a page load in the same phase keeps the epoch (a reload does not stop the callbacks of the phase)", tab.epoch == before)
check("a refused event changes nothing", { var copy = tab; return !copy.apply(.handOverStarts) && copy == tab }())

// The defect of the audit (SM-11): the page-load timer of the first chat (2.5 s) had no epoch, so after a mode switch it
// could start the hand-over of the new session's loading screen before the new chat page had loaded.
tab = lifecycle(.loading(loaded))
let timerEpoch = tab.epoch
tab.apply(.restart)
tab.apply(.chatURL(other, resume: false))
check("a page-load timer of the old session can not act after a mode switch", !tab.isCurrent(timerEpoch))
check("the new session's own page-load timer can act", tab.isCurrent(tab.epoch))
tab = lifecycle(.handingOver(loaded))
let globeEpoch = tab.epoch
tab.apply(.restart)
check("a globe timer of the old session can not take the new loading screen", !tab.isCurrent(globeEpoch))
tab = lifecycle(.resuming(url))
let resumeEpoch = tab.epoch
tab.apply(.restart)
check("the end of a resume can not type the old terminal text into the new session", !tab.isCurrent(resumeEpoch))
tab = lifecycle(.signingIn)
let signInEpoch = tab.epoch
tab.apply(.restart)
check("the end of a sign-in that the switch stopped can not show its note in the new session", !tab.isCurrent(signInEpoch))
tab = lifecycle(.loading(page))
let closeEpoch = tab.epoch
tab.apply(.close)
check("no callback acts on a closed tab", !tab.isCurrent(closeEpoch) && !tab.isCurrent(tab.epoch))

print("What the phase tells a close, a quit, a mode switch, and an update")
// One answer for every reader (the defect of the audit: a tab without a page was safe to close for a close, a quit, and
// a mode switch, but busy for an update).
check("starting: zeus starts, not safe to close", lifecycle(.starting).activity == .starting)
check("resuming: the kept session resumes, not safe to close", lifecycle(.resuming(url)).activity == .starting)
check("loading, the page has not loaded: no chat page to ask yet, not safe to close", lifecycle(.loading(page)).activity == .starting)
for phase: Phase in [.loading(loaded), .handingOver(page), .handingOver(loaded), .showing(page), .showing(loaded)] {
    check("\(phase.name)\(phase.page?.loaded == true ? " (loaded)" : ""): ask the chat page", lifecycle(phase).activity == .chat)
}
for phase: Phase in [.failed, .signingIn, .closed] {
    check("\(phase.name): no session", lifecycle(phase).activity == .noSession)
}
check("the start status shows only while zeus starts", allPhases.filter { lifecycle($0).showsStartStatus } == [.starting])

print("Settings…")
tab = lifecycle(.starting)
check("Settings… before the page waits", !tab.canOpenSettings && tab.wantSettings() && tab.settingsWanted)
tab.apply(.chatURL(url, resume: false))
check("it still waits while the page loads", !tab.takeSettingsWish() && tab.settingsWanted)
tab.apply(.pageLoaded(url))
check("the page has loaded: the settings open once", tab.takeSettingsWish() && !tab.takeSettingsWish())
tab = lifecycle(.loading(page))
tab.wantSettings()
tab.apply(.restart)
check("a mode switch drops the wish of the old page", !tab.settingsWanted)
tab = lifecycle(.starting)
tab.wantSettings()
tab.apply(.startFailed)
check("a failed start drops the wish", !tab.settingsWanted)
check("a closed tab takes no wish", { var closed = lifecycle(.closed); return !closed.wantSettings() && !closed.settingsWanted }())

print("Mode switch")
tab = lifecycle(.showing(loaded))
check("a switch starts", tab.beginSwitch() && tab.isSwitching)
check("a second switch of the same tab is refused", !tab.beginSwitch())
tab.apply(.restart)
check("the switch goes on across the restart of the tab", tab.isSwitching)
tab.endSwitch()
check("then it ends", !tab.isSwitching && tab.beginSwitch())
check("a closed tab does not switch", { var closed = lifecycle(.closed); return !closed.beginSwitch() }())

print("Close request")
let start = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
tab = lifecycle(.showing(loaded))
let first = tab.requestClose(now: start)
check("a close request starts: checking", first != nil && tab.close == .checking(id: first!, since: start))
check("a second request while one runs is refused", tab.requestClose(now: at(0.1)) == nil)
check("a draft defers the close", tab.closeAnswer(id: first!, reason: "composer-draft", now: at(0.1)) == .show("composer-draft")
      && tab.close == .deferred(id: first!, reason: "composer-draft", since: start))
check("the same reason again keeps the banner", tab.closeAnswer(id: first!, reason: "composer-draft", now: at(0.6)) == .wait)
check("a new reason shows", tab.closeAnswer(id: first!, reason: "busy", now: at(1.1)) == .show("busy") && tab.close.reason == "busy")
check("the request goes on across a phase change", { var copy = tab; copy.apply(.pageLoaded(url)); return copy.closeRuns(first!) }())
check("safe: the tab closes", tab.closeAnswer(id: first!, reason: nil, now: at(1.6)) == .close)
tab.cancelClose()
check("a cancel ends the request", tab.close == .none && !tab.closeRuns(first!))
check("an answer of the cancelled request is stale", tab.closeAnswer(id: first!, reason: nil, now: at(2)) == .stale)
let second = tab.requestClose(now: at(3))
check("a new request has a new number", second != nil && second != first)
check("an answer of the old request does not act on the new one",
      tab.closeAnswer(id: first!, reason: "busy", now: at(3.1)) == .stale && tab.close == .checking(id: second!, since: at(3)))
check("a chat that cannot answer: the banner waits for the limit", tab.closeAnswer(id: second!, reason: "unavailable", now: at(4)) == .wait
      && tab.close == .checking(id: second!, since: at(3)))
check("after the limit it offers Close anyway",
      tab.closeAnswer(id: second!, reason: "unavailable", now: at(3 + TabLifecycle.closeCheckLimit)) == .show("unavailable"))
tab.apply(.restart)
check("a mode switch ends the close request", tab.close == .none && tab.closeAnswer(id: second!, reason: nil, now: at(7)) == .stale)
tab = lifecycle(.starting)
let failing = tab.requestClose(now: start)
tab.apply(.startFailed)
check("a failed start keeps the close request: its next check closes the tab",
      failing != nil && tab.closeRuns(failing!) && tab.closeAnswer(id: failing!, reason: nil, now: at(1)) == .close)
tab.apply(.close)
check("the close ends the request", tab.close == .none)
check("a closed tab takes no close request", tab.requestClose(now: at(2)) == nil)

if failures == 0 { print("All checks passed."); exit(0) }
print("\(failures) checks failed.")
exit(1)
