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
  Offline, without `gh`, without access, or with any error, the app starts its current version and shows nothing.
  Development versions (such as `0.0.0-dev`), a read-only app folder, and `ZEUS_APP_NO_UPDATE=1` turn the check off.
- **Setup window.** The first start runs the bundled `install.sh` in app mode in a hidden terminal.
  `install.sh --check` ticks the steps that are already done. The window shows the installer output,
  an Accept button for the Anaconda license, the GitHub one-time code, a link for the Claude login, and a field for any other answer.
- **Chat window.** A click on the app runs `~/.local/bin/zeus --no-open` in `~/Code/zeus` in a hidden terminal,
  reads the `Zeus chat: <url>` line, and shows that page. If `zeus` stops before the page opens, the window shows its output
  with **Try again** and **Run the Zeus Setup**.
- **Tabs.** Cmd+T opens a tab with its own `zeus` session and chat.
  The app draws the tabs in the title bar in the Zeus chat theme; the + button also opens a tab, and Control-Tab and Control-Shift-Tab show the next and the previous tab.
  A tab has the name of the project that its chat shows, or **Project** without a project.
  Right-click a tab and choose **Rename Tab…** to give it a name: Return saves, Escape cancels, and an empty name gives back the project name.
  A renamed tab keeps its name when the project changes.
  The app does not keep tab names after it quits.
  The chat page tells the app its project with `window.webkit.messageHandlers.zeusApp.postMessage({type: "project", name})` (`name` is null without a project);
  for chat pages that do not send it, the app reads the project button of the chat.
  Cmd+J shows or hides the live terminal of the tab, for login prompts, slash commands, or debugging.
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
- **Speech to text.** The chat and the Zeus Editor pages can turn speech into text with Apple's speech recognition (`Sources/Zeus/Speech.swift`).
  The recognition runs on the Mac only (`requiresOnDeviceRecognition`), so no audio leaves the Mac.
  The app asks for the speech recognition and microphone permissions at the first use, not at start.
  At document start, every Zeus page gets `window.zeusApp.speech = {version: 1}`; the page keeps it when it sets its own `window.zeusApp`.
  A page posts `{type: "speech-languages"}`, `{type: "speech-start", id, locale}` (a BCP-47 id, or null for the `default` of the languages answer), and `{type: "speech-stop", id}` to `window.webkit.messageHandlers.zeusApp`.
  The app answers in that page only, with `window.zeusSpeech?.onEvent(event)`:
  `{type: "languages", locales: [{id, name, onDevice: true}], default}` (only the languages that the Mac recognizes on the Mac),
  `{type: "state", id, state: "listening" | "stopped"}`, `{type: "partial", id, text}`, `{type: "final", id, text}`,
  and `{type: "error", id, code: "permission-denied" | "no-on-device" | "unavailable" | "busy" | "failed", message}`.
  After "listening", a recognition always ends with "stopped"; an error before "listening" is the only answer to that start.
  One recognition runs at a time: a start while one runs gets "busy".
  The recognition stops (with its final text) when its tab or Zeus Editor tab goes out of view, and ends at once when its tab, window, or page closes, and when the app quits.
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

### The EU handoff when a tab switches from EU to Apolix

Before the EU session stops, the app (not Claude) asks the workspace's Zeus which projects need a handoff: `python3 <workspace>/scripts/zeus.py --workspace <workspace> handoff pending --json`, in the workspace, without the variables of a Claude Code session.
With none, the switch goes on as above. Otherwise the tab shows **Handing off data securely** on the loading screen while Zeus runs `handoff build <project> --json` and `handoff scan <project> --json` (off the main thread, with time limits),
and shows each step as Zeus starts it (its `{"stage", "label"}` progress lines on stderr), each for a moment, then ticks them off; a blocked review step shows as failed. Then a summary sheet shows what goes over (counts), the scan result, and any findings (masked previews from Zeus), with:

- **Release and continue on Apolix**: `handoff release <project> <hash> --json`, then the Apolix session starts. Disabled while the scan has findings or after an error.
- **Open review page**: the HTML review page of the scan.
- **Continue without handoff**: Apolix starts without a release.
- **Stay on EU**: the EU session keeps running.

An error of Zeus shows in the sheet with its fix; it never starts Apolix by itself and never blocks a later switch to EU.

## Build

Needs only the Xcode Command Line Tools (Swift 5.9 or later). Full Xcode is not necessary.

```bash
app/build.sh 0.1.0        # app/build/Zeus.app and app/build/Zeus.zip, for Apple silicon and Intel
app/dev-bundle.sh         # app/build/Zeus-dev.app, a quick debug build for this Mac
```

The app has an ad-hoc signature, not an Apple Developer ID.
The GitHub CLI does not mark its downloads with the quarantine attribute, so macOS opens the app without a Developer ID.

To publish a release, run `app/release.sh [version]` (see [Release the Zeus app](../README.md#release-the-zeus-app-maintainer)).
It makes the release `app-v<version>` with `Zeus.zip` and `Zeus.zip.sha256` in the private zeus repo.
`install-app.sh` (through `install.sh --app-only`), step 12 of `install.sh`, and the app's self-update download the newest one.

## Debug

`ZEUS_APP_TRACE=/path/to/file` adds setup events, update events, session states, and page loads to the end of that file.
`ZEUS_APP_REPO=owner/name` replaces the repo of the app releases, as in `install.sh`.
`ZEUS_APP_NO_UPDATE=1` turns off the update check at start.
`ZEUS_APP_TEST_NO_CONFIRM=1` (debug builds) makes the new copy of an update not confirm, so that the old copy rolls back.
`ZEUS_APP_INSTALLER=/path/to/install.sh` replaces the bundled installer.
`ZEUS_APP_PTY_CAPTURE=/path/to/folder` (debug builds) writes every byte of each session's PTY to `pty-<pid>.log` in that folder.
`ZEUS_APP_TEST_SPEECH=1` (debug builds) replaces Apple's speech recognition with a simulated recognizer that "hears" "Hello Zeus" (`denied`: no permission).
`ZEUS_APP_TEST_ID=<id>` (debug builds) makes the test actions reach only this app copy.
`ZEUS_APP_WORKSPACE=/path/to/zeus` replaces the Zeus workspace (`~/Code/zeus`): sessions start there, and the handoff runs its `scripts/zeus.py`.
`ZEUS_APP_ZEUS_COMMAND=/path/to/zeus` replaces the zeus command. The app passes its environment on to `zeus`, so `ZEUS_EDITOR_PORT` and `ZEUS_EDITOR_STATE_DIR` give a development Zeus Editor of its own.
`ZEUS_APP_EU_ENV="NAME=value NAME=value"` replaces the `claude-eu` alias, `ZEUS_APP_GCLOUD=/path/to/gcloud` replaces `gcloud`, and `ZEUS_APP_PYTHON` replaces `python3` for the handoff.
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
app/test/update/run.sh [release] [install] [app]
```

GitHub is simulated (`app/test/sim/payload/gh`): no repo, release, or tag is made, and nothing is downloaded.

1. `release`: `app/release.sh` in a temporary copy of this repo stops for a working tree with changes, a commit that is not the newest main commit,
   a wrong or a too low version, and an existing tag; otherwise it builds the app for both architectures and makes the next `app-v` release with a valid zip and checksum.
2. `install`: `install-app.sh` on a simulated new Mac stops after step 5 without access and downloads nothing;
   with access, it installs the newest `app-v` release (not drafts, pre-releases, or other tags), and it stops for a wrong checksum or version, or without an app release.
3. `app`: the app updates itself from 1.0.0 to 1.1.0, restarts in the new version, and keeps the user state;
   it starts its current version when it is up to date, without access, or when the download is damaged or is not Zeus;
   when the new copy does not confirm, the old copy is put back.

## Test the plugin scope

```bash
app/test/plugin-scope/run.sh
```

`install.sh` must add every plugin and marketplace with `--scope user`.
At project scope, Claude Code writes the tracked `.claude/settings.json` of the Zeus folder again, and then `git pull --ff-only` cannot update Zeus.
The test runs the plugin steps of `install.sh` and the commands in its next steps against a simulated `claude` in a Zeus folder.
It checks that each plugin install, update, and marketplace add uses `--scope user` and that `.claude/settings.json` does not change.

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
   Cmd+T tabs start separate sessions and come in without the hand-over; a tab takes the name of the project picked in its chat,
   keeps a name given with Rename, and gets the project name again after an empty name;
   `"chat-focus"` from the chat page of a tab that is not selected shows that tab with the keyboard in its chat page; Cmd+J shows the terminal and its input reaches that session;
   a close while Zeus works waits for the turn; closing one tab keeps the others; a chat that cannot answer the close check
   (older editor plugin) waits 3 s, then **Close anyway** closes it; **Close anyway** also stops a busy tab; quitting stops every session.
2. One tab has unsent text and one tab is busy: a logout that another app cancels changes nothing, a later quit asks about both tabs,
   and a logout while that question is open stops every session and quits within 12 s without an answer;
   the quit event of a logout while a quit still checks the tabs asks nothing, also after the check, and quits within 12 s.
3. Speech to text with a simulated recognizer (`ZEUS_APP_TEST_SPEECH`, debug builds): the chat page keeps `window.zeusApp.speech` after it sets `window.zeusApp`;
   the languages and the default come to the page; a start listens, the words come in, and a stop gives the final text, which replaces only the dictated part of the message;
   a second start is busy; a language without recognition on the Mac gives `no-on-device`; showing another tab stops it; it runs in a Zeus Editor page,
   another page cannot stop it, and closing the Zeus Editor window, closing the tab, or quitting the app ends it;
   with Apple's recognizer, the page gets the languages of this Mac, and a language that no Mac knows gives `no-on-device` without a permission question.
4. No access to one private repo: step 5 fails, the setup stops, and nothing after step 5 is installed.
5. Developer Settings and the host switch: a tab starts on Apolix; the cost on connect shows only when its setting is on; the switch to EU checks the Google Cloud sign-in, stops the Apolix session,
   and starts `zeus` with the EU variables and without keys, proxies, or region overrides; blind build mode reaches new sessions only; the cost of each report reaches the title bar;
   the host bar follows the selected tab; without a sign-in the EU start is refused and nothing starts on Apolix; **Try again** starts on EU after the sign-in.
6. The EU handoff with a simulated `scripts/zeus.py` (`payload/handoff-zeus.py`): a clean scan ticks off its stages in under 3 s and releases before the EU session stops;
   a scan with findings disables Release and **Stay on EU** keeps EU; a failed build or pending check asks, and **Continue without handoff** starts Apolix without a release; with no EU work the step is skipped.

`ZEUS_SIM_SCENARIOS="5 6"` runs only the named scenarios (2 and 3 run with 1).

With a folder, it saves a screenshot of each state (only the test app's windows), a recording of the startup animation, and the traces. It needs Screen Recording
permission for the terminal only for the screenshots.
