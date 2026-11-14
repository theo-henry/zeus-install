# Contributing to the Zeus installer

Many people use Zeus.
These rules keep each change small, checked, and reviewed.

## Report a problem or an idea

Open an issue in [theo-henry/zeus](https://github.com/theo-henry/zeus/issues), the intake repository for all Zeus repositories.
The maintainer triages each issue and moves it to the repository that owns it.
Do not open a pull request to report a problem.

Write what you did, what you expected, and what happened.
Do not put client data in an issue: no rows, values, screenshots, project names, URLs, emails, or keys.

## Change the code

1. Fork this repository and push your branch to your fork, not to this repository.
2. Install [no-mistakes](https://github.com/kunchenguid/no-mistakes) and run `no-mistakes init --fork-url <your fork URL>` in your clone.
3. Raise the pull request through no-mistakes: `git push no-mistakes <branch>`.
   The pipeline reviews, tests, and documents the change, then opens the pull request with its attestation in the body.

Each pull request runs two checks:

- `Tests`: the PTY, plugin scope, and install tests in `app/test` on a macOS runner (the `test` command in `.no-mistakes.yaml`).
- `PR must be raised via no-mistakes`: the pull request body must have a completed no-mistakes attestation for the current head commit.
  A pull request that does not come from no-mistakes fails this check.

## Who merges

Only the maintainer merges pull requests.
The maintainer merges only pull requests with passing checks.
`.github/CODEOWNERS` makes the maintainer the owner of all files.
