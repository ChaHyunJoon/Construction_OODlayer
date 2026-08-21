# 레포 파일 종류 축소 — wm4spacecraft_manufacturing 코드 + md 통합

## Spec (이 계획이 논증하는 권위)

사용자 요구 두 가지다.

1. `wm4spacecraft_manufacturing/` 에 **현행 중간결과(2026-08-17 발표자료)를 만드는 데 쓰이지 않는**
   py/jl/sh 가 너무 많아 어떤 코드가 무슨 역할인지 파악이 안 된다. 불필요한 파일을 제거한다.
   **2026-08-18 사용자 개정 — 이것이 지배 기준이다:** 지우고 싶은 것은 주로 *자동 작업을 맡겼을 때
   Claude 가 validation 을 하려고 만든* py/jl/sh 다("run_xxx.sh 라던지 test_xxx.py 라던지").
   즉 기준은 도달가능성이 아니라 **생산자냐 검사자냐** 다 — 결과를 만들면 남기고, 결과를 검사만
   하면 지운다. 대상 접두/접미: `test_*` · `audit_*` · `gate_*` · `check_*` · `verify*` ·
   `probe_*` · `diag_*` · `measure_*` · 중복 `run_*.sh` 변종.
2. `wm4spacecraft_manufacturing/md/`(30개)와 `.superpowers/`(131개)의 md 를 **각각 하나의 파일로
   압축·정리**한다.

사용자가 확정한 범위 결정 두 가지:
- **결과 데이터 디렉터리는 건드리지 않는다.** `results_*`, `artifacts_*`, `oracle/out`,
  `dp_oracle/`, `_night/`, `_quarantine_*`, `_backup_*`, `baseline_n5/`, `sweep_lab/`,
  `LDraw_files/`, `.venv/` 는 이 계획의 범위 밖이다. 22GB 중 19GB 가 여기다.
- **구세대 분석 도구는 삭제하고 `audit_objective.py` 를 같이 갱신한다.** CLAUDE.md 가 이미
  "현행 덤프에서 exit 1 로 하드 스톱한다" 고 기록한 도구들이다.

## Global Constraints

- **G1 — 현행 산출 경로를 깨지 않는다.** 아래 두 경로가 이 레포의 결과를 만든다:
  - 스윕: `run_4pol_parallel.sh` → `gate_prereq.sh` · `run_shard.sh` → `llm_ood_eval.py`
    → (julia) `tools/monitor/run_demo.jl`
  - 표: `finish_tables.sh` → `merge_shards.py` → `build_final_table.py`(서브프로세스로
    `llm_ood_eval.py report` · `shadow_score.py`) → `build_compare_table.py`
  - 서비스 런타임: `src/respec/llm_service/dspy_service.py` 가 **import** 하는
    `eval_surrogate_v2.py` · `surrogate_features.py` · `surrogate_v2.py` (+ `wm_datasets.py`)
  - 라벨 레인: `oracle/run_relabel_20260816.sh` → `oracle/gen_oracle_dataset.jl`
    (`ood_mdp_shim.jl` · `action_registry.jl` · `objective.jl` include)
  - 보드/렌더: `render_all.sh` · `publish_streams.sh` → `tools/monitor/render_demo.jl`
- **G2 — 레포 밖 경로는 수정 금지.** `src/`, `tools/`, `test/`, `docs/src/`, `.venv/` 는
  건드리지 않는다. 단 `.claude/CLAUDE.md` 의 **삭제된 파일 참조 갱신**은 허용한다.
- **G3 — 살아남은 파이프라인이 여전히 임포트되고 돌아야 한다.**
  🔴 **개정(2026-08-18): 옛 G3(테스트 18 PASS/1 FAIL 유지)는 무효다** — 테스트 자체가
  삭제 대상이 됐다. 검사자를 지우는 게 목적인데 검사자의 통과를 합격 조건으로 쓸 수는 없다.
  대체 검증은 **Task 1 이 명세한 레시피**를 쓴다. 최소한 다음을 포함해야 한다:
  - 살아남은 모듈 전부가 임포트된다(`python -c "import ..."`).
  - `llm_ood_eval.py` · `build_final_table.py` · `build_compare_table.py` · `merge_shards.py` ·
    `shadow_score.py` 가 `--help` 로 뜬다(문법·임포트 동시 확인).
  - **`bash finish_tables.sh` 가 기존 `results_4pol` 트리에서 끝까지 돌고
    `artifacts_4pol/COMPARE.md` 의 합계가 `210/210 · 189/210 · 205/210` 로 재생산된다.**
    이게 이 정리의 진짜 게이트다 — 결과를 만드는 경로가 살아 있는지를 결과로 증명한다.
- **G4 — git 으로 복구 가능한 것만 바로 지운다.** `md/`(30개 전부 tracked)와 코드는 tracked 라
  `git show HEAD:<path>` 로 복구된다. **`.superpowers/` 는 untracked(gitignore)라 복구 불가** —
  반드시 **통합 문서를 먼저 쓰고 검증한 뒤** 지운다.
- **G5 — 이 계획의 SDD 작업공간은 지우지 않는다.** `.superpowers/sdd/` 아래 **2026-08-18 이전
  6개 세션 디렉터리만** 통합 대상이다:
  `2026-08-11-seed20-verification` · `2026-08-12-parallel-30seed-sweep` · `2026-08-13-dp-oracle` ·
  `2026-08-13-surrogate-rebuild` · `2026-08-13-unified-objective` · `PLAN_4POLICY_5H_2026-08-10`.
  이 계획 자신의 작업공간 디렉터리는 **대상이 아니다.**
- **G6 — 커밋은 태스크마다.** 각 태스크가 자기 변경을 커밋한다. push 는 하지 않는다.

## Task 1 — 코드 분류표를 만든다 (planner, 파일 변경 없음)

`wm4spacecraft_manufacturing/` 의 **모든** `*.py` · `*.jl` · `*.sh` · `*.ps1` · `*.cmd` 를
(단 `results_*`/`artifacts_*`/`_night`/`_quarantine_*`/`__pycache__`/`.pytest_cache`/`oracle/out`
/`dp_oracle/` 하위 데이터 제외; `dp_oracle/*.py` 자체는 포함) KEEP / DELETE 로 분류하고
`<workspace>/CLASSIFY.md` 에 쓴다. **파일을 지우거나 고치지 않는다.**

각 행에 다음을 적는다: 경로 · KEEP|DELETE · **근거 한 줄**(누가 이 파일에 도달하는가 —
import 체인 / 서브프로세스 호출 / 셸 스크립트 / 기계 검사 / 도달 없음).

근거를 만들 때 반드시 실측할 것:
- `ast` 로 import 그래프를 만들되 **G1 의 엔트리포인트 전부**를 루트로 넣는다
  (`dspy_service.py` 를 빼면 `surrogate_v2.py` 가 고아로 잘못 나온다 — 실제로 잘못 나왔다).
- import 만으로는 부족하다. `build_final_table.py:344,358` 은 `shadow_score.py` 를
  **서브프로세스**로 부른다. `grep -n 'HERE / "'` 로 서브프로세스 호출을 따로 훑을 것.
- `audit_objective.py:68-71` 의 `LITERAL_SCAN` 12개 파일명과 `:110,:118` 의
  `oracle/gen_oracle_mc.jl` · `oracle/gen_oracle_dataset.jl` 은 **존재가 기계 검사 대상**이다.
  이 목록에서 DELETE 로 분류한 파일은 Task 2 가 감사도 같이 고쳐야 하므로 분류표에 표시할 것.
- `gate_prereq.sh` 는 `audit_action_vocab.py` · `test_surrogate_support.py` ·
  `gate_llm_concurrency.py` 를 부른다.

**DELETE 기본 근거 세 가지**(이 중 하나에 해당하고 G1 경로에서 도달 불가일 때만 DELETE):
(a) CLAUDE.md 가 "구세대 덤프에서 하드 스톱" 으로 기록한 분석 도구,
(b) 어떤 셸/파이썬/줄리아에서도 참조되지 않는 고아,
(c) Windows 전용 `.ps1`/`.cmd` (이 레포는 linux 에서 돈다).

분류표 맨 아래에 KEEP 수 · DELETE 수 · 합계를 적는다.

## Task 2 — 분류표대로 코드를 지우고 기계 검사를 맞춘다 (generator)

`<workspace>/CLASSIFY.md` 의 DELETE 행을 `git rm`(tracked) / `rm`(untracked) 한다. 그리고:

- 🔴 **개정(2026-08-18): `audit_objective.py` 는 패치 대상이 아니라 삭제 대상이다**(검사자다).
  따라서 옛 지시 "LITERAL_SCAN 을 갱신한다" 는 **무효**다. `audit_action_vocab.py` 도 같다.
- **KEEP 파일이 DELETE 파일을 부르는 자리를 끊는다.** Task 1 의 "KEEP files that call a DELETE
  file" 절이 `file:line` 을 준다. 최소한 `run_4pol_parallel.sh` 의 `gate_prereq.sh` 호출과
  `build_final_table.py` 가 발행물에 찍는 삭제된 스크립트 이름이 여기 해당한다.
  호출을 끊을 때 **그 자리에 무엇이 없어졌는지 한 줄 주석**을 남긴다.
- `.claude/CLAUDE.md` 에서 **삭제된 파일을 가리키는 문장**을 갱신한다. 통째로 지우지 말고
  "이 도구는 2026-08-18 정리에서 삭제됐다(`git show HEAD~1:<path>`)" 로 사실을 바꿔 적는다.
  🔴 `objective_hash` 값을 이 파일에 새로 적지 말 것 — `audit_objective.py` 항목 9 가
  CLAUDE.md 안의 해시 인용 개수를 기계로 본다.
- 삭제된 모듈을 import 하던 **남는** 파일이 있으면 그 import 를 지운다.

검증: **G3 의 대체 레시피**(Task 1 리포트가 명세한 명령들)를 그대로 돌리고 출력을 리포트에
붙인다. `finish_tables.sh` 재생산 합계가 `210/210 · 189/210 · 205/210` 이 아니면 실패다.

## Task 3 — `.superpowers/` 6개 세션을 한 파일로 압축한다 (generator)

G5 의 6개 디렉터리(md 80개 · diff 50개 · 약 16MB)를 읽고
`docs/superpowers/SDD_SESSIONS_ARCHIVE.md` **한 파일**로 압축한다.

- `.diff` 파일은 **본문에 넣지 않는다.** 그 diff 들은 전부 커밋된 변경의 사본이라 git 에 있다.
  세션별로 "review diff N개(커밋 범위 `<a>..<b>`)" 한 줄로만 적는다.
- 세션마다 다음을 남긴다: 기간 · 원래 계획서 경로 · **무엇을 했나 3~6줄** ·
  **살아남은 교훈/함정**(재현되는 사실만 — 그 세션에서 측정된 것) · 그 결과가 지금 어디에 사는가
  (현행 문서·코드 경로). 태스크 브리프의 지시문·진행상황 로그처럼 **그때만 쓸모 있던 것은 버린다.**
- 최종 파일은 **60KB 이하**여야 한다(원본 md 합계 1.45MB). 못 지키면 요약을 더 줄인다.
- 문서를 쓰고 **읽어서 검증한 뒤에만** `rm -rf` 로 6개 디렉터리를 지운다. G4 대로 복구 불가다.
- 이 계획 자신의 작업공간은 지우지 않는다(G5).

## Task 4 — `md/` 30개를 한 파일로 압축한다 (generator)

`wm4spacecraft_manufacturing/md/` 의 30개(816KB)를 `wm4spacecraft_manufacturing/md/README.md`
**한 파일**로 통합하고 나머지 29개를 `git rm` 한다.

- 유지할 것: 현행 세대 결과 수치(3레인 × 7 case 표) · 재현 명령 · 살아 있는 계약 ·
  **측정된 함정 목록**(README §8 이 이미 그 자리다) · 각 문서가 어디로 갔는지의 SHA 색인.
- `ARCHIVE.md` 의 기존 관례를 따른다: 내린 문서마다 **파일명 · 무엇이 있었나 · 왜 내렸나 ·
  꺼내는 명령**(`git show <SHA>:wm4spacecraft_manufacturing/md/<파일명>`). SHA 는
  `git log -1 --format=%H -- <path>` 로 **실제로 조회해서** 적는다. 지어내지 않는다.
  기존 `ARCHIVE.md` 본문도 새 README 안으로 흡수한다.
- 🔴 구세대 수치를 현행으로 승격하지 말 것. 현행 세대는
  `RESULTS_SWAPBATTERY_COURIER_2026-08-15.md` + `artifacts_4pol/COMPARE.md`(합계
  canonical 210 / surrogate 189 / llm 205)다. 2026-08-17 발표에 쓰인 표(207/198/203)는
  **그 직전 세대**이므로 그렇게 표시한다.
- 최종 파일은 **120KB 이하**.
- 통합 후 `../.venv/bin/python audit_objective.py` 가 여전히 exit 0 이어야 한다
  (그 감사가 문서에 박힌 해시·계약 개수를 본다).
