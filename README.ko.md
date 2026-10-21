# whylog

[English](README.md) | **한국어**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/bash-%2B%20python3-4EAA25)
![Requires Claude Code](https://img.shields.io/badge/requires-Claude%20Code-555)
[![lint](https://github.com/tom0266/whylog/actions/workflows/lint.yml/badge.svg)](https://github.com/tom0266/whylog/actions/workflows/lint.yml)

**Claude Code 세션 기록과 코드 diff로 매일 연구 일지를 자동으로 써 주는 도구.**

평소처럼 연구하면, 매일 밤 그날 무엇을 **왜** 했는지가 저절로 정리돼 내 비공개 GitHub 저장소에 쌓입니다. 직접 쓸 일은 없습니다.

```markdown
# 2026-08-13 작업 일지

**TL;DR**: 데이터 로더를 정리하다가 검증 세트 누수를 발견해 바로잡았다.

**오늘의 흐름**: 느린 데이터 로더를 빠르게 하려고 시작했다. 프로파일링 중 검증 점수가
지나치게 높다는 의심이 들어 분할 코드와 설정을 직접 대조했고, 학습 샘플의 증강 사본이
검증 쪽에 섞여 들어가는 것을 확인했다. 분할을 고친 뒤 베이스라인을 다시 돌렸다.

### 데이터 파이프라인 — 검증 누수 적발
- **무엇을**: `split.py`에서 중복 제거를 train/val 분할 앞으로 옮김.
- **왜**: 같은 샘플의 증강 사본이 양쪽에 들어가고 있었음.
- **기대효과**: 검증 점수가 현실적인 수준으로 내려옴. 이전 결과는 재확인 필요.
- **계기**: 프로파일링 중 "왜 val이 train보다 좋지?"라는 의문.
```

전체 샘플은 [`examples/`](examples/)에 있습니다: 일일 일지(영어·한국어), 주간 요약, 인덱스.

## 특징

- **완전 자동**: 매일 밤 cron이 씁니다. 세션을 열어 둘 필요도, 뭔가 입력할 필요도 없습니다.
- **무엇을 바꿨나 — `git log`가 아닌 스냅샷 diff**: 커밋하지 않은 작업이나 늦게 한 커밋도 그날 것으로 정확히 잡힙니다.
- **왜 했나 — 세션 기록**: Claude Code 트랜스크립트에서 내 지시, 편집한 파일, 실행한 명령, 세션의 결론을 뽑아 변경마다 의도를 짝지어 줍니다.
- **스스로 복구**: 서버가 꺼져 밤 실행을 놓치거나 요약이 실패해도, 다음 실행이 최근 3일 중 빠진 날을 메웁니다.
- **쉬는 날은 공짜**: 활동이 없는 날은 모델을 부르지 않고 한 줄만 남깁니다.
- **롤업**: 주간·월간 요약, 그리고 날짜별 TL;DR 한 줄을 모은 `INDEX.md`.
- **내 소유의 기록**: 내 git 저장소에 쌓이는 평범한 Markdown. 버전이 남고 비공개 원격에 push됩니다.
- **한국어/영어**: `whylog.conf`의 `LANGUAGE`로 고릅니다.

## 5분 설치

필요한 것: Linux, [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` CLI, 로그인 상태), `git`, `python3`, `cron`. 선택: `gh` (비공개 GitHub 저장소를 대신 만들어 줌). macOS는 아직 지원하지 않습니다 (GNU `date -d`, `timeout` 사용).

```bash
git clone https://github.com/tom0266/whylog ~/whylog
cd ~/whylog
vi whylog.conf        # 대개 그대로 둬도 됩니다 (아래 참조)
bash install.sh
```

`install.sh`가 하는 일: 필수 도구 확인 → 일지 저장소(git) 준비 → 원한다면 GitHub 비공개 저장소 생성 → 코드 스냅샷 기준선 생성 → cron 등록 → 동작 확인(dry-run). 여러 번 다시 실행해도 안전합니다.

> clone 직후에는 `origin`이 이 도구 저장소를 가리킵니다. `install.sh`가 이 연결을 자동으로 끊어 **내 일지가 이곳으로 push되지 않게** 합니다. clone 대신 **Use this template** 버튼을 써도 됩니다.

실행 시각을 바꾸려면 `CRON_TIME="30 19" bash install.sh` (분 시 순서, 기본 `0 22` = 밤 10시).

## 설정 (`whylog.conf`)

| 항목 | 기본값 | 설명 |
|---|---|---|
| `TRACK_REPO` | `$HOME` | 기록 대상 작업 폴더. 이 아래의 코드·문서 변경과 세션이 대상 |
| `WORKLOG_DIR` | (이 폴더) | 일지가 쌓이는 곳 |
| `MODEL` | `opus` | 요약 모델. 사용량을 줄이려면 `sonnet` |
| `LANGUAGE` | `ko` | 일지 언어: `ko` 또는 `en` |
| `CLAUDE_BIN` | (자동 탐지) | `claude` 실행 파일 경로 |
| `DIFF_BUDGET` 등 | 60000 / 6000 / 40 | 프롬프트에 실을 코드 diff 분량 상한 |
| `SESS_BUDGET` | 30000 | 세션 기록에서 뽑아 실을 근거 분량 상한 |
| `SKIP_DIR` | (빈 값) | 경로에 이 문자열이 있는 세션은 기록하지 않음 |

## 어떻게 그날 한 일을 아는가

정확도의 두 축이 있습니다.

**무엇을 바꿨나 — 코드 스냅샷.** `.snapshot.git`(일지 저장소 안의 별도 git)에 매일 밤 작업 폴더 스냅샷을 뜹니다. "어제 스냅샷 대비 오늘 diff"가 그날 바꾼 것입니다. 작업 폴더의 `git status`를 쓰면 커밋이 뜸한 저장소에서 수개월치 누적 변경이 "오늘 한 일"로 둔갑하기 때문에, 별도 스냅샷을 두는 것이 핵심입니다.

diff는 하루 수십만 자에 이르므로 전부 넣을 수 없습니다. **변경량이 큰 파일부터 파일당 상한을 두고** 담습니다. (단순히 앞에서 잘라내면 git diff의 경로 알파벳순 때문에 `.`으로 시작하는 에디터 설정 폴더가 예산을 다 먹고 정작 연구 코드는 하나도 안 실립니다. 실제로 그렇게 돌아간 날이 있었습니다.)

**왜 했나 — 세션 기록.** `~/.claude/projects/**/*.jsonl` 트랜스크립트에서 그날치 이벤트만 뽑습니다: 내가 내린 지시/질문, 실제로 편집된 파일, 실행한 명령, 세션이 어떻게 끝났는지. 원문(세션 하나가 40MB를 넘기도 합니다)은 넣지 않고 이벤트만 추출합니다. "무엇을"과 "왜"가 짝지어지는 건 이 축 덕분입니다.

그날의 커밋(`TRACK_REPO` 바로 아래 독립 git 저장소들의 커밋 포함)도 보조 근거로 들어갑니다.

## 쓰는 법

| 하고 싶은 것 | 명령 |
|---|---|
| 지금 즉시 오늘 일지 생성 | `bash daily.sh` |
| 기록하지 않고 결과만 미리보기 | `bash daily.sh --dry-run` |
| 놓친 날 복구 | `bash daily.sh --date 2026-08-13` |
| 주간 요약 | `bash rollup.sh week` |
| 월간 요약 | `bash rollup.sh month 2026-08` |
| 인덱스 갱신 | `bash rollup.sh index` |

주간 요약은 일요일 밤에 자동으로 돌고, `INDEX.md`는 매일 일지 작성 후 갱신됩니다.

자동 요약이 틀렸다면 Claude 세션에서 **"오늘 일지 이 부분 고쳐줘"**라고 하면 됩니다.

## 구조

```
whylog/
├── whylog.conf          # 설정 — 환경이 다르면 여기만 고치면 된다
├── install.sh           # 설치 (멱등)
├── daily.sh             # 일일 기록 (cron 매일 밤)
├── rollup.sh            # 주간/월간 요약 + INDEX (cron 일요일 밤)
├── extract_sessions.py  # 세션 트랜스크립트 → 이벤트 추출
├── examples/            # 출력 샘플
├── INDEX.md             # 전체 날짜의 TL;DR 한 줄 목록
└── YYYY-MM/YYYY-MM-DD.md
```

## 개인정보와 알아 둘 것

- **일지 저장소는 비공개로 두세요.** 무엇을 왜 했는지가 그대로 남습니다 — 미발표 결과, 실패한 시도, 판단 근거까지. 그 정직함이 이 일지의 가치인데, 공개되는 순간 자기검열이 시작됩니다. 남들과 공유하려면 원본은 비공개로 두고 주간 요약만 따로 내보내세요.
- **요약을 만들 때 코드 diff와 지시 내용이 Claude로 전송됩니다.** 사내·기관 정책상 코드 외부 전송이 제한된다면 `TRACK_REPO`를 해당 폴더 밖으로 한정하세요.
- 기록 대상에서 빼고 싶은 폴더는 `.snapshot.git/info/exclude`에 추가합니다 (에디터·터미널 설정 폴더는 기본으로 제외돼 있습니다).
- `.claude/`가 작업 폴더의 `.gitignore`에 있으면 **스킬·에이전트를 만든 작업은 코드 diff에 안 잡힙니다.** 다만 세션 기록 축에서는 잡히므로 완전히 누락되지는 않습니다.
- 밤 실행 이후의 세션은 그날 일지에 들어가지 않습니다(코드 변경은 다음 날 diff에 잡힘). 늦게까지 일한다면 `CRON_TIME`을 늦추세요.

## 제거

```bash
crontab -l | grep -v -e whylog/daily.sh -e whylog/rollup.sh | crontab -
```

`whylog`가 아닌 다른 폴더 이름으로 설치했다면 그 이름으로 바꿔 넣으세요. 일지가 더 필요 없으면 폴더를 지우면 됩니다.

## 라이선스

[MIT](LICENSE)

Anthropic과 무관한 비공식 커뮤니티 프로젝트입니다. Claude, Claude Code는 Anthropic의 상표입니다.
