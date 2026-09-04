"""The 3-agent synthesis lane, live, on the two OOD lanes -- with the F2 feedback loop.

Run:  .venv/bin/python tools/probes/probe_synth_multi_lane.py     (PROBE_OUT=<path> optional)
🔴 EVERY run of this file is billable: 3 LM round trips per lane, 5 if the F2 loop fires.

Isolation: no simulator, no MILP, no RVO. The only thing measured is
`synthesize.synthesize_multi(state, tools)` -- agent-1 observe -> agent-2 design
(+ groundability redesign) -> agent-3 compose.

Cache is OFF so every call is a real billed round trip (this repo has been fooled
by disk-cache replays that looked like live calls).
"""
import os, sys, json, datetime

os.environ["DSPY_CACHE"] = "0"          # must be set BEFORE importing dspy_service
os.environ["TOOL_SYNTHESIS"] = "1"
os.environ["SYNTH_MULTI_AGENT"] = "1"
os.environ["DSPY_PROGRAM"] = "__seed_only__"

SVC = "/home/chahj578/Construction_OODlayer/src/respec/llm_service"
sys.path.insert(0, SVC)
os.chdir(SVC)

import dspy_service as S            # noqa: E402
import synthesize as SY             # noqa: E402
from tool_registry import build_tools   # noqa: E402

assert S.CACHE is False, "cache did not turn off -- abort, the numbers would be replays"
# 🔴 2026-09-03 (컨트롤러 판정, Task 9 fix round 2). `SY.multi_agent_enabled()` was deleted
# by Task 1 under D8 -- there is one synthesis lane now, so the old dual-lane switch this
# assert checked no longer exists in `synthesize.py` (see its own "(5) The 3-agent pipeline
# itself" comment). `SYNTH_MULTI_AGENT` still gets set above for `dspy_service.py`'s
# `/health` generation stamp only, not as a lane switch -- this probe does not need to
# re-check it.
assert SY.synthesis_enabled()

S._configure_dspy()                 # production LM + native-FC adapter. 0 calls.
import dspy                          # noqa: E402
LM = dspy.settings.lm
print("model=%s temperature=%s max_tokens=%s cache=%s"
      % (LM.model, LM.kwargs.get("temperature"), LM.kwargs.get("max_tokens"), S.CACHE))

# ---- the two observations -----------------------------------------------------------------
ZONE_STATE = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures_zone_state.txt"),
                  encoding="utf-8").read().rstrip("\n")

mild_req = S.MacroRequest(
    kind="battery", soc=0.5491454717560347, severity=0.5491454717560347, spare_count=8,
    agent_pending=1, progress=0.85, n_active=19,
    nl=("Robot R4's battery is degraded and now at about 55% charge; it is moving below "
        "its normal speed and will keep draining while it works."),
    descriptors=[0.4508545282439653, 0.41304347826086957, 0.4508545282439653,
                 0.2962962962962963, 0.8491803278688524, 0.6333333333333333],
    routing_kind="unknown:battery_mild",
    battery_pending_transports=1,
    battery_payload_proxy_max=2.2937600000000002,
    battery_payload_proxy_total=2.2937600000000002,
    battery_fleet_soc_median=0.9992821142262296, battery_higher_soc_robots=9,
    valid=["NOOP"],
    agents=[{"id": "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(4)", "label": "R4"}],
)
MILD_STATE = S._llm_input(mild_req)

TOOLS = build_tools(mild_req.agents, ["NOOP"])       # both lanes shipped valid=["NOOP"]
assert len(TOOLS) == 1 and TOOLS[0].name == "no_intervention"

CASES = [("mild_battery", "battery", MILD_STATE), ("zone", "zone", ZONE_STATE)]

out = {"when": datetime.datetime.now().isoformat(timespec="seconds"),
       "model": LM.model, "max_tokens": LM.kwargs.get("max_tokens"),
       "cache": S.CACHE, "cases": {}}

for name, kind, state in CASES:
    print("\n" + "=" * 90 + "\n== %s  (state %d chars)\n" % (name, len(state)) + "=" * 90)
    n_before = len(LM.history)
    led = SY.SynthesisLedger()                     # per-case ledger: |K| starts at 0
    rec = SY.synthesize_multi(state=state, tools=TOOLS, kind=kind, ledger=led)
    calls = LM.history[n_before:]
    rec["_n_lm_calls"] = len(calls)
    rec["_finish_reasons"] = []
    rec["_usage"] = []
    for h in calls:
        try:
            ch = (h.get("response").choices or [None])[0]
            rec["_finish_reasons"].append(getattr(ch, "finish_reason", None))
        except Exception as e:
            rec["_finish_reasons"].append("unreadable:%s" % type(e).__name__)
        u = h.get("usage") or {}
        rec["_usage"].append({k: u.get(k) for k in ("prompt_tokens", "completion_tokens")})
    out["cases"][name] = rec
    print("stages          =", rec.get("stages"))
    print("expressible     =", repr(rec.get("expressible")))
    print("synthesis_event =", rec.get("synthesis_event"), " ran =", rec.get("ran"))
    print("redesigned      =", rec.get("redesigned"),
          " ungrounded =", rec.get("ungrounded_params"))
    print("reach_first     =", repr(rec.get("reach_first")),
          " -> reach =", repr(rec.get("reach")))
    print("recomposed      =", rec.get("recomposed"),
          " spec_changed =", rec.get("spec_changed_by_feedback"),
          " redacted =", rec.get("compose_feedback_redacted"))
    print("recompose_err   =", rec.get("recompose_error"),
          " skipped =", rec.get("recompose_skipped"))
    print("expressible2    =", repr(rec.get("expressible_after_recompose")))
    print("body_first      =", repr((rec.get("body_first") or "")[:160]))
    print("tool_name       =", repr(rec.get("tool_name")))
    print("reach           =", repr(rec.get("reach")))
    print("body_names      =", rec.get("body_names"))
    # ---- A (2026-09-03): 구조화 인자 채널. 🔴 이걸 안 찍으면 유료 런을 하고도 못 본다.
    print("calls           =", rec.get("calls"))
    print("calls_match_body=", rec.get("calls_match_body"),
          " calls_flat =", rec.get("calls_flat"),
          " unreadable =", rec.get("calls_unreadable"),
          " | ", (rec.get("calls_flat_detail") or "")[:90])
    # 🔴 F8(2026-09-03)의 판정 대상은 바로 이 산문이다 — agent-2 가 **기전**을 골랐나,
    #    아니면 **효과**를 적었나. JSON 에만 있고 화면에 없으면 런을 하고도 못 읽는다.
    print("mechanism       =", repr((rec.get("mechanism") or "")[:420]))
    print("missing_prim    =", repr((rec.get("missing_primitive") or "")[:300]))
    print("tool_minted     =", repr(rec.get("tool_minted")), " reason =", rec.get("reason"))
    print("error           =", rec.get("error"))
    print("lm calls        =", rec["_n_lm_calls"], rec["_finish_reasons"], rec["_usage"])

# 🔴 Default lands in `results/` -- that path is gitignored, so a live run's raw JSON never
#    becomes a committed number nobody re-derived.
# 🔴 2026-09-03: `PROBE_OUT` 이 **상대경로면 저장이 죽는다** — 이 파일은 import 시점에
#    `os.chdir(SVC)` 를 하므로 상대경로가 `src/respec/llm_service/` 기준으로 풀린다. 실제로
#    한 번 그렇게 잃었다: 유료 10콜이 돌고 난 **뒤에** FileNotFoundError 가 나서 원본 기록이
#    통째로 사라졌다(화면 출력만 남았다). 이제 레포 루트 기준으로 풀고 디렉토리도 만든다.
#    🔴 그리고 저장을 **모든 LM 호출보다 뒤가 아니라, 실패해도 잃지 않도록** 절대경로로
#    먼저 확정해 둔다.
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_p = os.environ.get("PROBE_OUT") or os.path.join("results", "synth_multi_lane_result.json")
dst = _p if os.path.isabs(_p) else os.path.join(REPO, _p)
os.makedirs(os.path.dirname(dst), exist_ok=True)
json.dump(out, open(dst, "w", encoding="utf-8"), indent=1, ensure_ascii=False, default=str)
print("\nwrote", dst)
print("TOTAL BILLED ROUND TRIPS =", sum(c["_n_lm_calls"] for c in out["cases"].values()))
