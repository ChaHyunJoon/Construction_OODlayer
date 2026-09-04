# =============================================================================
# 합성 body 의 집행. (2026-08-30, T3 / spec §5, §9-2)
#
# 🔴 2026-09-03 (Task 10) — 이 파일은 **집행 기계**를 재지 알파벳을 재지 않는다.
#   알파벳(고정 19-원시 레지스트리 파일)은 이 계획이 지웠고 표는 런 스코프가 됐다. 그래서
#   이 파일이 쓰는 원시 이름들은 `test/minted_seed_fixture.jl` 이 **손으로 씨 뿌린다** —
#   그 이름들이 집행부의 생산 표 다섯(`SILENT_SUCCESS_STATUSES` 등)의 키이고, 씨를 안 뿌리면
#   그 표를 재는 절이 전부 "unknown primitive" 로 죽어 **한 번도 안 태워진다.**
#
# 🔴 2026-09-03 fix round 2 (F10) — **이 머리말은 한 라운드 동안 거짓이었다.** fix round 1 의
#   판이 "(9)(9b)(12) 세 명제는 은퇴했다 / 나머지 열둘" 이라고 적어 놨는데, 바로 그 라운드가
#   (9) 와 (12) 를 **되살렸다**(각각 `:334`·`:300` 에 살아 있다). 은퇴한 것은 **(9b) 하나**다.
#   ⚠️ 이것은 F1 이 잡은 결함과 **같은 종류**다(색인이 커버리지에 대해 거짓을 말한다) —
#   F1 을 고치면서 그 자리에서 다시 냈다. 이 파일이 무엇을 덮는지 판단하는 다음 사람은
#   testset 목록이 아니라 **이 머리말**을 읽는다. 명제를 더하거나 빼면 여기도 같이 고칠 것.
#
# 재는 명제 열아홉 — (1)~(19). 은퇴한 것은 **(9b)** 하나뿐이다.
#   (1) 🔴 게이트는 자기신고가 아니라 **body** 를 심사한다 — 이름이 전부 해석되고 전부
#       집행가능하고 인자가 전부 바인딩되면 굴린다. 미끼는 `impl_name` 이고(2026-09-03,
#       Task 9), 그것이 없으면 "못 쟀다" = `:deferred` 다. `reach` 자기신고는 판정에
#       **안 들어간다**(경계 키에서도 빠졌다) — 옛 `:admit_unsanctioned` 구분과 함께 사라졌다.
#   (2) body 에 미지 원시가 하나라도 있으면 **아무것도 집행하지 않고** `:reject` 다.
#       부분 집행은 undo 가 없는 이 설계에서 최악이다.
#   (3) 빈 body 는 `:admit` 이 아니다.
#   (4) `undo` 는 언제나 `:none` 이다. C 단계가 없다는 사실을 결과가 들고 다닌다.
#   (5) `env` 를 요구하는 원시에 `env` 가 없으면 거절이다.
#   (6) `env` 가 있으면 위치인자로 들어간다.
#   (7) 여러 원시가 하나의 params dict 을 나눠 갖는다 — 원시 단위 off-schema 거절 금지.
#   (8) 그러나 **아무 원시도 모르는** 인자는 body 전체를 본 뒤 거절된다(조용히 안 버린다).
#   (9) 🔴 집행 가능성은 `harness_args ⊆ {"env"}` 가 **아니다**(연언지 셋). 못 부르는 원시는
#       **부르기 전에**, 어느 연언지가 깨졌는지(`:harness`·`:arity`·`:kwargs`·`:multimethod`)와
#       함께 `reject:unenactable:<이름>:<사유>` 로 거절된다 — "모르는 이름" 과 **다른 사유**다.
#       ⚠️ 파일 위치가 (12) **뒤**다(`:334`) — 픽스처 검사기를 먼저 태우기 위해서다.
#  (9b) 🔴 **은퇴했다**(이 파일에서 유일하게 은퇴한 명제). "레지스트리의 `enactable` 도장이
#       Julia 의 계산과 일치한다" 를 쟀는데 그 도장을 나르던 JSON 도, 그것을 렌더할 파이썬
#       인벤토리도 없다(D5). 근거는 (9) 자리의 주석에 있다.
#  (10) 🔴 `zone_keys` 는 유도하지 않는다. 안 주면 키워드를 빼고, 주면 `Symbol` 로 강제해
#       살아 있는 존인지 **호출 전에** 검사한다.
#  (11) 🔴 "불렀는데 아무 일도 없었다" · "부르지 않았다" · "못 쟀다"는 서로 다른 사건이다 —
#       `applied`(노린 적응) · `partial`(던졌다) · `world_maybe_dirty`(둘 중 하나) 가 verdict 와
#       별개로 그것을 나른다. 표는 **집행 가능한 여덟 전부**를 덮어야 한다.
#       🔴 한 발도 안 굴린 판(`:deferred`/`:reject`)의 `applied` 는 `false` 가 아니라
#       **`nothing`("못 쟀다")** 이다 — `_r` 의 기본값이 그 삼상을 나른다(C1, Task 9 F6-4).
#  (12) 🔴 **픽스처**의 이름→impl 짝과 params 키를 못 박는다(`check_minted_fixture`).
#       옛 판은 삭제된 레지스트리 JSON 을 쟀고, 오늘은 세 시험 파일이 공유하는 씨뿌리기
#       표를 잰다 — 그 표의 한 행이 조용히 바뀌면 **세 파일이 동시에 초록**이 되기 때문이다.
#       음성 대조 셋(impl 교체 · params 키 추가 · 이름 삭제)이 검사기의 하중을 확인한다.
#  (13)~(19) 재개·타입·invariant·보관소·status·calls 배선·교차언어 왕복.
#
# 변이시험 — 열하나 전부 실제로 빨갛게 만든 뒤 되돌렸다. 재현 방법(`src/respec/minted_tool.jl`):
#   · (1): 🔴 이 변이는 **은퇴했다** — `sanctioned`/`:admit_unsanctioned` 가 없어졌다
#          (Task 9). 오늘 (1) 을 잡는 변이는 `nm === nothing && return _r(:deferred, …)` 를
#          지우는 것이다 → `r3.verdict === :deferred` 가 빨개진다.
#   · (2): `enact_minted!` 의 해석 루프에서 `p === nothing && return _r(:reject, ...)` 를
#          `p === nothing && continue` 로 바꾼다.
#   · (3): `isempty(names) && return _r(:reject, "empty body: ...")` 의 `:reject` 를 `:admit` 로.
#   · (4): `_r` 안의 `undo = :none` 을 `undo = :maybe` 로.
#   · (5): `bind_primitive_args` 의 `ctx.env === nothing && return "reject:missing_harness_arg:env"`
#          줄을 지운다.
#   · (6): 같은 함수의 `push!(pos, ctx.env)` 를 `push!(pos, nothing)` 으로.
#   · (7): 같은 함수의 kw 선별 루프를 원시 단위 off-schema 거절로 되돌린다
#          (`haskey(prim.params, String(k)) || return "reject:off_schema:$(k)"`).
#   · (8): `enact_minted!` 의 `let known = ...` 블록 전체를 지운다.
#   · (9): 🔴 명제 (9) 는 은퇴했지만 이 변이는 **살아 있다** — `_enactability` 의 본문을
#          `return (true, :ok)` 로 바꾸면 (1) 의 `swap_battery` 거절 단언이 빨개진다.
#   ·(10): `bind_primitive_args` 의 `haskey(live, k) || return "reject:unknown_zone_key:..."`
#          줄을 지운다.
#   ·(11): 집행 루프의 `applied |= _step_applied(...)` 를 `applied = true` 로.
#   ·(11b): `SILENT_SUCCESS_STATUSES` 에서 `"force_advance_stuck_carrier"` 행을 지운다
#           (= 리뷰 전의 결함 상태. 커버리지 단언과 :disabled 단언이 빨개진다).
#   ·(11c): `_step_status` 의 `COUNT_RETURN_PRIMITIVES` 갈래를 지운다(맨 Int 를 못 읽는다).
#   ·(11d): `_step_applied` 의 `status in UNMEASURABLE_STATUSES ? false :` 를 지운다
#           (= 못 잰 것이 다시 성공으로 샌다).
#   ·(11e): `_step_status` 의 `try`/`catch` 를 지운다(Hostile 반환이 예외로 새어 나간다).
#   ·(11f): `_r` 의 `world_maybe_dirty = applied || partial` 를 `= applied` 로
#           (던진 경우가 깨끗한 세계로 보고된다).
#   ·(12a)(12b): 🔴 은퇴했다 — 둘 다 **레지스트리 JSON 을 편집하는** 변이였고 그 파일이 없다.
#          오늘 이름→impl 짝은 `register_minted_primitive!` 가 구성상 고정한다.
#   ·(13a): `PRIMITIVE_RESUMES_CACHE["recover_stalled_teams"]` 를 `true` 로
#           (= 리뷰가 잡은 CRITICAL 의 상태 — 재개가 조용히 안 나간다).
#   ·(13b): `enact_minted!` 의 루프 뒤 재개 블록을 통째로 지운다.
#   ·(13c): `WORLD_UNCHANGED_STATUSES` 를 `SILENT_SUCCESS_STATUSES` 의 별칭으로 되돌린다
#           (= 옮겨진 빌드가 world_maybe_dirty=false 로 보고되는 IMPORTANT 결함).
#   ·(F1): `test/minted_seed_fixture.jl` 의 `seed_minted_fixture!` 호출을 지운다 → 표가 비어
#          이 파일의 거의 모든 절이 "unknown primitive" 로 빨개진다(픽스처가 하중을 진다).
#   ·(13d): `_step_touched_world` 의 `UNMEASURABLE_STATUSES ? true :` 를 `false` 로.
#   ·(13e): 던진 경로의 `_issue_resume!` 호출을 지운다.
#   ·(14a): `bind_primitive_args` 의 `_param_type_reject` 호출을 지운다(= 최종 리뷰 이전 상태 —
#           타입 틀린 param 이 호출 경계에서 던지고 그 예외가 `partial=true` 로 기록된다).
#   ·(14b): `PARAM_JSON_TYPES["boolean"]` 을 `Any` 로(= `"true"` 문자열이 통과한다).
#   ·(14c): `_param_type_reject` 의 `t === nothing && return "no_declared_type"` 을
#           `t === nothing && return nothing` 으로(= 선언 없는 param 이 조용히 통과한다).
#
# 🔴 이 게이트는 서비스도 MILP 도 안 쓴다. (11) 이 부르는 유일한 실제 원시는
#    `translate_whole_build!` 이고, 그 함수는 `isempty(env.staging_circles)` 첫 줄에서
#    `:no_staging` 으로 돌아선다 — 세계도 솔버도 필요 없다.
#
# 🔴 `test/runtests.jl` 은 모든 시험 파일을 **같은 `Main` 스코프**에 include 한다 — 그래서
#    이 파일도 자기 `module` 로 감싼다(이 계획의 앞 태스크가 실제로 밟은 버그).
#
# 🔴 navigator 계층 guard 는 `test/minted_tool_resolves.jl`(T2) 과 같은 관용구다.
# =============================================================================
module MintedToolEnacts

using Test
using ConstructionBots
using Graphs
import JSON3          # (19) 교차언어 절이 파이썬 출력을 실제 응답과 같은 타입으로 읽는다
const CB = ConstructionBots

isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

# 🔴 2026-09-03 (Task 10). 원시 표는 이제 **런 스코프**이고 기본이 비어 있다(Task 2). 이 파일이
#    재는 것은 알파벳이 아니라 **집행 기계**(인자 바인딩·타입 검사·삼상·재개·calls 배선)이고,
#    그 기계는 손으로 쓴 원시들로 색인된 생산 표 다섯을 통과해야 태워진다. 그래서 픽스처가
#    직접 씨를 뿌린다 — 근거와 `register_minted_primitive!` 를 안 쓰는 이유는 그 파일에 있다.
include(joinpath(@__DIR__, "minted_seed_fixture.jl"))
seed_minted_fixture!()
check_minted_fixture()   # 🔴 F2: 오염된 픽스처로 아래를 돌리지 않는다

# 세계를 안 건드리는 최소 컨텍스트. env 를 요구하는 원시는 (11) 말고는 안 부른다.
# 🔴 `impl_name` 을 함께 싣는다(2026-09-03, Task 9). 집행 게이트의 미끼가 `reach` 에서
#    `impl_name` 으로 옮겨졌고, 경계(`enact_minted_decision!`)는 `impl_name === nothing` **단독**
#    으로 막는다. 픽스처가 그 값을 안 실으면 이 파일의 모든 판이 `:deferred` 로 떨어진다.
#    ⚠️ 일부러 `impl_name` 을 이름에서 **유도**한다 — `minted_tool.jl` 안쪽 게이트가
#    `impl_name === nothing`(단독)이든 `impl_name === nothing && isempty(body_names)`(연언)이든
#    이 픽스처는 양쪽에서 같은 갈래를 태운다. 게이트의 현재 모양에 매이지 않는다.
#    `impl_name = nothing` 을 명시하면 "합성 레인이 값을 안 실었다" 갈래를 겨냥할 수 있다.
_synth(; reach = "composed", names = String[], params = Dict{String,Any}(), calls = nothing,
         impl_name = isempty(names) ? nothing : first(names)) =
    Dict{String,Any}("reach" => reach, "body_names" => names, "impl_name" => impl_name,
                     "tool_name" => "t", "params" => params, "missing_primitive" => nothing,
                     # 🔴 삼상: 기본은 `nothing`("못 쟀다") 이지 `[]`("읽었는데 비었다") 가 아니다.
                     "calls" => calls)

# `getproperty` 가 던지는 반환값. (11) 이 "못 읽는 모양은 예외가 아니라 기록"을 잰다.
struct Hostile end
Base.hasproperty(::Hostile, ::Symbol) = true
Base.getproperty(::Hostile, ::Symbol) = error("이 반환값은 읽을 수 없다")

# 🔴 (16) 용 스텁 스케줄. `payload_reprice_install.jl` 의 `_StubSched` 와 같은 관용구다 —
#    씬·솔버 없이 `_resolve_schedule_agent` 의 순회·필터를 정확히 겨냥한다. 정점마다 소유자
#    id 를 **직접** 준다: 유효 `BotID` · 무효(음수) `BotID` · 로봇이 아닌 id · `nothing` 을
#    한 스케줄에 섞어 두면, 필터 네 갈래가 전부 이 하나의 픽스처에서 돈다.
#    ⚠️ 스텁이 재지 **못하는** 것 하나: 진짜 스케줄이 실제로 이 문자열 형태를 내는가.
#       2026-09-02 에 out-of-band 프로브가 **진짜 env 로 쟀다**(`run_lego_demo`,
#       `tractor.mpd`, `num_robots=10`, `MersenneTwister(1)`, `closed=54`):
#         · 정점 305 중 유효 `BotID` 소유가 122, 서로 다른 문자열은 18 개였고
#           **전부** `"ConstructionBots.BotID{ConstructionBots.DeliveryBot}(k)"` 형태였다.
#         · 그중 하나를 그대로 넣으면 `forbid_heavy_cargo!` 가 `:banned` 를 내고
#           `STANDING_CARGO_BANS[]` 에 `{BotID(1) => 2}` 가 실제로 앉았다.
#         · 음성 대조: 모듈 한정만 벗긴 `"BotID{DeliveryBot}(1)"` 은 `:unknown_agent` 이고
#           보관소 크기가 안 늘었다(1 → 1).
#       기록: `.superpowers/sdd/2026-09-01-cargo-ban/task-7-report.md` §2·§3.
#       🔴 그 디렉터리는 **gitignore** 다 — 클론에는 그 파일이 없다. 그래서 재현에 필요한
#          것(판·형태·왕복·음성 대조)을 위에 통째로 적어 두었다. 파일이 없으면 위가 절차다.
struct _BanSched
    owners::Vector{Any}
end
ConstructionBots.get_graph(s::_BanSched) = Graphs.SimpleDiGraph(length(s.owners))
ConstructionBots._edge_owner_id(s::_BanSched, v) = s.owners[v]

@testset "(1) 게이트는 자기신고가 아니라 body 를 심사한다" begin
    # 🔴 2026-09-03 (Task 10). **이 절은 다시 쓰였다 — 재던 성질은 그대로다.**
    #    Task 9 가 `:admit_unsanctioned` verdict 를 지웠다: 그것은 "agent-3 이 조합에 실패했다고
    #    신고했는데 body 는 있다"(`reach != "composed"`)를 재던 구분인데, **조합 단계 자체가
    #    없어졌다**(D8 — agent-3 은 인벤토리에서 조합하지 않고 구현을 쓴다). 그리고 `reach` 는
    #    `SYNTH_LANE_KEYS` 에서 빠져 경계를 못 넘는다. 그래서 그 verdict 를 기대하던 단언 넷은
    #    **잴 대상이 없어졌다**(a). 살아 있는 성질은 이것이고 아래가 그것을 잰다:
    #      · 게이트는 자기신고가 아니라 **body** 를 본다 — 이름이 전부 해석되고 전부
    #        집행가능하고 인자가 전부 바인딩되면 굴린다.
    #      · 자격 없는 body 는 여전히 세계 무접촉이다((3)(4)(6) 이 그대로 산다).
    #      · 못 쟀다(`impl_name` 도 `body_names` 도 없다) ≠ 아니라고 했다 → `:deferred`.
    fake = (staging_circles = Dict{Symbol,Any}(),)   # :no_staging 으로 첫 줄에서 돌아선다

    # 🔴 `reach` 가 무엇이든 결과가 **바이트 동일**이다 — 자기신고는 이제 판정에 안 들어간다.
    r = CB.enact_minted!(fake, nothing,
                         _synth(reach = "needs_primitive", names = ["translate_whole_build"]))
    r2 = CB.enact_minted!(fake, nothing, _synth(names = ["translate_whole_build"]))
    @test r.verdict === :admit && r2.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :no_staging
    @test [(s.name, s.status) for s in r2.steps] == [(s.name, s.status) for s in r.steps]
    @test r2.applied === r.applied && r2.world_maybe_dirty === r.world_maybe_dirty
    @test r.undo === :none

    # 🔴 못 쟀다 ≠ 아니라고 했다. 합성 레인이 값을 하나도 안 실으면 `:deferred` 다.
    r3 = CB.enact_minted!(fake, nothing, _synth(impl_name = nothing, names = String[]))
    @test r3.verdict === :deferred
    @test isempty(r3.steps)

    # 🔴 자격 없는 body 는 여전히 세계 무접촉이다.
    @test CB.enact_minted!(fake, nothing,
              _synth(names = ["teleport_the_build"])).verdict === :reject   # 알파벳 밖
    @test CB.enact_minted!(fake, nothing,
              _synth(names = ["swap_battery"])).verdict === :reject         # 집행 불가(:arity)
    @test CB.enact_minted!(nothing, nothing,
              _synth(names = ["restage_all_blocked"])).world_maybe_dirty === false

    # 🔴 게이트의 첫 연언지 — 집행 계열 verdict 는 이제 `:admit` **하나**다(T2 가 이 술어를 부른다).
    @test CB.ENACTED_VERDICTS === (:admit,)
    @test CB.minted_handled_verdict_ok(:admit) === true
    @test CB.minted_handled_verdict_ok(:reject) === false
    @test CB.minted_handled_verdict_ok(:deferred) === false
    # 음성 대조: 사라진 verdict 가 되살아나면 여기서 빨개진다.
    @test CB.minted_handled_verdict_ok(:admit_unsanctioned) === false
end

@testset "(2) 미지 원시 하나면 아무것도 안 한다" begin
    r = CB.enact_minted!(nothing, nothing,
                         _synth(names = ["restage_all_blocked", "teleport_the_build"]))
    @test r.verdict === :reject
    # 🔴 2026-09-03 (Task 10). `false`("쟀는데 적응이 없었다") 가 아니라 **`nothing`
    #    ("못 쟀다")** 이다 — 한 발도 안 굴렸으니 잰 것이 없다. `_r` 의 기본값이 그 삼상을
    #    나르고(`applied = nothing`), C1 이 그것을 계약으로 세웠다
    #    (`test/minted_registration.jl` (8)(9)(11)).
    @test r.applied === nothing
    @test occursin("teleport_the_build", r.reason)
    # 🔴 첫 원시가 해석 가능해도 **집행 시도조차 없어야** 한다. undo 가 없으므로
    #    부분 집행은 되돌릴 수 없는 손상이다.
    @test isempty(r.steps)
end

@testset "(3) 빈 body 는 admit 이 아니다" begin
    # 🔴 2026-09-03 (Task 10). 게이트가 `impl_name` 으로 옮겨졌으므로(Task 9) "빈 body" 를
    #    겨냥하려면 **`impl_name` 은 있고 `body_names` 만 빈** 기록이 필요하다. 그 조합은
    #    라이브에서 실재한다: 파이썬은 `body_names = [impl_name] if impl_name else []` 로
    #    채우지만 경계를 넘는 것은 dict 이고, 둘 중 하나만 실린 찢어진 기록이 오면 여기가
    #    막는 자리다. `impl_name` 도 없는 판은 (1) 이 `:deferred` 로 따로 잰다 — 못 쟀다와
    #    빈 body 는 다른 사건이다.
    r = CB.enact_minted!(nothing, nothing, _synth(names = String[], impl_name = "ghost!"))
    @test r.verdict === :reject
    @test r.applied === nothing          # 한 발도 안 굴렸다 = 못 쟀다(삼상)
    @test occursin("empty", r.reason)
end

@testset "(4) undo 는 언제나 none 이다" begin
    for s in (_synth(reach = "needs_primitive"), _synth(names = ["nope"]), _synth())
        @test CB.enact_minted!(nothing, nothing, s).undo === :none
    end
end

@testset "(5) 인자 바인딩 — env 를 요구하는 원시에 env 가 없으면 거절이다" begin
    p = CB.resolve_primitive("restage_all_blocked")
    got = CB.bind_primitive_args(p, (env = nothing, truth = nothing, params = Dict{String,Any}()))
    @test got isa String                    # 거절 사유
    @test occursin("env", got)
end

@testset "(6) 인자 바인딩 — env 가 있으면 위치인자로 들어간다" begin
    p = CB.resolve_primitive("restage_all_blocked")
    sentinel = Ref(:env_sentinel)
    got = CB.bind_primitive_args(p, (env = sentinel, truth = nothing, params = Dict{String,Any}()))
    @test got isa Tuple
    @test first(got)[1] === sentinel        # positional[1] == env
end

@testset "(7) 여러 원시가 params 를 나눠 갖는다 — 두 번째 원시에서 죽지 않는다" begin
    # 🔴 합성기는 tool 하나에 params dict 하나를 낸다. body 가 둘 이상이면 그 키들은
    #    원시들에 흩어진다. 원시 단위로 off-schema 를 거절하면 정상 body 가 죽는다.
    p = CB.resolve_primitive("restage_all_blocked")     # zone_keys 만 안다
    got = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                                     params = Dict{String,Any}("agent" => "R3")))
    @test got isa Tuple                    # 거절이 아니다 — 모르는 키는 그냥 안 넘긴다
    @test !haskey(NamedTuple(got[2]), :agent)
end

@testset "(8) 아무 원시도 모르는 인자는 body 전체를 본 뒤 거절된다" begin
    r = CB.enact_minted!(nothing, nothing,
                         _synth(names = ["restage_all_blocked"],
                                params = Dict{String,Any}("nonsense_knob" => 1)))
    @test r.verdict === :reject
    @test occursin("nonsense_knob", r.reason)
    @test r.applied === nothing          # 거절은 못 잰 것이지 잰 0 이 아니다
end

# =============================================================================
# (9) 🔴 집행 가능성은 `harness_args ⊆ {"env"}` 가 **아니다** — 연언지 셋이다.
#
# 그 술어 하나만 보면 빈 `harness_args` 가 공짜로 통과한다. 실제로 부를 수 없는 원시를
# 부르면 호출 시점 `MethodError` 가 나고 집행부의 `try` 가 그것을 `:admit`/집행됨으로
# 보고한다 = **거절보다 나쁜 거짓 admit**. 그래서 `_enactability` 는 부르기 **전에** 거절하고
# 어느 연언지가 깨졌는지를 함께 낸다.
#
# 🔴 2026-09-03 (Task 10, fix round 1) — **이 절은 은퇴했다가 되살아났다.**
#   1차에서 "알파벳이 없어졌으니 잴 대상도 없어졌다" 로 판정하고 지웠는데, 그것이 틀렸다:
#   사라진 것은 **개수**(19 중 8)라는 알파벳에 대한 주장뿐이고, `_enactability` 의 판정과
#   `reject:unenactable:` 생산 경로는 그대로다. 그리고 같은 커밋이 더한 씨뿌리기 픽스처가
#   그 판정을 **완전히 측정 가능하게** 만든다 — 표를 `minted_table()` 로 바꾸는 두 줄이면
#   전부 초록이었다. 지운 대가는 `:harness`/`:arity` 사유 코드와 `reject:unenactable:` 경로의
#   커버리지 **0** 이었고, 그 회귀는 (1) 의 맨 `verdict === :reject` 로는 "unknown primitive"
#   와 구별되지 않는다.
#   ⚠️ 1차의 은퇴 주석은 "(14)(15) 가 `compile_constraint` 로 계속 태운다" 고 적었는데
#   **거짓**이었다 — `compile_constraint` 는 그 주석 밖 이 파일 어디에도 없었다.
#
# 🔴 여기서 재는 것은 **오늘의 픽스처 표에 대한 사실**이지 삭제된 알파벳에 대한 사실이 아니다.
#   개수(19/8)는 안 잰다. 재는 것은 (i) 씨 뿌린 표에서 집행 가능한 이름 집합이
#   `ENACTABLE_TODAY` 와 같은가, (ii) 못 부르는 것이 **부르기 전에** 자기 연언지 이름과 함께
#   거절되는가다. (ii) 가 이 절의 본체이고 알파벳과 무관하다.
#
# 🔴 (9b)(레지스트리의 `enactable` 도장이 Julia 의 계산과 일치한다)는 **은퇴한 채로 둔다** —
#   그 도장을 나르던 JSON 이 없고, 파이썬 프롬프트가 렌더할 인벤토리도 없다(D5). 오늘 그
#   자리를 대신 지키는 것은 규약 1(`f(env; kw…)`)이 생성 원시를 구성상 전부 enactable 로
#   만든다는 사실이고, 그 한 줄을 재는 것은 `test/minted_registration.jl` testset **(6)** 이다
#   (규약 위반이 등록 자체에서 거절된다 — 그래서 표에 못 들어온다).
# =============================================================================
const ENACTABLE_TODAY = sort(["forbid_heavy_cargo", "force_advance_stuck_carrier",
                              "recover_stalled_teams",
                              "reform_stuck_teams", "release_pending_assignments",
                              "resolve_schedule_wedge",
                              "restage_all_blocked", "translate_whole_build"])

# 🔴 2026-09-03 (Task 10 fix round 1 / F2). 옛 명제 (12)(레지스트리의 이름→impl 짝과 params
#    키)를 픽스처 자신으로 옮겼다 — 그 표가 세 시험 파일의 공유 진실원이 됐기 때문이다.
#    `check_minted_fixture()` 는 파일 머리에서 이미 한 번 돌았고(오염된 채 아래를 돌지 않게),
#    여기서는 그것이 **하중을 지는지**를 음성 대조로 잰다: 던지지 않는 검사기는 검사기가 아니다.
@testset "(12) 픽스처의 이름→impl 짝과 params 키가 못박혀 있다" begin
    @test check_minted_fixture() === nothing          # 오늘의 표는 통과한다

    # 🔴 음성 대조 셋. 리뷰가 이름 지은 시나리오를 그대로 태운다:
    #    "impl 을 다른 함수로 돌리거나 params 에 키를 더하면 스위트 전부 초록인 채로
    #     부를 수 있는 표면이 넓어진다."
    #
    # 🔴 2026-09-03 fix round 2 (F12) — **맨 `@test_throws Exception` 은 쓰지 않는다.**
    #    이 레포는 정확히 그 약한 형태에 데었다: `tools/monitor/test_minted_wiring.jl` 의 옛
    #    (5)절 `@test_throws Exception CB.PRIMITIVE_TABLE()` 은 심볼이 아예 없어져
    #    `UndefVarError` 가 나는데도 **통과했다**(`UndefVarError <: Exception`) — 재려던 사건
    #    ("레지스트리 파일이 없으면 error 를 낸다")과 실제로 난 사건("그 이름이 없다")이
    #    그 단언에는 같은 관측이었다. 그래서 여기서는 셋 다 (a) 타입을 `ErrorException` 으로
    #    좁히고 (b) **사유 문자열까지** 대조한다. 헬퍼가 그 둘을 한 자리에서 한다.
    _why_of(f) = try
        f()
        "(안 던졌다)"
    catch e
        sprint(showerror, e)
    end
    let saved = copy(CB.minted_table())
        try
            row = copy(CB.minted_table()["resolve_schedule_wedge"])
            row["impl"] = "recover_stalled_teams!"        # 짝을 다른 함수로 돌린다
            CB.minted_table()["resolve_schedule_wedge"] = row
            @test_throws ErrorException check_minted_fixture()
            local why = _why_of(check_minted_fixture)
            @test occursin("이름→impl 짝이 어긋났다", why)     # 의도한 검사가 걸렸다
            @test occursin("resolve_schedule_wedge", why)      # 어느 행인지가 사유에 있다
            @test occursin("recover_stalled_teams!", why)      # 무엇으로 바뀌었는지도
        finally
            CB.minted_table()["resolve_schedule_wedge"] = saved["resolve_schedule_wedge"]
        end
        try
            row = copy(CB.minted_table()["restage_all_blocked"])
            row["params"] = merge(row["params"],
                                  Dict{String,Any}("resume" => Dict{String,Any}("type" => "boolean")))
            CB.minted_table()["restage_all_blocked"] = row
            @test_throws ErrorException check_minted_fixture()   # params 에 키를 더한다
            local why = _why_of(check_minted_fixture)
            @test occursin("params 키가 어긋났다", why)        # 짝 검사가 아니라 키 검사가 걸렸다
            @test occursin("resume", why)                      # 더해진 키가 사유에 있다
        finally
            CB.minted_table()["restage_all_blocked"] = saved["restage_all_blocked"]
        end
        try
            delete!(CB.minted_table(), "pop_spare")          # 이름이 통째로 빠진다
            @test_throws ErrorException check_minted_fixture()
            local why = _why_of(check_minted_fixture)
            @test occursin("이름 집합이", why)                  # 집합 검사가 걸렸다(짝 검사가 아니라)
            @test occursin("pop_spare", why)                    # 어느 이름이 빠졌는지가 사유에 있다
        finally
            CB.minted_table()["pop_spare"] = saved["pop_spare"]
        end
        @test check_minted_fixture() === nothing          # 셋 다 되돌아왔다
    end
end

@testset "(9) 집행 불가는 부르기 전에, 깨진 연언지와 함께 거절된다" begin
    # (i) 씨 뿌린 표에서 실제로 부를 수 있는 이름 집합. 🔴 개수가 아니라 **이름**이다 —
    #     표가 넓어져도 좁아져도 빨개진다.
    got = sort([n for n in keys(CB.minted_table()) if CB.resolve_primitive(n).enactable])
    @test got == ENACTABLE_TODAY
    # 빈-통과 방지: 표가 비면 위 줄은 `[] == ENACTABLE_TODAY` 로 정직하게 빨개지지만,
    #     `ENACTABLE_TODAY` 가 비는 편집에는 침묵한다. 그 길을 막는다.
    @test !isempty(ENACTABLE_TODAY) && length(CB.minted_table()) > length(ENACTABLE_TODAY)

    # (ii) 🔴 본체. 못 부르는 것은 **부르기 전에**, 어느 연언지가 깨졌는지와 함께 거절된다.
    #  · compile_constraint — harness 에 `model`·`t0`·`tF`·`Xa`·`sched` 가 있다. 바인더가
    #       만들 수 있는 것은 `BINDABLE_HARNESS_ARGS` = {env, invariant} 뿐이다  → :harness
    #  · swap_battery       — harness 는 env 하나인데 위치인자가 둘이다        → :arity
    for (nm, why) in (("compile_constraint", :harness), ("swap_battery", :arity))
        p = CB.resolve_primitive(nm)
        @test p !== nothing                    # 전제: 표에 있다(= "모르는 이름" 과 다른 사건이다)
        @test p.enactable === false
        @test p.unenactable_why === why
        r = CB.enact_minted!(Ref(:e), nothing, _synth(names = [nm]))
        @test r.verdict === :reject
        # 🔴 사유가 **자기 이름과 연언지**를 싣는다. 이것이 (1) 의 맨 `:reject` 와 이 절을
        #    가르는 전부다 — 그것 없이는 "집행 불가" 와 "모르는 이름" 이 한 관측이 된다.
        @test occursin("reject:unenactable:$(nm):$(why)", r.reason)
        @test !occursin("unknown primitive", r.reason)
        @test isempty(r.steps)                 # 한 발도 안 나갔다
    end

    # 음성 대조: 같은 경로로 **부를 수 있는** 원시를 보내면 그 거절이 안 난다.
    #    (없으면 위 루프는 "`enact_minted!` 가 늘 거절한다" 로도 통과한다.)
    let ok = CB.enact_minted!((staging_circles = Dict{Symbol,Any}(),), nothing,
                              _synth(names = ["translate_whole_build"]))
        @test ok.verdict === :admit
        @test !occursin("unenactable", ok.reason)
    end

    # 🔴 나머지 두 연언지(`:kwargs`·`:multimethod`)는 오늘 픽스처에 자연 표본이 없다 —
    #    런-스코프 표에 행 둘을 직접 돌려 넣어 잰다(옛 판은 오염된 레지스트리 **파일 사본**을
    #    썼고 그 경로는 삭제됐다).
    let saved = copy(CB.minted_table())
        try
            CB.minted_table()["kw_bad"] = Dict{String,Any}(
                "name" => "kw_bad", "impl" => "recover_stalled_teams!", "surface" => "physical",
                "harness_args" => ["env"],
                "params" => Dict{String,Any}("no_such_kwarg" => Dict{String,Any}("type" => "integer")),
                "reversible" => false)
            CB.minted_table()["mm_bad"] = Dict{String,Any}(
                "name" => "mm_bad", "impl" => "compile_constraint!", "surface" => "milp",
                "harness_args" => String[], "params" => Dict{String,Any}(), "reversible" => false)
            @test CB.resolve_primitive("kw_bad").unenactable_why === :kwargs
            # 🔴 메서드가 여럿이어도 **던지지 않는다** (`compile_constraint!` 는 6개).
            @test CB.resolve_primitive("mm_bad").unenactable_why === :multimethod
            @test occursin("reject:unenactable:kw_bad:kwargs",
                           CB.enact_minted!(Ref(:e), nothing, _synth(names = ["kw_bad"])).reason)
        finally
            delete!(CB.minted_table(), "kw_bad")
            delete!(CB.minted_table(), "mm_bad")
        end
        # 🔴 픽스처가 온전히 돌아왔다 — 표는 프로세스 전역이고 뒤 절·뒤 파일이 물려받는다.
        @test sort(collect(keys(CB.minted_table()))) == sort(collect(keys(saved)))
    end
end

# =============================================================================
# (10) 🔴 `zone_keys` 를 truth 에서 유도하면 안 되는 이유는 실측 셋이다:
#   (a) 서비스가 존 키를 프롬프트에 렌더한다(`dspy_service.py::_zones_block`) — 모델이 준다.
#   (b) `RESTRICTION_ZONES[]` 는 `Dict{Symbol,Ball2}` 이고 소비자는 `haskey` 로 거른다.
#       String 키는 조용히 걸러져 `zones == []` → `translate_whole_build!` 가 Δ=0 ·
#       잔여 0 으로 `:already_clear` 를 낸다 = 맞는 답이 거짓 증거로 둔갑한다.
#   (c) 유도값은 callee 기본값(`collect(keys(RESTRICTION_ZONES[]))`)보다 **좁다**.
# =============================================================================
@testset "(10) zone_keys 는 유도하지 않고, 주면 Symbol 로 강제해 검사한다" begin
    p = CB.resolve_primitive("restage_all_blocked")
    saved = CB.RESTRICTION_ZONES[]
    try
        CB.RESTRICTION_ZONES[] = Dict{Symbol,CB.LazySets.Ball2}(
            :zone_blk_1 => CB.LazySets.Ball2([0.0, 0.0, 0.0], 1.0),
            :zone_blk_2 => CB.LazySets.Ball2([5.0, 0.0, 0.0], 1.0))

        # (c) 안 주면 **키워드를 아예 뺀다** — callee 기본값(살아 있는 존 전부)이 이긴다.
        kw = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                                        params = Dict{String,Any}()))[2]
        @test !haskey(kw, :zone_keys)

        # (b) String 을 주면 Symbol 로 강제된다 — 조용히 걸러지지 않는다.
        kw2 = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("zone_keys" => ["zone_blk_1"])))[2]
        @test kw2.zone_keys == Symbol[:zone_blk_1]

        # 살아 있지 않은 존은 **호출 전에** 거절된다(살아 있는 키까지 사유에 싣는다).
        bad = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("zone_keys" => ["zone_blk_9"])))
        @test bad isa String
        @test occursin("reject:unknown_zone_key:zone_blk_9", bad)
        @test occursin("zone_blk_1,zone_blk_2", bad)

        # 🔴 빈 목록은 기본값으로 폴백하지 않는다 — 폴백하면 "존 전부"가 되어 뜻이 뒤집힌다.
        empt = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("zone_keys" => String[])))
        @test empt == "reject:empty_zone_keys"

        # 그리고 거절은 집행부까지 그대로 올라간다 — 한 발도 안 나간다.
        r = CB.enact_minted!(Ref(:e), nothing,
                _synth(names = ["restage_all_blocked"],
                       params = Dict{String,Any}("zone_keys" => ["zone_blk_9"])))
        @test r.verdict === :reject
        @test r.applied === nothing      # 거절은 못 잰 것이지 잰 0 이 아니다
        @test isempty(r.steps)
    finally
        CB.RESTRICTION_ZONES[] = saved
    end
end

# =============================================================================
# (11) 🔴 "불렀는데 아무 일도 없었다" ≠ "부르지 않았다" ≠ "못 쟀다"(spec §9-2).
#
# 2026-08-30 리뷰가 잡은 결함: 처음 `SILENT_SUCCESS_STATUSES` 를 zone 원시 둘만 채웠더니
# **집행 가능한 여섯 중 넷**이 아무 일도 안 하고 `applied = true` 를 냈다. 그중
# `force_advance_stuck_carrier!` 는 `CARRIER_RESCUE != "1"`(= 손 안 댄 **기본 환경**)이면
# 언제나 `:disabled, moved=0` 이다 — 매 런이 "적응했다"로 결정 행에 남았을 것이다.
# `reform_stuck_teams!` 는 아예 NamedTuple 이 아니라 맨 `Int` 를 돌려준다.
# 그래서 이 절은 이제 **여섯 전부**를 이름으로 잰다.
# =============================================================================
@testset "(11) applied 는 status 로, partial 은 예외로, 못 쟀으면 false 다" begin
    # 🔴 표는 집행 가능한 여섯을 **빠짐없이** 덮어야 한다. 어휘가 늘면(이 계획의 뒤 태스크가
    #    원시를 하나 더한다) 표를 채우기 전까지 여기서 먼저 빨개진다 — `_step_applied` 의
    #    보수적 기본값(참)으로 조용히 새는 길을 막는 것이 이 단언 하나다.
    @test sort(collect(keys(CB.SILENT_SUCCESS_STATUSES))) == ENACTABLE_TODAY

    # 여섯 원시의 실제 return 문에서 읽은 상태들. 왼쪽=조용한 성공(false), 오른쪽=진짜 적응(true).
    quiet = [("restage_all_blocked", :none), ("restage_all_blocked", :infeasible),
             ("restage_all_blocked", :residual_blocked),
             ("translate_whole_build", :no_staging), ("translate_whole_build", :already_clear),
             ("translate_whole_build", :infeasible), ("translate_whole_build", :residual_blocked),
             # 🔴 CARRIER_RESCUE 미설정이 기본값이다 — 이 한 줄이 리뷰가 잡은 결함이다.
             ("force_advance_stuck_carrier", :disabled), ("force_advance_stuck_carrier", :no_carrier),
             ("recover_stalled_teams", :no_team), ("recover_stalled_teams", :stuck),
             # recover 는 carrier 의 결과를 그대로 전달한다 — :disabled 가 여기로도 올라온다.
             ("recover_stalled_teams", :disabled), ("recover_stalled_teams", :no_carrier),
             ("resolve_schedule_wedge", :not_applicable), ("resolve_schedule_wedge", :no_wedge),
             ("reform_stuck_teams", :moved_none),
             # 🔴 2026-09-02 (T7) — `forbid_heavy_cargo` 는 **네 갈래 전부**가 조용한 성공이다.
             #    실제 적응 status 가 하나도 없는 첫 원시다: 이 원시는 `STANDING_CARGO_BANS[]`
             #    에 항목 하나를 쓸 뿐이고, 노린 적응(재풀이가 무거운 화물을 뗀다)은 **다음
             #    formulate** 의 몫이다. `:banned` 를 성공으로 세면 세계가 바이트 동일인데도
             #    `applied=true` 가 되어 폴백이 삼켜진다.
             ("forbid_heavy_cargo", :banned), ("forbid_heavy_cargo", :unknown_agent),
             ("forbid_heavy_cargo", :no_schedule), ("forbid_heavy_cargo", :invalid_n),
             ("forbid_heavy_cargo", :missing_agent),
             ("release_pending_assignments", :both_scopes)]
    for (n, st) in quiet
        @test CB._step_applied(n, st) === false
    end
    real = [("restage_all_blocked", :restaged_all), ("restage_all_blocked", :partial),
            ("translate_whole_build", :translated),
            ("force_advance_stuck_carrier", :carrier_closed),
            ("force_advance_stuck_carrier", :carrier_advanced),
            ("recover_stalled_teams", :snapped), ("recover_stalled_teams", :restaged),
            ("recover_stalled_teams", :unwedged), ("recover_stalled_teams", :force_snapped),
            ("resolve_schedule_wedge", :unwedged), ("reform_stuck_teams", :moved)]
    for (n, st) in real
        @test CB._step_applied(n, st) === true
    end

    # 🔴 "못 쟀다"는 성공이 아니다. 모양을 못 읽었다는 것은 세계가 변했는지 **모른다**는 뜻이다.
    #    이것은 표에 없는 원시의 보수적 기본값(참)보다 **먼저** 판정된다.
    @test CB._step_applied("restage_all_blocked", :unreadable_return) === false
    @test CB._step_applied("primitive_not_in_table", :unreadable_return) === false
    # 표에 없는 원시의 그 밖 상태는 보수적으로 참이다. ⚠️ 위 커버리지 단언 때문에 집행
    # 가능한 여섯에 대해서는 이 기본값에 **도달할 수 없다**.
    @test CB._step_applied("primitive_not_in_table", :whatever) === true

    # 반환 모양 읽기 — 세 갈래.
    @test CB._step_status("translate_whole_build", (status = :translated,)) === :translated
    @test CB._step_status("reform_stuck_teams", 0) === :moved_none   # 맨 Int 를 개수로 읽는다
    @test CB._step_status("reform_stuck_teams", 3) === :moved
    @test CB._step_status("restage_all_blocked", 3) === :unreadable_return  # 개수 원시가 아니다
    @test CB._step_status("whatever", nothing) === :unreadable_return
    @test occursin("unreadable return shape", CB._step_detail(nothing))

    # 🔴 `getproperty` 가 던지는 반환값도 **기록**이지 예외가 아니다. 오늘의 여섯에는 그런
    #    반환이 없지만 이 계획의 뒤 태스크가 어휘에 원시를 하나 더한다.
    @test CB._step_status("whatever", Hostile()) === :unreadable_return
    @test occursin("unreadable return shape", CB._step_detail(Hostile()))

    # 끝에서 끝까지: 불렸고(:admit), 그러나 세계는 안 바뀌었다(applied=false).
    fake = (staging_circles = Dict{Symbol,Any}(),)      # 첫 줄에서 :no_staging 으로 돌아선다
    r = CB.enact_minted!(fake, nothing, _synth(names = ["translate_whole_build"]))
    @test r.verdict === :admit
    @test r.applied === false                          # 🔴 조용한 성공을 성공으로 세지 않는다
    @test r.partial === false
    @test r.world_maybe_dirty === false
    @test length(r.steps) == 1
    @test r.steps[1].status === :no_staging
    @test occursin("적응", r.reason)                    # 사유가 그 사실을 말한다
    @test r.undo === :none

    # 던지면 `partial` 이 참이다 — 세계는 절반만 고쳐졌을 수 있고 되돌릴 방법이 없다.
    r2 = CB.enact_minted!((nope = 1,), nothing, _synth(names = ["translate_whole_build"]))
    @test r2.verdict === :admit
    @test r2.partial === true
    @test r2.applied === false                         # applied 는 status 전용이다(뒤집지 않는다)
    # 🔴 그래서 파생 필드가 따로 있다 — 한 필드만 읽고 다른 것의 답을 얻어 가면 안 된다.
    @test r2.world_maybe_dirty === true
    @test r2.steps[1].status === :threw
    @test occursin("undo 없음", r2.reason)

    # 거절은 세계에 손을 안 댔다.
    @test CB.enact_minted!(nothing, nothing, _synth(names = ["nope"])).world_maybe_dirty === false
end

# =============================================================================
# 🔴 2026-09-03 (Task 10) — **명제 (12) 는 은퇴했다.**
#
# 그것은 "레지스트리의 이름→impl 짝과 params 키를 못 박는다" 였고, 변이 (12a)(12b) 가
# **레지스트리 JSON 을 편집하는** 변이였다. 그 파일이 없다 — 오늘 이름→impl 짝을 정하는 것은
# `register_minted_primitive!` 이고, 그 함수는 `"impl" => String(name)`(함수 자신이 원시다,
# 이름이 둘일 이유가 없다)로 **구성상** 짝을 고정한다. 즉 이 절이 막던 실패 모드(짝을 조용히
# 다른 함수로 돌리기)가 기전 자체로 불가능해졌다. `test/minted_registration.jl` (2)(4) 가
# 그 기전을 잰다.
# =============================================================================
@testset "(13) 스케줄 캐시 재개 · 세계 접촉 표" begin
    # ---- 표 셋의 커버리지 -------------------------------------------------------------
    @test sort(collect(keys(CB.WORLD_UNCHANGED_STATUSES))) == ENACTABLE_TODAY
    @test sort(collect(keys(CB.PRIMITIVE_RESUMES_CACHE)))  == ENACTABLE_TODAY

    # 🔴 불변식: 원시마다 `WORLD_UNCHANGED ⊆ SILENT_SUCCESS`. 세계를 안 건드렸으면 노린
    #    적응도 당연히 안 일어났다. 이 포함이 `applied ⟹ world_maybe_dirty` 를 보장한다 —
    #    즉 T4 의 `handled` 판정이 `applied` 판정보다 **넓기만** 하다(좁아지지 않는다).
    for n in ENACTABLE_TODAY
        @test issubset(CB.WORLD_UNCHANGED_STATUSES[n], CB.SILENT_SUCCESS_STATUSES[n])
    end

    # ---- 두 표가 갈리는 자리를 **값으로** 못박는다 (b) --------------------------------
    # 🔴 이 셋이 결함의 실체다: 조용한 성공이지만 세계는 이미 건드렸다.
    # 🔴 넷째(2026-09-01): `release_pending_assignments` 의 `:released_none`. 앞의 셋과 이유가
    #    다르다 — 앞 셋은 그 status 로 가는 경로가 이미 세계를 편집한 뒤이고, 이쪽은 `faulted`
    #    **params 에 따라** 편집일 수도 아닐 수도 있어 (이름, status) 표가 구별할 수 없다.
    #    표가 못 가르는 곳에서는 보수적인 쪽("건드렸을 수 있다")을 고른다.
    for (n, st) in (("translate_whole_build",       :residual_blocked),
                    ("translate_whole_build",       :already_clear),
                    ("restage_all_blocked",         :residual_blocked),
                    ("release_pending_assignments", :released_none))
        @test CB._step_applied(n, st) === false         # 노린 적응은 아니다
        @test CB._step_touched_world(n, st) === true    # 🔴 그러나 세계는 건드렸다
    end
    # 나머지 조용한 성공은 두 표에서 같다 — 위 셋만 예외라는 것을 전수로 못박는다.
    for n in ENACTABLE_TODAY, st in CB.SILENT_SUCCESS_STATUSES[n]
        expected_touch = (n, st) in (("translate_whole_build",       :residual_blocked),
                                     ("translate_whole_build",       :already_clear),
                                     ("restage_all_blocked",         :residual_blocked),
                                     ("release_pending_assignments", :released_none))
        @test CB._step_touched_world(n, st) === expected_touch
    end

    # 🔴 "못 쟀다"의 답은 두 질문에서 **반대**다. 적응했다고 셀 수는 없지만, 세계가 깨끗하다고
    #    말할 수도 없다.
    @test CB._step_applied("translate_whole_build", :unreadable_return) === false
    @test CB._step_touched_world("translate_whole_build", :unreadable_return) === true
    # 표에 없는 원시도 마찬가지로 보수적이다(양쪽 다 "건드렸다").
    @test CB._step_touched_world("primitive_not_in_table", :whatever) === true

    # ---- 재개 표 (a) — 소스에서 읽은 값 그대로 --------------------------------------
    @test CB.PRIMITIVE_RESUMES_CACHE["restage_all_blocked"]         === true
    @test CB.PRIMITIVE_RESUMES_CACHE["translate_whole_build"]       === true
    @test CB.PRIMITIVE_RESUMES_CACHE["resolve_schedule_wedge"]      === true
    @test CB.PRIMITIVE_RESUMES_CACHE["reform_stuck_teams"]          === false
    @test CB.PRIMITIVE_RESUMES_CACHE["recover_stalled_teams"]       === false
    @test CB.PRIMITIVE_RESUMES_CACHE["force_advance_stuck_carrier"] === false
    # 🔴 자기 docstring 이 "Does not re-solve: the caller's formulate_milp +
    #    update_project_schedule! do that" 라고 선언한다 — 캐시 재개도 당연히 안 한다.
    @test CB.PRIMITIVE_RESUMES_CACHE["release_pending_assignments"] === false

    # `_needs_cache_resume` = 세계를 건드렸고 && 스스로 재개 안 한다. 전수로 잰다.
    for n in ENACTABLE_TODAY, st in CB.SILENT_SUCCESS_STATUSES[n]
        @test CB._needs_cache_resume(n, st) ===
              (CB._step_touched_world(n, st) && !CB.PRIMITIVE_RESUMES_CACHE[n])
    end
    # 🔴 실제 적응 상태에서: 자체 재개 안 하는 셋은 참, 하는 셋은 거짓.
    @test CB._needs_cache_resume("recover_stalled_teams", :snapped) === true
    @test CB._needs_cache_resume("reform_stuck_teams", :moved) === true
    @test CB._needs_cache_resume("force_advance_stuck_carrier", :carrier_closed) === true
    @test CB._needs_cache_resume("release_pending_assignments", :released) === true
    @test CB._needs_cache_resume("translate_whole_build", :translated) === false
    @test CB._needs_cache_resume("restage_all_blocked", :restaged_all) === false
    @test CB._needs_cache_resume("resolve_schedule_wedge", :unwedged) === false
    # 아무 일도 안 한 판은 재개도 필요 없다(멱등이어도 안 해도 되는 일은 안 한다).
    @test CB._needs_cache_resume("recover_stalled_teams", :stuck) === false
    # ⚠️ 모르는 원시의 기본값은 "재개 안 함"(참)이다 — 모르는 것을 "알아서 하겠지"로 접으면
    #    그것이 곧 조용한 미복구다.
    @test CB._needs_cache_resume("primitive_not_in_table", :whatever) === true

    # ---- (13-c) `_issue_resume!` 가 진짜로 프론티어를 다시 짓는가 --------------------
    # 🔴 no-op 이 아님을 **세계 상태로** 확인한다: 낡은 정점을 심어 두고, 재개 뒤 사라지는지.
    let sched = CB.OperatingSchedule(), cache = CB.initialize_planning_cache(sched)
        push!(cache.active_set, 12345)
        env = (cache = cache, sched = sched)
        @test CB._issue_resume!(env) === (:issued, "")
        @test isempty(cache.active_set)               # 낡은 프론티어가 실제로 지워졌다

        # ---- (13-d) 멱등 — 자체 재개한 원시 뒤에 한 번 더 나가도 해롭지 않다 --------
        # 근거 셋 중 셋째(소스·생산선례는 PRIMITIVE_RESUMES_CACHE docstring 에 있다).
        push!(cache.closed_set, 7)
        CB._issue_resume!(env)
        local a1, c1 = copy(cache.active_set), copy(cache.closed_set)
        CB._issue_resume!(env)
        @test cache.active_set == a1 && cache.closed_set == c1   # 두 번째 호출이 아무것도 안 바꾼다
    end

    # `env` 가 cache/sched 를 안 들고 있으면 **기록**이지 예외가 아니다.
    @test CB._issue_resume!((nope = 1,))[1] === :failed
    @test CB._issue_resume!(nothing)[1] === :failed

    # ---- (13-e) 양성 대조 — enact_minted! 이 실제로 재개를 집행한다 ------------------
    # 던진 단계는 무엇을 하다 던졌는지 모른다 → 보수적으로 재개한다. 이 판은 **진짜 캐시**를
    # 들고 있으므로 재개가 성공하고, 낡은 프론티어가 지워진 것이 관측된다.
    let sched = CB.OperatingSchedule(), cache = CB.initialize_planning_cache(sched)
        push!(cache.active_set, 999)
        env = (cache = cache, sched = sched)          # scene_tree 없음 → reform 이 던진다
        r = CB.enact_minted!(env, nothing, _synth(names = ["reform_stuck_teams"]))
        @test r.verdict === :admit
        @test r.partial === true
        @test r.steps[1].status === :threw
        @test r.resume === :issued                    # 🔴 재개를 실제로 불렀다
        @test isempty(cache.active_set)               # 🔴 그리고 그것이 세계에 보인다
        @test occursin("resume=issued", r.reason)     # 조용하지 않다
    end

    # ---- (13-f) 음성 대조 — 안 건드렸으면 재개도 안 한다 -----------------------------
    # 같은 픽스처, 반대 결과. 이 쌍이 (13-e) 를 "언제나 재개한다" 로 읽는 길을 막는다.
    let sched = CB.OperatingSchedule(), cache = CB.initialize_planning_cache(sched)
        push!(cache.active_set, 999)
        env = (cache = cache, sched = sched, staging_circles = Dict{Symbol,Any}())
        r = CB.enact_minted!(env, nothing, _synth(names = ["translate_whole_build"]))
        @test r.steps[1].status === :no_staging
        @test r.world_maybe_dirty === false
        @test r.resume === :not_needed_untouched
        @test cache.active_set == Set([999])          # 🔴 프론티어가 그대로 = 재개 안 했다
        @test occursin("resume=not_needed", r.reason)
    end

    # ---- (13-h) 🔴 `world_maybe_dirty` 가 `applied` 가 아니라 `touched` 로 지어지는가 ----
    # (b) 결함의 실체를 **집행 경로 끝에서** 잰다. 그러려면 "조용한 성공인데 세계는 건드렸다"
    # 인 status 를 실제로 내는 판이 필요한데, `:residual_blocked` 는 진짜 기하가 있어야 나온다.
    # `:unreadable_return` 이 같은 성질을 값싸게 준다: `_step_applied=false`(못 쟀으니 성공으로
    # 안 센다) · `_step_touched_world=true`(못 쟀으니 깨끗하다고도 못 한다).
    # 🔴 2026-09-03 (Task 10). 옛 판은 오염된 **레지스트리 파일 사본**(`PRIMITIVE_REGISTRY` env
    #    var + `_reset_primitive_table!`)으로 이 갈래를 만들었다. 그 파일 경로도 그 두 심볼도
    #    삭제됐다(Task 2) — 오늘은 런-스코프 표에 행 하나를 **직접** 돌려 넣는다.
    #    재는 성질은 한 글자도 안 바뀌었다: `restage_all_blocked` 의 impl 만 "반환 모양을 못
    #    읽는" 함수로 바꾼다. 🔴 `"generated"` 표시는 **안 붙인다** — 붙이면 `_step_applied`
    #    가 생성 갈래(`nothing`)로 빠져 이 절이 다른 것을 재게 된다.
    let saved = copy(CB.minted_table())
        try
            CB.minted_table()["restage_all_blocked"] = Dict{String,Any}(
                "name" => "restage_all_blocked", "impl" => "process_schedule!",
                "surface" => "physical", "harness_args" => ["env"],
                "params" => Dict{String,Any}(), "reversible" => false)
            local sched = CB.OperatingSchedule()      # env 자리에 그대로 넣는다 — impl 이 이걸 받는다
            local r = CB.enact_minted!(sched, nothing, _synth(names = ["restage_all_blocked"]))
            @test r.steps[1].status === :unreadable_return
            @test r.applied === false                 # 못 쟀으면 적응했다고 안 센다
            @test r.partial === false                 # 던지지 않았다
            # 🔴 그런데도 참이다. `_r` 이 `applied || partial` 로 되돌아가면 이 줄이 빨개진다.
            @test r.world_maybe_dirty === true
            # 이 원시는 스스로 재개하므로 대신 부르지 않는다(멱등이어도 안 해도 되는 일은 안 한다).
            @test r.resume === :not_needed_self
            @test occursin("resume=not_needed", r.reason)
        finally
            CB.minted_table()["restage_all_blocked"] = saved["restage_all_blocked"]
        end
    end
    # 🔴 픽스처가 온전히 돌아왔다 — 표는 프로세스 전역이라 뒤 절·뒤 파일이 이것을 물려받는다.
    @test CB.resolve_primitive("restage_all_blocked").impl === CB.restage_all_blocked!

    # ---- (13-g) 아무것도 안 부른 판의 resume 은 :none 이다 ---------------------------
    @test CB.enact_minted!(nothing, nothing, _synth(names = ["nope"])).resume === :none
    @test CB.enact_minted!(nothing, nothing, _synth(reach = "needs_primitive")).resume === :none
end

# =============================================================================
# (14) 🔴 2026-09-01 — `invariant` 하네스 인자와 `commit_respec` 제거.
#
# 이 절이 재는 것은 **한 결정의 양면**이다.
#   · MILP 재풀이와 그 write-back 은 body 가 아니라 **harness** 의 몫이다 — `apply_action!`
#     이 모든 팔 뒤에 `resolve_assignments!` (T13, `src/smdp/generative.jl:238`) 를 돌린다.
#     그래서 `commit_respec` 은 알파벳에서 빠졌다. 남겨 두면 LLM 이 계속 body 끝에 붙이고
#     (`synthesize.py` 의 파싱 예시들이 그렇게 가르쳤다), 그때마다 body 가 통째로 거절된다.
#   · body 가 말해야 하는 것은 "무엇을 열고 무엇을 재가격할지"뿐이고, 그 "여는" 쪽인
#     `release_pending_assignments` 는 `invariant` 를 요구한다. `build_invariant(env)` 는
#     env 의 순수 함수라 바인더가 만들 수 있다.
#
# 🔴 두 자리가 **같은 상수**(`BINDABLE_HARNESS_ARGS`)를 읽는지도 여기서 잰다. 예전에는
#    `_enactability` 의 연언지 (i) 과 `bind_primitive_args` 의 분기가 같은 사실을 각자
#    적고 있었다 — 어긋나면 조용한 어휘 축소(좁은 쪽이 판정) 또는 거짓 admit(넓은 쪽이 판정)이다.
#
# 변이시험 — 넷 다 실제로 빨갛게 만든 뒤 되돌렸다:
#   ·(14a): `BINDABLE_HARNESS_ARGS` 에서 `"invariant"` 를 뺀다 → (9)(14) 가 빨개진다.
#   ·(14b): `bind_primitive_args` 의 `elseif a == "invariant"` 갈래만 지운다(상수는 그대로)
#           → 두 자리가 어긋나 `unknown_harness_arg:invariant` 로 떨어진다.
#   ·(14c): `_step_status` 의 `EDGELIST_RETURN_PRIMITIVES` 갈래를 지운다
#           → `:unreadable_return` = 읽을 수 있는데 "못 쟀다"로 보고한다.
#   ·(14d): `_step_detail` 의 같은 갈래를 지운다 → status 는 `:released` 인데 detail 은
#           "unreadable return shape" = 한 줄 안에서 두 말이 어긋난다.

# =============================================================================
# (14) 🔴 2026-08-30 최종 리뷰 (IMPORTANT) — **타입 틀린 param 은 예외가 아니라 거절이다.**
#
# 레지스트리 `params` 의 **값**은 아무것도 못 박혀 있지 않았고 `bind_primitive_args` 는 매치된
# param 을 검증 없이 넘겼다(`zone_keys` 만 예외). 집행 가능한 여섯이 실제로 받는 타입 있는
# 키워드는 셋이다: `min_ready::Int` · `snap_all::Bool` · `tol::Float64`.
#
# `{"snap_all": "true"}` 는 **호출 경계의 `convert` 에서** 죽는다 — impl 본문은 한 줄도 안
# 돌았으므로 세계는 **증명 가능하게** 손대지 않은 상태다. 그런데 `enact_minted!` 의 `catch` 는
# 그것을 무조건 `partial = true` 로 적고, 그러면 `world_maybe_dirty = true` → T4 의
# `handled = true` 가 되어 **아무 일도 안 일어난 세계 위에서 기본 복구 사슬이 건너뛰어진다.**
# 즉 LLM 의 오타 하나가 폴백을 삼킨다.
#
# 그래서 이 절이 재는 것은 두 가지다: (i) 타입 오류가 `verdict=:reject` 로 나오는가(= 세계
# 무접촉, `steps` 비어 있음, 폴백이 산다), (ii) **맞는 타입은 여전히 통과하는가**(음성 대조 —
# 없으면 "전부 거절" 이라는 퇴화한 구현이 이 절을 통째로 초록으로 만든다).
# =============================================================================
@testset "(14) 선언된 타입으로 변환 안 되는 param 은 거절이다" begin
    # ---- 전제: 오늘 집행 가능한 여섯에서 타입 있는 키워드는 이 셋이다 ------------------
    local rf = CB.resolve_primitive("reform_stuck_teams")
    local fa = CB.resolve_primitive("force_advance_stuck_carrier")
    @test String(rf.params["min_ready"]["type"]) == "integer"
    @test String(rf.params["snap_all"]["type"])  == "boolean"
    @test String(fa.params["tol"]["type"])       == "number"

    # ---- (14-a) 순수 판정식. 스키마는 레지스트리에서 오고 여기서 다시 안 적는다 ---------
    @test CB._param_type_reject(rf.params["snap_all"], "true") !== nothing   # 문자열 → Bool 불가
    @test CB._param_type_reject(rf.params["snap_all"], true)   === nothing
    @test CB._param_type_reject(rf.params["min_ready"], 1.5)   !== nothing   # InexactError
    @test CB._param_type_reject(rf.params["min_ready"], 2)     === nothing
    @test CB._param_type_reject(rf.params["min_ready"], 2.0)   === nothing   # 변환은 된다
    @test CB._param_type_reject(fa.params["tol"], 0.02)        === nothing
    @test CB._param_type_reject(fa.params["tol"], "0.02")      !== nothing
    # 합집합 선언(`["string","null"]`)은 하나라도 변환되면 통과한다.
    local rp = CB.resolve_primitive("release_pending_assignments")
    @test CB._param_type_reject(rp.params["faulted"], "R3")    === nothing
    @test CB._param_type_reject(rp.params["faulted"], nothing) === nothing
    @test CB._param_type_reject(rp.params["faulted"], 3)       !== nothing
    # 2026-09-01 (cargo-ban T6): `agent` 범위 인자도 같은 합집합 선언이다. 🔴 `"null"` 이
    # 빠지면 기본 호출(`agent = nothing`)이 타입 거절되므로 그 자리를 못 박는다.
    @test CB._param_type_reject(rp.params["agent"], "R3")      === nothing
    @test CB._param_type_reject(rp.params["agent"], nothing)   === nothing
    @test CB._param_type_reject(rp.params["agent"], 3)         !== nothing
    # 🔴 선언이 없거나 모르는 타입이면 거절이다 — 통과시키면 레지스트리 편집이 게이트 전부
    #    초록인 채로 호출 표면을 넓힌다(R46 이 parked 한 확장 경로).
    @test CB._param_type_reject(Dict{String,Any}(), 1) == "no_declared_type"
    @test CB._param_type_reject(Dict{String,Any}("type" => "widget"), 1) ==
          "unknown_declared_type:widget"

    # ---- (14-b) 바인더가 그것을 **거절 문자열**로 낸다 ---------------------------------
    local bad = CB.bind_primitive_args(rf, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("snap_all" => "true")))
    @test bad isa String
    @test occursin("reject:param_type:snap_all", bad)
    @test occursin("reform_stuck_teams", bad)          # 어느 원시인지가 사유에 있다
    # 음성 대조 — 맞는 타입은 통과하고 값이 그대로 실린다("전부 거절" 구현을 막는다).
    local ok = CB.bind_primitive_args(rf, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("snap_all" => true, "min_ready" => 2)))
    @test ok isa Tuple
    @test ok[2].snap_all === true && ok[2].min_ready == 2

    # ---- (14-c) 🔴 집행부까지: `:reject` 이지 `partial` 이 아니다 -----------------------
    # 이것이 결함의 실체다. 고치기 전에는 `verdict=:admit, partial=true,
    # world_maybe_dirty=true` 였고 T4 가 그것을 `handled=true` 로 읽어 폴백을 삼켰다.
    local r = CB.enact_minted!(Ref(:e), nothing,
                _synth(names = ["reform_stuck_teams"],
                       params = Dict{String,Any}("min_ready" => 1.5)))
    @test r.verdict === :reject
    @test isempty(r.steps)                 # 🔴 한 발도 안 나갔다
    @test r.partial === false
    @test r.applied === nothing            # 거절은 못 잰 것이지 잰 0 이 아니다
    @test r.world_maybe_dirty === false     # ⟹ T4 의 handled 가 거짓 ⟹ 폴백이 산다
    @test r.resume === :none
    @test occursin("reject:param_type:min_ready", r.reason)
end

# =============================================================================
@testset "(15) invariant 하네스 인자 · commit_respec 제거" begin
    # ---- (15-a) 상수 하나가 두 자리를 지배한다 ---------------------------------------
    @test CB.BINDABLE_HARNESS_ARGS == Set(["env", "invariant"])

    # ---- (15-b) release 는 이제 집행 가능하다 ----------------------------------------
    rp = CB.resolve_primitive("release_pending_assignments")
    @test rp.harness_args == ["env", "invariant"]      # 레지스트리가 실제 시그니처를 적는다
    @test rp.enactable === true
    @test rp.unenactable_why === :ok

    # ---- (15-c) commit_respec 은 알파벳 밖이다 ---------------------------------------
    @test CB.resolve_primitive("commit_respec") === nothing
    r = CB.enact_minted!(nothing, nothing,
                         _synth(names = ["release_pending_assignments", "commit_respec"]))
    @test r.verdict === :reject
    @test occursin("unknown primitive: commit_respec", r.reason)
    @test isempty(r.steps)                              # 🔴 한 발도 안 나갔다

    # ---- (15-d) 바인더가 만들다 실패하면 **거절**이지 예외가 아니다 -------------------
    # `Ref(:e)` 는 env 가 아니므로 `build_invariant` 가 던진다. 그 예외가 새어 나가면
    # `enact_minted!` 이 기록 대신 예외로 끝나고 호출자는 세계 상태를 알 방법을 잃는다.
    r2 = CB.enact_minted!(Ref(:e), nothing, _synth(names = ["release_pending_assignments"]))
    @test r2.verdict === :reject
    @test occursin("reject:harness_arg_build_failed:invariant", r2.reason)
    @test isempty(r2.steps)

    # ---- (15-e) 간선 목록 반환을 **읽는다** ------------------------------------------
    @test CB._step_status("release_pending_assignments", Tuple{Int,Int}[]) === :released_none
    @test CB._step_status("release_pending_assignments", [(1, 2), (3, 4)]) === :released
    # 🔴 다른 원시의 Vector 반환까지 삼키지는 않는다 — 표에 이름이 있어야 읽는다.
    @test CB._step_status("reform_stuck_teams", [(1, 2)]) === :unreadable_return

    # ---- (15-f) detail 이 status 와 같은 말을 한다 -----------------------------------
    @test CB._step_detail([(1, 2), (3, 4)], "release_pending_assignments") == "released=2"
    @test CB._step_detail(Tuple{Int,Int}[], "release_pending_assignments") == "released=0"
    # 이름을 안 주면 예전 그대로 "못 읽었다" 다(1-인자 호출자는 안 깨진다).
    @test occursin("unreadable return shape", CB._step_detail([(1, 2)]))

    # ---- (15-g) 삼상: `:released_none` 은 "적응 안 함"이되 "세계는 모른다" -----------
    @test CB._step_applied("release_pending_assignments", :released)       === true
    @test CB._step_applied("release_pending_assignments", :released_none)  === false
    @test CB._step_touched_world("release_pending_assignments", :released_none) === true
end

# =============================================================================
# (16) 🔴 2026-09-02 (cargo-ban T7) — `forbid_heavy_cargo` 는 **보관소에 실제로 쓴다.**
#
# 왜 이 절이 있는가: 이 원시의 네 status 는 **전부 조용한 성공**이라 위 (11)(13) 의 표
# 게이트만으로는 "아무것도 안 하는 원시"와 구별되지 않는다. 반환 심볼은 세계가 변했다는
# 증거가 아니다(S-3) — 그래서 여기서는 **보관소 내용물을 직접 잰다.**
#   양성: `:banned` 뒤에 `STANDING_CARGO_BANS[]` 가 그 항목을 얻는다.
#   음성: 짧게 쓴 id 는 `:unknown_agent` 이고 보관소는 **바이트 동일**이다.
# 음성 대조가 없으면 양성은 "무조건 쓴다"와 구별되지 않는다.
#
# 🔴 `agent` 문자열을 리터럴로 적지 않는다 — `string(CB.RobotID(4))` 에서 **파생**한다.
#    손으로 짧게 쓴 형태는 조용히 `:unknown_agent` 가 되고, 이 레포가 이미 데인 자리다.
#    (그 짧은 형태를 아래에서 **음성 대조로** 실제로 던져 본다.)
#
# 🔴 이 절은 전역(`STANDING_CARGO_BANS[]`)을 건드리므로 `try/finally` 로 직접 소유·복원한다.
#    안 비우면 뒤따르는 시험 파일의 모든 `formulate_milp` 이 조용히 달라진다.
# =============================================================================
@testset "(16) forbid_heavy_cargo 가 보관소에 쓴다 (양성 · 음성 대조)" begin
    saved = copy(CB.STANDING_CARGO_BANS[])
    try
        CB.clear_all_cargo_bans!()
        id4   = CB.RobotID(4)
        good  = string(id4)                       # 파생 — 리터럴로 적지 않는다
        short = replace(good, "ConstructionBots." => "")   # 손으로 짧게 쓴 형태
        @test short != good                        # 🔴 전제: 두 형태가 실제로 다르다
        sched = _BanSched(Any[id4,                        # 유효 로봇
                              CB.RobotID(-2),             # 무효 id (풀린 슬롯의 자리표)
                              CB.ObjectID(4),             # 로봇이 아닌 id
                              nothing])                   # 소유자 없음
        env = (sched = sched,)

        # ---- 양성 -------------------------------------------------------------------
        r = CB.forbid_heavy_cargo!(env; agent = good, n = 2)
        @test r.status === :banned
        @test r.agent == good
        @test r.n == 2
        @test haskey(CB.STANDING_CARGO_BANS[], id4)       # 🔴 보관소가 실제로 얻었다
        @test CB.STANDING_CARGO_BANS[][id4] == 2
        @test length(CB.STANDING_CARGO_BANS[]) == 1       # 다른 것은 안 썼다

        # 덮어쓴다(누적 아님) — 보관소 계약 그대로.
        @test CB.forbid_heavy_cargo!(env; agent = good, n = 1).status === :banned
        @test CB.STANDING_CARGO_BANS[][id4] == 1
        @test length(CB.STANDING_CARGO_BANS[]) == 1

        # ---- 음성 대조 셋 — 전부 보관소를 **바이트 동일**로 둔다 ---------------------
        before = copy(CB.STANDING_CARGO_BANS[])
        for (why, call) in (
                (:unknown_agent, () -> CB.forbid_heavy_cargo!(env; agent = short, n = 1)),
                (:unknown_agent, () -> CB.forbid_heavy_cargo!(env; agent = string(CB.RobotID(-2)), n = 1)),
                (:unknown_agent, () -> CB.forbid_heavy_cargo!(env; agent = string(CB.ObjectID(4)), n = 1)),
                (:invalid_n,     () -> CB.forbid_heavy_cargo!(env; agent = good, n = 0)),
                (:invalid_n,     () -> CB.forbid_heavy_cargo!(env; agent = good, n = -3)),
                (:invalid_n,     () -> CB.forbid_heavy_cargo!(env; agent = good, n = 1.5)),
                (:no_schedule,   () -> CB.forbid_heavy_cargo!((nope = 1,); agent = good, n = 1)),
                (:no_schedule,   () -> CB.forbid_heavy_cargo!(nothing; agent = good, n = 1)))
            out = call()
            @test out.status === why
            @test CB.STANDING_CARGO_BANS[] == before      # 🔴 한 항목도 안 움직였다
        end

        # 🔴 `n = 0` 은 **clamp 되지 않는다**. clamp 했다면 위 루프의 보관소 비교가 통과하고
        #    이 줄만 빨개진다 — 두 단언이 함께 있어야 "안 썼다"와 "1 로 올려 썼다"가 갈린다.
        @test CB.STANDING_CARGO_BANS[][id4] == 1

        # ---- 진짜 `OperatingSchedule` 로도 음성 대조(스텁이 아니다) -------------------
        # 로봇이 하나도 없는 실제 스케줄에서 어떤 이름도 안 풀린다.
        @test CB.forbid_heavy_cargo!((sched = CB.OperatingSchedule(),);
                                     agent = good, n = 1).status === :unknown_agent

        # ---- 집행부 끝에서 끝까지 ----------------------------------------------------
        CB.clear_all_cargo_bans!()
        res = CB.enact_minted!(env, nothing,
                _synth(names = ["forbid_heavy_cargo"],
                       params = Dict{String,Any}("agent" => good, "n" => 3)))
        @test res.verdict === :admit
        @test res.steps[1].status === :banned
        @test CB.STANDING_CARGO_BANS[][id4] == 3          # 🔴 body 를 통해서도 실제로 썼다
        # 🔴 그런데 `applied` 는 **거짓**이고 `world_maybe_dirty` 도 **거짓**이다 — 노린 적응
        #    (재풀이가 무거운 화물을 뗀다)은 다음 formulate 의 몫이고, 이 원시는 세계(씬·
        #    스케줄·캐시)를 안 건드렸다. 그래서 기본 복구 사슬이 그대로 돈다.
        @test res.applied === false
        @test res.world_maybe_dirty === false
        @test res.resume === :not_needed_untouched
    finally
        CB.STANDING_CARGO_BANS[] = saved
    end
end

@testset "(17) 인자 오류는 예외가 아니라 status 다 — 폴백을 삼키지 않는다" begin
    # 🔴 R1. 예외로 나가면 partial=true → world_maybe_dirty=true → handled=true 가 되어
    #    **세계를 한 바이트도 안 건드린 판이** 기본 복구 사슬을 삼킨다(사건은 이미 소비됐다).
    env = (cache = CB.PlanningCache(), sched = CB.OperatingSchedule())

    # (a) forbid_heavy_cargo 를 agent 없이 부른다 (여덟 중 유일하게 기본값 없던 kwarg)
    r = CB.enact_minted!(env, nothing,
                         _synth(names = ["forbid_heavy_cargo"], params = Dict{String,Any}()))
    @test r.steps[1].status === :missing_agent      # 던지지 않는다
    @test r.partial === false
    @test r.world_maybe_dirty === false             # ⟹ handled=false ⟹ 폴백이 정상으로 돈다
    @test r.applied === false

    # (b) release_pending_assignments 에 faulted 와 agent 를 둘 다 준다
    r2 = CB.enact_minted!(env, nothing,
             _synth(names = ["release_pending_assignments"],
                    params = Dict{String,Any}("faulted" => "R1", "agent" => "R2")))
    @test r2.steps[1].status === :both_scopes
    @test r2.partial === false
    @test r2.world_maybe_dirty === false

    # 🔴 음성 대조: "안 줬다" 와 "틀린 걸 줬다" 는 **다른 status** 다(spec §9-2).
    r3 = CB.enact_minted!(env, nothing,
             _synth(names = ["forbid_heavy_cargo"],
                    params = Dict{String,Any}("agent" => "no_such_robot")))
    @test r3.steps[1].status !== :missing_agent     # :unknown_agent 또는 :no_schedule
end

# =============================================================================
# (18) 🔴 B1 (2026-09-03) — 인자는 `params` 가 아니라 `calls` 로 온다.
#
# 실측이 계기다. `params` 는 값이 아니라 **JSON 스키마**로 도착한다
# (`{"agent": {"type": "string"}}`) — 집행부가 그것을 값으로 읽으면 원시가 스키마 dict 을
# 인자로 받는다. 게다가 `params` 는 **도구 하나에 dict 하나**라서 body 가 원시 둘 이상이면
# 어느 인자가 어느 원시의 것인지 적히지 않는다.
#
# agent-3 이 이제 `calls` 를 낸다: body 와 **같은 순서**의
# `[{"primitive": ..., "args": {평평한 스칼라}}]`. 값이고, 원시 단위로 스코프가 있다.
#
# 🔴 설계 결정 넷(2026-09-03, 사용자 승인):
#   D1 `calls` 가 있으면 집행은 **거기서** 인자를 묶는다. `body_names` 는 canon/ledger 의
#      계보 기록으로 그대로 남는다(`parse_body` 산출물이라 psi·원장이 그것을 읽는다).
#   D2 `calls` 와 `body_names` 가 **어긋나면 `:reject`**. undo 가 없으므로 어느 쪽이 의도인지
#      모르는 채로 세계를 편집할 수 없다 — 고르는 것보다 안 하는 것이 옳다.
#   D3 `calls === nothing`("못 쟀다": 단일 agent 레인에는 이 필드가 아예 없고, 낡은 서비스도
#      마찬가지) 이면 지금의 `params` 경로 그대로다.
#   D4 모양이 틀린 `calls`·`params`(예: 문자열)는 **예외가 아니라 `:reject`** 다. 예외로 새면
#      `enact_minted!` 이 기록 대신 예외로 끝나고 호출자는 세계 상태를 알 방법을 잃는다.
#
# 변이시험(`src/respec/minted_tool.jl`):
#   ·(18a): `normalize_calls` 의 `x === nothing && return nothing` 을 `return String[]` 로
#           (= 못 쟀다가 빈 호출열이 되어 D3 폴백이 죽는다).
#   ·(18b): 호출별 ctx 를 만드는 자리에서 `call_args` 대신 `params` 를 넘긴다(= 스코프 소실).
#   ·(18c): 이름 일치 검사(`names_from_calls == names`)를 지운다.
#   ·(18d): 미지 인자 검사를 호출 단위에서 body 전체 기준으로 되돌린다.
#   ·(18e): `params` 의 `pairs()` 앞 모양 검사를 지운다(= 문자열이 MethodError 로 던진다).
# =============================================================================

# `calls` 항목 하나. 서비스가 보내는 모양 그대로(String 키 dict) 짓는다.
_c(name; args = Dict{String,Any}()) =
    Dict{String,Any}("primitive" => name, "args" => args)

# 🔴 여섯을 **한 겹 안에** 둔다. 최상위 `@testset` 은 자기가 끝나는 순간 던지므로, 평평하게
#    두면 앞의 하나가 빨개진 자리에서 파일이 멈춰 나머지 다섯을 **RED 로 본 적이 없게** 된다.
@testset "(18) calls 배선" begin

@testset "(18a) calls 가 없으면(못 쟀다) params 경로가 그대로 돈다" begin
    # 🔴 단일 agent 레인에는 `calls` 필드가 아예 없다 — 그 레인이 이 배선으로 죽으면 안 된다.
    fake = (staging_circles = Dict{Symbol,Any}(),)
    r = CB.enact_minted!(fake, nothing, _synth(names = ["translate_whole_build"]))
    @test r.verdict === :admit
    @test length(r.steps) == 1 && r.steps[1].status === :no_staging

    # `calls` 키가 아예 없는 합성 기록(낡은 서비스)도 같은 결과여야 한다.
    # 🔴 2026-09-03 (Task 10). `impl_name` 은 넣는다 — 그것이 없는 기록은 오늘 `calls` 문제가
    #    아니라 **게이트**에서 `:deferred` 로 막히고(Task 9), 그러면 이 절이 재려던
    #    "params 경로가 그대로 돈다" 를 한 번도 안 태운 채 초록이 된다.
    bare = Dict{String,Any}("impl_name" => "translate_whole_build",
                            "body_names" => ["translate_whole_build"])
    r2 = CB.enact_minted!(fake, nothing, bare)
    @test r2.verdict === :admit && [s.status for s in r2.steps] == [s.status for s in r.steps]
end

@testset "(18b) 인자 스코프가 원시 단위다 — params 로는 표현 못 하는 것" begin
    # `n` 은 `forbid_heavy_cargo` 의 것이고 `translate_whole_build` 는 모른다.
    # calls 로 주면 **그 호출이** 거절된다.
    names = ["translate_whole_build", "forbid_heavy_cargo"]
    r = CB.enact_minted!(nothing, nothing,
            _synth(names = names,
                   calls = [_c("translate_whole_build", args = Dict{String,Any}("n" => 2)),
                            _c("forbid_heavy_cargo")]))
    @test r.verdict === :reject
    # 🔴 사유를 정확히 못박는다. `occursin("n", ...)` 같은 느슨한 검사는 아무 단어에나 걸려
    #    **구현이 없어도 초록**이다(첫 판이 실제로 그랬다 — env 없음 거절 문구에 걸렸다).
    @test occursin("arg_matches_no_primitive_in_call:n", r.reason)
    @test occursin("translate_whole_build", r.reason)
    @test isempty(r.steps) && r.world_maybe_dirty === false

    # 🔴 음성 대조. 같은 인자를 **공유 params** 로 주면 (8) 은 통과한다(어떤 원시는 안다) —
    #    즉 위의 거절은 이 배선이 새로 만든 것이지 옛 게이트가 이미 하던 일이 아니다.
    r2 = CB.enact_minted!(nothing, nothing,
            _synth(names = names, params = Dict{String,Any}("n" => 2)))
    @test r2.verdict === :reject
    @test occursin("missing_harness_arg:env", r2.reason)               # 다른 이유로 돌아섰다
    @test !occursin("arg_matches_no_primitive_in_call", r2.reason)     # 이 게이트는 안 걸렸다
end

@testset "(18c) calls 와 body_names 가 어긋나면 거절이다" begin
    fake = (staging_circles = Dict{Symbol,Any}(),)
    two = ["translate_whole_build", "restage_all_blocked"]

    # 순서가 다르다
    r1 = CB.enact_minted!(fake, nothing,
            _synth(names = two, calls = [_c("restage_all_blocked"), _c("translate_whole_build")]))
    @test r1.verdict === :reject && occursin("calls_disagree_with_body", r1.reason)
    @test isempty(r1.steps)

    # 길이가 다르다
    r2 = CB.enact_minted!(fake, nothing,
            _synth(names = two, calls = [_c("translate_whole_build")]))
    @test r2.verdict === :reject && isempty(r2.steps)

    # 🔴 읽었는데 비었다(`[]`) ≠ 못 쟀다(`nothing`). body 가 비지 않았으므로 어긋남이다.
    r3 = CB.enact_minted!(fake, nothing, _synth(names = two, calls = Any[]))
    @test r3.verdict === :reject && isempty(r3.steps)

    # 양성 대조: 같은 순서면 통과해 집행까지 간다.
    r4 = CB.enact_minted!(fake, nothing,
            _synth(names = ["translate_whole_build"], calls = [_c("translate_whole_build")]))
    @test r4.verdict === :admit && length(r4.steps) == 1
end

@testset "(18d) 모양이 틀린 calls 는 예외가 아니라 거절이다" begin
    fake = (staging_circles = Dict{Symbol,Any}(),)
    one = ["translate_whole_build"]
    bad = Any["문자열이다",                                        # 리스트가 아니다
              Any["translate_whole_build"],                       # 항목이 dict 이 아니다
              Any[Dict{String,Any}("args" => Dict{String,Any}())],  # primitive 키가 없다
              Any[Dict{String,Any}("primitive" => "translate_whole_build",
                                   "args" => "dict 이 아니다")]]
    for b in bad
        r = CB.enact_minted!(fake, nothing, _synth(names = one, calls = b))
        @test r.verdict === :reject
        @test isempty(r.steps) && r.world_maybe_dirty === false
    end

    # 🔴 변이 18d 가 위 넷으로는 **살아남았다**(2026-09-03 실측): 항목 검사를 `continue` 로
    #    바꿔도 넷은 전부 다른 게이트(리스트 아님 · primitive 없음 · args 모양 · 이름 불일치)에
    #    걸려 거절됐다. 즉 저 넷은 이 검사를 재고 있지 않았다.
    #    이 판이 진짜 위험한 모양이다: **정상 호출 하나 + 못 읽는 항목 하나.** 항목을 조용히
    #    건너뛰면 남은 하나가 body 와 일치해 **집행까지 간다** — 모델이 뜻한 적 없는 body 를
    #    undo 없이 굴리는 것이고, 그것이 `normalize_calls` 가 전부-아니면-전무인 이유다.
    r5 = CB.enact_minted!(fake, nothing,
            _synth(names = one,
                   calls = Any[_c("translate_whole_build"), "못 읽는 항목"]))
    @test r5.verdict === :reject
    @test occursin("calls_item_not_an_object", r5.reason)
    @test isempty(r5.steps) && r5.world_maybe_dirty === false
end

@testset "(18e) 문자열 params 는 예외가 아니라 거절이다" begin
    # 🔴 서비스는 `params` 를 JSON **스키마 문자열**로 보낼 수 있다. `pairs("...")` 는
    #    MethodError 이고, 그것이 새면 집행부가 기록 대신 예외로 끝난다.
    fake = (staging_circles = Dict{Symbol,Any}(),)
    r = CB.enact_minted!(fake, nothing,
            _synth(names = ["translate_whole_build"],
                   params = "{\"zone_keys\": {\"type\": \"array\"}}"))
    @test r.verdict === :reject
    @test isempty(r.steps) && r.world_maybe_dirty === false
end

@testset "(18f) calls 경로에서도 zone_keys 강제와 타입 검사가 그대로 돈다" begin
    fake = (staging_circles = Dict{Symbol,Any}(),)
    # 살아 있지 않은 존을 주면 **호출 전에** 거절된다 = 값이 실제로 그 호출에 도착했다는 증거.
    r = CB.enact_minted!(fake, nothing,
            _synth(names = ["translate_whole_build"],
                   calls = [_c("translate_whole_build",
                               args = Dict{String,Any}("zone_keys" => ["유령존"]))]))
    @test r.verdict === :reject && occursin("unknown_zone_key", r.reason)
    @test isempty(r.steps)

    # 음성 대조: 안 주면 그 거절이 없다(키워드를 빼서 callee 기본값이 쓰인다).
    r2 = CB.enact_minted!(fake, nothing,
            _synth(names = ["translate_whole_build"], calls = [_c("translate_whole_build")]))
    @test r2.verdict === :admit

    # 선언된 타입으로 변환 안 되는 값도 그대로 거절이다((14) 와 같은 검사가 돈다).
    r3 = CB.enact_minted!(fake, nothing,
            _synth(names = ["forbid_heavy_cargo"],
                   calls = [_c("forbid_heavy_cargo",
                               args = Dict{String,Any}("agent" => "a", "n" => "둘"))]))
    @test r3.verdict === :reject && occursin("param_type", r3.reason)
end

# 🔴 (18g) Step 5. 어느 경로로 인자를 묶었는지가 **결과에 실려야** 한다.
#    없으면 유료 런이 끝난 뒤 로그만 보고 "calls 로 값이 도착해서 굴렀다" 와 "calls 가 없어
#    옛 params 경로로 떨어져 인자 없이 굴렀다" 를 구별할 수 없다 — B1 을 배선한 목적이
#    정확히 그 구별인데 관측할 창이 없는 셈이다.
#    삼상이다: `:calls` · `:params` · `nothing`(그 자리에 **도달 못 했다**, "인자가 없다" 가 아니다).
@testset "(18g) 인자 출처가 결과에 실린다" begin
    fake = (staging_circles = Dict{Symbol,Any}(),)
    one  = ["translate_whole_build"]

    r1 = CB.enact_minted!(fake, nothing, _synth(names = one, calls = [_c("translate_whole_build")]))
    @test r1.verdict === :admit && r1.args_from === :calls && r1.n_calls == 1

    r2 = CB.enact_minted!(fake, nothing, _synth(names = one))
    @test r2.verdict === :admit && r2.args_from === :params && r2.n_calls === nothing

    # 🔴 판정 자리에 도달하지 못한 판은 `nothing` 이다 — `:params` 로 적으면 "옛 경로로
    #    굴렀다" 는 거짓 진술이 된다(아무 경로로도 안 굴렀다).
    # (미끼는 `reach` 가 아니라 `impl_name` 이다 — Task 9.)
    r3 = CB.enact_minted!(fake, nothing, _synth(impl_name = nothing, names = one))
    @test r3.verdict === :deferred && r3.args_from === nothing && r3.n_calls === nothing
    r4 = CB.enact_minted!(fake, nothing, _synth(names = ["teleport_the_build"]))
    @test r4.verdict === :reject && r4.args_from === nothing

    # calls 를 **읽고 나서** 거절한 판은 그 사실이 남는다(읽은 개수까지).
    r5 = CB.enact_minted!(fake, nothing,
             _synth(names = one, calls = [_c("translate_whole_build"), _c("restage_all_blocked")]))
    @test r5.verdict === :reject && r5.args_from === :calls && r5.n_calls == 2
end

end # (18)

# =============================================================================
# (19) 🔴 교차언어 — 파이썬이 정규화한 `calls` 가 JSON 왕복 뒤 집행부에 그대로 도착한다.
#
# (18) 은 **손으로 지은** 픽스처로 잰다. 그 픽스처가 파이썬이 실제로 보내는 모양과 다르면
# 줄리아 게이트는 전부 초록인데 라이브에서만 인자가 사라진다 — 이 레포가 `ran`/`synthesis_ran`
# 에서 이미 밟은 모양이고, `test/synth_lane_keys_survive.jl` 이 그것 때문에 존재한다.
#
# 그래서 여기서는 픽스처를 **파이썬에게 만들게 한다**: 원문을 줄리아가 소유하고,
# `synthesize.normalize_calls` 를 실제로 태우고, JSON 으로 받아 `JSON3` 로 읽어 집행부에 먹인다.
# 이 절이 덮는 것 넷 — 출력 키 이름(`primitive`) · `name` 별칭 · 꼬리 `!` 제거 ·
# `JSON3.Array{JSON3.Object}` 타입이 `normalize_calls`(줄리아)를 통과한다는 것.
#
# 🔴 못 하면 **skip 이 아니라 빨개진다**. 유료 호출 0건(모델을 안 부르고 함수만 태운다).
# 변이시험: ·(19a) 파이썬 `normalize_calls` 의 출력 키를 `"prim"` 으로 개명한다(**사본 위에서**)
#           → 줄리아가 `calls_item_has_no_primitive` 로 거절한다.
# =============================================================================
const REPO   = normpath(joinpath(@__DIR__, ".."))
const PY_BIN = joinpath(REPO, ".venv", "bin", "python")
const SYNDIR = joinpath(REPO, "src", "respec", "llm_service")
# 🔴 `synthesize.py` 는 형제 모듈(`features_agnostic`)의 자리를 `__file__` 에서 유도한다 —
#    사본을 /tmp 에 두면 그 유도가 틀려 import 에서 죽는다(실측). 그 파일이 그러라고 둔
#    탈출구가 `WM_DIR` 이다. 두 판 모두 같은 값을 주므로 양성·음성의 차이는 사본 하나뿐이다.
const WMDIR  = joinpath(REPO, "wm4spacecraft_manufacturing")

# 🔴 `sys.path` 를 **여러 개** 받는다(`:` 구분). 음성 대조는 `synthesize.py` 한 장만 사본으로
#    두고 형제 모듈(`features_agnostic` 등)은 진짜 디렉터리에서 찾게 해야 한다 — 첫 판은
#    `*.py` 를 통째로 복사했는데 그 모듈이 이 디렉터리에 없어 import 에서 죽었다(실측).
const _PY_NORM = raw"""
import json, sys
for p in reversed(sys.argv[1].split(":")):
    sys.path.insert(0, p)
import synthesize as syn
print(json.dumps(syn.normalize_calls(json.loads(sys.argv[2])), ensure_ascii=False))
"""

"파이썬 `normalize_calls` 를 실제로 태우고 JSON3 값으로 돌려준다. 실패는 **예외**다(skip 아님)."
function py_normalize_calls(raw_json::AbstractString; syndir::AbstractString = SYNDIR)
    isfile(PY_BIN) || error("교차언어 게이트: 파이썬이 없다 — $(PY_BIN) (skip 하지 않는다)")
    isfile(joinpath(syndir, "synthesize.py")) || error("합성기 소스가 없다 — $(syndir)")
    local path = syndir == SYNDIR ? syndir : "$(syndir):$(SYNDIR)"
    local o = IOBuffer(); local e = IOBuffer()
    local pr = run(pipeline(ignorestatus(
        `env -u OPENAI_API_KEY WM_DIR=$(WMDIR) $(PY_BIN) -c $(_PY_NORM) $(path) $(raw_json)`);
        stdout = o, stderr = e))
    local out = String(take!(o))
    pr.exitcode == 0 || error("정규화 실패 (rc=$(pr.exitcode))\n$(String(take!(e)))")
    return JSON3.read(out)
end

@testset "(19) 파이썬이 낸 calls 가 JSON 왕복 뒤 집행부에 도착한다" begin
    fake = (staging_circles = Dict{Symbol,Any}(),)
    # 🔴 원문은 **줄리아가 소유한다.** `name` 별칭을 일부러 쓴다 — 라이브에서 실제로 나오는
    #    표기이고, 파이썬이 그것을 접어 주지 않으면 아래 이름 일치가 깨진다.
    # 🔴 2026-09-03 (Task 10) — **꼬리 `!` 는 더 이상 접히지 않는다. 그것이 계약이다.**
    #    Task 8 이 파이썬 `normalize_calls` 에서 `!` 벗김을 지웠고 그 제거가 옳다고 판정됐다:
    #    줄리아의 `normalize_calls` 는 한 번도 안 벗기고, `check_impl_conventions` 는 `!` 로
    #    안 끝나는 이름을 **거절**하므로 등록된 원시 이름에는 `!` 가 반드시 있다. 파이썬이
    #    벗기면 `calls` 의 이름과 `body_names`(= `[impl_name]`, `!` 포함)가 언제나 어긋나
    #    모든 집행이 `calls_disagree_with_body` 로 거절된다.
    #    ⟹ 이 절은 그 무손실을 **양방향으로** 못박는다: `!` 는 살아남고, 별칭은 접힌다.
    raw_bang = """[{"name": "translate_whole_build!", "args": {}}]"""
    @test py_normalize_calls(raw_bang)[1]["primitive"] == "translate_whole_build!"

    raw = """[{"name": "translate_whole_build", "args": {"zone_keys": ["유령존"]}}]"""
    calls = py_normalize_calls(raw)
    @test length(calls) == 1
    @test calls[1]["primitive"] == "translate_whole_build"    # `name` 별칭이 접혔다

    # 값이 그 호출에 실제로 도착했다는 증거: 살아 있지 않은 존이라 **호출 전에** 거절된다.
    r = CB.enact_minted!(fake, nothing,
            _synth(names = ["translate_whole_build"], calls = calls))
    @test r.verdict === :reject && occursin("unknown_zone_key", r.reason)
    @test isempty(r.steps)

    # 양성 대조: 같은 경로로 인자 없이 오면 집행까지 간다.
    ok = py_normalize_calls("""[{"primitive": "translate_whole_build", "args": {}}]""")
    r2 = CB.enact_minted!(fake, nothing, _synth(names = ["translate_whole_build"], calls = ok))
    @test r2.verdict === :admit && length(r2.steps) == 1

    # 🔴 음성 대조 — 이 절이 정말 하중을 지는가. 파이썬 출력 키를 개명한 **사본**을 태운다.
    #    생산 소스는 안 건드린다.
    mktempdir() do dir
        local src = read(joinpath(SYNDIR, "synthesize.py"), String)
        write(joinpath(dir, "synthesize.py"),
              replace(src, "out.append({\"primitive\":" => "out.append({\"prim\":"))
        local bad = py_normalize_calls(raw; syndir = dir)
        @test !haskey(bad[1], :primitive)                       # 개명이 실제로 먹혔다
        local r3 = CB.enact_minted!(fake, nothing,
                       _synth(names = ["translate_whole_build"], calls = bad))
        @test r3.verdict === :reject
        @test occursin("calls_item_has_no_primitive", r3.reason)
    end
end

end # module
