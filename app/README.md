# Zeus app

A small native macOS app (Swift, AppKit, and SwiftUI) that starts Zeus without Terminal.

- **Applications folder.** At the first start, an app that runs from another folder (Downloads, a build folder)
  copies itself to `/Applications` (`~/Applications` without administrator rights), opens the copy, and quits.
  A copy in Downloads goes to the Trash. Development builds, `ZEUS_APP_TRACE`, and `ZEUS_APP_NO_MOVE=1` turn this off.
- **Updates.** At each start, before any chat window or Zeus session opens, the app asks the private zeus repo for the newest release with a tag `app-v<version>` (`gh api`, with the user's GitHub CLI login; the app holds no token).
  While it checks, the app shows the loading screen (the Zeus globe) with "Checking for updates…"; the check stops after 5 s, and the app then starts its current version.
  When that version is higher, the loading screen shows "Downloading Zeus X.Y.Z…", the app downloads `Zeus.zip` and `Zeus.zip.sha256` (`gh release download`), and checks the checksum, the zip, the bundle identifier, the version, and the signature.
  Then it swaps the new app into the place of the running app in one rename (`renamex_np` with `RENAME_SWAP`), opens the new copy, and waits up to 20 s for the new copy to confirm in `~/Library/Application Support/Zeus/update.json`.
  After the confirmation, it removes the old copy and quits; without it, it stops the new copy, swaps the old app back, and starts as before.
  For 2 minutes after a roll back, `update.json` marks the roll back: a new copy that macOS starts late (under a high load) quits at once and does not update again.
  Offline, without `gh`, without access, or with any error, the app starts its current version and shows nothing.
  Development versions (such as `0.0.0-dev`), a read-only app folder, and `ZEUS_APP_NO_UPDATE=1` turn the check off.
- **Update from the settings.** **Check for updates** and **Update now** in the settings of the chat and Zeus Editor pages ask the app about the app (`Sources/Zeus/AppUpdate.swift`).
  At document start, every Zeus page gets `window.zeusApp.update = {version: 1}`.
  A page posts `{type: "app-update-check"}` to `window.webkit.messageHandlers.zeusApp`; the app asks the zeus repo for its `app-v` releases (as at launch, but it waits up to 20 s)
  and answers in that page with `window.zeusApp.onUpdateEvent({type: "app-update", current, latest, notes, available, error?, message?})`.
  `latest` is the newest app release (or null), `notes` has the release notes of each release newer than `current` (or null), and `available` is true when the app can install `latest` now.
  `error` is `no-gh`, `unreachable` (no answer from GitHub, or no access), `no-release`, `development` (a development build), or `cannot-update` (a read-only app folder, or `ZEUS_APP_NO_UPDATE=1`), and `message` says it in words.
  A page posts `{type: "app-update-apply"}` for **Update now**. The app downloads and checks the newest release as at launch, while the user keeps working.
  Then it waits until Zeus works in no tab (a turn, a question or permission prompt in a turn, a message on its way, or a start).
  Then it shows the loading screen with "Installing Zeus X.Y.Z…" in the place of the front chat window and hides the chat windows, so that no message can start a turn.
  When a tab started to work just before, the chat windows come back and the update waits again.
  Otherwise it keeps each tab, ends every session, swaps the app, and opens the new copy.
  The new copy opens the same tabs in the same windows: each tab starts `zeus` again, restarts its Claude Code session with `--resume` through the control socket of the launch
  (`{op: "restart", resume: <session id>}`, zeus-editor `packages/launcher/control.js`), and then shows the chat.
  The tab keeps its project, its name, its open terminal, the unsent text of the message box (`#zeus-message`), and the unsent text of the terminal (typed back without Enter).
  Attachments that were not sent are not kept.
  The tabs are in `~/Library/Application Support/Zeus/restore.json` until the new copy reads them.
  When the new copy does not confirm, the old copy is put back, opens the same tabs again, and says that the new version did not start.
  On the way, each chat page and the page that asked get `{type: "app-update-progress", state: "checking" | "downloading" | "waiting" | "installing", version?, busy?}`
  (`busy`: the number of tabs that the update waits for), or `{type: "app-update-failed", error, message}` with `error` `up-to-date`, `download-failed`, or one of the check errors.
- **Setup window.** The first start runs the bundled `install.sh` in app mode in a hidden terminal.
  `install.sh --check` ticks the steps that are already done. The window shows the installer output,
  an Accept button for the Anaconda license, the GitHub one-time code, a link for the Claude login, and a field for any other answer.
- **Chat window.** A click on the app runs `~/.local/bin/zeus --no-open` in `~/Code/zeus` in a hidden terminal,
  reads the `Zeus chat: <url>` line, and shows that page. If `zeus` stops before the page opens, the window shows its output
  with **Try again** and **Run the Zeus Setup**.
- **Tabs.** Cmd+T (or its shortcut in the settings) opens a tab with its own `zeus` session and chat.
  The app draws the tabs in the title bar in the Zeus chat theme; the + button also opens a tab, and Control-Tab and Control-Shift-Tab show the next and the previous tab.
  A tab has the name of the project that its chat shows, or **Project** without a project.
  Right-click a tab and choose **Rename Tab…** to give it a name: Return saves, Escape cancels, and an empty name gives back the project name.
  A renamed tab keeps its name when the project changes.
  The app does not keep tab names after it quits, but it keeps them across an update from the settings.
  The chat page tells the app its project with `window.webkit.messageHandlers.zeusApp.postMessage({type: "project", name})` (`name` is null without a project);
  for chat pages that do not send it, the app reads the project button of the chat.
  Cmd+J shows or hides the live terminal of the tab, for login prompts, slash commands, or debugging.
- **Keyboard.** Typing and pasting (Cmd+V or Edit > Paste) go to the part of the tab that the user clicked last: the chat page or the terminal.
  Cmd+J gives the keyboard to the terminal it shows; the terminal header then says "typing and pasting go here".
  A click in the chat page gives the keyboard back to the chat, also the click that only brings the window to the front, which WebKit does not give to the page.
  A tab that shows again gives the keyboard to the part that had it, and an open terminal does not take it only because it is open.
- **Keyboard shortcuts.** The shortcuts of the app actions come from the Zeus settings file `~/Library/Application Support/Zeus/settings.json`,
  which the settings pop-up of the chat and Zeus Editor pages writes: `{"version": 1, "shortcuts": {"<action id>": "<shortcut>"}}`.
  The file has only the changed shortcuts; an action without an entry has its default.
  A shortcut is the modifiers in the order Ctrl, Alt, Shift, Cmd, then one key, joined by "+" (for example `Shift+Cmd+M`).
  The app actions and their defaults: `app.newTab` (Cmd+T), `app.newChat` (Cmd+N), `app.closeTab` (Cmd+W), `app.nextTab` (Ctrl+Tab),
  `app.prevTab` (Ctrl+Shift+Tab), and `app.toggleTerminal` (Cmd+J). The pages handle their own actions (`chat.`, `editor.`, and `speech.toggle`).
  The app only reads the file: at start, when a page posts `{type: "settings-changed"}` to `window.webkit.messageHandlers.zeusApp`,
  and when the file changes (also from a browser). The menu items show the new shortcuts at once.
  Two app actions never share a shortcut: a changed action that collides gets its default, until no two collide.
  In the chat and Zeus Editor windows, the page does not get the shortcuts of the app actions, and a symbol key matches by its place on a US keyboard.
  A missing or damaged file, an entry that is not a shortcut, a shortcut without Cmd or Ctrl, a shortcut of two app actions,
  and a reserved shortcut give the default: the macOS shortcuts (Cmd+Q, Cmd+Tab, Cmd+Space, Cmd+H, Cmd+M, Shift+Cmd+3/4/5, Ctrl+Cmd+Q, Alt+Cmd+Escape,
  Cmd+\`, Shift+Cmd+\`, Ctrl+Cmd+Space, Alt+Cmd+Space, Ctrl+Space, Shift+Cmd+Q, Ctrl+Up/Down/Left/Right, Alt+Cmd+D, Shift+Cmd+/),
  Cmd+, (Settings), and the fixed items of the app menu (Alt+Cmd+H, Cmd+Z, Shift+Cmd+Z, Cmd+X, Cmd+C, Cmd+V, Cmd+A, Cmd+R, Cmd+0, Cmd+=, Shift+Cmd+=, Cmd+-, Ctrl+Cmd+F).
  At document start, every Zeus page gets `window.zeusApp.shortcuts = {version: 1, appActions: [<ids>]}`, so that the settings pop-up shows the app shortcuts in the app only.
  **Zeus > Settings…** (Cmd+,) calls `window.zeusApp.openSettings?.()` in the page in front; **Zeus Setup…** has no shortcut.
  In a tab that still shows its loading screen, Settings… opens when the chat page has loaded.
- **Go to the chat.** When the consultant clicks **Go to the chat** in Zeus Editor, the chat page posts `"chat-focus"` to `window.webkit.messageHandlers.zeusApp`.
  The app then shows the tab of that chat, brings its window and the app to the front, and puts the keyboard in the chat page.
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
- **Speech to text.** The chat and the Zeus Editor pages turn speech into text on this Mac; no audio leaves the Mac (`Sources/Zeus/Speech.swift`, `Sources/Zeus/Dictation`).
  The engine is Whisper (whisper.cpp with Metal, `Contents/Frameworks/whisper.framework`), with a local model: **Accurate** (Whisper Large V3 Turbo Q5, the default, 574 MB) or **Fast** (Whisper Tiny, English only, 78 MB).
  Whisper gives the text after Stop: while the user speaks, the page gets the audio level; after Stop, "processing", then the text.
  A recording stops by itself after 10 minutes and is then transcribed.
  The model list is in the app (`Resources/dictation-models.json`, see [docs/dictation-models.md](../docs/dictation-models.md)).
  The first setup downloads the model of the settings next to the installer, with its progress in the checklist; a failed download never stops the setup, and the app tries again in the background.
  At each start, about 2 s after the first window opens, the app downloads a missing or new model in the background, checks its size and SHA-256, and loads it; the model stays loaded for all tabs.
  The models are in `~/Library/Application Support/io.github.theo-henry.zeus/whisper-models/`, so an app update does not download them again.
  When an app update changes a model, the old model stays in use until the new one loads; then the app deletes the old file.
  Until a model is loaded, the app uses Apple's speech recognition on the Mac (`requiresOnDeviceRecognition`), which shows the words while the user speaks.
  The app asks for the microphone permission at the first use (and, for Apple's recognizer, the speech recognition permission), not at start.
  The dictation settings are app-wide, for both chats: the model, the language (auto-detect or one language; the Fast model is English only), and one list of custom words.
  The custom words go to the model as its initial prompt, up to 100 tokens: a hint for spelling, not a guarantee.
  At document start, every Zeus page gets `window.zeusApp.speech = {version: 1, versions: [1, 2]}`; the page keeps it (and `shortcuts`) when it sets its own `window.zeusApp`.
  [docs/speech-bridge.md](../docs/speech-bridge.md) is the contract of both versions: start, stop, cancel, the status of the models and their downloads, the settings, the audio level, the processing state, and the text.
  A version 2 page starts with `version: 2` and gets the Whisper behaviour above.
  A version 1 page (zeus-editor before its version 2 update) keeps its behaviour: Apple's text while the user speaks, and at Stop the Whisper text when it is ready within 2.8 s, otherwise Apple's text, so that the page gets its text within its 4 s deadline.
  This hybrid path is transitional; a version 1 session in a language that the loaded model does not decode uses only Apple's recognizer.
  One recognition runs at a time, from its start until it stops (also while Whisper processes): a start while one runs gets "busy".
  The recognition stops (with its final text) when its tab or Zeus Editor tab goes out of view, and ends at once when its tab, window, or page closes, and when the app quits.
  The third-party notices of whisper.cpp, OpenSuperWhisper, Silero VAD, and the Whisper models are in `Resources/THIRD-PARTY-NOTICES.md` (also in the app bundle).
- **Links.** Pages on 127.0.0.1 stay in the app (pop-ups open in a new app window). Other links open in the default browser.

## Developer Settings

**Zeus > Developer > Developer Settings…** opens a small window in the Zeus theme. Each setting applies at once to every open window, except blind build mode, which applies to sessions that start after the change.

- **Show Claude host switch** (off). The right end of the tab strip gets an **Apolix | EU** switch for the selected tab. The host belongs to the tab: each tab has its own session on its own host, and the switch, the EU pill, and the cost always show the selected tab.
  - **Apolix** is the Claude Code subscription login, as before: the session gets `ZEUS_CLAUDE_HOST=apolix` and nothing else changes.
  - **EU** is Claude on Google Cloud Vertex AI in the EU. The session gets the variables of the `claude-eu` alias of your shell profile
    (`CLAUDE_CODE_USE_VERTEX`, `CLOUD_ML_REGION`, `ANTHROPIC_VERTEX_PROJECT_ID`, the model variables), plus `ZEUS_CLAUDE_HOST=eu` and
    `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. It starts without `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
    Bedrock and Foundry variables, and `VERTEX_REGION_*` overrides, also when the alias sets one. The app refuses an alias whose region is not `eu` or `europe-*`.
  - Claude Code cannot change host while it runs. A click on the switch stops the session of the tab and starts a new one on the other host in the same tab (a running chat is asked about first).
    The loading screen covers the old chat page before its session stops. The chats stay in the chat history; a chat that ran on EU continues only on EU.
  - Before every EU start, the app runs `gcloud auth application-default print-access-token`. When that fails, the tab shows the reason and **Try again**. It never starts on Apolix instead. The token is not kept or logged.
  - An EU tab shows a green **EU** pill in the title bar, also when the switch is hidden. With the switch shown, a new tab starts on the host picked last; with the switch hidden, on Apolix.
- **Show session cost in EU windows** (on) and **Show session cost in Apolix windows** (off). The title bar shows the cost of the tab's session, such as `≈ €1.84`, with the chat that runs now and the tokens in the tooltip.
  The chat page posts `cost:<JSON>` to `window.webkit.messageHandlers.zeusApp` on connect and after each reply (zeus-editor, `docs/chat.md`, "Session cost"); the app shows a report only when its `host` is the tab's host.
  The EU figure is an estimate from Google Cloud list prices; the Apolix figure is the value at API list prices, not a charge on the subscription.
- **Blind build mode** (off). Every session that the app starts, on both hosts, gets `ZEUS_BLIND_MODE=1`; with the setting off, the variable is absent (an inherited one is removed). Zeus enforces what it means: sessions outside the EU see no row values and cannot read raw data files.

### The Secure Handoff when a tab switches from EU to Apolix

Before the EU session stops, the app (not Claude) asks the workspace's Zeus which projects need a Secure Handoff (every project with EU work, sandbox demo projects too): `python3 <workspace>/scripts/zeus.py --workspace <workspace> handoff pending --json`, in the workspace, without the variables of a Claude Code session.
With none, the switch goes on as above, and the loading screen of the Apolix session says "No Secure Handoff needed — this EU session didn't work on a project." for about 1.2 s while the session starts (no step, no sheet). Otherwise the tab shows **Secure Handoff** with "Handing off data securely — removing and aggregating sensitive information" on the loading screen while Zeus runs `handoff build <project> --json` and `handoff scan <project> --json` (off the main thread, with time limits),
and shows each step as Zeus starts it (its `{"stage", "label"}` progress lines on stderr), each for a moment, then ticks them off; a blocked review step shows as failed.
When `pending` says `draft_ready` (Zeus built the draft when the EU session ended, and it is still current), only `handoff scan` runs: collect, strip, and aggregate show as done, "prepared when the EU session ended". If that scan fails, the full build runs. Then a summary sheet shows what goes over (counts), the scan result, and any findings (masked previews from Zeus), with:

- **Release and continue on Apolix**: `handoff release <project> <hash> --json`, then the Apolix session starts. Disabled while the scan has findings or after an error.
- **Open review page**: the HTML review page of the scan.
- **Continue without Secure Handoff**: Apolix starts without a release.
- **Stay on EU**: the EU session keeps running.

An error of Zeus shows in the sheet with its fix; it never starts Apolix by itself and never blocks a later switch to EU.

## Build

Needs only the Xcode Command Line Tools (Swift 5.9 or later). Full Xcode is not necessary.
The first build downloads the whisper.cpp framework (about 54 MB, pinned by its checksum in `Package.swift`); SwiftPM keeps it in its cache.
The app needs macOS 13.3 or later.

```bash
app/build.sh 0.1.0        # app/build/Zeus.app and app/build/Zeus.zip, for Apple silicon and Intel
app/dev-bundle.sh         # app/build/Zeus-dev.app, a quick debug build for this Mac
```

The app has an ad-hoc signature, not an Apple Developer ID.
The GitHub CLI does not mark its downloads with the quarantine attribute, so macOS opens the app without a Developer ID.

CI publishes a release with `app/release.sh` after each merge to `main` that changes the app (see [Release the Zeus app](../README.md#release-the-zeus-app-maintainer)).
It makes the release `app-v<version>` with `Zeus.zip` and `Zeus.zip.sha256` in the private zeus repo.
`install-app.sh` (through `install.sh --app-only`), step 12 of `install.sh`, and the app's self-update download the newest one.

## Debug

`ZEUS_APP_TRACE=/path/to/file` adds setup events, update events, session states, and page loads to the end of that file.
`ZEUS_APP_REPO=owner/name` replaces the repo of the app releases, as in `install.sh`.
`ZEUS_APP_NO_UPDATE=1` turns off the update check at start.
`ZEUS_APP_TEST_NO_CONFIRM=1` (debug builds) makes the new copy of an update not confirm, so that the old copy rolls back. That copy then starts nothing.
`ZEUS_APP_INSTALLER=/path/to/install.sh` replaces the bundled installer.
`ZEUS_APP_PTY_CAPTURE=/path/to/folder` (debug builds) writes every byte of each session's PTY to `pty-<pid>.log` in that folder.
`ZEUS_APP_TEST_SPEECH=1` (debug builds) replaces Apple's speech recognition with a simulated recognizer that "hears" "Hello Zeus" (`denied`: no permission).
`ZEUS_APP_TEST_SPEECH=whisper` (debug builds) also replaces the Whisper model with a simulated one (a file that starts with `ZEUS-SIMULATED-MODEL`) and the microphone with a simulated voice.
`ZEUS_APP_DICTATION_MANIFEST=/path/to/models.json` (debug builds) replaces the model list of the app.
`ZEUS_APP_TEST_AUDIO_FILE=/path/to/sound.wav` (debug builds) replaces the microphone with that sound file, played in real time and then silence, for the real Whisper model.
`ZEUS_APP_TEST_RECORDING_LIMIT=<seconds>` (debug builds) replaces the 10-minute recording limit.
`ZEUS_APP_TEST_V1_DEADLINE=<seconds>` (debug builds) replaces the 2.8 s that Whisper has for the text of a version 1 session.
`ZEUS_APP_NO_MODEL_DOWNLOAD=1` turns off the download of the dictation models; dictation then uses a model that is already on the Mac, or Apple's recognizer.
The tests set it.
`ZEUS_APP_TEST_ID=<id>` (debug builds) makes the test actions reach only this app copy.
`ZEUS_APP_DEFAULTS_SUITE=<domain>` (debug builds) makes the app read and write its settings (`setupDone`, `showMenuBar`, and the dictation settings) in that defaults domain instead of `io.github.theo-henry.zeus`.
`ZEUS_APP_TEST_BACKGROUND=1` (debug builds) makes the app never come to the front: it does not activate and puts its windows behind the windows of other apps.
Its pages keep running and drawing while other windows cover them.
The tests in `app/test` set it, so they do not come in front of your work.
Screenshots use the window number, so they work for windows behind other windows.
Release builds ignore it.
`ZEUS_APP_WORKSPACE=/path/to/zeus` replaces the Zeus workspace (`~/Code/zeus`): sessions start there, and the Secure Handoff runs its `scripts/zeus.py`.
`ZEUS_APP_ZEUS_COMMAND=/path/to/zeus` replaces the zeus command. The app passes its environment on to `zeus`, so `ZEUS_EDITOR_PORT` and `ZEUS_EDITOR_STATE_DIR` give a development Zeus Editor of its own.
`ZEUS_APP_EU_ENV="NAME=value NAME=value"` replaces the `claude-eu` alias, `ZEUS_APP_GCLOUD=/path/to/gcloud` replaces `gcloud`, and `ZEUS_APP_PYTHON` replaces `python3` for the Secure Handoff.
`ZEUS_APP_TEST_NO_SWITCH_QUESTION=1` and `ZEUS_APP_TEST_NO_OPEN=1` (debug builds) skip the switch question and the opening of the review page in tests.
Start the app's binary directly to pass them, for example
`ZEUS_APP_TRACE=/tmp/zeus.log app/build/Zeus-dev.app/Contents/MacOS/Zeus`.
The web pages can be inspected with Safari's Develop menu.

## Test the PTY

```bash
app/test/pty/run.sh
```

It sends 1 MiB to a raw-mode terminal and checks that every byte arrives, that a resize reaches the terminal, and that the UI run loop stays responsive.

## Test the releases and the self-update

```bash
app/test/update/run.sh [release] [globe] [install] [app] [upgrade] [settings]
```

GitHub is simulated (`app/test/sim/payload/gh`): no repo, release, or tag is made, and nothing is downloaded.
Each app case stops all its app copies and fails after `ZEUS_UPDATE_TEST_CASE_LIMIT` seconds (default 300), and the whole test stops after `ZEUS_UPDATE_TEST_LIMIT` seconds (default 3600).
`ZEUS_UPDATE_TEST_CASES="settings-rollback"` runs only those cases of the `settings` part, and `ZEUS_UPDATE_TEST_TRACES=<folder>` keeps the trace of each app case.

1. `release`: `app/release.sh` in a temporary copy of this repo stops for a working tree with changes, a zeus-editor that cannot be checked, a commit that is not the newest main commit,
   a wrong or a too low version, and an existing tag; otherwise it builds the app for both architectures and makes the next `app-v` release with a valid zip and checksum.
   The `globe` part tests `app/check-globe-sync.sh` with a stubbed `gh`: the same files pass; a different globe, `--ink-900`, status page colour, or `LoaderPage.background` is refused; so is a zeus-editor that `gh` cannot read.
2. `install`: `install-app.sh` on a simulated new Mac stops after step 5 without access and downloads nothing;
   with access, it installs the newest `app-v` release (not drafts, pre-releases, or other tags), and it stops for a wrong checksum or version, or without an app release.
3. `app`: the app updates itself from 1.0.0 to 1.1.0, restarts in the new version, and keeps the user state;
   it starts its current version when it is up to date, without access, or when the download is damaged or is not Zeus;
   when the new copy does not confirm, the old copy is put back, and a late start of the new copy quits at once.
4. `upgrade`: `install-app.sh` on a Mac with an older app and user data (the Zeus folder and its client projects, the Zeus settings,
   the Claude chats and plugin data, and the saved window state) closes the open older app with its own quit, shows both versions,
   puts the newest release in its place, and opens it; the new app confirms its start in `update.json`, as after a self-update,
   and the old copy is then removed. Every user data file except `update.json` stays byte-identical.
   With the newest app installed, it downloads nothing and opens the app;
   when the new app stops at once, or runs but does not confirm within 60 s, it puts the same old app bundle back and opens it.
5. `settings`: with a simulated `zeus` (`app/test/sim/payload/zeus.mjs`, with a launch record and a control socket), a chat page asks
   **Check for updates**: no update, then a new release with its notes (not drafts), and no answer from GitHub.
   **Update now** with three tabs (a project with a tab name, unsent text, and a busy turn with an open terminal and unsent terminal text)
   downloads 1.1.0, waits for the turn, keeps the tabs, ends the sessions, and swaps the app; the new copy opens the three tabs,
   resumes each Claude Code session, and puts back the project, the name, and the unsent text of the message box and of the terminal.
   **Update now** on the latest version changes nothing; when the new copy does not confirm, the old copy is put back and opens the same tabs again.

## Test the plugin scope

```bash
app/test/plugin-scope/run.sh
```

`install.sh` must add every plugin and marketplace with `--scope user`.
At project scope, Claude Code writes the tracked `.claude/settings.json` of the Zeus folder again, and then `git pull --ff-only` cannot update Zeus.
The test runs the plugin steps of `install.sh` and the commands in its next steps against a simulated `claude` in a Zeus folder.
It checks that each plugin install, update, and marketplace add uses `--scope user` and that `.claude/settings.json` does not change.

## Test the Claude Code update

```bash
app/test/claude-update/run.sh
```

Step 7 of `install.sh` updates an installed Claude Code with the method that installed it.
The test runs step 7 against a simulated `claude`, `npm`, `brew`, and `sudo` in a temporary home folder, so the real Claude Code of this Mac does not change.
It checks the native install (`claude update`), an npm install (`npm install -g` in the same prefix), and a Homebrew install (`brew upgrade --cask claude-code`).
It checks that the summary shows the old and the new version, or "up to date".
It checks that a failed update, an npm folder that needs `sudo`, and an update that does not finish in the time limit give a warning, never use `sudo`, and let the installer continue.
It checks that the time limit also stops the child processes of the update.
It also checks the `@@zeus` lines of step 7 in app mode.

## Test on a simulated new Mac

```bash
app/test/sim/run.sh [screenshot-folder]
```

The test runs the app (behind the other apps) and the bundled installer with `HOME` set to an empty temporary folder, and with
simulated tools first on `PATH` (`app/test/sim/stubs` and `payload`): xcode-select, the Anaconda and Node.js
downloads, conda, gh, npm, claude, and a `zeus` that serves a simple chat page. Nothing is downloaded, and the
real home folder, Claude Code, GitHub login, and app settings are not used (the app settings are restored).
The paste checks use the pasteboard, then put back what the user had on it.
It presses the app's buttons through the debug test actions and checks the trace:

1. A new Mac: the check finds 12 steps to do; all 13 steps install, with the Anaconda license, the GitHub
   one-time code, and the Claude login answered in the app; Start Zeus opens the chat page from `~/Code/zeus`
   with `--no-open` and the globe hand-over; a close with unsent text waits and can be cancelled; closing the window stops `zeus` with SIGTERM;
   Cmd+T tabs start separate sessions and come in without the hand-over; a tab takes the name of the project picked in its chat,
   keeps a name given with Rename, and gets the project name again after an empty name;
   `"chat-focus"` from the chat page of a tab that is not selected shows that tab with the keyboard in its chat page; Cmd+J shows the terminal and its input reaches that session;
   with the terminal open, a click in the chat box takes the keyboard, and a one-line and a multi-line paste go into the chat box, not into the terminal;
   after a click in the terminal, a paste reaches its session; a tab that shows again gives the keyboard back to the part that had it;
   a close while Zeus works waits for the turn; closing one tab keeps the others; a chat that cannot answer the close check
   (older editor plugin) waits 3 s, then **Close anyway** closes it; **Close anyway** also stops a busy tab; quitting stops every session.
2. One tab has unsent text and one tab is busy: a logout that another app cancels changes nothing, a later quit asks about both tabs,
   and a logout while that question is open stops every session and quits within 12 s without an answer;
   the quit event of a logout while a quit still checks the tabs asks nothing, also after the check, and quits within 12 s.
   The quit of the install line (`quit_zeus_app` in `install.sh`) asks about unsent text as the app's own quit does, and the install line waits.
3. Speech to text with a simulated recognizer (`ZEUS_APP_TEST_SPEECH`, debug builds): the chat page keeps `window.zeusApp.speech` after it sets `window.zeusApp`;
   the languages and the default come to the page; a start listens, the words come in, and a stop gives the final text, which replaces only the dictated part of the message;
   a second start is busy; a language without recognition on the Mac gives `no-on-device`; showing another tab stops it; it runs in a Zeus Editor page,
   another page cannot stop it, and closing the Zeus Editor window, closing the tab, or quitting the app ends it;
   with Apple's recognizer, the page gets the languages of this Mac, and a language that no Mac knows gives `no-on-device` without a permission question.
   Then Whisper dictation with a simulated model, which a local server sends slowly (`ZEUS_APP_TEST_SPEECH=whisper`): the page has bridge versions 1 and 2;
   while the model downloads, dictation uses Apple's recognizer; the download shows its progress, is checked, and loads;
   Whisper sends the audio level, then "processing", then the text, and the trace has the time from the stop to the text;
   a version 1 start gets the words while the user speaks, then the Whisper text within 4 s, and Apple's text when Whisper is not ready in time;
   the custom words are cleaned, saved, counted in tokens, and reach the model; a fixed language reaches the model, and an unknown language is refused;
   a start while Whisper processes is busy; a cancel while it processes gives no text; the Fast model downloads when the user picks it and decodes English only;
   the model on the Mac loads at the next start without a download; the recording limit stops a recording and gives its text;
   a new model with a wrong checksum fails and the old model stays in use; a new model list downloads the new model, switches to it, and deletes the old file;
   a new model that does not load is removed, and the old model stays in use;
   a version 1 page in a language that the English-only model does not decode gets only Apple's text;
   a re-download of the model on this Mac fetches and checks it again while dictation keeps working, and the runtime loads the new copy.
4. Keyboard shortcuts: the app reads the changed shortcuts of the settings file at start, gives the default for a reserved shortcut,
   a shortcut without Cmd or Ctrl, and a shortcut of two actions (also after a chain of collisions), and shows the shortcuts in the menu; the chat page has `window.zeusApp.shortcuts`;
   the old shortcut does nothing and the new one opens a tab; a file saved with a rename, a file written in place, and `{type: "settings-changed"}`
   apply at once; a damaged file gives the defaults without a crash; a symbol key shortcut with Shift works in a Zeus Editor window;
   Settings… calls `openSettings` in the chat page, also when it comes while a new tab still loads its chat page.
5. No access to one private repo: step 5 fails, the setup stops, and nothing after step 5 is installed.
6. Developer Settings and the host switch: a tab starts on Apolix; the cost on connect shows only when its setting is on; the switch to EU checks the Google Cloud sign-in, stops the Apolix session,
   and starts `zeus` with the EU variables and without keys, proxies, or region overrides; blind build mode reaches new sessions only; the cost of each report reaches the title bar;
   the host bar follows the selected tab; without a sign-in the EU start is refused and nothing starts on Apolix; **Try again** starts on EU after the sign-in.
7. The Secure Handoff with a simulated `scripts/zeus.py` (`payload/handoff-zeus.py`): a clean scan ticks off its stages in under 3 s and releases before the EU session stops;
   a scan with findings disables Release and **Stay on EU** keeps EU; a failed build or pending check asks, and **Continue without Secure Handoff** starts Apolix without a release; a draft prepared when the EU session ended is scanned, not built; with no EU work the step is skipped and the loading screen says so.

`ZEUS_SIM_SCENARIOS="6 7"` runs only the named scenarios (2 and 3 run with 1).

With a folder, it saves a screenshot of each state (only the test app's windows), a recording of the startup animation, and the traces. It needs Screen Recording
permission for the terminal only for the screenshots.
