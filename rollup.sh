#!/usr/bin/env bash
# Rolls daily logs up into weekly/monthly summaries and refreshes INDEX.md.
# Daily logs are the record of "what I did that day"; rollups answer "so what moved forward in this period".
#
#   rollup.sh week  [YYYY-MM-DD]   summary of that date's week (Mon–Sun) → YYYY-MM/weekly-YYYY-Www.md
#   rollup.sh month [YYYY-MM]      summary of that month                → YYYY-MM/SUMMARY.md
#   rollup.sh index                rebuild INDEX.md (no model call)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "${WHYLOG_CONF:-$SCRIPT_DIR/whylog.conf}" ] && . "${WHYLOG_CONF:-$SCRIPT_DIR/whylog.conf}"
: "${WORKLOG_DIR:=$SCRIPT_DIR}"
: "${MODEL:=opus}"
: "${TIMEOUT_SEC:=600}"
: "${LANGUAGE:=ko}"
if [ -z "${CLAUDE_BIN:-}" ]; then
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
  [ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
fi
if [ "$LANGUAGE" = "en" ]; then
  SYS="You are a non-interactive summarizer. Never ask questions. Use only the text the user gives you and output an English summary immediately."
else
  SYS="너는 비대화형 요약기다. 되묻지 않는다. 오직 사용자가 준 텍스트만 근거로 한국어 요약을 즉시 출력하라."
fi

MODE="${1:-index}"

# ── INDEX.md: every log's TL;DR line, so the whole history fits on one screen ──
make_index() {
  python3 - "$WORKLOG_DIR" "$LANGUAGE" <<'PY'
import os, re, sys
root, lang = sys.argv[1], sys.argv[2]
en = lang == "en"
months = sorted([d for d in os.listdir(root) if re.fullmatch(r"\d{4}-\d{2}", d)], reverse=True)
out = ["# Work Log Index" if en else "# 작업 일지 인덱스", "",
       "One-line TL;DR per day. Click a date for details." if en else
       "각 날짜의 TL;DR 한 줄. 자세한 내용은 날짜 링크를 누르세요.", ""]
for m in months:
    mdir = os.path.join(root, m)
    days = sorted([f for f in os.listdir(mdir) if re.fullmatch(r"\d{4}-\d{2}-\d{2}\.md", f)], reverse=True)
    if not days:
        continue
    out.append(f"## {m}")
    extra = sorted(f for f in os.listdir(mdir) if f.startswith(("weekly-", "SUMMARY")))
    if extra:
        out.append(("Summaries: " if en else "요약: ") + " · ".join(f"[{os.path.splitext(f)[0]}]({m}/{f})" for f in extra))
    out.append("")
    out.append("| Date | TL;DR |" if en else "| 날짜 | TL;DR |")
    out.append("|---|---|")
    for d in days:
        tldr = ""
        with open(os.path.join(mdir, d), errors="replace") as fh:
            for line in fh:
                if "**TL;DR**" in line:
                    tldr = line.split("**TL;DR**", 1)[1].lstrip(": ").strip()
                    break
        tldr = tldr.replace("|", "\\|")
        if len(tldr) > 160:
            tldr = tldr[:160] + "…"
        out.append(f"| [{d[:-3]}]({m}/{d}) | {tldr or ('_(no summary)_' if en else '_(요약 없음)_')} |")
    out.append("")
print("\n".join(out))
PY
}

if [ "$MODE" = "index" ]; then
  make_index > "$WORKLOG_DIR/INDEX.md"
  echo "INDEX.md updated ($(grep -c '^| \[' "$WORKLOG_DIR/INDEX.md") days)"
  exit 0
fi

# ── Pick the period ──
if [ "$MODE" = "week" ]; then
  REF="${2:-$(date +%Y-%m-%d)}"
  # Mon–Sun week and ISO week number. Use the ISO year, or a year-end week collides with W01
  # (date's %Y-W%V labelled the week of 2024-12-30 as 2024-W01). python3 instead of GNU date -d.
  read -r START END LABEL < <(python3 - "$REF" <<'PY'
import datetime as dt, sys
r = dt.date.fromisoformat(sys.argv[1])
s = r - dt.timedelta(days=r.weekday())
y, w, _ = s.isocalendar()
print(s, s + dt.timedelta(days=6), f"{y}-W{w:02d}")
PY
)
  OUTFILE="$WORKLOG_DIR/${START%-*}/weekly-$LABEL.md"
  TITLE="주간 요약 $LABEL ($START ~ $END)"
  [ "$LANGUAGE" = "en" ] && TITLE="Weekly summary $LABEL ($START ~ $END)"
  SPAN="이번 주"
elif [ "$MODE" = "month" ]; then
  M="${2:-$(date +%Y-%m)}"
  START="$M-01"
  END=$(python3 -c 'import calendar,sys; y,m=map(int,sys.argv[1].split("-")); print(f"{y:04d}-{m:02d}-{calendar.monthrange(y,m)[1]:02d}")' "$M")
  LABEL="$M"
  OUTFILE="$WORKLOG_DIR/$M/SUMMARY.md"
  TITLE="월간 요약 $M"
  [ "$LANGUAGE" = "en" ] && TITLE="Monthly summary $M"
  SPAN="이번 달"
else
  echo "usage: $0 {week [YYYY-MM-DD] | month [YYYY-MM] | index}" >&2; exit 1
fi

# ── Collect the period's daily logs ──
BODY=""; N=0
DAYS=$(python3 -c 'import datetime as dt,sys; a,b=(dt.date.fromisoformat(x) for x in sys.argv[1:]); print(*(a+dt.timedelta(days=i) for i in range((b-a).days+1)))' "$START" "$END")
for D in $DAYS; do
  F="$WORKLOG_DIR/${D%-*}/$D.md"
  if [ -f "$F" ]; then
    BODY="$BODY

--------- $D ---------
$(cat "$F")"
    N=$((N + 1))
  fi
done

if [ "$N" -eq 0 ]; then
  echo "[skip] no daily logs between $START and $END"; exit 0
fi

PROMPT="[worklog-auto] 아래는 한 연구자의 일일 작업 일지 ${N}일치입니다. 이것을 ${SPAN} 단위 요약으로 다시 쓰세요.

목적: 날짜별 기록을 다 읽지 않아도 이 기간에 무엇이 어디까지 진행됐는지 알 수 있게 하는 것.

출력 형식(반드시 이 순서, 서론·맺음말 없이 본문만):
1. \`**핵심 성과**\` — 불릿 3개 이내. 이 기간에 '완료된' 것만.
2. \`**프로젝트별 진척**\` — 프로젝트마다 소제목 + 3~5줄. 시작 상태 → 무슨 일이 있었나 → 지금 상태 순으로 서술.
3. \`**다음 기간으로 넘어가는 것**\` — 미완·대기·막힌 것.

규칙: (a) 날짜별로 나열하지 말고 주제별로 묶어 인과로 서술. (b) 며칠에 걸쳐 이어진 작업은 하나의 흐름으로 합칠 것. (c) 하루짜리 사소한 변경은 생략. (d) 일지에 없는 내용을 지어내지 말 것.
${BODY}"
[ "$LANGUAGE" = "en" ] && PROMPT="$PROMPT

[Output language] Write the summary in English. Use these labels: **Key results**, **Progress by project**, **Carried over**."

echo "[$TITLE] summarizing ${N} daily logs…"
TO=$(command -v timeout || command -v gtimeout || true)   # macOS has no timeout by default
OUT=$(${TO:+"$TO" "$TIMEOUT_SEC"} "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --append-system-prompt "$SYS" --tools "" 2>/dev/null)
[ -z "$OUT" ] && { echo "[error] summary generation failed"; exit 1; }

mkdir -p "$(dirname "$OUTFILE")"
{
  echo "# $TITLE"
  echo
  if [ "$LANGUAGE" = "en" ]; then
    echo "_Generated from ${N} daily logs. Originals are the dated files in this folder._"
  else
    echo "_일일 일지 ${N}일치를 모아 자동 생성. 원본은 같은 폴더의 날짜별 파일._"
  fi
  echo
  echo "$OUT"
} > "$OUTFILE"
echo "written: $OUTFILE"

make_index > "$WORKLOG_DIR/INDEX.md"
echo "INDEX.md updated"
