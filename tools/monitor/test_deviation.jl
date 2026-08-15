# tools/monitor/test_deviation.jl
# =============================================================================
# 결정 카운터와 deviation 게이트의 순수 로직 검사.
# 시뮬레이터를 띄우지 않는다 — policy.jl 의 판정 함수만 부른다.
#
# 규약은 tools/test_policy_escalation.jl 을 따른다: policy.jl 에는 module 이 없으므로
# `module TestX` 로 감싸고, policy.jl 이 필요로 하는 import(HTTP, JSON3) 를 먼저 한 뒤
# `include` 하고, bare 이름으로 호출한다.
#
# 실행:  julia +lts --project=. tools/monitor/test_deviation.jl
# =============================================================================
module TestDeviation

using Test
import HTTP, JSON3
include(joinpath(@__DIR__, "policy.jl"))

@testset "should_deviate" begin
    # (deviate_at, deviate_arm, 현재 결정 인덱스) -> 갈아쓸 이름 또는 nothing
    @test should_deviate(3, "Replace", 3) == "Replace"   # 그 결정에서만
    @test should_deviate(3, "Replace", 2) === nothing     # 이전 결정은 기준 정책
    @test should_deviate(3, "Replace", 4) === nothing     # 이후 결정도 기준 정책
    @test should_deviate(0, "Replace", 1) === nothing     # OFF (at<=0)
    @test should_deviate(3, "",        3) === nothing     # 팔 이름이 비면 OFF
end

@testset "decision counter" begin
    _reset_decision_counter!()
    @test _next_decision_index!() == 1
    @test _next_decision_index!() == 2
    @test _next_decision_index!() == 3
    _reset_decision_counter!()
    @test _next_decision_index!() == 1
end

# ---------------------------------------------------------------------------------------------
# DS_DEVIATE_AT 오타 → error() (2026-08-17 리뷰 라운드 2, fix #3)
#
# `DEVIATE_AT`/`DEVIATE_ARM` 은 policy.jl 최상위의 **const** 라 이미 이 프로세스에 한 번
# include 된 뒤에는 값이 고정된다 — 같은 프로세스에서 다른 ENV 로 재-include 해도 재정의
# 경고만 나고 상수는 안 바뀐다. 그래서 이 게이트만은 **서브프로세스**로 검사한다(리뷰어 권고:
# withenv + 서브프로세스 include 가 싸다). "빈 문자열/미설정 = OFF, 그 외 파싱 실패·<=0 = error"
# 라는 계약이 실제로 지켜지는지, 오타가 조용히 OFF 로 새지 않는지를 이 한 지점만 확인한다.
# ---------------------------------------------------------------------------------------------
@testset "DS_DEVIATE_AT 오타 → error() (서브프로세스)" begin
    project_root = joinpath(@__DIR__, "..", "..")
    policy_path = joinpath(@__DIR__, "policy.jl")
    script = "import HTTP, JSON3; include(raw\"$(policy_path)\")"

    # stderr 를 잡아서 **문구**까지 본다 — exit != 0 만 보면 다른 원인의 startup 실패(예:
    # 패키지 로드 실패)와 구분이 안 된다(재리뷰 지적). 메시지가 실제로 DS_DEVIATE_AT 을
    # 가리키는지까지 확인해야 "그 error() 가 발화했다"는 증거가 된다.
    function _run_capture(cmd)
        io = IOBuffer()
        ok = try
            run(pipeline(cmd; stdout = devnull, stderr = io)); true
        catch
            false
        end
        return ok, String(take!(io))
    end

    cmd_bad = addenv(`julia +lts --project=$(project_root) -e $script`,
                      "DS_DEVIATE_AT" => "not-a-number")
    ok_bad, err_bad = _run_capture(cmd_bad)
    @test !ok_bad                                    # 파싱 실패 → error() → exit != 0
    @test occursin("DS_DEVIATE_AT", err_bad) && occursin("not-a-number", err_bad)

    cmd_zero = addenv(`julia +lts --project=$(project_root) -e $script`,
                       "DS_DEVIATE_AT" => "0")
    ok_zero, err_zero = _run_capture(cmd_zero)
    @test !ok_zero          # 0 도 켜짐과 꺼짐 사이 회색지대가 아니라 error
    @test occursin("DS_DEVIATE_AT", err_zero)

    cmd_arm_only = addenv(`julia +lts --project=$(project_root) -e $script`,
                           "DS_DEVIATE_ARM" => "Replace")
    ok_arm_only, err_arm_only = _run_capture(cmd_arm_only)
    @test !ok_arm_only      # ARM 만 있고 AT 없음 → 항상 설정 실수
    @test occursin("DS_DEVIATE_ARM", err_arm_only) && occursin("DS_DEVIATE_AT", err_arm_only)

    cmd_off = addenv(`julia +lts --project=$(project_root) -e $script`,
                      "DS_DEVIATE_AT" => "", "DS_DEVIATE_ARM" => "")
    ok_off, _ = _run_capture(cmd_off)
    @test ok_off             # 미설정/빈 문자열은 정상 OFF — 안 죽어야 한다
end

end # module
