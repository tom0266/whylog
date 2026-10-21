#!/usr/bin/env bash
# Writes a detailed narrative log of the day's actual work, using headless claude.
# Two kinds of evidence keep "what I did today" accurate:
#   1) What changed → a nightly snapshot in the log repo's .snapshot.git gives "diff since yesterday"
#   2) Why          → prompts, edits, commands and conclusions extracted from the day's session transcripts
# Settings come from whylog.conf in the same folder (defaults below otherwise).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "${WHYLOG_CONF:-$SCRIPT_DIR/whylog.conf}" ] && . "${WHYLOG_CONF:-$SCRIPT_DIR/whylog.conf}"

# ===== Defaults (kept as-is if whylog.conf already set them) =====
: "${TRACK_REPO:=$HOME}"                 # root of the work folder to log
: "${WORKLOG_DIR:=$SCRIPT_DIR}"          # log repo (where this script lives)
: "${MODEL:=opus}"                       # summarizing model
: "${DIFF_BUDGET:=60000}"                # total diff size in the prompt (chars); generous, it's one call a day
: "${DIFF_PER_FILE:=6000}"               # per-file cap so one file can't eat the budget (chars)
: "${DIFF_MAX_FILES:=40}"                # max files with diff bodies (the rest appear in --stat only)
: "${SESS_BUDGET:=30000}"                # cap on session evidence (chars)
: "${TIMEOUT_SEC:=600}"
: "${SKIP_DIR:=}"                        # skip sessions whose path contains this (empty = none)
: "${LANGUAGE:=ko}"                      # log language: ko | en
SNAP="$WORKLOG_DIR/.snapshot.git"        # code/docs-only snapshot repo (for the daily diff)
if [ "$LANGUAGE" = "en" ]; then
  SYS="You are a non-interactive summarizer. Never ask questions. Use only the text the user gives you and output an English summary immediately. If information is missing, summarize what is there."
else
  SYS="너는 비대화형 요약기다. 되묻지 않는다. 오직 사용자가 준 텍스트만 근거로 한국어 요약을 즉시 출력하라. 정보가 부족하면 있는 것만으로 요약하라."
fi

# Find claude ourselves: cron doesn't read .bashrc, so it may not be on PATH
if [ -z "${CLAUDE_BIN:-}" ]; then
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
  [ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
fi
if [ ! -x "${CLAUDE_BIN:-}" ]; then
  echo "[error] claude executable not found. Set CLAUDE_BIN in whylog.conf." >&2
  exit 1
fi
# ================

# --dry-run          : print the result only; touches no log, snapshot or git (for checking setup)
# --date YYYY-MM-DD  : backfill a past day from the diff between that day's snapshot commit and the previous one
#                      (recovery when cron missed a night, e.g. the server was down)
# --init-snapshot    : create the snapshot repo and exit (for install.sh; no model call)
DRY_RUN=0; TARGET_DATE=""; INIT_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --date)    shift; TARGET_DATE="${1:-}" ;;
    --init-snapshot) INIT_ONLY=1; DRY_RUN=1 ;;
    *) echo "usage: $0 [--dry-run] [--date YYYY-MM-DD]" >&2; exit 1 ;;
  esac
  shift
done

DATE="${TARGET_DATE:-$(date +%Y-%m-%d)}"
TIME=$(date +%H:%M)
MONTH="${DATE%-*}"
LOGDIR="$WORKLOG_DIR/$MONTH"
LOGFILE="$LOGDIR/$DATE.md"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$LOGDIR"

  if [ ! -f "$LOGFILE" ]; then
    if [ "$LANGUAGE" = "en" ]; then
      printf '# %s Work Log\n\n_Written automatically every night. If something is wrong, ask Claude to fix that part._\n\n---\n' "$DATE" > "$LOGFILE"
    else
      printf '# %s 작업 일지\n\n_매일 밤 자동으로 기록됩니다. 틀린 내용이 있으면 Claude에게 "이 부분 고쳐줘"라고 하면 됩니다._\n\n---\n' "$DATE" > "$LOGFILE"
    fi
  fi

  # Skip if today is already written (guards against duplicate cron runs). The marker is the
  # success header "## 🤖 " in any language; the failure header is "## ⚠️ ", so the next run retries.
  if grep -q "^## 🤖 " "$LOGFILE" 2>/dev/null; then
    echo "[$DATE] already written → skip"; exit 0
  fi
fi

# ── Gap guard: backfill any of the last 3 days that has no log yet ──
# (If the nightly run was missed because of downtime or a reboot, the next run fills it in.
#  Children run with --date, so this does not recurse.)
# Right after installation there are no past logs, so backfilling would only write 3 empty days.
# Today's file was just created above, so it is left out of that check.
PRIOR_LOG=$(ls "$WORKLOG_DIR"/20*/20*.md 2>/dev/null | grep -v "/$DATE\.md$" | head -1)
if [ "$DRY_RUN" -eq 0 ] && [ -z "$TARGET_DATE" ] && [ -n "$PRIOR_LOG" ]; then
  for back in 3 2 1; do
    D=$(python3 -c 'import datetime as dt,sys; print(dt.date.today()-dt.timedelta(days=int(sys.argv[1])))' "$back")
    F="$WORKLOG_DIR/${D%-*}/$D.md"
    if ! grep -q "^## 🤖 " "$F" 2>/dev/null; then
      echo "[$DATE] missing log for $D → backfilling"
      bash "$0" --date "$D" || echo "[$DATE] backfill of $D failed — skipped"
    fi
  done
fi

# ── Create the snapshot repo (first run only) ──
if [ ! -d "$SNAP" ]; then
  git --git-dir="$SNAP" init -q
  cat > "$SNAP/info/exclude" <<'EOF'
/wandb/
node_modules/
.next/
# dev environment / editor files — not research work, keep them out of the diff budget
/.antigravity-ide-server/
/.antigravity-server/
/.warp/
/.vscode/
/.vscode-R/
/.npm-global/
/.pki/
/.agents/
# add folders you don't want logged here
*.csv
*.parquet
*.pt
*.ckpt
*.npz
*.zip
*.xlsx
*.xls
*.pdf
*.png
*.jpg
*.db
*.sqlite
EOF
  # Exclude the log repo if it sits inside the work folder; otherwise yesterday's log shows up as today's 'code change'
  case "$WORKLOG_DIR" in "$TRACK_REPO"/*) echo "/${WORKLOG_DIR#"$TRACK_REPO"/}/" >> "$SNAP/info/exclude" ;; esac
fi
[ "$INIT_ONLY" -eq 1 ] && exit 0

# Snapshot helper (-C makes pathspecs relative to the work folder root)
snap() { git --git-dir="$SNAP" --work-tree="$TRACK_REPO" -C "$TRACK_REPO" "$@"; }

# ── (1) The day's code changes (= "what") ──
# Normal run: stage the work tree and compare with the previous snapshot commit
# Backfill:   compare that day's snapshot commit with the one before (the work tree is no longer in that day's state)
HAD_PREV=$(snap rev-parse -q --verify HEAD || true)
# Re-running on the same day (e.g. after a failed summary): today's snapshot is already committed,
# so a diff against the work tree would be empty → compare snapshot commits, as in a backfill
TODAY_SNAP=""
[ -z "$TARGET_DATE" ] && TODAY_SNAP=$(snap log --format='%H %s' 2>/dev/null | awk -v d="$DATE" '$2=="snapshot" && $3==d {print $1; exit}')
if [ -n "$TARGET_DATE" ] || [ -n "$TODAY_SNAP" ]; then
  END_C=$(snap log --format='%H %s' 2>/dev/null | awk -v d="$DATE" '$2=="snapshot" && $3==d {print $1; exit}')
  # Pick the previous *snapshot* commit; using any other commit as the base mixes in unrelated changes
  BASE_C=""
  [ -n "$END_C" ] && BASE_C=$(snap log --format='%H %s' "$END_C" 2>/dev/null | awk -v d="$DATE" '$2=="snapshot" && $3<d {print $1; exit}')
  if [ -n "$END_C" ] && [ -n "$BASE_C" ]; then
    DIFF_RANGE="$BASE_C $END_C"
  else
    # The script never ran that day, so there is no snapshot — exactly the case backfill exists for.
    # Give up on the code diff and write from session transcripts only.
    DIFF_RANGE=""
    echo "[warn] no snapshot commit for $DATE — writing from session evidence only, without a code diff" >&2
  fi
else
  # Add each pattern separately: git add aborts entirely if any pathspec matches nothing, so passing
  # them together would empty the whole diff just because one extension wasn't touched that day.
  for pat in '*.py' '*.md' '*.sh' '*.ipynb' '*.tex' '*.R' '*.yaml' '*.yml'; do
    snap add -A -- "$pat" 2>/dev/null || true
  done
  DIFF_RANGE="--cached"
fi

DIFF_STAT=""; DIFF_BODY=""
if [ -n "$HAD_PREV" ] && [ -n "$DIFF_RANGE" ]; then
  DIFF_STAT=$(snap diff $DIFF_RANGE --stat 2>/dev/null | tail -200)
  # Take files largest-change first, each with its own cap.
  # (A global head -c cut by git's alphabetical path order, so later paths were always dropped.)
  DIFF_BODY=$(
    snap diff $DIFF_RANGE --numstat --no-renames -- '*.py' '*.sh' '*.md' '*.R' '*.tex' 2>/dev/null \
      | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1+$2 "\t" $3 }' \
      | sort -k1,1nr | head -"$DIFF_MAX_FILES" | cut -f2 \
      | while IFS= read -r f; do
          printf '\n===== %s =====\n' "$f"
          snap diff $DIFF_RANGE -- "$f" 2>/dev/null | head -c "$DIFF_PER_FILE"
        done | head -c "$DIFF_BUDGET"
  )
fi

if [ -n "$TARGET_DATE" ] || [ -n "$TODAY_SNAP" ]; then
  :                          # backfills and re-runs don't advance the snapshot
elif [ "$DRY_RUN" -eq 1 ]; then
  snap reset -q              # dry runs leave snapshot history alone
else
  snap commit -q -m "snapshot $DATE $TIME" >/dev/null 2>&1 || true
fi

# ── (2) The day's session activity (intent = 'why', actions = 'what'), extracted from transcripts ──
SESSIONS=$(python3 "$SCRIPT_DIR/extract_sessions.py" "$TRACK_REPO" "$DATE" "$SKIP_DIR" "$SESS_BUDGET" 2>/dev/null)

# ── (2b) history.jsonl — fallback if transcripts are missing or their format changed ──
# 'project' is the session's cwd, so compare by prefix to include subfolders.
PROMPTS=$(python3 - "$TRACK_REPO" "$DATE" "$SKIP_DIR" <<'PY' 2>/dev/null
import json, os, sys, datetime
repo, day = sys.argv[1], sys.argv[2]
skip = sys.argv[3] if len(sys.argv) > 3 else ""
hist = os.path.expanduser("~/.claude/history.jsonl")
start = int(datetime.datetime.combine(datetime.date.fromisoformat(day), datetime.time()).timestamp() * 1000)
end = start + 86400 * 1000
out = []
try:
    with open(hist) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            proj = str(o.get("project") or "")
            if not (start <= o.get("timestamp", 0) < end):
                continue
            if not proj.startswith(repo) or (skip and skip in proj):
                continue
            d = (o.get("display") or "").strip()
            if d and not d.startswith("/") and d not in ("exit", "quit"):
                out.append("- " + " ".join(d.split())[:300])
except FileNotFoundError:
    pass
print("\n".join(out[:80]))
PY
)

# Today's commits, plus files modified today (mtime) as a secondary signal
COMMITS=$(cd "$TRACK_REPO" && git log --since="$DATE 00:00" --until="$DATE 23:59" --pretty=format:'- %h %an %s' 2>/dev/null)
# Also collect commits from independent repos directly below (one git per project), except the log repo
for g in "$TRACK_REPO"/*/.git; do
  r=$(dirname "$g"); [ "$r" -ef "$WORKLOG_DIR" ] && continue
  c=$(git -C "$r" log --since="$DATE 00:00" --until="$DATE 23:59" --pretty=format:"- [$(basename "$r")] %h %an %s" 2>/dev/null)
  [ -n "$c" ] && COMMITS="${COMMITS:+$COMMITS
}$c"
done
# mtime only means something relative to now — skip it in backfills, or today's files leak into a past day
MTIME_FILES=""
[ -z "$TARGET_DATE" ] && MTIME_FILES=$(cd "$TRACK_REPO" && find . -type f \( -name '*.py' -o -name '*.md' -o -name '*.sh' -o -name '*.ipynb' -o -name '*.tex' -o -name '*.R' \) \
  -mmin -960 -not -path './.git/*' -not -path "./${WORKLOG_DIR#"$TRACK_REPO"/}/*" \
  -not -path '*/node_modules/*' -not -path '*/.next/*' \
  -not -path './.antigravity-ide-server/*' -not -path './.antigravity-server/*' \
  -not -path './.warp/*' -not -path './.vscode*' 2>/dev/null | head -80)

# ── Code-change ('what') evidence, by situation ──
if [ -n "$HAD_PREV" ] && [ -n "$DIFF_STAT" ]; then
  CHANGE_GUIDE="'무엇을'은 아래 '어제 이후 실제 코드 변경(diff)'을 근거로 하세요."
  CHANGE_CTX="### 어제 이후 실제 코드 변경 (= 오늘 바꾼 것, '무엇을'의 근거)
${DIFF_STAT}

${DIFF_BODY}"
elif [ -n "$TARGET_DATE" ]; then
  CHANGE_GUIDE="그날의 코드 diff 는 남아 있지 않습니다(스냅샷 결손). 아래 세션 기록만을 근거로, 무엇을 왜 했는지 사실만 적고 코드 변경의 규모·파일명을 지어내지 마세요."
  CHANGE_CTX="### 코드 변경 근거 없음 (스냅샷 결손일)"
elif [ -n "$HAD_PREV" ]; then
  CHANGE_GUIDE="추적 코드에 변경이 없습니다. 아래 프롬프트/수정파일만으로, 오늘 어느 프로젝트를 다뤘는지만 사실로 적으세요."
  CHANGE_CTX="### 오늘 수정된 파일 (mtime 16시간 내)
${MTIME_FILES:-없음}"
else
  CHANGE_GUIDE="오늘은 스냅샷 첫 실행이라 '어제 대비 코드 변경분'을 알 수 없습니다. 아래 프롬프트와 '오늘 수정된 파일'만 근거로, 오늘 어느 프로젝트/무엇을 다뤘는지 사실만 적고, 파일 삭제·신규 추가 같은 건 지어내지 마세요. 상세 diff는 내일부터 정확합니다."
  CHANGE_CTX="### 오늘 수정된 파일 (mtime 16시간 내)
${MTIME_FILES:-없음}"
fi

# ── Build the prompt ──
PROMPT="[worklog-auto] 당신은 한 연구자의 일일 작업 일지를 대신 정리하는 조수입니다. ${CHANGE_GUIDE}

'왜(의도)·기대효과·계기(어떤 오류·문제)'는 **'그날의 세션 기록'을 최우선 근거**로 삼고, 커밋 메시지·코드 주석·계획 노트로 보완하세요. 세션 기록의 [편집한 파일]과 코드 diff 를 연결해, 어떤 지시가 어떤 변경으로 이어졌는지 짝지어 서술하세요. 근거 없이 diff 모양만으로 추론한 부분은 '(추정)'을 붙이고, 근거가 전혀 없으면 왜/기대효과는 비워 두세요(지어내지 말 것).

출력 형식(반드시 이 순서):
1. \`**TL;DR**: \` 한 줄 — 오늘의 핵심 성과.
2. \`**오늘의 흐름**: \` 2~3문장 — 무엇을 왜 했고 어떻게 이어졌는지 서사적으로(항목 나열 금지, 인과로 연결).
3. 프로젝트/주제별 소제목 + 불릿. 각 주요 항목은 가능한 한 **무엇을 / 왜 / 기대효과 / 계기**로.
규칙: (a) 나열하지 말고 요약 — 사소한 변경은 개별 나열 말고 '기타'로 묶고, 실질적인 작업 위주로. (b) 흩어진 사실을 인과로 연결(예: 'X 때문에 Y를 고쳤고 그 결과 Z'). (c) .vscode/.warp/.npm 등 개발환경 설정 변경 제외. (d) 서론/맺음말 없이 본문만.

### 그날의 세션 기록 (의도·'왜'의 최우선 근거)
세션별로 [지시/질문]=사용자가 실제로 요구한 것, [편집한 파일]=그 요구로 실제 손댄 파일,
[실행]=돌린 작업, [세션 마지막 정리]=그 세션이 어떻게 끝났는지 입니다.
${SESSIONS:-${PROMPTS:-없음}}

${CHANGE_CTX}

### 오늘 커밋
${COMMITS:-없음}"
# Keep one (Korean) instruction set; for English logs, only switch the output language and labels
[ "$LANGUAGE" = "en" ] && PROMPT="$PROMPT

[Output language] Write the entire log in English. Use these labels instead of the Korean ones above: **TL;DR**, **Today's flow**, and What / Why / Effect / Trigger. Group minor changes under 'Other'."

if [ "$DRY_RUN" -eq 1 ]; then
  echo "===== [DRY-RUN] evidence ====="
  echo "prompt: ${#PROMPT} chars (diff body ${#DIFF_BODY} / budget ${DIFF_BUDGET})"
  echo "changed files: $(printf '%s' "$DIFF_STAT" | tail -1)"
  echo "files with diff body: $(printf '%s' "$DIFF_BODY" | LC_ALL=C grep -ac '^===== ')"
  echo "session evidence: ${#SESSIONS} chars / $(printf '%s' "$SESSIONS" | LC_ALL=C grep -ac '^#### 세션') sessions (history.jsonl fallback: $(printf '%s' "${PROMPTS:-}" | LC_ALL=C grep -ac '^- ') prompts)"
  echo
fi

# No evidence at all (a day off, say): don't call the model — it would only spend usage writing "nothing happened"
if [ -z "$SESSIONS$PROMPTS$DIFF_STAT$COMMITS$MTIME_FILES" ]; then
  [ "$LANGUAGE" = "en" ] && NARRATIVE="**TL;DR**: No recorded activity." || NARRATIVE="**TL;DR**: 기록된 작업 없음."
else
  TO=$(command -v timeout || command -v gtimeout || true)   # macOS has no timeout by default
  NARRATIVE=$(${TO:+"$TO" "$TIMEOUT_SEC"} "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --append-system-prompt "$SYS" --tools "" 2>/dev/null)
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "===== [DRY-RUN] output (nothing written) ====="
  echo "${NARRATIVE:-(generation failed)}"
  exit 0
fi

{
  echo ""
  if [ -n "$NARRATIVE" ]; then
    [ "$LANGUAGE" = "en" ] && echo "## 🤖 Claude auto summary ($TIME)" || echo "## 🤖 Claude 자동 상세 요약 ($TIME)"
    echo ""
    echo "$NARRATIVE"
  else
    # The failure header is not 🤖, so the next run's gap guard retries this day
    [ "$LANGUAGE" = "en" ] && echo "## ⚠️ Claude summary failed → files modified today ($TIME)" || echo "## ⚠️ Claude 자동 요약 실패 → 오늘 수정된 파일 ($TIME)"
    echo '```'
    echo "${MTIME_FILES:-없음}"
    echo '```'
  fi
  echo ""
} >> "$LOGFILE"

# Refresh INDEX — no model call, so it's free to run daily
bash "$SCRIPT_DIR/rollup.sh" index >/dev/null 2>&1 || echo "[warn] INDEX update failed"

# Commit & push the log repo
cd "$WORKLOG_DIR" || exit 1
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "worklog: $DATE"
  if git remote get-url origin >/dev/null 2>&1; then
    git push -q origin main 2>/dev/null || echo "[warn] push failed"
  fi
fi
if [ -n "$NARRATIVE" ]; then
  echo "[$DATE $TIME] log written: $LOGFILE"
else
  echo "[$DATE $TIME] summary failed — the next run will retry: $LOGFILE" >&2
  exit 1
fi
