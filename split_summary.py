#!/usr/bin/env python3
"""Fallback when the one-shot daily summary comes back refused or malformed.

A large day's evidence can trip the model's safety classifier even when every piece of it
passes on its own. This splits the evidence by top-level project folder, summarizes each
group in its own call, then asks for the TL;DR / flow lines over the (short) group summaries.

Usage: split_summary.py <EVIDENCE_DIR> <TRACK_REPO> <CLAUDE_BIN> <MODEL> <SYS> <TIMEOUT_SEC> <LANGUAGE>
EVIDENCE_DIR holds sessions.txt, changes.txt (diff body or mtime file list), commits.txt.
Prints the narrative on stdout; prints nothing and exits 1 if every group failed.
"""
import os
import re
import subprocess
import sys

ev_dir, repo, claude, model, sys_prompt, timeout, lang = sys.argv[1:8]
timeout = int(timeout)
en = lang == "en"
OTHER = "Other" if en else "기타"
HOME = "(home)" if en else "(홈)"


def read(name):
    try:
        with open(os.path.join(ev_dir, name), encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def group_of(path):
    """Top-level folder under the tracked repo ('proj/x.py', './proj/x.py' or an absolute path)."""
    p = path.strip()
    if p.startswith(repo):
        p = p[len(repo):]
    p = p[2:] if p.startswith("./") else p.lstrip("/")
    return p.split("/", 1)[0] or HOME


groups = {}   # name -> {"sessions": [], "changes": [], "commits": []}


def add(g, kind, text):
    groups.setdefault(g, {"sessions": [], "changes": [], "commits": []})[kind].append(text)


# Sessions: blocks starting with "#### 세션 <id> · <cwd> · ..."
for block in re.split(r"(?m)^(?=#### 세션 )", read("sessions.txt")):
    m = re.match(r"#### 세션 \S+ · (.+?) · ", block)
    if m:
        add(group_of(m.group(1)), "sessions", block.strip())

# Changes: diff bodies have "===== path =====" headers; otherwise one file path per line
changes = read("changes.txt")
if re.search(r"(?m)^===== .+ =====$", changes):
    for block in re.split(r"(?m)^(?====== .+ =====$)", changes):
        m = re.match(r"===== (.+) =====", block)
        if m:
            add(group_of(m.group(1)), "changes", block.strip())
else:
    for line in changes.splitlines():
        if line.strip() and line.strip() != "없음":
            add(group_of(line), "changes", line.strip())

# Commits: "- [Project] hash author subject" for sub-repos, plain for the tracked repo itself
for line in read("commits.txt").splitlines():
    m = re.match(r"- \[([^\]]+)\] ", line)
    add(m.group(1) if m else HOME, "commits", line)

# Groups without any session go into one "other" bundle — they are usually small and incidental
final = {}
for g, d in groups.items():
    key = g if d["sessions"] else OTHER
    tgt = final.setdefault(key, {"sessions": [], "changes": [], "commits": []})
    for k in tgt:
        tgt[k] += d[k]


def call(prompt):
    try:
        r = subprocess.run([claude, "-p", prompt, "--model", model, "--append-system-prompt", sys_prompt,
                            "--tools", ""], capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def first_line(text):
    return next((l.strip() for l in text.splitlines() if l.strip()), "")


sections, failed = [], []
for g, d in final.items():
    title = g
    if en:
        prompt = (f"[worklog-auto] You are writing one part of a researcher's daily work log: only the '{g}' group. "
                  "Use the session transcripts as the primary evidence for 'why' and the code changes for 'what', and pair them. "
                  "Mark inferences without evidence '(inferred)'; leave why/effect empty when there is no evidence.\n"
                  f"Output: the first line must be exactly `### {title}`, followed by bullets only (What / Why / Effect / Trigger for main items, "
                  "minor changes grouped under 'Other'). No intro, no closing, no TL;DR.\n\n")
    else:
        prompt = (f"[worklog-auto] 한 연구자의 일일 작업 일지 중 '{g}' 묶음만 정리합니다. 세션 기록을 '왜'의 최우선 근거로, "
                  "코드 변경을 '무엇을'의 근거로 삼아 짝지어 서술하세요. 근거 없이 추론한 부분은 '(추정)', 근거가 없으면 왜/기대효과는 비워 두세요.\n"
                  f"출력: 첫 줄은 반드시 `### {title}`, 그 아래는 불릿만. 주요 항목은 무엇을 / 왜 / 기대효과 / 계기로, 사소한 변경은 '기타'로 묶기. "
                  "서론·맺음말·TL;DR 없이.\n\n")
    prompt += "### 세션 기록\n" + ("\n\n".join(d["sessions"]) or "없음") + "\n\n"
    prompt += "### 코드 변경\n" + ("\n".join(d["changes"]) or "없음") + "\n\n"
    prompt += "### 커밋\n" + ("\n".join(d["commits"]) or "없음")
    out = call(prompt)
    if out and first_line(out).startswith("###"):
        sections.append(out)
    else:
        failed.append(g)
        files = [re.sub(r"^===== (.+) =====.*", r"\1", c.splitlines()[0]) for c in d["changes"]][:20]
        note = "_(summary refused or failed for this group — changed files only)_" if en else "_(이 묶음은 요약이 거부되거나 실패해 바뀐 파일만 남김)_"
        sections.append(f"### {title}\n{note}\n" + "\n".join(f"- `{f}`" for f in files))

if len(failed) == len(final):
    sys.exit(1)

body = "\n\n".join(sections)
if en:
    head_prompt = ("Below is today's work log body, already written per project. Output exactly two lines and nothing else: "
                   "`**TL;DR**: ` one line with the day's key result, then `**Today's flow**: ` 2-3 sentences linking what was done and why.\n\n" + body)
else:
    head_prompt = ("아래는 과제별로 나눠 쓴 오늘 작업 일지 본문입니다. 이것만 근거로 두 줄만 출력하세요(다른 것은 출력하지 말 것): "
                   "`**TL;DR**: ` 한 줄 — 오늘의 핵심 성과, `**오늘의 흐름**: ` 2~3문장 — 무엇을 왜 했고 어떻게 이어졌는지.\n\n" + body)
head = call(head_prompt)
if not first_line(head).startswith("**TL;DR**"):
    head = "**TL;DR**: (overall summary failed — see per-project sections)" if en else "**TL;DR**: (전체 요약 생성 실패 — 아래 과제별 요약 참고)"
note = ("_The one-shot summary was refused, so this log was summarized per project._" if en
        else "_한 번에 요약하는 호출이 거부되어 과제별로 나눠 요약했다._")
print(f"{head}\n\n{note}\n\n{body}")
