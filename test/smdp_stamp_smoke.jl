# test/smdp_stamp_smoke.jl
# 도장 계약의 Julia 쪽. Python 과 **같은 문자열**을 읽는지, 그리고 도장 없는 입력에서
# 정말 죽는지(음성 대조)를 본다.
#   julia +lts --project=. test/smdp_stamp_smoke.jl
using ConstructionBots
using Test
import JSON3
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))

@testset "어휘 도장" begin
    # 도장은 "오늘 참인 것"을 선언한다. 2026-08-24 3팔 축소로 오늘은 "v4-3arms" 다.
    # 이 세대는 은퇴 표식이 아니라 **엔트리 삭제** 정책이라 전체 엔트리 수도 3 이다.
    @test ActionRegistry.VOCAB == "v4-3arms"
    @test length(ActionRegistry.IDS) == 3
    @test ActionRegistry.IDS == [0, 1, 2]
    @test ActionRegistry.require_vocab(Dict("vocab" => "v4-3arms"), "ok") === nothing
    @test_throws ErrorException ActionRegistry.require_vocab(Dict{String,Any}(), "도장 없음")
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => "v3-4arms"), "구세대")
    # ⚠️ 재번호(0..2 연속) 이후 도장이 **유일한** 방어선이다 — 예전에는 구세대 macro id 가 영구
    # 결번이라 조회 실패로도 죽었지만, 이제 v3-4arms 세대의 macro 2(RelocateBuild) 행이 새
    # 어휘에서 SwapBattery 로 조용히 읽힌다. 위 두 줄이 그 유일한 문지기의 회귀 검사다.

    # arm-count 일관성 어서션 — Python 쪽 assert_vocab_arm_count 의 Julia 대응. 오늘은
    # (선언 9, 실제 9)로 통과해야 하고, 태스크 5 가 은퇴를 집행하며 "v2-6arms"/6 으로 바꾸는
    # 순간의 통과가 그 은퇴가 실제로 됐다는 증거다(load-bearing, action_registry.jl 주석 참고).
    @test ActionRegistry.assert_vocab_arm_count("v1-9arms", 9) === nothing
    @test_throws ErrorException ActionRegistry.assert_vocab_arm_count("v1-9arms", 7)
    @test_throws ErrorException ActionRegistry.assert_vocab_arm_count("not-a-vocab-stamp", 9)

    # 리뷰 Minor: 정수 등 문자열이 아닌 도장 값도 계약 메시지(ErrorException)로 죽어야 한다 —
    # 이전엔 `String(::Int64)` 메서드가 없어 MethodError 로 죽었다(죽긴 죽지만 계약 메시지가 아님).
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => 3), "정수 도장")

    # `n_non_retired` 는 "retired" 표식이 없는 엔트리만 센다. 2026-08-20 세대의 실제
    # registry 에는 은퇴 엔트리가 0 개지만(삭제 정책), 이 술어 자체는 계약으로 남아 있고
    # Julia/Python 두 로더가 같은 규칙을 써야 하므로 스크래치 registry 로 계속 검사한다.
    _small = JSON3.read("""{"macros": {"0": {"name":"A","cost":1.0},
                                        "1": {"name":"B","cost":1.0,"retired":true},
                                        "2": {"name":"C","cost":1.0,"retired":false}}}""")
    _small_registry = Dict{Int,Any}(parse(Int, String(k)) => v for (k, v) in pairs(_small.macros))
    @test ActionRegistry.n_non_retired(_small_registry) == 2
end

# ---- 태스크 5 시나리오 (스크래치 registry, 서브프로세스) -----------------------------------
# Julia 의 `const VOCAB`/어서션 호출도 파일이 처음 include 될 때 딱 한 번 평가된다 — 같은
# 프로세스 안에서 다른 ACTION_REGISTRY 로 재로드를 검증할 수 없다(재-include 해도 `const`
# 재정의 경고/에러가 난다). 그래서 Python 쪽과 같은 방식으로 **서브프로세스**를 띄운다.
# 커밋된 action_registry.json 은 절대 건드리지 않는다.
function _synthetic_registry_json(vocab; retired_ids::Vector{Int}=Int[])
    macros = Dict{String,Any}()
    for i in 0:8
        entry = Dict{String,Any}("name" => "Macro$(i)", "cost" => 1.0,
                                  "kinds" => ["fault"], "doc" => "synthetic")
        i in retired_ids && (entry["retired"] = true)
        macros[string(i)] = entry
    end
    return JSON3.write(Dict("vocab" => vocab, "macros" => macros))
end

function _write_scratch_registry(vocab; retired_ids::Vector{Int}=Int[])
    path = tempname() * ".json"
    write(path, _synthetic_registry_json(vocab; retired_ids=retired_ids))
    return path
end

function _load_in_subprocess(json_path)
    ar_path = normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
    proj_dir = normpath(joinpath(@__DIR__, ".."))
    script_path = tempname() * ".jl"
    write(script_path, "include(raw\"$(ar_path)\")\n")
    env = copy(ENV)
    env["ACTION_REGISTRY"] = json_path
    cmd = setenv(`julia +lts --project=$(proj_dir) $(script_path)`, env)
    errbuf = IOBuffer()
    proc = run(pipeline(cmd; stdout=devnull, stderr=errbuf); wait=false)
    wait(proc)
    return (success = (proc.exitcode == 0), stderr = String(take!(errbuf)))
end

@testset "태스크 5 시나리오 (스크래치 registry, 서브프로세스)" begin
    r_today = _load_in_subprocess(_write_scratch_registry("v1-9arms"; retired_ids=Int[]))
    @test r_today.success

    # 태스크 5 가 실제로 저지를 수 있는 실수: 3/5/6 을 은퇴시켰는데 도장 문자열을 그대로
    # "v1-9arms" 로 남겼다. 어서션이 이걸 못 잡으면(= 재리뷰 이전 상태) 도장은 장식이다.
    r_stale = _load_in_subprocess(_write_scratch_registry("v1-9arms"; retired_ids=[3, 5, 6]))
    @test !r_stale.success
    @test occursin("거짓말한다", r_stale.stderr)

    # 태스크 5 의 올바른 변경: 3/5/6 을 은퇴시키고 도장을 "v2-6arms" 로 갈아 끼웠다.
    # 어서션이 이걸 막으면(= 재리뷰 이전 상태, 선언 6 vs 실제 9 로 죽음) 태스크 5 가
    # 정상적으로 끝날 수 없다.
    r_bumped = _load_in_subprocess(_write_scratch_registry("v2-6arms"; retired_ids=[3, 5, 6]))
    @test r_bumped.success
end

@testset "3팔 확정 (2026-08-24 축소, id 재번호 0..2)" begin
    delete!(ENV, "DS_COMBO_ARMS")
    @test ActionRegistry.active_ids() == [0, 1, 2]
    ENV["DS_COMBO_ARMS"] = "1"
    @test ActionRegistry.active_ids() == [0, 1, 2]   # 지워진 조합 팔은 플래그로도 안 살아난다
    delete!(ENV, "DS_COMBO_ARMS")
    @test ActionRegistry.NAME == Dict(0 => "NOOP", 1 => "Replace", 2 => "SwapBattery")
    @test ActionRegistry.COST == Dict(0 => 0.0, 1 => 1.0, 2 => 0.2)
    # 은퇴 표식이 아니라 삭제 정책 — RETIRED 는 비어 있다
    @test isempty(ActionRegistry.RETIRED)
    # 지워진 팔은 registry 밖 id 이므로 is_active 가 false 여야 한다(KeyError 가 아니라)
    for gone in (3, 4, 5, 6, 7, 8, -1, 99)
        @test ActionRegistry.is_active(gone) == false
    end
    # reform 도 zone 도 더 이상 사건 종류가 아니다
    @test isempty(ActionRegistry.kind_valid(:reform))
    @test isempty(ActionRegistry.kind_valid(:zone))
    @test ActionRegistry.kind_valid(:fault)   == [0, 1]
    @test ActionRegistry.kind_valid(:battery) == [0, 1, 2]
end

# ---- 판정 K: retired 표식 형식 — 4경우(양 언어 동일 규칙). 공유 truthy 규약으로 합의하지
# 않는다 — 갈린 것이 바로 truthiness 다. "retired" 가 boolean 이 아니면 무조건 에러여야 한다.
@testset "retired 표식 형식 (판정 K, 4경우)" begin
    # 실제 REGISTRY 값과 같은 타입(JSON3.Object)으로 만든다 — dot-access(`m.retired`)가
    # 실제 로더와 같은 경로를 타야 이 테스트가 로더를 실제로 검증한다. JSON3.write(Dict(...))
    # 로 만들어 문자열 안에 따옴표를 손으로 이스케이프하는 함정을 피한다.
    function _mk(entry)
        blob = JSON3.write(Dict("0" => entry))
        obj = JSON3.read(blob)
        return Dict{Int,Any}(parse(Int, String(k)) => v for (k, v) in pairs(obj))
    end
    reg_str = _mk(Dict("name" => "X", "cost" => 1.0, "retired" => "2026-08-19 spec §2.1 ..."))
    reg_true = _mk(Dict("name" => "X", "cost" => 1.0, "retired" => true))
    reg_false = _mk(Dict("name" => "X", "cost" => 1.0, "retired" => false))
    reg_absent = _mk(Dict("name" => "X", "cost" => 1.0))

    # 문자열 → 에러(매크로 id 를 밝히며)
    err = try
        ActionRegistry.n_non_retired(reg_str)
        nothing
    catch e
        e
    end
    @test err isa Exception
    @test occursin("0", sprint(showerror, err))
    # true → 은퇴(0개 비은퇴)
    @test ActionRegistry.n_non_retired(reg_true) == 0
    # false → 비은퇴(1개 비은퇴)
    @test ActionRegistry.n_non_retired(reg_false) == 1
    # 부재 → 비은퇴(1개 비은퇴)
    @test ActionRegistry.n_non_retired(reg_absent) == 1
end

@testset "동역학 도장" begin
    CB.disable_hazard!()
    @test CB.dynamics_stamp() == "hazard-off"

    # 리뷰 [Important]: hazard-on 분기가 실제로 hazard 상태를 읽는지 확인한다. 이게 없으면
    # dynamics_stamp() = "hazard-off" 리터럴로도 위 검사와 DEMO_SUMMARY 의 assert 를 그대로
    # 통과한다(2026-08-16 의 "영원히 실패할 수 없는 검사"와 같은 모양). 전역 상태를 직접
    # 세우고 반드시 disable_hazard!() 로 복구한다 — 다른 테스트로 새면 안 된다.
    try
        CB.HAZARD_STATE[] = CB._new_hazard_state(CB.HazardParams(), 7)
        CB.HAZARD_ENABLED[] = true
        @test CB.dynamics_stamp() == "hazard-on"
    finally
        CB.disable_hazard!()
    end
    @test CB.dynamics_stamp() == "hazard-off"
end

# ---- 리뷰 F1 (판정: Important) — 은퇴가 combo-arm 경로에서 새는지 회귀 검사 --------------------
# `ood_mdp_shim.action_to_proposal` 의 `combo_arms_on() && a in COMBO_IDS` 분기가 `valid_actions`
# 문지기보다 먼저 return 해서, `DS_COMBO_ARMS=1` 만으로 은퇴한 macro 5/6 이 진짜 RespecProposal 을
# 만들 수 있었다(`_zone_arms_for` 에서 고친 것과 같은 모양의 구멍, 같은 파일). 수정 전에는 이
# 테스트가 macro 5 에서 `nothing` 이 아닌 RespecProposal 을 받아 **빨간불**이었다(실측,
# 2026-08-19 리뷰 라운드 2). `ActionRegistry.is_active(a)` 가드를 그 분기 조건에 추가해 닫았다.
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "ood_mdp_shim.jl"))

@testset "은퇴는 combo-arm 경로도 이긴다 (리뷰 F1)" begin
    ENV["DS_COMBO_ARMS"] = "1"
    try
        agent = CB.RobotID(id=1)
        ctx5 = (type=:fault, agent=agent, zone=nothing, assembly=nothing, soc=NaN, after=0.0, source="test")
        ctx6 = (type=:fault, agent=agent, zone=nothing, assembly=nothing, soc=NaN, after=0.0, source="test")
        @test action_to_proposal(ctx5, 5) === nothing   # 은퇴한 macro 5, DS_COMBO_ARMS=1 이어도 프로포절 없음
        @test action_to_proposal(ctx6, 6) === nothing   # 같은 이유로 macro 6 도 없음
        # 게이트가 combo 분기만 막고 살아 있는 팔까지 죽이지 않는지 양성 대조(같은 ctx, macro 1).
        @test action_to_proposal(ctx5, 1) !== nothing
    finally
        delete!(ENV, "DS_COMBO_ARMS")
    end
end

# ---- 리뷰 라운드 2 Critical #2 — surrogate 아티팩트의 어휘 도장 (판정: Critical) --------------
# `surrogate_linear.json` 이 도장 없이 배포돼 있었다(2026-08-19 실측: macro_3 9열 포함 63열,
# vocab 필드 없음). export_surrogate.py 가 이제 "vocab" 을 찍고, tools/demos.jl 의
# `require_surrogate_vocab` 이 그것을 대조한다(부재/불일치 시 죽는다 — action_registry 의
# require_vocab 과 같은 계약). demos.jl 은 `module Demos` 로 감싸여 있고 CLI 실행부가
# `abspath(PROGRAM_FILE) == @__FILE__` 로 막혀 있어 include 해도 데모가 돌지 않는다(안전).
include(joinpath(@__DIR__, "..", "tools", "demos.jl"))

@testset "surrogate 아티팩트 어휘 도장 (리뷰 라운드 2/3 Critical)" begin
    # 리뷰 라운드 3 Important 수정: 예전엔 여기서 실제
    # `wm4spacecraft_manufacturing/surrogate/surrogate_linear.json` 을 읽었다 — 그런데 그 파일은
    # **커밋돼 있지 않다**(작업 트리에만 있는 산출물). 깨끗한 체크아웃에는 그 파일이 아예 없으므로
    # `read()` 가 `SystemError` 로 죽어 이 테스트 파일 전체가 빨간불이 된다(리뷰가 잡은 "NEW-0"
    # 모양 — 검사 **자신**이 커밋 안 된 아티팩트에 기대는 새 결함). 그래서 실제 파일을 읽지 않고
    # 문제가 됐던 두 모양(도장 없음 / 도장은 맞는데 열이 오염됨)을 **스크래치로 합성**한다 — 저장소
    # 상태와 무관하게 항상 같은 결과를 내야 진짜 회귀 검사다.
    # 라운드 4: 도장 값도 정경(`ActionRegistry.VOCAB`)에서 받는다 — 예전엔 여기서 파일을
    # 다시 파싱했고, 게이트가 ENV(`ACTION_REGISTRY`)를 존중하게 된 뒤로는 그 사본이 게이트와
    # 다른 파일을 볼 수 있었다.
    current_vocab = Demos.ActionRegistry.VOCAB
    # 2026-08-20: 오염 판정 기준이 "은퇴 id" 에서 "레지스트리 밖 id" 로 바뀌었다(삭제 정책이라
    # RETIRED 가 언제나 비어 있어 예전 전제가 항진이 된다). 아래 검사가 공회전하지 않는다는
    # 전제는 이제 "살아있는 어휘가 전체 정수의 진부분집합" 이다.
    live_ids = sort(collect(Demos.ActionRegistry.IDS))
    @test live_ids == [0, 1, 2]
    # 구세대 id — 이 세대의 레지스트리 밖이므로 열에 남아 있으면 오염이다.
    # 2026-08-24 3팔 축소로 **3 이 여기 합류했다**(구 SwapBattery id). 이 목록이 낡으면
    # 재번호가 조용히 통과한다.
    dead_ids = [3, 4, 5, 6, 7, 8]
    @test isempty(intersect(Set(live_ids), Set(dead_ids)))

    # 사례 1 (Critical #2): 도장 자체가 없다 -- 구세대 아티팩트의 실측 모양을 그대로 합성.
    unstamped_spec = JSON3.read(JSON3.write(Dict("feature_names" =>
        ["soc", "macro_0", "macro_1", "macro_2", "macro_3", "macro_4", "macro_7", "macro_8"])))
    @test !haskey(unstamped_spec, :vocab)
    @test_throws ErrorException Demos.require_surrogate_vocab(unstamped_spec, "scratch-unstamped")

    # 사례 2: 도장은 **현행과 정확히 일치**하는데 실제 열에는 구세대 macro_7(RelocateBuild 의
    # 옛 id)이 남아 있다 -- "나쁜 재수출"의 정직한 모양. 도장 문자열만 보면 조용히 통과한다.
    # 이제는 죽어야 한다 -- 이게 이 테스트의 핵심이고, 재번호 세대에서 특히 중요하다.
    stamped_but_contaminated = JSON3.read(JSON3.write(Dict(
        "vocab" => current_vocab, "feature_names" => ["soc", "macro_0", "macro_7", "macro_1"])))
    @test_throws ErrorException Demos.require_surrogate_vocab(stamped_but_contaminated, "scratch-stamped-but-contaminated")

    # 스크래치 사양(현행 vocab 과 일치 + 은퇴한 열 없음) -- 통과해야 한다.
    ok_spec = JSON3.read(JSON3.write(Dict("feature_names" => ["macro_0", "macro_1__x__soc"], "vocab" => current_vocab)))
    @test Demos.require_surrogate_vocab(ok_spec, "scratch-ok") === nothing

    # 스크래치 사양(도장 문자열 자체가 불일치) -- 죽어야 한다.
    bad_spec = JSON3.read(JSON3.write(Dict("feature_names" => ["macro_0"], "vocab" => "v1-9arms")))
    @test_throws ErrorException Demos.require_surrogate_vocab(bad_spec, "scratch-bad")

    # 라운드 3 §3.4 C1 (라운드 4 에서 봉합): 한 열 이름 안에 산 id 가 은퇴 id 보다 **앞에**
    # 오면 `match` 는 첫 매치만 보고 은퇴 id 를 놓쳤다. `eachmatch` 로 바꿨으니 죽어야 한다.
    c1_spec = JSON3.read(JSON3.write(Dict(
        "vocab" => current_vocab, "feature_names" => ["macro_0__x__macro_$(first(dead_ids))"])))
    @test_throws ErrorException Demos.require_surrogate_vocab(c1_spec, "scratch-c1-second-id")

    # 라운드 4 [Minor]: "틀린 게 아니라 없는" 모양은 fail-closed 여야 하고, **계약 에러**
    # (ErrorException)로 죽어야 한다 -- 예전엔 KeyError/MethodError 라 이 형태의 단언이
    # 못 덮었고, 빈 리스트는 아예 통과했다.
    @test_throws ErrorException Demos.require_surrogate_vocab(
        JSON3.read(JSON3.write(Dict("vocab" => current_vocab, "features" => ["macro_0"]))), "scratch-wrong-key")
    @test_throws ErrorException Demos.require_surrogate_vocab(
        JSON3.read(JSON3.write(Dict("vocab" => current_vocab, "feature_names" => String[]))), "scratch-empty")
    @test_throws ErrorException Demos.require_surrogate_vocab(
        JSON3.read(JSON3.write(Dict("vocab" => current_vocab, "feature_names" => "macro_0"))), "scratch-not-a-list")

    # ---- 실제 아티팩트 (라운드 4 [Important] 재구성) ------------------------------------------
    # 예전 이 블록은 실물이 있으면 `@test_throws ErrorException ...(real_spec)` 을 **무조건**
    # 걸었다. 즉 "배포된 surrogate 아티팩트는 영원히 오염돼 있다" 를 단언한 것이다. 이 게이트가
    # 존재하는 목적(태스크 6 필터로 데이터를 정리한 뒤 깨끗하게 재수출)이 달성되는 순간 이
    # 영구 회귀 테스트가 **정답 위에서 빨간불**이 된다 -- 재리뷰가 실물을 정상 모양(도장
    # v2-6arms + 은퇴열 제거)으로 만들어 EXIT=1 을 실측했다. 저장소가 깨져 있는 동안에만 통과할
    # 수 있는 검사는 "영원히 실패할 수 없는 검사" 의 거울상이고, 최악의 순간에 "고치려고" 지워진다.
    #
    # 그래서 **파일의 현재 내용에 대한 사실**이 아니라 **규칙**을 단언한다. 실물의 열 이름을
    # 그대로 재료로 써서:
    #   (a) 은퇴 macro 열을 걷어낸 사양은 **통과해야 한다**(깨끗한 재수출은 받아준다),
    #   (b) 같은 열에 은퇴 macro 열을 하나 되돌린 사양은 **죽어야 한다**(오염은 거부한다).
    # 둘 다 오늘 실물이 오염돼 있든 깨끗하든 **언제나** 참이다. 오늘의 실물이 어느 쪽인지는
    # 게이트와 독립적인 열 스캔으로 재서 **단언이 아니라 일치성**으로만 확인한다.
    real_path = joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "surrogate", "surrogate_linear.json")
    if isfile(real_path)
        real_spec = JSON3.read(read(real_path, String))
        real_cols = String[String(f) for f in real_spec["feature_names"]]
        _has_retired(c) = any(!(parse(Int, mm.captures[1]) in Set(live_ids))
                              for mm in eachmatch(r"macro_(\d+)", c))

        # (a) 깨끗한 쪽 -- 실물의 열에서 은퇴 열만 뺀 것.
        clean_cols = filter(!_has_retired, real_cols)
        @test !isempty(clean_cols)
        clean_spec = JSON3.read(JSON3.write(Dict("vocab" => current_vocab, "feature_names" => clean_cols)))
        @test Demos.require_surrogate_vocab(clean_spec, "real-artifact-cleaned") === nothing

        # (b) 오염된 쪽 -- 같은 열에 은퇴 macro 열을 하나 되돌린 것.
        stale_cols = vcat(clean_cols, "macro_$(first(dead_ids))")
        stale_spec = JSON3.read(JSON3.write(Dict("vocab" => current_vocab, "feature_names" => stale_cols)))
        @test_throws ErrorException Demos.require_surrogate_vocab(stale_spec, "real-artifact-restaled")

        # 오늘의 실물: 게이트의 판정이 **독립 스캔**의 판정과 같은가. 실물이 오염돼 있으면 둘 다
        # 거부, 깨끗해지면 둘 다 승인 -- 어느 쪽이든 초록이고, 갈리면 빨간불이다.
        indep_ok = haskey(real_spec, :vocab) && String(real_spec.vocab) == current_vocab &&
                   !isempty(real_cols) && !any(_has_retired, real_cols)
        gate_ok = try (Demos.require_surrogate_vocab(real_spec, real_path); true) catch; false end
        @test gate_ok == indep_ok
        @info "배포된 surrogate 아티팩트 오늘의 상태" path=real_path n_cols=length(real_cols) accepted=gate_ok
    end
end
