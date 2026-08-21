# test/smdp_action_name_smoke.jl
# ACTION_NAME 이 레지스트리와 갈리면 라벨 행에 틀린 이름이 찍힌다. 리터럴이 되살아나면
# 이 시험이 죽는다.
#   julia +lts --project=. test/smdp_action_name_smoke.jl
using Test
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
const AR = ActionRegistry

# gen_oracle_dataset.jl 을 통째로 로드하면 씬을 만들기 시작하므로, 상수 정의부만 정규식으로 읽는다.
const SRC = read(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing",
                          "oracle", "gen_oracle_dataset.jl"), String)

@testset "ACTION_NAME 은 레지스트리 파생이다" begin
    # 1) 이름 리터럴이 소스에 남아 있으면 안 된다
    @test !occursin("2=>\"Deprioritize\"", replace(SRC, " " => ""))
    @test !occursin("3=>\"ForbidZone\"",   replace(SRC, " " => ""))
    # 2) 레지스트리가 오늘 뭐라고 하는지 못박는다 (음성 대조의 기준선)
    @test AR.NAME[2] == "RelocateBuild"
    @test AR.NAME[3] == "SwapBattery"
    @test AR.VOCAB  == "v3-4arms"
end
