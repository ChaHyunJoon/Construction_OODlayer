# Phase 1 retry-body live gate — 2026-09-23

Plan: docs/superpowers/plans/2026-09-22-tractor-xwing-full-recovery.md, Task 6 Step 7–8.
Campaign: p1gate-20260923T0005 · HEAD 99ee87dcd2f85ce499ef70d6919a68b632309963 (Phase 1 code 67949f57..99ee87dc)
Working tree dirty at start: 24 non-deleted src/tools/test entries (other sessions; recorded in dirty_at_start.txt and in run_ctx.code_dirty_digest).
Service: uvicorn :8095, TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1, SYNTH_RECORD_LOG=/home/chahj578/Construction_OODlayer/results/2026-09-23-retry-gate/ledger.jsonl (absolute), policy dspy:gpt-4o, code_fingerprint 72b8b5af417e6b2c, generation gate OK. Stopped after gate B.

## Deviations from the plan text (rulings R13/R14)
- Gate B used DEMO_CASE_TAG=retrygate_B (not router_zone) and DEMO_OUT_DIR — avoids overwriting tools/monitor/streams/tractor__router_zone_z3.jsonl. DEMO_OUT_DIR exists only in another session's uncommitted render_demo.jl hunk (present at run time).
- Ledger passed explicitly (post-run copy), --health-json snapshot, DEMO_CAMPAIGN_ID set, --expect-ctx checks instead of manual tail.

## Gate A — fixture probe (tools/fixtures/probe_retry_boom.json), canonical, zone seed 3
render rc=1 (184 s): probe body only throws, build incomplete → "refusing to publish incomplete animation" (expected).
grep "[minted] enact_retry: 되먹임 1회" = 1. Stream 3887601 bytes.
verify (exit 0): {"decisions": 0, "decide_joined": 0, "attempts": 1, "roundtrip_ok": 1, "attempt_joined": 1, "parent_ok": 0, "parent_fixture_allowed": 1, "code_equal": 1, "duplicates": 0, "cache_hits": 0, "cache_misses": 0, "cache_unknown": 1, "raw_lm_live": 1, "foreign_rows": 0, "ledger_append_failures": 0, "problems": [], "warnings": [], "verdict": "ok"}
/health after A: {'calls': 0, 'billed': 0, 'ledger_append_failures': 0}

## Gate B — router, zone seed 3
render rc=1 (214 s): zone run incomplete (closed 218, project_blocked) — not a gate criterion.
Synthesis fired (decide_outcome=synthesis_ran), one /rewrite (trigger threw). Stream 4732649 bytes vs 4255096 for the 2026-09-06 sweep stream of the same cell (≈1.11×, under the plan's 2× report threshold).
verify (exit 0): {"decisions": 1, "decide_joined": 1, "attempts": 1, "roundtrip_ok": 1, "attempt_joined": 1, "parent_ok": 1, "parent_fixture_allowed": 0, "code_equal": 1, "duplicates": 0, "cache_hits": 0, "cache_misses": 0, "cache_unknown": 4, "raw_lm_live": 4, "foreign_rows": 1, "ledger_append_failures": 0, "problems": [], "warnings": [], "verdict": "ok"}
/health after B: {'calls': 1, 'billed': 0, 'ledger_append_failures': 0}

## Observations
- /health `calls`/`billed` do NOT count /rewrite (both stayed 0 after gate A's live rewrite), and `billed` stayed 0 in B while raw_lm_live=4 — /health is not a paid-call counter; raw_lm_live (per raw LM entry: cache_hit≠True and non-empty usage) is the better proxy, still not a billing count.
- Live LM entries recorded: A 1 (rewrite), B 4 (observe/design/compose + rewrite); plus the macro SelectTool call(s) in B, which are not in raw_lm by design.
- Ledger: 3 v2 rows (rewrite A, decide B, rewrite B); ledger_append_failures 0.
