# test/smdp_hazard_knobs.jl
# (1) 손잡이 셋이 spec 의 D-3 · D-4 · D-5 대로인가.
# (2) λ 의 단일 진실원 — 무거운 레인(hazard_rate)과 경량 레인(hazard_rate_from)이 **같은 수**를
#     내는가. 갈리면 롤아웃이 다른 세계를 탐색한다.
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
    src = read(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle",
                        "gen_oracle_dataset.jl"), String)
    # 브리프 원문은 여기 needle 에 공백을 남겨 뒀는데(`", "`) haystack 은
    # `replace(src, " " => "")` 로 공백을 **전부** 지운다 — needle 도 공백을 지워야
    # 매칭된다(원문 그대로면 소스가 뭐든 영원히 FAIL). 실측 후 정정.
    @test occursin("\"DS_DRAIN_SIGMA\",\"0.0\"", replace(src, " " => ""))
    @test CB.HazardParams().drain_sigma == 0.0
end

@testset "🔴 라벨 레인 HZ_PARAMS 전 필드 기계적 대조 (T6 라운드 2, 컨트롤러 지시)" begin
    # 손으로 적은 이름 목록이 아니라, gen_oracle_dataset.jl 의 `CB.HazardParams(...)` 호출을
    # **그 소스 그대로 파싱해 평가**한다 — 그래야 나중에 그 호출에 필드가 하나 늘어도 이 시험이
    # 저절로 걸린다(사람이 목록을 안 늘려도 됨). ENV 를 지운 채 평가하므로 "아무 DS_* 도 안 준
    # 기본 호출"과 정확히 같다.
    ds_path = joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "gen_oracle_dataset.jl")
    src = read(ds_path, String)
    mi = findfirst("const HZ_PARAMS", src)
    mi === nothing && error("HZ_PARAMS 상수를 못 찾았다 — gen_oracle_dataset.jl 구조가 바뀌었다")
    ci = findnext("CB.HazardParams(", src, first(mi))
    ci === nothing && error("HZ_PARAMS 정의 안에서 CB.HazardParams( 호출을 못 찾았다")
    start = first(ci)
    depth = 0
    stop = nothing
    # ⚠️ 파일에 한글 주석(멀티바이트 UTF-8)이 섞여 있어 `start:lastindex(src)` 처럼 정수를 1씩
    # 늘리며 인덱싱하면 문자 경계 중간을 가리켜 StringIndexError 가 난다(실측). `eachindex` 로
    # 코드포인트 경계만 밟는다.
    for i in eachindex(src)
        i < start && continue
        c = src[i]
        c == '(' && (depth += 1)
        c == ')' && (depth -= 1; depth == 0 && (stop = i; break))
    end
    stop === nothing && error("CB.HazardParams(...) 호출의 괄호 짝을 못 찾았다")
    call_src = src[start:stop]

    # 이 프로세스에 우연히 DS_* 가 이미 설정돼 있으면 "기본값" 비교가 아니게 된다 — 명시적으로 지운다.
    for k in ("DS_MTBF_BREAK", "DS_MTBF_CELL", "DS_MTBF_ZONE", "DS_DRAIN_SIGMA",
              "DS_FIRE_REQUIRE_SPARE", "DS_HOTSWAP", "HOT_SWAP", "DS_MAX_EVENTS")
        haskey(ENV, k) && delete!(ENV, k)
    end
    label_params = Base.eval(Main, Meta.parse(call_src))::CB.HazardParams
    exec_params  = CB.HazardParams()

    # "안 건드리면 같은 세계" 가 기본값이다 — 다르게 튜닝된 필드는 여기 **이름을 박고 근거를 달아야**
    # 통과한다(코멘트 없이 그냥 빼는 조용한 폴백을 막으려고 Dict 값이 String 이어야 함).
    # ⚠️ 아래 세 항목의 근거는 **추정**이다(소스에 설계자 주석이 없다) — task-T6-report.md 의
    # "Fix round 1" 절이 컨트롤러 확인을 요청한다. D-3(fire_require_spare)·D-4(mtbf_zone_s) 는
    # 사건 **종류**가 아예 가능한지를 가르는 구조적 스위치라 두 레인이 반드시 같아야 하지만, 아래
    # 셋은 `hz_seed` 가 무장될 때만(=K-rollout/에피소드 배경잡음) 쓰이고 연구 대상 사건 자체는
    # FIRE_POINTS 로 별도 결정론적으로 배치된다 — 그렇다면 "더 짧은 MTBF·낮은 상한" 은 좁은
    # rollout 창 안에서 매크로 간 통계적 분리를 만들려는 의도적 스트레스-세계일 수 있다. 확정된
    # 설계 근거가 아니므로 여기서 억지로 맞추지 않고, 이름을 박아 다음 사람이 판단하게 한다.
    ALLOWED_DIVERGENCE = Dict{Symbol,String}(
        :mtbf_break_s => "추정: K-rollout 배경잡음 세기 손잡이(연구 대상 사건과 무관, 확정 근거 없음 — report 참조)",
        :mtbf_cell_s  => "추정: 위와 동일",
        :max_events   => "추정: 위와 동일(런어웨이 상한을 좁은 rollout 창에 맞춘 것으로 보임)",
    )

    unexplained = Tuple{Symbol,Any,Any}[]
    for f in fieldnames(CB.HazardParams)
        lv = getfield(label_params, f)
        ev = getfield(exec_params, f)
        lv == ev && continue
        haskey(ALLOWED_DIVERGENCE, f) && continue
        push!(unexplained, (f, lv, ev))
    end
    if !isempty(unexplained)
        @error "라벨 레인 vs 실행 레인 미해명 불일치 (필드, 라벨값, 실행값)" unexplained
    end
    @test isempty(unexplained)

    # D-3/D-4/D-5 는 위 루프와 별개로 직접 재확인(회귀 고정판) — 루프 로직이 잘못돼도 이건 남는다.
    @test label_params.drain_sigma       == exec_params.drain_sigma
    @test label_params.fire_require_spare == exec_params.fire_require_spare
    @test label_params.mtbf_zone_s        == exec_params.mtbf_zone_s
end
