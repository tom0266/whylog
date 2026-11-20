#!/usr/bin/env bash
# whylog installer — after this one script, the daily log runs on its own.
# Safe to run again (idempotent).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${WHYLOG_CONF:-$SCRIPT_DIR/whylog.conf}"   # WHYLOG_CONF lets the config live outside the tool folder
CRON_TIME="${CRON_TIME:-0 22}"        # default: daily at 22:00. e.g. CRON_TIME="30 19" ./install.sh

# "09" is read as octal by the arithmetic below, so normalise with 10# and check the range here
# rather than registering a broken cron line.
case "$CRON_TIME" in
  [0-9]*' '[0-9]*) ;;
  *) echo "[error] CRON_TIME must be \"<minute> <hour>\", e.g. CRON_TIME=\"30 19\" (got: $CRON_TIME)" >&2; exit 1 ;;
esac
CRON_MIN=$((10#${CRON_TIME%% *})); CRON_HOUR=$((10#${CRON_TIME#* }))
if [ "$CRON_MIN" -lt 0 ] || [ "$CRON_MIN" -gt 59 ] || [ "$CRON_HOUR" -lt 0 ] || [ "$CRON_HOUR" -gt 23 ]; then
  echo "[error] CRON_TIME out of range: minute $CRON_MIN, hour $CRON_HOUR" >&2; exit 1
fi
CRON_TIME="$CRON_MIN $CRON_HOUR"

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
# git needs an identity or every commit fails with "Please tell me who you are". The snapshot repo
# carries its own, but the log repo uses yours, so say something now instead of failing nightly.
if ! git config --get user.email >/dev/null 2>&1 || ! git config --get user.name >/dev/null 2>&1; then
  say "note: git user.name/user.email are not set. Log commits will use a fallback identity."
  say "      To use your own:  git config --global user.name 'You'; git config --global user.email you@example.com"
fi

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
CUR_ORIGIN=$(git -C "$WORKLOG_DIR" remote get-url origin 2>/dev/null || true)
if [ -n "$TOOL_REPO" ] && [ -n "$CUR_ORIGIN" ]; then
  case "$CUR_ORIGIN" in
    *"$TOOL_REPO"*)
      git -C "$WORKLOG_DIR" remote remove origin
      CUR_ORIGIN=""
      say "Removed the tool repo origin (so your logs are never pushed there)" ;;
  esac
fi

# A fork or a repo made from the template is public unless you chose otherwise, and the nightly run
# pushes to origin. Check before that happens rather than after a month of logs is online.
if [ -n "$CUR_ORIGIN" ]; then
  # gh wants owner/repo; normalise ssh and .git forms or an SSH remote falls through as "unknown"
  SLUG=$(printf '%s' "$CUR_ORIGIN" | sed -E -e 's#\.git$##' -e 's#^git@[^:]*:##' -e 's#^[a-z+]+://[^/]*/##')
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    VIS=$(gh repo view "$SLUG" --json isPrivate -q .isPrivate 2>/dev/null || echo unknown)
    case "$VIS" in
      false) fail "origin is a PUBLIC repo: $CUR_ORIGIN
  Your daily logs would be published. Fix it one of these ways, then run install again:
    gh repo edit $CUR_ORIGIN --visibility private --accept-visibility-change-consequences
    git -C $WORKLOG_DIR remote set-url origin <a private repo>
    git -C $WORKLOG_DIR remote remove origin      # keep the logs local only" ;;
      true)  say "Remote: $CUR_ORIGIN (private)" ;;
      *)     say "Remote: $CUR_ORIGIN — visibility could not be checked. Make sure it is private." ;;
    esac
  else
    say "Remote: $CUR_ORIGIN — gh is unavailable, so visibility was not checked. Make sure it is private."
  fi
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
fi

# ── 4. Snapshot repo ──
echo "[4/6] Preparing the code snapshot repo"
SNAP="$WORKLOG_DIR/.snapshot.git"
if [ ! -d "$SNAP" ]; then
  say "Taking the first snapshot (this is the baseline; exact daily diffs start tomorrow)"
  bash "$SCRIPT_DIR/daily.sh" --init-snapshot >/dev/null 2>&1   # create the snapshot repo with its excludes (no model call)
  # Same fixed identity as daily.sh, so the baseline commit works without a global git config
  snap() {
    git -c user.name=whylog -c user.email=whylog@localhost -c core.quotepath=false \
        --git-dir="$SNAP" --work-tree="$TRACK_REPO" -C "$TRACK_REPO" "$@"
  }
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
# cron doesn't read .bashrc, so set PATH on our lines only (never touch a crontab-wide PATH=).
# The folder claude was found in goes first: npm-global, nvm and Homebrew all live outside the
# default list, and without this the nightly run fails with "claude executable not found".
CBIN_DIR=$(dirname "$CLAUDE_FOUND")
CPATH_DIRS="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
case ":$CPATH_DIRS:" in *":$CBIN_DIR:"*) ;; *) CPATH_DIRS="$CBIN_DIR:$CPATH_DIRS" ;; esac
CPATH="PATH=$CPATH_DIRS"
# Quote the paths (a folder name may contain spaces) and escape % (cron reads it as a newline).
esc() { printf '%s' "$1" | sed 's/%/\\%/g'; }
DSH=$(esc "$SCRIPT_DIR/daily.sh"); RSH=$(esc "$SCRIPT_DIR/rollup.sh"); CLOG=$(esc "$WORKLOG_DIR/cron.log")
# Carry WHYLOG_CONF into cron when the config lives outside the tool folder; cron reads no profile
CONF_ENV=""
[ -n "${WHYLOG_CONF:-}" ] && CONF_ENV="WHYLOG_CONF='$(esc "$WHYLOG_CONF")' "
LINE="${CRON_TIME} * * * $CPATH $CONF_ENV/bin/bash '$DSH' >> '$CLOG' 2>&1"
# Weekly summary 30 minutes after the daily run, so the week's last day is included. If that
# crosses midnight the run belongs to Monday — on Sunday it would precede Sunday's own log.
WM=$(( (CRON_MIN + 30) % 60 )); CARRY=$(( (CRON_MIN + 30) / 60 ))
WH=$(( (CRON_HOUR + CARRY) % 24 ))
WDOW=$(( (CRON_HOUR + CARRY) / 24 == 0 ? 0 : 1 ))
# Landing on Monday means the Sunday run crossed midnight, so ask for the week that just ended —
# plain "week" would summarise the week that had only just started.
WARG="week"; [ "$WDOW" -eq 1 ] && WARG="week last"
WLINE="$WM $WH * * $WDOW $CPATH $CONF_ENV/bin/bash '$RSH' $WARG >> '$CLOG' 2>&1"
# Monthly summary on the 1st, for the month that just ended
MLINE="$WM $WH 1 * * $CPATH $CONF_ENV/bin/bash '$RSH' month last >> '$CLOG' 2>&1"
# Replace only lines that call this folder's scripts (other jobs, even another rollup.sh, stay)
CUR=$(crontab -l 2>/dev/null | grep -v -F -e "$SCRIPT_DIR/daily.sh" -e "$SCRIPT_DIR/claude_log.sh" -e "$SCRIPT_DIR/rollup.sh" || true)
printf '%s\n%s\n%s\n%s\n' "$CUR" "$LINE" "$WLINE" "$MLINE" | grep -v '^$' | crontab -
say "daily  : $LINE"
say "weekly : $WLINE"
say "monthly: $MLINE"

# ── 6. Test run ──
echo "[6/6] Test run (--dry-run, nothing is written)"
bash "$SCRIPT_DIR/daily.sh" --dry-run 2>&1 | head -8

cat <<EOF

== Done ==
Your daily log will be written every day at $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MIN").

  Write today's log now : bash $SCRIPT_DIR/daily.sh
  Preview only          : bash $SCRIPT_DIR/daily.sh --dry-run
  Recover a missed day  : bash $SCRIPT_DIR/daily.sh --date YYYY-MM-DD
  Weekly summary        : bash $SCRIPT_DIR/rollup.sh week
EOF
