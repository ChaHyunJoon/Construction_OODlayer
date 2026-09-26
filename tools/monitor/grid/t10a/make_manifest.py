"""B0 campaign manifest (T1 schema) — template 에서 출발해 GAP 을 명시 값으로 채운다."""
import json, sys, copy
ROOT = "/home/chahj578/Construction_OODlayer"
out, code_rev, dirty, config, grid_root = sys.argv[1:6]
t = json.load(open(ROOT + "/tools/monitor/grid/repair_verification_manifest.template.json"))
m = copy.deepcopy(t)
NC = "new_choice"
m["campaign_id"] = "zrv-t10a-b0-20260925"
m["arms"] = ["B0"]
w = m["budget"]["worker"]
w["wall_timeout_s"] = {"value": 3600, "source": NC, "ref": "T10a new choice = src/verification/repair_runtime.jl RepairRuntime.LIMITS.wall_s (T7/T8 production branch limit). B0 launches NO branch worker (the parent is the trusted original world, unsandboxed); the value binds T10b/T11 branch workers. The B0 episode wall is budget.episode.wall_timeout_s (campaign.py RUN_TIMEOUT)."}
w["cpu_s"] = {"value": 7200, "source": NC, "ref": "T10a new choice = RepairRuntime.LIMITS.cpu_s (RLIMIT_CPU of a sandboxed branch worker). Not applied to the B0 parent; B0 records its measured cpu_s per episode (b0.json cpu_s)."}
w["memory_mb"] = {"value": 24576, "source": NC, "ref": "T10a new choice = RepairRuntime.LIMITS.mem_bytes 24 GiB (RLIMIT_AS of a sandboxed branch worker; ~2.5 GB RSS/process observed, CLAUDE.md). Not applied to the B0 parent."}
md = m["budget"]["model"]
md["max_total_tokens"] = {"value": 1, "source": NC, "ref": "N/A for B0: arm B0 makes zero model calls (pi0, canonical lane, no service). Set at the schema minimum so that any model usage is a manifest violation; observed usage = 0 (no DSPY_URL in any launch env)."}
md["max_cost_usd_episode"] = {"value": 0.01, "source": NC, "ref": "N/A for B0 (zero model calls); nominal cap, observed cost = 0."}
md["max_cost_usd_campaign"] = {"value": 0.01, "source": NC, "ref": "N/A for B0 (zero model calls); replaces the historical A2 watchdog CAP=150 for this campaign only; observed cost = 0."}
c = m["continuation"]
c["fault_battery_lane"] = "canonical (DEMO_POLICY=canonical DEMO_ROUTER=0 — campaign lane 'canonical'; the same lane decides fault/battery in every arm)"
c["pinned_env"] = dict(c["pinned_env"], DEMO_POLICY="canonical", DEMO_ROUTER="0", ZONE_REPAIR_VERIFICATION="shadow")
m["exogenous_rng"]["replay_version"] = "zrv-replay/1 (exogenous draws pre-t0, historical-compatible)"
m["cost_ledger"]["real_ledger"] = grid_root + "/<model>/streams/<model_base>__canonical_<case>_s<seed>_z<seed>.jsonl (the parent = original world writes the real monitor stream)"
m["cost_ledger"]["shadow_namespace"] = grid_root + "/<model>/zr/<run_key>/ (B0: parent only, no branch writes)"
b = m["build"]
b.update(code_rev=code_rev, code_dirty_digest=dirty,
         dirty_snapshot_digest=dirty + " (campaign.py snapshot <grid>/snapshot restores this code_dirty_digest; restore_verified in snapshot.json)",
         config_digest=config, julia_version="1.10.11", manifest_digest="7fc013eba0f5afba", build_id="9a53d859d1be76ae",
         julia_threads=1, solver={"name": "HiGHS", "version": "1.23.0", "seed": 0, "threads": 0})
m["model_side"] = {"model": "none: B0 (pi0) makes no model call", "service_code_fingerprint": "none: no service (B0)",
                   "prompt_digest": "none: no prompt (B0)", "schema_digest": "none: no proposals (B0)"}
m["trusted"] = {"validator_version": "task-contract-validator/1 + repair-supervisor/1 checkpoint_gaps/identity_gaps",
                "scorer_version": "zrv-b0-episode/1 (outcome from parent terminal.json terminal_reason; UNKNOWN from campaign runs.jsonl)",
                "capability_contract_version": "capability-contract/1"}
json.dump(m, open(out, "w"), indent=1, sort_keys=True)
print("wrote", out)
