# =============================================================================
# `service_decide` 가 **살아 있는 출입금지 구역 설명**을 payload 에 실어 보내는지 못박는다.
# (2026-08-29, Plan B / T4b)
#
# 왜 이 파일이 필요한가
# ----------------------
# 파이썬 서비스는 `MacroRequest.zones` 를 **이미 선언하고** 복구-결정 프롬프트에 렌더한다
# (`5d39eebe`; `dspy_service.py:539` 의 `zones: Optional[List[Dict[str, Any]]]` 와
# `:886` 의 `_zones_block`). 그런데 T4b 이전에는 **아무도 그 값을 안 실었다** —
# `grep '"zones"' tools/monitor/policy.jl` 가 0 건이었다. 즉 필드는 선언돼 있으나 휴면이었고,
# 결정 레인의 프롬프트에는 구역 기하가 한 번도 안 떴다. 바인딩 스펙이 `zones` 를 기하 축의
# **유일한** 입력으로 못박으므로, 이게 없으면 zone 사건의 파라미터 유도는 원리적으로 불가능하다.
#
# T4b 가 고친 세 줄은 모두 `tools/monitor/policy.jl` 에 있다:
#   (a) `service_decide` 의 kwarg 선언 `zones = nothing`
#   (b) payload 조립 줄 `zones === nothing || (payload["zones"] = zones)`
#   (c) `decide_all` 호출부의 `zones = CB.open_zone_descriptors(env)`
# 이 셋은 `agents` 가 이미 쓰는 규약과 **정확히 같다**(키워드로 받고, nothing 이 아닐 때만 싣는다).
#
# 🔴 왜 "선언·시그니처 검사"만으로는 부족한가 — 이 레포가 실제로 밟은 함정
# ------------------------------------------------------------------------
# `service_decide_ships_agents.jl` 의 헤더(라운드 2 G1+G2)가 실측으로 기록한 내용이다:
# kwarg 선언과 원시 함수만 재는 어서션은 (b)/(c) 두 줄을 **한 번도 안 태운다** — 원래 버그를
# 되살려도 초록이었다. 그래서 이 파일도 같은 방식으로 잰다: **루프백에 진짜 HTTP 서버를 띄우고**
# `DSPY_URL` 이 그것을 가리키는 상태에서 policy.jl 을 include 한 뒤 `decide_all` 을 **실제로
# 실행**해, 네트워크로 나간 요청 본문의 `"zones"` 를 붙잡아 비교한다.
#
# 🔴 **8077(진짜 DSPy 서비스)로는 한 요청도 안 나간다.** `/decide` 는 사용자 계정에 과금되는
#    OpenAI 호출이고 지금 리스너가 살아 있다. `const DSPY_URL`(policy.jl:19)은 include 시점에
#    ENV 에서 **한 번** 읽히므로, 우리 포트를 가리키는 동안에만 include 하고 곧바로 되돌린다.
#
# 🔴 `import Sockets` 를 **하지 않는다**(agents 게이트 라운드 5 K1 이 실측한 함정). stdlib 이라도
#    `Project.toml` 의 `[deps]` 에 없으면 `Pkg.test()` 샌드박스에서 안 풀려
#    `ArgumentError: Package Sockets not found in current path` 로 게이트가 통째로 **에러**가
#    된다 — 단독 실행은 `@stdlib` 덕에 초록이라 그 차이가 안 보인다. `HTTP` 가 `Sockets` 를
#    의존하고 그 바인딩을 그대로 들고 있으므로 `HTTP.Sockets.*` 로 닿는다.
#
# 이 파일이 재는 것
# ------------------
#   (1) `service_decide` 가 `zones` 키워드를 **선언한다**(메서드 객체에서 직접 확인).
#   (2) **구역 없음**: `RESTRICTION_ZONES` 가 비면 `open_zone_descriptors` 는 **빈 벡터**를 내고,
#       `decide_all` 은 `"zones"` 키를 **싣되 빈 배열**로 싣는다 — 키가 빠지는 것이 아니다.
#       (소비자가 알아야 하므로 둘 중 어느 쪽인지 여기서 못박는다.)
#   (3) **구역 있음**: 빌드 한복판에 구역을 등록하면 요청 본문의 `zones` 가
#       `CB.open_zone_descriptors(env)` 의 직렬화와 **같다**.
#   (4) **422 를 못 내는 이유의 구조적 근거**: 서비스는 잘못된 `zones` 를 degradation 이 아니라
#       **HTTP 422** 로 떨어뜨린다(`test_zone_channel.py::
#       test_zones_are_rejected_at_the_pydantic_boundary_when_malformed`). 그래서 실제 씬에서
#       나온 값이 언제나 well-formed 인지를 여기서 잰다: 원소는 전부 JSON object 이고,
#       `_zones_block` 이 **실제로 읽는 네 키**(center/radius/covers/covers_root)는 전부 non-null.
#
# 실행: julia +lts --project=. test/service_decide_ships_zones.jl
# =============================================================================
module ServiceDecideShipsZones

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3
import Random
# policy.jl 의 `_agent_pending`(ood_features 경유, service_decide 가 부른다)이 Graphs 를 쓴다.
# policy.jl 은 스크립트라 자기 의존성을 안 들고 온다(CLAUDE.md Gotchas).
import Graphs

const REPO = normpath(joinpath(@__DIR__, ".."))

# ZoneTruth / BatteryTruth 는 런타임 include 계층(navigator.jl)에 산다.
isdefined(CB, :ZoneTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# ---- 로컬 DSPy 대역 서버 -----------------------------------------------------
# policy.jl 이 찌르는 두 엔드포인트만 답한다. `/decide` 의 본문이 이 시험의 측정값이다.
# 핸들러는 서버 태스크에서 돌지만 클라이언트가 응답을 받을 때까지 블록하므로, 아래에서
# `_CAPTURED_BODY[]` 를 읽는 시점엔 쓰기가 이미 끝나 있다.
const _CAPTURED_BODY = Ref{Union{Nothing,String}}(nothing)
const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        # `dspy_ready()` 가 찌르는 자리. 200 을 안 주면 `service_decide` 가 곧장 nothing 을
        # 돌려주고 아래 시험은 "본문을 못 받았다"로 **빨개진다**(조용히 안 샌다).
        # 🔴 2026-08-29 (T11): `surro_kinds` 를 **반드시** 싣는다. kind 색인 라우터가 이 값을
        #    `/health` 에서만 받고, 없으면 "못 쟀다"로 캐시한 뒤 `select_lane` 이 그 사건에서
        #    **죽는다**(§0-C 결정 3 의 설계된 동작). 실측: 이 줄이 없으면 `decide_all` 을
        #    부르는 절이 "surrogate kind support is unknown" 으로 정당하게 빨개진다.
        #    값은 서비스의 실측 기준값(`oracle_dataset.jsonl` 33행)과 같다.
        return HTTP.Response(200, "{\"status\":\"ok\",\"surro_kinds\":[\"battery\",\"fault\"]}")
    elseif req.target == "/decide"
        _CAPTURED_BODY[] = String(req.body)
        # 🔴 2026-08-29 (T11): 여기 있던 `Dict("dspy"=>nothing,"surrogate"=>nothing)` 은 이제
        #    **못 쓴다.** 근거였던 *"둘 다 null 이면 policy_entry 가 unavailable 로 채운다"* 는
        #    참이지만, 새 라우터는 고른 레인이 unavailable 이면 `error()` 로 **죽는다**
        #    (§0-C 결정 3) — 그러면 요청을 잰다는 이 파일의 목적 자체가 도달 불가가 된다.
        #    ⟹ **요청된 레인마다 최소한의 유효 결정을 돌려준다.** `payload["lanes"]` 를 읽으므로
        #    라우팅이 또 바뀌어도 이 픽스처는 안 깨진다(kind 축이 무엇을 고르든 따라간다).
        #    이 파일은 여전히 응답이 아니라 **요청**을 잰다 — 아래 값은 죽지 않기 위한 최소치다.
        local _req_lanes = try
            local pl = JSON3.read(_CAPTURED_BODY[])
            haskey(pl, :lanes) ? String.(collect(pl[:lanes])) : ["dspy", "surrogate"]
        catch
            ["dspy", "surrogate"]
        end
        local _ok = Dict{String,Any}("chosen" => _NOOP_NAME, "ranking" => [_NOOP_NAME],
                                     "margin" => 0.0, "rationale" => "fake (request gate)",
                                     "policy" => "test", "unsupported" => String[])
        return HTTP.Response(200, JSON3.write(Dict{String,Any}(l => _ok for l in _req_lanes)))
    end
    return HTTP.Response(404, "")
end
const _PORT = HTTP.Servers.port(_SERVER)

# 🔴 `_SERVER` 를 연 뒤 모듈 본문이 끝날 때까지 **밖으로 나가는 모든 길**에 `close(_SERVER)`
#    가 있어야 한다(agents 게이트 라운드 5 K3 이 실측한 누수). 아래 셋이 그 전부다:
#    (i) 이 include, (ii) TENV 구축, (iii) 테스트 블록.
const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:$(_PORT)"
try
    include(joinpath(REPO, "tools", "monitor", "policy.jl"))
catch
    close(_SERVER)   # (i)
    rethrow()
finally
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)
end

# 🔴 매크로 이름 리터럴을 쓰지 않는다(`test/policy_macro_binding.jl:134` 의 규칙) —
#    레지스트리에서 유도한다. `ActionRegistry` 는 위 policy.jl include 가 들여온다.
#    위 서버 클로저는 **호출 시점에** 이 전역을 읽으므로 정의 순서는 무관하다.
const _NOOP_NAME = ActionRegistry.NAME[0]

# 실 env 구축이 이 파일에서 가장 비싼 부분이다(실측: 파일 전체 1:41 중 테스트 블록은 10.7s —
# 나머지가 패키지 로드 + `run_lego_demo`). 씬은 agents 게이트의 정본과 같다. 시뮬레이션은 한
# 스텝도 안 돌린다 — `open_zone_descriptors` 가 읽는 것(스케줄 그래프 · staging_circles ·
# RESTRICTION_ZONES)은 `return_env_before_sim=true` 시점에 이미 완성돼 있다.
const TENV = try
    CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                       project_name = "service_decide_zones",
                       num_robots = 4, assignment_mode = :greedy,
                       n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
catch
    close(_SERVER)   # (ii)
    rethrow()
end

# JSON3 이 돌려주는 뷰 타입을 평범한 Julia 컨테이너로 내린다. Dict 동등성은 **키 순서에
# 무관**하므로, 이 정규화 뒤의 `==` 는 직렬화 시점의 Dict 순회 순서에 기대지 않는다
# (Global Constraint: Dict 순회 순서에 기대지 않는다).
_norm(x) = x
_norm(x::JSON3.Object) = Dict{String,Any}(String(k) => _norm(v) for (k, v) in pairs(x))
_norm(x::JSON3.Array)  = Any[_norm(v) for v in x]

"기댓값을 **같은 직렬화기**로 한 번 통과시켜 비교 가능한 모양으로 만든다(Float 표현·nothing→null 일치)."
_wire_shape(x) = _norm(JSON3.read(JSON3.write(x)))

"`decide_all` 을 한 번 돌리고 붙잡힌 요청 본문을 파싱해 돌려준다. 못 받았으면 nothing."
function _capture_decide(truth)
    _CAPTURED_BODY[] = nothing
    decide_all(TENV, truth; nl = "")
    b = _CAPTURED_BODY[]
    return b === nothing ? nothing : JSON3.read(b)
end

# (iii) 마지막 길. `try/finally` 는 오직 서버를 닫고 전역 구역 상태를 되돌리기 위한 것이다 —
# 예외를 삼키지 않으므로 실패는 그대로 위로 전파된다.
const _PREV_ZONES = copy(CB.restriction_zones())
try
    @testset "service_decide 가 zones 를 payload 에 싣는다" begin

    @testset "(1) service_decide 는 zones 키워드를 선언한다" begin
        local decls = Iterators.flatten(Base.kwarg_decl(m) for m in methods(service_decide))
        @test :zones in collect(decls)
    end

    # 이 게이트의 (2)/(3) 이 무언가를 재려면 `decide_all` 이 `service_decide` 를 **실제로 불러야**
    # 한다. policy.jl 의 삼항식은 세 조건이 모두 참일 때 그 호출을 건너뛴다. 하류 증상("본문을
    # 못 받았다") 대신 전제 자체를 여기서 이름 붙여 빨개지게 한다(agents 게이트 라운드 5 L2 와
    # 같은 형태 — skip 조건을 **그대로 부정**한다).
    @testset "(0) 전제: 이 설정에서 decide_all 은 서비스 호출을 건너뛰지 않는다" begin
        @test !(POLICY in ("canonical", "noop", "oracle") && !router_drives() &&
                get(ENV, "DEMO_ALL_POLICIES", "1") == "0")
    end

    @testset "(2) 구역 없음 — 빈 벡터가 실린다 (키는 빠지지 않는다)" begin
        CB.clear_restriction_zones!()      # 스위트 안에서 앞선 게이트가 남긴 구역이 있어도 결정적
        # 원시 함수의 계약: 활성 구역이 없으면 `nothing` 이 아니라 **빈 벡터**다. 이 구분이
        # payload 규약을 정한다 — `zones === nothing || ...` 는 빈 벡터를 **싣는다**.
        local zs = CB.open_zone_descriptors(TENV)
        @test zs isa Vector{Dict{String,Any}}
        @test isempty(zs)

        # 비공간 사건(배터리)에서 구역이 하나도 없는, 실제로 가장 흔한 상태.
        local parsed = _capture_decide(CB.BatteryTruth(CB.RobotID(1), 0.5))
        @test parsed !== nothing              # 못 받았으면 아무것도 안 잰 것이다
        # 🔴 소비자를 위해 **둘 중 어느 쪽인지 못박는다**: 키는 있고, 값은 빈 배열이다.
        #    (파이썬 쪽에서 `zones=[]` 와 `zones=None` 은 `_zones_block` 이 똑같이 빈 문자열을
        #     내므로 프롬프트는 같지만, 요청 본문은 다르다 — 여기서 재는 것은 본문이다.)
        @test haskey(parsed, "zones")
        @test _norm(parsed["zones"]) == Any[]
    end

    @testset "(3) 구역 있음 — 실린 zones 가 open_zone_descriptors(env) 와 같다" begin
        CB.clear_restriction_zones!()
        # 빌드 한복판(루트 deposit 목표들의 무게중심) = 실제로 무언가를 가두는 구역.
        # 이 자리를 고르는 이유는 `covers` 가 비지 않게 해서 어서션을 항진명제에서 구하기 위해서다.
        local gs = CB.root_deposit_goals(TENV)
        local zc = isempty(gs) ? Float64[1.5, 0.96] : Vector{Float64}(sum(gs) ./ length(gs))[1:2]
        CB.add_restriction_zone!(:t4b_zone, zc, 2.5)
        CB.add_restriction_zone!(:t4b_far, Float64[500.0, 500.0], 1.0)   # 아무것도 안 덮는 구역

        local expected = CB.open_zone_descriptors(TENV)
        # 사전조건: 구역이 실제로 살아 있고(2개), 정렬 순회라 순서가 결정적이다.
        @test length(expected) == 2
        @test [d["key"] for d in expected] == ["t4b_far", "t4b_zone"]   # sort by string
        # 사전조건 — **항진명제 방지**. 두 구역의 설명이 서로 **다르고**, 중앙 구역 쪽은 기하가
        # 실제로 무언가를 쟀어야 한다. 안 그러면 아래 비교가 "빈 것 두 개" 끼리의 비교로 전락한다.
        #
        # 🔴 여기서 `covers` 가 아니라 `covers_root`/`work_reach` 로 재는 이유(실측):
        #    `colored_8x8` 씬의 `staging_circles` 는 **한 개**(루트 AssemblyID(1)) 뿐이라
        #    옮길 수 있는 하위 조립체가 없고, `zone_blocked_assemblies` 는 이 씬에서 **구조적으로
        #    언제나 빈 목록**이다. 즉 `!isempty(covers)` 는 이 씬에서 절대 참이 될 수 없다.
        #    대신 이 씬이 잡는 것은 중앙-코어 사례다: 구역이 루트의 안 옮겨지는 deposit 목표를
        #    가둬 `covers_root == true` 가 되고, `work_reach` 가 양수로 측정된다.
        #    ⚠️ 한계는 그대로 적는다: 이 게이트는 **비어 있지 않은 `covers` 를 망가뜨리는** 버그는
        #       못 잡는다(키를 통째로 떨어뜨리는 버그는 아래 동등성이 잡는다). 그걸 재려면
        #       하위 조립체가 여럿인 씬(예: tractor)이 필요하다 — 이 파일은 그 비용을 안 낸다.
        @test expected[2]["covers_root"] === true        # :t4b_zone — 루트 목표를 가둔다
        @test expected[2]["work_reach"] > 0.0            # 기하가 실제로 무언가를 쟀다
        @test expected[1]["covers_root"] === false       # :t4b_far — 아무것도 안 덮는 음성 대조
        @test expected[1]["work_reach"] == 0.0
        @test expected[1] != expected[2]                 # 두 항목이 서로 다르다(구별 가능한 payload)

        local parsed = _capture_decide(CB.ZoneTruth(:t4b_zone, zc, 2.5, nothing))
        @test parsed !== nothing
        @test haskey(parsed, "zones")
        # 🔴 이 한 줄이 (b) payload 조립 줄과 (c) `decide_all` 호출부 줄을 **둘 다** 태운다.
        @test _norm(parsed["zones"]) == _wire_shape(expected)
    end

    @testset "(4) 실리는 값은 언제나 well-formed — 이 채널로는 422 가 안 난다" begin
        # 서비스는 잘못된 `zones` 를 **422 로 떨어뜨린다**(degradation 이 아니다): 필드가
        # `Optional[List[Dict[str, Any]]]` 이고 `_zones_block` 에는 방어 가드가 **의도적으로**
        # 없다. 그러니 "무엇을 실어도 안전하다"가 아니라 **"우리가 싣는 것이 항상 well-formed
        # 이다"** 를 재야 한다. 그 성질은 `open_zone_descriptors` 의 구조에서 나온다:
        #   · 매 반복이 `Dict{String,Any}(...)` 리터럴 하나만 push! → 원소는 언제나 JSON object
        #     (= 422 의 유일한 트리거인 "dict 가 아닌 원소"가 구조적으로 불가능).
        #   · 렌더러가 **실제로 읽는** 네 키는 전부 non-null.
        # null 이 될 수 있는 것은 `build_center`/`build_radius`/`max_shift` 셋뿐이고
        # (`isempty(env.staging_circles)` 인 씬), 값 타입이 `Any` 라 pydantic 이 null 을 받으며
        # `_zones_block` 은 그 셋을 **아예 렌더하지 않는다**.
        local zs = CB.open_zone_descriptors(TENV)
        @test !isempty(zs)                     # (3) 이 등록한 구역이 아직 살아 있다
        for d in zs
            @test d isa Dict{String,Any}
            # `_zones_block` 이 읽는 네 키 — 전부 있고, 전부 non-null, 전부 렌더 가능한 타입.
            @test d["key"] isa String
            @test d["center"] isa AbstractVector && length(d["center"]) == 2 &&
                  all(x -> x isa Real, d["center"])
            @test d["radius"] isa Real
            @test d["covers"] isa Vector{String}          # 원소에 nothing 이 못 섞인다
            @test d["covers_root"] isa Bool
        end
        # 그리고 그 well-formed 성질은 **직렬화 뒤에도** 유지된다(실제로 나가는 바이트 기준).
        local wire = _wire_shape(zs)
        @test all(e -> e isa Dict{String,Any}, wire)
        @test all(e -> e["center"] !== nothing && e["radius"] !== nothing &&
                       e["covers"] !== nothing && e["covers_root"] !== nothing, wire)
    end

    end # testset
finally
    # 전역 구역 상태를 원래대로(스위트의 뒤 게이트를 오염시키지 않는다) + 리스너 정리.
    CB.clear_restriction_zones!()
    for (k, v) in _PREV_ZONES
        CB.restriction_zones()[k] = v
    end
    close(_SERVER)
end

end # module
