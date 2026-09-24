# test/repair_ablation_wiring.jl — 렌더 경로 배선의 소스 고정(명세 §6·§7)
#   julia +lts --project=. test/repair_ablation_wiring.jl
using Test
const ROOT = normpath(joinpath(@__DIR__, ".."))
src(p) = read(joinpath(ROOT, p), String)

@testset "render_demo: 레벨 설정 → run_ctx → 주입 → 무장 → score → ablation 순서" begin
    s = src("tools/monitor/render_demo.jl")
    i_set   = findfirst("CB.set_repair_ablation!(CB.repair_ablation_from_env())", s)
    i_ctx   = findfirst("repair_ablation = String(CB.REPAIR_ABLATION[])", s)
    i_inj   = findfirst("injected pre-sim\")", s)
    i_arm   = findfirst("CB.arm_repair_ablation!()   # presim", s)
    i_score = findfirst("println(\"[score] complete=\"", s)
    i_abl   = findfirst("finally\n    print_ablation_line!()      # `[score]` 뒤", s)
    @test all(!isnothing, (i_set, i_ctx, i_inj, i_arm, i_score, i_abl))
    @test first(i_set) < first(i_ctx)
    @test first(i_inj) < first(i_arm)          # 🔴 주입이 끝난 뒤에 무장한다(Review Focus 5)
    @test first(i_score) < first(i_abl)
end

@testset "render_demo: [ablation] 줄은 정확히 한 번 — 시뮬이 던져도(Task 8 M1)" begin
    s = src("tools/monitor/render_demo.jl")
    # 찍는 자리는 가드된 함수 하나뿐이다
    @test length(collect(eachmatch(r"println\(\"\[ablation\] \"", s))) == 1
    i_def  = findfirst("function print_ablation_line!()\n    _ABLATION_LINE_PRINTED[] && return nothing", s)
    i_sim  = findfirst("render_result[] = CB.run_lego_demo(;", s)
    i_fin  = findfirst("render_result[] === nothing && print_ablation_line!()", s)
    i_err  = findfirst("render_result[] === nothing && error(\"render did not return", s)
    i_score = findfirst("println(\"[score] complete=\"", s)
    i_abl  = findfirst("finally\n    print_ablation_line!()      # `[score]` 뒤", s)
    @test all(!isnothing, (i_def, i_sim, i_fin, i_err, i_score, i_abl))
    @test first(i_def) < first(i_sim) < first(i_fin) < first(i_err) < first(i_score) < first(i_abl)
    # 시뮬의 finally 안이다(다음 `end` 전에 있고, `finally` 뒤에 있다)
    blk = s[first(i_sim):first(i_err)]
    @test occursin(r"\nfinally\n[\s\S]*render_result\[\] === nothing && print_ablation_line!\(\)[^\n]*\nend\n", blk)
end

@testset "render_demo: 서비스 레벨 단언은 [run-ctx] 뒤·시뮬 전(m2)" begin
    s = src("tools/monitor/render_demo.jl")
    i_ctx  = findfirst("println(\"[run-ctx] \", JSON3.write(RUN_CTX[]))", s)
    i_asrt = findfirst("router_drives() && assert_service_repair_ablation()", s)
    i_pre  = findfirst("\npre = function (env)", s)
    i_sim  = findfirst("render_result[] = CB.run_lego_demo(;", s)
    @test all(!isnothing, (i_ctx, i_asrt, i_pre, i_sim))
    @test first(i_ctx) < first(i_asrt) < first(i_pre) < first(i_sim)
    # 조건부 없이 최상위 문장이다(줄 머리에서 시작)
    @test occursin("\nrouter_drives() && assert_service_repair_ablation()", s)
    # 지연 주입 경로도 콜백 안에서 주입 뒤에 무장한다
    @test occursin(r"nl = inject_blocking_zone!\(e\)[\s\S]{0,400}CB\.arm_repair_ablation!\(\)   # deferred", s)
end

@testset "policy.jl·dp_lane.jl: 존 진단 4곳이 전부 이름 붙은 면제 안에 있다" begin
    p = src("tools/monitor/policy.jl"); d = src("tools/monitor/dp_lane.jl")
    for site in (":policy_payload", ":reference_label", ":monitor_record")
        @test occursin("CB.ablation_exempt($(site))", p)
    end
    @test occursin("CB.ablation_exempt(:dp_lane)", d)
    # 면제 밖의 맨 zone_diagnosis 호출이 남지 않았다
    for (name, txt) in (("policy.jl", p), ("dp_lane.jl", d))
        for m in eachmatch(r"CB\.zone_diagnosis\(env", txt)
            # thisind: 한글 주석 때문에 바이트 오프셋 -120 이 글자 중간에 떨어질 수 있다(StringIndexError)
            ctx = txt[thisind(txt, max(1, m.offset - 120)):m.offset]
            @test occursin("ablation_exempt", ctx)
        end
    end
    @test occursin("\"REPAIR_ABLATION\"", p)
    @test occursin("\"REPAIR_ABLATION\" => \"none\"", p)
end

@testset "replace_robot: 사다리 존 분기는 ablation 에서 건너뛰고 센다" begin
    r = src("src/respec/replace_robot.jl")
    i_skip = findfirst("if zone_blocked && ablation_blocks_zone_ladder()", r)
    i_fire = findfirst("_ablation_bump!(\"ladder_zone_fired\")", r)
    i_call = findfirst("res = restage_all_blocked!(env)", r)
    @test all(!isnothing, (i_skip, i_fire, i_call))
    @test first(i_skip) < first(i_fire) < first(i_call)
end

@testset "render_demo enact_reform!: ZONE_RESCUE 존 사다리도 ablation 에서 건너뛰고 센다 (2026-09-23 컨트롤러 판정)" begin
    s = src("tools/monitor/render_demo.jl")
    i_fn = findfirst("function enact_reform!(env)", s)
    @test i_fn !== nothing
    body = s[first(i_fn):end]
    body = body[1:first(findfirst(r"\nend\n", body))]          # enact_reform! 본문만
    i_skip = findfirst("CB.ablation_blocks_zone_ladder()", body)
    i_sk   = findfirst("CB._ablation_bump!(\"zone_rescue_skipped\")", body)
    i_fire = findfirst("CB._ablation_bump!(\"ladder_zone_fired\")", body)
    i_call = findfirst("CB.translate_whole_build!(env", body)
    @test all(!isnothing, (i_skip, i_sk, i_fire, i_call))
    @test first(i_skip) < first(i_sk) < first(i_fire) < first(i_call)
    @test occursin("CB._ablation_bump!(\"zone_rescue_fired\")", body)
end
