#!/usr/bin/env python3
"""그날의 Claude Code 세션 트랜스크립트에서 '일지 근거'만 뽑아낸다.

트랜스크립트(~/.claude/projects/**/*.jsonl)는 세션 하나가 40MB 를 넘기도 하므로
원문을 프롬프트에 넣지 않는다. 여기서는 이벤트만 추출한다:
  - 사용자가 내린 지시/질문 (= '왜'의 최우선 근거)
  - 편집·생성한 파일 (= '무엇을')
  - 실행한 명령의 description (= '어떻게')
  - 세션 마지막 결론 (= '그래서 어떻게 됐나')

사용법: extract_sessions.py <TRACK_REPO> [YYYY-MM-DD] [제외할_디렉터리_이름조각] [총_글자수_상한]
"""
import json
import os
import sys
import datetime
from collections import Counter

# 세션당 상한 — 프롬프트 예산을 지키기 위한 값
MAX_SESSIONS = 12
MAX_PROMPTS = 25
MAX_FILES = 15
MAX_CMDS = 8
PROMPT_CHARS = 400
CONCLUSION_CHARS = 400

SKIP_PREFIXES = (
    "<",                                  # system-reminder, command-name 등 하네스 삽입 블록
    "Caveat:",
    "This session is being continued",    # 컨텍스트 압축 요약
    "[Request interrupted",
)
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit"}
SELF_MARK = "[worklog-auto]"   # worklog 가 제 요약 프롬프트에 심는 표식 (daily.sh / rollup.sh)


def is_real_prompt(text):
    t = text.strip()
    if not t or len(t) < 2:
        return False
    if t.startswith(SKIP_PREFIXES):
        return False
    if t.startswith("/"):                 # 슬래시 커맨드는 의도를 담지 않음
        return False
    return True


def user_text(msg):
    """user 메시지에서 사람이 실제로 친 텍스트만 꺼낸다 (tool_result 는 제외)."""
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = [b.get("text", "") for b in c
                 if isinstance(b, dict) and b.get("type") == "text"]
        return "\n".join(parts)
    return ""


def local_date(ts):
    """트랜스크립트 timestamp 는 UTC ISO('...Z') 이고 우리는 로컬(KST) 날짜로 일지를 쓴다.
    문자열 비교로 두면 로컬 00~09시 작업이 전날 UTC 로 밀려 통째로 누락된다."""
    try:
        return datetime.datetime.fromisoformat(
            ts.replace("Z", "+00:00")).astimezone().date().isoformat()
    except Exception:
        return ""


def scan(path, day, repo, skip=""):
    """트랜스크립트 하나에서 대상 날짜(로컬 기준)의 이벤트를 뽑는다."""
    prompts, files, cmds, conclusion = [], Counter(), [], ""
    cwd = ""
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") not in ("user", "assistant"):
            continue
        if local_date(o.get("timestamp", "")) != day:
            continue
        c = o.get("cwd", "")
        if not c.startswith(repo) or (skip and skip in c):
            continue
        cwd = cwd or c
        if o.get("isSidechain"):          # 서브에이전트 내부 대화는 의도가 아니다
            continue

        if o.get("type") == "user":
            if o.get("isCompactSummary"):
                continue
            t = user_text(o.get("message", {}))
            if is_real_prompt(t):
                prompts.append(" ".join(t.split())[:PROMPT_CHARS])
        else:
            blocks = o.get("message", {}).get("content")
            if not isinstance(blocks, list):
                continue
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    name, inp = b.get("name"), b.get("input", {})
                    if not isinstance(inp, dict):
                        continue
                    if name in EDIT_TOOLS and inp.get("file_path"):
                        files[inp["file_path"].replace(repo + "/", "")] += 1
                    elif name == "Bash" and inp.get("description"):
                        cmds.append(inp["description"])
                elif b.get("type") == "text" and b.get("text", "").strip():
                    conclusion = b["text"]      # 마지막 것이 남는다
    # worklog 자신의 헤드리스 실행도 트랜스크립트를 남긴다. 그대로 두면 백필 시
    # "일지를 정리했다"가 그날의 작업으로 둔갑하므로 세션 통째로 제외한다.
    if any(SELF_MARK in p for p in prompts):
        return cwd, [], Counter(), [], ""
    return cwd, prompts, files, cmds, conclusion


def main():
    repo = sys.argv[1]
    day = sys.argv[2] if len(sys.argv) > 2 else datetime.date.today().isoformat()
    skip = sys.argv[3] if len(sys.argv) > 3 else ""   # 기록에서 뺄 디렉터리 이름 조각
    budget = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else 0   # 0 = 상한 없음
    root = os.path.expanduser("~/.claude/projects")
    if not os.path.isdir(root):
        return

    # 대상 날짜(로컬 00:00) 이후에 수정된 파일만 본다 — 그 전에 끝난 세션은 그날 기록을 가질 수 없다
    cutoff = datetime.datetime.fromisoformat(day + "T00:00:00").timestamp()

    sessions = []
    for dirpath, _, names in os.walk(root):
        for n in names:
            if not n.endswith(".jsonl"):
                continue
            p = os.path.join(dirpath, n)
            try:
                if os.path.getmtime(p) < cutoff:
                    continue
                cwd, prompts, files, cmds, conclusion = scan(p, day, repo, skip)
            except Exception:
                continue
            if prompts or files:
                sessions.append((len(prompts) + len(files), cwd, prompts, files, cmds, conclusion, n))

    sessions.sort(reverse=True, key=lambda s: s[0])
    blocks = []
    for _, cwd, prompts, files, cmds, conclusion, name in sessions[:MAX_SESSIONS]:
        out = []
        out.append(f"\n#### 세션 {name[:8]} · {cwd or repo} · 지시 {len(prompts)}건")
        if prompts:
            out.append("[지시/질문]")
            out += [f"- {p}" for p in prompts[:MAX_PROMPTS]]
            if len(prompts) > MAX_PROMPTS:
                out.append(f"- …외 {len(prompts) - MAX_PROMPTS}건")
        if files:
            out.append("[편집한 파일]")
            out += [f"- {f} ({n}회)" for f, n in files.most_common(MAX_FILES)]
            if len(files) > MAX_FILES:
                out.append(f"- …외 {len(files) - MAX_FILES}개")
        if cmds:
            seen, uniq = set(), []
            for c in cmds:
                if c not in seen:
                    seen.add(c)
                    uniq.append(c)
            out.append("[실행]")
            out += [f"- {c}" for c in uniq[:MAX_CMDS]]
        if conclusion:
            out.append("[세션 마지막 정리]")
            out.append("- " + " ".join(conclusion.split())[:CONCLUSION_CHARS])
        blocks.append("\n".join(out))

    # 상한은 바이트가 아니라 글자 수로, 세션 경계에서만 자른다.
    # (예전엔 셸의 head -c 로 잘라 한글이 3배로 깎이고 마지막 세션이 글자 중간에서 끊겼다)
    # 근거가 많은 세션부터 담고, 남는 세션은 머리줄만 남겨 그런 작업이 있었다는 것은 전한다.
    used, kept = 0, []
    for b in blocks:
        head = b.split("\n", 2)[1]
        if budget and used + len(b) > budget:
            b = head + " (예산 초과로 내용 생략)"
        kept.append(b)
        used += len(b)
    print("\n".join(kept))


if __name__ == "__main__":
    main()
