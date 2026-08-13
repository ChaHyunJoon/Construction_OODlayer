# ============================================================================
#  greedy 배정 회귀 게이트 (spec §9 "greedy 회귀 검사", 계획 태스크 2)
#
#  assign_collaborative_tasks! 는 이 저장소의 모든 숫자가 올라앉은 핵심 스케줄링 함수다.
#  비용 클로저를 greedy_cost 디스패치로 바꾸는 변경이 배정을 **한 엣지도** 바꾸지 않았음을
#  기계적으로 증명한다.
#
#  왜 시뮬레이션이 아니라 배정만 보는가:
#    이 하니스의 시뮬레이션은 런간 재현성이 없다(makespan 노이즈 ~4.6%, spec §4.2).
#    반면 **배정 단계는 결정적이다** — run_lego_demo(return_env_before_sim=true) 는
#    고정 rng 로 스케줄을 세우고 거기서 멈춘다. 그러므로 게이트는 시뮬 결과가 아니라
#    배정 그래프 자체에 건다.
#
#  사용법:
#    골든 생성:  GREEDY_GOLDEN_WRITE=1 julia +lts --project=. test/greedy_assignment_regression.jl
#    검사:       julia +lts --project=. test/greedy_assignment_regression.jl
# ============================================================================

using ConstructionBots
using Test
using Random
using Graphs
using SHA
const CB = ConstructionBots

const GOLDEN_PATH = joinpath(@__DIR__, "greedy_assignment_golden.txt")
const SEED = 3
const NROB = 12

"고정 시드로 env 를 배정 직후 상태까지만 세운다(시뮬 안 함)."
function build_env()
    model = get(ENV, "GREEDY_REG_MODEL", "tractor.mpd")
    return CB.run_lego_demo(; ldraw_file = model, project_name = "greedy_reg",
        num_robots = NROB, assignment_mode = :greedy,
        save_animation = false, write_results = false, overwrite_results = true,
        return_env_before_sim = true, rng = Random.MersenneTwister(SEED))
end

"""
배정 결과의 정규 지문. 두 성분을 담는다:
  (1) 스케줄 그래프의 모든 엣지 (정렬) — 어떤 로봇이 어떤 일감에 붙었는가
  (2) 모든 정점의 tF (6자리 반올림) — 언제 끝나는가
비용식이 조금이라도 달라지면 argmin 이 갈리고 둘 중 하나가 반드시 바뀐다.
"""
function assignment_fingerprint(env)
    sched = env.sched
    io = IOBuffer()
    for e in sort(collect(Graphs.edges(sched.graph)), by = x -> (Graphs.src(x), Graphs.dst(x)))
        println(io, Graphs.src(e), "->", Graphs.dst(e))
    end
    println(io, "--tF--")
    for v in 1:Graphs.nv(sched)
        println(io, v, "=", round(CB.get_tF(sched, v), digits = 6))
    end
    body = String(take!(io))
    return bytes2hex(SHA.sha256(body)), body
end

env = build_env()
digest, body = assignment_fingerprint(env)

if get(ENV, "GREEDY_GOLDEN_WRITE", "0") == "1"
    open(GOLDEN_PATH, "w") do io
        println(io, digest)
        print(io, body)
    end
    println("[greedy-reg] GOLDEN WRITTEN: $digest -> $GOLDEN_PATH")
    println("[greedy-reg] edges+tF lines = ", count(==('\n'), body))
else
    @testset "greedy 배정 회귀 (디스패치 배선이 배정을 바꾸지 않는다)" begin
        @test isfile(GOLDEN_PATH)
        golden_lines = readlines(GOLDEN_PATH)
        golden_digest = first(golden_lines)
        if digest != golden_digest
            # 어디가 갈렸는지 알려준다 — 해시만 다르다고 하면 디버깅이 불가능하다.
            golden_body = join(golden_lines[2:end], "\n") * "\n"
            gl = split(golden_body, '\n'); nl = split(body, '\n')
            for i in 1:min(length(gl), length(nl))
                gl[i] == nl[i] || (println("[greedy-reg] 첫 불일치 line $i: golden=$(gl[i]) new=$(nl[i])"); break)
            end
            println("[greedy-reg] golden lines=$(length(gl)) new lines=$(length(nl))")
        end
        @test digest == golden_digest
    end
end
