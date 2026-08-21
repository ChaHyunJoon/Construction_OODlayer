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

# ---- gen_oracle_dataset.jl 의 실제 HZ_PARAMS 생성자를 소스에서 파싱해 평가 -----------------
# 손으로 적은 이름 목록이 아니라, `CB.HazardParams(...)` 호출을 **그 소스 그대로 파싱해 평가**한다
# — 그래야 나중에 그 호출에 필드가 하나 늘어도 이 시험이 저절로 걸린다(사람이 목록을 안 늘려도 됨).
# ENV 를 지운 채 평가하므로 "아무 DS_* 도 안 준 기본 호출"과 정확히 같다. 두 testset(전체-필드
# 대조 + 비율 고정)이 같은 `label_params`/`exec_params` 를 쓰므로 여기 top level 에서 한 번만 판다.
const _DS_PATH = joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "gen_oracle_dataset.jl")
const _DS_SRC  = read(_DS_PATH, String)
let mi = findfirst("const HZ_PARAMS", _DS_SRC)
    mi === nothing && error("HZ_PARAMS 상수를 못 찾았다 — gen_oracle_dataset.jl 구조가 바뀌었다")
    ci = findnext("CB.HazardParams(", _DS_SRC, first(mi))
    ci === nothing && error("HZ_PARAMS 정의 안에서 CB.HazardParams( 호출을 못 찾았다")
    global _HZ_CALL_START = first(ci)
end
let depth = 0, stop = nothing
    # ⚠️ 파일에 한글 주석(멀티바이트 UTF-8)이 섞여 있어 `start:lastindex(src)` 처럼 정수를 1씩
    # 늘리며 인덱싱하면 문자 경계 중간을 가리켜 StringIndexError 가 난다(실측). `eachindex` 로
    # 코드포인트 경계만 밟는다.
    for i in eachindex(_DS_SRC)
        i < _HZ_CALL_START && continue
        c = _DS_SRC[i]
        c == '(' && (depth += 1)
        c == ')' && (depth -= 1; depth == 0 && (stop = i; break))
    end
    stop === nothing && error("CB.HazardParams(...) 호출의 괄호 짝을 못 찾았다")
    global _HZ_CALL_SRC = _DS_SRC[_HZ_CALL_START:stop]
end

# 이 프로세스에 우연히 DS_* 가 이미 설정돼 있으면 "기본값" 비교가 아니게 된다 — 명시적으로 지운다.
for k in ("DS_MTBF_BREAK", "DS_MTBF_CELL", "DS_MTBF_ZONE", "DS_DRAIN_SIGMA",
          "DS_FIRE_REQUIRE_SPARE", "DS_HOTSWAP", "HOT_SWAP", "DS_MAX_EVENTS")
    haskey(ENV, k) && delete!(ENV, k)
end
const LABEL_PARAMS = Base.eval(Main, Meta.parse(_HZ_CALL_SRC))::CB.HazardParams
const EXEC_PARAMS  = CB.HazardParams()

@testset "🔴 라벨 레인 HZ_PARAMS 전 필드 기계적 대조 (T6 라운드 2, 컨트롤러 지시)" begin
    # "안 건드리면 같은 세계" 가 기본값이다 — 다르게 튜닝된 필드는 여기 **이름을 박고 근거를 달아야**
    # 통과한다(코멘트 없이 그냥 빼는 조용한 폴백을 막으려고 Dict 값이 String 이어야 함).
    # D-3(fire_require_spare)·D-4(mtbf_zone_s) 는 사건 **종류**가 아예 가능한지를 가르는 구조적
    # 스위치라 두 레인이 반드시 같아야 했고, 이제 같다(위 컨트롤러 라운드 1 지시로 고침).
    #
    # 아래 세 항목(mtbf_break_s·mtbf_cell_s·max_events)은 **강도(intensity) 손잡이**로 남겨 둔다
    # (T6 라운드 2, 컨트롤러 판정): 데이터 생성기가 짧은 에피소드 안에서 사건이 실제로 나오도록
    # 발생률을 올리는 것은 라벨 커버리지를 위한 통상적 importance sampling 이지 버그가 아니다 —
    # 단 이 근거는 **미확인**이다(소스에 설계자 코멘트가 없다). 결정적으로, 실행 레인의
    # `mtbf_*` 자체가 **미교정**이다(`hazard.jl` 의 `mtbf_zone_s` 주석: "⚠️ 미교정 초기값이다.
    # Task C8(N-G3)이 교정한다") — 그 자체가 잠정인 숫자에 라벨 레인을 강제로 맞추는 것은 아무
    # 의미가 없다. **Task C8(λ 교정 + 게이트 N-G3)이 이 셋의 재판정을 소유한다** — C8 이
    # `hazard.jl` 의 `mtbf_break_s`/`mtbf_cell_s` 를 교정하면, 그때 의미 있는 것은 라벨 레인의
    # **절대값이 아니라 실행 레인에 대한 비율**이다(바로 아래 testset 이 그 비율을 고정한다).
    ALLOWED_DIVERGENCE = Dict{Symbol,String}(
        :mtbf_break_s => "미확인: 라벨-커버리지 강도 손잡이로 추정(연구 대상 사건과 무관). Task C8 재판정 소유.",
        :mtbf_cell_s  => "미확인: 위와 동일. Task C8 재판정 소유.",
        :max_events   => "미확인: 위와 동일(런어웨이 상한을 좁은 rollout 창에 맞춘 것으로 보임). Task C8 재판정 소유.",
    )

    unexplained = Tuple{Symbol,Any,Any}[]
    for f in fieldnames(CB.HazardParams)
        lv = getfield(LABEL_PARAMS, f)
        ev = getfield(EXEC_PARAMS, f)
        lv == ev && continue
        haskey(ALLOWED_DIVERGENCE, f) && continue
        push!(unexplained, (f, lv, ev))
    end
    if !isempty(unexplained)
        @error "라벨 레인 vs 실행 레인 미해명 불일치 (필드, 라벨값, 실행값)" unexplained
    end
    @test isempty(unexplained)

    # D-3/D-4/D-5 는 위 루프와 별개로 직접 재확인(회귀 고정판) — 루프 로직이 잘못돼도 이건 남는다.
    @test LABEL_PARAMS.drain_sigma        == EXEC_PARAMS.drain_sigma
    @test LABEL_PARAMS.fire_require_spare == EXEC_PARAMS.fire_require_spare
    @test LABEL_PARAMS.mtbf_zone_s        == EXEC_PARAMS.mtbf_zone_s
end

@testset "🔴 미확인 강도-손잡이 셋의 비율을 고정한다 (T6 라운드 2, 컨트롤러 지시)" begin
    # 위 testset 이 mtbf_break_s·mtbf_cell_s·max_events 를 "다르게 튜닝된 강도 손잡이"로
    # 허용하지만, 그 허용을 **오늘 측정한 비율에 고정**한다 — 그래야 어느 한쪽만 조용히 바뀌는
    # 것과 "의도적으로 같이 스케일된" 것을 구분할 수 있다. 라벨값이나 실행값 **어느 한쪽만**
    # 바뀌어도 이 testset 이 걸린다; 둘을 같은 비율로 같이 바꾸면(예: C8 이 실행 레인을 재교정하며
    # 라벨 레인도 같은 배수로 맞추면) 통과하려면 이 상수도 같이 고쳐야 한다 — 그것이 바로
    # "묵시적으로 넘어가지 않는다" 는 점이다. Task C8(λ 교정 + 게이트 N-G3)이 이 셋의 재판정과
    # 함께 이 비율 상수의 갱신도 소유한다.
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
