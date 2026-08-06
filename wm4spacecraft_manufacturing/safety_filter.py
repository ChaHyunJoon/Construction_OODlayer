#!/usr/bin/env python
"""safety_filter.py -- LLM 이 낸 **조합 행동**을 실행 전에 거르는 3층 필터.

왜 필요한가
-----------
행동공간을 조합으로 열면 LLM 은 엔진이 실행할 수 없거나, 실행은 되지만 의미가 모순이거나,
자원 불변식을 깨는 제안을 낼 수 있다. LLM 을 형식 명세 생성기로 쓰는 연구들은 예외 없이
**검사기를 함께 둔다** -- AutoTAMP 는 LLM 번역 결과의 구문 오류와 의미 오류를 분리해서
잡고 재프롬프트하며, 산업 HITL 지침은 승인 로직을 "모델이 런타임에 협상하는 것"이 아니라
**워크플로 실행 계층에서 강제**하라고 못박는다. 그래서 이 필터는 프롬프트가 아니라 코드다.

3층 (PLAN_ACTION_GROWTH.md §4 [4])
  L1 문법  : spec 타입이 실재하는가, 인자 개수/타입/도메인이 맞는가
  L2 의미  : 조합이 모순이 아닌가 (같은 로봇을 교체하면서 동시에 미루는 등)
  L3 불변식: 스페어 잔량 >= 요구량, 금지구역이 필수 경로를 전부 막지 않는가,
             비가역(스페어 소모) 행동이 필요 이상으로 섞여 있지 않은가

거부되면 canonical 로 폴백하고 **거부 사유를 남긴다**. 이 로그는 두 가지로 쓰인다:
  (1) LLM 프롬프트 개선의 재료
  (2) "LLM 이 유효한 조합을 낼 확률"이라는 **측정값** 자체
      (PLAN §7 R4: 조합 제안 능력은 아직 미검증이고, 거부율이 그 측정이다)

사용
    from safety_filter import SafetyFilter, Ctx
    f = SafetyFilter()
    v = f.check([{"type": "ForbidAgent", "agent": "R3", "after": 0.0},
                 {"type": "ReformTeam"}],
                Ctx(agents={"R3"}, spares_left=2, zones={"z1"}, assemblies={"A1"}))
    v.ok, v.layer, v.reason
"""
import os, sys, json, time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))

# ==========================================================================================
#  L1 문법: spec 타입과 인자 스키마. src/respec/spec_dsl.jl 의 struct 정의와 **1:1** 이어야 한다.
# ==========================================================================================
#   필드명 -> ("종류", 필수여부)   종류: id / float / symbol
SPEC_SCHEMA = {
    "ForbidAgent":       {"agent": ("id", True), "after": ("float", True)},
    "ForbidWindow":      {"node": ("id", True), "t_lo": ("float", True), "t_hi": ("float", True)},
    "ForbidZone":        {"assembly": ("id", True), "zone": ("symbol", True)},
    "ReplaceAgent":      {"agent": ("id", True), "after": ("float", True)},
    "ReformTeam":        {},
    "DeprioritizeAgent": {"agent": ("id", True), "weight": ("float", True)},
}

# 스페어를 소모하는 spec (= 비가역). features_agnostic.psi 의 a_consumes_spare 와 같은 사실.
CONSUMES_SPARE = {"ReplaceAgent"}

MAX_SPECS = 3          # 조합 크기 상한. 조합폭발(PLAN R2)에 대한 1차 방어선.

# ==========================================================================================
#  L2 추가 규칙: **혼합 종류 조합은 현재 엔진이 실행하지 못한다** (2026-08-02 실측)
# ==========================================================================================
# `RespecProposal.constraints` 는 Vector 이지만, `maybe_respecify!`(replan.jl:273)의 디스패치는
# **첫 매치 승리** 체인이고 각 분기가 단일 종류를 전제한다:
#     _is_robot_fault (replan.jl:144)  = length(constraints)==1 && ForbidAgent   <- 1개일 때만!
#     _is_zone_respec / _is_robot_replace / _is_reform = any(...)                 <- 먼저 잡히면 return
#     _is_deprioritize                 = all(...)
# 그래서 [ForbidAgent, ReformTeam] 을 넣으면 `_is_reform` 이 먼저 잡아 **ReformTeam 만 실행**되고
# ForbidAgent 는 조용히 사라진다. 실측: 조합 팔과 ReformTeam 단독 팔의 결과가 완전히 동일했다
# (closed 201/313, label_seconds 372.08).
#
# 조용한 무시는 최악이다 — 측정은 "조합을 실행했다"고 기록하는데 실제로는 단일 spec 을 실행한
# 것이므로, 그 위에 쌓는 모든 결론이 허구가 된다. 엔진에 다중 spec 디스패처가 생기기 전까지
# **여기서 큰 소리로 막는다**. 생기면 `allow_mixed_kinds=True` 로 열면 된다.
def _kind_group(spec_type):
    """엔진 디스패처가 이 spec 을 어느 분기로 보내는가."""
    return {"ForbidAgent": "reassign", "ForbidWindow": "generic",
            "ForbidZone": "zone", "ReplaceAgent": "replace",
            "ReformTeam": "reform", "DeprioritizeAgent": "soft"}.get(spec_type, "generic")


@dataclass
class Ctx:
    """결정 시점의 실행 맥락. 필터가 불변식을 검사하려면 이만큼은 알아야 한다."""
    agents: Set[str] = field(default_factory=set)          # 존재하는 로봇 id
    spares_left: int = 0                                   # 남은 스페어 수
    zones: Set[str] = field(default_factory=set)           # RESTRICTION_ZONES 의 키
    assemblies: Set[str] = field(default_factory=set)      # 조립체 id
    nodes: Set[str] = field(default_factory=set)           # 스케줄 노드 id (ForbidWindow 대상)
    t_now: float = 0.0
    horizon: float = float("inf")                          # 남은 계획 지평(있으면)
    faulted_agents: Set[str] = field(default_factory=set)  # 지금 고장난 로봇
    clear_staging_exists: bool = True                      # 금지구역 밖 적치 위치가 있는가


@dataclass
class Verdict:
    ok: bool
    layer: Optional[str] = None       # 거부한 층 ("L1"/"L2"/"L3")
    reason: Optional[str] = None
    detail: Dict[str, Any] = field(default_factory=dict)


class SafetyFilter:
    def __init__(self, log_path: str = "artifacts_mdp/safety_filter_log.jsonl",
                 max_specs: int = MAX_SPECS, strict_ids: bool = True,
                 allow_mixed_kinds: bool = False):
        self.log_path = os.path.join(HERE, log_path) if log_path else None
        self.max_specs = max_specs
        # strict_ids=False 면 id 존재검사를 건너뛴다(맥락을 모르는 단위테스트용).
        self.strict_ids = strict_ids
        # 엔진에 다중 spec 디스패처가 생기면 True 로 열 것 (위 주석 참조).
        self.allow_mixed_kinds = allow_mixed_kinds
        self.stats = {"total": 0, "pass": 0, "L1": 0, "L2": 0, "L3": 0}

    # ---------------------------------------------------------------- L1 문법
    def _l1(self, specs: List[Dict[str, Any]], ctx: Ctx) -> Optional[Verdict]:
        if not isinstance(specs, list):
            return Verdict(False, "L1", "제안이 리스트가 아니다", {"got": type(specs).__name__})
        if len(specs) == 0:
            return Verdict(False, "L1", "빈 조합 (NOOP 을 뜻하려면 명시적으로 NOOP 이어야 한다)")
        if len(specs) > self.max_specs:
            return Verdict(False, "L1", f"조합 크기 {len(specs)} > 상한 {self.max_specs}")
        for i, s in enumerate(specs):
            if not isinstance(s, dict) or "type" not in s:
                return Verdict(False, "L1", f"spec[{i}] 에 type 이 없다", {"spec": s})
            t = s["type"]
            if t not in SPEC_SCHEMA:
                # **여기가 닫힌 어휘의 경계다.** LLM 이 새 타입을 발명하면 여기서 막힌다.
                return Verdict(False, "L1", f"알 수 없는 spec 타입: {t}",
                               {"known": sorted(SPEC_SCHEMA)})
            schema = SPEC_SCHEMA[t]
            for k, (kind, required) in schema.items():
                if k not in s:
                    if required:
                        return Verdict(False, "L1", f"{t} 에 필수 인자 {k} 가 없다", {"spec": s})
                    continue
                v = s[k]
                if kind == "float":
                    try:
                        fv = float(v)
                    except Exception:
                        return Verdict(False, "L1", f"{t}.{k} 가 수치가 아니다", {"got": v})
                    if fv != fv or fv in (float("inf"), float("-inf")):
                        return Verdict(False, "L1", f"{t}.{k} 가 유한하지 않다", {"got": v})
                elif kind in ("id", "symbol") and not isinstance(v, str):
                    return Verdict(False, "L1", f"{t}.{k} 는 문자열이어야 한다", {"got": repr(v)})
            extra = set(s) - set(schema) - {"type"}
            if extra:
                return Verdict(False, "L1", f"{t} 에 정의되지 않은 인자: {sorted(extra)}")
            # 도메인 검사 (시간창의 순서 등)
            if t == "ForbidWindow" and float(s["t_lo"]) >= float(s["t_hi"]):
                return Verdict(False, "L1", "ForbidWindow 의 t_lo >= t_hi")
            if t in ("ForbidAgent", "ReplaceAgent") and float(s["after"]) < 0:
                return Verdict(False, "L1", f"{t}.after 가 음수")
            if t == "DeprioritizeAgent" and not (0.0 < float(s["weight"]) <= 1e4):
                return Verdict(False, "L1", "DeprioritizeAgent.weight 가 (0, 1e4] 밖")
        return None

    # ---------------------------------------------------------------- L2 의미
    def _l2(self, specs: List[Dict[str, Any]], ctx: Ctx) -> Optional[Verdict]:
        # (0) 엔진 실행가능성: 서로 다른 디스패치 분기로 가는 spec 을 섞으면 하나만 실행된다.
        if not self.allow_mixed_kinds:
            groups = {_kind_group(s["type"]) for s in specs}
            if len(groups) > 1:
                return Verdict(False, "L2",
                               "혼합 종류 조합은 현재 엔진이 하나만 실행한다"
                               " (maybe_respecify! 는 첫 매치 승리 디스패치)",
                               {"groups": sorted(groups),
                                "evidence": "arm5[ForbidAgent+ReformTeam] == arm4[ReformTeam] "
                                            "(closed 201/313, label_seconds 372.08)"})

        by_type = {}
        for s in specs:
            by_type.setdefault(s["type"], []).append(s)

        # (a) 같은 spec 타입이 같은 대상에 두 번
        seen = set()
        for s in specs:
            key = (s["type"], s.get("agent"), s.get("assembly"), s.get("node"))
            if key in seen:
                return Verdict(False, "L2", f"같은 대상에 같은 spec 이 중복: {key}")
            seen.add(key)

        # (b) 교체한 로봇을 동시에 미루거나 금지하는 것은 무의미하다
        #     (교체는 그 로봇을 빼고 스페어를 넣는 것이므로, 뒤이은 제약은 대상이 사라진다)
        replaced = {s["agent"] for s in by_type.get("ReplaceAgent", [])}
        for t in ("DeprioritizeAgent", "ForbidAgent"):
            for s in by_type.get(t, []):
                if s["agent"] in replaced:
                    return Verdict(False, "L2",
                                   f"{s['agent']} 를 교체하면서 동시에 {t} — 대상이 사라진다")

        # (c) 미루기와 금지를 같은 로봇에 동시에: 금지가 미루기를 포함(strictly stronger)
        depri = {s["agent"] for s in by_type.get("DeprioritizeAgent", [])}
        forbid = {s["agent"] for s in by_type.get("ForbidAgent", [])}
        both = depri & forbid
        if both:
            return Verdict(False, "L2", f"{sorted(both)} 에 Deprioritize 와 Forbid 가 동시 — "
                                        f"Forbid 가 이미 더 강하다")

        # (d) 고장난 로봇에 Deprioritize 만 거는 것은 대응이 아니다(정지한 것을 미룬다)
        for s in by_type.get("DeprioritizeAgent", []):
            if s["agent"] in ctx.faulted_agents and "ReplaceAgent" not in by_type \
                    and "ForbidAgent" not in by_type:
                return Verdict(False, "L2",
                               f"{s['agent']} 는 이미 고장 상태 — 미루기는 아무것도 바꾸지 않는다")

        # (e) 같은 조립체를 두 구역에 대해 동시에 재배치
        asm = [s["assembly"] for s in by_type.get("ForbidZone", [])]
        if len(asm) != len(set(asm)):
            return Verdict(False, "L2", "같은 조립체에 ForbidZone 이 둘 이상 — 재배치가 충돌한다")
        return None

    # ---------------------------------------------------------------- L3 불변식
    def _l3(self, specs: List[Dict[str, Any]], ctx: Ctx) -> Optional[Verdict]:
        # (a) 존재하지 않는 대상
        if self.strict_ids:
            for s in specs:
                if "agent" in s and ctx.agents and s["agent"] not in ctx.agents:
                    return Verdict(False, "L3", f"존재하지 않는 로봇: {s['agent']}")
                if "zone" in s and ctx.zones and s["zone"] not in ctx.zones:
                    return Verdict(False, "L3", f"존재하지 않는 구역: {s['zone']}")
                if "assembly" in s and ctx.assemblies and s["assembly"] not in ctx.assemblies:
                    return Verdict(False, "L3", f"존재하지 않는 조립체: {s['assembly']}")
                if "node" in s and ctx.nodes and s["node"] not in ctx.nodes:
                    return Verdict(False, "L3", f"존재하지 않는 노드: {s['node']}")

        # (b) 스페어 잔량 -- **비가역 자원**이다. 초과 예약이 과거에 실제로 완주를 막았다.
        need = sum(1 for s in specs if s["type"] in CONSUMES_SPARE)
        if need > ctx.spares_left:
            return Verdict(False, "L3", f"스페어 부족: 요구 {need} > 잔량 {ctx.spares_left}")

        # (c) 금지구역을 걸었는데 비켜 놓을 자리가 없다
        #     (엔진의 verifier 도 find_clear_staging_center 가 실패하면 라인정지로 폴백한다)
        if any(s["type"] == "ForbidZone" for s in specs) and not ctx.clear_staging_exists:
            return Verdict(False, "L3", "ForbidZone: 구역 밖 적치 위치가 없다 — 필수 경로를 전부 막는다")

        # (d) 계획 지평 밖의 시간창은 아무 효과가 없다(= 조용한 NOOP). 조용한 무효화를 거부한다.
        for s in specs:
            if s["type"] == "ForbidWindow" and float(s["t_lo"]) >= ctx.horizon:
                return Verdict(False, "L3", "ForbidWindow 가 계획 지평 밖 — 아무 효과가 없다")
            if s["type"] in ("ForbidAgent", "ReplaceAgent") and float(s["after"]) >= ctx.horizon:
                return Verdict(False, "L3", f"{s['type']}.after 가 계획 지평 밖 — 효과 없음")
        return None

    # ---------------------------------------------------------------- 진입점
    def check(self, specs, ctx: Ctx, meta: Optional[dict] = None) -> Verdict:
        self.stats["total"] += 1
        v = self._l1(specs, ctx) or self._l2(specs, ctx) or self._l3(specs, ctx)
        if v is None:
            v = Verdict(True)
            self.stats["pass"] += 1
        else:
            self.stats[v.layer] += 1
        self._log(specs, ctx, v, meta or {})
        return v

    def _log(self, specs, ctx, v, meta):
        if not self.log_path:
            return
        try:
            os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
            rec = {"t": time.time(), "ok": v.ok, "layer": v.layer, "reason": v.reason,
                   "detail": v.detail, "specs": specs,
                   "ctx": {"spares_left": ctx.spares_left, "n_agents": len(ctx.agents),
                           "clear_staging": ctx.clear_staging_exists}, "meta": meta}
            with open(self.log_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
        except Exception:
            pass          # 로깅 실패가 결정 경로를 막아서는 안 된다

    def rejection_rate(self):
        t = max(1, self.stats["total"])
        return {k: self.stats[k] / t for k in ("pass", "L1", "L2", "L3")}


# ==========================================================================================
#  자체 검사 -- 의도적으로 만든 불량 조합이 각 층에서 잡히는가
# ==========================================================================================
def _selftest():
    ctx = Ctx(agents={"R1", "R2", "R3"}, spares_left=1, zones={"z1"},
              assemblies={"A1", "A2"}, nodes={"n1"}, horizon=100.0,
              faulted_agents={"R2"}, clear_staging_exists=True)
    f = SafetyFilter(log_path=None)

    cases = [
        # (설명, 제안, 기대 층 None=통과)
        ("정상: 단일 Replace", [{"type": "ReplaceAgent", "agent": "R1", "after": 0.0}], None),
        # 2026-08-02: 혼합 종류 조합은 엔진이 하나만 실행하므로 지금은 **거부**가 정답이다.
        ("L2: 혼합조합 [ForbidAgent, ReformTeam] (엔진 미지원)",
         [{"type": "ForbidAgent", "agent": "R1", "after": 0.0}, {"type": "ReformTeam"}], "L2"),
        ("L2: 혼합조합 [Deprioritize, ForbidWindow] (엔진 미지원)",
         [{"type": "DeprioritizeAgent", "agent": "R1", "weight": 50.0},
          {"type": "ForbidWindow", "node": "n1", "t_lo": 1.0, "t_hi": 9.0}], "L2"),
        ("L1: 없는 spec 타입 (LLM 이 발명)",
         [{"type": "RestrictCapability", "agent": "R1", "skill": "manip"}], "L1"),
        ("L1: 필수 인자 누락", [{"type": "ReplaceAgent", "agent": "R1"}], "L1"),
        ("L1: 시간창 역전",
         [{"type": "ForbidWindow", "node": "n1", "t_lo": 9.0, "t_hi": 1.0}], "L1"),
        ("L1: 조합 크기 초과",
         [{"type": "ReformTeam"}, {"type": "ReformTeam"}, {"type": "ReformTeam"},
          {"type": "ReformTeam"}], "L1"),
        ("L2: 교체하면서 동시에 미루기",
         [{"type": "ReplaceAgent", "agent": "R1", "after": 0.0},
          {"type": "DeprioritizeAgent", "agent": "R1", "weight": 50.0}], "L2"),
        ("L2: 같은 로봇에 Deprioritize + Forbid",
         [{"type": "DeprioritizeAgent", "agent": "R1", "weight": 50.0},
          {"type": "ForbidAgent", "agent": "R1", "after": 0.0}], "L2"),
        ("L2: 고장난 로봇을 미루기만",
         [{"type": "DeprioritizeAgent", "agent": "R2", "weight": 50.0}], "L2"),
        ("L2: 같은 조립체에 ForbidZone 둘",
         [{"type": "ForbidZone", "assembly": "A1", "zone": "z1"},
          {"type": "ForbidZone", "assembly": "A1", "zone": "z1"}], "L2"),
        ("L3: 없는 로봇", [{"type": "ReplaceAgent", "agent": "R9", "after": 0.0}], "L3"),
        ("L3: 스페어 초과 예약",
         [{"type": "ReplaceAgent", "agent": "R1", "after": 0.0},
          {"type": "ReplaceAgent", "agent": "R3", "after": 0.0}], "L3"),
        ("L3: 지평 밖 시간창",
         [{"type": "ForbidWindow", "node": "n1", "t_lo": 500.0, "t_hi": 600.0}], "L3"),
    ]
    npass = 0
    print("안전 필터 자체 검사")
    for desc, specs, expect in cases:
        v = f.check(specs, ctx)
        got = None if v.ok else v.layer
        ok = (got == expect)
        npass += ok
        mark = "OK " if ok else "FAIL"
        print(f"  [{mark}] {desc:<38} 기대={expect or '통과':<4} 실제={got or '통과':<4}"
              f"  {v.reason or ''}")

    # 스페어가 없을 때 ForbidZone 은 여전히 통과해야 한다(스페어를 안 쓰는 행동)
    f2 = SafetyFilter(log_path=None)
    v = f2.check([{"type": "ForbidZone", "assembly": "A1", "zone": "z1"}],
                 Ctx(agents={"R1"}, spares_left=0, zones={"z1"}, assemblies={"A1"},
                     horizon=100.0))
    extra_ok = v.ok
    print(f"  [{'OK ' if extra_ok else 'FAIL'}] 스페어 0 에서도 비소모 행동은 통과")
    total = len(cases) + 1
    npass += extra_ok
    print(f"\n  {npass}/{total} 통과")
    return npass == total


if __name__ == "__main__":
    sys.exit(0 if _selftest() else 1)
