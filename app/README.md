# Zeus app

A small native macOS app (Swift, AppKit, and SwiftUI) that starts Zeus without Terminal.

- **Applications folder.** At the first start, an app that runs from another folder (Downloads, a build folder)
  copies itself to `/Applications` (`~/Applications` without administrator rights), opens the copy, and quits.
  A copy in Downloads goes to the Trash. Development versions turn this off, and so do `ZEUS_APP_TRACE` and `ZEUS_APP_NO_MOVE=1` in debug builds.
- **Updates.** At each start, before any chat window or Zeus session opens, the app asks the private zeus repo for the newest release with a tag `app-v<version>` (`gh api`, with the user's GitHub CLI login; the app holds no token).
  While it checks, the app shows the loading screen (the Zeus globe) with "Checking for updates…"; the check stops after 5 s, and the app then starts its current version.
  When that version is higher, the loading screen shows "Downloading Zeus X.Y.Z…", the app downloads `Zeus.zip` and `Zeus.zip.sha256` (`gh release download`), and checks the checksum, the zip, the bundle identifier, the version, and the signature.
  Then it swaps the new app into the place of the running app in one rename (`renamex_np` with `RENAME_SWAP`), opens the new copy, and waits up to 20 s for the new copy to confirm in `~/Library/Application Support/Zeus/update.json`.
  After the confirmation, it removes the old copy and quits; without it, it stops the new copy, swaps the old app back, and starts as before.
  For 2 minutes after a roll back, `update.json` marks the roll back: a new copy that macOS starts late (under a high load) quits at once and does not update again.
  The file has one stage (`Sources/Zeus/UpdateHandoff.swift`): `swapped`, `newCopyStarted` (with the process ID of the new copy), `confirmed`, or `rolledBack` (with the end of the mark).
  The old copy, the new copy, and `install.sh` change the stage only through its legal transitions, under the lock `update.lock` in the same folder, so a confirmation and a roll back at the same moment cannot both win.
  The file also keeps the fields `confirmed`, `newPID`, and `rolledBack` of app versions before the stage, so that such a version can be the old or the new copy.
  Offline, without `gh`, without access, or with any error, the app starts its current version and shows nothing.
  Development versions (such as `0.0.0-dev`), a read-only app folder, and `ZEUS_APP_NO_UPDATE=1` (debug builds) turn the check off.
- **Update from the settings.** **Check for updates** and **Update now** in the settings of the chat and Zeus Editor pages ask the app about the app (`Sources/Zeus/AppUpdate.swift`).
  At document start, every Zeus page gets `window.zeusApp.update = {version: 1}`.
  A page posts `{type: "app-update-check"}` to `window.webkit.messageHandlers.zeusApp`; the app asks the zeus repo for its `app-v` releases (as at launch, but it waits up to 12 s, because the page waits 15 s)
  and answers in that page with `window.zeusApp.onUpdateEvent({type: "app-update-check", status, version, latest, notes, available, error?, message?})` (the contract of zeus-editor, `docs/chat.md`).
  `status` is `current`, `available` (the app can install `latest` now), or `error`.
  `version` is the installed version, `latest` is the newest app release (or null), `notes` has the release notes of each release newer than `version` (an array), and `available` is true when the app can install `latest` now.
  When `status` is `error`, `error` is `no-gh`, `unreachable` (no answer from GitHub, or no access), `no-release`, `development` (a development build), or `cannot-update` (a read-only app folder, or `ZEUS_APP_NO_UPDATE=1`), and `message` says it in words.
  A page posts `{type: "app-update-apply"}` for **Update now**.
  The app asks for the releases (it waits up to 12 s) and answers in that page with `{type: "app-update-apply", status: "started" | "error", message?}` as soon as it finds the new release (`error` when it does not, or when this copy cannot update itself).
  The app downloads and checks the newest release as at launch, while the user keeps working.
  Then it waits until Zeus works in no tab (a turn, a question or permission prompt in a turn, a message on its way, or a start).
  Then it shows the loading screen with "Installing Zeus X.Y.Z…" in the place of the front chat window and hides the chat windows, so that no message can start a turn.
  When a tab started to work just before, the chat windows come back and the update waits again.
  Otherwise it keeps each tab, ends every session, swaps the app, and opens the new copy.
  The new copy opens the same tabs in the same windows: each tab starts `zeus` again, restarts its Claude Code session with `--resume` through the control socket of the launch
  (`{op: "restart", resume: <session id>}`, zeus-editor `packages/launcher/control.js`), and then shows the chat.
  The tab keeps its project, its name, its open terminal, the unsent text of the message box (`#zeus-message`), and the unsent text of the terminal (typed back without Enter).
  Attachments that were not sent are not kept.
  The tabs are in `restore.json` until the new copy reads them: Standard tabs in `~/Library/Application Support/Zeus`, EU tabs in `~/.zeus/eu/editor/app` (in the EU vault).
  The Standard record keeps only the place and mode of each EU tab, so each tab opens again in its own mode and order; the EU tabs open after Touch ID opens the vault, and stay closed when it is cancelled.
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
- **Simple EU and EU with isolation.** `isolation` (boolean, default false) in the EU launch profile `eu-profile.json` of the installed Zeus Editor is the one switch that the app, Zeus Editor, and zeus share (`EUProfile.isolation`).
  False (simple EU): an EU tab starts like a Standard tab, with the EU model account only (`zeus --eu`); the app makes, unlocks, and mounts no EU vault, runs Standard without the read block (`StandardJail.isOn`), copies no EU status line, hides EU data access and the handover, and keeps the EU tab records in the app folder (`restore-eu.json`).
  True: the EU vault, the read block, the handover, and EU data access, as below.
  The per-tab switch, the EU badge, and the EU cost work in both.
- **gcloud Python.** gcloud 593 has no Python of its own, and the Python of macOS (3.9) makes it stop. `ShellEnvironment.make` sets `CLOUDSDK_PYTHON` to a Python 3.10 or later (`GcloudPython`: Anaconda, Miniconda, or Miniforge of the home folder, the system folders, then python3.14 ... python3 on the PATH), unless the user set one, so the Google sign-in button and the EU start check do not depend on the login PATH.
- **Standard | EU per tab.** Each tab has its own mode (`ChatTab.mode`, the mode of its `ZeusSession`; `Sources/Zeus/EUMode.swift`), and Standard and EU tabs run side by side.
  An EU tab runs `zeus --eu --no-open` in `~/Code/zeus`, the workspace that both modes share (`Paths.workspace`), with the EU launch profile `eu-profile.json` of Zeus Editor (schema 1 or 2; the app does not use its `workspace`).
  With isolation, an EU session starts only while the EU vault is open: the first EU start makes the vault after Touch ID, a later one unlocks it after Touch ID, and the vault stays open until the app quits.
  Without the Zeus plugins of EU mode in the vault, the app asks for the Zeus setup, which installs them in the open vault.
  A cancelled Touch ID keeps the tab Standard; at an app start with an EU tab, the app opens a Standard tab and shows why on its window.
  Each app start sets a new `ZEUS_APP_RUN` for the sessions, so Zeus Editor keeps a passed EU start check for one app run.
  **File > New EU Chat** (Shift+Cmd+T) and **New Standard Chat** open a tab of that mode; **New Tab** and **New Chat** use the mode of the selected tab of the front window.
  The first tab of an app start has the mode of the tab used last (`ZeusMode.lastUsed`, the `zeusMode` default).
  The `Standard | EU` control at the right of the tab bar shows the mode of the selected tab, and a click switches only that tab (`AppDelegate.switchTab`), as does **Switch Tab to EU…** in the tab menu.
  The switch asks first (a new chat in this tab; the old chat stays in the history of its mode), opens the vault for EU, runs the close check of the tab, then starts the session of the other mode and gives it to the tab (`ChatTab.switchSession`).
  The tab keeps its place, name, and terminal panel; its chat page is made again, because the web data store of a page is fixed when it is made.
  The old session ends.
  An EU tab shows a green **EU** badge in its label; the title bar shows the EU session cost estimate of the selected EU tab (in euros, see below) from the `cost:` messages of the chat page.
  While the vault is open, a green lock in the title bar opens the vault menu with the lock state.
  Each mode has its own web data store, and the terminal of a tab runs in the environment of its mode.
  When EU mode does not start, the tab shows the `zeus:` message with **Sign in to Google Cloud** (it runs the gcloud sign-in in the tab's terminal),
  **Run the Zeus setup**, **Try again**, and **Switch to Standard**. An `eu-error:` message (Vertex AI 403, 404, or 429) shows a question with the fix.
  When gcloud refuses the EU project as the quota project of the sign-in for a missing permission (no Service Usage Consumer role), the tab shows the 403 access message, with the Google account when gcloud names it, in place of the gcloud error.
- **EU handover.** **Hand Over First…** at the switch of an EU tab to Standard opens the handover window (`Sources/Zeus/Handover.swift`).
  **Ask Zeus in this chat** sends the summary request to an EU tab, with the project that the tab shows.
  The app runs the handoff commands of `scripts/zeus.py` of the shared workspace `~/Code/zeus` with `--workspace ~/Code/zeus`.
  EU Claude can not write the `scripts` folder (Zeus Editor denies it to EU), and the app runs `python3 -E -s`, so no module in the working folder loads, and EU Claude can not change the scan.
  `handoff build`, `scan`, and `mask` get `--dir ~/Library/Application Support/Zeus/handover/<project>/<id>` (owner only, mode 700), the handover's own folder: the handover is built, scanned, masked, and released only there, where no Claude session can write.
  The app takes `<id>` from the newest `clients/<project>/handoff/<id>/summary.md` of the workspace, as `handoff build` does, and refuses a build answer for another ID.
  The app refuses an answer whose `id` or `project` is not the handover of the review (a decoy folder), and every path that is not in that folder.
  The app shows the summary, the files, and one row per finding group with its real values, read from the app's copy (not selectable, never written to a file or the trace).
  For each group the user chooses Keep or Mask (`Mask All` for the rest); e-mail and IBAN groups offer only Mask, and a changed or missing file needs **Build Again**.
  A Keep holds for the group and a hash of each value, so a new value in the same group needs a new choice.
  **Release to Standard** runs `handoff mask` for the Mask groups, scans again, and releases only when every finding left is a kept one.
  A failed step goes back to the review with the user's choices; the masks that were made stay.
  The app copies the checked files to `~/Code/zeus/clients/<project>/handoff/from-eu/<id>/` and writes `released.json`
  (`kept` and `masked` as kinds and counts, never a group ID or a value; `removed_count`, never the path of a removed file, because the scan does not check those paths).
  The same record goes into the EU handover folder `clients/<project>/handoff/<id>/` without following a link; it is in the shared workspace, so it also names no removed path.
  Claude never releases a handover.
- **EU data access.** For a selected EU tab, the title bar shows **EU data access** for the project of the tab (`EUDataAccess` in `Sources/Zeus/EUMode.swift`).
  The app reads it with `eu-access <project> --json` and changes it with `eu-access <project> on|off --json` (the workspace's `zeus.py`, outside Claude, as for the handover); on asks first.
- **EU cost in euros.** The EU cost shows in euros at the daily ECB reference rate (`EuroRate`), loaded for EU tabs once a day and kept in
  `~/Library/Application Support/Zeus/euro-rate.json`. Without a rate of today, it shows USD with "(no euro rate)". The tooltip shows the USD estimate.
  The euro value is a conversion of the Vertex USD estimate at the ECB daily reference rate, not the amount that Google bills; the label stays an estimate.
  `ZEUS_APP_EURO_RATE_URL` (debug builds) replaces the ECB address.
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
  A tab where Zeus still starts, or resumes its chat after an update, has no chat to ask yet: it is not safe to close, with the reason "Zeus is starting".
  The same answer goes to the quit question, the mode switch, and an update, which all wait for it or ask first (`Sources/Zeus/TabLifecycle.swift`).
  Then the app sends SIGTERM to its `zeus`; the chat stays in the history.
  In the app, the app owns closing: `zeus` runs with `ZEUS_APP=1`, so the editor does not close terminals when the page closes.
- **Standard read block.** On a Mac with an EU vault (its disk image, or a mounted vault with its marker), open or locked, the app starts every Standard `zeus` through `/usr/bin/sandbox-exec` with a macOS sandbox profile that denies reading and writing the EU folders (`Sources/Zeus/StandardJail.swift`).
  The Standard Claude Code, its hooks, its Bash commands, and the programs that they start as child processes inherit it: `cat`, Python, or a child shell get "Operation not permitted" in those folders.
  Known limit of phase 1: a program that a Standard session starts through launchd (`launchctl` or a LaunchAgent), `open`, or `osascript` is not its child process and runs outside the read block.
  No Standard process can rename or delete a denied folder or a folder that holds one (a `(deny file-write-unlink ...)` rule for each of them up to `/Users` and `/private`), so `mv ~/Code ~/Code-x` can not give an EU folder a new path outside the denies.
  The profile is `(allow default)` with three deny rules: `(deny file-read* file-write* ...)` for the EU folders, `(deny file-write* ...)` for its own jail folder, and `(deny file-write-unlink ...)` for each EU folder and every folder above it, such as `~/Code`, `~/.zeus`, `~/Library/Application Support/Zeus`, the home folder, `/Users`, `/private`, and `/tmp`.
  These folders can not be renamed or deleted; the network, the keychain, and every other folder work as before, and content-cli reads a large View as without it.
  The app always denies its own EU folders, whatever the Zeus Editor EU profile (`eu-profile.json`) says: the EU vault (`~/.zeus/eu` and its disk image), the default EU Claude Code folder and editor state (`~/.zeus/eu/claude`, `~/.zeus/eu/editor`), the old EU workspace `~/Code/zeus-eu`, the default EU temporary folder `/tmp/zeus-eu-<uid>` (`/private/tmp/zeus-eu-<uid>`), and the app's handover folder.
  The EU profile can only add denied folders (its Claude Code folder, editor state, and `tmp_dir`); an added folder that holds the home folder, `~/Code/zeus`, or the app folder is never denied.
  The shared workspace `~/Code/zeus` stays open to Standard: EU client data is in the vault.
  Without an EU vault, Standard starts exactly as before, without `sandbox-exec`.
  The app writes the profile to `~/Library/Application Support/Zeus/jail/standard.sb` (owner only) at start and again before each Standard start, and the profile also denies writes to its own folder.
  EU sessions do not run in it. A macOS sandbox can not start inside another one, so Standard Claude Code must run its commands without the Claude Code sandbox (zeus-editor PR 139).
  A Zeus Editor from before that change still runs them in it, and Claude Code could not start in the read block.
  On a Mac with an EU vault, Standard never starts without the read block: with that Zeus Editor, the Standard session does not start and the app tells the user to run the Zeus setup to update Zeus Editor; without `sandbox-exec`, it does not start and the app says that Standard can not start while an EU vault exists.
- **EU vault.** `Sources/Zeus/EUVault.swift` makes and opens the EU vault: one encrypted APFS sparse bundle (AES-256) per user in `~/Library/Application Support/Zeus/eu-vault.sparsebundle`, mounted at `~/.zeus/eu` with `-nobrowse` and `-owners on`.
  It has a `.zeus-vault` marker file with the ID of its volume (`{"schema": 1, "kind": "zeus-eu-vault", "volume_uuid": "..."}`) and a `.metadata_never_index` file; `mdutil -i off` needs administrator rights, so the app only tries it.
  The key is a random 64-character password in the login keychain, in an item that the app makes, so its access list trusts only the Zeus app.
  The app reads the key only after Touch ID, or the login password on a Mac without Touch ID (`LAContext`, `deviceOwnerAuthentication`), and gives it to `hdiutil -stdinpass` on standard input.
  The key is never in an environment, an argument, a log, a file, or a Claude session.
  The app does not make the vault over a `~/.zeus/eu` folder that holds files, because the mount would hide them.
  The vault locks only when the app quits, after every session stopped (`hdiutil detach -force`, because a program can still have a file of it open; the app waits for it at most 4 s).
  After a crash, the next app start locks it before anything else.
  The first EU start makes the vault, and each later EU start of an app run opens it (see **Standard | EU**); the tests also make and open it with debug test actions.
- **Old EU folders.** The app never uses or removes `~/Code/zeus-eu` or the files in a plain `~/.zeus/eu` from before the shared workspace and the vault.
  The app has an ad-hoc signature, so the keychain knows it by the hash of its code, which changes with each version: after an app update, the first unlock of the vault makes macOS ask once for the login password, so that the new Zeus can read the key. Click **Always Allow**.
  Another program that asks for the key gets the same question from macOS.
- **No hidden sessions.** Quitting the app stops every session.
  When tabs are not safe to close, one question lists them all: **Quit Anyway** or **Cancel**.
  When macOS logs out, restarts, or shuts down, the app asks nothing and closes an open quit question; without a question, the quit ends within 12 s.
  When the window of the quit question closes (its last tab's session ended), the quit ends with it, and a later quit asks again.
  `AppLifecycle.swift` keeps the phase of the app (its start and its updates) and of its quit in one value, with the table of legal transitions.
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
`install-app.sh` (through `install.sh --app-only`), step 15 of `install.sh`, and the app's self-update download the newest one.

## Debug

Only debug builds (`swift build`, `app/dev-bundle.sh`) read these settings; a release build ignores every `ZEUS_APP_*` setting and `ZEUS_EDITOR_STATE_DIR`.
The app reads them only through `DebugEnvironment.value` (`Sources/Zeus/Environment.swift`).
`app/test/release-env/run.sh` (in `app/test/run-all.sh`) compiles `Environment.swift` without and with `DEBUG` and checks that only the `DEBUG` copy uses `ZEUS_APP_TRACE` and `ZEUS_EDITOR_STATE_DIR` (the editor state and the environment of the commands that the app starts).
It also starts a release build of the app with `ZEUS_APP_TRACE` and checks that it writes no trace file; the debug build, started the same way, writes the trace file.

`ZEUS_APP_TRACE=/path/to/file` adds setup events, update events, session states, and page loads to the end of that file.
`ZEUS_APP_REPO=owner/name` replaces the repo of the app releases, as in `install.sh`.
`ZEUS_APP_NO_UPDATE=1` turns off the update check at start.
`ZEUS_APP_EURO_RATE_URL=<url>` replaces the address of the ECB daily rates for the EU cost (a `file://` URL works).
`ZEUS_APP_TEST_NO_CONFIRM=1` makes the new copy of an update not confirm, so that the old copy rolls back. That copy then starts nothing.
`ZEUS_APP_INSTALLER=/path/to/install.sh` replaces the bundled installer.
`ZEUS_APP_ZEUS_COMMAND=/path/to/zeus` replaces `~/.local/bin/zeus`.
`ZEUS_APP_PTY_CAPTURE=/path/to/folder` writes every byte of each session's PTY to `pty-<pid>.log` in that folder.
`ZEUS_APP_TEST_SPEECH=1` replaces Apple's speech recognition with a simulated recognizer that "hears" "Hello Zeus" (`denied`: no permission).
`ZEUS_APP_TEST_SPEECH=whisper` also replaces the Whisper model with a simulated one (a file that starts with `ZEUS-SIMULATED-MODEL`) and the microphone with a simulated voice.
`ZEUS_APP_DICTATION_MANIFEST=/path/to/models.json` replaces the model list of the app.
`ZEUS_APP_TEST_AUDIO_FILE=/path/to/sound.wav` replaces the microphone with that sound file, played in real time and then silence, for the real Whisper model.
`ZEUS_APP_TEST_RECORDING_LIMIT=<seconds>` replaces the 10-minute recording limit.
`ZEUS_APP_TEST_V1_DEADLINE=<seconds>` replaces the 2.8 s that Whisper has for the text of a version 1 session.
`ZEUS_APP_NO_MODEL_DOWNLOAD=1` turns off the download of the dictation models; dictation then uses a model that is already on the Mac, or Apple's recognizer.
The tests set it.
`ZEUS_APP_TEST_ID=<id>` makes the test actions reach only this app copy.
`ZEUS_APP_TEST_VAULT_AUTH=allow|cancel|fail` replaces Touch ID for the EU vault with that answer (the test action `test-vault-auth:<answer>` changes it).
`ZEUS_APP_TEST_JAIL=1` starts Standard sessions in the read block also on a Mac without an EU vault.
`ZEUS_APP_TEST_KEYCHAIN=/path/to/file.keychain-db` keeps the EU vault key in that keychain file instead of the login keychain.
`ZEUS_APP_DEFAULTS_SUITE=<domain>` makes the app read and write its settings (`setupDone`, `showMenuBar`, and the dictation settings) in that defaults domain instead of `io.github.theo-henry.zeus`.
`ZEUS_APP_TEST_BACKGROUND=1` makes the app never come to the front: it does not activate and puts its windows behind the windows of other apps.
Its pages keep running and drawing while other windows cover them.
The tests in `app/test` set it, so they do not come in front of your work.
Screenshots use the window number, so they work for windows behind other windows.
Start the app's binary directly to pass them, for example
`ZEUS_APP_TRACE=/tmp/zeus.log app/build/Zeus-dev.app/Contents/MacOS/Zeus`.
The web pages can be inspected with Safari's Develop menu.

## Test the PTY

```bash
app/test/pty/run.sh
```

It sends 1 MiB to a raw-mode terminal and checks that every byte arrives, that a resize reaches the terminal, and that the UI run loop stays responsive.

## Test the EU sign-in failure

```bash
app/test/eu-sign-in/run.sh
```

It checks which gcloud output of the EU sign-in is a quota project refused for a missing permission (`Sources/Zeus/EUSignInFailure.swift`), and that other errors, a failed login, and a completed sign-in are not.

## Test the app and quit phases

```bash
app/test/lifecycle/run.sh
```

It compiles `Sources/Zeus/AppLifecycle.swift` alone and checks each legal transition of the app phase (the start, the update at launch, and the steps of an update from the settings) and of the quit phase, and that each phase refuses every other event.

## Test gcloud with an old Python

```bash
app/test/gcloud-python/run.sh
```

It runs the installer steps with a PATH that has only a Python 3.9 and a fake gcloud that refuses it, as gcloud 593 does.
Step 14 does not take that gcloud as installed and shows the gcloud error and the fix; the sign-in step says that gcloud does not run and asks nothing.
With Anaconda in the home folder, step 14 runs gcloud with its Python (`CLOUDSDK_PYTHON`) and says so.
It also checks `GcloudPython`, which finds the same Python for the commands that the app starts.

## Test the update handoff

```bash
app/test/update-handoff/run.sh
```

It tests the stages of `update.json` (`Sources/Zeus/UpdateHandoff.swift`) without app copies: each legal transition and the refused ones, the role of a copy that starts, and each step of the waiting copy.
Then it tests the file between the app and `install.sh`: each side reads the stages that the other writes, the fields of older app versions stay, both use the same lock, and a roll back of `install.sh` does not stop a new app that confirmed.

## Test the chat tab lifecycle

```bash
app/test/tab-lifecycle/run.sh
```

It tests the lifecycle of a chat tab (`Sources/Zeus/TabLifecycle.swift`) without app copies and without WebKit: each legal transition of the phases and that every other transition is refused,
the epoch that stops a timer or a callback of an earlier phase or of the session before a mode switch, what the phase tells a close, a quit, a mode switch, and an update,
Settings… before the chat page has loaded, the mode switch of the tab, and the close request.

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
   when the new copy does not confirm, the old copy is put back, and a late start of the new copy quits at once;
   a roll back mark that has ended does not stop the app, also when another process has the process ID of the old copy.
4. `upgrade`: `install-app.sh` on a Mac with an older app and user data (the Zeus folder and its client projects, the Zeus settings,
   the Claude chats and plugin data, and the saved window state) closes the open older app with its own quit, shows both versions,
   puts the newest release in its place, and opens it; the new app confirms its start in `update.json`, as after a self-update,
   and the old copy is then removed. Every user data file except `update.json` and `update.lock` stays byte-identical.
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
It also checks the EU plugin list and that the EU status line follows the Standard one (`eu_mirror_status_line`, `install.sh --eu-status-line`).

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

## Test the environment failures

```bash
app/test/env-failures/run.sh
```

The test covers three problems of a Mac that is not set up correctly, and a Mac that is.
A folder of the user that root owns (`~/.config`, `~/.config/gh`, `~/.npm`, `~/.local`, `~/.local/bin`, `~/.claude`) stops the installer before step 1 with one `sudo chown` line.
Root-owned files in the npm cache stop step 8 with the `sudo chown` line for `~/.npm`.
The installer never runs `sudo`.
The Claude login command gets the real terminal device as its input, not `/dev/tty`, because Claude Code stops with `EINVAL: invalid argument, kqueue` on `/dev/tty`.
Without a terminal, the login step tells the user to run `claude` in the Terminal app, and an existing login is skipped.
Before the browser login opens, step 13 reads the keychain with `security`.
Before each keychain check, it prints that macOS may ask for the login keychain password.
When the login keychain is locked, macOS can show a dialog that asks for that password.
The keychain is unlocked only if the user enters the password, and Cancel gives the stop for a locked keychain with the fix.
When the default keychain is missing, the login keychain is locked, or the default keychain is not in the keychain search list, it stops with the exact fix and the warning never to click Reset To Defaults.
When the browser login fails and the keychain is then not usable, for example Claude Code prints "Couldn't save your login", the same fix shows.
The login command keeps the terminal for its input and output.
The installer never runs `security unlock-keychain`, never creates, deletes, or resets a keychain, and never changes the keychain search list.
When the global folder of npm is not writable, content-cli goes to `~/.npm-global` and is linked into `~/.local/bin`.
A root-owned folder in the test is a link to `/private/etc` in a temporary home folder, so no `sudo` and no real folder is used.
A Mac with its own folders, a writable npm folder, or a finished login takes the same path as before, with no new output.

## Test on a simulated new Mac

```bash
app/test/sim/run.sh [screenshot-folder]
app/test/sim/run.sh --eu [screenshot-folder]   # EU mode only
app/test/sim/run.sh --vault [screenshot-folder]   # EU vault and Standard read block only
app/test/sim/run.sh --signin [screenshot-folder]   # Google sign-in step of the setup only
app/test/sim/run.sh --quit [screenshot-folder]   # quit question whose window closes only
```

The test runs the app (behind the other apps) and the bundled installer with `HOME` set to an empty temporary folder, and with
simulated tools first on `PATH` (`app/test/sim/stubs` and `payload`): xcode-select, the Anaconda and Node.js
downloads, conda, gh, npm, claude, and a `zeus` that serves a simple chat page. Nothing is downloaded, and the
real home folder, Claude Code, GitHub login, and app settings are not used (the app settings are restored).
The paste checks use the pasteboard, then put back what the user had on it.
It presses the app's buttons through the debug test actions and checks the trace:

1. A new Mac: the check finds 14 steps to do; all 16 steps run (with the three EU steps: the Google Cloud CLI; the EU plugins, which with isolation wait without an open EU vault and write nothing in `~/.zeus/eu`, and with `ZEUS_INSTALL_TEST_EU_VAULT_OPEN` install, trust `~/Code/zeus`, and change no shell profile; and the Google sign-in with the EU quota project), with the Anaconda license, the GitHub
   one-time code, the Claude login, and the Google sign-in question answered in the app; the access check gets the token in files, never on a command line; Start Zeus opens the chat page from `~/Code/zeus`
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
   An EU step that fails (the Google Cloud CLI download) is a warning: the later steps run (the Google sign-in fails without gcloud and asks nothing), the setup completes,
   and a switch to EU mode names the missing Google Cloud CLI. In Terminal use, the steps after a failed EU step also run.
   An EU step that stops on a command without its own message (an EU config folder that can not be made) is also reported as failed.

`--eu` runs the EU mode scenario with isolation (`app/test/sim/eu.sh`, the payload profile says `"isolation": true`) with a simulated `gcloud`, EU `zeus`, and handoff `scripts/zeus.py`:
the app start keeps the old EU workspace `~/Code/zeus-eu`;
a real EU vault (as in `--vault`): a cancelled Touch ID makes no vault and keeps Standard, the first EU start makes it, the setup question when the EU plugins are not in it, and the EU plugins step of `install.sh` installs them in the mounted vault;
the switch of a tab to EU (a new EU chat in the same tab, the old Standard chat ends, and no app-wide switch or kept mode tabs) with `zeus --eu --no-open` in `~/Code/zeus`, the same workspace as Standard;
before each EU session, the app gives EU Claude Code the status line of Standard (`install.sh --eu-status-line`), also after a Standard status line change;
the vault lock in the title bar, the EU web data store, and the cost label; a 429 error question; a failed start that needs the Google sign-in,
a quota project refused for a missing permission (the 403 access message), the sign-in in the terminal, and the retry; a 403 failure; the handover request that names the project of the tab, the handover with findings, an accepted finding, an edited summary, a removed file,
the release, and `released.json` (the EU copy in the shared workspace names no removed path); the handoff commands run the workspace's `scripts/zeus.py` and never a module of the working folder; the switch of the handover tab back to Standard (a new Standard chat, no EU chat resumes, the other EU tab keeps running);
a Standard tab and an EU tab on the same project at the same time; the restore of both tabs after an app start, each in its own mode and order, the EU tab after the vault unlock, with no EU chat or project in the Standard record;
an app start with an EU tab and a cancelled Touch ID opens a Standard tab and says why; and a restart with an EU tab that unlocks the vault before the EU session, with a new `ZEUS_APP_RUN` for each app start.

`--eu-simple` runs the simple EU scenario (`app/test/sim/simple.sh`, a profile with `"isolation": false`):
the EU plugins step of `install.sh` is done with nothing to install and no vault message;
Standard runs without the read block on a Mac with an EU vault disk image; New EU Chat starts `zeus --eu --no-open` in `~/Code/zeus` with no Touch ID, no vault, and no EU status line step;
the EU cost without EU data access and without a vault button; Standard and EU tabs on the same project; a switch to Standard and back without the handover choice;
and the restore of both tabs after an app start, with the EU record in the app folder; the vault disk image and the old EU folders stay untouched.
Then a new app run whose first chat page does not say "chat-ready" switches the mode of its tab before the hand-over: the page-load timer of the old page is ignored, and the new chat hands over only after its own page has loaded.
Last, a tab where Zeus starts, and a tab that resumes its kept chat, are not safe to close: the update waits for them, Cmd+W shows "Zeus is starting" with **Close anyway**, the mode switch asks first, and the quit question lists them.

`--signin` runs the Google sign-in step of the setup (`app/test/sim/signin.sh`) with a simulated `gcloud` and simulated Google answers:
**Skip** completes the setup without a sign-in and writes no marker file, and the setup again asks while the user is signed out; an account without the two roles gets the message for the roles with the account, and the setup completes;
after the roles, the setup again sets the EU quota project without a question or a second sign-in; a Mac that is signed in gets no question;
in Terminal use, the same results are warnings that do not stop the setup, and without a keyboard an expired sign-in is skipped with a note.

`--quit` runs the quit scenario (`app/test/sim/quit.sh`): a quit asks about unsent text; the tab's session ends while the question shows,
so the tab and its window close; the quit ends with that window (AppKit does not call the completion of a sheet whose window closes), and a later quit of a new chat quits the app.

`--vault` runs the EU vault and Standard read block scenario (`app/test/sim/vault.sh`) with a real encrypted disk image in the temporary home folder,
a keychain file of the test (`ZEUS_APP_TEST_KEYCHAIN`) instead of the login keychain, and test answers instead of Touch ID (`ZEUS_APP_TEST_VAULT_AUTH`), so no macOS window opens:
the app start keeps the old EU workspace; the read block profile and its folders; no vault over the EU folders from before the vault; a cancelled Touch ID makes no vault and no key;
the vault is made encrypted, mounted without a Finder icon, owner only, with its marker, and its key is only in the keychain item that only the app may read, and not in the trace;
a new Standard session in the read block can not read the vault, its disk image, the old EU workspace, or the handover folder with `cat`, Python, a child shell, or Node, and can not write the vault, the old EU workspace, or its own profile,
and can not rename `~/Code`, `~/.zeus`, the app folder, or the old EU workspace to read an EU file at a new path,
while it reads and renames in its own workspace and gets a 20 MB response complete (as content-cli gets a large View);
a lock fails while a program has a vault file open, and the quit locks the vault after the sessions stopped; a cancelled Touch ID keeps it locked, and Touch ID opens it;
after a crash the next start locks it before anything else; a wrong key does not open it; with an EU profile that names other EU folders, the profile still denies the fixed EU folders and adds the profile's, but not a schema 1 `workspace`, and a schema 2 profile without `workspace` loads;
and with a Zeus Editor that still runs Standard commands in the Claude Code sandbox, Standard does not start on a Mac with a vault and the app tells the user to update Zeus Editor.

With a folder, it saves a screenshot of each state (only the test app's windows), a recording of the startup animation, and the traces. It needs Screen Recording
permission for the terminal only for the screenshots.
