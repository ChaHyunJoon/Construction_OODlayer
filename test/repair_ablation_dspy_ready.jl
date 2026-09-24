# =============================================================================
# test/repair_ablation_dspy_ready.jl — dspy_ready() 는 `/health` 본문을 한 번만 읽는다
# (2026-09-23, zone-repair-base-ablation Task 12 버그 수정)
#
#   julia +lts --project=. test/repair_ablation_dspy_ready.jl
#
# 버그: `tools/monitor/policy.jl` 의 `dspy_ready()` 가 `/health` 응답 본문을
# `JSON3.read(String(r.body))` 로 **두 번** 읽었다 — 한 번은 `SURRO_KINDS[]`, 한 번은
# (Task 8 이 새로 얹은) `SERVICE_REPAIR_ABLATION[]`. `String(::Vector{UInt8})` 는 Base 계약상
# 바이트 벡터의 소유권을 가져가 **벡터를 비운다** — 그래서 두 번째 `String(r.body)` 는 빈
# 벡터를 받고, `JSON3.read("")` 가 던지고, 바깥의 맨 `catch`(경고도 없이)가
# `SERVICE_REPAIR_ABLATION[] = nothing` 으로 떨어뜨린다. 귀결: `assert_service_repair_ablation()`
# 이 서비스와 줄리아의 레벨이 실제로 같아도 **모든 라우터 런에서** 죽는다
# ("service repair_ablation=nothing != julia ...").
#
# 이 파일은 `test/service_decide_ships_agents.jl` / `test/run_ctx_and_record_id.jl` 과 같은
# 패턴을 쓴다: policy.jl 을 include 하기 전에 루프백에 진짜 `/health` 서버를 띄우고
# `ENV["DSPY_URL"]` 을 그 포트로 돌린다(해적질 없음, 진짜 HTTP 왕복).
#
# RED (수정 전): (1) 이 `SERVICE_REPAIR_ABLATION[] == "all"` 에서 `nothing == "all"` 로 실패한다.
# =============================================================================
module RepairAblationDspyReady

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3

const REPO = normpath(joinpath(@__DIR__, ".."))

# ---- 가짜 /health: surro_kinds 와 repair_ablation 을 한 응답에 같이 싣는다 -------------------
const _SERVER = HTTP.serve!(HTTP.Sockets.localhost, 0; listenany = true, verbose = -1) do req
    if req.target == "/health"
        return HTTP.Response(200,
            "{\"status\":\"ok\",\"surro_kinds\":[\"battery\",\"fault\"],\"repair_ablation\":\"all\"}")
    end
    return HTTP.Response(404, "")
end
const _PORT = HTTP.Servers.port(_SERVER)

# policy.jl 은 이 모듈 안으로 include 된다 — `dspy_ready`·`SERVICE_REPAIR_ABLATION`·`SURRO_KINDS`
# ·`assert_service_repair_ablation` 은 이 모듈 안에서만 정의된다. `const DSPY_URL` 은 include
# 시점에 한 번 ENV 에서 읽히므로, 그 순간에만 ENV 를 우리 포트로 돌려놓고 곧바로 되돌린다.
const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:$(_PORT)"
try
    include(joinpath(REPO, "tools", "monitor", "policy.jl"))
catch
    close(_SERVER)
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)
    rethrow()
end
_PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)

try
    @testset "(1) dspy_ready(): 본문을 한 번만 읽어 surro_kinds 와 repair_ablation 둘 다 산다" begin
        @test dspy_ready() === true
        @test SERVICE_REPAIR_ABLATION[] == "all"
        @test surro_kinds() == Set(["battery", "fault"])
    end

    @testset "(2) assert_service_repair_ablation(): 레벨이 같으면 통과, 다르면 던진다" begin
        try
            CB.set_repair_ablation!(:all)
            @test assert_service_repair_ablation() === nothing
            CB.set_repair_ablation!(:none)
            @test_throws ErrorException assert_service_repair_ablation()
        finally
            CB.set_repair_ablation!(:none)
        end
    end
finally
    close(_SERVER)
    DSPY_HEALTHY[] = nothing
    SURRO_KINDS[] = nothing
    SERVICE_REPAIR_ABLATION[] = nothing
end

end # module
