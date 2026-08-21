# test/smdp_action_name_smoke.jl
# `ACTION_NAME`/`MACRO_COST` 가 레지스트리와 갈리면 라벨 행에 틀린 이름·틀린 비용이 찍힌다.
# 리터럴이 되살아나면 이 시험이 죽는다.
#   julia +lts --project=. test/smdp_action_name_smoke.jl
#
# 🔴 **이 파일은 오늘의 어휘를 못박지 않는다** (2026-08-20 최종 리뷰 C1/I5).
# 초판은 `AR.NAME[2] == "RelocateBuild"` · `AR.VOCAB == "v3-4arms"` 를 단언했는데, 그 값들은
# **커밋되지 않은 작업트리 마이그레이션**에서만 참이었다 — 깨끗한 체크아웃에서는 커밋된
# 레지스트리가 `v2-6arms`(2=Deprioritize · 3=ForbidZone) 라 이 파일이 그대로 빨개진다.
# 어휘 자체는 이 브랜치의 소유가 아니므로 여기서 게이트하지 않는다(어휘 도장 검사는
# `wm4spacecraft_manufacturing/smdp/test_stamps.py` 의 몫이다). 여기서 못박는 것은 태스크 1 이
# 실제로 바꾼 것, 즉 **파생**이다 — 그 성질은 어느 레지스트리에서도 참이다.
#
# 그리고 초판의 "리터럴이 없다" 검사는 소스 텍스트 `occursin` 이었다. 그것은 (a) `MACRO_COST`
# 를 아예 못 보고 (b) 공백 하나만 바꿔도 통과한다. 여기서는 상수를 **실제로 평가해서** 값이
# 레지스트리와 같은지 본다. `gen_oracle_dataset.jl` 을 통째로 include 하면 씬을 만들기
# 시작하므로, 파일을 **파싱만** 해서 문제의 두 `const` 정의만 뽑아 eval 한다(파싱은 실행이 아니다).
using Test
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
const AR = ActionRegistry

const GEN_SRC = read(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing",
                              "oracle", "gen_oracle_dataset.jl"), String)

"파일 전체를 파싱해 `const <name> = ...` 토플레벨 정의 하나를 Expr 로 돌려준다(없으면 nothing)."
function const_def(src::AbstractString, name::Symbol)
    for ex in Meta.parseall(src).args
        ex isa Expr && ex.head === :const || continue
        a = ex.args[1]
        a isa Expr && a.head === :(=) && a.args[1] === name && return ex
    end
    return nothing
end

@testset "ACTION_NAME·MACRO_COST 는 레지스트리 파생이다" begin
    for (name, registry_table) in ((:ACTION_NAME, AR.NAME), (:MACRO_COST, AR.COST))
        ex = const_def(GEN_SRC, name)
        @test ex !== nothing
        ex === nothing && continue

        # (1) 정의가 **레지스트리를 훑는다**. `string(Expr)` 은 정규화된 형태라 공백·줄바꿈
        #     재배치로는 통과할 수 없다(구판의 소스 텍스트 grep 이 못 하던 것).
        rendered = string(ex)
        @test occursin("ActionRegistry.IDS", rendered)

        # (2) 그리고 **값이 실제로** 레지스트리 표와 같다. 리터럴을 되살리면 — 오늘의 값과
        #     우연히 같은 리터럴이 아닌 한 — 여기서 죽는다. 어휘가 재번호돼도 이 단언은 참이다.
        Core.eval(@__MODULE__, ex)
        @test getfield(@__MODULE__, name) == Dict(i => registry_table[i] for i in AR.IDS)
    end

    # 두 표가 같은 id 집합을 덮는다 — 한쪽만 파생으로 바꾸면(2026-08-20 이 브랜치가 낸 실제
    # 결함) 이름은 새 어휘, 비용은 옛 어휘가 되어 같은 라벨 행이 두 세계를 가리킨다.
    @test keys(ACTION_NAME) == keys(MACRO_COST)
    @test Set(keys(ACTION_NAME)) == Set(AR.IDS)
end
