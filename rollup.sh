#!/usr/bin/env bash
# 일일 일지를 주간/월간으로 굴리고 INDEX.md 를 갱신한다.
# 일일 기록은 "그날 무엇을 했나"의 원본이고, 롤업은 "그래서 이 기간에 뭐가 진행됐나"를 보는 단위다.
#
#   rollup.sh week  [YYYY-MM-DD]   그 날짜가 속한 주(월~일) 요약  → YYYY-MM/weekly-YYYY-Www.md
#   rollup.sh month [YYYY-MM]      그 달 요약                    → YYYY-MM/SUMMARY.md
#   rollup.sh index                INDEX.md 재생성 (모델 호출 없음)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "${WORKLOG_CONF:-$SCRIPT_DIR/worklog.conf}" ] && . "${WORKLOG_CONF:-$SCRIPT_DIR/worklog.conf}"
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

# ── INDEX.md: 각 일지의 TL;DR 한 줄을 모아 전체 흐름을 한 화면에 ──
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
  echo "INDEX.md 갱신 완료 ($(grep -c '^| \[' "$WORKLOG_DIR/INDEX.md") 일)"
  exit 0
fi

# ── 기간 결정 ──
if [ "$MODE" = "week" ]; then
  REF="${2:-$(date +%Y-%m-%d)}"
  DOW=$(date -d "$REF" +%u)                       # 1=월 … 7=일
  START=$(date -d "$REF -$((DOW - 1)) days" +%Y-%m-%d)
  END=$(date -d "$START +6 days" +%Y-%m-%d)
  LABEL="$(date -d "$START" +%Y)-W$(date -d "$START" +%V)"
  OUTFILE="$WORKLOG_DIR/${START%-*}/weekly-$LABEL.md"
  TITLE="주간 요약 $LABEL ($START ~ $END)"
  [ "$LANGUAGE" = "en" ] && TITLE="Weekly summary $LABEL ($START ~ $END)"
  SPAN="이번 주"
elif [ "$MODE" = "month" ]; then
  M="${2:-$(date +%Y-%m)}"
  START="$M-01"
  END=$(date -d "$START +1 month -1 day" +%Y-%m-%d)
  LABEL="$M"
  OUTFILE="$WORKLOG_DIR/$M/SUMMARY.md"
  TITLE="월간 요약 $M"
  [ "$LANGUAGE" = "en" ] && TITLE="Monthly summary $M"
  SPAN="이번 달"
else
  echo "사용법: $0 {week [YYYY-MM-DD] | month [YYYY-MM] | index}" >&2; exit 1
fi

# ── 해당 기간 일지 수집 ──
BODY=""; N=0
D="$START"
while [ "$D" != "$(date -d "$END +1 day" +%Y-%m-%d)" ]; do
  F="$WORKLOG_DIR/${D%-*}/$D.md"
  if [ -f "$F" ]; then
    BODY="$BODY

--------- $D ---------
$(cat "$F")"
    N=$((N + 1))
  fi
  D=$(date -d "$D +1 day" +%Y-%m-%d)
done

if [ "$N" -eq 0 ]; then
  echo "[skip] $START ~ $END 구간에 일지가 없습니다."; exit 0
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

echo "[$TITLE] 일지 ${N}일치 → 요약 생성 중…"
OUT=$(timeout "$TIMEOUT_SEC" "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --append-system-prompt "$SYS" --tools "" 2>/dev/null)
[ -z "$OUT" ] && { echo "[error] 요약 생성 실패"; exit 1; }

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
echo "생성: $OUTFILE"

make_index > "$WORKLOG_DIR/INDEX.md"
echo "INDEX.md 갱신 완료"
