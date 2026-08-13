# ConstructionBots.jl

Behavioral guidelines are inherited from `venv/.claude/CLAUDE.md` (auto-loaded). This file is project context only.

## ★ 결과 세대 — 먼저 읽을 것 (2026-08-09 정리)

### 2026-08-13 — 목적함수 통일로 또 한 번 세대가 갈렸다

`wm4spacecraft_manufacturing/objective.json` 이 목적함수 J 의 단일 진실원이고, `objective_hash()` =
**`59b1174118b874ed`**. 파일에 `generation` 필드(현재 `"2026-08-13-energy-activation"`)가 있고
해시에 들어간다 — **규칙: 스칼라가 하나도 안 바뀌어도 목적함수의 유효 의미가 바뀌면(플래너
재배선 포함) 반드시 올린다.** greedy(`GreedyEnergyAwareCost`) · MILP(전역 `AUTO_EFFICIENCY_KAPPA`) ·
오라클 라벨(`gen_oracle_mc.scalar_cost`) · Python 분석(`e1_analyze.cost_lex_key`) 이 전부 그 J 를
본다. 설계: `docs/superpowers/specs/2026-08-13-unified-objective-design.md`.

- **세대 판정 계약**: 산출물의 `objective_hash` 필드가 현재 `objective.json` 의 해시와 같은가.
  `.venv/bin/python wm4spacecraft_manufacturing/audit_objective.py` (exit 0 = 소비처 전부 일치).
- **기계적 계약**: `test_objective.py`(29/29) · `audit_objective.py`(8/8) · `test_surrogate_support.py`(7/7)
  · `audit_action_vocab.py`(6/6) · `test/greedy_cost_dispatch_equivalence.jl`(실제 게이트 — 인프로세스
  포뮬러 동치 + 변경 전 함수의 축자 사본과의 인프로세스 A/B). `test/greedy_assignment_regression.jl`
  은 비게이팅 진단용으로 격하됐다 — 이유는 아래 Gotchas.
- **`verify.py` 는 이제 구세대 덤프(`graded_hs_n44.jsonl`·`n44_plus78.jsonl` 둘 다)에서 exit 1 로
  하드 스톱한다**(`ObjectiveError: 완주 런인데 energy_J 가 없다`) — 아래 Commands 절의 표를 이
  값으로 교체했다. **"8/8 PASS" 는 더 이상 어떤 기존 덤프로도 유효하지 않다.** 신세대 덤프(단계 6
  재실행 후)에서 기대값은 **6/8**(S1·S4 FAIL) — surrogate 가 아직 `closed − λ·MACRO_COST` 로
  학습돼 있는데 채점 기준은 `-J` 로 바뀌었기 때문이다. 둘이 닫히는 시점은 spec §8 단계 7(surrogate
  를 J 로 재라벨·재학습)이다.
- 같은 이유로 구세대 덤프에서 하드 스톱하는 것: `verify.py`(양쪽 덤프) · `firegrid_report.py` ·
  `build_md_report.py` · `test_llm7h.py` · `export_surrogate.py --cost-aware` · `cost_eval.py` ·
  MC 집계 · `tools/step6_gap.py`. 발행된 `md/RESULTS_*.md` 표 재생성은 그래서 세대 재구축(단계 6)
  에 게이트돼 있다. (`ladder.py` 는 이것과 무관한 기존 empty-glob `ValueError` 로 더 일찍 죽는다.)
- 이 날 이전의 모든 결과 문서(= `RESULTS_D20_2026-08-12.md` 포함)는 구세대다 — 🔴 배너 붙음.
- `ENERGY_OBJECTIVE=0` 으로 구세대 동작을 재현할 수 있다(끈 사실이 로그에 남는다).
- **와이어링은 됐지만 아직 안 켜진 것**: `GreedyEnergyAwareCost` 는 존재하고 맞지만 **어느 레인도
  아직 고르지 않는다** — greedy 는 t=0 에만 도는데 그 시점엔 `AGENT_COST_BIAS[]` 가 비어 있고
  `EDGE_COST_MULTIPLIER[]` 가 `nothing` 이라, 항이 있어도 에너지·SoC·DeprioritizeAgent 정보 없이
  `dt` 를 0.075% 재스케일할 뿐이다. 그래서 **spec §6.2 는 아직 미이행**이고 **§6.3 은 절반만
  참**이다 — κ 는 전역으로 배선됐고, fault 재배정 경로(`fault_robot_and_reassign!` →
  `release_pending_assignments!`, `RESPEC_ENABLED=true` 오라클 레인에서 도달)에서 에너지 항이
  실제로 새로 살아 있지만, battery-SoC 가격 책정은 아직 부활하지 않았다(`rebalance_for_battery!`
  의 재풀이가 빌드 중간엔 후보 간선이 0개다).
- **아직 안 한 것**: 630판 스윕 재실행(단계 6), surrogate 재라벨·재학습(단계 7),
  prefix 결정성 재측정(단계 8), DP 계획 재개(단계 9). 그때까지 신세대 성능 수치는 없다.
  **에너지 결정력(spec §4.2/§9 무력 검사)도 아직 측정 안 됐다** — 지금 있는 모든 덤프는
  전부 미완주만 있거나(에너지 항이 관여 안 함) energy_J 자체가 없다(구세대). 신세대 덤프가
  생기면 `wm4spacecraft_manufacturing/report_energy_decisiveness.py` 로 잰다 — "에너지가 a*
  를 한 번이라도 바꾸는가"를 세고, 0 이면 0 이라고 그대로 보고하는 도구다.

행동 어휘가 **2026-08-06** 에 바뀌었다: `action_registry.json` 이 매크로 **7(RelocateBuild)·8(SwapBattery)**
를 포함한다. 그 이전 측정치는 **행동집합이 잘린 상태**의 숫자다(zone 은 지원 팔이 `{NOOP}` 뿐이라
언제나 NOOP, battery 는 `SwapBattery` 미학습으로 적중 0/6). 두 세대가 섞여 있어 실제로 오판이
일어났기 때문에, 이전 세대 산출물을 **삭제**했다.

- **현행 배포 학습셋** = `oracle/out/n44_plus78.jsonl`. 계약: `python test_surrogate_support.py`
  → `support=[0, 1, 2, 3, 4, 7, 8]` (7/7 PASS). 이게 "**행동 어휘** 세대인가"의 유일한 기계적
  판정이다 — **목적함수 세대**는 별개 축이다(위 `2026-08-13` 절의 `objective_hash` 계약을 볼 것).
  실제로 이 학습셋 자체가 목적함수 기준으로는 구세대다: `energy_J` 가 없어 `verify.py` 가
  하드 스톱한다(위 절 참조). 두 "세대"를 섞지 말 것 — 행동 어휘는 현행, 목적함수는 구세대다.
- **현행 측정 문서는 없다.** `md/RESULTS_D20_2026-08-12.md` 가 2026-08-12 시점(창고 거리
  기본값 `D=20.0`, 그 기하에서 재유도한 기준 정책 + 4지표 결과 행렬)엔 유일한 현행 문서였지만,
  **이 커밋(2026-08-13)에서 그 문서에도 🔴 구세대 배너가 붙었다** — 목적함수가 통일되며 플래너
  동역학이 바뀌었기 때문이다. `md/RESULTS_FARDEPOT_2026-08-12.md`(D=40) · `md/RESULTS_LLM7H.md`
  도 마찬가지로 🔴 배너가 붙어 있다. **결과 문서 전부가 구세대다** — 신세대 수치는 630판 스윕
  재실행(spec §8 단계 6) 뒤에야 나온다. 다른 md 의 수치를 현재 성능으로 인용하지 말 것.
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
- 알려진 실패(2026-08-09 정리 당시): `python verify.py oracle/out/n44_plus78.jsonl` → V0 PASS 후
  **S1 에서 `KeyError: 7`**. baseline 이 고른 팔이 그 instance 의 `vals` 에 없다. `norm_regret` 이
  baseline 의 선택 팔을 그 instance 의 `vals` 에서 찾지 못해 죽는다 — 7·8 을 포함한 덤프로
  harness 를 올리는 것이 남은 일이었다(이 문제 자체는 아직 안 고쳐졌다).
  **2026-08-13 목적함수 통일 이후로는 이 지점에 도달하지 못한다** — `verify.py` 가 그보다 먼저
  `ObjectiveError` 로 하드 스톱한다(구세대 덤프에 `energy_J` 가 없어서). 상세는 위 `2026-08-13` 절.

## Environment
- **`julia +lts` (1.10)** — `Manifest.toml` is pinned to 1.10.11; `Pkg.add` under a newer Julia silently breaks the build.
- Always pass `--project=.`.
- PyCall's interpreter must be the one `rvo2` is installed into (`ENV["PYTHON"]` / `CB_PYTHON`). See `PYTHON_SETUP.md`.
- Python stack = **`.venv/`(레포 루트)**, 즉 `/home/chahj578/Construction_OODlayer/.venv/bin/python`
  — **dspy 3.3.0**. (`venv/hjcrl` 은 존재하지 않는 경로다: 2026-08-13 정정.)
  데모/렌더 재현엔 `DSPY_URL` + `NOVELTY_CALIB`(repo 내 경로) 필요.
- **dspy 3.3.0 은 `import dspy` 시점에 `numpy` 를 lazy 프록시로 갈아 끼운다** — 그래서
  `src/respec/llm_service/dspy_service.py:44` 의 `import numpy, sklearn.ensemble` 는 `import dspy`
  **앞에** 있어야 한다(지우면 numpy 반쪽 초기화로 surrogate 로드가 죽고, 레인이 조용히 canonical
  로 폴백한다 — 커밋 `f43ad79` 가 고친 회귀다).

## Commands
```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'   # full test suite
julia +lts --project=. tools/demos.jl <key>         # also: tests|checks|restage|e2e|diagnostics|setup
julia +lts --project=. -i tools/dev_session.jl      # Revise REPL: t() re-checks, rebuild() re-builds env
python wm4spacecraft_manufacturing/audit_action_vocab.py   # 매크로 추가/수정 후 필수 (exit 0 = 6/6)
```
Key can also come from an env var (`DEMO=`, `TEST=`, ...), which takes precedence over `ARGS[1]`.

**기대 baseline(실패 아님):** `Pkg.test()` = 11 pass / **1 error**(Gurobi 라이선스 없음, 변경과 무관).

`verify.py` 는 **어느 덤프로 돌리는지에 따라 결과가 갈린다.** 인자를 반드시 같이 인용할 것
(2026-08-13 재측정 — 목적함수 통일 이후 상태로 8/8 표는 더 이상 유효하지 않다):

| 명령 | 결과 |
|---|---|
| `python verify.py oracle/out/graded_hs_n44.jsonl` | **exit 1** — `ObjectiveError`(완주 런인데 `energy_J` 없음). 구세대 덤프라 하드 스톱 |
| `python verify.py oracle/out/n44_plus78.jsonl` | **exit 1** — 위와 동일 이유로 하드 스톱 |

**"8/8 PASS" 는 이제 어떤 기존 덤프로도 재현되지 않는다** — `graded_hs_n44.jsonl` 에서 예전엔
8/8 이 났지만, `verify.py` 가 이제 `objective.J`/`J_row` 를 거치므로 완주 런에 `energy_J` 가 없으면
(= 모든 구세대 덤프) 조용히 넘어가지 않고 죽는다(spec §5, §7). 신세대 덤프(spec §8 단계 6 재실행
후)에서 기대값은 **6/8**(S1·S4 FAIL) — surrogate 가 아직 `closed − λ·MACRO_COST` 로 학습돼 있는데
채점 기준은 `-J` 로 바뀌었기 때문이다. 둘이 닫히는 시점은 spec §8 단계 7(surrogate 재라벨·재학습).
그 외 기계적 계약: `test_objective.py`(29/29) · `audit_objective.py`(8/8) · `test_surrogate_support.py`(7/7)
· `audit_action_vocab.py`(6/6, 커버리지 한계는 위 참조).

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
- **컴파일을 다시 하면 배정이 재현되지 않는다.** 5회 반복 통제 실험에서, 바이트 동일한 소스가
  무관한 편집 후 재컴파일을 거치면 다른 배정 지문을 냈다(단, 한 번 컴파일된 상태 안에서는
  결정적이다). 따라서 **프로세스 간 golden-hash 비교는 코드 변경 검증 게이트가 될 수 없다** —
  차이가 코드 때문인지 재컴파일 때문인지 구분이 안 된다. 실제로 게이팅하는 것은
  `test/greedy_cost_dispatch_equivalence.jl`(인프로세스 포뮬러 항등성 + 변경 전 함수의 축자
  사본과의 인프로세스 A/B)이다. `test/greedy_assignment_regression.jl` 은 비게이팅 진단용으로
  남아 있다 — 실패해도 게이트가 아니다.
- **`@info` 가 프로세스 전역에서 조용히 사라진 적이 있었다.** `run_lego_demo` 가
  `global_logger(…, Logging.Warn)` 을 설치하고 복구를 안 해서, 첫 env 빌드 이후의 모든 `@info` 가
  안 찍혔다. 이 작업 도중 실제로 이걸로 오판을 냈다("폴백이 안 탔다" — 사실은 탔었다). `finally`
  블록에서 복구하도록 고쳤지만, 이 레포의 다른 진단 로직 중 "로그에 안 떴다"로 추론하는 것은
  아직 감사 안 됐다 — 의심하고 볼 것.

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
