#!/usr/bin/env python
"""
translate_eval.py -- FAST, env-free iteration on the LLM translation layer.

Scores ONLY translation (DSL kind + target id) against a cached fixture
(tools/llm_fixture.json, produced once by tools/dump_llm_fixture.jl). No Julia,
no env build, no MILP, no uvicorn -- it imports propose() fresh and calls it
in-process, so prompt/schema edits in src/respec/llm_service/ take effect on the
very next run. This is the inner loop for tuning the prompt/schema; the full
behavioral metric (eval_respec_ood.jl) is only run to confirm a change.

Run with the hjcnlp interpreter (the one that has `anthropic`):
    HJC="C:/Users/chahj/PythonCodes/venv/hjcnlp/Scripts/python.exe"
    "$HJC" tools/translate_eval.py            # all cases, 2 samples each
    "$HJC" tools/translate_eval.py --quick    # zone_closure only, 1 sample/paraphrase
    "$HJC" tools/translate_eval.py --case zone_closure --samples 3

Model: inherits RESPEC_MODEL (propose.py default = claude-opus-4-8, the PRODUCTION
model). Do NOT silently swap to a weaker model -- the point is to test the prompt
on the model that ships. Set RESPEC_MODEL only for a deliberate cheap structural
smoke. Needs ANTHROPIC_API_KEY. Exit code 0 iff every scored trial passed.
"""
# =============================================================================
# [한국어 설명]
#  이 파일이 하는 일:
#   - LLM "번역(translation) 레이어"만 빠르게 채점하는 테스트 스크립트.
#   - 사람이 자연어(NL)로 쓴 OOD 상황("로봇 3 고장났다", "남쪽 구역 폐쇄" 등)을
#     propose()에 넣으면, LLM이 DSL 제약(constraint)으로 번역해 준다.
#   - 그 번역 결과의 kind(ForbidAgent / ForbidWindow / DeprioritizeAgent 등)와
#     target id(어느 로봇/노드를 가리키는지)가 정답(gold)과 맞는지 점수를 매긴다.
#
#  프로젝트에서의 역할:
#   - ConstructionBots는 다중 로봇 건설 시뮬레이터이고, 예기치 못한 상황(OOD)이
#     생기면 LLM/surrogate "re-spec" 레이어가 계획을 고쳐 쓴다.
#   - 이 스크립트는 그중 "자연어 -> DSL 번역" 부분만 떼어내, Julia/시뮬레이터
#     빌드 없이(env-free) 아주 빠르게 반복 테스트하는 "안쪽 루프(inner loop)"다.
#   - 실제 동작(behavioral) 검증은 무겁게 eval_respec_ood.jl 로 따로 한다.
#
#  문법 참고 (파이썬 초보용):
#   · """ ... """  = 모듈/함수 맨 위 여러 줄 문자열 = docstring(설명문).
#   · argparse     = 커맨드라인 옵션(--quick, --case ...) 파싱 라이브러리.
#   · {x for x in ...}  = set(집합) comprehension, [x for x in ...] = list comprehension.
#   · f"...{변수}..."   = f-string, 중괄호 안 파이썬 값을 문자열에 바로 끼워 넣음.
#   · json.load(f) = 파일에서 JSON을 읽어 dict/list로 변환.
#   · sys.exit(코드) = 프로그램 종료(0=성공, 그 외=실패). CI가 이 코드로 통과여부 판단.
#   · dict(a=1, b=2) = 키워드로 dict 만들기 = {"a":1, "b":2} 와 같음.
#   · c.get("kind")  = dict에서 키가 없어도 에러 없이 None 반환(안전한 조회).
# =============================================================================
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))   # 이 스크립트가 있는 폴더(tools/)
ROOT = os.path.dirname(HERE)                         # 프로젝트 최상위 폴더
SVC = os.path.join(ROOT, "src", "respec", "llm_service")  # LLM 번역 서비스 코드 위치
sys.path.insert(0, SVC)  # import propose/schema straight from the service dir
# ↑ sys.path 맨 앞에 서비스 폴더를 넣어, 아래에서 `from propose import propose`가
#   그 폴더의 최신 코드를 바로 불러오게 한다(프롬프트/스키마 수정이 즉시 반영됨).

FIXTURE_PATH = os.path.join(HERE, "llm_fixture.json")  # 미리 덤프해 둔 씬(scene) 고정 데이터


# 캐시된 fixture(JSON) 파일을 읽어 dict로 반환. 없으면 만드는 방법을 알려주고 종료.
def _load_fixture():
    if not os.path.exists(FIXTURE_PATH):
        sys.exit(f"ERROR: {FIXTURE_PATH} missing. Build it once:\n"
                 f"    julia +lts --project=. tools/dump_llm_fixture.jl")
    with open(FIXTURE_PATH, encoding="utf-8") as f:
        return json.load(f)


# --- Translation eval cases (MIRROR eval_respec_ood.jl, translation axis only) ----
# Each resolves its gold target(s) from the fixture, so they stay correct across env
# rebuilds. `score` returns (kind_ok, target_ok, emitted_repr).
# 채점 케이스 정의부. 정답 target을 fixture에서 그때그때 뽑으므로 env를 다시 빌드해도
# 정답이 어긋나지 않는다. 각 score 함수는 (kind_ok, target_ok, 표시용문자열)을 돌려준다.

# fixture 안 노드 중 label에 "south"가 든 노드들의 id 집합(set)을 반환.
def _south_nodes(fx):
    return {nd["id"] for nd in fx["nodes"] if "south" in nd["label"]}


# "로봇 3"에 해당하는 agent의 id를 찾아 반환(정확 매칭 실패 시 "RobotID(3)" 기본값).
def _robot3_agent(fx):
    for a in fx["agents"]:
        if a["id"] == "RobotID(3)" or "3" in (a.get("label") or ""):  # a.get(...) or "" : label이 None이어도 안전
            return a["id"]
    return "RobotID(3)"


# proposal(LLM이 낸 결과)의 constraints 중 주어진 kind인 것만 골라 list로 반환.
def _constraints(proposal, kind):
    return [c for c in proposal.get("constraints", []) if c.get("kind") == kind]


# robot_fault 케이스 채점: 결과가 ForbidAgent(로봇 3 금지)인지 검사.
def _score_forbidagent(proposal, fx):
    tgt = _robot3_agent(fx)
    cs = _constraints(proposal, "ForbidAgent")
    if not cs:
        return False, False, f"no ForbidAgent (got {[c.get('kind') for c in proposal.get('constraints', [])]})"
    c = cs[0]
    ok = (c.get("agent") == tgt)   # 대상 agent가 로봇 3(tgt)과 일치하면 target_ok
    return True, ok, f"ForbidAgent(agent={c.get('agent')})" + ("" if ok else f"  [want {tgt}]")


# battery_deprioritize 케이스 채점: 배터리 저하는 "부드러운" DeprioritizeAgent여야 함
# (완전 금지 ForbidAgent/ReplaceAgent가 아니라 — 저하된 로봇도 일은 할 수 있으므로).
def _score_deprioritize(proposal, fx):
    # battery/degradation NL must translate to the SOFT DeprioritizeAgent grounded to R3,
    # NOT the hard ForbidAgent/ReplaceAgent (a degraded robot can still work).
    tgt = _robot3_agent(fx)
    kinds = [c.get("kind") for c in proposal.get("constraints", [])]
    cs = _constraints(proposal, "DeprioritizeAgent")
    if not cs:
        return False, False, f"no DeprioritizeAgent (got {kinds})"
    c = cs[0]
    ok = (c.get("agent") == tgt)   # 대상이 로봇 3인지 확인
    return True, ok, f"DeprioritizeAgent(agent={c.get('agent')}, factor={c.get('factor')})" + ("" if ok else f"  [want {tgt}]")


# zone_closure 케이스 채점: 남쪽 구역 폐쇄 -> 남쪽 노드 전부에 ForbidWindow가 걸렸는지
# (정답 집합 gold와 결과 집합 got가 완전히 같아야 target_ok).
def _score_forbidwindow_set(proposal, fx):
    gold = _south_nodes(fx)
    cs = _constraints(proposal, "ForbidWindow")
    if not cs:
        return False, False, f"no ForbidWindow (got {[c.get('kind') for c in proposal.get('constraints', [])]})"
    got = {c.get("node") for c in cs}   # 결과가 실제로 건 노드들의 집합
    kind_ok = all(c.get("kind") == "ForbidWindow" for c in proposal.get("constraints", []))  # 모든 제약이 ForbidWindow인가
    ok = (got == gold)                  # 정답 남쪽 노드 집합과 정확히 일치?
    return kind_ok, ok, f"ForbidWindow x{len(cs)} on {sorted(got)}" + ("" if ok else f"  [want {sorted(gold)}]")


# 테스트 케이스 표: 케이스이름 -> {기대 kind, 채점함수 score, 자연어 이벤트 3개(패러프레이즈)}.
# 같은 상황을 다르게 표현한 문장 여러 개로 LLM이 표현에 흔들리지 않는지 확인한다.
CASES = {
    "robot_fault": dict(
        kind="ForbidAgent", score=_score_forbidagent,
        events=[
            "We just lost robot 3 — it's reporting a motor fault and can't move.",
            "Robot R3 has broken down and is immobile.",
            "Take robot 3 out of service; it is stuck and unavailable.",
        ]),
    "zone_closure": dict(
        kind="ForbidWindow", score=_score_forbidwindow_set,
        events=[
            "A worker has entered the southern staging area. No assembly work may take place in the south between time 20 and time 50.",
            "Safety lockout: the south staging zone is closed from t=20 to t=50 - keep every southern assembly out of that window.",
            "There is a spill in the south area; nothing located in the south can be active between t=20 and t=50.",
        ]),
    "battery_deprioritize": dict(
        kind="DeprioritizeAgent", score=_score_deprioritize,
        events=[
            "Robot R3's battery is degraded and now at about 39% charge; it should avoid long-distance and heavy-payload hauls so it does not run flat.",
            "Heads up: robot 3 is low on charge. Prefer other robots for the heavy transport jobs, but it can still work if needed.",
            "R3's battery health has dropped a lot. Spare it from big/long hauls so it lasts, without taking it offline.",
        ]),
}


# 메인 진입점: 옵션을 읽고, 각 케이스의 문장들을 propose()에 넣어 채점하고, 총점으로 종료코드 결정.
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="precede only, 1 sample/paraphrase")  # zone_closure만 1회씩
    ap.add_argument("--case", choices=list(CASES), help="run a single case")   # 케이스 하나만 실행
    ap.add_argument("--samples", type=int, default=2, help="samples per paraphrase")  # 문장당 반복 샘플 수
    args = ap.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):   # LLM 호출용 키가 없으면 바로 실패 종료
        sys.exit("ERROR: ANTHROPIC_API_KEY not set in this process's environment.")

    fx = _load_fixture()
    from propose import propose  # imported AFTER sys.path insert; fresh each process
    # ↑ sys.path 넣은 뒤에 import해야 서비스 폴더의 최신 propose를 매 프로세스 새로 읽는다.

    # 어떤 케이스를 몇 번씩 돌릴지 옵션에 따라 결정(case_ids=케이스 목록, n=문장당 반복수)
    if args.quick:
        case_ids, n = ["zone_closure"], 1
    elif args.case:
        case_ids, n = [args.case], args.samples
    else:
        case_ids, n = list(CASES), args.samples

    model = os.environ.get("RESPEC_MODEL", "claude-opus-4-8 (propose.py default)")
    print(f"== translate_eval ==  model={model}  fixture(open_ids={len(fx['open_ids'])}, "
          f"nodes={len(fx['nodes'])}, agents={len(fx['agents'])}, closed={fx.get('closed_count')})")

    total_ok = total = 0            # 전체 정답 수 / 전체 시도 수 누적
    for cid in case_ids:
        case = CASES[cid]
        print(f"\n---- case {cid}  [expect {case['kind']}]  {len(case['events'])} paraphrases x {n} ----")
        kind_hits = tgt_hits = trials = 0   # 이 케이스의 kind 맞춘 수 / target 맞춘 수 / 시도 수
        for ei, event in enumerate(case["events"]):   # enumerate: (인덱스ei, 값event) 동시에
            for s in range(n):                        # 같은 문장을 n번 샘플링(LLM은 확률적이라)
                trials += 1
                try:
                    proposal = propose(event, fx["open_ids"], fx["agents"], fx["nodes"])  # LLM 번역 호출
                    kind_ok, tgt_ok, rep = case["score"](proposal, fx)   # 해당 케이스 채점함수로 점수
                except Exception as e:  # noqa: BLE001  # 예외가 나도 그 시도는 실패로 처리하고 계속
                    kind_ok = tgt_ok = False
                    rep = f"EXC {type(e).__name__}: {e}"
                kind_hits += kind_ok    # 파이썬에서 True==1이라 그대로 더할 수 있음
                tgt_hits += tgt_ok
                mark = "OK " if tgt_ok else ("~  " if kind_ok else "X  ")  # OK=완전정답, ~=kind만 맞음, X=틀림
                print(f"  [{mark}] p{ei+1}.s{s+1}: {rep}")
        print(f"  => kind {kind_hits}/{trials}  target {tgt_hits}/{trials}")
        total_ok += tgt_hits
        total += trials

    print(f"\n==== TOTAL target {total_ok}/{total} ====")
    sys.exit(0 if total_ok == total else 1)   # 전부 맞아야 0(성공), 아니면 1(실패)


if __name__ == "__main__":   # 이 파일을 직접 실행할 때만 main() 호출(import될 땐 실행 안 함)
    main()
