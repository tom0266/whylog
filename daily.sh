#!/usr/bin/env bash
# claude(헤드리스)가 그날 실제 작업을 상세 서술형으로 일지에 기록한다.
# "오늘 한 일" 정확도의 두 축:
#   1) 무엇을 바꿨나 → 일지 저장소의 .snapshot.git 로 매일 스냅샷을 떠 "어제 대비 diff" 계산
#   2) 왜 했나       → 그날 세션 트랜스크립트에서 지시·편집·실행·결론을 추출
# 설정은 같은 폴더의 whylog.conf 에서 읽는다 (없으면 아래 기본값).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "${WHYLOG_CONF:-$SCRIPT_DIR/whylog.conf}" ] && . "${WHYLOG_CONF:-$SCRIPT_DIR/whylog.conf}"

# ===== 기본값 (whylog.conf 가 이미 정했으면 그대로 둔다) =====
: "${TRACK_REPO:=$HOME}"                 # 일지에 기록할 작업 저장소 루트
: "${WORKLOG_DIR:=$SCRIPT_DIR}"          # 일지 저장소 (이 스크립트가 있는 곳)
: "${MODEL:=opus}"                       # 상세 요약 모델
: "${DIFF_BUDGET:=60000}"                # 프롬프트에 넣을 diff 총량(자). 하루 1회 호출이라 여유 있게.
: "${DIFF_PER_FILE:=6000}"               # 파일 하나가 예산을 독점하지 못하게 하는 상한(자)
: "${DIFF_MAX_FILES:=40}"                # diff 본문을 실을 최대 파일 수 (나머지는 --stat 으로만 전달)
: "${SESS_BUDGET:=30000}"                # 세션 트랜스크립트에서 뽑은 근거의 상한(자)
: "${TIMEOUT_SEC:=600}"
: "${SKIP_DIR:=}"                        # 기록에서 뺄 디렉터리 이름 조각 (빈 값이면 제외 없음)
: "${LANGUAGE:=ko}"                      # 일지 언어: ko | en
SNAP="$WORKLOG_DIR/.snapshot.git"        # 코드/문서 전용 스냅샷 저장소 (일일 diff용)
if [ "$LANGUAGE" = "en" ]; then
  SYS="You are a non-interactive summarizer. Never ask questions. Use only the text the user gives you and output an English summary immediately. If information is missing, summarize what is there."
else
  SYS="너는 비대화형 요약기다. 되묻지 않는다. 오직 사용자가 준 텍스트만 근거로 한국어 요약을 즉시 출력하라. 정보가 부족하면 있는 것만으로 요약하라."
fi

# claude 실행 파일: cron 은 .bashrc 를 읽지 않아 PATH 에 없을 수 있으므로 직접 찾는다
if [ -z "${CLAUDE_BIN:-}" ]; then
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
  [ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
fi
if [ ! -x "${CLAUDE_BIN:-}" ]; then
  echo "[error] claude executable not found. Set CLAUDE_BIN in whylog.conf." >&2
  exit 1
fi
# ================

# --dry-run          : 일지·스냅샷·git 을 전혀 건드리지 않고 결과만 출력 (설정 검증용)
# --date YYYY-MM-DD  : 과거 날짜 백필. 그날 스냅샷 커밋과 직전 스냅샷 커밋의 차이를 근거로 재생성한다
#                      (cron 이 서버 다운 등으로 걸렀을 때 복구용)
# --init-snapshot    : 스냅샷 저장소만 만들고 끝낸다 (install.sh 용, 모델 호출 없음)
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

  # 오늘 이미 기록됐으면 건너뜀 (cron 중복 방지). 표식은 언어와 무관하게 성공 머리글 "## 🤖 "
  # (실패 머리글은 "## ⚠️ " 라서 다음 실행이 다시 시도한다)
  if grep -q "^## 🤖 " "$LOGFILE" 2>/dev/null; then
    echo "[$DATE] already written → skip"; exit 0
  fi
fi

# ── 결손 가드: 최근 3일 중 기록이 빠진 날이 있으면 먼저 백필한다 ──
# (서버 다운·재부팅으로 22:00 을 놓쳐도 다음 실행이 스스로 메운다. 자식은 --date 로 돌아 재귀하지 않는다.)
# 첫 설치 직후에는 과거 일지가 없으므로 백필이 의미 없다(빈 날 3개를 모델로 쓰게 된다).
# 오늘 파일은 위에서 이미 만들어졌으니 판단에서 제외한다.
PRIOR_LOG=$(ls "$WORKLOG_DIR"/20*/20*.md 2>/dev/null | grep -v "/$DATE\.md$" | head -1)
if [ "$DRY_RUN" -eq 0 ] && [ -z "$TARGET_DATE" ] && [ -n "$PRIOR_LOG" ]; then
  for back in 3 2 1; do
    D=$(date -d "$back days ago" +%Y-%m-%d 2>/dev/null) || continue
    F="$WORKLOG_DIR/${D%-*}/$D.md"
    if ! grep -q "^## 🤖 " "$F" 2>/dev/null; then
      echo "[$DATE] missing log for $D → backfilling"
      bash "$0" --date "$D" || echo "[$DATE] backfill of $D failed — skipped"
    fi
  done
fi

# ── 스냅샷 저장소 초기화 (최초 1회) ──
if [ ! -d "$SNAP" ]; then
  git --git-dir="$SNAP" init -q
  cat > "$SNAP/info/exclude" <<'EOF'
/wandb/
node_modules/
.next/
# 개발환경/에디터 리소스 — 연구 작업이 아니므로 diff 예산에서 제외
/.antigravity-ide-server/
/.antigravity-server/
/.warp/
/.vscode/
/.vscode-R/
/.npm-global/
/.pki/
/.agents/
# 기록하고 싶지 않은 폴더는 여기에 추가하세요
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
  # 일지 저장소가 작업 폴더 안에 있으면 스냅샷에서 뺀다 — 안 빼면 어제 일지가 오늘의 '코드 변경'으로 잡힌다
  case "$WORKLOG_DIR" in "$TRACK_REPO"/*) echo "/${WORKLOG_DIR#"$TRACK_REPO"/}/" >> "$SNAP/info/exclude" ;; esac
fi
[ "$INIT_ONLY" -eq 1 ] && exit 0

# 스냅샷 명령 헬퍼 (-C 로 pathspec을 저장소 루트 기준으로 해석)
snap() { git --git-dir="$SNAP" --work-tree="$TRACK_REPO" -C "$TRACK_REPO" "$@"; }

# ── (1) 그날의 코드 변경분(="무엇을") ──
# 평시: 작업 트리를 스테이징해 직전 스냅샷 커밋과 비교
# 백필: 그날 스냅샷 커밋 ↔ 직전 스냅샷 커밋 을 비교 (작업 트리는 이미 그날 상태가 아니므로 못 씀)
HAD_PREV=$(snap rev-parse -q --verify HEAD || true)
# 같은 날 다시 돌리는 경우(앞선 요약 실패 후 재실행 등): 오늘 스냅샷이 이미 커밋돼 있어
# 작업 트리 대비 diff 는 비어 버린다 → 백필과 같은 방식으로 그날 스냅샷 커밋끼리 비교한다
TODAY_SNAP=""
[ -z "$TARGET_DATE" ] && TODAY_SNAP=$(snap log --format='%H %s' 2>/dev/null | awk -v d="$DATE" '$2=="snapshot" && $3==d {print $1; exit}')
if [ -n "$TARGET_DATE" ] || [ -n "$TODAY_SNAP" ]; then
  END_C=$(snap log --format='%H %s' 2>/dev/null | awk -v d="$DATE" '$2=="snapshot" && $3==d {print $1; exit}')
  # 직전 '스냅샷' 커밋을 고른다 — housekeeping 등 다른 커밋을 base 로 잡으면 무관한 변경이 섞인다
  BASE_C=""
  [ -n "$END_C" ] && BASE_C=$(snap log --format='%H %s' "$END_C" 2>/dev/null | awk -v d="$DATE" '$2=="snapshot" && $3<d {print $1; exit}')
  if [ -n "$END_C" ] && [ -n "$BASE_C" ]; then
    DIFF_RANGE="$BASE_C $END_C"
  else
    # 그날 스크립트가 아예 안 돌아 스냅샷이 없는 경우 — 결손 복구가 필요한 바로 그 상황이다.
    # 코드 diff 는 포기하고 세션 트랜스크립트만으로 작성한다.
    DIFF_RANGE=""
    echo "[warn] no snapshot commit for $DATE — writing from session evidence only, without a code diff" >&2
  fi
else
  # 패턴별로 따로 add 한다: git add 는 pathspec 하나라도 매칭 0이면 fatal 로 전체를 취소하므로,
  # 한꺼번에 넘기면 그날 해당 확장자가 없다는 이유만으로 diff 가 통째로 비어 버린다.
  for pat in '*.py' '*.md' '*.sh' '*.ipynb' '*.tex' '*.R' '*.yaml' '*.yml'; do
    snap add -A -- "$pat" 2>/dev/null || true
  done
  DIFF_RANGE="--cached"
fi

DIFF_STAT=""; DIFF_BODY=""
if [ -n "$HAD_PREV" ] && [ -n "$DIFF_RANGE" ]; then
  DIFF_STAT=$(snap diff $DIFF_RANGE --stat 2>/dev/null | tail -200)
  # 변경량이 큰 파일부터 파일당 상한을 두고 담는다.
  # (전역 head -c 는 git diff 의 경로 알파벳순 때문에 뒷글자 경로만 잘려 나갔다)
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
  :                          # 백필·재실행은 스냅샷을 갱신하지 않는다
elif [ "$DRY_RUN" -eq 1 ]; then
  snap reset -q              # 드라이런은 스냅샷 이력을 건드리지 않는다
else
  snap commit -q -m "snapshot $DATE $TIME" >/dev/null 2>&1 || true
fi

# ── (2) 그날의 세션 활동 (=의도 '왜' + 실제 행위 '무엇을') : 세션 트랜스크립트에서 이벤트 추출 ──
SESSIONS=$(python3 "$SCRIPT_DIR/extract_sessions.py" "$TRACK_REPO" "$DATE" "$SKIP_DIR" "$SESS_BUDGET" 2>/dev/null)

# ── (2-보조) history.jsonl — 트랜스크립트가 없거나 형식이 바뀐 경우의 폴백 ──
# project 는 세션의 cwd 이므로 하위 디렉터리까지 잡으려면 prefix 로 비교해야 한다.
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

# 오늘 실제 커밋 + 보조로 오늘 수정된 파일(mtime)
COMMITS=$(cd "$TRACK_REPO" && git log --since="$DATE 00:00" --until="$DATE 23:59" --pretty=format:'- %h %an %s' 2>/dev/null)
# 바로 아래의 독립 저장소(프로젝트별 git)의 커밋도 모은다 — 일지 저장소 자신은 제외
for g in "$TRACK_REPO"/*/.git; do
  r=$(dirname "$g"); [ "$r" -ef "$WORKLOG_DIR" ] && continue
  c=$(git -C "$r" log --since="$DATE 00:00" --until="$DATE 23:59" --pretty=format:"- [$(basename "$r")] %h %an %s" 2>/dev/null)
  [ -n "$c" ] && COMMITS="${COMMITS:+$COMMITS
}$c"
done
# mtime 은 '지금'을 기준으로만 의미가 있다 — 백필에서는 오늘 파일이 과거 날짜에 섞이므로 쓰지 않는다
MTIME_FILES=""
[ -z "$TARGET_DATE" ] && MTIME_FILES=$(cd "$TRACK_REPO" && find . -type f \( -name '*.py' -o -name '*.md' -o -name '*.sh' -o -name '*.ipynb' -o -name '*.tex' -o -name '*.R' \) \
  -mmin -960 -not -path './.git/*' -not -path "./${WORKLOG_DIR#"$TRACK_REPO"/}/*" \
  -not -path '*/node_modules/*' -not -path '*/.next/*' \
  -not -path './.antigravity-ide-server/*' -not -path './.antigravity-server/*' \
  -not -path './.warp/*' -not -path './.vscode*' 2>/dev/null | head -80)

# ── 코드 변경(무엇을) 근거: 상황별 ──
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

# ── 프롬프트 구성 ──
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
# 지시문은 한국어 하나로 유지하고, 영어 일지는 출력 언어와 라벨만 바꿔 받는다
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

# 근거가 하나도 없는 날(휴일 등)은 모델을 부르지 않는다 — 부르면 "기록 없음"을 길게 써 사용량만 쓴다
if [ -z "$SESSIONS$PROMPTS$DIFF_STAT$COMMITS$MTIME_FILES" ]; then
  [ "$LANGUAGE" = "en" ] && NARRATIVE="**TL;DR**: No recorded activity." || NARRATIVE="**TL;DR**: 기록된 작업 없음."
else
  NARRATIVE=$(timeout "$TIMEOUT_SEC" "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --append-system-prompt "$SYS" --tools "" 2>/dev/null)
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
    # 실패 머리글은 🤖 가 아니다 — 다음 실행(결손 가드)이 이 날을 다시 시도하게 한다
    [ "$LANGUAGE" = "en" ] && echo "## ⚠️ Claude summary failed → files modified today ($TIME)" || echo "## ⚠️ Claude 자동 요약 실패 → 오늘 수정된 파일 ($TIME)"
    echo '```'
    echo "${MTIME_FILES:-없음}"
    echo '```'
  fi
  echo ""
} >> "$LOGFILE"

# INDEX 갱신 — 모델 호출이 없어 비용이 들지 않으므로 매일 돌려 최신 상태를 유지한다
bash "$SCRIPT_DIR/rollup.sh" index >/dev/null 2>&1 || echo "[warn] INDEX update failed"

# 일지 저장소에 커밋 & push
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
