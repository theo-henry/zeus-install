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

## Install

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
| 9 | Copy of the zeus repo to `~/Code/zeus` | The folder already contains the zeus repo. |
| 10 | Zeus Editor plugin (`zeus-editor@zeus-editor`, for your user) | Never skipped. An existing install is updated. |
| 11 | The `zeus` command in `~/.local/bin` | The command is already installed and up to date. |

The installer does not use `sudo`.
Your Mac password can be necessary only for the Apple pop-up in step 1.
The installer asks you to accept the Anaconda license before it installs Anaconda.
Logs for Anaconda and the GitHub CLI are in `~/Library/Logs/zeus-install`.

## After the install

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
