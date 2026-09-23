# test/smdp_hazard_knobs.jl
# (1) 손잡이 셋이 spec 의 D-3 · D-4 · D-5 대로인가.
# (2) λ 의 단일 진실원 — 무거운 레인(hazard_rate)과 경량 레인(hazard_rate_from)이 **같은 수**를
#     내는가. 갈리면 롤아웃이 다른 세계를 탐색한다.
# (3) 이 저장소에 독립적으로 CB.HazardParams(...) 를 만드는 **모든 알려진 자리**가 D-3/D-4/D-5
#     이후에도 실행 레인과 같은 세계인지 — 파일 하나가 아니라 그 자리들의 목록을(T6 라운드 3).
#   julia +lts --project=. test/smdp_hazard_knobs.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

@testset "D-3 · D-4 · D-5 기본값" begin
    p = CB.HazardParams()
    @test p.fire_require_spare == false          # D-3
    @test isfinite(p.mtbf_zone_s)                # D-4 — Inf 면 zone 이 영원히 안 온다
    @test p.drain_sigma == 0.0                   # D-5 — eff 를 s 에서 빼려면 먼저 없애야 한다
    @test p.drain_step_cv == 0.0                 # 유지
    @test p.fire_safe_target == true             # 바꾸지 않는다
end

@testset "🔴 D-5 의 음성 대조 — eff 가 진짜로 상수 1.0 이다" begin
    st = CB._new_hazard_state(CB.HazardParams(), 8)
    for i in 1:8; CB._hz_ensure!(st, i); end
    @test all(v -> v == 1.0, values(st.eff))
    # σ 를 되살리면 갈린다 — 이 시험이 D-5 를 되돌리는 변경을 잡는다
    st2 = CB._new_hazard_state(CB.HazardParams(drain_sigma = 0.15), 8)
    for i in 1:8; CB._hz_ensure!(st2, i); end
    @test !all(v -> v == 1.0, values(st2.eff))
end

@testset "λ 의 단일 진실원" begin
    # ⚠️ Important 4 (T6 라운드 3, 컨트롤러 지시): 이 시험은 지금 당장은 **구조적으로 실패할 수
    # 없다.** `hazard_rate(st, id; mode, soc)` 은 현재 `hazard_rate_from(st.params,
    # st.usage_s[id], soc, mode)` 를 호출하는 한 줄짜리 얇은 래퍼다(hazard.jl 의 λ 단일 진실원
    # 접기, T6 라운드 1) — 그러니 아래 `heavy == light` 는 "같은 함수를 두 이름으로 불러서 같은
    # 값이 나온다"를 확인하는 것과 다르지 않다. **두 레인이 실제로 갈릴 수 있는 경로는 아직
    # 존재하지 않는다** — `src/smdp/rates.jl`(경량 레인, Task T7 이 만든다)가 생겨 자신만의
    # 계산 경로로 `hazard_rate_from` 을 부르기 시작해야, 그 경량 레인이 `hazard_rate_from` 을
    # 우회하거나 다른 인자를 넘기는 회귀를 이 시험이 비로소 잡을 수 있다.
    #
    # 그래도 지우지 않는다 — 이 testset 은 **재인라인(re-inline) 방지용 회귀 고정판**이다:
    # 누군가 나중에 `hazard_rate` 를 다시 자기 몸을 가진 독립 함수로 되돌리면(즉 `hazard_rate_from`
    # 을 호출하는 대신 계산을 다시 그 자리에 베끼면) 이 시험이 그 순간 갈릴 조건을 마련해 둔다.
    # 지금의 초록을 "두 레인이 오늘 일치를 확인했다"는 증거로 보고하지 말 것 — 계획서가
    # 지시한 형태 그대로이므로 이 시험 자체는 이 태스크의 결함이 아니지만, Global Constraint가
    # 경고하는 "절대 실패할 수 없던 시험" 모양과 정확히 같다는 점은 밝혀 둔다.
    st = CB._new_hazard_state(CB.HazardParams(), 3)
    CB._hz_ensure!(st, 1)
    st.usage_s[1] = 240.0
    for mode in (:idle, :transit, :carry, :manip), soc in (1.0, 0.6, 0.05)
        heavy = CB.hazard_rate(st, 1; mode = mode, soc = soc)
        light = CB.hazard_rate_from(st.params, 240.0, soc, mode)
        @test heavy == light          # 근사가 아니라 **정확히** 같아야 한다
    end
end

@testset "🔴 라벨 레인이 실행 레인과 같은 세계다" begin
    src = read(joinpath(@__DIR__, "..", "tools", "oracle",
                        "gen_oracle_dataset.jl"), String)
    # 브리프 원문은 여기 needle 에 공백을 남겨 뒀는데(`", "`) haystack 은
    # `replace(src, " " => "")` 로 공백을 **전부** 지운다 — needle 도 공백을 지워야
    # 매칭된다(원문 그대로면 소스가 뭐든 영원히 FAIL). 실측 후 정정.
    @test occursin("\"DS_DRAIN_SIGMA\",\"0.0\"", replace(src, " " => ""))
    @test CB.HazardParams().drain_sigma == 0.0
end

# =============================================================================================
#  🔴 이 저장소에서 독립적으로 CB.HazardParams(...) 를 만드는 알려진 자리 전부 (T6 라운드 3)
#  ---------------------------------------------------------------------------------------------
#  라운드 1~2 는 `gen_oracle_dataset.jl` 하나만 봤다 — 컨트롤러 판정: "클래스를 죽여라, 파일
#  하나가 아니라." 실측(`grep -rn "CB.HazardParams(" --include=*.jl .`)으로 확인한 오늘의 전체
#  개수는 **정확히 둘**이다: `gen_oracle_dataset.jl`(라벨 레인)과 `tools/demos.jl`(데모 스크립트,
#  `demo_hazard_mdp()`). `src/smdp/hazard.jl` 자신의 `HazardParams()`(인자 없음, 기본값 그 자체)
#  와 그 docstring 안의 예시는 "독립 구성"이 아니므로 셈에서 뺀다.
#
#  두 자리를 같은 방식으로 다루지 못한다: `gen_oracle_dataset.jl` 은 모든 필드가 그 호출
#  **안에서** `get(ENV, ...)` 로 바로 계산되므로 호출 텍스트만 뽑아 eval 하면 끝나지만,
#  `tools/demos.jl` 은 중간 지역변수(`MTBF_BREAK` 등)를 거친다 — 호출 텍스트만 떼어 eval 하면
#  그 변수가 정의 안 돼 있어 `UndefVarError` 로 죽는다. 그래서 그 변수를 만드는 줄들도 **소스에서
#  그대로** 뽑아 호출 앞에 이어붙인다(값을 손으로 베끼지 않는다 — 베끼면 그 파일이 바뀌어도 이
#  시험이 옛 값을 보고 계속 초록일 수 있다, T6 라운드 1 이 이미 겪은 실수와 같은 모양).
#
#  ⚠️ 정직하게 밝혀 둔다: 이것은 "레지스트리"이지 완전 범용 스캐너가 아니다. `src/`, `tools/`,
#  `wm4spacecraft_manufacturing/` 아래 **새** 독립 구성이 생기면(오늘은 없다, 위 grep 이 증거),
#  이 파일에 항목을 하나 더 손으로 추가해야 잡힌다 — 지역변수를 거치는 임의의 Julia 코드를
#  일반적으로 재구성하려면 사실상 축소판 Julia 인터프리터가 필요한데, 그건 테스트 파일의
#  적정 몸집을 넘는다고 판단했다(report 에 이 판단을 명시). 대신 **한 자리 안에서** 필드가
#  하나 늘거나 값이 바뀌는 것은(오늘의 두 자리 모두) 손 안 대고 잡는다 — 그 소스를 그 자리에서
#  파싱해 evaluate 하기 때문이다.
# =============================================================================================

# 균형 괄호로 "이름(" 뒤의 호출 전체를 뽑는다. 파일에 한글 주석(멀티바이트 UTF-8)이 섞여 있어
# 정수를 1씩 늘리며 인덱싱하면 문자 경계 중간을 가리켜 StringIndexError 가 난다(T6 라운드 1 실측)
# — `eachindex` 로 코드포인트 경계만 밟는다.
function _extract_balanced_call(src::String, call_start::Int)
    depth = 0
    stop = nothing
    for i in eachindex(src)
        i < call_start && continue
        c = src[i]
        c == '(' && (depth += 1)
        c == ')' && (depth -= 1; depth == 0 && (stop = i; break))
    end
    stop === nothing && error("괄호 짝을 못 찾았다 (start=$call_start)")
    return src[call_start:stop]
end

# 소스에서 `anchor` 이후 최초로 나오는 `CB.HazardParams(` 호출 전체(괄호 포함)를 뽑는다.
function _extract_hz_call(src::String, anchor::String, anchor_err::String, call_err::String)
    mi = findfirst(anchor, src)
    mi === nothing && error(anchor_err)
    ci = findnext("CB.HazardParams(", src, first(mi))
    ci === nothing && error(call_err)
    return _extract_balanced_call(src, first(ci))
end

# `varname = ...` 한 줄 전체를 뽑는다(오늘 두 자리의 지역변수 정의는 전부 이 형태 — 한 줄, 대입).
function _extract_var_line(src::String, varname::String)
    re = Regex("^[ \\t]*" * varname * "[ \\t]*=.*\$", "m")
    m = match(re, src)
    m === nothing && error("`$varname = ...` 줄을 못 찾았다 — 소스 구조가 바뀌었다")
    return m.match
end

# ---- (1) tools/oracle/gen_oracle_dataset.jl — 라벨 레인 -----------------
const _ORACLE_PATH = joinpath(@__DIR__, "..", "tools", "oracle", "gen_oracle_dataset.jl")
const _ORACLE_SRC  = read(_ORACLE_PATH, String)
const _ORACLE_CALL = _extract_hz_call(_ORACLE_SRC, "const HZ_PARAMS",
    "HZ_PARAMS 상수를 못 찾았다 — gen_oracle_dataset.jl 구조가 바뀌었다",
    "HZ_PARAMS 정의 안에서 CB.HazardParams( 호출을 못 찾았다")

# Important 2 (T6 라운드 3, 컨트롤러 지시): 라운드 2 는 이 env 전부를 **지운 채** 딱 한 번만
# 평가했다 — 그런데 실제 호출 지점은 전부 `DS_HOTSWAP=1` 을 준다(`tools/regen_d20.sh:31`,
# `tools/mdp_cfgprobe.sh:22`, `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py:373`,
# `tools/oracle/run_relabel_20260816.sh:86`, `.claude/CLAUDE.md:246` 가
# 필수라고 못박는다). "아무도 안 쓰는 설정에서 초록"은 게이트가 아니다 — **두 지점 모두** 평가해
# 아래에서 각각 대조한다.
#
# minor 6 (T6 라운드 3): 예전 버전은 `delete!(ENV, k)` 만 하고 복원을 안 해서
# `DS_HOTSWAP=1 julia ... test/smdp_hazard_knobs.jl` 처럼 손잡이를 실제로 쥔 호출조차 조용히
# 지워 버렸다(그리고 그 상태가 이 프로세스에 영구히 남았다). `withenv` 는 값이 `nothing` 이면
# 그 스코프 동안만 지우고 끝나면 호출자의 환경을 그대로 돌려준다 — 그래서 이 프로세스에
# 우연히 켜져 있던 DS_* 도 안전하게 다루면서, 시험이 끝난 뒤에는 아무 흔적도 안 남긴다.
function _oracle_hz_params(; hotswap::Bool)
    pairs = Pair{String,Union{Nothing,String}}[
        "DS_MTBF_BREAK"         => nothing,
        "DS_MTBF_CELL"          => nothing,
        "DS_MTBF_ZONE"          => nothing,
        "DS_DRAIN_SIGMA"        => nothing,
        "DS_FIRE_REQUIRE_SPARE" => nothing,
        "DS_HOTSWAP"            => (hotswap ? "1" : nothing),
        "HOT_SWAP"              => nothing,
        "DS_MAX_EVENTS"         => nothing,
    ]
    return withenv(pairs...) do
        Base.eval(Main, Meta.parse(_ORACLE_CALL))::CB.HazardParams
    end
end

const LABEL_PARAMS         = _oracle_hz_params(hotswap = false)  # 아무 DS_* 도 안 준 기본 호출
const LABEL_PARAMS_HOTSWAP = _oracle_hz_params(hotswap = true)   # 실제 호출 지점의 모양(DS_HOTSWAP=1)
const EXEC_PARAMS          = CB.HazardParams()

# ---- (2) tools/demos.jl `demo_hazard_mdp()` — 세 번째 독립 CB.HazardParams(...) (Important 3) --
const _DEMOS_PATH = joinpath(@__DIR__, "..", "tools", "demos.jl")
const _DEMOS_SRC  = read(_DEMOS_PATH, String)
const _DEMOS_CALL = _extract_hz_call(_DEMOS_SRC, "function demo_hazard_mdp()",
    "demo_hazard_mdp() 함수를 못 찾았다 — tools/demos.jl 구조가 바뀌었다",
    "demo_hazard_mdp() 안에서 CB.HazardParams( 호출을 못 찾았다")
# 이 파일은 필드 값을 지역변수로 받는다(위 큰 주석 참조) — 그 정의 줄들을 소스에서 그대로 뽑아
# 호출 앞에 붙인다. HOT_SWAP 은 이 파일 자신의 기본값이 이미 "1"(하드웨어 hot-swap 기본 ON, 주석
# "정체성 보존 hot-swap 을 기본으로 켠다" 참조)이므로, env 를 아예 안 건드리는 것이 이 파일의
# **실제** 운용 기본값과 정확히 같다(gen_oracle_dataset.jl 처럼 "아무도 안 쓰는 설정"이 아니다).
const _DEMOS_SNIPPET = join((
    _extract_var_line(_DEMOS_SRC, "MTBF_BREAK"),
    _extract_var_line(_DEMOS_SRC, "MTBF_CELL"),
    _extract_var_line(_DEMOS_SRC, "MTBF_ZONE"),
    _extract_var_line(_DEMOS_SRC, "DRAIN_SIG"),
    _extract_var_line(_DEMOS_SRC, "FIRE_REQUIRE_SPARE"),
    _extract_var_line(_DEMOS_SRC, "HOT_SWAP"),
    _DEMOS_CALL,
), "\n")

function _demos_hz_params()
    pairs = Pair{String,Union{Nothing,String}}[
        "MTBF_BREAK" => nothing, "MTBF_CELL" => nothing, "MTBF_ZONE" => nothing,
        "DRAIN_SIGMA" => nothing, "FIRE_REQUIRE_SPARE" => nothing, "HOT_SWAP" => nothing,
    ]
    return withenv(pairs...) do
        Base.eval(Main, Meta.parse("begin\n" * _DEMOS_SNIPPET * "\nend"))::CB.HazardParams
    end
end

const DEMOS_PARAMS = _demos_hz_params()

# 공용 필드-대조 루프. `allowed` 에 없는 필드가 하나라도 다르면 그 목록을 loud 하게 찍고 실패한다
# — "안 건드리면 같은 세계" 가 기본, 다른 값은 이름을 박고 근거를 달아야 통과한다.
function _unexplained_divergences(label::CB.HazardParams, exec::CB.HazardParams,
                                   allowed::Dict{Symbol,String})
    out = Tuple{Symbol,Any,Any}[]
    for f in fieldnames(CB.HazardParams)
        lv = getfield(label, f)
        ev = getfield(exec, f)
        lv == ev && continue
        haskey(allowed, f) && continue
        push!(out, (f, lv, ev))
    end
    return out
end

@testset "🔴 gen_oracle_dataset.jl vs 실행 레인 — 환경 미설정 (T6 라운드 2)" begin
    # D-3(fire_require_spare)·D-4(mtbf_zone_s) 는 사건 **종류**가 아예 가능한지를 가르는 구조적
    # 스위치라 두 레인이 반드시 같아야 했고, 이제 같다(라운드 1 지시로 고침).
    #
    # mtbf_break_s·mtbf_cell_s·max_events 는 **강도(intensity) 손잡이**로 남겨 둔다(라운드 2
    # 컨트롤러 판정): 데이터 생성기가 짧은 에피소드 안에서 사건이 실제로 나오도록 발생률을
    # 올리는 것은 라벨 커버리지를 위한 통상적 importance sampling 이지 버그가 아니다 — 단 이
    # 근거는 **미확인**이다(소스에 설계자 코멘트가 없다). 결정적으로, 실행 레인의 `mtbf_*`
    # 자체가 **미교정**이다(`hazard.jl` 의 `mtbf_zone_s` 주석: "⚠️ 미교정 초기값이다. Task
    # C8(N-G3)이 교정한다") — 그 자체가 잠정인 숫자에 라벨 레인을 강제로 맞추는 것은 아무
    # 의미가 없다. **Task C8(λ 교정 + 게이트 N-G3)이 이 셋의 재판정을 소유한다.**
    ALLOWED_DIVERGENCE = Dict{Symbol,String}(
        :mtbf_break_s => "미확인: 라벨-커버리지 강도 손잡이로 추정(연구 대상 사건과 무관). Task C8 재판정 소유.",
        :mtbf_cell_s  => "미확인: 위와 동일. Task C8 재판정 소유.",
        :max_events   => "미확인: 위와 동일(런어웨이 상한을 좁은 rollout 창에 맞춘 것으로 보임). Task C8 재판정 소유.",
    )

    unexplained = _unexplained_divergences(LABEL_PARAMS, EXEC_PARAMS, ALLOWED_DIVERGENCE)
    if !isempty(unexplained)
        @error "라벨 레인(환경 미설정) vs 실행 레인 미해명 불일치 (필드, 라벨값, 실행값)" unexplained
    end
    @test isempty(unexplained)

    # D-3/D-4/D-5 는 위 루프와 별개로 직접 재확인(회귀 고정판) — 루프 로직이 잘못돼도 이건 남는다.
    @test LABEL_PARAMS.drain_sigma        == EXEC_PARAMS.drain_sigma
    @test LABEL_PARAMS.fire_require_spare == EXEC_PARAMS.fire_require_spare
    @test LABEL_PARAMS.mtbf_zone_s        == EXEC_PARAMS.mtbf_zone_s
end

@testset "🔴 gen_oracle_dataset.jl vs 실행 레인 — 실제 호출 지점 DS_HOTSWAP=1 (T6 라운드 3, Important 2)" begin
    # 위와 같은 세 강도 손잡이를 허용하되, **여기서는 fire_clear 도 허용해야 한다** — 그리고 그
    # 자체가 이 testset 의 발견이다.
    #
    # `fire_clear = !(get(ENV,"DS_HOTSWAP",...) == "1")`. 실제 호출 지점은 전부 DS_HOTSWAP=1 을
    # 주므로(위 큰 주석의 파일 목록) 여기서는 `fire_clear = false` 다. 반면 실행 레인
    # (`tools/monitor/run_demo.jl:628`, `CB.enable_hazard!(env; seed=…)` — **`params` 를 안
    # 넘긴다**)은 `CB.HazardParams()` 의 순수 구조체 기본값 `fire_clear = true` 를 그대로 쓴다.
    # 두 레인이 실제로 돌리는 설정에서 `fire_clear` 가 **갈린다.**
    #
    # ⚠️ 어느 쪽이 틀렸는지: `tools/demos.jl:2913`(이 파일의 자체 주석) 은 의도된 의미를 이렇게
    # 적어 뒀다 — "hot-swap 은 고장 본체를 창고로 되돌려 정체성을 보존하므로 견인(clear)하면
    # 안 된다." `run_demo.jl:644` 는 `CB.set_hot_swap!(enabled = true, ...)` 로 hot-swap 을
    # **무조건 켠다**. 그런데 같은 파일 `:628` 의 `enable_hazard!` 호출은 `fire_clear` 를 hot-swap
    # 상태에 맞춰 유도하지 않고 구조체 기본값(true = 견인함)을 그대로 흘려보낸다 — 이 파일 자신의
    # 주석이 말하는 "hot-swap 이면 견인 금지" 규칙과 **반대다.** 라벨 레인(gen_oracle_dataset.jl)
    # 과 `tools/demos.jl` 은 둘 다 `fire_clear = !hotswap` 을 실제로 유도하므로 규칙과 일치한다.
    # 즉 **`run_demo.jl` 이 이 갈림의 틀린 쪽으로 보인다** — 그러나 이 판단은 보고만 하고 고치지
    # 않는다(컨트롤러 라운드 3 지시: "Do not fix that. Report it... and let me rule.").
    ALLOWED_DIVERGENCE = Dict{Symbol,String}(
        :mtbf_break_s => "미확인: 라벨-커버리지 강도 손잡이로 추정(연구 대상 사건과 무관). Task C8 재판정 소유.",
        :mtbf_cell_s  => "미확인: 위와 동일. Task C8 재판정 소유.",
        :max_events   => "미확인: 위와 동일(런어웨이 상한을 좁은 rollout 창에 맞춘 것으로 보임). Task C8 재판정 소유.",
        :fire_clear   => "확인됨(T6 라운드 3, Important 2): DS_HOTSWAP=1(모든 실제 호출)에서 라벨 " *
                          "레인은 fire_clear=false 를 올바르게 유도하지만 run_demo.jl:628 은 " *
                          "HazardParams() 기본값 true 를 그대로 쓴다 — tools/demos.jl 의 자체 주석이 " *
                          "말하는 hot-swap 규칙과 반대. run_demo.jl 이 틀린 쪽으로 보임. 고치지 않고 " *
                          "컨트롤러에게 보고(라운드 3 지시).",
    )

    unexplained = _unexplained_divergences(LABEL_PARAMS_HOTSWAP, EXEC_PARAMS, ALLOWED_DIVERGENCE)
    if !isempty(unexplained)
        @error "라벨 레인(DS_HOTSWAP=1) vs 실행 레인 미해명 불일치 (필드, 라벨값, 실행값)" unexplained
    end
    @test isempty(unexplained)

    # 회귀 고정판: 오늘 실제로 확인된 fire_clear 값 자체를 직접 박아 둔다 — 위 Dict 로직이
    # 잘못돼도 이 값들이 조용히 흘러가지 않게.
    @test LABEL_PARAMS_HOTSWAP.fire_clear == false
    @test EXEC_PARAMS.fire_clear          == true
end

@testset "🔴 tools/demos.jl 의 독립 HazardParams — 세 번째 자리 (T6 라운드 3, Important 3)" begin
    # D-3/D-4/D-5 는 이 자리도 라운드 3 에서 gen_oracle_dataset.jl 과 같은 방식으로 고쳤다
    # (env 로 열되 기본은 HazardParams() 와 맞춤) — 아래서 직접 재확인한다.
    #
    # mtbf_break_s/mtbf_cell_s 는 여기서도 강도 손잡이로 남지만, 이 자리는 근거가 **확인됨**이다
    # — 이 파일 자신의 주석(:2842-2843)이 못박는다: "MTBF 는 빌드 길이에 맞춰야 한다. 트랙터
    # 빌드는 무사고 시 ~20 시뮬초라, 300~400 s 를 쓰면 기대 사건 수가 1 미만이 되어 '아무 일도
    # 안 일어나는' 실행이 나온다(실측: 19.55 s / 1 event)." 짧은 대화형 데모가 사건을 보여주려면
    # 기준 MTBF 를 빌드 길이에 맞게 낮춰야 한다는 것이 소스에 직접 적혀 있다 — gen_oracle_dataset.jl
    # 의 미확인 가설과 달리 여기는 추측이 아니다. `max_events` 는 이 자리에서 아예 안 건드리므로
    # (호출에 그 키워드가 없다) HazardParams() 기본값을 그대로 물려받아 마찰 없이 일치한다.
    #
    # fire_clear 는 바로 위 testset 과 **같은 발견**이다 — 이 자리는 `fire_clear = !HOT_SWAP` 을
    # 스스로 올바르게 유도하고(이 파일 기본 HOT_SWAP="1"), 그래서 여기서도 `false` 가 나와
    # `EXEC_PARAMS` 의 구조체 기본값 `true` 와 갈린다. 새 근거가 아니라 같은 근거의 두 번째 목격.
    ALLOWED_DIVERGENCE = Dict{Symbol,String}(
        :mtbf_break_s => "확인됨(소스 주석 tools/demos.jl:2842-2843): 짧은 대화형 데모 빌드 길이에 맞춘 강도 손잡이(실측: 300~400s MTBF 로는 기대 사건 수 <1).",
        :mtbf_cell_s  => "확인됨: 위와 동일 근거.",
        :fire_clear   => "확인됨 — 위 gen_oracle_dataset.jl/DS_HOTSWAP=1 testset 과 같은 발견의 두 번째 목격(run_demo.jl 쪽이 hot-swap 규칙과 반대로 보임). 고치지 않고 보고.",
    )

    unexplained = _unexplained_divergences(DEMOS_PARAMS, EXEC_PARAMS, ALLOWED_DIVERGENCE)
    if !isempty(unexplained)
        @error "tools/demos.jl vs 실행 레인 미해명 불일치 (필드, 라벨값, 실행값)" unexplained
    end
    @test isempty(unexplained)

    @test DEMOS_PARAMS.drain_sigma        == EXEC_PARAMS.drain_sigma
    @test DEMOS_PARAMS.fire_require_spare == EXEC_PARAMS.fire_require_spare
    @test DEMOS_PARAMS.mtbf_zone_s        == EXEC_PARAMS.mtbf_zone_s
end

@testset "🔴 미확인 강도-손잡이 셋의 비율을 고정한다 (T6 라운드 2, 컨트롤러 지시)" begin
    # 위 testset 들이 mtbf_break_s·mtbf_cell_s·max_events 를 "다르게 튜닝된 강도 손잡이"로
    # 허용하지만, 그 허용을 **오늘 측정한 비율에 고정**한다 — 그래야 어느 한쪽만 조용히 바뀌는
    # 것과 "의도적으로 같이 스케일된" 것을 구분할 수 있다. 라벨값이나 실행값 **어느 한쪽만**
    # 바뀌어도 이 testset 이 걸린다.
    #
    # minor 7 (T6 라운드 3 정정): 예전 코멘트는 "양쪽을 같은 배수 k 로 같이 스케일해도 이
    # testset 이 걸린다"고 썼는데 **틀렸다** — `label/exec` 비율은 k 로 나눠도 그대로이므로
    # 그 경우는 **조용히 통과한다.** 이 gate 가 실제로 잡는 것은 컨트롤러가 요청한 딱 그
    # 경우다: **한쪽만** 움직이는 것. 양쪽을 같이 재교정하는 변경(예: Task C8)은 이 gate 를
    # 통과하지만, 그런 변경은 정의상 "의도적 재교정"이므로 그 자체로 문제가 아니다 — 다만 그
    # 경우에도 아래 상수를 그 시점의 새 비율로 다시 박아 두는 것이 좋다(그래야 그 **다음**
    # 한쪽만의 변경을 이 gate 가 여전히 잡는다). Task C8(λ 교정 + 게이트 N-G3)이 이 갱신을 소유한다.
    #
    # 오늘(2026-08-21) 측정한 비율 — 라벨값 / 실행값:
    RATIO_MTBF_BREAK = 500.0 / 900.0    # label mtbf_break_s=500.0, exec mtbf_break_s=900.0
    RATIO_MTBF_CELL  = 500.0 / 1200.0   # label mtbf_cell_s=500.0,  exec mtbf_cell_s=1200.0
    RATIO_MAX_EVENTS = 12 / 64          # label max_events=12,      exec max_events=64

    for (fname, target_ratio) in ((:mtbf_break_s, RATIO_MTBF_BREAK),
                                   (:mtbf_cell_s,  RATIO_MTBF_CELL),
                                   (:max_events,   RATIO_MAX_EVENTS))
        lv = getfield(LABEL_PARAMS, fname)
        ev = getfield(EXEC_PARAMS, fname)
        measured_ratio = lv / ev
        ok = measured_ratio == target_ratio
        if !ok
            @error "라벨/실행 비율이 오늘 고정한 값과 다르다 — 한쪽만 움직였을 수 있다" field = fname label_value = lv exec_value = ev measured_ratio = measured_ratio pinned_ratio = target_ratio
        end
        @test ok
    end
end

# =============================================================================================
#  🔴 Important 5 (T6 라운드 3) — D-4 는 zone 메커니즘을 **알려진 세계에서도** 무장한다
#  (문서화 + 에스컬레이션만, 고치지 않는다 — 컨트롤러 지시)
#  ---------------------------------------------------------------------------------------------
#  `src/smdp/hazard.jl:475-480`(`hazard_step!` 안, 전역 zone 블록)은 사건 종류 게이팅 없이
#  매 스텝 zone 시계를 돌린다:
#      λz = _rate(st.params.mtbf_zone_s) * st.params.mode
#      if λz > 0
#          st.cum_zone += λz * dt
#          st.cum_zone >= st.thr_zone && _hz_fire_zone!(env, st)
#      end
#  `_hz_fire_zone!`(`:598-615`)은 발화할 때마다 무조건 재장전한다(`st.cum_zone = 0.0; st.thr_zone
#  = _exp1(st.rng_zone)`) — 즉 "이번 실행은 fault 종류만 연구한다"는 선언이 이 시계를 막을 방법이
#  **없다.** `mtbf_zone_s` 가 라운드 1 에서 `Inf`(꺼짐) → `1800.0`(켜짐)으로 바뀌었고, 양쪽 레인이
#  같은 값을 쓰도록 맞춰졌으므로(위 testset 들), **hazard 가 무장된 모든 실행 — fault/battery
#  라벨 rollout 을 포함해 — 이 이제 배경 zone 주입을 받는다.**
#
#  `.claude/CLAUDE.md` 의 OOD 절은 "알려진 세계"가 zone **매크로**뿐 아니라 zone **메커니즘
#  자체**를 배제해야 한다고 요구한다 — 이 변경은 그 경계를 조용히 옮긴다. 이걸 만드는 것은
#  이 태스크의 일탈이 아니다(브리프가 `1800.0` 을 못박았고, 컨트롤러가 두 레인을 맞추라고
#  판정했다) — 그러나 아무 도장도 이 사실을 기록하지 않는다.
#
#  영향받는 라벨 레인 진입점(둘 다 `hz_seed` 가 주어지면 `enable_hazard!(env; params=HZ_PARAMS,
#  seed=hz_seed)` 를 부른다 — `HZ_PARAMS.mtbf_zone_s` 가 이제 유한하므로 무조건 zone 시계가 돎):
#    · `tools/oracle/gen_oracle_dataset.jl:1019` (`studied_prod`, K-rollout)
#    · `tools/oracle/gen_oracle_dataset.jl:1347` (`episode_prod`, 에피소드 모드)
#  두 곳 모두 `kind` 인자로 fault/battery/zone 중 무엇을 연구하는지 알지만, `enable_hazard!` 호출은
#  그 `kind` 를 몰라서 zone 시계를 선택적으로 끌 방법이 없다.
#
#  ⚠️ 추가로: `_hz_fire_zone!` (`hazard.jl:603-608`) 는 주입 실패를 잡아 `@warn` 만 하고 넘어간다
#  (`catch err; @warn "[HAZARD] zone injection failed; deferring" err = err; nothing end`) — 이건
#  기존에 있던 조용한-폴백 모양인데, D-4 가 기본을 유한으로 바꾸면서 **기본적으로 도달 가능**해졌다
#  (전에는 `mtbf_zone_s = Inf` 라 이 경로 자체가 죽은 코드였다).
#
#  이 블록은 시험이 아니라 기록이다 — 코드를 고치지 않는다(experiment-design 결정이지 손잡이가
#  아니라는 것이 컨트롤러 판정). N-G3/후속 게이트가 이 소견을 다뤄야 한다.
# =============================================================================================
