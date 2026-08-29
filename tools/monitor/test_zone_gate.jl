# tools/monitor/test_zone_gate.jl
# zone 주입 게이트의 전수 검사. 순수 함수라 즉시 끝난다.
#
# 왜 이 게이트가 필요한가 (2026-08-25)
# ------------------------------------
# 2026-08-24 (spec §5.1) 가 zone 을 `case_kinds` 에서 빼면서, run_demo.jl / render_demo.jl 의
# zone 주입 블록이 전부 `if :zone in kinds` 뒤에 갇혔다. `case_kinds` 는 zone 계열 인자를
# **error 로 거부**하므로 그 조건은 **영원히 false** 다 = 주입기 네 개(`inject_blocking_zone!` ·
# `inject_staging_zone!` · `inject_core_zone!` · `inject_declared_zone!`)가 통째로 도달 불가였다.
# zone 을 다시 굴리려면 그 게이트를 **어휘(case_kinds)와 분리된 자기 손잡이**로 옮겨야 한다.
#
# 술어를 파일로 뺀 이유는 lane_select.jl 과 같다: 두 엔진이 각자 리터럴을 들면 그 순간
# 어긋난다(이 레포가 2026-08-16 에 `all` 케이스로 실제로 데인 방식). 진실원은 하나여야 한다.
#
# 실행: julia +lts --project=. tools/monitor/test_zone_gate.jl
using Test
include(joinpath(@__DIR__, "zone_gate.jl"))

@testset "DEMO_ZONE 손잡이" begin
    # 기본값(꺼짐) = 2026-08-24 이후의 현재 동작 그대로. 아무것도 안 심는다.
    @test zone_requested("0", "") == false
    @test zone_requested("", "")  == false
    # 명시적으로 켠다.
    @test zone_requested("1", "") == true
end

@testset "DEMO_ZONE_AT 은 스스로 zone 을 켠다" begin
    # 좌표를 선언해 놓고 DEMO_ZONE 을 안 켠 판이 **조용히 zone 없이** 도는 것을 막는다.
    # 이 레포에서 가장 비싼 실패 모양이 정확히 그것이다(손잡이는 줬는데 아무 데도 안 닿는다).
    @test zone_requested("0", "1.0,2.0,0.5") == true
    @test zone_requested("",  "1.0,2.0,0.5") == true
    # 공백만 있는 값은 선언이 아니다.
    @test zone_requested("0", "   ") == false
end

@testset "case_kinds 와 독립이다" begin
    # 이 술어는 kinds 를 인자로 받지 않는다 — 그것이 이 파일의 존재 이유다.
    # (인자로 받는 순간 zone 이 다시 어휘에 묶이고, 2026-08-24 의 도달불가 상태가 재현된다.)
    @test hasmethod(zone_requested, (String, String))
    @test hasmethod(zone_requested, ())
    @test !hasmethod(zone_requested, (String, String, Vector{Symbol}))
    @test !hasmethod(zone_requested, (Vector{Symbol},))
end
