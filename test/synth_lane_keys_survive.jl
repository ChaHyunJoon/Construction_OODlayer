# =============================================================================
# 합성 레인 키의 경계 게이트. (2026-08-30, T1)
#
# 재는 명제 하나: **파이썬이 `# ---- 합성 레인` 표식 아래에 싣는 키 집합과 줄리아의
# `SYNTH_LANE_KEYS` 가 같다.**
#
# 🔴 왜 `tool_lane_keys_survive.jl` 에 안 얹는가. 그 파일 (6)절은 파이썬의
#    `# ---- tool 레인` 표식 **아래** 집합을 `TOOL_LANE_KEYS` 와 양방향 등호로 본다.
#    합성 키는 그 표식 **위**에 있다(`dspy_service.py` 의 `# ---- 합성 레인` 블록).
#    한 튜플에 섞으면 그 게이트가 정당하게 빨개진다.
#
# 🔴 **아홉이다, 여덟이 아니다** (2026-08-30 정정). 최초 계획서는 `params` 를 빠뜨렸다 —
#    그 값이 없으면 T3/T4 의 인터프리터가 신설 도구 원시연산에 넘길 키워드 인자를 못 받는다.
#    서비스는 성공 경로에서 `params` 를 이미 `synthesis` dict 안에 싣고 있다(실측).
#
# 🔴 이 파일은 `using ConstructionBots` 없이 `policy.jl` 을 **standalone** include 한다
#    (실측: `policy.jl` 의 load-time 작업은 `import HTTP, JSON3` · 세 sibling include ·
#    ENV 읽기뿐이라 패키지 로드가 필요 없다). 게이트가 `tool_lane_keys_survive.jl` 처럼
#    루프백 HTTP 서버를 띄우지 않는 것도 그 때문이다 — `policy_entry` 를 손으로 만든
#    JSON3 픽스처로 직접 부른다. 8077/8079 로 나가는 요청 0건 = 유료 호출 0건.
#
# 🔴 **교차언어 결속** (2026-08-30 최종 리뷰, IMPORTANT — 이 파일의 원래 결함).
#    위 명제는 2026-08-30 T1 시점에 **손으로 지은 픽스처**로만 재고 있었다. 그래서 파이썬
#    쪽에서 `ran` 을 개명하면 `synthesis_ran` 이 영원히 `nothing`("못 쟀다")으로 도착하는데
#    **줄리아 게이트는 전부 초록**이었다 — 서비스는 멀쩡히 쟀는데 기록에는 "못 쟀다" 가 남는,
#    이 레포가 반복해 데인 모양이다. `test/tool_lane_keys_survive.jl` (6)절은 파이썬의
#    `# ---- tool 레인` 표식 **아래** 집합만 보므로 합성 키(표식 **위**에 산다)를 안 덮는다.
#    아래 마지막 testset 이 그 (6)절의 관용구를 합성 레인에 그대로 옮긴 것이다.
#
# 변이시험 (실패하는 것을 실제로 볼 것)
#   · `SYNTH_LANE_KEYS` 에서 "tool_minted" 를 지우면 (1) 이 빨개진다.
#   · `policy_entry` 의 성공 분기에서 합성 dict 조립을 지우면 (2) 가 빨개진다.
#   · `policy_entry` 의 실패 분기에서 지우면 (3) 이 빨개진다.
#   · `params` 를 `SYNTH_LANE_KEYS` 에서 지우면 (1)·(2) 가 함께 빨개진다.
#   · 파이썬 `synthesize.py` 에서 `"ran"` 을 개명하면 교차언어 절이 빨개진다(그 절 자신의
#     음성 대조가 **사본 위에서** 그것을 실제로 보여준다 — 생산 소스는 안 건드린다).
# =============================================================================
module SynthLaneKeysSurvive

using Test
import JSON3
include(joinpath(@__DIR__, "..", "tools", "monitor", "policy.jl"))

@testset "SYNTH_LANE_KEYS 의 내용" begin
    # (1) 🔴 2026-09-03 (Task 9): `reach`·`missing_primitive` 를 빼고 다섯을 더했다.
    #    agent-3 이 인벤토리에서 조합하는 대신 원시 자신을 코드로 쓴다(D8) — "조합했는가" 를
    #    재던 둘은 더 이상 나는 사실이 없고, 대신 `impl_name`·`impl_code`·`surface`·
    #    `reversible`·`wrote` 다섯이 나른다. 리터럴로 못박는다 — 이 목록이 계약이다.
    #    🔴 2026-09-03 최종 리뷰: `refused` 가 열넷째로 들어왔다. 이 키가 없으면 G1 거절
    #    (돈을 쓰기 전에 돌아선 사건)이 줄리아 쪽에서 "발화할 사건이 아니었다" 와 **바이트
    #    동일**해진다 — 처방이 정반대인 두 사건이다(근거 전문은 `SYNTH_LANE_KEYS` docstring).
    #    🔴 2026-09-04 (Wave A, W5): `mechanism` 이 열다섯째로 들어왔다. 이 키가 없으면
    #    `/rewrite` 의 `spec` 이 **생산 경로에서 언제나 빈 문자열**이다(Task 9 실측: 가짜
    #    서버가 받은 payload 의 `spec` = `''`) — 즉 agent-3 이 **명세 없이** "이 거절을
    #    고쳐라" 를 받는다. 그 상태로 유료 런을 돌리면 되먹임 성공률이 아래로 편향되고
    #    원인이 모델이 아니라 우리 배선이 되는데, D17 이 재려는 수치가 정확히 그 성공률이다.
    #    파이썬 쪽에는 이 키가 **이미 있었다**(`synthesize.py` 의 `_SPEC_FIELDS`, 그리고
    #    아래 교차언어 절이 AST 로 그것을 재확인한다) — 못 건넌 것은 줄리아 목록뿐이었다.
    @test Set(SYNTH_LANE_KEYS) == Set(["tool_minted", "synthesis_event", "synthesis_ran",
                                       "synthesis_error", "refused", "tool_name", "body_names",
                                       "params", "calls", "impl_name", "impl_code",
                                       "surface", "reversible", "wrote", "mechanism"])
end

@testset "성공 분기가 열을 전부 나른다" begin
    # 서비스 응답을 흉내낸 dict. `policy_entry` 는 `b` 를 **Symbol 키**로 읽는다
    # (`get(b, :error, nothing)` 등) — 실제 응답은 JSON3.Object 이지 Dict{String,Any} 가
    # 아니다. Dict{String,Any} 픽스처를 그대로 넘기면 모든 Symbol 조회가 미스해
    # available=false·chosen="" 인 **실패 분기**를 조용히 태우게 된다(브리프의 결함).
    # 그래서 JSON3.write → JSON3.read 왕복으로 실제와 같은 타입을 만든다.
    fake = JSON3.read(JSON3.write(Dict{String,Any}(
        "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing,
        "rationale" => "r", "policy" => "dspy:gpt-4o", "coerced" => false, "error" => nothing,
        "tool_minted" => true,
        "synthesis" => Dict{String,Any}(
            "synthesis_event" => true, "ran" => true, "error" => nothing,
            "tool_name" => "clear_zone_and_resume",
            "body_names" => ["restage_all_blocked", "translate_whole_build"],
            # 🔴 2026-09-03 (Task 9): `reach`/`missing_primitive` 대신 agent-3 이 쓴 코드 자체.
            "impl_name" => "restage_all_blocked", "impl_code" => "function restage_all_blocked(env)\n    return :ok\nend\n",
            "surface" => "sched", "reversible" => true, "wrote" => true,
            # 🔴 W5: agent-2 가 고른 기전 산문. `/rewrite` 의 `spec` 이 이 값이다.
            "mechanism" => "release the pending assignments, then re-solve",
            # 🔴 G1 가드가 돌고 통과한 판이다 — `false`("쟀고 통과") 이지 `nothing`("안 돌았다")
            #    도 문자열(사유)도 아니다.
            "refused" => false,
            "params" => Dict{String,Any}("threshold" => 0.3, "zone" => "A"),
            # 🔴 B1(2026-09-03). agent-3 이 body 와 **같은 순서로** 내는 구조화 호출열.
            #    `params`(도구 하나에 dict 하나)와 달리 원시마다 자기 인자를 들고 온다.
            "calls" => [Dict{String,Any}("primitive" => "restage_all_blocked",
                                         "args" => Dict{String,Any}()),
                        Dict{String,Any}("primitive" => "translate_whole_build",
                                         "args" => Dict{String,Any}("zone_keys" => ["A"]))]))))
    e = policy_entry(fake, "dspy")
    # 성공 분기가 실제로 태워졌는지 먼저 확인한다 — 그렇지 않으면 아래 열셋 키 단언은
    # "실패 분기가 우연히 값을 갖는다" 는 것을 재는 것일 수 있다.
    @test e["available"] === true
    @test e["chosen"] == "NOOP"
    # 열셋 키가 전부 있고, 값이 응답에서 온 그대로다.
    @test e["tool_minted"] === true
    @test e["synthesis_event"] === true
    @test e["synthesis_ran"] === true
    @test e["synthesis_error"] === nothing
    @test e["tool_name"] == "clear_zone_and_resume"
    @test e["body_names"] == ["restage_all_blocked", "translate_whole_build"]
    @test e["impl_name"] == "restage_all_blocked"
    @test occursin("function restage_all_blocked", e["impl_code"])
    @test e["surface"] == "sched"
    @test e["reversible"] === true
    @test e["wrote"] === true
    @test e["refused"] === false
    @test e["mechanism"] == "release the pending assignments, then re-solve"
    @test e["params"]["threshold"] == 0.3
    @test e["params"]["zone"] == "A"
    @test length(e["calls"]) == 2
    @test e["calls"][1]["primitive"] == "restage_all_blocked"
    @test e["calls"][2]["args"]["zone_keys"] == ["A"]
end

@testset "실패 분기도 열을 나른다 — 값은 nothing 이다" begin
    # 🔴 키를 빼지 않는다. 키가 사라지면 소비자가 "레인이 안 돌았다" 와 "값이 없다" 를
    #     못 가른다 — `margin` 에서 이미 세운 규약이다.
    e = policy_entry(nothing, "dspy")
    @test e["available"] === false
    for k in SYNTH_LANE_KEYS
        @test haskey(e, k)
        @test e[k] === nothing
    end
end

@testset "합성 dict 이 없어도 죽지 않는다" begin
    # 낡은 서비스(합성 레인 이전 세대)가 응답할 수 있다. 그 사실을 nothing 으로 적는다.
    fake = JSON3.read(JSON3.write(Dict{String,Any}(
        "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing,
        "rationale" => "r", "policy" => "p", "coerced" => false, "error" => nothing)))
    e = policy_entry(fake, "dspy")
    @test e["available"] === true
    @test e["tool_minted"] === nothing
    @test e["impl_name"] === nothing
    @test e["params"] === nothing
    @test e["calls"] === nothing        # 🔴 낡은 서비스는 이 필드를 아예 모른다
end

@testset "합성 dict 은 있는데 상세 열셋이 없다 — 흔한 실행 경로" begin
    # `synthesize_multi` 의 이른 탈출 경로 중 성공("minted") 경로만 상세를 전부 채운다.
    # 이것은 예외가 아니라 **흔한** 모양이다 — `synthesis_event`/`synthesis_ran`/
    # `synthesis_error` 만 있고 나머지는 없는 사건.
    fake = JSON3.read(JSON3.write(Dict{String,Any}(
        "chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing,
        "rationale" => "r", "policy" => "dspy", "coerced" => false, "error" => nothing,
        "tool_minted" => false,
        "synthesis" => Dict{String,Any}(
            "synthesis_event" => true, "ran" => false, "error" => "no_missing_primitive"))))
    e = policy_entry(fake, "dspy")
    @test e["available"] === true
    @test e["tool_minted"] === false
    @test e["synthesis_event"] === true
    @test e["synthesis_ran"] === false
    @test e["synthesis_error"] == "no_missing_primitive"
    @test e["tool_name"] === nothing
    @test e["body_names"] === nothing
    @test e["impl_name"] === nothing
    @test e["impl_code"] === nothing
    @test e["surface"] === nothing
    @test e["reversible"] === nothing
    @test e["wrote"] === nothing
    @test e["refused"] === nothing
    # 🔴 W5: 이른 탈출 경로에서는 `mechanism` 도 없다 — `""`(빈 명세)가 아니라 `nothing`
    #    ("못 쟀다")이다. 이 구별이 무너지면 "agent-2 가 기전을 안 냈다" 와 "합성이 그
    #    단계까지 못 갔다" 가 같은 값이 된다.
    @test e["mechanism"] === nothing
    @test e["params"] === nothing
    @test e["calls"] === nothing
end

# =============================================================================
# 🔴 교차언어 — 줄리아의 합성 키가 파이썬 소스에 묶여 있다
#
# 값의 출처가 **둘**이라 그물도 둘이다(`SYNTH_LANE_KEYS` 의 docstring 이 적는 그대로):
#   (a) `tool_minted` 는 응답 **최상위**다 → `dspy_service.py` 의 `out["dspy"]` 리터럴에서
#       `# ---- tool 레인` 표식 **위** 집합에 있어야 한다. 그 아래로 내려가면
#       `test/tool_lane_keys_survive.jl` (6)절이 정당하게 빨개진다(반대 방향의 그물).
#       나머지 여덟을 나르는 `synthesis` dict 자체도 같은 자리에 있어야 한다.
#   (b) 나머지 여덟은 `synthesize.py` 가 짓는 **합성 기록 dict** 안이다. 이름이 둘만 다르고
#       (`synthesis_ran`→`ran`, `synthesis_error`→`error`) 그 사전이 `policy.jl::_SYNTH_RENAME`
#       이다 — 그러므로 대조도 그 사전을 통해서 한다. 사전을 두 벌 적지 않는다.
#
# 🔴 **이 게이트는 이름 축만 잰다 — 타입 축은 `test/minted_end_to_end.jl` (5) 가 잰다.**
#    (2026-09-03 최종 리뷰 B3.) `_PY_EXTRACT` 는 AST 로 **키 이름**만 견준다: 타입도 값도
#    안 본다. 그래서 파이썬이 `params` 를 JSON 스키마 **문자열**로 내고 줄리아 등록 가드가
#    `AbstractDict` 를 요구하는 파열이 이 게이트 초록인 채로 다섯 리뷰 라운드를 살아남았다.
#    타입/모양은 여기서 재지 않는다 — 그러려면 파이썬을 **돌려서** 진짜 기록을 만들고
#    줄리아 경계에 먹여야 하고, 그것은 `ConstructionBots` 가 로드된 파일의 몫이다(이 파일은
#    일부러 standalone 이다). 두 축이 한 집씩 갖는다: 이름은 여기, 타입은 저기.
#
# 🔴 파이썬에 못 닿으면 **skip 이 아니라 빨개진다** — skip 은 같은 구멍에 단계만 더한 것이다.
# 🔴 서비스를 **import 하지 않는다**: `ast` 로 소스만 읽고, 모든 호출을 `env -u OPENAI_API_KEY`
#    로 감싼다(부팅도 과금도 0).
# ⚠️ `dspy_service.py` 는 작업 트리에서 **남의 미커밋 작업**을 안고 있다. 이 게이트는 그것을
#    읽기만 한다 — 변이는 전부 `mktempdir()` 안의 **사본** 위에서 일어난다.
# =============================================================================
const REPO    = normpath(joinpath(@__DIR__, ".."))
const _PY_BIN = joinpath(REPO, ".venv", "bin", "python")
const _PY_SVC = get(ENV, "SYNTH_LANE_PY_SVC",
                    joinpath(REPO, "src", "respec", "llm_service", "dspy_service.py"))
const _PY_SYN = get(ENV, "SYNTH_LANE_PY_SYN",
                    joinpath(REPO, "src", "respec", "llm_service", "synthesize.py"))

const _PY_EXTRACT = raw"""
import ast, json, re, sys
svc, syn = sys.argv[1], sys.argv[2]

src = open(svc, encoding="utf-8").read()
lines = src.split("\n")
lits = [n.value for n in ast.walk(ast.parse(src))
        if isinstance(n, ast.Assign) and len(n.targets) == 1
        and isinstance(n.targets[0], ast.Subscript)
        and isinstance(n.targets[0].value, ast.Name) and n.targets[0].value.id == "out"
        and isinstance(n.targets[0].slice, ast.Constant) and n.targets[0].slice.value == "dspy"
        and isinstance(n.value, ast.Dict)]
if len(lits) != 1:
    sys.exit("expected exactly 1 out[dspy] dict literal, found %d" % len(lits))
d = lits[0]
keys = []
for k in d.keys:
    if not (isinstance(k, ast.Constant) and isinstance(k.value, str)):
        sys.exit("non-literal key in out['dspy'] at line %s" % getattr(k, "lineno", "?"))
    keys.append((k.value, k.lineno))
marks = [i + 1 for i in range(d.lineno - 1, d.end_lineno)
         if re.match(r"^\s*#\s*-{2,}\s*tool ", lines[i])]
if len(marks) != 1:
    sys.exit("expected exactly 1 `# ---- tool ...` marker inside out['dspy'], found %d" % len(marks))

tree = ast.parse(open(syn, encoding="utf-8").read())
rec = set()
def is_rec_sub(t, pred):
    return (isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name)
            and t.value.id == "rec" and pred(t.slice))
# 🔴 2026-09-03 (Task 9). `for f in _BODY_FIELDS:` 는 순회 대상이 리터럴이 아니라 **이름**이다
#    (`_BODY_FIELDS = (...)` 가 모듈 최상위에 따로 있다). 그 자리를 못 풀면 `impl_name`·
#    `impl_code`·`surface`·`reversible` 가 `_copy_body_fields` 안에서 실제로 `rec[f] = ...`
#    로 쓰이는데도 추출기 눈에는 안 보인다 — 거짓 음성이지 파이썬 쪽 결함이 아니다. 그래서
#    `n.iter` 가 `ast.Name` 이면 모듈 최상위에서 같은 이름의 튜플/리스트 리터럴 대입을 찾아
#    푼다(한 단계 별칭만 — 그 이상은 이 게이트의 범위가 아니다).
def resolve_iter_elts(iter_node):
    if isinstance(iter_node, (ast.Tuple, ast.List)):
        return iter_node.elts
    if isinstance(iter_node, ast.Name):
        for s in ast.walk(tree):
            if (isinstance(s, ast.Assign) and len(s.targets) == 1
                    and isinstance(s.targets[0], ast.Name) and s.targets[0].id == iter_node.id
                    and isinstance(s.value, (ast.Tuple, ast.List))):
                return s.value.elts
    return None
for n in ast.walk(tree):
    if isinstance(n, ast.Assign) and len(n.targets) == 1 and is_rec_sub(
            n.targets[0], lambda s: isinstance(s, ast.Constant) and isinstance(s.value, str)):
        rec.add(n.targets[0].slice.value)
    if isinstance(n, ast.FunctionDef) and n.name == "_blank":
        for sub in ast.walk(n):
            if isinstance(sub, ast.Return) and isinstance(sub.value, ast.Dict):
                for k in sub.value.keys:
                    if isinstance(k, ast.Constant) and isinstance(k.value, str):
                        rec.add(k.value)
    if isinstance(n, ast.For) and isinstance(n.target, ast.Name):
        elts = resolve_iter_elts(n.iter)
        if elts is None:
            continue
        var = n.target.id
        if any(isinstance(s, ast.Assign) and len(s.targets) == 1 and is_rec_sub(
                   s.targets[0], lambda sl: isinstance(sl, ast.Name) and sl.id == var)
               for s in ast.walk(n)):
            for e in elts:
                if isinstance(e, ast.Constant) and isinstance(e.value, str):
                    rec.add(e.value)
if not rec:
    sys.exit("no synthesis record keys found in %s" % syn)
print(json.dumps({"above": [k for k, ln in keys if ln < marks[0]],
                  "marker": marks[0], "rec": sorted(rec)}, ensure_ascii=False))
"""

"""
    _py_synth_keys(svc, syn) -> (above::Set{String}, rec::Set{String}, marker::Int)

🔴 **못 하면 예외로 죽는다 — skip 하지 않는다.** 인터프리터 부재도, 소스 부재도, 추출 실패도
전부 빨간색이다. 건너뛰면 두 언어의 목록이 조용히 갈리는 바로 그 구멍이 그대로 남는다.
"""
function _py_synth_keys(svc::AbstractString, syn::AbstractString)
    isfile(_PY_BIN) || error("교차언어 게이트: 파이썬이 없다 — $(_PY_BIN) (skip 하지 않는다)")
    isfile(svc) || error("교차언어 게이트: 서비스 소스가 없다 — $(svc)")
    isfile(syn) || error("교차언어 게이트: 합성기 소스가 없다 — $(syn)")
    local o = IOBuffer(); local e = IOBuffer()
    local pr = run(pipeline(ignorestatus(
        `env -u OPENAI_API_KEY $(_PY_BIN) -c $(_PY_EXTRACT) $(svc) $(syn)`); stdout = o, stderr = e))
    local out = String(take!(o)); local errs = String(take!(e))
    pr.exitcode == 0 || error("교차언어 게이트: 키 추출 실패 (rc=$(pr.exitcode))\n$(errs)")
    local j = JSON3.read(out)
    return (Set(String.(j["above"])), Set(String.(j["rec"])), Int(j["marker"]))
end

@testset "🔴 교차언어 — 합성 열이 파이썬 소스에 묶여 있다" begin
    local (above, rec, marker) = _py_synth_keys(_PY_SVC, _PY_SYN)
    println("    python out[\"dspy\"] 표식 위 = ", join(sort(collect(above)), " · "))
    println("    python 합성 기록 키       = ", join(sort(collect(rec)), " · "))

    # (a) 최상위 둘. `tool_minted` 는 결정 행이 직접 읽고, `synthesis` 는 나머지 여덟의 그릇이다
    #     (`policy.jl::_synth_view` 가 `get(resp, :synthesis, nothing)` 로 그것을 연다).
    @test "tool_minted" in above
    @test "synthesis" in above

    # (b) 나머지 여덟. 이름 사전은 `_SYNTH_RENAME` 하나이고 여기서 다시 안 적는다.
    for k in SYNTH_LANE_KEYS
        k == "tool_minted" && continue
        @test get(_SYNTH_RENAME, k, k) in rec
    end

    # ---- 음성 대조: 이 대조가 정말 하중을 지는가 --------------------------------------
    # 🔴 위 단언들은 **언제나 참일 수도** 있다(추출이 줄리아 목록을 베껴 오는 식으로 망가지면).
    #    그래서 파이썬 소스를 실제로 변형해 빨개지는지 확인한다. 🔴 변형은 **파이썬 리터럴을
    #    베끼지 않고** 줄리아 쪽 이름과 추출기가 돌려준 표식 줄 번호만으로 만든다 — 파이썬
    #    코드를 여기 한 줄이라도 적으면 그것이 또 하나의 사본이 되고, 낡는 순간 대조가 죽는다.
    # 🔴 생산 소스는 안 건드린다. 전부 `mktempdir()` 안의 사본이다.
    mktempdir() do dir
        local svc_lines = split(read(_PY_SVC, String), "\n")
        @test 0 < marker <= length(svc_lines)

        # ① `synthesis` 를 개명한다 → 그릇이 사라진다 = 여덟이 전부 nothing 으로 도착한다.
        local svc2 = joinpath(dir, "dspy_service_renamed.py")
        write(svc2, replace(join(svc_lines, "\n"), "\"synthesis\":" => "\"synthesis_renamed\":"))
        local (above2, _, _) = _py_synth_keys(svc2, _PY_SYN)
        @test !("synthesis" in above2)

        # ② 최상위 `tool_minted` 를 표식 **아래**로 옮긴다 → 표식 위 집합에서 사라진다
        #    (그리고 그 순간 `tool_lane_keys_survive.jl` (6)절이 반대편에서 빨개진다).
        # ⚠️ `findlast` 다. `tool_minted` 이라는 키는 이 파일의 다른 dict(`/macro` 핸들러의
        #    반환)에도 있고, 그 줄을 뽑으면 파이썬이 **문법 오류**로 죽는다 = 원하는 대조가
        #    아니라 추출 실패다(실측). 표식 **직전**의 것이 `out["dspy"]` 의 그것이다.
        local i = findlast(l -> occursin("\"tool_minted\":", l), svc_lines[1:marker])
        @test i !== nothing && i < marker
        local moved = vcat(svc_lines[1:i-1], svc_lines[i+1:marker], [svc_lines[i]],
                           svc_lines[marker+1:end])
        local svc3 = joinpath(dir, "dspy_service_moved.py")
        write(svc3, join(moved, "\n"))
        local (above3, _, _) = _py_synth_keys(svc3, _PY_SYN)
        @test !("tool_minted" in above3)

        # ③ 🔴 이 절이 존재하는 이유 그 자체: 합성기에서 `ran` 을 개명한다. 이름은
        #    `_SYNTH_RENAME` 에서 뽑는다(파이썬 리터럴이 아니다).
        local py_ran = _SYNTH_RENAME["synthesis_ran"]
        local syn2 = joinpath(dir, "synthesize_renamed.py")
        write(syn2, replace(read(_PY_SYN, String),
                            "\"$(py_ran)\"" => "\"$(py_ran)_renamed\""))
        local (_, rec2, _) = _py_synth_keys(_PY_SVC, syn2)
        @test !(py_ran in rec2)
        @test !all(get(_SYNTH_RENAME, k, k) in rec2
                   for k in SYNTH_LANE_KEYS if k != "tool_minted")
    end
end

end # module
