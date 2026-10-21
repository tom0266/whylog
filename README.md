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
- **Heals itself.** If the server was down or a summary failed, the next run fills in any of the last 3 days that are missing.
- **Quiet days are free.** With no activity, it writes a one-line entry without calling the model.
- **Rollups.** Weekly and monthly summaries, plus an `INDEX.md` with one TL;DR line per day.
- **Your own archive.** Plain Markdown in a git repo you own, versioned and pushed to a private remote.
- **Korean or English.** Set `LANGUAGE` in `whylog.conf`.

## Quick start

Requirements: Linux, [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` CLI, logged in), `git`, `python3`, `cron`. Optional: `gh`, to create the private GitHub repo for you. macOS is not supported yet (the scripts use GNU `date -d` and `timeout`).

```bash
git clone https://github.com/tom0266/whylog ~/whylog
cd ~/whylog
vi whylog.conf        # usually fine as is (see below)
bash install.sh
```

`install.sh` checks the requirements, prepares the log repo, optionally creates a private GitHub repo, takes the baseline code snapshot, registers the cron jobs and does a dry run. It is safe to run again.

> After cloning, `origin` points at this tool repo. `install.sh` detaches it automatically, so your logs are never pushed here. You can also click **Use this template** instead of cloning.

To change the run time: `CRON_TIME="30 19" bash install.sh` (minute hour; the default `0 22` is 10 pm).

## Configuration (`whylog.conf`)

| Key | Default | Description |
|---|---|---|
| `TRACK_REPO` | `$HOME` | Folder to track. Code/doc changes and Claude Code sessions under it are logged |
| `WORKLOG_DIR` | (this folder) | Where the logs are kept |
| `MODEL` | `opus` | Summarizing model. Use `sonnet` to save usage |
| `LANGUAGE` | `ko` | Log language: `ko` or `en` |
| `CLAUDE_BIN` | (auto) | Path to the `claude` executable |
| `DIFF_BUDGET` etc. | 60000 / 6000 / 40 | Caps on how much code diff goes into the prompt |
| `SESS_BUDGET` | 30000 | Cap on the session evidence |
| `SKIP_DIR` | (empty) | Sessions whose path contains this string are not logged |

## How it knows what you did

It relies on two kinds of evidence.

**What changed: code snapshots.** Every night it snapshots the tracked folder into `.snapshot.git`, a separate git repo inside the log repo, so "today's diff against yesterday's snapshot" is exactly what you changed. Using `git status` of the work folder instead would report months of uncommitted changes as "today's work" in repos that are rarely committed.

A day's diff can run to hundreds of thousands of characters, so files are included **largest change first, each with its own cap**. Simply truncating the diff fails, because git orders paths alphabetically: dot-folders such as editor settings use up the budget and no research code gets in. That happened on a real day.

**Why: session transcripts.** From `~/.claude/projects/**/*.jsonl` it extracts only that day's events: your instructions and questions, the files that were edited, the commands that ran, and how each session ended. The raw transcripts, which can exceed 40 MB per session, never go into the prompt. This evidence is what pairs each "what" with its "why".

Commits made that day, including those in independent git repos directly under `TRACK_REPO`, are added as supporting evidence.

## Usage

| Task | Command |
|---|---|
| Write today's log now | `bash daily.sh` |
| Preview without writing | `bash daily.sh --dry-run` |
| Recover a missed day | `bash daily.sh --date 2026-08-13` |
| Weekly summary | `bash rollup.sh week` |
| Monthly summary | `bash rollup.sh month 2026-08` |
| Rebuild the index | `bash rollup.sh index` |

The weekly summary also runs on Sunday nights, and `INDEX.md` is refreshed after every daily run.

If a summary is wrong, ask Claude in any session to "fix that part of today's log".

## Layout

```
whylog/
├── whylog.conf          # settings: edit this file if your setup differs
├── install.sh           # installer (idempotent)
├── daily.sh             # daily log (cron, nightly)
├── rollup.sh            # weekly/monthly summaries + INDEX (cron, Sunday)
├── extract_sessions.py  # session transcripts → events
├── examples/            # sample outputs
├── INDEX.md             # one TL;DR line per day
└── YYYY-MM/YYYY-MM-DD.md
```

## Privacy and good to know

- **Keep your log repo private.** It records what you did and why: unpublished results, failed attempts and the reasoning behind decisions. That honesty is what makes the log useful, and making it public invites self-censorship. To share, keep the original private and export only the weekly summaries.
- **Code diffs and your prompts are sent to Claude** when the summary is generated. If your organization restricts sending code outside, limit `TRACK_REPO` accordingly.
- To exclude a folder from tracking, add it to `.snapshot.git/info/exclude`. Editor and terminal settings folders are excluded by default.
- If `.claude/` is in your work folder's `.gitignore`, work on skills and agents will not appear in the code diff. It still shows up in the session evidence.
- Sessions after the nightly run are not in that day's log. Their code changes appear in the next day's diff. Move `CRON_TIME` later if you often work late.

## Uninstall

```bash
crontab -l | grep -v -e whylog/daily.sh -e whylog/rollup.sh | crontab -
```

If you installed into a folder not named `whylog`, use that folder name instead. Then delete the folder if you no longer need the logs.

## License

[MIT](LICENSE)

Unofficial community project. Not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.
