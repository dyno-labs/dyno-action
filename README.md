# dyno Action

Checks each game in your repo's `dyno.toml` with [dyno](https://dynoapp.io), and uploads the results to dynoapp.io. It needs no secret: it uses the run's GitHub OIDC token.

This repository is private for now, so only workflows in `dyno-labs` repos can use it. Until it is public, the setup pull request that dynoapp.io opens writes the same steps into the workflow itself.

## Before you use it

1. Install the dyno-cloud GitHub App from dynoapp.io, Settings, GitHub, and connect the repo there.
2. Pick the games there too. dynoapp.io opens a pull request that adds `dyno.toml`, with each game's id, name and build folder.

The site only takes results from a repo that you connected. It refuses a run from a pull request of a fork, and such a run gets no OIDC token, so the Action skips it with a notice and passes.

## Use

Build the games first. The Action checks the build folders that `dyno.toml` names, and does not build them.

```yaml
name: dyno

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

jobs:
  dyno:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      # Build the games here.
      - uses: dyno-labs/dyno-action@v1
```

`id-token: write` lets the job ask GitHub for OIDC tokens. Without it, the Action skips with a notice.

## Inputs

| Input         | Default | What it does                                                                                                                                                        |
| ------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `games`       | empty   | The games of `dyno.toml` to check, by id or name, one per line or with commas between them. Empty checks every game.                                                |
| `report-only` | `true`  | When true, a game that fails, is incomplete or is invalid still passes the job. A game that dyno cannot check, or a result that does not upload, fails the job either way. |
| `version`     | latest  | The dyno to download, `latest` or a commit's full sha.                                                                                                              |

The output `results` is the folder that holds each game's result, as `<game id>.json`.

## What it does

1. It asks GitHub for an OIDC token with the audience `https://dynoapp.io`, and downloads dyno for Linux on x86-64 from `https://dynoapp.io/api/dist/<version>/x86_64-unknown-linux-gnu`. It checks the archive against the SHA-256 that the site gives.
2. For each game, it runs `dyno check <build> --browser --out <game id>.json`. dyno serves the build folder to its own Chromium, the Google Chrome on GitHub's runners, so the browser loads the files that dyno scanned.
3. It asks GitHub for a fresh token, because a token lasts only minutes, and runs `dyno upload` with it in `DYNO_TOKEN`.
4. It writes a table of the games to the job summary, and uploads the results as the artifact `dyno-<job id>`.

The Action runs on Linux on x86-64, and needs `curl`, `python3` 3.11 or newer, and Google Chrome or Chromium. GitHub's Ubuntu runners have them. On GitHub's own runners it lets Chromium's sandbox make user namespaces, which Ubuntu 24.04 limits.

## Tests

`test/test.sh` runs `dyno.sh` against a fake dynoapp.io, a fake GitHub token service and a fake dyno, on your own machine. It needs `bash`, `curl` and `python3`.
