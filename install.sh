#!/usr/bin/env bash
# whylog installer — after this one script, the daily log runs on its own.
# Safe to run again (idempotent).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/whylog.conf"
CRON_TIME="${CRON_TIME:-0 22}"        # default: daily at 22:00. e.g. CRON_TIME="30 19" ./install.sh

say()  { echo "  $*"; }
fail() { echo "[error] $*" >&2; exit 1; }

echo "== whylog install =="

# ── 1. Requirements ──
echo "[1/6] Checking requirements"
command -v git     >/dev/null || fail "git not found."
command -v python3 >/dev/null || fail "python3 not found."
command -v crontab >/dev/null || fail "crontab not found."
CLAUDE_FOUND=$(command -v claude 2>/dev/null || true)
[ -z "$CLAUDE_FOUND" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_FOUND="$HOME/.local/bin/claude"
[ -z "$CLAUDE_FOUND" ] && fail "claude CLI not found. Install Claude Code and run again."
say "claude: $CLAUDE_FOUND"

# ── 2. Config ──
echo "[2/6] Reading config"
[ -f "$CONF" ] || fail "whylog.conf not found ($CONF)"
# shellcheck source=/dev/null
. "$CONF"
: "${TRACK_REPO:=$HOME}"
: "${WORKLOG_DIR:=$SCRIPT_DIR}"
say "Tracked folder (TRACK_REPO): $TRACK_REPO"
say "Log repo (WORKLOG_DIR): $WORKLOG_DIR"
say "Model: ${MODEL:-opus} / language: ${LANGUAGE:-ko} / schedule: ${CRON_TIME} (min hour)"
[ -d "$TRACK_REPO" ] || fail "TRACK_REPO does not exist: $TRACK_REPO"
mkdir -p "$WORKLOG_DIR"

# ── 3. Log repo (git) ──
echo "[3/6] Preparing the log repo"
if [ ! -d "$WORKLOG_DIR/.git" ]; then
  git -C "$WORKLOG_DIR" init -q
  git -C "$WORKLOG_DIR" checkout -q -b main 2>/dev/null || true
  printf 'cron.log\n.snapshot.git/\n' > "$WORKLOG_DIR/.gitignore"
  say "git repo created"
else
  say "git repo already exists"
fi

# If the tool repo was cloned, origin points at someone else's repo, and every night
# your log would be pushed there — so detach it, but only in that case.
# (A repo created from the template has your own origin; leave it alone.)
TOOL_REPO=$(cat "$SCRIPT_DIR/.whylog-template" 2>/dev/null)
if [ -n "$TOOL_REPO" ] && [ -d "$WORKLOG_DIR/.git" ]; then
  CUR_ORIGIN=$(git -C "$WORKLOG_DIR" remote get-url origin 2>/dev/null || true)
  case "$CUR_ORIGIN" in
    *"$TOOL_REPO"*)
      git -C "$WORKLOG_DIR" remote remove origin
      say "Removed the tool repo origin (so your logs are never pushed there)" ;;
  esac
fi

if ! git -C "$WORKLOG_DIR" remote get-url origin >/dev/null 2>&1; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    read -r -p "  Create a private GitHub repo for your logs? (enter a repo name, or Enter to skip) " REPO
    if [ -n "${REPO:-}" ]; then
      gh repo create "$REPO" --private --source "$WORKLOG_DIR" --remote origin \
        && gh auth setup-git \
        && say "Remote connected: $REPO"
    else
      say "No remote; logs stay local."
    fi
  else
    say "gh not installed or not logged in → logs stay local (add one later with git remote add origin)."
  fi
else
  say "Remote: $(git -C "$WORKLOG_DIR" remote get-url origin)"
fi

# ── 4. Snapshot repo ──
echo "[4/6] Preparing the code snapshot repo"
SNAP="$WORKLOG_DIR/.snapshot.git"
if [ ! -d "$SNAP" ]; then
  say "Taking the first snapshot (this is the baseline; exact daily diffs start tomorrow)"
  bash "$SCRIPT_DIR/daily.sh" --init-snapshot >/dev/null 2>&1   # create the snapshot repo with its excludes (no model call)
  snap() { git --git-dir="$SNAP" --work-tree="$TRACK_REPO" -C "$TRACK_REPO" "$@"; }
  for pat in '*.py' '*.md' '*.sh' '*.ipynb' '*.tex' '*.R' '*.yaml' '*.yml'; do
    snap add -A -- "$pat" 2>/dev/null || true
  done
  snap commit -q -m "snapshot baseline $(date +%Y-%m-%d\ %H:%M)" >/dev/null 2>&1 || true
  say "Baseline committed ($(snap ls-files | wc -l) files tracked)"
else
  say "Snapshot repo already exists ($(git --git-dir="$SNAP" ls-files | wc -l) files tracked)"
fi

# ── 5. Register cron jobs ──
echo "[5/6] Registering cron jobs"
# cron doesn't read .bashrc, so set PATH on our lines only (never touch a crontab-wide PATH=)
CPATH="PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
LINE="${CRON_TIME} * * * $CPATH /bin/bash $SCRIPT_DIR/daily.sh >> $WORKLOG_DIR/cron.log 2>&1"
# Weekly summary on Sunday, 30 minutes after the daily run, so the week's last day is included
CM=${CRON_TIME%% *}; CH=${CRON_TIME#* }
WM=$(( (CM + 30) % 60 )); WH=$(( (CH + (CM + 30) / 60) % 24 ))
WLINE="$WM $WH * * 0 $CPATH /bin/bash $SCRIPT_DIR/rollup.sh week >> $WORKLOG_DIR/cron.log 2>&1"
# Replace only lines that call this folder's scripts (other jobs, even another rollup.sh, stay)
CUR=$(crontab -l 2>/dev/null | grep -v -F -e "$SCRIPT_DIR/daily.sh" -e "$SCRIPT_DIR/claude_log.sh" -e "$SCRIPT_DIR/rollup.sh" || true)
printf '%s\n%s\n%s\n' "$CUR" "$LINE" "$WLINE" | grep -v '^$' | crontab -
say "daily : $LINE"
say "weekly: $WLINE"

# ── 6. Test run ──
echo "[6/6] Test run (--dry-run, nothing is written)"
bash "$SCRIPT_DIR/daily.sh" --dry-run 2>&1 | head -8

cat <<EOF

== Done ==
Your daily log will be written every day at ${CRON_TIME#* }:$(printf '%02d' "${CRON_TIME%% *}").

  Write today's log now : bash $SCRIPT_DIR/daily.sh
  Preview only          : bash $SCRIPT_DIR/daily.sh --dry-run
  Recover a missed day  : bash $SCRIPT_DIR/daily.sh --date YYYY-MM-DD
  Weekly summary        : bash $SCRIPT_DIR/rollup.sh week
EOF
