"""The REAL `dspy_service` app with a SCRIPTED FAKE LM, for the T9 Julia end-to-end episode only.

    FAKE_REPAIR_SCRIPT=general|geometry REPAIR_ABLATION=all .venv/bin/python fake_lm_service.py <port>

🔴 Zero provider calls, by construction and by measurement:
  * every credential-shaped env var is deleted before anything is imported;
  * litellm's provider entry points are replaced by a counter that raises (`/__fake_lm_stats.provider_calls`);
  * the only LM the app ever sees is `ScriptedLM`, whose `forward` never reaches litellm (and has no disk cache).
The generation stamps (`/health`) are the real ones -- the code fingerprint is this tree's `llm_service` source, so the
Julia side's generation gate and provenance checks run exactly as in production. The scripts play the MODEL
(they may read the prompt); nothing here is a trusted component.
"""
import os
import re
import sys

for _k in list(os.environ):
    if re.search(r"(API_KEY|_TOKEN|SECRET|PASSWORD)", _k):
        del os.environ[_k]
os.environ["TOOL_SYNTHESIS"] = "1"
os.environ["SYNTH_MULTI_AGENT"] = "1"
os.environ.setdefault("DSPY_CACHE", "0")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
for _p in (os.path.join(ROOT, "src", "respec", "llm_service"), HERE):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy)
import dspy  # noqa: E402
import litellm  # noqa: E402
from fake_repair_lm import BROKEN, DESIGN_FIRES, FIXED, OBSERVE, RELEASE, ScriptedLM  # noqa: E402

PROVIDER = {"calls": 0}


def _forbidden(*a, **k):
    PROVIDER["calls"] += 1
    raise RuntimeError("fake_lm_service: a real provider entry point was called")


for _n in ("completion", "acompletion", "responses", "aresponses", "text_completion"):
    if hasattr(litellm, _n):
        setattr(litellm, _n, _forbidden)


def _rejected_ids(messages):
    txt = messages[-1].get("content", "")
    blk = txt.split("[[ ## rejected ## ]]", 1)[-1].split("[[ ## max_candidates ## ]]", 1)[0]
    return re.findall(r'"proposal_id":\s*"([^"]+)"', blk)


def _revise_general(messages):
    return {"wrote": True, "candidates": [dict(FIXED, rewrite_of=_rejected_ids(messages)[0])]}


def _configs(messages):
    txt = messages[-1].get("content", "")
    return [(m.group(1), float(m.group(2)), float(m.group(3))) for m in
            re.finditer(r'config_ref "([^"]+)": x=([-0-9.e]+) y=([-0-9.e]+) staging_radius=\S+ closed=no', txt)]


def _patches(messages):
    ref, x, y = _configs(messages)[0]            # the fake "model" chooses: first open staging config, a small shift
    return {"candidates": [{"writes": [{"config_ref": ref, "x": x + 0.3, "y": y - 0.2}], "rationale": "fake"},
                           {"writes": [{"config_ref": "AssemblyID(999999)", "x": 0.0, "y": 0.0}], "rationale": "fake"}]}


def _revise_patches(messages):
    ref, x, y = _configs(messages)[0]
    return {"candidates": [{"writes": [{"config_ref": ref, "x": x + 0.25, "y": y - 0.25}],
                            "rewrite_of": _rejected_ids(messages)[0], "rationale": "fake"}]}


SCRIPTS = {
    "general": [OBSERVE, DESIGN_FIRES,
                {"expect": "compose", "fields": {"wrote": True, "needs": "", "candidates": [RELEASE, BROKEN]}},
                {"expect": "compose_revision", "fields_fn": _revise_general}],
    "geometry": [OBSERVE, DESIGN_FIRES, {"expect": "compose", "fields_fn": _patches},
                 {"expect": "compose_revision", "fields_fn": _revise_patches}],
}
LM = ScriptedLM(SCRIPTS[os.environ["FAKE_REPAIR_SCRIPT"]])
svc._configure_dspy = lambda: dspy.configure(lm=LM, adapter=svc.build_adapter())
svc._repair_lm = lambda: LM


@svc.app.get("/__fake_lm_stats")
def _fake_lm_stats():
    return {"provider_calls": PROVIDER["calls"], "fake_calls": len(LM.seen),
            "stages": [s["stage"] for s in LM.seen], "remaining_script": len(LM.script),
            # the zone-repair binding sensor must reach the observe prompt (and only the zone-repair lane renders it)
            "observe_has_bindings": any("ROBOTS AND THEIR COMMITTED WORK" in (m.get("content") or "")
                                        for s in LM.seen if s["stage"] == "observe" for m in s["messages"]),
            "max_retries_seen": sorted({str(s["kwargs"].get("max_retries")) for s in LM.seen}),
            "credential_env_left": sorted(k for k in os.environ if re.search(r"(API_KEY|_TOKEN|SECRET|PASSWORD)", k))}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(svc.app, host="127.0.0.1", port=int(sys.argv[1]), log_level="warning")
