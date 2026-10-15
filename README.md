# Zeus installer

This installer prepares a Mac for Zeus.
It installs the tools that Zeus needs and copies the private zeus repo to `~/Code/zeus`.

This repo contains only the installer.
It contains no Zeus content and no secrets.
You can get the zeus repo only with a GitHub account that has access.

## Before you start

1. Make a GitHub account at [github.com](https://github.com) and turn on 2FA.
2. Send your GitHub username to Theo for access to the zeus repo.

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
| 5 | Check of your access to the zeus repo | Never skipped. The installer stops here if you have no access. |
| 6 | Node.js 24 in `~/.local/node` | Node.js 18.20.5 or later is already installed. |
| 7 | Claude Code | `claude` is already installed. |
| 8 | Celonis content-cli | `content-cli` is already installed. |
| 9 | Copy of the zeus repo to `~/Code/zeus` | The folder already contains the zeus repo. |

The installer does not use `sudo`.
Your Mac password can be necessary only for the Apple pop-up in step 1.
The installer asks you to accept the Anaconda license before it installs Anaconda.
Logs for Anaconda and the GitHub CLI are in `~/Library/Logs/zeus-install`.

## After the install

1. Close Terminal and open a new Terminal window.
2. Type `cd ~/Code/zeus` and press Enter.
3. Type `claude` and press Enter.
   Log in to Claude in the browser the first time.
4. In Claude, type these two commands:

```text
/plugin install celonis-yaml-builder@yaml-builder
/plugin install celonis-ocpm@celonis-ocpm
```

5. Close Claude (Ctrl + C two times), type `claude` again, and then type `/zeus`.
