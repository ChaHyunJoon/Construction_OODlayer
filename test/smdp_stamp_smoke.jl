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
    # 리뷰 라운드 1 판정 G: 도장은 "오늘 참인 것"을 선언한다. 태스크 5(2026-08-19)가 3/5/6 을
    # 실제로 은퇴시켰으므로 오늘은 "v2-6arms" 다("v1-9arms" 는 그 이전 세대의 값).
    @test ActionRegistry.VOCAB == "v2-6arms"
    @test length(ActionRegistry.IDS) == 9   # 은퇴는 엔트리를 안 지운다 — 전체 엔트리 수는 그대로 9
    @test ActionRegistry.require_vocab(Dict("vocab" => "v2-6arms"), "ok") === nothing
    @test_throws ErrorException ActionRegistry.require_vocab(Dict{String,Any}(), "도장 없음")
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => "v1-8arms"), "구세대")

    # arm-count 일관성 어서션 — Python 쪽 assert_vocab_arm_count 의 Julia 대응. 오늘은
    # (선언 9, 실제 9)로 통과해야 하고, 태스크 5 가 은퇴를 집행하며 "v2-6arms"/6 으로 바꾸는
    # 순간의 통과가 그 은퇴가 실제로 됐다는 증거다(load-bearing, action_registry.jl 주석 참고).
    @test ActionRegistry.assert_vocab_arm_count("v1-9arms", 9) === nothing
    @test_throws ErrorException ActionRegistry.assert_vocab_arm_count("v1-9arms", 7)
    @test_throws ErrorException ActionRegistry.assert_vocab_arm_count("not-a-vocab-stamp", 9)

    # 리뷰 Minor: 정수 등 문자열이 아닌 도장 값도 계약 메시지(ErrorException)로 죽어야 한다 —
    # 이전엔 `String(::Int64)` 메서드가 없어 MethodError 로 죽었다(죽긴 죽지만 계약 메시지가 아님).
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => 3), "정수 도장")

    # 재리뷰 라운드 2 판정: `n_non_retired` 는 "retired" 표식이 없는 엔트리만 센다 —
    # 은퇴는 엔트리를 안 지우고 표식만 다는 영구적 성질이라(task-5-brief.md Step 3),
    # length(IDS)(전체 엔트리 수)로 재면 태스크 5 이후에도 영원히 9 로 고정돼 어서션이
    # 은퇴를 못 본다.
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

@testset "6팔 확정" begin
    delete!(ENV, "DS_COMBO_ARMS")
    @test ActionRegistry.active_ids() == [0, 1, 2, 4, 7, 8]
    ENV["DS_COMBO_ARMS"] = "1"
    @test ActionRegistry.active_ids() == [0, 1, 2, 4, 7, 8]   # 은퇴가 실험 게이트를 이긴다
    delete!(ENV, "DS_COMBO_ARMS")
    @test ActionRegistry.NAME[3] == "ForbidZone"              # 이름표는 남는다
    @test sort(collect(keys(ActionRegistry.RETIRED))) == [3, 5, 6]
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

@testset "surrogate 아티팩트 어휘 도장 (리뷰 라운드 2 Critical #2)" begin
    # 실제 배포 아티팩트 -- 도장이 없다. 재학습·재수출 없이, 이 검사만으로 죽어야 한다.
    real_path = joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "surrogate", "surrogate_linear.json")
    real_spec = JSON3.read(read(real_path, String))
    @test !haskey(real_spec, :vocab)   # 오늘의 실측을 문서화(이게 언젠가 재수출로 바뀌면 이 줄이 알려준다)
    @test_throws ErrorException Demos.require_surrogate_vocab(real_spec, real_path)

    # 스크래치 사양(현행 vocab 과 일치) -- 통과해야 한다.
    current_vocab = String(JSON3.read(read(Demos._ACTION_REGISTRY, String)).vocab)
    ok_spec = JSON3.read(JSON3.write(Dict("feature_names" => ["macro_0"], "vocab" => current_vocab)))
    @test Demos.require_surrogate_vocab(ok_spec, "scratch-ok") === nothing

    # 스크래치 사양(불일치) -- 죽어야 한다.
    bad_spec = JSON3.read(JSON3.write(Dict("feature_names" => ["macro_0"], "vocab" => "v1-9arms")))
    @test_throws ErrorException Demos.require_surrogate_vocab(bad_spec, "scratch-bad")
end
