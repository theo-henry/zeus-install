# Zeus installer

This installer prepares a Mac for Zeus.
It installs the tools that Zeus needs and copies the private zeus repo to `~/Code/zeus`.

This repo contains only the installer and the code of the Zeus app.
It contains no Zeus content and no secrets.
You can get the zeus repo, the Zeus Editor plugin, and the Zeus app only with a GitHub account that has access.

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

3. Follow the instructions on the screen.
   The line runs steps 1 to 5 of the installer: Git, Python (Anaconda), the GitHub CLI, the GitHub login, and the check of your access to all the private Zeus repos.
   If your account has no access to one of the repos, the line stops there and downloads nothing.
4. Then the line downloads the newest Zeus app from a release of the private zeus repo, installs it, and opens it.
   Its setup window shows each tool that Zeus needs, with a tick for each tool that is already installed.
   Click **Install**. The window shows the installer output and the questions to answer.
5. When the setup is complete, click **Start Zeus**.

After that, click Zeus in the Dock. You do not need Terminal.
The Zeus app runs the `zeus` command in a hidden terminal and shows the Zeus chat and the Zeus Editor in its own window.
Each tab has its own Zeus session.
Closing a tab, or quitting the app, stops that Zeus session, so no Claude Code session stays open in the background.
While Zeus works, or while the chat has unsent text, the tab waits before it closes; the chat stays in the history.
Running `zeus` in Terminal still works next to the app.

The app is not on a public download page.
It is in a release of the private zeus repo, and the install line downloads it with your GitHub login.
The app has no Apple Developer ID signature.
A browser marks its downloads, and macOS then blocks such an app until you click
**System Settings > Privacy & Security > Open Anyway**.
A download with the GitHub CLI has no such mark, so the app opens without that step.

### Updates

The Zeus app updates itself each time it starts, before a Zeus session starts.
It asks the private zeus repo, with your GitHub login, for the newest app release.
While the app checks, it shows the Zeus globe with "Checking for updates…".
When a newer version is available, the app downloads it and starts again in the new version.
Your settings, your workspace, and your chats do not change.
If the new version does not start, the app puts the old version back and starts it.
When you are offline, or your account has no access, the app starts its current version and shows no message.
While the app runs, **Check for updates** in the settings of the chat shows what is new, and **Update now** installs it.
The app waits until Zeus has finished its work in every tab, starts again in the new version, and opens the same tabs with their chats, projects, and unsent text.
The Zeus content (`~/Code/zeus` and the plugins) updates itself each time Zeus starts, as before.

### You already have the Zeus app

Versions 0.1.0, 0.1.1, and 0.1.2 of the app cannot update themselves: their update always goes back to the old version.
**Zeus > About Zeus** shows your version.
To get the newest version, run the same install line one time in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/theo-henry/zeus-install/main/install-app.sh | bash
```

Your projects and your history stay.
The line replaces only the app.
It does not change `~/Code/zeus` and its client folders, the Zeus settings in `~/Library/Application Support/Zeus`, your Claude chats in `~/.claude`, or your plugins.

- The line shows your version and the newest version, replaces the app, and opens the new app.
  From the new version on, the app updates itself again.
- When your app is already the newest version, the line tells you and opens it.
- When the Zeus app is open, the line closes it as when you quit it.
  When a tab has unsent text or Zeus is working, the app asks you first.
  If you click **Cancel**, the app stays open, and after 2 minutes the line stops without a change.
- The line keeps the old app until the new app has started.
  If the new app does not start, the line puts the old app back and opens it.

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
Steps 14 to 16 set up EU mode (see [EU mode](#eu-mode)).
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
| 7 | Claude Code, or an update of an installed Claude Code to the newest version, with the method that installed it: `claude update` (the native install), npm (an npm install, in its own folder), or Homebrew (`brew upgrade --cask`). The summary shows the version. | Never skipped. When Claude Code is already the newest version, the summary shows "up to date". A failed update, or an update that does not finish in 5 minutes, is a warning: the installer continues with the installed version and tells you how to update it later. |
| 8 | Celonis content-cli | `content-cli` is already installed. |
| 9 | Copy of the zeus repo to `~/Code/zeus`, or an update of an existing copy (fast-forward only, local work is never discarded) | The copy is already up to date or already has the Zeus version that Zeus Editor needs, or it cannot update safely. Then the installer tells you how Zeus gets the update. |
| 10 | Zeus Editor plugin (`zeus-editor@zeus-editor`, for your user) | Never skipped. An existing install is updated. |
| 11 | The `zeus` command in `~/.local/bin` | The command is already installed and up to date. |
| 12 | Google Cloud CLI 593.0.0 in `~/google-cloud-sdk`, for the Google sign-in of EU mode. The installer checks the SHA-256 of the official macOS archive and does not change your shell profile. | `gcloud` is already installed (on your `PATH`, in `~/google-cloud-sdk`, or from Homebrew). |
| 13 | Copy of the zeus repo to `~/Code/zeus-eu`, the EU workspace, or an update of an existing copy (fast-forward only) | The copy is already up to date, or it cannot update safely. |
| 14 | The Zeus plugins of EU mode (Zeus Editor and the skill plugins) in the EU Claude folder `~/.zeus/eu/claude`, and the first-start settings of that folder | Never skipped. Installed plugins are updated. |
| 15 | The Zeus app in `/Applications` (`~/Applications` without administrator rights), from the newest app release of the private zeus repo. An installed older app is updated in its folder, as with the install line (see [You already have the Zeus app](#you-already-have-the-zeus-app)). | The app is already the newest version, or an older app is open (quit it, then run the line again). A failed download does not stop the installer. |

The installer does not use `sudo`.
Your Mac password can be necessary only for the Apple pop-up in step 1.
The installer asks you to accept the Anaconda license before it installs Anaconda.
Logs for Anaconda, the GitHub CLI, and the Claude Code update are in `~/Library/Logs/zeus-install`.

## After the install

When step 15 installed the Zeus app, it opens. Follow its setup window; it does the steps below for you.
Without the app:

1. Close Terminal and open a new Terminal window.
2. Type `cd ~/Code/zeus` and press Enter.
3. Type `claude` and press Enter.
   Log in to Claude in the browser the first time.
4. The Zeus Editor needs Node.js 22 or later.
5. Close Claude (Ctrl + C two times) and type these commands.
   `--scope user` installs the plugins for you, not in the Zeus folder.
   A plugin installed in the Zeus folder changes its `.claude/settings.json`, and then Zeus cannot update itself.

```text
claude plugin marketplace add theo-henry/YAML-builder --scope user
claude plugin install celonis-yaml-builder@yaml-builder --scope user
claude plugin marketplace add theo-henry/celonis-ocpm --scope user
claude plugin install celonis-ocpm@celonis-ocpm --scope user
claude plugin marketplace add theo-henry/celonis-pql --scope user
claude plugin install celonis-pql@celonis-pql --scope user
```

6. Open a new Terminal window.
7. Type `zeus` and press Enter.
   The `zeus` command starts Claude Code with the Zeus Editor and opens the chat page.
   When the Zeus Editor plugin is not installed, the command tells you to run the install line again.

## EU mode

EU mode runs Zeus with Claude on Google Vertex AI in the EU (location `eu`), for clients whose data must stay in the EU.
The model is Claude Sonnet 5.5.
Web search is available; web fetch and MCP servers are off.
EU mode has its own workspace (`~/Code/zeus-eu`), its own Claude Code folder (`~/.zeus/eu/claude`), and its own Zeus Editor state (`~/.zeus/eu/editor`).
Nothing of EU mode goes into `~/Code/zeus` or `~/.claude`.

### Set up EU mode

1. Run the install line or Zeus > Zeus Setup… in the app.
   The EU steps are the same on every Mac (steps 12 to 14, or 14 to 16 in the app).
2. Ask the Zeus maintainer to give your Google account access to the EU project.
   The maintainer gives the account the Vertex AI User role on the project `project-4bf0bacd-fec4-406b-a99`.
3. Sign in to Google one time.
   In the app, the EU start page shows **Sign in to Google Cloud** when it is necessary.
   In Terminal, use these two commands:

```text
gcloud auth application-default login
gcloud auth application-default set-quota-project project-4bf0bacd-fec4-406b-a99
```

### Use EU mode in the app

- The mode switch is at the right of the tab bar (`Standard | EU`), in the Zeus menu, and in the menu bar icon.
  A green EU pill shows in EU mode.
- A switch closes all the tabs of the current mode and stops their sessions before the other mode starts.
  The app asks first when a tab has unsent text or Zeus is working.
  The tabs of each mode come back when you switch back to that mode.
  An EU tab never opens in Standard mode, and a Standard tab never opens in EU mode.
- Each mode has its own web data (cookies and storage) and its own terminal environment.
- In EU mode, the tab bar shows an estimate of the session cost in USD.
- When the EU start fails, the app shows why and what to do: sign in to Google Cloud, run the Zeus setup, try again, or switch to Standard.

### Hand over EU work to Standard

EU work never goes to Standard by itself.
A person releases it in the app:

1. In EU mode, select Zeus > Hand Over EU Work…, or **Hand Over First…** when you switch to Standard.
2. Click **Ask Zeus in this chat**.
   The EU chat writes the handover summary of its project.
   Then click **Review…** next to the project.
3. Review the summary and the files.
   The app scans them for client data.
   You can edit the summary, remove files, and accept a finding.
   An e-mail address or an IBAN can not be accepted: remove the file, or change the text in EU mode.
4. Click **Release to Standard**.
   The app copies the released files into `~/Code/zeus/clients/<project>/handoff/from-eu/<id>/` and writes `released.json` there.
   The Standard project must already exist.

The "Zeus feedback" section of the handover summary goes to Standard with the release.
Standard Zeus sends it, not EU mode.

## Release the Zeus app (maintainer)

The app releases are in the private zeus repo, with tags `app-v<version>` and the assets `Zeus.zip` and `Zeus.zip.sha256`.
The install line, step 15, and the self-update of the app use the newest of these releases.
Drafts, pre-releases, and the other releases of the zeus repo are not used.

CI makes a release by itself.
Each push to `main` runs the tests, and then the `release` job of `.github/workflows/ci.yml` finds the commit of the newest app release (in its notes).
When `app/`, `install.sh`, or `install-app.sh` changed since that commit, the job runs `app/release.sh` on a GitHub-hosted macOS runner.
The release has the next version (the newest app release plus 1 in the last number), and its notes list the subjects of all commits that changed these files since that commit.
The runs of `main` run one at a time, and a run never stops a running run, so two merges cannot take the same version.
The job never runs on the self-hosted runner.
If a newer commit is already on `main`, the job of the older commit does not release and shows a notice: the run of the newer commit releases all app changes since the newest app release.
Because each run compares with the newest app release, a change is also released by the next push to `main` when a job failed or did not release.
If GitHub lost the run of a push to `main`, start it by hand: in Actions, open CI, choose Run workflow, and select `main`.

The job needs the Actions secret `ZEUS_RELEASE_TOKEN` in this repo: a fine-grained personal access token with access to only the repo `theo-henry/zeus` and the permission Contents: read and write.
The token cannot do anything else.
To make the token, open GitHub > Settings > Developer settings > Fine-grained tokens, and set a date for it to expire.
Make a new token before that date, and replace the secret.
Without the secret the job fails with an error that names `ZEUS_RELEASE_TOKEN`, so CI on `main` is red until you add it.

To make a release by hand (for a version that you choose, or when CI cannot), run this on a Mac with the Xcode Command Line Tools and with `gh` logged in with write access to the zeus repo:

```bash
git switch main && git pull --ff-only
app/release.sh            # the newest app release plus 1 in the last number, or 0.1.0 for the first release
app/release.sh 1.2.0      # or a version that you choose, higher than the newest app release
```

The script stops when the working tree has changes or when the checkout is not the newest commit of `origin/main`.
It also stops when `app/Resources/globe.js` or the loader colour differ from zeus-editor (`app/check-globe-sync.sh`, see `app/README.md`).
CI skips this check with `ZEUS_SKIP_GLOBE_CHECK=1`, because its token cannot read the private zeus-editor repo.
It builds the app with `app/build.sh`, checks the zip (bundle identifier, version, and signature), and makes the release with `gh`.
The release is not marked as the latest release of the zeus repo.
No GitHub token is stored in the app or in the files of this repo.
The only token is the secret `ZEUS_RELEASE_TOKEN` of the CI release job.

## When the installer says "no access"

Step 5 lists each private repo that your GitHub account cannot reach.
1. Check for invitations at [github.com/notifications](https://github.com/notifications).
   The installer also prints a link to the invitations page of each missing repo.
2. Accept each invitation.
3. If there is no invitation, send your GitHub username to Theo and ask for access to the repos in the list.
4. Run the same install line again.
