# whylog

**English** | [한국어](README.ko.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/bash-%2B%20python3-4EAA25)
![Requires Claude Code](https://img.shields.io/badge/requires-Claude%20Code-555)
[![lint](https://github.com/tom0266/whylog/actions/workflows/lint.yml/badge.svg)](https://github.com/tom0266/whylog/actions/workflows/lint.yml)

**A daily research log that writes itself from your Claude Code sessions and code diffs.**

Work as usual. Every night, a log of what you did that day, and **why**, is written and pushed to your private GitHub repo. You never write it yourself.

```markdown
# 2026-08-13 Work Log

**TL;DR**: Cleaned up the data loader and found that the validation split was leaking.

**Today's flow**: Started out to speed up the slow data loader. While profiling it,
validation scores looked suspiciously high, so I compared the split code against the
config and confirmed that augmented copies of training samples were ending up in
validation. Fixed the split, then re-ran the baseline.

### Data pipeline — validation leak found and fixed
- **What**: Moved deduplication before the train/val split in `split.py`.
- **Why**: Augmented copies of the same sample were landing on both sides.
- **Effect**: Validation score dropped to a realistic level; earlier results need re-checking.
- **Trigger**: The question "why is val better than train?" during profiling.
```

More samples in [`examples/`](examples/): a full daily log, a weekly summary and the index.

## Features

- **Fully automatic.** A nightly cron job writes the log. No session needs to be open, and there is nothing to type.
- **What changed: a snapshot diff, not `git log`.** Uncommitted work and late commits are still captured correctly.
- **Why it changed: your sessions.** Your prompts, edited files, commands and each session's conclusion are extracted from Claude Code transcripts, so every change is paired with its intent.
- **Heals itself, within limits.** If the server was down or a summary failed, the next run fills in any of the last 3 days that are missing. A missed day is rebuilt from session transcripts only: its code diff is not recovered, and those changes land in the diff of the next normal run.
- **Quiet days are free.** With no activity, it writes a one-line entry without calling the model.
- **Rollups.** Weekly and monthly summaries, both scheduled in cron, plus an `INDEX.md` with one TL;DR line per day.
- **Your own archive.** Plain Markdown in a git repo you own, versioned and pushed to a private remote.
- **Korean or English.** Set `LANGUAGE` in `whylog.conf`.

## Quick start

Requirements: Linux or macOS, [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` CLI, logged in), `git`, `python3` (3.7 or newer; the code uses `datetime.fromisoformat`), `crontab`. Optional: `gh`, to create the private GitHub repo for you and to check that your remote is private; `timeout` (or `gtimeout` on macOS), which caps each model call at `TIMEOUT_SEC` seconds. Without it the call has no time limit. On macOS, cron may need Full Disk Access if your work folder is under Documents or Desktop. Linux is what it runs on daily; macOS has not been tested on a real machine yet.

```bash
git clone https://github.com/tom0266/whylog ~/whylog
cd ~/whylog
vi whylog.conf        # usually fine as is (see below)
bash install.sh
```

`install.sh` checks the requirements, prepares the log repo, optionally creates a private GitHub repo, takes the baseline code snapshot, registers the cron jobs and does a dry run. It is safe to run again. The dry run calls the model for real if there is any activity to summarize, so it can wait up to `TIMEOUT_SEC` seconds.

> After cloning, `origin` points at this tool repo. `install.sh` detaches it automatically, so your logs are never pushed here. You can also click **Use this template** instead of cloning. If you do, **choose Private** for the new repo. If `origin` is a public repo (checked with `gh`), `install.sh` stops without registering anything, and `daily.sh` refuses to push to an `origin` that points at the tool repo.

To change the run time: `CRON_TIME="30 19" bash install.sh` (minute hour; the default `0 22` is 10 pm). A leading zero such as `30 09` is fine; the format and range are checked.

The cron jobs are:

| Job | Schedule | Command |
|---|---|---|
| Daily log | `CRON_TIME` | `daily.sh` |
| Weekly summary | 30 minutes after the daily run, on Sunday | `rollup.sh week` |
| Monthly summary | 30 minutes after the daily run, on the 1st of each month | `rollup.sh month last` (the month that just ended) |

If 30 minutes after the daily run crosses midnight, the weekly job is registered for Monday instead of Sunday. The cron `PATH` starts with the folder `claude` was found in, then `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, `/usr/bin` and `/bin`, so npm-global, nvm and Homebrew installs work from cron. Output goes to `cron.log` in the log folder. If you move `claude`, run `install.sh` again.

Git `user.name` and `user.email` are not required. Without them, commits use `whylog <whylog@localhost>` and the installer only prints a note.

## Configuration (`whylog.conf`)

| Key | Default | Description |
|---|---|---|
| `TRACK_REPO` | `$HOME` | Folder to track. Code/doc changes and Claude Code sessions under it are logged |
| `WORKLOG_DIR` | (the folder whylog was cloned into) | Where the logs are kept |
| `MODEL` | `opus` | Summarizing model. Use `sonnet` to save usage |
| `LANGUAGE` | `ko` | Log language: `ko` or `en` |
| `CLAUDE_BIN` | (auto) | Path to the `claude` executable |
| `TIMEOUT_SEC` | 600 | Time limit for each model call, in seconds |
| `WHYLOG_CONF` | (`whylog.conf` beside `install.sh`) | Environment variable, not a key in the file. Path of the config file, for keeping it outside the tool folder. Read by `daily.sh`, `rollup.sh` and `install.sh`, and carried into the cron lines when it is set |
| `DIFF_BUDGET` etc. | 60000 / 6000 / 40 | Caps on how much code diff goes into the prompt |
| `SESS_BUDGET` | 30000 | Cap on the session evidence |
| `SKIP_DIR` | (empty) | Sessions, prompts, commits and modified-file entries whose path contains this string are not logged (comma-separated for several). It does **not** filter the code diff |
| `EXCLUDE` | (empty) | Extra folders to keep out of the code diff, as space-separated gitignore patterns on one line (e.g. `"/datasets/ /runs/*/outputs/"`). It filters the snapshot diff only |

## How it knows what you did

It relies on two kinds of evidence.

**What changed: code snapshots.** Every night it snapshots the tracked folder into `.snapshot.git`, a separate git repo inside the log repo, so "today's diff against yesterday's snapshot" is exactly what you changed. Using `git status` of the work folder instead would report months of uncommitted changes as "today's work" in repos that are rarely committed.

A day's diff can run to hundreds of thousands of characters, so files are included **largest change first, each with its own cap**. Simply truncating the diff fails, because git orders paths alphabetically: dot-folders such as editor settings use up the budget and no research code gets in. That happened on a real day.

**Why: session transcripts.** From `~/.claude/projects/**/*.jsonl` it extracts only that day's events: your instructions and questions, the files that were edited, the commands that ran, and how each session ended. The raw transcripts, which can exceed 40 MB per session, never go into the prompt. This evidence is what pairs each "what" with its "why".

Commits made that day, including those in independent git repos directly under `TRACK_REPO`, are added as supporting evidence. A day with no change still gets a snapshot commit (`--allow-empty`), so a quiet day is not later mistaken for a missing one. Paths with non-ASCII characters or spaces appear in the diff as written.

Before anything is sent, the diff and the session evidence pass through a filter that replaces secret-shaped strings with `[REDACTED]`: `sk-` and `ghp_`-style tokens, `AKIA` keys, `xox`-style tokens, `PRIVATE KEY` headers, and the value after `password=`, `token=`, `secret=` or `api_key=`. This is a net, not a guarantee. Commit messages are not filtered, and a secret in another shape gets through. Keep real secrets out of tracked files and prompts.

## Usage

| Task | Command |
|---|---|
| Write today's log now | `bash scripts/daily.sh` |
| Preview without writing | `bash scripts/daily.sh --dry-run` |
| Recover a missed day | `bash scripts/daily.sh --date 2026-08-13` |
| Weekly summary | `bash scripts/rollup.sh week` |
| Monthly summary | `bash scripts/rollup.sh month 2026-08` (`last` means the previous month) |
| Rebuild the index | `bash scripts/rollup.sh index` |

The weekly summary runs from cron on Sunday nights and the monthly one on the 1st (see Quick start), and `INDEX.md` is refreshed after every daily run.

If a summary is wrong, ask Claude in any session to "fix that part of today's log".

## Layout

```
whylog/
├── whylog.conf          # settings: edit this file if your setup differs
├── install.sh           # installer (idempotent)
├── scripts/
│   ├── daily.sh             # daily log (cron, nightly)
│   ├── rollup.sh            # weekly/monthly summaries + INDEX (cron, weekly and monthly)
│   ├── extract_sessions.py  # session transcripts → events
│   └── split_summary.py     # fallback: re-summarize per project when a summary is refused or malformed
├── .whylog-template     # name of this tool repo (used to keep your logs from being pushed here)
├── examples/            # sample outputs
├── cron.log             # output of the cron jobs (created on first run, not committed)
├── INDEX.md             # one TL;DR line per day
└── YYYY-MM/YYYY-MM-DD.md
```

## Privacy and good to know

- **Keep your log repo private.** It records what you did and why: unpublished results, failed attempts and the reasoning behind decisions. That honesty is what makes the log useful, and making it public invites self-censorship. To share, keep the original private and export only the weekly summaries.
- **Code diffs and your prompts are sent to Claude** when the summary is generated. If your organization restricts sending code outside, limit `TRACK_REPO` accordingly.
- `EXCLUDE` and `SKIP_DIR` cover different evidence, so neither alone keeps a folder out of the log. `EXCLUDE` (or `.snapshot.git/info/exclude` directly) removes files from the snapshot diff only. `SKIP_DIR` removes sessions, prompts, commits from repos directly under `TRACK_REPO`, and modified-file entries, but not the diff. For a sensitive folder, use both, and do not rely on either as a guarantee.
- The commit list of `TRACK_REPO` itself is not filtered by `SKIP_DIR`. Package and environment folders (conda, venv, `site-packages`) and editor settings are excluded by default, so installing a library never floods the day's diff.
- If `.claude/` is in your work folder's `.gitignore`, work on skills and agents will not appear in the code diff. It still shows up in the session evidence.
- Sessions after the nightly run are not in that day's log. Their code changes appear in the next day's diff. Move `CRON_TIME` later if you often work late.

## Troubleshooting

The first place to look is `cron.log` in the log folder (`tail -50 cron.log`). When a model call fails, the last lines of its error are written there as `[error] claude call failed:`.

| Symptom | What to check |
|---|---|
| The day's log has a `⚠️ Claude summary failed` header | The call failed. Read `cron.log` for the reason. The next run retries any of the last 3 days; for an older day, run `bash scripts/daily.sh --date YYYY-MM-DD` |
| Login expired or the model call is refused | Run `claude` once by hand to check that it is logged in, then retry with `bash scripts/daily.sh` |
| Usage limit reached | The call fails the same way and the day is retried on a later run. Use `MODEL="sonnet"` to spend less |
| `claude executable not found` in `cron.log` | cron has a minimal environment. Set `CLAUDE_BIN` in `whylog.conf`, or run `install.sh` again so the cron `PATH` includes the folder `claude` is in |
| Git identity errors | Not expected: commits fall back to `whylog <whylog@localhost>`. To use your own, set `git config --global user.name` and `user.email` |
| Install stops with "origin is a PUBLIC repo" | Make the repo private or point `origin` at a private one, as the message says, then run `install.sh` again |
| Unsure what would be sent | `bash scripts/daily.sh --dry-run` prints the evidence sizes and the summary without writing a log, a snapshot or a commit |

## Updating

In the default setup `install.sh` has removed `origin`, so `git pull` cannot fetch new versions. Add the tool repo as a second remote:

```bash
cd ~/whylog
git remote add upstream https://github.com/tom0266/whylog   # the name is also in .whylog-template
git pull upstream main
bash install.sh                                              # refreshes the cron lines; safe to repeat
```

If you edited `whylog.conf`, resolve any merge conflict in it. Keeping the config outside the folder with `WHYLOG_CONF` avoids this. Do not push to `upstream`.

## Uninstall

```bash
crontab -l | grep -v -e whylog/scripts/daily.sh -e whylog/scripts/rollup.sh | crontab -
```

If you installed into a folder not named `whylog`, use that folder name instead. Then delete the folder if you no longer need the logs.

## License

[MIT](LICENSE)

Unofficial community project. Not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.
