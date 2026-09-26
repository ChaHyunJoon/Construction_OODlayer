"""Scripted fake LM for the zone-repair proposal lane (T9). **Hand-written test fixture -- not model output.**

No network, no provider, no dspy disk cache: `forward` is overridden, so `dspy.LM`'s cached litellm path is never
entered. Each call pops the next scripted step and asserts the stage it was asked for:

    {"expect": "observe"|"design"|"compose"|"compose_revision",
     "fields": {...}            # formatted like the adapter expects (ChatAdapter by default), or
     "json": {...}              # a JSON object body (the JSONAdapter fallback reads this), or
     "text": "..."              # raw text (e.g. garbage to force the adapter's hidden retry), or
     "raise": "..."             # a provider error raised from forward()
     "fields_fn": f(messages)   # fields computed from the prompt (the fake plays the model; the harness computes nothing)
     "finish_reason": "stop",   # "length" = the provider cut the answer at the token cap
     "usage": {"prompt_tokens": .., "completion_tokens": .., "total_tokens": ..} | None,
     "cost": 0.0001 | None}                                         # None = unmeasured

`seen` keeps every call's stage, messages and kwargs -- the prompt audit reads what was actually sent.
Used by `src/respec/llm_service/test_zone_repair_lane.py` (in-process) and `fake_lm_service.py` (a local service
for the Julia end-to-end episode).
"""
import json

from dspy.dsp.utils.utils import dotdict
from dspy.utils.dummies import DummyLM


def stage_of(messages):
    sysmsg = (messages or [{}])[0].get("content", "") or ""
    if "`rejected`" in sysmsg:
        return "compose_revision"
    if "`candidates`" in sysmsg:
        return "compose"
    if "`expressible`" in sysmsg:
        return "design"
    return "observe"


class ScriptedLM(DummyLM):
    def __init__(self, script, adapter=None):
        super().__init__([], adapter=adapter)
        self.cache = False
        self.script = list(script)
        self.seen = []

    def forward(self, prompt=None, messages=None, **kwargs):
        messages = messages or [{"role": "user", "content": prompt}]
        st = stage_of(messages)
        # kwargs = what a real LM would send: its own defaults (e.g. max_retries=0 from the copy) + this call's
        self.seen.append({"stage": st, "messages": messages, "kwargs": {**self.kwargs, **kwargs}})
        if not self.script:
            raise AssertionError("fake LM: unscripted call at stage %s" % st)
        step = self.script.pop(0)
        want = step.get("expect", st)
        assert want == st, "fake LM: expected a %s call, got %s" % (want, st)
        if "raise" in step:
            raise RuntimeError("fake provider error: %s" % step["raise"])
        if "fields_fn" in step:                     # the reply depends on what was asked (e.g. a revision names ids)
            text = self._format_answer_fields(dict({"reasoning": "scripted"}, **step["fields_fn"](messages)))
        elif "text" in step:
            text = step["text"]
        elif "json" in step:
            text = json.dumps(dict({"reasoning": "scripted"}, **step["json"]))
        else:
            text = self._format_answer_fields(dict({"reasoning": "scripted"}, **step["fields"]))
        usage = step.get("usage", {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30})
        resp = dotdict(choices=[dotdict(message=dotdict(content=text, tool_calls=None),
                                        finish_reason=step.get("finish_reason", "stop"))],
                       model="fake-repair-lm")
        if usage is not None:                       # "usage": None = the provider reported no usage
            resp["usage"] = dotdict(**usage)
        cost = step.get("cost", 0.0001)             # "cost": None = no priced cost (dspy reads _hidden_params)
        if cost is not None:
            resp["_hidden_params"] = {"response_cost": cost}
        return resp


# ---- canned steps ------------------------------------------------------------------------------------------
OBSERVE = {"expect": "observe", "fields": {"reasoning_log": "A no-go zone stops the transport unit that must "
                                                            "drive to one goal; the work behind it is frozen."}}
DESIGN_FIRES = {"expect": "design", "fields": {
    "expressible": False, "tool_name": "reroute_frozen_work",
    "params": "{}", "mechanism": "change which robots are committed to the frozen work so the re-solve can "
                                 "hand it to units whose route is open; the way is open"}}


def tool(name, body_lines, **extra):
    """A complete candidate object as the compose stage would emit it."""
    code = "function %s(env)\n%s\nend" % (name, "\n".join("    " + l for l in body_lines))
    d = {"impl_name": name, "surface": "sched", "reversible": False, "claimed_effects": ["assignment"],
         "impl_code": code, "params": {}, "calls": [{"primitive": name, "args": {}}]}
    d.update(extra)
    return d


# A NON-GEOMETRIC candidate: releases one robot's pending assignments and lets the harness re-solve
# (same shape as test/fixtures/repair_verification/t6_tool_sources.jl "release" -- a hand-written fixture).
RELEASE = tool("t9_release_one!", [
    "ws = sort!([node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n) &&",
    "            !(node_id(n) in Set(vcat(values(SPARE_POOLS[])...)))]; by = string)",
    "for w in ws",
    "    r = release_pending_assignments!(env, build_invariant(env); agent = string(w))",
    "    n = r isa AbstractVector ? length(r) : 0",
    "    n > 0 && return (; status = :success)",
    "end",
    "return (; status = :success)"])
# Rejected at t0 (registration: unknown call) -- exercises the preflight -> revision channel.
BROKEN = tool("t9_broken!", ["t9_no_such_helper(env)", "return (; status = :success)"])
FIXED = dict(tool("t9_fixed!", ["return (; status = :success)"]))
