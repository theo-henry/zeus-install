# Zeus app

A small native macOS app (Swift, AppKit, and SwiftUI) that starts Zeus without Terminal.

- **Applications folder.** At the first start, an app that runs from another folder (Downloads, a build folder)
  copies itself to `/Applications` (`~/Applications` without administrator rights), opens the copy, and quits.
  A copy in Downloads goes to the Trash. Development builds, `ZEUS_APP_TRACE`, and `ZEUS_APP_NO_MOVE=1` turn this off.
- **Setup window.** The first start runs the bundled `install.sh` in app mode in a hidden terminal.
  `install.sh --check` ticks the steps that are already done. The window shows the installer output,
  an Accept button for the Anaconda license, the GitHub one-time code, a link for the Claude login, and a field for any other answer.
- **Chat window.** A click on the app runs `~/.local/bin/zeus --no-open` in `~/Code/zeus` in a hidden terminal,
  reads the `Zeus chat: <url>` line, and shows that page. If `zeus` stops before the page opens, the window shows its output
  with **Try again** and **Run the Zeus Setup**.
- **Tabs.** Cmd+T opens a tab with its own `zeus` session and chat.
  Cmd+J shows or hides the live terminal of the tab, for login prompts, slash commands, or debugging.
- **Safe close.** Closing a tab asks the chat (`window.zeusApp.closeState()`) first.
  While Zeus works, or while the chat has unsent text, attachments, or a pending send, the tab stays open with a banner, and closes when the chat is safe.
  **Close anyway** closes the tab at once; **Cancel close** keeps the tab.
  When the chat cannot answer (for example an older Zeus Editor plugin), the app waits 3 s, then asks: **Close anyway** or **Cancel**.
  Then the app sends SIGTERM to its `zeus`; the chat stays in the history.
  In the app, the app owns closing: `zeus` runs with `ZEUS_APP=1`, so the editor does not close terminals when the page closes.
- **No hidden sessions.** Quitting the app stops every session.
  When tabs are not safe to close, one question lists them all: **Quit Anyway** or **Cancel**.
  When macOS logs out, restarts, or shuts down, the app asks nothing and closes an open quit question; without a question, the quit ends within 12 s.
  If the app crashes, its hidden terminal closes and `zeus` stops as after a closed Terminal window.
- **Theme.** The setup window, the loading screen, and the status pages use the Zeus chat theme.
  While `zeus` starts, the loading screen shows the Zeus globe with one line of status text, such as "Checking for updates…".
  When the chat page is ready, the globe moves to the place of the chat page's own globe while the chat comes in behind it.
  A chat page without a globe (an older Zeus Editor) gets a cross-fade.
  This hand-over plays only for the first chat after the app starts; later chats (Cmd+T, **Try again**) come in at once when their page is ready.
  The close banner and the terminal panel stay usable while the loading screen shows.
- **Links.** Pages on 127.0.0.1 stay in the app (pop-ups open in a new app window). Other links open in the default browser.

## Build

Needs only the Xcode Command Line Tools (Swift 5.9 or later). Full Xcode is not necessary.

```bash
app/build.sh 0.1.0        # app/build/Zeus.app and app/build/Zeus.zip, for Apple silicon and Intel
app/dev-bundle.sh         # app/build/Zeus-dev.app, a quick debug build for this Mac
```

The app has an ad-hoc signature, not an Apple Developer ID.
A release for other people needs a Developer ID Application signature with the hardened runtime, notarization (`xcrun notarytool submit --wait`), and a stapled ticket (`xcrun stapler staple`).
Publish `app/build/Zeus.zip` as the `Zeus.zip` asset of a GitHub release of this repo;
`install-app.sh` and step 12 of `install.sh` download `releases/latest/download/Zeus.zip`.

## Debug

`ZEUS_APP_TRACE=/path/to/file` writes setup events, session states, and page loads to that file.
`ZEUS_APP_INSTALLER=/path/to/install.sh` replaces the bundled installer.
`ZEUS_APP_PTY_CAPTURE=/path/to/folder` (debug builds) writes every byte of each session's PTY to `pty-<pid>.log` in that folder.
`ZEUS_APP_TEST_ID=<id>` (debug builds) makes the test actions reach only this app copy.
Start the app's binary directly to pass them, for example
`ZEUS_APP_TRACE=/tmp/zeus.log app/build/Zeus-dev.app/Contents/MacOS/Zeus`.
The web pages can be inspected with Safari's Develop menu.

## Test the PTY

```bash
app/test/pty/run.sh
```

It sends 1 MiB to a raw-mode terminal and checks that every byte arrives, that a resize reaches the terminal, and that the UI run loop stays responsive.

## Test on a simulated new Mac

```bash
app/test/sim/run.sh [screenshot-folder]
```

The test runs the app and the bundled installer with `HOME` set to an empty temporary folder, and with
simulated tools first on `PATH` (`app/test/sim/stubs` and `payload`): xcode-select, the Anaconda and Node.js
downloads, conda, gh, npm, claude, and a `zeus` that serves a simple chat page. Nothing is downloaded, and the
real home folder, Claude Code, GitHub login, and app settings are not used (the app settings are restored).
It presses the app's buttons through the debug test actions and checks the trace:

1. A new Mac: the check finds 12 steps to do; all 13 steps install, with the Anaconda license, the GitHub
   one-time code, and the Claude login answered in the app; Start Zeus opens the chat page from `~/Code/zeus`
   with `--no-open` and the globe hand-over; a close with unsent text waits and can be cancelled; closing the window stops `zeus` with SIGTERM;
   Cmd+T tabs start separate sessions and come in without the hand-over; Cmd+J shows the terminal and its input reaches that session;
   a close while Zeus works waits for the turn; closing one tab keeps the others; a chat that cannot answer the close check
   (older editor plugin) waits 3 s, then **Close anyway** closes it; **Close anyway** also stops a busy tab; quitting stops every session.
2. One tab has unsent text and one tab is busy: a logout that another app cancels changes nothing, a later quit asks about both tabs,
   and a logout while that question is open stops every session and quits within 12 s without an answer;
   the quit event of a logout while a quit still checks the tabs asks nothing, also after the check, and quits within 12 s.
3. No access to one private repo: step 5 fails, the setup stops, and nothing after step 5 is installed.

With a folder, it saves a screenshot of each state (only the test app's windows), a recording of the startup animation, and the traces. It needs Screen Recording
permission for the terminal only for the screenshots.
