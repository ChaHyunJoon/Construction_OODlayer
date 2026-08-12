# ConstructionBots.jl

Behavioral guidelines are inherited from `venv/.claude/CLAUDE.md` (auto-loaded). This file is project context only.

## ★ 결과 세대 — 먼저 읽을 것 (2026-08-09 정리)

행동 어휘가 **2026-08-06** 에 바뀌었다: `action_registry.json` 이 매크로 **7(RelocateBuild)·8(SwapBattery)**
를 포함한다. 그 이전 측정치는 **행동집합이 잘린 상태**의 숫자다(zone 은 지원 팔이 `{NOOP}` 뿐이라
언제나 NOOP, battery 는 `SwapBattery` 미학습으로 적중 0/6). 두 세대가 섞여 있어 실제로 오판이
일어났기 때문에, 이전 세대 산출물을 **삭제**했다.

- **현행 배포 학습셋** = `oracle/out/n44_plus78.jsonl`. 계약: `python test_surrogate_support.py`
  → `support=[0, 1, 2, 3, 4, 7, 8]` (7/7 PASS). 이게 "현행 세대인가"의 유일한 기계적 판정이다.
- **현행 측정 문서는 `md/RESULTS_FARDEPOT_2026-08-12.md` 하나뿐** (2026-08-12 갱신 — 창고 거리
  기본값이 `D=40.0`(원거리)로 바뀌었고, 그 기하에서 재유도한 기준 정책 + 4지표 결과 행렬이 이
  문서다). `md/RESULTS_LLM7H.md` 는 **가까운 창고 기하**에서 잰 구세대 수치이며 🔴 배너가 붙었다.
  다른 md 의 수치를 현재 성능으로 인용하지 말 것 — 구세대 결과 문서에는 전부 🔴 세대 표시 배너가
  붙어 있다.
- **삭제됨**: `oracle/out` 의 08-06 이전 런 전부(145MB→5MB), `artifacts_{mdp,assimilation,openworld,classifier}`,
  `figs/`, sweep_lab 리포트(LLM 프로그램 `.json` 만 잔존), 루트 `results/`, `docs/src/*_visualization.html`,
  `tools/monitor/{anim,streams,regen_case_logs}`, 구세대 모델 `surrogate_{linear,hotswap,v2}.json`.
  복원하지 말 것 — 필요하면 `gen_oracle_dataset.jl` 로 **현재 어휘에서** 새로 만든다.
- `openworld_merged.jsonl`(= `wm_datasets.CANONICAL`) 은 매크로 7·8 이전 라벨이지만 **novelty 교정용
  입력으로만** 남겼다(`tools/monitor/README.md` 2026-08-08 이 그 경로를 부른다). **성능 근거 아님.**
- **`audit_action_vocab.py` 의 "6/6 consistent" 는 검사 대상 6곳만 본다** — 그 밖의 복제본은 안 잡힌다.
  `tools/demos.jl` 의 두 surrogate 데모는 2026-08-09 에 리터럴을 없애고 `Demos.load_action_vocab()`
  으로 registry 를 직접 읽게 고쳤다(파생이라 감사할 복제본이 없다. 검증: `[0,1,2,3,4,7,8]`).
  아직 남은 리터럴은 `wm4spacecraft_manufacturing/assimilation_gate.py`(자체 검사 고정 입력, 동작 무영향).
- 알려진 실패(정리 이전부터 존재, 이번 변경과 무관): `python verify.py oracle/out/n44_plus78.jsonl`
  → V0 PASS 후 **S1 에서 `KeyError: 7`**. baseline 이 고른 팔이 그 instance 의 `vals` 에 없다.

## Environment
- **`julia +lts` (1.10)** — `Manifest.toml` is pinned to 1.10.11; `Pkg.add` under a newer Julia silently breaks the build.
- Always pass `--project=.`.
- PyCall's interpreter must be the one `rvo2` is installed into (`ENV["PYTHON"]` / `CB_PYTHON`). See `PYTHON_SETUP.md`.
- Python stack = `venv/hjcrl` (dspy 3.2.1). 데모/렌더 재현엔 `DSPY_URL` + `NOVELTY_CALIB`(repo 내 경로) 필요.

## Commands
```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'   # full test suite
julia +lts --project=. tools/demos.jl <key>         # also: tests|checks|restage|e2e|diagnostics|setup
julia +lts --project=. -i tools/dev_session.jl      # Revise REPL: t() re-checks, rebuild() re-builds env
python wm4spacecraft_manufacturing/audit_action_vocab.py   # 매크로 추가/수정 후 필수 (exit 0 = 6/6)
```
Key can also come from an env var (`DEMO=`, `TEST=`, ...), which takes precedence over `ARGS[1]`.

**기대 baseline(실패 아님):** `Pkg.test()` = 11 pass / **1 error**(Gurobi 라이선스 없음, 변경과 무관).

`verify.py` 는 **어느 덤프로 돌리는지에 따라 결과가 갈린다.** 인자를 반드시 같이 인용할 것(2026-08-09 실측):

| 명령 | 결과 |
|---|---|
| `python verify.py oracle/out/graded_hs_n44.jsonl` | **8/8 PASS** — 문서의 8/8 은 이 5매크로 덤프 기준이고 재현된다 |
| `python verify.py oracle/out/n44_plus78.jsonl` | V0 3/3 PASS 후 **S1 `KeyError: 7`** — 현행 7매크로 학습셋은 아직 못 돈다 |

즉 8/8 은 유효하되 **배포 학습셋에서 검증된 값이 아니다**. `norm_regret` 이 baseline 의 선택 팔을
그 instance 의 `vals` 에서 찾지 못해 죽는다 — 7·8 을 포함한 덤프로 harness 를 올리는 것이 남은 일.
그 외 기계적 계약: `test_surrogate_support.py`(7/7) · `audit_action_vocab.py`(6/6, 커버리지 한계는 위 참조).

## Gotchas
- **`tools/*.jl` with no key runs a default silently** (`demos.jl` → `original_baseline`) instead of erroring. Read the `DEMOS` dict at the bottom of the file for valid keys.
- Behavior is driven by ~180 env-var knobs. Discover them, don't guess:
  `grep -rho 'get(ENV, *"[A-Z0-9_]*"' src tools | sort -u`
- Runtime `include` of navigator/battery modules must stay at module top level (world-age errors otherwise).
- **`tools/diagnostics.jl` does not load at all** — it top-level-`include`s the deleted `venv/decpomdp/examples/`, so every key fails before dispatch. Partial replacement: `wm4spacecraft_manufacturing/oracle/ood_mdp_shim.jl`.
- **비교 런은 순차 실행**(함정 30). 병렬이면 HiGHS가 다른 스케줄을 내 비교가 무효 + 프로세스당
  ~2.5GB라 OOM. 과거 "B-7 미완주"가 이 아티팩트였다(단독 실행 시 3/3 완주).
- 행동 어휘 단일 진실원 = `wm4spacecraft_manufacturing/action_registry.json`(리터럴 복붙 금지).
  누락은 에러 없이 성능으로만 샌다 — `SwapBattery` 한 줄이 battery 적중 0/6 → 6/6 을 갈랐다.
- LLM lane은 `DSPY_PROGRAM=__seed_only__`. 컴파일된 `dspy_real_program_gpt4o.json`은 battery 전용이라
  zone·RelocateBuild 어휘가 없다 — 그걸로 zone을 재면 어휘 밖 사건을 재는 것이 된다.
- `DSPY_URL` 포트는 레포에 6종이 흩어져 있다. 문서 숫자 말고 **띄운 uvicorn 포트**에 맞출 것.
- `_first_pending_assignment`는 "일감 유무"가 아니라 **"작업 경계"** — 중반 이후 조용히 틀림.
- 배포 surrogate 의 **매크로 지원 집합**은 학습셋이 정한다(`wm_datasets.N44_PLUS78`). 지원 밖 팔은
  에러 없이 후보에서 탈락해 **성능으로만** 샌다 — `python test_surrogate_support.py` 가 그 계약이다.

## Layout
- `src/respec/` — OOD → DSL re-spec layer (`spec_dsl.jl`, `compiler.jl`, `verifier.jl`, `llm_service/`)
- `src/safety/` — `cbf.jl`, `novelty.jl` · `src/mdp/` — `hazard.jl`, `mdp.jl` · `src/monitor/`, `src/navigator/`
- `wm4spacecraft_manufacturing/` — Python analysis stack (surrogate, drift, DSPy service)

## Docs
- **`wm4spacecraft_manufacturing/md/README.md` — 재현·실험 전 필수 선독.** §1 용어(F vs OOD) ·
  §6 완주 ≠ `closed==total` · §7 철회된 결론 · §8 함정 35개.
- `wm4spacecraft_manufacturing/md/SUMMARY_FORBIDZONE_RETRAIN_2026-08-07.md` — **비전문가용 요약.**
  ForbidZone 발화 + surrogate 매크로 7·8 재학습 작업의 배경·원인·결과를 용어 설명부터 적었다.
  세부 수치는 RESULTS_LLM7H.md 를 볼 것.
- `wm4spacecraft_manufacturing/md/RESULTS_LLM7H.md` — 최신 측정(5시드×4정책) + 재현 절차
- `wm4spacecraft_manufacturing/md/STATUS.md` — current state / resume point
- `wm4spacecraft_manufacturing/LABELING_MANUAL.md` — oracle labeling workflow
- **`md/ORACLE_REBUILD_2026-08-09.md` — 두 문서가 한 파일에 있다(같은 CPU 를 다투므로 순서가 중요).**
  §I **평가 보강 계획**(baseline 사다리 B0~B9 · case별 격자 · STEP A~F 와 비용) →
  §II **오라클 라벨 재빌드**(= 그 계획의 STEP D). 2026-08-09 정리로 fault 축
  (`firegrid_merged.jsonl`)은 하드 크래시, zone 축(`zcausal_reform/`)은 **조용히 n=0** 이므로
  결과표를 재측정하기 전에 §II 대로 두 라벨셋을 먼저 복구할 것.
- `tools/README.md` — fast iteration loops
- `src/SIMULATION_FLOW.md`, `RUN_GUIDE_KR.md`
