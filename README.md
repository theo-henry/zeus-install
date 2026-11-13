# Zeus installer

This installer prepares a Mac for Zeus.
It installs the tools that Zeus needs and copies the private zeus repo to `~/Code/zeus`.

This repo contains only the installer.
It contains no Zeus content and no secrets.
You can get the zeus repo and the Zeus Editor plugin only with a GitHub account that has access.

## Before you start

1. Make a GitHub account at [github.com](https://github.com) and turn on 2FA.
2. Send your GitHub username to Theo for access to the private Zeus repos:
   `zeus`, `zeus-editor`, `YAML-builder`, `celonis-ocpm`, and `celonis-pql`.

## Install the Zeus app (recommended)

1. Press Cmd + Space, type "Terminal", and press Enter.
2. Copy this line, paste it into Terminal, and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/theo-henry/zeus-install/main/install-app.sh | bash
```

3. The Zeus app opens. Its setup window shows each tool that Zeus needs, with a tick for each tool that is already installed.
   Click **Install**. The window shows the installer output, the GitHub one-time code, and the questions to answer.
4. When the setup is complete, click **Start Zeus**.

After that, click Zeus in the Dock. You do not need Terminal.
The Zeus app runs the `zeus` command in a hidden terminal and shows the Zeus chat and the Zeus Editor in its own window.
Each tab has its own Zeus session.
Closing a tab, or quitting the app, stops that Zeus session, so no Claude Code session stays open in the background.
While Zeus works, or while the chat has unsent text, the tab waits before it closes; the chat stays in the history.
Running `zeus` in Terminal still works next to the app.

Use the install line in Terminal, not a browser download of `Zeus.zip`.
The app has no Apple Developer ID signature.
A browser marks its downloads, and macOS then blocks the app until you click
**System Settings > Privacy & Security > Open Anyway**.
A download with `curl` has no such mark, so the app opens without that step.

### The Zeus app

| Feature | Where |
| --- | --- |
| New tab with a new Zeus session | File > New Tab (Cmd + T) or File > New Chat (Cmd + N) |
| Show or hide the live terminal of the tab | View > Show or Hide Terminal (Cmd + J) |
| Setup window again, for example after a failed step | Zeus > Zeus Setup… |
| Menu bar icon with the running sessions, and Open and Stop for each | Zeus > Show in Menu Bar |
| Keep Zeus in the Dock | Zeus > Keep in Dock, or the option in the setup window |

Links to other websites open in your default browser. Zeus Editor pages stay in the app.

The app runs its own copy of `install.sh` in app mode (`ZEUS_INSTALL_APP=1`).
In app mode, the installer prints `@@zeus` status lines for the checklist, `--check` only reports which steps are done,
and two more steps run: the Zeus skill plugins (step 12) and the Claude login (step 13).
To build the app, see [app/README.md](app/README.md).

## Install in Terminal only

1. Press Cmd + Space, type "Terminal", and press Enter.
2. Copy this line, paste it into Terminal, and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/theo-henry/zeus-install/main/install.sh | bash
```

3. Follow the instructions on the screen.

If the installer stops, it tells you why.
Fix the problem, then run the same line again.
The installer skips each step that is already done.

## What the installer does

| Step | Tool | Skipped when |
| --- | --- | --- |
| 1 | Git (Xcode Command Line Tools) | They are already installed. |
| 2 | Python (Anaconda) | conda is already installed, or Python 3.10 or later and the GitHub CLI are already installed. |
| 3 | GitHub CLI (from conda-forge) | `gh` is already installed. |
| 4 | GitHub login in the browser | You are already logged in. |
| 5 | Check of your access to all the private Zeus repos (`zeus`, `zeus-editor`, `YAML-builder`, `celonis-ocpm`, `celonis-pql`) | Never skipped. It only reads. The installer lists all the repos you cannot reach and stops here, before it installs more. |
| 6 | Node.js 24 in `~/.local/node` | Node.js 18.20.5 or later is already installed. |
| 7 | Claude Code | `claude` is already installed. |
| 8 | Celonis content-cli | `content-cli` is already installed. |
| 9 | Copy of the zeus repo to `~/Code/zeus`, or an update of an existing copy (fast-forward only, local work is never discarded) | The copy is already up to date, or it cannot update safely. Then the installer tells you how Zeus gets the update. |
| 10 | Zeus Editor plugin (`zeus-editor@zeus-editor`, for your user) | Never skipped. An existing install is updated. |
| 11 | The `zeus` command in `~/.local/bin` | The command is already installed and up to date. |
| 12 | The Zeus app in `/Applications` (`~/Applications` without administrator rights) | The app is open. A failed download does not stop the installer. |

The installer does not use `sudo`.
Your Mac password can be necessary only for the Apple pop-up in step 1.
The installer asks you to accept the Anaconda license before it installs Anaconda.
Logs for Anaconda and the GitHub CLI are in `~/Library/Logs/zeus-install`.

## After the install

When step 12 installed the Zeus app, it opens. Follow its setup window; it does the steps below for you.
Without the app:

1. Close Terminal and open a new Terminal window.
2. Type `cd ~/Code/zeus` and press Enter.
3. Type `claude` and press Enter.
   Log in to Claude in the browser the first time.
4. The Zeus Editor needs Node.js 22 or later.
5. In Claude, type these three commands:

```text
/plugin install celonis-yaml-builder@yaml-builder
/plugin install celonis-ocpm@celonis-ocpm
/plugin install celonis-pql@celonis-pql
```

6. Close Claude (Ctrl + C two times) and open a new Terminal window.
7. Type `zeus` and press Enter.
   The `zeus` command starts Claude Code with the Zeus Editor and opens the chat page.
   When the Zeus Editor plugin is not installed, the command tells you to run the install line again.

## When the installer says "no access"

Step 5 lists each private repo that your GitHub account cannot reach.
1. Check for invitations at [github.com/notifications](https://github.com/notifications).
   The installer also prints a link to the invitations page of each missing repo.
2. Accept each invitation.
3. If there is no invitation, send your GitHub username to Theo and ask for access to the repos in the list.
4. Run the same install line again.
