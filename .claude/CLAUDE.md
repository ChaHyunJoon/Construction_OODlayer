# ConstructionBots.jl

Behavioral guidelines are inherited from `venv/.claude/CLAUDE.md` (auto-loaded). This file is project context only.

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

**기대 baseline(실패 아님):** `Pkg.test()` = 11 pass / **1 error**(Gurobi 라이선스 없음, 변경과 무관) ·
`verify.py` = **8/8**(2026-08-06 V0 을 valid_mask 기준으로 고친 뒤. 그 이전 문서의 "7/8"·"8/8" 은
서로 다른 판정이라 함께 인용하면 안 된다).

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
- `wm4spacecraft_manufacturing/md/RESULTS_LLM7H.md` — 최신 측정(5시드×4정책) + 재현 절차
- `wm4spacecraft_manufacturing/md/STATUS.md` — current state / resume point
- `wm4spacecraft_manufacturing/LABELING_MANUAL.md` — oracle labeling workflow
- `tools/README.md` — fast iteration loops
- `src/SIMULATION_FLOW.md`, `RUN_GUIDE_KR.md`
