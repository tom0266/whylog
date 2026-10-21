#!/usr/bin/env python3
"""Extract only the log evidence from a day's Claude Code session transcripts.

A single transcript (~/.claude/projects/**/*.jsonl) can exceed 40 MB, so the raw text never
goes into the prompt. Only these events are extracted:
  - the user's instructions/questions (= the main evidence for 'why')
  - files edited or created (= 'what')
  - descriptions of commands run (= 'how')
  - the session's final message (= 'how it ended')

Usage: extract_sessions.py <TRACK_REPO> [YYYY-MM-DD] [SKIP_DIR] [CHAR_BUDGET]
"""
import json
import os
import sys
import datetime
from collections import Counter

# Per-session caps, to keep the prompt within budget
MAX_SESSIONS = 12
MAX_PROMPTS = 25
MAX_FILES = 15
MAX_CMDS = 8
PROMPT_CHARS = 400
CONCLUSION_CHARS = 400

SKIP_PREFIXES = (
    "<",                                  # blocks injected by the harness (system-reminder, command-name, ...)
    "Caveat:",
    "This session is being continued",    # context-compaction summary
    "[Request interrupted",
)
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit"}
SELF_MARK = "[worklog-auto]"   # marker whylog puts in its own summary prompts (daily.sh / rollup.sh)


def is_real_prompt(text):
    t = text.strip()
    if not t or len(t) < 2:
        return False
    if t.startswith(SKIP_PREFIXES):
        return False
    if t.startswith("/"):                 # slash commands carry no intent
        return False
    return True


def user_text(msg):
    """Return only the text a person typed in a user message (tool_result excluded)."""
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = [b.get("text", "") for b in c
                 if isinstance(b, dict) and b.get("type") == "text"]
        return "\n".join(parts)
    return ""


def local_date(ts):
    """Transcript timestamps are UTC ISO ('...Z'), but logs are written per local date.
    Comparing the strings directly would push early-morning local work into the previous UTC day."""
    try:
        return datetime.datetime.fromisoformat(
            ts.replace("Z", "+00:00")).astimezone().date().isoformat()
    except Exception:
        return ""


def scan(path, day, repo, skip=""):
    """Extract the target (local) date's events from one transcript."""
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
        if o.get("isSidechain"):          # subagent conversations are not user intent
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
                    conclusion = b["text"]      # the last one wins
    # whylog's own headless runs leave transcripts too. Left in, a backfill would report
    # "wrote the log" as that day's work, so drop such sessions entirely.
    if any(SELF_MARK in p for p in prompts):
        return cwd, [], Counter(), [], ""
    return cwd, prompts, files, cmds, conclusion


def main():
    repo = sys.argv[1]
    day = sys.argv[2] if len(sys.argv) > 2 else datetime.date.today().isoformat()
    skip = sys.argv[3] if len(sys.argv) > 3 else ""   # skip paths containing this
    budget = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else 0   # 0 = no cap
    root = os.path.expanduser("~/.claude/projects")
    if not os.path.isdir(root):
        return

    # Only files modified since the target date's local midnight — sessions that ended earlier can't have that day's events
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

    # The budget counts characters, not bytes, and cuts only at session boundaries.
    # (A shell head -c used to cut by bytes — a third of the budget for Korean — mid-character.)
    # Sessions with the most evidence go first; the rest keep their header line so they still show up.
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
