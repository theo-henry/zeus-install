# Contributing to the Zeus installer

**Pull requests must go through [no-mistakes](https://github.com/kunchenguid/no-mistakes), pass all checks, and get a human review before merge.**

The contributor is responsible for the change and the evidence that it works.
Review must not be the first time someone tests it.

AI-assisted contributions are welcome.
You must understand what the change does, check the generated code, and test the result yourself.

## Report a problem or an idea

Open an issue in [theo-henry/zeus](https://github.com/theo-henry/zeus/issues), the intake repository for all Zeus repositories.
The maintainer triages each issue and moves it to the repository that owns it.
Do not open a pull request to report a problem.

Write what you did, what you expected, and what happened.
Do not put client data in an issue: no rows, values, screenshots, project names, URLs, emails, or keys.

## Workflow

1. Fork this repository and clone the parent repository, `https://github.com/theo-henry/zeus-install.git`.
   Keep `origin` pointed at the parent repository.
2. Create a feature branch.
   Keep each pull request small and focused on one problem.
   Put unrelated fixes and refactors in separate pull requests.
3. Install [no-mistakes](https://github.com/kunchenguid/no-mistakes) and set your fork as its push target:
   Replace `YOUR-USERNAME` with your GitHub username.

   ```sh
   no-mistakes init --fork-url https://github.com/YOUR-USERNAME/zeus-install.git
   ```

4. Make the change and run the checks below.
   For a bug fix, first reproduce the problem, then verify that the fix stops it.
   Add or update tests for changed behavior and update the related documentation.
5. Review your diff and commit the change.
6. Push through the gate, with your feature branch name in place of `<branch>`:

   ```sh
   git push no-mistakes <branch>
   ```

7. Run `no-mistakes` to follow the pipeline and respond to its findings.
   It reviews, tests, and documents the change, then pushes the branch to your fork and opens the pull request against this repository.
8. Check the pull request description against the requirements below.
   Respond to review comments and run the checks again after changes.

Local checks help you find problems before the pipeline runs.
They do not replace no-mistakes: this repository checks its attestation on each pull request.

## Development and tests

Use a Mac with macOS 13.3 or later and the Xcode Command Line Tools (Swift 5.9 or later).
The app tests also use Node.js and Python 3.
Run these commands from the repository root.

Build a development app:

```sh
app/dev-bundle.sh
```

The output is `app/build/Zeus-dev.app`.
The first build downloads the whisper.cpp framework with the checksum in `app/Package.swift`.

Run the test command used by both [no-mistakes](.no-mistakes.yaml) and [CI](.github/workflows/ci.yml):

```sh
app/test/run-all.sh
```

It tests the PTY, plugin scope, app installation, self-update, upgrades, and the app on a simulated new Mac.
The app tests start real test app copies behind your other windows.
GitHub and installer downloads are simulated, and the tests use temporary home folders.
Allow about 25-30 minutes on a busy Mac.

For a UI change, also use the changed screen and check the result yourself.
See [app/README.md](app/README.md) for individual test commands, debug settings, and screenshot capture.

## Pull request requirements

Each pull request must include:

- A clear description of the problem and what the change does.
  Link the issue when there is one.
- The commands you ran and their results.
  Describe manual test steps, expected behavior, and what you observed.
  State any checks you could not run and why.
  A check you did not run is not a passing check.
- Screenshots for UI changes, with the old and new states when useful.
  Use test data and remove private information.
- Tests for changed behavior and documentation that matches the result.

Do not submit a generated diff that you cannot explain or have not tested.
Fix failing tests and review findings before asking for merge.

## Review and merge

Each pull request runs two checks:

- `Tests`: `app/test/run-all.sh` on a macOS runner.
- `PR must be raised via no-mistakes`: the pull request body must have a completed no-mistakes attestation for the current head commit.
  Keep that attestation in the body when you edit the description.

Only the maintainer merges pull requests.
Before merge, a human reviewer must approve the change, review findings must be resolved, and both checks must pass for the latest commit.
Passing automated checks does not replace human review.
`.github/CODEOWNERS` makes the maintainer the owner of all files.
