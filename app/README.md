# Zeus app

A small native macOS app (Swift, AppKit, and SwiftUI) that starts Zeus without Terminal.

- **Setup window.** The first start runs the bundled `install.sh` in app mode in a hidden terminal.
  `install.sh --check` ticks the steps that are already done. The window shows the installer output,
  an Accept button for the Anaconda license, the GitHub one-time code, a link for the Claude login, and a field for any other answer.
- **Chat window.** A click on the app runs `~/.local/bin/zeus --no-open` in `~/Code/zeus` in a hidden terminal,
  reads the `Zeus chat: <url>` line, and shows that page. If `zeus` stops before the page opens, the window shows its output
  with **Try again** and **Run the Zeus Setup**.
- **No hidden sessions.** Closing a chat window sends SIGTERM to its `zeus`, and quitting the app stops every session.
  If the app crashes, its hidden terminal closes and `zeus` stops as after a closed Terminal window.
- **Links.** Pages on 127.0.0.1 stay in the app (pop-ups open in a new app window). Other links open in the default browser.

## Build

Needs only the Xcode Command Line Tools (Swift 5.9 or later). Full Xcode is not necessary.

```bash
app/build.sh 0.1.0        # app/build/Zeus.app and app/build/Zeus.zip, for Apple silicon and Intel
app/dev-bundle.sh         # app/build/Zeus-dev.app, a quick debug build for this Mac
```

The app has an ad-hoc signature, not an Apple Developer ID.
Publish `app/build/Zeus.zip` as the `Zeus.zip` asset of a GitHub release of this repo;
`install-app.sh` and step 12 of `install.sh` download `releases/latest/download/Zeus.zip`.

## Debug

`ZEUS_APP_TRACE=/path/to/file` writes setup events, session states, and page loads to that file.
`ZEUS_APP_INSTALLER=/path/to/install.sh` replaces the bundled installer.
Start the app's binary directly to pass them, for example
`ZEUS_APP_TRACE=/tmp/zeus.log app/build/Zeus-dev.app/Contents/MacOS/Zeus`.
The web pages can be inspected with Safari's Develop menu.
