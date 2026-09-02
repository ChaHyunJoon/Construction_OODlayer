# =============================================================================
# cargo_ban_primitive.jl — 알파벳 원시 `forbid_heavy_cargo` 의 구현. (2026-09-02, Task 7)
#
# 왜 별도 파일인가
# ----------------
# 이 함수가 하는 일은 **보관소에 항목 하나를 넣는 것**뿐이고(`set_cargo_ban!`), 그 보관소와
# 컴파일러는 `spec_dsl.jl`·`compiler.jl` 에 산다. 자연스러운 집은 `spec_dsl.jl` 이지만 그
# 파일은 지금 다른 레인이 소유하고 있어(2026-09-02 동시 작업) 건드리지 않는다. 그렇다고
# `minted_tool.jl`(합성 tool 의 **해석·집행 기계**)에 도메인 원시를 끼워 넣으면 그 파일의
# 역할이 흐려진다 — 레지스트리의 다른 열여덟 원시는 전부 자기 도메인 파일에 산다.
# 그래서 화물 금지 도메인의 **알파벳 표면**만 담는 파일을 따로 둔다.
#
# 🔴 이 원시는 **세계를 안 바꾼다.** `STANDING_CARGO_BANS[]` 에 `{로봇 → n}` 하나를 쓰고
#    끝이며, 그 항목이 뜻을 갖는 것은 **다음 `formulate_milp`** 이 훅
#    (`_compile_standing_cargo_bans!`)에서 그것을 읽을 때다. 그래서 `:banned` 도
#    `minted_tool.jl` 의 `SILENT_SUCCESS_STATUSES`·`WORLD_UNCHANGED_STATUSES` 에 들어간다 —
#    `reprice_agent_by_payload` 와 **같은 논거**다(S2 lane Ruling 5).
# =============================================================================

"""
    _resolve_schedule_agent(sched, agent::AbstractString) -> Union{Nothing,AbstractID}

`agent` 문자열이 가리키는 스케줄 위의 로봇 id. 못 찾으면 `nothing`.

🔴 **권위는 스케줄이지 `BATTERY_FLEET[]` 이 아니다.** 금지가 실제로 걸리는 자리는
`compile_constraint!(…, ::ForbidHeavyCargo)` 이고 거기서 소유자 선택자는
`_edge_owner_id(sched, u)` 다. 이름 해석을 다른 출처에서 하면 "해석은 됐는데 컴파일러는
그 로봇의 간선을 하나도 못 찾는" 어긋남이 생긴다. `_schedule_agent_ids`(`reassign.jl`)와
**같은 순회·같은 필터**이고, 다른 것은 문자열이 아니라 **id 를 돌려준다**는 것뿐이다
(보관소가 `Dict{AbstractID,Int}` 라 id 가 필요하다).

🔴 문자열 형태는 **모듈 한정**이다 — `string(CB.RobotID(4))` 가 내는
`"ConstructionBots.BotID{ConstructionBots.DeliveryBot}(4)"` 그대로여야 한다. 손으로 짧게
쓴 `"BotID{DeliveryBot}(4)"` 는 여기서 `nothing` 이 되고 호출자가 `:unknown_agent` 를 낸다.
이 레포가 이미 데인 자리다(`reprice_agent_by_payload!` 의 docstring, `release_pending_assignments!`
의 `:unknown_agent` 갈래).

무효 id(`reset_slot_to_invalid!` 가 찍는 음수 자리표)와 비-로봇 노드는 거른다 — 호출자가
정당하게 뜻할 수 있는 이름이 아니다.
"""
function _resolve_schedule_agent(sched, agent::AbstractString)
    want = String(agent)
    for v in Graphs.vertices(get_graph(sched))
        id = _edge_owner_id(sched, v)
        id isa BotID && valid_id(id) && string(id) == want && return id
    end
    return nothing
end

"""
    _try_resolve_schedule_agent(env, agent) -> (Bool, Union{Nothing,AbstractID})

`(스케줄을 읽을 수 있었나, 그 안에서 찾은 id)`. 첫 값이 거짓이면 둘째는 무의미하다.

🔴 **두 실패를 갈라야 해서 존재한다.** "스케줄을 못 읽었다"(`env` 에 `sched` 가 없다, 값이
스케줄이 아니다)와 "스케줄은 읽었는데 그런 로봇이 없다"는 다른 사건이고, 전자를 후자로 접으면
배선 결함이 오탈자처럼 보인다(삼상 규약).

⚠️ `try` 를 **별도 함수로** 뺀 이유는 문체가 아니다: **`forbid_heavy_cargo!` 본문 안에**
`catch` → `return` 을 직접 두었을 때 이 브랜치의 julia 1.10.11 에서 `Unreachable reached` 로
프로세스가 죽는 것을 봤다(2026-09-02 Task 7 — `test/minted_tool_enacts.jl` (16) 이 SIGILL 로
넘어갔다). 그래서 되돌리지 말 것.

🔴 **그러나 이것을 "`catch` 안의 `return` 은 위험하다" 로 일반화하지 말 것 — 그 일반화는
틀렸다.** 2026-09-02 실측(이 트리, `src/**/*.jl` 정규식 스캔): `catch` 뒤 3줄 안에서
`return` 하는 자리가 **27 곳**, 6줄까지 넓히면 **41 곳**이고 전부 멀쩡히 돈다. 확인한 표본:
`src/essential_tg_coponents.jl:1420`(= **`_edge_owner_id` 자신**, 바로 위 순회가 매 정점마다
부르는 그 함수다) · `src/respec/compiler.jl:393` · `src/respec/verifier.jl:195` ·
`src/respec/minted_tool.jl:508`(집행부 본체) · `src/navigator/payload_bias.jl:99`.
⟹ `Unreachable reached` 는 실재하는 codegen/추론 버그지만 부르는 것은 **구문 부류가 아니라
특정 추론 형상**이다. 여기 적힌 것은 **이 함수에서 관측된 한 사례**이고, 다른 40 곳을
"같은 버그" 로 보고 고치러 가지 말 것. 이 자리에서는 회피 비용이 함수 하나라 그대로 둔다.
"""
_try_resolve_schedule_agent(env, agent::AbstractString) =
    try
        (true, _resolve_schedule_agent(env.sched, agent))
    catch
        # 🔴 **여기서 잡히는 것이 전부 `:no_schedule` 은 아니다 — 알면서 그렇게 접는다.**
        # 세 표(`minted_tool.jl` 의 `SILENT_SUCCESS_STATUSES`·`WORLD_UNCHANGED_STATUSES` 와
        # 아래 `forbid_heavy_cargo!` 의 status 목록)가 정의하는 `:no_schedule` 은
        # "손으로 지은 env / `sched` 필드 부재 / 스케줄이 아닌 값" 뿐인데, 이 `catch` 는
        # `_resolve_schedule_agent` 의 **순회 자체가 던지는 모든 예외**도 같이 삼킨다.
        # 오늘 그 표면은 `get_graph(sched)`·`Graphs.vertices` 와 `valid_id`/`string` 이다
        # (`_edge_owner_id` 는 자기 안에서 이미 전부 삼키고 `nothing` 을 낸다).
        # ⟹ 나중에 순회가 던지게 되면 원인은 "스케줄 워커가 깨졌다" 인데 로그는
        #    "env 에 스케줄이 없다" 라고 말한다 = **오귀인**. `:no_schedule` 을 디버깅할 때
        #    env 배선부터 보지 말고 **이 순회부터** 볼 것.
        #
        # 🔴 그래도 status 를 안 늘린다: `:no_schedule` 은 위 세 표의 **키**이고 게이트
        #    (`test/minted_tool_enacts.jl` (11)·(16))가 그 집합을 그대로 못 박는다.
        # 🔴 좁혀 잡지도 않는다: 빠져나간 예외는 `enact_minted!` 의 `try` 가
        #    `partial = true` 로 적고, **손도 안 댄 세계**가 `world_maybe_dirty = true →
        #    handled = true` 로 기록돼 기본 복구 사슬을 삼킨다(아래 `:invalid_n` 와 같은 논거).
        # ⟹ **방향은 안전하다 — 이 갈래는 아무것도 안 쓴다. 거친 것은 진단뿐이다.**
        (false, nothing)
    end

"""
    forbid_heavy_cargo!(env; agent::AbstractString, n::Real = 1)
        -> (; status, agent, n)

`agent` 가 **1대당 부담 상위 `n` 개** 화물을 맡지 않도록 지속 금지를 등록한다.
`STANDING_CARGO_BANS[]` 에 항목 하나를 쓰는 것이 전부다(덮어쓰기 — 누적이 아니다).

🔴 **이 함수 자체는 세계를 안 바꾼다.** 스케줄 그래프도, 씬트리도, 캐시도 안 건드린다.
효과는 **다음 MILP 정식화**가 보관소를 읽을 때 난다(Task 3 의 훅이 모든
`formulate_milp(::SparseAdjacencyMILP, …)` 에서 돈다). 그래서 `:banned` 는 **조용한 성공**
이고 이 원시는 `WORLD_UNCHANGED` 다.

status — 넷. **이 목록이 `minted_tool.jl` 의 세 표의 진실원이다**(표는 이 `return` 문들을
읽어서 채웠다):

  · `:banned`        보관소에 `{id → n}` 을 썼다. 유일하게 무언가를 남기는 갈래다.
  · `:unknown_agent` 문자열이 스케줄의 어떤 로봇도 안 가리킨다 — **던지지 않는다.**
                     아무것도 안 쓴다. 짧게 쓴 id 형태가 여기로 온다.
  · `:no_schedule`   `env` 에서 스케줄을 못 읽었다(손으로 지은 env, `sched` 필드 부재,
                     스케줄이 아닌 값). 이름을 해석할 권위가 없으므로 **추측하지 않는다** —
                     "이름을 못 찾았다"(`:unknown_agent`)와 다른 사건이다.
                     `reprice_agent_by_payload!` 의 `:no_fleet` 과 같은 자리다.
  · `:invalid_n`     `n` 이 정수가 아니거나 `1` 미만이다. 아무것도 안 쓴다.

🔴 **`n < 1` 을 여기서 막는다 — 보관소까지 흘리지 않는다.** `set_cargo_ban!` 은 `n >= 1` 을
`error` 로 강제하고(`ForbidHeavyCargo` 생성자와 같은 계약: 0 개 금지는 hollow admit 이다),
집행부(`enact_minted!`)의 `try` 는 그 예외를 `partial = true` 로 적는다 = 손도 안 댄 세계가
`world_maybe_dirty=true → handled=true` 로 기록돼 **기본 복구 사슬을 삼킨다.** 그래서 이
자리에서 **읽을 수 있는 status 로 거절**한다(거절 = 세계 무접촉 = 폴백이 돈다).
🔴 **clamp 하지 않는다.** `0` 을 `1` 로 올리면 호출자가 요청하지 않은 개입을 지어내는 것이고,
그 뒤로는 "빈 후보 목록에서 나온 0" 과 "정말 1 개를 뜻한 요청" 이 기록에서 구별되지 않는다.

⚠️ `n` 을 `::Integer` 로 선언하지 않는 이유: `bind_primitive_args` 는 레지스트리의
`"type": "integer"` 를 **`convert(Integer, v)` 가 되는가**로 재고 값을 **날것 그대로** 넘긴다.
그래서 JSON 의 `1.0`(Float64)이 그 관문을 통과해 여기로 온다 — `::Integer` 였다면 호출 경계
`MethodError` 가 나고 위와 똑같은 거짓 `partial` 이 됐을 것이다. `1.5` 는 관문에서 이미 걸린다.

⚠️ **`n` 은 상한이지 보장이 아니다.** 실제로 몇 행이 걸리는지는 컴파일 시점의 후보 도착점 수가
정한다(`_heavy_cargo_targets` 의 `min(n, length(cands))`). 그리고 부담 계층이 없으면
(navigator 미로드 또는 `enable_battery!` 미호출) 그 formulate 는 이 금지를 **집행하지 않는다** —
`@warn` + 0 행이다. `:banned` 를 "화물 n 개가 실제로 떨어져 나갔다" 로 읽으면 안 된다.
"""
function forbid_heavy_cargo!(env; agent::AbstractString, n::Real = 1)
    a = String(agent)
    # (1) 순수 인자 검사 먼저 — 세계를 안 읽어도 판정된다. 🔴 `isinteger` 가 `Inf`·`NaN` 도 막는다.
    #     🔴 `n` 필드는 **요청값 그대로**를 싣는다(`-3` 을 `0` 으로 적으면 기록이 거짓말한다).
    (isinteger(n) && n >= 1) || return (status = :invalid_n, agent = a, n = Float64(n))
    nn = Int(n)
    # (2) 이름을 해석할 권위(스케줄)를 얻는다. 못 얻으면 `:unknown_agent` 로 접지 않는다.
    ok, id = _try_resolve_schedule_agent(env, a)
    ok || return (status = :no_schedule, agent = a, n = nn)
    id === nothing && return (status = :unknown_agent, agent = a, n = nn)
    # (3) 여기서만 무언가를 남긴다.
    set_cargo_ban!(id, nn)
    return (status = :banned, agent = a, n = nn)
end
