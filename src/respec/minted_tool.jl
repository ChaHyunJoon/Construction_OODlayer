# =============================================================================
# 합성된 tool 의 집행. (2026-08-30, T2·T3 / spec §3-1, §5; 2026-09-03 갱신)
#
# LLM 은 시퀀스를 조합하고, 원시 자신은 **런에서 생성된다** — `register_minted_primitive!`
# (`minted_registration.jl`)이 규약을 검사하고 `Core.eval` 로 심는다. 이 파일은 그 시퀀스를
# 받아 **런-스코프 표**(`minted_table()`)를 통해 실제 함수로 해석하고 집행한다.
#
# 🔴 알파벳은 그 런-스코프 표이지 CB 의 심볼 표가 아니다. `isdefined(CB, Symbol(name))` 로
#    해석하면 합성기가 `run_lego_demo` 든 무엇이든 부를 수 있고, 그 순간 안전층이
#    검사할 대상 자체가 정의되지 않는다(spec §3-1 의 마지막 문단).
#
# 🔴 이 파일에 **undo 가 없다.** Plan B 의 C 단계가 그것이고 이 계획의 범위 밖이다.
#    body 중간에서 실패하면 세계는 절반만 고쳐진 채 남는다. 그 사실을 `enact_minted!` 가
#    결과에 `undo = :none` 으로 싣는다 — 없는 안전장치를 있는 척하지 않는다.
#
# 이 파일을 `respec.jl`(`restage_zone.jl` 옆)에서 include 하는 이유: Julia 는 자유 전역을
# 정의 시점이 아니라 **호출 시점**에 푼다 — 함수 본문이 `ZoneTruth` 를 이름으로 써도 정의는
# 문제없이 컴파일되고, 실제로 그 이름을 필요로 하는 것은 나중에 그 함수가 불릴 때다. 그리고
# `src/navigator/` 는 애초에 `src/ConstructionBots.jl` 의 include 목록에 없다 — navigator 계층은
# 호출자가 `CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))` 로 **런타임에**
# CB 모듈 안에 얹는다. 그러므로 "먼저 로드해야 UndefVarError 를 피한다" 는 전제 자체가
# 이 파일에는 적용되지 않는다 — `resolve_primitive` 는 navigator 타입을 이름으로 쓰지 않는다.
# =============================================================================

"""
    resolve_primitive(name) -> Union{Nothing,NamedTuple}

원시 이름 하나를 해석한다. 레지스트리에 **없으면 `nothing`** 이다 — 조용히 통과시키지
않는다. 있으면 `(name, impl, surface, harness_args, params, reversible, enactable,
unenactable_why)`.

🔴 `enactable` 은 "이 원시를 `bind_primitive_args` 가 만드는 인자로 **실제로 부를 수
있는가**"다(연언지 셋은 `_enactability` 를 보라).
집행부는 이것이 거짓인 원시를 **부르기 전에** 거절한다 — 부르면 `MethodError` 가 나고
`try` 가 그것을 "집행됐다"로 보고해서 거짓 admit 이 된다.

⚠️ **"19 중 8" 은 이제 이 자리의 사실이 아니다**(2026-09-03 정정). 그 비율은 삭제된 고정
레지스트리(`core/primitive_registry.json`, 설계 §7)에 대한 2026-09-01 실측이었다. 오늘 표는
런에서 생성되고 크기는 그 런이 주조한 만큼이다. 그리고 규약 1(`f(env; kw…)`)이 arity·kwargs
연언지를 **구성상** 통과시키므로 생성 원시는 원리상 전부 `enactable` 이다 —
`test/minted_registration.jl` testset (5) 가 그 한 줄을 잰다.
"""
function resolve_primitive(name::AbstractString)
    tbl = minted_table()
    haskey(tbl, String(name)) || return nothing
    p = tbl[String(name)]
    sym = Symbol(String(p["impl"]))
    # 🔴 2026-09-03 정정: 예전 문구는 `test/primitive_registry_resolves.jl` 이 이걸 잡는다고
    #    적었는데 그 파일은 이 브랜치에서 **삭제됐다**(설계 §7). 그리고 이 자리는 생성 행에서는
    #    도달 불가다 — `register_minted_primitive!` 가 `Core.eval` **성공 뒤에만** 행을 쓴다.
    #    여기 오는 것은 표에 **손으로 씨 뿌린** 행(시험·프로브)이 CB 에 없는 impl 을 가리킬
    #    때뿐이고, 그 행을 쓴 코드가 고칠 일이다.
    isdefined(@__MODULE__, sym) || error(
        "표의 행이 이름 짓는 impl 이 CB 에 없다: $(p["impl"]) (원시 $(name)). " *
        "생성 행은 eval 성공 뒤에만 쓰이므로, 이 행은 손으로 씨 뿌린 것이다.")
    f = getfield(@__MODULE__, sym)
    f isa Function || error("$(p["impl"]) 이 callable 이 아니다 (원시 $(name))")
    harness = String[String(a) for a in get(p, "harness_args", [])]
    prms    = Dict{String,Any}(String(k) => v for (k, v) in pairs(get(p, "params", Dict())))
    # 🔴 D16. 키워드의 **선언 타입**(이름 → `Type`). 기본값은 **빈 `Dict`** 이지 `nothing`
    #    이 아니다 — 손으로 씨 뿌린 알려진 원시(`test/minted_seed_fixture.jl` 의
    #    `MINTED_FIXTURE_ROWS`, 2026-09-04 실측 **19행**)에는 이 열이 아예 없고, 그때
    #    `bind_primitive_args` 는 "선언 타입을 모른다 ⟹ 값을 그대로 흘린다" 로 가야 한다
    #    (오늘의 동작). `nothing` 을 넣으면 그 자리가 `haskey`/`get` 두 어휘로 갈린다.
    ptypes  = Dict{String,Any}(String(k) => v
                               for (k, v) in pairs(get(p, "param_types", Dict())))
    en, why = _enactability(f, harness, prms)
    return (name           = String(name),
            impl           = f,
            surface        = String(p["surface"]),
            harness_args   = harness,
            params         = prms,
            param_types    = ptypes,
            reversible     = Bool(get(p, "reversible", false)),
            enactable      = en,
            unenactable_why = why)
end

"""
    BINDABLE_HARNESS_ARGS

`bind_primitive_args` 가 **실제로 만들어 줄 수 있는** harness 위치인자의 이름들.

🔴 이 상수가 존재하는 이유는 하나다: `_enactability` 의 연언지 (i) 과 `bind_primitive_args`
   의 분기가 **같은 사실을 두 곳에 손으로 적고 있었다**. 둘이 어긋나면 정확히 두 가지 중
   하나가 난다 — 좁은 쪽이 판정이면 부를 수 있는 원시를 부르기 전에 거절하고(조용한 어휘
   축소), 넓은 쪽이 판정이면 호출 시점 `MethodError` 가 나서 집행부의 `try` 가 그것을
   `:admit`/집행됨으로 보고한다(거짓 admit). 이제 두 자리가 이 하나를 읽는다.

⚠️ 여기에 이름을 더하는 것은 **어휘를 넓히는 행위다**. 더하려면 `bind_primitive_args` 에
   그 값을 만드는 갈래를 같이 넣어야 하고(둘은 한 커밋에서만 움직인다), 새로 집행 가능해진
   원시마다 `SILENT_SUCCESS_STATUSES`·`WORLD_UNCHANGED_STATUSES`·`PRIMITIVE_RESUMES_CACHE`
   세 표의 행을 채워야 한다. 안 채우면 게이트 (9)(11)(13) 이 먼저 빨개진다 — 그것이 설계다.

  · `"env"`       — `ctx.env` 그대로.
  · `"invariant"` — `build_invariant(ctx.env)`. env 의 **순수 함수**라 만들 수 있다
                    (얼린 과거를 읽을 뿐 세계를 안 쓴다). 2026-09-01 추가.

🔴 `"milp"`·`"proposal"` 은 여기에 **못 들어온다**. `commit_respec!` 이 요구하는 그 둘은
   *이미 풀린* MILP 와 그것을 만든 제안이고, 알파벳에 solve 하는 원시가 없으므로
   `(env, truth, params)` 에서 만들어낼 방법이 없다. 그리고 만들 필요도 없다 —
   `apply_action!` 이 **모든 팔 뒤에** 공통 MILP 재풀이(T13, `resolve_assignments!`,
   `src/smdp/generative.jl:238`)를 돌리므로 write-back 은 harness 의 몫이지 body 의 몫이
   아니다. 그래서 `commit_respec` 은 2026-09-01 에 레지스트리에서 **제거됐다**.
"""
const BINDABLE_HARNESS_ARGS = Set{String}(["env", "invariant"])

"""
    _enactability(impl, harness_args, params) -> (Bool, Symbol)

이 원시를 `bind_primitive_args` 가 만드는 인자로 **실제로 부를 수 있는가**. `false` 면
둘째 값이 어느 연언지가 깨졌는지 말한다(`:harness`/`:multimethod`/`:arity`/`:kwargs`).
통과하면 `(true, :ok)`.

🔴 연언지는 **셋**이다. 연언지 (i) 하나만 보면(2026-09-01 실측) 19 중 17 이
집행 가능으로 표시되는데 실제로 부를 수 있는 것은 **8** 뿐이다. 나머지 11 은 호출 시점에
`MethodError` 로 죽고, 집행부의 `try` 는 그것을 `:admit`/집행됨으로 보고한다 — 거절보다
나쁘다(거짓 admit). 그래서 부르기 전에 시그니처를 직접 읽는다:

  (i)   `harness_args` 가 전부 `BINDABLE_HARNESS_ARGS` 안에 있어야 한다 — 오늘은
        `{"env", "invariant"}` 다. 🔴 이 집합을 **여기 다시 적지 않는다**: 예전에는 이 절이
        `a == "env"` 를 손으로 적고 `bind_primitive_args` 가 같은 사실을 따로 적어서, 둘이
        어긋나면 거짓 admit 이나 조용한 어휘 축소가 났다. 빈 `harness_args` 는 이 절을 공짜로
        통과하므로 (ii) 가 반드시 뒤따라야 한다(`pop_spare`·`deprioritize_agent` 가 그 예다).
  (ii)  위치인자 개수가 `harness_args` 개수와 같아야 한다. `swap_battery!(env, role)` 는
        `harness_args == ["env"]` 이지만 위치인자가 둘이다 — 바인더는 하나만 만든다.
  (iii) 레지스트리 `params` 의 키가 전부 그 메서드의 **키워드**여야 한다. 아니면 넘기는
        순간 `MethodError` 다.

⚠️ 메서드가 여럿이면(`compile_constraint!` 는 6개) 어느 메서드로 (ii)(iii) 를 재야 하는지
   결정할 수 없다. **추측하지 않고** `:multimethod` 로 집행 불가 처리한다 — `only(methods(f))`
   가 던지게 두면 `resolve_primitive` 자체가 죽어서 T2 게이트까지 같이 빨개진다.
"""
function _enactability(impl, harness_args, params)
    all(a in BINDABLE_HARNESS_ARGS for a in harness_args) || return (false, :harness)
    ms = methods(impl)
    length(ms) == 1 || return (false, :multimethod)
    m = first(ms)
    m.nargs - 1 == length(harness_args) || return (false, :arity)
    issubset(Set(keys(params)), Set(String.(Base.kwarg_decl(m)))) || return (false, :kwargs)
    return (true, :ok)
end


# =============================================================================
# T3 — 인자 바인더와 삼상 집행
# =============================================================================

"""
    SILENT_SUCCESS_STATUSES

원시가 **성공 계열 값을 돌려주면서 그 tool 이 노린 적응은 일으키지 않은** 경우들.
`applied` 판정이 **손으로 적은 어휘에 대해** 이 표 하나만 본다. 🔴 키는 **집행 가능한 원시
여덟 전부**여야 한다 — 게이트 (11) 이 `keys(SILENT_SUCCESS_STATUSES) == ENACTABLE_TODAY` 를
못 박으므로, 어휘에 집행 가능한 원시가 하나 늘면 이 표를 채우기 전까지 빨갛다.

🔴 **이 못박음은 정적이다 — 런타임에 주조된 이름은 볼 수 없다**(2026-09-03 최종 리뷰 C1).
`ENACTABLE_TODAY` 는 `test/minted_tool_enacts.jl` 이 손으로 적은 여덟 짜리 리터럴이고,
`Core.eval` 로 이 프로세스에 심긴 이름은 그 게이트가 도는 시점에 존재하지도 않는다.
그러므로 "어휘가 늘면 게이트가 먼저 빨개진다" 는 **손으로 늘린 어휘에 대해서만** 참이다.
생성 어휘에 대해서는 이 표가 통째로 미스이고, 그 미스를 기본값으로 접지 않도록
`_step_applied`/`_step_touched_world` 가 `"generated"` 행을 **따로** 처리한다.

🔴 이 표가 없거나 비면 조용한 폴백이 된다. 처음 이 표를 둘만 채웠을 때(2026-08-30 리뷰가
잡음) **집행 가능한 여섯 중 넷**이 아무 일도 안 하고 `applied = true` 를 냈다 — 그중
`force_advance_stuck_carrier!` 는 `CARRIER_RESCUE != "1"`, 즉 **기본 환경**에서 항상
`:disabled` 다. 손 안 댄 환경의 매 런이 "적응했다"로 기록됐을 것이다.

출처 — 여덟 원시의 `return` 문을 전부 읽어서 적었다(추측 없음):
  · `restage_all_blocked!`   `src/respec/restage_zone.jl`
      조용: `:none`(막힌 조립체 없음) `:infeasible`(하나도 못 놓음)
            `:residual_blocked`(못 옮기는 목표가 존에 남음)   실제: `:restaged_all` `:partial`
  · `translate_whole_build!` `src/respec/restage_zone.jl`
      조용: `:no_staging` `:infeasible` `:already_clear`(Δ=0) `:residual_blocked`
      실제: `:translated`
  · `force_advance_stuck_carrier!` `src/respec/replace_robot.jl`
      조용: `:disabled`(🔴 `CARRIER_RESCUE` 미설정 = **기본값**, `moved=0`)
            `:no_carrier`(`moved=0`)          실제: `:carrier_closed` `:carrier_advanced`
  · `recover_stalled_teams!` `src/respec/replace_robot.jl`
      조용: `:no_team`(`moved=0`) `:stuck`(`moved=0`)
            그리고 `force_advance_stuck_carrier!` 의 결과를 **그대로 전달**하므로
            `:disabled`·`:no_carrier` 도 여기로 올라온다(소스의 `carrier.status` 전달 둘).
      실제: `:snapped` `:restaged` `:unwedged` `:force_snapped` `:carrier_closed` `:carrier_advanced`
  · `resolve_schedule_wedge!` `src/respec/replace_robot.jl`
      조용: `:not_applicable`(`removed=0, moved=0`) `:no_wedge`(`removed=0, moved=0`)
      실제: `:unwedged`
  · `reform_stuck_teams!` `src/respec/replace_robot.jl`
      🔴 이 하나만 **NamedTuple 이 아니라 맨 `Int`**(`n_moved`)를 돌려준다. `_step_status` 가
      `COUNT_RETURN_PRIMITIVES` 를 보고 `:moved`/`:moved_none` 으로 읽는다.
      조용: `:moved_none`(`n_moved == 0`)     실제: `:moved`
  · `forbid_heavy_cargo!` `src/respec/cargo_ban_primitive.jl`
      조용: `:banned` `:unknown_agent` `:no_schedule` `:invalid_n` — 🔴 **넷 다**, `:banned` 도
      포함이다(S2 lane Ruling 5 와 같은 논거). 이 원시가 하는 일은 `STANDING_CARGO_BANS[]` 에
      항목 하나를 쓰는 것뿐이고 재풀이를 스스로 하지 않는다 — 노린 적응(재풀이가 그 로봇에게서
      무거운 화물을 떼는 것)이 일어났는지는 이 원시의 반환이 아니라 **다음 formulate** 의
      몫이다. 🔴 그러므로 **실제 적응 status 가 하나도 없다**: 이 원시는 네 갈래 전부가
      조용한 성공이고, 그것이 이 원시의 성질이지 표를 덜 채운 것이 아니다.
      ⚠️ `:invalid_n` 은 `n < 1`(또는 비정수)을 **보관소 경계에 닿기 전에** 잡는다 —
      `set_cargo_ban!` 은 그 값에 `error` 를 내고, 집행부의 `try` 가 그것을 `partial=true` 로
      적어 손도 안 댄 세계가 폴백을 삼킨다. 거절은 세계 무접촉이라 폴백이 정상으로 돈다.
      ⚠️ `:no_schedule` 은 `:unknown_agent` 와 **다른 사건**이다: 이름을 해석할 권위(스케줄)를
      아예 못 읽었다는 뜻이고, 못 읽은 것을 "그런 로봇 없다" 로 접지 않는다(삼상 규약).
  · `release_pending_assignments!` `src/respec/reassign.jl:194`
      조용: `:released_none`(= `removed` 가 비었다) · `:unknown_agent`. 실제: `:released`.
            🔴 **둘을 가르는 것이 2026-09-02 의 수정이다.** 예전엔 `:released_none` 의 원인이
            둘이었다 — (a) 풀 수 있는 미래 배정 간선이 애초에 없었다, (b) `agent` 문자열이
            **스케줄의 어떤 로봇도 안 가리켰다**(모듈 한정이 아닌 짧은 형태 등; `bind_primitive_args`
            는 타입만 보고 값 형태를 안 잰다). 이제 (b) 는 원시가 **편집 전에** 돌아서며
            `(status = :unknown_agent, …)` 를 내므로 `:released_none` 의 원인은 (a) **하나뿐**이다
            — 정확히는 "실재하는 로봇인데 지금 풀 것이 없다" 도 (a) 다.
            권위는 `_schedule_agent_ids(env.sched)`(`reassign.jl`)이고, `BATTERY_FLEET[]` 이
            **아니다**(이 원시는 스케줄 위에서 돌고 배터리 의존을 얻으면 안 된다).
      🔴 이 원시는 NamedTuple 을 안 돌려준다 — `Vector{Tuple{Int,Int}}`(떼어낸 간선)이다.
         `_step_status` 가 `EDGELIST_RETURN_PRIMITIVES` 를 보고 위 둘로 읽는다.
      ⚠️ `:released` 는 "노린 적응이 일어났다"가 맞다: 간선을 실제로 뗐다는 것은 다음
         재풀이가 다시 결정할 수 있는 후보가 생겼다는 뜻이고, 그것이 이 원시가 노리는
         전부다. 재풀이가 **다른 답을 고르는지**는 이 원시의 몫이 아니다(위 `forbid_heavy_cargo` 와 같음).
      ⚠️ `:released_none` 이 무엇을 지나가는가: 이 원시의 `WORLD_UNCHANGED_STATUSES` 행에
         `:released_none` 은 **일부러 없으므로**(아래 그 표의 문단) `_step_touched_world = true`
         → `world_maybe_dirty = true` → `tools/monitor/enact.jl` 의 `minted_handled`(정본;
         식을 여기 베끼지 않는다) 가 true 가 된다. 깨끗한 판에서
         재개가 한 번 더 나가는 것이 대가이고, 그 대가는 `faulted` 경로에서 더러워진 세계를
         "깨끗하다"고 보고하지 않으려고 치른다. 🔴 그리고 이 경로는 조용하지 않다 —
         `enact_minted!` 가 `quiet` 주석("불렸지만 어느 단계도 세계를 적응시키지 않았다")을
         reason 에 붙이고 `enact.jl` 의 `[minted] lane=present` 줄이 `applied=false` 를 찍는다.
      🔴 `:unknown_agent` 는 **반대쪽**이다 — 첫 편집 전에 돌아서므로 `WORLD_UNCHANGED` 에 들어
         있고, `_step_touched_world = false` → `handled = false` → **기본 복구 사슬로 폴백한다**.
         그 폴백도 조용하지 않다(`enact.jl` 이 "NOT handled → 기본 복구 사슬로 폴백한다" 를 찍는다).
         🔴 `SILENT_SUCCESS` 에 함께 있는 것은 불변식이 강제해서이기도 하고 **사실이기도 하다**:
         이름을 못 찾았으니 노린 적응은 일어나지 않았다(`applied=false`). 여기서 "silent" 는
         "로그가 조용하다"가 아니라 "성공 계열 값인데 노린 적응은 없었다"를 뜻한다.

⚠️ `translate_whole_build!` 의 `:residual_blocked` 는 빌드를 **실제로 옮긴다** — 세계의
   바이트는 변한다. 그런데도 여기 있는 이유는 `applied` 가 "바이트가 변했나"가 아니라
   **"이 tool 이 노린 적응이 일어났나"**를 재기 때문이다. 세밀한 사실은 안 잃는다: 그 단계의
   실제 status 가 `steps` 에 그대로 실리고, 세계가 더러워졌을 가능성은 `world_maybe_dirty`
   가 따로 나른다.
"""
const SILENT_SUCCESS_STATUSES = Dict{String,Set{Symbol}}(
    "restage_all_blocked"         => Set([:none, :infeasible, :residual_blocked]),
    "translate_whole_build"       => Set([:no_staging, :infeasible, :already_clear, :residual_blocked]),
    "force_advance_stuck_carrier" => Set([:disabled, :no_carrier]),
    "recover_stalled_teams"       => Set([:no_team, :stuck, :disabled, :no_carrier]),
    "resolve_schedule_wedge"      => Set([:not_applicable, :no_wedge]),
    "reform_stuck_teams"          => Set([:moved_none]),
    "forbid_heavy_cargo"          => Set([:banned, :unknown_agent, :no_schedule, :invalid_n, :missing_agent]),
    "release_pending_assignments" => Set([:released_none, :unknown_agent, :both_scopes]),
)

"""
    COUNT_RETURN_PRIMITIVES

반환값이 NamedTuple 이 아니라 **옮긴 개수 그 자체(`Int`)** 인 원시들. 오늘은
`reform_stuck_teams!` 하나다(`src/respec/replace_robot.jl` 의 `return n_moved`).
이 표가 없으면 그 반환은 "읽을 수 없는 모양"으로 떨어지고, 실제로는 **읽을 수 있는데도**
못 쟀다고 보고하게 된다.
"""
const COUNT_RETURN_PRIMITIVES = Set{String}(["reform_stuck_teams"])

"""
    EDGELIST_RETURN_PRIMITIVES

반환값이 NamedTuple 도 `Int` 도 아니라 **떼어낸 간선의 목록(`Vector{Tuple{Int,Int}}`)** 인
원시들. 오늘은 `release_pending_assignments!` 하나다(`src/respec/reassign.jl:194` 의
`return removed`).

🔴 이 표가 없으면 그 반환은 `:unreadable_return` 으로 떨어지고, **실제로는 읽을 수 있는데도**
   "못 쟀다"로 보고된다. 그러면 `applied` 는 영원히 거짓이고 `world_maybe_dirty` 는 영원히
   참이라, 몇 개를 풀었는지가 결정 행에서 사라진다 — 이 원시의 유일한 관측량이 그 개수다.
   (`0 → 2103`: S2 레인 실측, `tools/monitor/policy.jl:267`.)

상태 이름: 비었으면 `:released_none`, 아니면 `:released`.
"""
const EDGELIST_RETURN_PRIMITIVES = Set{String}(["release_pending_assignments"])

"""
    UNMEASURABLE_STATUSES

"불렸는데 **무슨 일이 났는지 읽을 수 없었다**"를 뜻하는 status 들. 🔴 이것은 절대
`applied = true` 가 아니다 — 모양을 못 읽었다는 것은 세계가 변했는지 **모른다**는 뜻이고,
모르는 것을 "적응했다"로 기록하면 결정 행이 거짓말을 한다. 표에 없는 원시/상태의 보수적
기본값(참)보다 이쪽이 먼저다.
"""
const UNMEASURABLE_STATUSES = Set{Symbol}([:unreadable_return])

"""
    _is_generated(prim_name) -> Bool

이 이름의 표 행이 **생성 코드에서 왔는가**(= `register_minted_primitive!` 가
`Core.eval` 로 심었는가). `minted_registration.jl` 이 행에 `"generated" => true` 를 쓰고,
이 술어가 그것을 읽는다.

🔴 **판별자가 "`minted_table()` 에 있는가" 가 아닌 이유** (2026-09-03 최종 리뷰 C1).
오늘은 **모든** 원시가 그 표를 지난다 — 알려진 여덟도 시험·프로브가 손으로 행을 씨 뿌려
넣는다. 표 멤버십으로 가르면 그 여덟까지 "못 잰다" 로 무너진다. 구별되는 사실은 오직
"`Core.eval` 로 주조됐는가" 이고 그것을 아는 곳은 등록 함수 하나뿐이다.
"""
_is_generated(prim_name::AbstractString) =
    get(get(minted_table(), String(prim_name), Dict{String,Any}()), "generated", false) === true

"""
    _step_applied(prim_name, status) -> Union{Bool,Nothing}

한 단계에서 **노린 적응이 일어났는가**. 🔴 **삼상이다**(2026-09-03 최종 리뷰 C1):
`true` = 일어났다 · `false` = 안 일어났다(쟀다) · `nothing` = **못 쟀다**.
판정 순서는 셋이다:

 1. 🔴 **생성 원시면 `nothing`.** 이 원시의 status 가 "조용한 성공" 인지 "노린 적응" 인지
    말해 주는 표가 **없다** — 아래 `SILENT_SUCCESS_STATUSES` 는 고정 어휘 19가 있던 시절에
    손으로 적혔고, 그 키에 런타임 이름이 있을 수 없다. 모르는 것을 성공으로도 실패로도
    적지 않는다.
 2. `UNMEASURABLE_STATUSES` — 반환 모양을 못 읽었다 → **거짓**. (이쪽은 손으로 적은 어휘
    전용이다. 그 여덟에 대해서는 status 어휘를 알기 때문에 "읽을 수 있었어야 하는데 못
    읽었다" 가 곧 "노린 적응은 확인되지 않았다" 이고, 게이트 셋이 그 값을 못 박는다.)
 3. `SILENT_SUCCESS_STATUSES` — 조용한 성공 → 거짓. 그 밖 → 참.

🔴 **왜 (1) 이 필요했나 — 실측(2026-09-03).** `_step_applied("touch_nothing!", :did_nothing)`
이 `true` 였다. `:did_nothing` 은 원시 자신이 "아무것도 안 했다" 고 적은 status 인데,
이름이 세 표 어디에도 없어 미스 기본값(3)으로 떨어졌기 때문이다. 그 기본값은 "집행 가능한
여덟" 을 전제로 쓰였고 그 전제는 이 브랜치가 없앴다 — 즉 **집행된 모든 생성 body 가
`applied=true`** 였고, Task 11 의 성공률은 구조적으로 100% 가 될 참이었다.

🔴 **`nothing` 을 내보내도 되는지 소비자를 먼저 봤다**(삼상 규약). `applied` 는 하류에서
찍히고(`tools/monitor/enact.jl` 의 `[minted]` 줄) 그대로 전달될 뿐, **불리언 문맥에 안
들어간다** — 들어가는 것은 `world_maybe_dirty` 이고(그 함수 `minted_handled`), 그래서
아래 `_step_touched_world` 는 삼상이 **아니다**. 프로브 둘(`probe_minted_body_enacts.jl` ·
`probe_cargo_ban_end_to_end.jl`)의 `_void_kind` 만 삼항으로 읽고 있었고, 같은 커밋에서
`:unmeasured` 갈래를 더했다.

⚠️ **`nothing` 에서 값으로 올라가는 길**: 등록 행이 자기 status 어휘를 **선언**하면 된다
(agent-3 의 계약에 그 필드를 더하는 일 = Task 8~9). 오늘의 계약(설계 §5)에는 없으므로
오늘의 정직한 답이 `nothing` 이다.
"""
_step_applied(prim_name::AbstractString, status::Symbol) =
    _is_generated(prim_name)           ? nothing :
    status in UNMEASURABLE_STATUSES    ? false :
    !(status in get(SILENT_SUCCESS_STATUSES, String(prim_name), Set{Symbol}()))

"""
    _merge_applied(acc, one) -> Union{Bool,Nothing}

`applied` 는 단계들에 대한 **선언**(하나라도 적응했으면 참)이다. 삼상에서의 선언은
Kleene 이다: 참이 하나라도 있으면 참, 없고 미상이 있으면 미상, 그 밖이면 거짓.
🔴 `|=` 로 접으면 `nothing` 이 곧바로 `MethodError` 다 — 그래서 이름 붙은 함수 하나가 소유한다.
"""
_merge_applied(acc, one) = (acc === true || one === true) ? true :
                           (acc === nothing || one === nothing) ? nothing : false

"""
    WORLD_UNCHANGED_STATUSES

원시가 **세계 상태를 하나도 안 바꾸고** 돌아선 경우들. `world_maybe_dirty` 판정이 이 표
하나만 본다.

⚠️ "한 바이트도 안 썼다" 가 **아니다**(2026-08-30 T4 리뷰의 parked minor, 최종 리뷰에서 문구
정정). `force_advance_stuck_carrier!` 는 `:no_carrier` 로 돌아서기 **전에**
`CARRIER_LAST_D[node_id(tu)] = d` 를 쓴다(`replace_robot.jl` 의 진행 점검 루프). 그럼에도
분류는 그대로 옳다: 그 dict 은 "직전 점검 때 이 캐리어가 얼마나 멀었나" 를 적는 **진행 메모**
이지 세계 상태가 아니다 — 씬 노드도, 스케줄 그래프도, 캐시도 아니다(`clear_carrier_progress!`
가 언제든 통째로 비울 수 있는 것이 그 증거다). 이 표가 재는 것은 **폴백이 그 위에 쌓여도
되는가**이고, 그 질문에 대해 진행 메모는 무관하다. 🔴 키는 **집행 가능한 원시 여덟 전부**여야 한다(게이트가 `keys(...) ==
ENACTABLE_TODAY` 를 못 박는다 — 단 그 못박음은 정적이다, `SILENT_SUCCESS_STATUSES` 의 같은 문단).

🔴 **왜 `SILENT_SUCCESS_STATUSES` 와 별개의 표인가** (2026-08-30 T4 리뷰).
한 status 가 동시에 "노린 적응은 안 일어났다"이고 "그런데 세계는 이미 건드렸다"일 수 있다.
표 하나로는 그 둘을 못 나른다. 실제 사고: `translate_whole_build!` 의 `:residual_blocked` 는
`_apply_uniform_translation!` 이 **이미 빌드를 통째로 옮긴 뒤**에 나오는 상태인데, 표가 하나뿐일
때 `applied=false → partial=false → world_maybe_dirty=false` 가 되어 **"세계가 깨끗하다"고
보고하는 옮겨진 빌드**가 됐다. 오늘은 로그의 거짓말이지만(`macro_to_proposal` 에 zone 분기가
없어 폴백이 이중 편집을 못 한다), zone 매크로가 어휘로 돌아오는 순간 그것이 **제어 흐름**이 된다.

🔴 **불변식: 원시마다 `WORLD_UNCHANGED ⊆ SILENT_SUCCESS`.** 세계를 안 건드렸으면 노린 적응도
당연히 안 일어났다. 이 포함이 `applied ⟹ world_maybe_dirty` 를 보장하고, `handled`(정본은
`tools/monitor/enact.jl` 의 `minted_handled` — 식을 여기 베끼지 않는다) 가 `applied` 판정보다 **넓다**는
성질을 준다.
게이트가 여덟 전부에 대해 이 포함을 잰다.

출처 — 여덟 원시의 소스에서 "첫 세계 편집 전에 돌아서는가"를 읽어서 적었다(추측 없음):
  · `restage_all_blocked!` `src/respec/restage_zone.jl:517`
      안 건드림: `:none`(막힌 조립체 0 → 루프 전에 반환)
                 `:infeasible`(= `isempty(moved) && !isempty(failed)`; `restage_assembly!` 의
                 비-`:restaged` 반환은 **전부** 첫 편집(`set_desired_global_transform!`, :235)
                 **앞**이다)
      🔴 건드림: `:residual_blocked` — 삼항 사슬상 `moved` 가 비지 않아야 도달한다(비었으면
                 `:infeasible` 로 먼저 갈린다). 즉 조립체를 **실제로 옮긴 뒤**의 상태다.
                 `:partial` · `:restaged_all` 도 같다.
  · `translate_whole_build!` `src/respec/restage_zone.jl:777`
      안 건드림: `:no_staging` · `:infeasible`(둘 다 `_apply_uniform_translation!` **앞**에서 반환)
      🔴 건드림: `:residual_blocked` · `:already_clear` · `:translated` — 셋 다
                 `_apply_uniform_translation!` 이 **이미 돈 뒤**다. `:already_clear`(|Δ|≤1e-9)도
                 제외하지 않는다: 그 함수는 Δ 와 무관하게 `_resync_scene_drift!(env)` 를 불러
                 드리프트한 씬 노드를 스냅한다(`restage_zone.jl:629`) = 세계 편집이다.
  · `force_advance_stuck_carrier!` `src/respec/replace_robot.jl:803`
      안 건드림: `:disabled`(첫 줄, `CARRIER_RESCUE` 미설정) · `:no_carrier`(= `isempty(teleported)`,
                 즉 `set_desired_global_transform!` 이 한 번도 안 돌았다)
      🔴 건드림: `:carrier_closed` · `:carrier_advanced`
  · `recover_stalled_teams!` `src/respec/replace_robot.jl:588`
      안 건드림: `:no_team`(하위 호출이 전부 비진행 반환) · `:stuck`(reform 둘 다 0, wedge/carrier 비진행)
                 그리고 `:disabled`·`:no_carrier`(`SILENT_SUCCESS_STATUSES` 의 키 집합을 그대로
                 맞춘다 — ⚠️ 실제로는 이 둘이 이 원시에서 **밖으로 올라오지 않는다**: 소스의
                 전달 조건이 `carrier.status in (:carrier_closed, :carrier_advanced)` 뿐이다.
                 도달 불가 항목이라 무해하고, 두 표의 키·값 대조를 쉽게 하려고 남긴다)
      🔴 건드림: `:snapped` · `:restaged` · `:unwedged` · `:force_snapped` · `:carrier_*`
  · `resolve_schedule_wedge!` `src/respec/replace_robot.jl:979`
      안 건드림: `:not_applicable` · `:no_wedge`(둘 다 `Graphs.rem_edge!` **앞**에서 반환)
      🔴 건드림: `:unwedged`
  · `reform_stuck_teams!` `src/respec/replace_robot.jl:458`
      안 건드림: `:moved_none`(`n_moved == 0`). 🔴 근거: `wedged` 가 참이면 `members` 는 비지 않고
                 팀원은 `robot_team(tu)` 에서 왔으므로 `has_component` 가 참이라 `n_moved ≥ 1` 이다.
                 따라서 `n_moved == 0` ⟹ 어떤 팀도 `wedged` 가 아니었다 ⟹ `capture_robots!` 도
                 한 번도 안 불렸다.
      🔴 건드림: `:moved`
  · `forbid_heavy_cargo!` `src/respec/cargo_ban_primitive.jl`
      안 건드림: `:banned` `:unknown_agent` `:no_schedule` `:invalid_n` — 🔴 **넷 다**. 본체가
                 하는 일은 `STANDING_CARGO_BANS[]` 에 `{로봇 → n}` 하나를 쓰는 것뿐이다 —
                 씬 노드도, 스케줄 그래프도, 캐시도 안 건드린다. 앞의 셋은 그 한 줄 **앞에서**
                 돌아서므로 아무것도 안 쓰고, `:banned` 도 보관소 항목 하나일 뿐이다.
                 ⚠️ 그 항목은 **다음 `formulate_milp`** 을 바꾼다(Task 3 의 훅이 모든 정식화에서
                 읽는다). 이 표가 재는 것은 "폴백이 그 위에 쌓여도 되는가" 이고, 그 질문에 대해
                 아직 아무 정식화도 안 돈 보관소 항목은 `AGENT_COST_BIAS`·`PAYLOAD_BIAS` 와
                 같은 부류다 — 세계(씬·스케줄·캐시)가 아니라 **다음 argmin 의 입력**이다.
  · `release_pending_assignments!` `src/respec/reassign.jl:194`
      안 건드림: `:unknown_agent` — 🔴 2026-09-02 추가, **이 행에 들어오는 유일한 것**.
                 `agent` 가 `_schedule_agent_ids(sched)` 에 없으면 원시가 `Graphs.rem_edge!` 는
                 물론 `active_ids` 계산보다도 **먼저** 돌아선다(`reassign.jl` 의 이른 반환).
                 params 와 무관하게 참이다: `faulted` 와 `agent` 를 함께 주는 것은 `ArgumentError`
                 이므로 이 갈래에서는 아래 faulted 블록이 **구조적으로 도달 불가**다. 즉 이 표가
                 (이름, status) 만 보고도 확실히 말할 수 있는 유일한 자리다.
      🔴 **`:released_none` 은 여기 넣지 않는다.** 이 표는 (이름, status)
         만 보는데, 이 원시의 세계 접촉은 **params 에 달려 있다**: `faulted !== nothing` 이면
         `removed` 가 비어도 마지막 블록(`reassign.jl:272-285`)이 하류의 낡은 id 노드마다
         `reset_slot_to_invalid!` 를 부른다 = `removed == []` 인데 세계는 편집됐다.
         표가 그 경우를 구별할 수 없으므로 **보수적인 쪽**을 고른다: 언제나 "건드렸을 수
         있다". 대가는 깨끗한 판에서도 재개가 한 번 더 나가는 것뿐이고, 그것은
         `_issue_resume!` 의 멱등성 문단이 무해하다고 못박은 일이다. 반대로 골랐다면
         faulted 모드에서 더러워진 세계를 "깨끗하다"고 보고했을 것이다 — 그쪽이 이 표가
         존재하는 이유인 실패다.
      (`WORLD_UNCHANGED ⊆ SILENT_SUCCESS` 불변식: `:unknown_agent` 는 `SILENT_SUCCESS` 에도
       있다 — 강제된 것이 아니라 참이다. 이름을 못 찾았으면 노린 적응도 안 일어났다.)
"""
const WORLD_UNCHANGED_STATUSES = Dict{String,Set{Symbol}}(
    "restage_all_blocked"         => Set([:none, :infeasible]),
    "translate_whole_build"       => Set([:no_staging, :infeasible]),
    "force_advance_stuck_carrier" => Set([:disabled, :no_carrier]),
    "recover_stalled_teams"       => Set([:no_team, :stuck, :disabled, :no_carrier]),
    "resolve_schedule_wedge"      => Set([:not_applicable, :no_wedge]),
    "reform_stuck_teams"          => Set([:moved_none]),
    "forbid_heavy_cargo"          => Set([:banned, :unknown_agent, :no_schedule, :invalid_n, :missing_agent]),
    "release_pending_assignments" => Set([:unknown_agent, :both_scopes]),  # 🔴 `:released_none` 은 일부러 빠졌다 — 위 문단
)

"""
    _step_touched_world(prim_name, status) -> Bool

한 단계가 **세계에 손을 댔을 수 있는가**. `_step_applied` 와 판정 순서가 **일부러 다르다**:

 1. 🔴 **생성 원시면 참** (2026-09-03 최종 리뷰 C1, 명시 갈래). 미스 기본값으로 떨어져서가
    아니라 **잰 값이다**: 임의의 생성 코드가 라이브 `env` 를 위치인자로 받아 끝까지 돌았다.
    이 필드가 묻는 것은 "세계가 변했나" 가 아니라 "손을 댔을 **수** 있는가" 이고, 그 가능성
    질문의 답은 참이다.
    🔴 **여기는 `nothing` 이 아니다** — `_step_applied` 와 다른 이유가 둘이다.
      (a) 위 문단대로 이 질문에 대해서는 실제로 **잰 것이 있다**(못 잰 것은 "노린 적응이
          일어났는가" 쪽이다).
      (b) 소비자가 Bool 을 요구한다. `world_maybe_dirty` 는 `tools/monitor/enact.jl` 의
          `minted_handled`(정본, 식을 여기 베끼지 않는다)에서 `&&` 의 항으로 들어가므로
          `nothing` 이 가면 그 함수가 `TypeError` 로 죽고, 집행 결과가 기록 대신 예외가 된다 —
          이 파일 전체가 막는 실패 모양이다.
    ⚠️ 대가는 정직하다: 아무것도 안 한 생성 body 도 `world_maybe_dirty=true` → `handled=true`
       라서 기본 복구 사슬을 건너뛴다. 그것이 이 필드의 계약이다(더러워졌을 수 있는 세계 위에
       폴백을 쌓는 것이 더 나쁘다). "정말로 적응했나" 를 재는 필드는 `applied` 이고, 그 필드가
       이제 `nothing` 으로 **모른다고 말한다** — 성공률을 그 위에서 세면 100% 가 안 나온다.
 2. `UNMEASURABLE_STATUSES` — 못 쟀다 → 🔴 **참**(보수적). `_step_applied` 는 같은 자리에서
    거짓을 낸다. 비대칭이 옳다: 반환 모양을 못 읽었다는 것은 "적응했다고 셀 수 없다"인
    동시에 "세계가 깨끗하다고 말할 수도 없다"이다. 두 질문의 안전한 답이 반대편이다.
 3. `WORLD_UNCHANGED_STATUSES` 에 있으면 거짓.
 4. 그 외 → 참(보수적).
"""
_step_touched_world(prim_name::AbstractString, status::Symbol) =
    _is_generated(prim_name)        ? true :
    status in UNMEASURABLE_STATUSES ? true :
    !(status in get(WORLD_UNCHANGED_STATUSES, String(prim_name), Set{Symbol}()))

"""
    PRIMITIVE_RESUMES_CACHE

원시가 세계를 고친 뒤 **스스로 `reset_cache_resume!` 를 부르는가**. 🔴 키는 집행 가능한
원시 여덟 전부여야 한다(게이트가 `keys(...) == ENACTABLE_TODAY` 를 못 박는다 — 정적 못박음이다,
`SILENT_SUCCESS_STATUSES` 의 같은 문단). 생성 원시는 여기서도 미스이고, 그 미스 기본값은
`_needs_cache_resume` 의 문단이 적은 대로 **`true`(스스로 재개 안 함)** 라서 보수적인 쪽이다 —
`applied` 의 미스 기본값과 달리 이쪽은 고칠 것이 없다.

🔴 **왜 이 표가 필요한가** (2026-08-30 T4 리뷰, CRITICAL).
`enact_minted!` 은 `r.prim.impl(env)` 를 부른다(2026-09-03 부터 world age 때문에
`Base.invokelatest` 로 — Task 5). 여덟 중 다섯은 스케줄 캐시를
스스로 재개하지 않는다 — `reform_stuck_teams!` 의 주석이 직접 그렇게 적는다(*"the callers …
drive the schedule via reset_cache_resume!"*). 그 대가는 `src/respec/ood_injection.jl` 이
적어 둔 그대로다: *"그래프는 바뀌었는데 스케줄 캐시가 옛 프론티어를 들고 있어 복구가 아무
효과가 없다 (예외는 안 난다)"*.

T4 배선이 이것을 **치명적**으로 만든다: body `["recover_stalled_teams"]` 가 `:snapped` 를 내면
`applied=true → handled=true → policy_producer 가 nothing 반환` = 기본 복구 사슬을 건너뛴다.
로그는 `verdict=admit applied=true handled=true` 라고 적고, 프론티어는 낡은 채이며, 그 OOD
사건은 **이미 소비돼 다시 오지 않는다.** 성공과 구별되지 않는 조용한 미복구 — 이 계획이
막으려는 바로 그 실패다.

출처 (`grep -n reset_cache_resume!` 실측):
  · `restage_all_blocked!`         **true**  `restage_zone.jl:532` — `(resume && !isempty(moved)) && reset_cache_resume!`
  · `translate_whole_build!`       **true**  `restage_zone.jl:789` — `_apply_uniform_translation!` 직후
  · `resolve_schedule_wedge!`      **true**  `replace_robot.jl:1037` (그리고 `:1039` 에서 한 번 더)
  · `reform_stuck_teams!`          **false** — 자기 주석이 호출자에게 미룬다
  · `recover_stalled_teams!`       **false** — 본체에 호출 0건. ⚠️ `:restaged`/`:unwedged` 하위
      경로는 위임한 원시(`restage_all_blocked!`·`translate_whole_build!`·`resolve_schedule_wedge!`)
      **안에서** 재개된다. 그래도 여기서는 **false** 로 둔다: 가장 흔한 `:snapped`·`:force_snapped`
      경로가 `reform_stuck_teams!` 만 타서 재개가 없기 때문이다. 그 하위 경로에서는 재개가
      한 번 더 나가는데, 그것이 안전한 근거는 `_issue_resume!` 의 멱등성 문단에 있다.
  · `force_advance_stuck_carrier!` **false** — `update_planning_cache!(env, 0.0)` 를 부르지
      `reset_cache_resume!` 를 부르지 않는다(`replace_robot.jl:875`)
  · `release_pending_assignments!` **false** — 자기 docstring 이 "Does not re-solve: the
      caller's `formulate_milp` + `update_project_schedule!` do that" 라고 선언한다. 캐시
      재개는커녕 재풀이도 안 한다. 🔴 그래서 이 원시가 든 body 는 **뒤에 재풀이가 따라와야**
      한다 — 레지스트리의 precondition 이 그것을 요구하고, `apply_action!` 의 공통 재풀이
      (T13, `src/smdp/generative.jl:360`)가 모든 팔 뒤에 돌아 그것을 구조적으로 보장한다.
"""
const PRIMITIVE_RESUMES_CACHE = Dict{String,Bool}(
    "restage_all_blocked"         => true,
    "translate_whole_build"       => true,
    "resolve_schedule_wedge"      => true,
    "reform_stuck_teams"          => false,
    "recover_stalled_teams"       => false,
    "force_advance_stuck_carrier" => false,
    # 🔴 캐시 재개는커녕 세계를 아예 안 건드린다 — 보관소에 항목 하나를 쓰고 끝난다.
    #    그래서 `_needs_cache_resume` 은 이 원시의 네 status 전부에서 거짓이다
    #    (`_step_touched_world` 가 이미 거짓이므로 이 값과 무관하게 거짓이다).
    "forbid_heavy_cargo"          => false,
    "release_pending_assignments" => false,
)

"""
    _needs_cache_resume(prim_name, status) -> Bool

이 단계 **하나** 때문에 body 끝에서 `reset_cache_resume!` 를 불러야 하는가.
= 세계를 건드렸을 수 있고(`_step_touched_world`), 그런데 그 원시가 스스로 재개하지 않는다.

⚠️ 표에 없는 이름의 기본값은 **`false`(자체 재개함)** 가 아니라 `true`(안 함)다 — 모르는
원시를 "알아서 재개하겠지"로 접으면 그것이 곧 조용한 미복구다.
"""
_needs_cache_resume(prim_name::AbstractString, status::Symbol) =
    _step_touched_world(prim_name, status) &&
    !get(PRIMITIVE_RESUMES_CACHE, String(prim_name), false)

"""
    _issue_resume!(env) -> (Symbol, String)

`reset_cache_resume!(env.cache, env.sched)` 를 **한 번** 부른다. 반환은
`(:issued, "")` 또는 `(:failed, "<첫 줄>")`.

🔴 **멱등이다 — 그래서 자체 재개한 원시 뒤에 한 번 더 나가도 해롭지 않다**(리뷰 지시 3).
근거 셋:
 1. 소스(`replan.jl:1577`): `closed_set` 을 **읽기만** 하고 `active_set`·`node_queue` 를 비운 뒤
    `(sched, closed_set)` 에서 **다시 계산**한다. 진행 상태를 소비하는 부분이 없다.
    `process_schedule!` 은 지속된 MILP 시각 위에서 고정점이다(그 docstring).
 2. 생산 코드의 선례: `resolve_schedule_wedge!` 가 `replace_robot.jl:1037` 과 `:1039` 에서
    **연달아 두 번** 부른다(사이에 `reform_stuck_teams!` 하나뿐).
 3. 게이트가 두 번 불러 `active_set`·`closed_set` 이 같음을 잰다.
그럼에도 발화 조건은 **좁게** 잡는다(자체 재개 안 하는 원시가 실제로 세계를 건드렸을 때만) —
멱등이라도 안 해도 되는 일을 하지 않는 편이 읽는 사람에게 정직하다.

⚠️ `env` 가 `cache`/`sched` 를 안 들고 있으면 던진다(손으로 지은 env, `nothing`). 그것을
**기록**으로 바꾼다 — 여기서 예외가 새면 `enact_minted!` 이 기록 대신 예외로 끝난다.
"""
function _issue_resume!(env)
    try
        reset_cache_resume!(env.cache, env.sched)
        return (:issued, "")
    catch e
        return (:failed, first(split(sprint(showerror, e), "\n")))
    end
end

"""
    RESOLVE_SURFACES

**재풀이가 필요한 편집 표면.** body 가 이 표면의 원시를 하나라도 굴렸을 때만 공통 MILP
재풀이가 돈다.

🔴 왜 "모든 body 뒤" 가 아닌가 (2026-09-02, 판정 1 집행 중의 범위 결정). 프롬프트의 약속
문장 자신이 범위를 적는다: *"a body that edits **assignment edges or edge weights** is
completed by that re-solve"*. 배정 문제를 건드리지 않는 표면(`scene_tree`·`physical`)은
간선을 **매달아 놓지 않는다** — 계획은 그대로 유효하고, 거기서 재풀이는 순수 재최적화다.
그 대가는 공짜가 아니다: 재풀이 하나가 최악 60초(S2 실측)이고 그것이 **렌더 루프 안**에서
돈다. 그래서 약속의 범위 그대로 좁힌다.

🔴 `milp` 이 여기 들어가는 이유는 `sched` 와 다르다. `forbid_heavy_cargo!` 는 지속 금지
보관소에 한 줄 쓰는 것이 전부이고 **세계를 안 바꾼다** — 그 다음 `formulate` 가 그것을 읽어야
비로소 효과가 생긴다. 재풀이가 없으면 그 원시는 `applied=true` 로 기록되면서 **아무 일도
일으키지 않는다**(이 레포가 `deprioritize_agent` 에서 이미 밟은 자리: "MILP 재풀이 없이는 무효").

⚠️ 건너뛴 판은 `resolve = :not_needed_surface` 로 **기록된다.** 조용히 안 부르지 않는다 —
"안 필요해서 안 불렀다" 와 "부르고 실패했다" 는 다른 사건이다.
"""
const RESOLVE_SURFACES = Set(["sched", "milp"])

"""
    _issue_resolve!(env) -> (Symbol, String)

**주조 body 뒤의 공통 MILP 재풀이** (판정 1, 2026-09-02). `resolve_assignments!`
(`src/respec/common_resolve.jl`)를 한 번 부르고 그 판정을 기록용 태그로 돌려준다.

🔴 왜 여기가 그 자리인가. `synthesize.py` 는 프롬프트에서 두 번
*"THE HARNESS RE-SOLVES THAT MILP AUTOMATICALLY AFTER EVERY TOOL BODY"* 라고 약속하고,
2026-09-01 에 `commit_respec` 을 알파벳에서 뺀 근거가 그 문장이다. 그 약속이 이 엔진에서는
**거짓이었다**: 재풀이는 SMDP 런타임 모듈 안에만 살았고 이 파일의 유일한 프로덕션
호출자(`render_demo.jl`)는 그 모듈을 include 하지 않는다. 그래서 body 가 배정 간선을 떼면
**아무도 재배정하지 않은 채** `handled=true` 로 기본 복구 사슬까지 삼켰다.

🔴 **던지지 않는다.** 여기서 예외가 새면 `enact_minted!` 이 기록 대신 예외로 끝나고 호출자는
세계 상태를 알 방법을 잃는다 — `_issue_resume!` 과 같은 논거다.

⚠️ **시간의 대가는 공개다**(S2 실측): 범위를 안 좁힌 전 구간 release 뒤의 재풀이는 60초
`TIME_LIMIT` 을 친다(좁힌 release 는 0.2초 `OPTIMAL`). `_respec_optimizer()` 에 시간 제한이
없으므로 그런 body 는 집행 경로를 그만큼 잡아 둔다. 숨기지 않고 status 와 함께 적는다.
"""
function _issue_resolve!(env)
    try
        r = resolve_assignments!(env)
        return (r.status, "n_reassigned=$(r.n_reassigned)")
    catch e
        return (:threw, first(split(sprint(showerror, e), "\n")))
    end
end

"""
    _resolve_note(tag, detail) -> String

재풀이 판정을 사유 문자열에 싣는다. 🔴 `_resume_note` 와 같은 규율 — "재풀이가 실패했다"도
사건이고, 그 사실이 로그와 `resolve` 필드 **양쪽**에 있어야 사람과 게이트가 같이 본다.
"""
_resolve_note(tag::Symbol, detail::AbstractString) =
    tag === :resolved      ? " [resolve=resolved: $(detail)]" :
    tag === :infeasible    ? " [resolve=INFEASIBLE — 🔴 body 가 편집한 세계에서 배정을 다시 못 풀었다]" :
    tag === :commit_failed ? " [resolve=COMMIT_FAILED — 🔴 재풀이는 됐는데 반영이 거부됐다]" :
    tag === :threw         ? " [resolve=THREW: $(detail) — 🔴 재풀이가 던졌다]" :
    tag === :not_needed_surface ? " [resolve=not_needed: $(detail)]" : ""

"""
    _resolve_if_needed!(env, ran) -> (Symbol, String)

`ran` 중 하나라도 `RESOLVE_SURFACES` 의 표면을 건드리면 재풀이를 부르고, 아니면
`(:not_needed_surface, ...)` 를 기록한다.
"""
function _resolve_if_needed!(env, ran)
    hit = String[]
    for r in ran
        r.prim.surface in RESOLVE_SURFACES && push!(hit, r.prim.name)
    end
    isempty(hit) && return (:not_needed_surface,
                            "배정 문제를 건드린 원시가 없다(표면: " *
                            join(unique([r.prim.surface for r in ran]), ",") * ")")
    return _issue_resolve!(env)
end

"""
    _resume_note(tag, detail) -> String

재개 판정을 **사유 문자열에 싣는다**. 🔴 조용한 폴백 금지: "재개를 안 했다"도 사건이고,
그 이유(세계를 안 건드렸다 / 원시가 알아서 한다 / 시도했는데 실패했다)가 서로 다르다.
`resume` 필드가 같은 것을 기계가 읽을 수 있게 나른다 — 둘 다 있어야 사람과 게이트가 함께 본다.
"""
_resume_note(tag::Symbol, detail::AbstractString) =
    tag === :issued               ? " [resume=issued: 자체 재개 안 하는 원시가 세계를 건드려 reset_cache_resume! 를 한 번 불렀다]" :
    tag === :failed               ? " [resume=FAILED: $(detail) — 🔴 프론티어가 낡은 채로 남았다]" :
    tag === :not_needed_self      ? " [resume=not_needed: 세계를 건드린 원시가 전부 스스로 재개한다]" :
    tag === :not_needed_untouched ? " [resume=not_needed: 어느 단계도 세계를 안 건드렸다]" : ""

"""
    PARAM_JSON_TYPES

레지스트리 `params` 스키마의 `"type"` 문자열 → 그 값이 **변환될 수 있어야 하는** Julia 타입.

🔴 왜 필요한가 (2026-08-30 최종 리뷰, IMPORTANT — 여섯 번째 조용한 미복구 경로).
집행 가능한 여덟이 실제로 받는 타입 있는 키워드는 다섯이다
(`reform_stuck_teams!(env; min_ready::Int, snap_all::Bool)` ·
`force_advance_stuck_carrier!(env; tol::Float64)` ·
`forbid_heavy_cargo!(env; agent::AbstractString, n::Real)`). LLM 이 `{"snap_all": "true"}` 나
`{"min_ready": 1.5}` 를 주면 Julia 는 **호출 경계에서** `convert` 에 실패한다 — impl 본문은
한 줄도 안 돌고 세계는 **증명 가능하게** 손대지 않은 상태다. 그런데 `enact_minted!` 의
`catch` 는 그것을 무조건 `partial = true` 로 적고, 그러면 `world_maybe_dirty = true` →
`handled = true` 가 되어 **아무 일도 안 일어난 세계 위에서 기본 복구 사슬이 건너뛰어진다.**
그래서 타입 오류는 예외가 아니라 **거절**이어야 한다(거절 = 세계 무접촉 = 폴백이 돈다).

🔴 스키마를 **여기서 두 번째로 적지 않는다.** 판정에 쓰는 것은 레지스트리 항목의 `"type"`
그 자체이고, 이 표는 그 문자열을 Julia 타입으로 옮기는 사전일 뿐이다.

⚠️ 판정식은 `convert` 다 — "선언된 타입으로 **변환이 되는가**". `isa` 로 재면 `min_ready`
에 `2.0`(JSON 은 그것을 Float64 로 읽는다)을 준 판이 실제로는 잘 도는데도 거절된다.
"""
const PARAM_JSON_TYPES = Dict{String,Type}(
    "integer" => Integer, "number"  => Real,          "boolean" => Bool,
    "string"  => AbstractString, "array" => AbstractVector,
    "object"  => AbstractDict,   "null"  => Nothing)

"""
    _param_type_reject(spec, v) -> Union{Nothing,String}

레지스트리가 이 param 에 선언한 타입으로 `v` 가 변환되는가. `nothing` 이면 통과, 문자열이면
거절 사유의 꼬리다.

🔴 **선언이 없거나 모르는 타입이면 거절한다.** 통과시키면 값 스키마를 넓히는 레지스트리 편집이
게이트 전부 초록인 채로 호출 표면을 넓힌다(T3 가 parked 한 세 번째 확장 경로, R46). 거절은
세계를 안 건드리므로 그 대가가 폴백 한 번이다.

⚠️ JSON-Schema 의 `["string", "null"]` 같은 **합집합** 선언을 받는다 — 하나라도 변환되면 통과.
"""
function _param_type_reject(spec, v)
    t = try get(spec, "type", nothing) catch; nothing end
    t === nothing && return "no_declared_type"
    ts = String[]
    try
        ts = t isa AbstractVector ? String[String(x) for x in t] : String[String(t)]
    catch
        return "unreadable_declared_type"
    end
    isempty(ts) && return "empty_declared_type"
    for one in ts
        haskey(PARAM_JSON_TYPES, one) || return "unknown_declared_type:$(one)"
    end
    for one in ts
        try
            convert(PARAM_JSON_TYPES[one], v)
            return nothing
        catch
        end
    end
    return "$(join(ts, "|")):got ::$(typeof(v))"
end

"""
    _convert_arg(T, v) -> Any    (던질 수 있다 — 호출자가 거절로 바꾼다)

값 하나를 선언 타입 `T` 로 옮긴다. 기본은 `convert` 그대로다.

🔴 **`AbstractDict` 만 예외다** (2026-09-04 fix round 1, F4). `JSON3.Object` 의 `keytype`
   은 `Symbol` 이라 `convert(Dict{String,Any}, ::JSON3.Object)` 가 **던진다**(`Cannot
   convert an object of type Symbol to an object of type String`). 그런데
   `Dict{String,Any}` 는 이 레포가 도처에서 쓰는 철자이고 모델이 객체 인자에 가장 자연스럽게
   쓸 철자다 — 그대로 두면 **모든 객체 인자가 `reject:param_convert:` 로 막혀** 원시가 영영
   안 돈다(거절이라 안전하지만 채널은 닫힌 것이다). 키를 옮겨 주는 것이 경계의 몫이다.

⚠️ 얕다. `Vector{Dict{String,Any}}` 처럼 **컨테이너 안의** 객체는 여전히 `convert` 가
   던지고 거절이 된다 — 라이브에서 그 철자가 실제로 나오는지 안 쟀으므로 넓히지 않는다
   (안 넓힌 대가는 예외가 아니라 거절이다). 진실원: `test/minted_end_to_end.jl` testset (7).
"""
_convert_arg(T, v) = convert(T, v)
function _convert_arg(T::Type{<:AbstractDict}, v::AbstractDict)
    local K, V = keytype(T), valtype(T)
    local d = Dict{K,V}()
    for k in keys(v)
        d[_dict_key(K, k)] = v[k]
    end
    return convert(T, d)
end

"`Symbol` ↔ `String` 사이에는 `convert` 메서드가 없다 — 생성자를 써야 한다."
_dict_key(::Type{String}, k) = String(k)
_dict_key(::Type{Symbol}, k) = Symbol(k)
_dict_key(::Type{K}, k) where {K} = convert(K, k)

"""
    bind_primitive_args(prim, ctx) -> Union{String, Tuple{Tuple,NamedTuple}}

한 원시의 실제 호출 인자를 만든다. 문자열이면 **거절 사유**다. 순수 함수 — 세계를 안 건드린다.

`ctx` 는 `(env, truth, params)`. `params` 는 합성기가 낸 평평한 스칼라 dict 이다
(`synthesize.py` 가 `params_flat` 으로 제약하고 기록한다).

🔴 **`harness_args` 가 계약이다.** 레지스트리가 `["env"]` 라고 적은 원시는 `env` 를 첫
위치인자로 받는다. 이 표가 없으면 20개 원시의 서로 다른 시그니처를 손으로 두 벌 적게 되고,
그 두 벌은 갈린다 — 이 레포가 이미 세 번 밟은 실패 모양이다.

🔴 **`"env"` 말고는 지원하지 않는다, 그리고 넓히지 않는다.** 실측(2026-08-30): 비-`env`
harness 인자를 쓰는 원시는 넷이고(`invariant` `sched`/`scene_tree` `model,t0,tF,Xa,sched`
`milp,proposal`), 넓혀도 얻는 것이 없다 — `milp` 는 **solve 를 돌려야만** 생기는데 알파벳에
solve 하는 원시가 없다(`formulate_milp`·`optimize!` 는 레지스트리에 없다). 그 사실은
`resolve_primitive` 의 `enactable` 이 들고 다니고, 집행부가 부르기 **전에** 거절한다.

🔴 **이 원시가 선언한 키는 선언한 타입으로 변환돼야 한다** — 아니면 `reject:param_type:…`
이다(근거는 `PARAM_JSON_TYPES` 의 docstring: 타입 오류를 예외로 흘리면 손도 안 댄 세계가
`partial=true → handled=true` 로 기록돼 폴백을 삼킨다). ⚠️ 값의 **범위**(`minimum`/`enum`/
`items`)는 아직 안 본다 — 그것은 R46 이 parked 한 전면 값 스키마 못박기다.

🔴 **모르는 키워드는 여기서 버리지도 거절하지도 않는다.** 합성기는 **tool 하나에 params
dict 하나**를 낸다 — body 가 원시 둘 이상이면 그 키들은 원시들에 흩어져 있다(예:
`{agent, n}` 은 `forbid_heavy_cargo` 의 것이고 `release_pending_assignments` 는 `agent` 만
안다). 그러므로 여기서는 **이 원시가 선언한 키만 골라 넘긴다**. 어느 원시도 모르는 키가
있는지는 `enact_minted!` 가 body 전체를 본 뒤에 판정한다 — 원시 단위로 거절하면 정상 body
가 두 번째 원시에서 죽고, 조용히 버리면 LLM 이 준 인자가 없는 것처럼 집행되면서 결정 행에는
그 인자가 그대로 남아 기록과 세계가 어긋난다.

🔴 **`zone_keys` 는 유도하지 않는다.** 셋 다 실측으로 뒤집힌 유혹이다(2026-08-30):
  (a) 서비스가 존 키를 모델에게 **보여준다** — `dspy_service.py::_zones_block` 이 프롬프트에
      `zone "zone_blk_1"` 을 그대로 렌더한다. 모델은 이 인자를 줄 수 있고 실제로 준다.
  (b) `RESTRICTION_ZONES[]` 는 `Dict{Symbol,Ball2}` 이고 소비자는 전부 `haskey` 로 거른다.
      **String** 키를 그대로 넘기면 조용히 걸러져 `zones == []` 가 되고,
      `translate_whole_build!` 는 Δ=[0,0] · 잔여를 0개 존에 대해 세고 `:already_clear` 를
      돌려준다 = 맞는 답이 "존을 치웠다"는 거짓 증거로 둔갑한다. 그래서 **호출 전에**
      `Symbol` 로 강제하고 살아 있는 존인지 확인한다.
      ⚠️ 그 **강제는 조건부다** — 선언 타입이 있는 원시(= 생성 원시)에는 안 한다.
      살아 있는 존 검사는 무조건 돈다. 근거는 아래 zone 블록의 F2 주석에 한 번만 적는다.
  (c) 유도값은 callee 기본값보다 **좁다** — `restage_all_blocked!`·`translate_whole_build!`
      둘 다 `zone_keys` 를 `collect(keys(RESTRICTION_ZONES[]))` 로 기본한다. 안 주면
      **키워드를 아예 빼서** 그 기본값(= 살아 있는 존 전부)이 그대로 쓰이게 한다.
"""
function bind_primitive_args(prim, ctx)
    pos = Any[]
    for a in prim.harness_args
        if a == "env"
            ctx.env === nothing && return "reject:missing_harness_arg:env"
            push!(pos, ctx.env)
        elseif a == "invariant"
            # `build_invariant(env)` 는 env 의 순수 함수 — 얼린 과거(closed/frozen_t0/tF)를 읽어
            # `InvariantSpec` 을 만들 뿐 세계를 쓰지 않는다. 그래서 바인더가 만들어도 안전하다.
            # 🔴 던지면 거절이지 예외가 아니다: 여기서 새어 나가면 `enact_minted!` 이 기록 대신
            #    예외로 끝나고 호출자는 세계 상태를 알 방법을 잃는다(집행 루프의 같은 논거).
            ctx.env === nothing && return "reject:missing_harness_arg:invariant(env is nothing)"
            local inv
            try
                inv = build_invariant(ctx.env)
            catch e
                return "reject:harness_arg_build_failed:invariant:" *
                       first(split(sprint(showerror, e), "\n"))
            end
            push!(pos, inv)
        else
            # 🔴 도달 불가여야 한다 — `_enactability` 의 연언지 (i) 이 `BINDABLE_HARNESS_ARGS`
            #    밖의 이름을 가진 원시를 **부르기 전에** 거절한다. 그래도 남겨 둔다: 두 자리가
            #    같은 상수를 읽으므로 어긋날 수 없지만, 어긋난다면 거짓 admit 이 아니라 거절로
            #    떨어지는 쪽이 옳다.
            return "reject:unknown_harness_arg:$(a)"
        end
    end
    kw = Dict{Symbol,Any}()
    for (k, v) in ctx.params
        haskey(prim.params, String(k)) || continue
        # 🔴 **타입이 안 맞으면 예외가 아니라 거절이다**(`PARAM_JSON_TYPES` 의 docstring).
        #    안 막으면 호출 경계의 `convert` 실패가 `enact_minted!` 의 `catch` 에서
        #    `partial = true` 로 적히고, 손도 안 댄 세계가 `handled=true` 로 폴백을 삼킨다.
        local bad = _param_type_reject(prim.params[String(k)], v)
        bad === nothing || return "reject:param_type:$(k):$(bad) (원시 $(prim.name))"
        # 🔴 D16 (프로브 P1). Julia 의 **키워드 인자는 `convert` 가 아니라 타입 단언**이다 —
        #    위치인자와 달리 자동 변환이 없다. 그리고 `/decide` 를 거쳐 온 값은 네이티브
        #    컨테이너가 아니라 `JSON3.Array`/`JSON3.Object` 의 **지연 뷰**다. 둘이 겹쳐,
        #    등록이 처음 성공하는 순간 호출이 `TypeError` 로 죽는다(실측). 변환은 우리 몫이다.
        #    🔴 예외가 아니라 거절이다: 여기서 던지면 `enact_minted!` 의 catch 가 손도 안 댄
        #    세계를 `partial=true → handled=true` 로 적어 폴백을 삼킨다.
        #    🔴 삼상이다(`impl_param_types` 의 표가 진실원): 키 없음 = 주석 없음(오늘 그대로
        #    흐른다) · `Type` = 읽었다(변환한다) · `String` = 주석은 있는데 **못 읽었다**.
        #    셋째를 그냥 흘리면 뷰가 그대로 호출에 닿아 `TypeError` 로 죽는다 — 예외라
        #    위의 삼킴이 그대로 난다. 그래서 값이 실제로 온 이 자리에서 거절한다(F3).
        local T = get(prim.param_types, String(k), nothing)
        if T === nothing
            kw[Symbol(k)] = v                 # 주석 없는 키워드는 오늘 그대로 흐른다
        elseif !(T isa Type)
            return "reject:param_annotation_unreadable:$(k):$(T) (원시 $(prim.name))"
        else
            local cv
            try
                cv = _convert_arg(T, v)
            catch
                return "reject:param_convert:$(k):expected $(T), got $(typeof(v)) (원시 $(prim.name))"
            end
            kw[Symbol(k)] = cv
        end
    end
    # zone 계열: 안 주면 키워드를 빼고(= callee 기본값 = 살아 있는 존 전부), 줬으면
    # `Symbol` 로 강제한 뒤 **집행 한 발 전에** 살아 있는 존인지 검사한다. 위 (b) 를 보라.
    if haskey(kw, :zone_keys)
        v = kw[:zone_keys]
        v isa AbstractVector || return "reject:zone_keys_not_a_vector:$(typeof(v))"
        ks = Symbol[Symbol(string(e)) for e in v]
        isempty(ks) && return "reject:empty_zone_keys"    # 🔴 기본값으로 폴백하지 않는다
        live = RESTRICTION_ZONES[]
        for k in ks
            haskey(live, k) || return "reject:unknown_zone_key:$(k):" *
                "live=$(join(sort(String.(string.(collect(keys(live))))), ","))"
        end
        # 🔴 D16 (2026-09-04 fix round 1, F2). 선언 타입이 있으면 **덮어쓰지 않는다.**
        #    생성 원시가 `zone_keys::Array{String,1}` 로 주석하면 위 루프가 이미
        #    `Vector{String}` 을 만들어 놨는데, 이 줄이 무조건 `Vector{Symbol}` 로 되돌리면
        #    호출이 `TypeError: in keyword argument zone_keys, expected Vector{String}, got
        #    Vector{Symbol}` 로 죽는다(실측). 그리고 그것은 거절이 아니라 **예외**라
        #    `enact_minted!` 의 catch 가 손도 안 댄 세계를 `partial=true → handled=true` 로
        #    적어 폴백을 삼킨다 — 이 태스크가 없애려던 바로 그 사건이다.
        #    ⚠️ **비켜서는 것은 대입뿐이다.** 위의 `unknown_zone_key`/`empty_zone_keys`
        #    검사는 선언 타입이 있든 없든 그대로 돈다 — 그 검사는 타입이 아니라 **살아 있는
        #    세계**에 대한 것이고, 건너뛰면 집행부가 없는 존을 만진다.
        #    진실원: `test/minted_end_to_end.jl` testset (12)(음성 대조 포함).
        haskey(prim.param_types, "zone_keys") || (kw[:zone_keys] = ks)
    end
    return (Tuple(pos), NamedTuple(kw))
end

"`synth` 가 String 키 dict(`policy.jl::_synth_view`)든 Symbol 키(`JSON3.Object`·NamedTuple)든 읽는다."
function _synth_get(synth, key::String, default)
    v = get(synth, key, nothing)
    v === nothing && (v = get(synth, Symbol(key), nothing))
    return v === nothing ? default : v
end

"""
    normalize_calls(x) -> Union{Nothing, String, Vector{Tuple{String,Dict{String,Any}}}}

agent-3 의 `calls` 를 읽는다. **삼상이다**: `nothing`(못 쟀다 — 이 필드를 모르는 레인/세대),
`String`(거절 사유), 또는 `(원시이름, 인자dict)` 의 순서 있는 벡터.

🔴 왜 이 필드가 필요한가 (2026-09-03 실측). `params` 는 값이 아니라 **JSON 스키마**로 도착한다
(`{"agent": {"type": "string"}}`) — 집행부가 그것을 값으로 읽으면 원시가 스키마 dict 을 인자로
받는다. 게다가 `params` 는 **도구 하나에 dict 하나**라서 body 가 원시 둘 이상이면 어느 인자가
어느 원시의 것인지 적히지 않는다. `calls` 는 원시마다 자기 인자를 값으로 들고 온다.

🔴 **모양이 틀리면 거절이지 예외가 아니다.** 여기서 예외가 새면 `enact_minted!` 이 기록 대신
예외로 끝나고 호출자는 세계 상태를 알 방법을 잃는다(이 파일이 여러 자리에서 지키는 규약).

🔴 **전부-아니면-전무.** 항목 하나가 안 읽히면 나머지를 살려 쓰지 않는다 — 반쪽 호출열로
집행하면 undo 없는 세계가 모델이 뜻한 적 없는 상태로 남는다.
"""
function normalize_calls(x)
    x === nothing && return nothing
    x isa AbstractVector || return "reject:calls_not_a_list:$(typeof(x))"
    out = Tuple{String,Dict{String,Any}}[]
    for (i, c) in enumerate(x)
        c isa AbstractDict || return "reject:calls_item_not_an_object:$(i):$(typeof(c))"
        local nm = _synth_get(c, "primitive", nothing)
        nm isa AbstractString || return "reject:calls_item_has_no_primitive:$(i)"
        local a = _synth_get(c, "args", Dict{String,Any}())
        a isa AbstractDict || return "reject:calls_args_not_an_object:$(i):$(typeof(a))"
        push!(out, (String(nm), Dict{String,Any}(String(k) => v for (k, v) in pairs(a))))
    end
    return out
end

"""
    _step_status(prim_name, out) -> Symbol

호출 결과에서 status 를 읽는다. 네 갈래다:
 1. 🔴 **맨 `Symbol` 이면 그것이 status 다** (2026-09-03 최종 리뷰 C2).
 2. `status` 필드가 있으면 그것.
 3. `COUNT_RETURN_PRIMITIVES` 이고 `Integer` 면 개수로 읽어 `:moved`/`:moved_none`.
 4. 그 밖 = **모양을 못 읽었다** → `:unreadable_return`(= `applied` 거짓, "못 쟀다").

🔴 **왜 (1) 을 더했나.** 프롬프트가 모델에게 약속하는 반환 모양은 **둘**이다 —
`src/respec/llm_service/world_interface.py` 의 `_RULES` 3: *"Return a value the harness can
read a status from: either a Symbol, or a NamedTuple with a `status::Symbol` field."*
하네스는 뒤엣것만 읽었다. 실측(2026-09-03): 맨 `:did_the_thing` 을 돌려주는 생성 원시가
`status=:unreadable_return` 으로 떨어졌다 — 즉 **합법이라고 가르친 모양의 절반이 영구히
"못 쟀다"** 였다. 판정은 **하네스를 넓히는 쪽**이다(프롬프트를 좁히지 않는다): 맨 Symbol 은
완벽히 읽을 수 있는 status 이고, 이 방향은 잃는 것이 없다.
⚠️ 갈래 순서는 뜻이 없다(`Symbol` 에는 `:status` 프로퍼티가 없다) — 읽는 사람을 위해
약속된 두 모양을 맨 앞에 나란히 둔다.

🔴 필드 접근을 `hasproperty` 로 감싼다 — `restage_all_blocked!` 는 `:none` 일 때만
4-필드가 아니라 **3-필드**를 돌려준다(residual 없음).

🔴 그리고 그 위를 다시 `try` 로 감싼다. `hasproperty` 가 참이어도 `getproperty` 가 던지는
반환값이 있을 수 있고, 그 예외가 여기서 새어 나가면 `enact_minted!` 가 **기록 대신
예외**로 끝난다 — 호출자는 세계가 어떤 상태인지 알 방법이 없어진다. 오늘의 여덟에는
그런 반환이 없다(이 레인이 더한 `forbid_heavy_cargo!` 도 평범한 NamedTuple 리터럴이라
해당 없음을 확인했다) — 그래도 어휘가 다시 늘면 이 위험은 새로 열린다.

🔴 예전 이름 `:no_status_field` 는 **`applied = true`** 로 흘렀다(2026-08-30 리뷰가 잡음).
읽을 수 없는 모양은 "세계가 변했다"가 아니라 "변했는지 모른다"이다.
"""
function _step_status(prim_name, out)
    try
        out isa Symbol && return out          # 🔴 C2 — 프롬프트가 약속한 두 모양 중 하나
        hasproperty(out, :status) && return Symbol(getproperty(out, :status))
        if String(prim_name) in COUNT_RETURN_PRIMITIVES && out isa Integer
            return out > 0 ? :moved : :moved_none
        end
        if String(prim_name) in EDGELIST_RETURN_PRIMITIVES && out isa AbstractVector
            return isempty(out) ? :released_none : :released
        end
        return :unreadable_return
    catch
        return :unreadable_return
    end
end

_brief_val(x) = x isa AbstractVector ? string(length(x)) : string(x)

"단계 기록에 실을 한 줄. 🔴 읽을 수 없는 모양이면 **그 모양을 이름으로 적는다** — 그래야
`applied=false` 가 \"재서 아무 일도 없었다\"가 아니라 \"못 쟀다\"로 읽힌다."
function _step_detail(out, prim_name = "")
    try
        # 🔴 읽을 수 있는 모양을 "unreadable" 이라고 적으면 그것 자체가 기록의 거짓말이다.
        #    `_step_status` 가 `EDGELIST_RETURN_PRIMITIVES` 로 읽어낸 것과 **같은 사실**을
        #    detail 도 읽는다 — 안 그러면 status 는 `:released` 인데 detail 은 "못 읽었다" 가
        #    되어 한 줄 안에서 두 말이 어긋난다(2026-09-01 프로브가 실제로 그 줄을 냈다).
        if String(prim_name) in EDGELIST_RETURN_PRIMITIVES && out isa AbstractVector
            return "released=$(length(out))"
        end
        # 🔴 C2(2026-09-03): 맨 Symbol 은 **읽을 수 있는 모양**이다 — "unreadable" 이라고
        #    적으면 `_step_status` 가 이미 읽어낸 것과 한 줄 안에서 두 말이 어긋난다(바로 위
        #    EDGELIST 갈래와 같은 논거). 상세 필드는 없으므로 `(status = :x,)` 짜리
        #    NamedTuple 이 내는 것과 **같은 빈 문자열**을 낸다 — 정보량이 실제로 같다.
        out isa Symbol && return ""
        hasproperty(out, :status) ||
            return "unreadable return shape ::$(typeof(out))=$(_brief_val(out))"
        return join([string(f, "=", _brief_val(getproperty(out, f)))
                     for f in (:moved, :failed, :removed, :residual, :delta) if hasproperty(out, f)], " ")
    catch e
        return "unreadable return shape ::$(typeof(out)): " *
               first(split(sprint(showerror, e), "\n"))
    end
end

"""
    ENACTED_VERDICTS · minted_handled_verdict_ok(v) -> Bool

`handled` 판정의 **첫 연언지**. 🔴 2026-09-03 (Task 9, 컨트롤러 판정 R1): 집행 계열 verdict 는
다시 **하나** `:admit` 뿐이다. `:admit_unsanctioned`(2026-09-02 결정 2 가 더했던 것)는 모델이
`reach != "composed"` 라고 신고했는데 body 는 조합돼 있어 굴린 행을 가리켰는데, D8 로 agent-3 이
더 이상 인벤토리에서 조합하지 않고 원시 자신을 코드로 쓴다 — "조합에 실패했다고 자기신고했다"
는 구분 자체가 없어졌다. 그 집합의 정본은 바로 아래 `ENACTED_VERDICTS` 하나이고, 소비자가
리터럴 대신 이 이름을 부르므로 그때 **한 자리만** 바뀌었다.

🔴 `handled` 자체는 여기 없다 — 나머지 세 연언지(`world_maybe_dirty` · `resume !== :failed` ·
`!resolve_failed`)는 `tools/monitor/enact.jl` 이 소유한다. 이 함수는 그중 첫째만 답한다.
실측 근거: 손으로 베낀 3-연언지 복사본이 프로덕션 4-연언지와 갈렸다(2026-09-02 T0).
"""
const ENACTED_VERDICTS = (:admit,)
minted_handled_verdict_ok(v::Symbol) = v in ENACTED_VERDICTS

"""
    enact_minted!(env, truth, synth) -> NamedTuple

합성된 tool 의 body 를 집행한다. 반환:
`(verdict, reason, applied, partial, world_maybe_dirty, steps, undo, resume)`. T4 가 읽는다.

| `verdict` | 뜻 |
|---|---|
| `:admit` | body 의 모든 원시가 해석·집행가능·바인딩됐고 **하나도 빠짐없이 불렸다** |
| `:reject` | 아무것도 부르기 **전에** 돌아섰다 — 세계는 손대지 않았다 |
| `:deferred` | 집행할 사건이 아니었다(합성 기록이 없거나 `impl_name` 이 없음 — 못 쟀다) |

🔴 2026-09-03 (Task 9, 컨트롤러 판정 R1): `:admit_unsanctioned` 는 사라졌다. 그것은 "모델이
조합에 실패했다고 신고했는데 body 는 있다" 를 재던 구분인데, D8 로 agent-3 이 인벤토리에서
조합하는 단계 자체가 없어졌다 — `reach`/`missing_primitive` 는 더 이상 경계로 안 건너온다.

`applied` 와 `partial` 은 verdict 와 **다른 것**을 잰다(spec §9-2 — "불렀는데 아무 일도 없었다"
와 "부르지 않았다"는 다른 사건이고 반환값에서 구분돼야 한다):

| 필드 | 뜻 |
|---|---|
| `applied` | **노린 적응이 일어났다** — 불린 단계 중 하나라도 `SILENT_SUCCESS_STATUSES` 에도 `UNMEASURABLE_STATUSES` 에도 없는 status 를 냈다. "세계의 바이트가 변했나"가 **아니다**. 🔴 **삼상이다**(2026-09-03 C1): 생성 원시는 status 어휘를 아는 표가 없어 `nothing`(못 쟀다)이 된다 — `false`(쟀는데 없었다)와 **다른 사건**이고, 성공률을 셀 때 분자에도 분모에도 넣으면 안 된다 |
| `partial` | 어떤 단계가 **던졌다** — 세계는 절반만 고쳐졌을 수 있고 되돌릴 방법이 없다 |
| `world_maybe_dirty` | `touched`(`_step_touched_world`) 또는 `partial` — "세계에 손을 댔을 수 있는가". 다음 태스크가 **이미 더러워진 세계 위에 폴백을 쌓아도 되나**를 이 필드로 정한다. ⚠️ `applied` 가 **아니다**: `translate_whole_build!` 의 `:residual_blocked` 는 `applied=false` 인데 빌드를 이미 옮겼다(2026-08-30 T4 리뷰) |
| `resume` | 스케줄 캐시 재개 판정 다섯 상태: `:issued` · `:failed` · `:not_needed_self` · `:not_needed_untouched` · `:none`(아무것도 안 불렀다). 🔴 여덟 중 다섯이 스스로 재개하지 않아 여기서 대신 부른다 — 안 부르면 세계는 고쳐졌는데 프론티어가 낡아 **성공과 구별되지 않는 미복구**가 된다 |

🔴 세 필드는 **서로 다른 질문**이다. 하나만 읽고 다른 것의 답으로 쓰지 말 것 — 특히
`applied == false` 는 "세계가 안 변했다"가 아니다(던졌을 수도, 못 쟀을 수도 있다).
그래서 파생인 `world_maybe_dirty` 를 굳이 실어 보낸다.

🔴 **`undo` 는 언제나 `:none`.** Plan B 의 C 단계가 이 계획의 범위 밖이므로, body 중간에서
던지면 세계는 절반만 고쳐진 채 남는다. 그 사실을 결과가 들고 다닌다.

🔴 **부르기 전에 전부 검사한다.** 순서는 (1) 삼상 판정 → (2) 빈 body → (3) 이름 전부 해석
→ (4) 집행가능성 전부 확인 → (5) body 전체 기준 미지 인자 판정 → (6) 인자 전부 바인딩
→ (7) 그제야 집행. undo 가 없으므로 부분 집행은 되돌릴 수 없는 손상이다.

⚠️ (5)(미지 인자)를 (6)(바인딩)보다 **앞에** 둔 것은 의도다. 브리핑의 원래 순서는 원시마다
`resolve → bind` 를 붙여 돌았는데, 그러면 `env === nothing` 인 호출에서 첫 원시의
`missing_harness_arg:env` 가 먼저 나와 미지 원시·미지 인자 판정에 **도달하지 못한다**
(브리핑 게이트 (2)·(8) 이 실제로 그것 때문에 통과 불가였다). 세계를 안 건드리는 판정을
세계를 요구하는 판정보다 앞세우는 것이 옳기도 하다 — env 없이도 body 를 심사할 수 있다.
"""
function enact_minted!(env, truth, synth)
    # 🔴 `world_maybe_dirty` 는 파생 필드다(`touched || partial`). 왜 따로 싣는가:
    #    `applied` 는 "노린 적응이 일어났나"만 재고 `partial` 은 "던져서 절반일 수 있나"만
    #    잰다 — 둘 중 하나만 읽은 호출자가 다른 쪽의 답을 얻어 가면 안 된다. 다음 태스크는
    #    "이미 더러워진 세계 위에 폴백을 쌓아도 되나"를 이 필드 하나로 결정한다.
    #
    # 🔴 2026-08-30 T4 리뷰: `applied` 가 아니라 **`touched`**(`_step_touched_world`)로 짓는다.
    #    한 status 가 동시에 "노린 적응은 아니다"이고 "그런데 세계는 이미 옮겼다"일 수 있고
    #    (`translate_whole_build!` 의 `:residual_blocked`), `applied` 로 지으면 그 판이
    #    **"세계가 깨끗하다"고 보고하는 옮겨진 빌드**가 된다. 두 표는 원시마다
    #    `WORLD_UNCHANGED ⊆ SILENT_SUCCESS` 라서 이 변경은 **넓히기만 한다**(applied ⟹ dirty).
    # 🔴 Step 5(2026-09-03). 인자를 **어디서** 묶었는지가 결과에 실린다. 없으면 유료 런의
    #    로그로 "calls 로 값이 도착해 굴렀다" 와 "calls 가 없어 옛 params 경로로 떨어져 인자
    #    없이 굴렀다" 를 구별할 수 없다 — B1 의 목적이 그 구별인데 관측할 창이 없어진다.
    # 🔴 삼상이다. `nothing` 은 "인자가 없다" 가 아니라 **그 판정 자리에 도달 못 했다** 이다
    #    (조기 deferred·거절). `:params` 로 적으면 굴린 적 없는 경로를 굴렸다고 적는 셈이다.
    # 🔴 두 지역변수를 `_r` **앞에** 선언한다 — 클로저가 같은 결속을 보므로 아래에서 값을
    #    정하면 이후의 모든 `_r(...)` 이 자동으로 그것을 싣는다(반환 자리마다 손으로 넘기면
    #    한 자리를 빠뜨리는 순간 그 판만 조용히 `nothing` 이 된다).
    local args_from = nothing
    local n_calls   = nothing
    # 🔴 F6(4)(2026-09-03 최종 리뷰). `applied` 의 기본값은 `nothing` 이지 `false` 가 아니다.
    #    이 함수 안의 조기 반환(`:deferred`·`:reject`, 예: 바로 위 (1)(2))은 `applied=` 를
    #    명시적으로 안 넘기므로 이 기본값을 그대로 받는데, `false` 는 "불렀는데 적응이
    #    없었다"(쟀다)를 뜻해 **아무것도 부르지 않았다**는 사실과 어긋난다 — 세 줄 위
    #    `args_from`/`n_calls` 가 이미 같은 사건에 `nothing`("그 판정 자리에 도달 못
    #    했다")을 쓰고, 그 규약과 맞춘다. Task 9 전에는 `:deferred` 가 사실상 도달 불가
    #    (레지스트리가 항상 값을 실었다)에 가까워 파장이 작았지만, 이제 `impl_name` 결측이
    #    라이브 판에서 실제로 발화하므로 이 결함의 반경이 커졌다 — 지금 고친다.
    _r(v, why; steps = NamedTuple[], applied = nothing, partial = false,
       touched = false, resume = :none, resolve = :none) =
        (verdict = v, reason = why, applied = applied, partial = partial,
         world_maybe_dirty = touched || partial, steps = steps, undo = :none,
         resume = resume, resolve = resolve,
         args_from = args_from, n_calls = n_calls)

    # ---- (1)(2) 집행할 사건인가 ------------------------------------------------------------
    synth === nothing && return _r(:deferred, "no synthesis record")
    # 🔴 2026-09-03 (Task 9, 컨트롤러 판정 R1, **F1 로 원상복구**). 미끼가 `reach` 에서
    #    `impl_name` 으로 옮겨왔다 — agent-3 이 이제 인벤토리에서 조합하는 대신 원시 자신을
    #    코드로 쓴다(D8). `reach` 는 경계 키에서 빠졌으므로(`SYNTH_LANE_KEYS`) 그 자리에
    #    그대로 두면 **모든 집행이 deferred 로 떨어진다.**
    # 🔴 R1 최종(F1 재리뷰): 한때 이 자리를 `impl_name === nothing && isempty(body_names)`
    #    로 완화했었다 — `test/minted_registration.jl` 의 register→enact 단일 프레임 시험
    #    셋이 `impl_name` 없이 `body_names` 만 채운 옛 픽스처였기 때문이다. 그런데 그 완화는
    #    **생산 게이트를, 범위 밖 시험 픽스처를 통과시키려고 넓힌 것**이었고, 아래
    #    `enact_minted_decision!`(`tools/monitor/enact.jl`) 이 "두 게이트는 같은 미끼를
    #    써야 한다" 고 적어 놓고 정작 이 자리만 미끼를 넓히는 자기모순이었다(리뷰 F1).
    #    올바른 수선은 게이트가 아니라 **픽스처**다 — `impl_name` 을 채우면 셋 다 초록이고
    #    (실측), 그 편이 3줄 수정이다. 그래서 게이트를 브리프 원안대로 되돌린다.
    nm = _synth_get(synth, "impl_name", nothing)
    nm === nothing && return _r(:deferred, "impl_name missing — 합성 레인이 값을 안 실었다")
    # 🔴 `sanctioned`/`admit_unsanctioned` 는 사라진다. 그것은 "모델이 조합에 실패했다고
    #    신고했는데 body 는 있다" 를 재던 구분인데, 조합 단계 자체가 없어졌다.
    admit_verdict = :admit

    names = String[String(n) for n in _synth_get(synth, "body_names", String[])]
    isempty(names) && return _r(:reject, "empty body: 조합할 원시가 하나도 없다")

    # ---- (3) 이름을 전부 해석한다 ----------------------------------------------------------
    prims = Any[]
    for n in names
        p = resolve_primitive(n)
        p === nothing && return _r(:reject, "unknown primitive: $(n) — 알파벳 밖이다")
        push!(prims, p)
    end

    # ---- (4) 전부 실제로 부를 수 있는가 ----------------------------------------------------
    # 🔴 여기서 안 막으면 호출 시점 `MethodError` 가 되고, 아래 `try` 가 그것을
    #    `:admit`/집행됨으로 보고한다 = 거절보다 나쁜 거짓 admit.
    for p in prims
        p.enactable || return _r(:reject,
            "reject:unenactable:$(p.name):$(p.unenactable_why) — " *
            "레지스트리는 이 원시를 이름 짓지만 바인더가 만드는 인자로는 부를 수 없다")
    end

    # ---- (4-b) 🔴 B1(2026-09-03): 인자를 어디서 읽을지 정한다 -------------------------------
    # `calls` 가 있으면 **그것이 인자다**(원시마다 값). 없으면(`nothing` = 못 쟀다: 단일 agent
    # 레인에는 이 필드가 아예 없고 낡은 서비스도 마찬가지) 예전처럼 공유 `params` 를 쓴다.
    # 🔴 `calls` 가 있을 때 `params` 는 **읽지 않는다.** 그 자리에 오는 것은 스키마이지 값이
    #    아니고, 둘을 합치면 스키마 조각이 인자로 새어 들어간다.
    calls = normalize_calls(_synth_get(synth, "calls", nothing))
    calls isa String && return _r(:reject, calls)
    if calls !== nothing
        args_from = :calls          # 🔴 **읽은 시점**에 적는다 — 아래 어긋남 거절도 이 사실을
        n_calls   = length(calls)   #    싣고 나가야 "몇 개를 읽고 거절했나" 가 남는다.
    end

    local ctxs::Vector{Any}
    if calls === nothing
        # 🔴 문자열 `params`(= JSON 스키마 원문)는 **거절이지 예외가 아니다.** `pairs("...")` 는
        #    MethodError 이고, 그것이 새면 집행부가 기록 대신 예외로 끝난다(실측 2026-09-03).
        local praw = _synth_get(synth, "params", Dict{String,Any}())
        praw isa AbstractDict || return _r(:reject, "reject:params_not_an_object:$(typeof(praw))")
        params = Dict{String,Any}(String(k) => v for (k, v) in pairs(praw))
        args_from = :params

        # ---- (5) body 전체를 본 뒤에야 "아무도 모르는 인자"를 판정한다 ----------------------
        # 원시 단위로 거절하면 정상 body 가 두 번째 원시에서 죽는다(`bind_primitive_args` 주석).
        # ⚠️ 조용히 버리지 않는 이유: 버리면 LLM 이 준 인자가 없는 것처럼 집행되고, 결정 행에는
        #    그 인자가 그대로 남아 기록과 세계가 어긋난다.
        let known = reduce(union, [Set(keys(p.params)) for p in prims]; init = Set{String}())
            for k in keys(params)
                k in known || return _r(:reject, "arg matches no primitive in body: $(k)")
            end
        end
        ctxs = Any[(env = env, truth = truth, params = params) for _ in prims]
    else
        # 🔴 D2: 어긋나면 거절이다. undo 가 없으므로 어느 쪽이 모델의 뜻인지 모르는 채로
        #    세계를 편집할 수 없다 — 고르는 것보다 안 하는 것이 옳다.
        local cnames = String[c[1] for c in calls]
        cnames == names || return _r(:reject,
            "reject:calls_disagree_with_body: calls=[$(join(cnames, ", "))] " *
            "body=[$(join(names, ", "))]")
        # (5') 호출 단위 미지 인자. `calls` 는 원시마다 스코프가 있으므로 (5) 의 "body 전체
        #      기준" 논거가 여기서는 성립하지 않는다 — 이 원시가 모르는 키는 **그 호출의**
        #      오류다. 공유 dict 이었다면 못 했을 판정이다.
        for (i, (nm, a)) in enumerate(calls)
            for k in keys(a)
                haskey(prims[i].params, k) || return _r(:reject,
                    "reject:arg_matches_no_primitive_in_call:$(k) (원시 $(nm), 호출 $(i))")
            end
        end
        ctxs = Any[(env = env, truth = truth, params = calls[i][2]) for i in eachindex(prims)]
    end

    # ---- (6) 인자를 전부 바인딩한다. 여기까지 통과해야 한 발이라도 집행한다 ------------------
    # 🔴 ctx 가 **호출마다** 다르다(B1). `calls` 가 없으면 위에서 같은 dict 을 n 벌 깔았으므로
    #    옛 동작과 바이트 동일이다 — 바인더 자체는 한 벌 그대로다(타입 검사·zone_keys 강제가
    #    두 경로에서 같은 코드를 지난다).
    resolved = Any[]
    for (i, p) in enumerate(prims)
        b = bind_primitive_args(p, ctxs[i])
        b isa String && return _r(:reject, "$(b) (원시 $(p.name))")
        push!(resolved, (prim = p, args = b))
    end

    # ---- (7) 집행 단계 ---------------------------------------------------------------------
    steps = NamedTuple[]
    # 🔴 삼상이다(2026-09-03 C1). 한 단계도 안 굴린 채 나가는 자리에서는 `false` 가 맞다
    #    (부르지 않았으니 적응도 없었다 — 쟀다). `nothing` 은 **불렀는데 못 쟀다** 뿐이다.
    applied::Union{Bool,Nothing} = false
    touched = false        # 세계에 손을 댔을 수 있는가 (`applied` 와 다른 질문)
    need_resume = false    # 스스로 재개하지 않는 원시가 세계를 건드렸는가
    for (ri, r) in enumerate(resolved)
        local st, dt
        try
            # 🔴 `invokelatest` 다. 생성 원시는 이 호출 **직전**에 `Core.eval` 로 정의되므로
            #    현재 world age 에서는 안 보인다. 맨 호출은 `MethodError` 가 되고 아래 `try`
            #    가 그것을 `:threw`/`partial=true` 로 적어 "세계가 절반일 수 있다" 는 **거짓
            #    기록**을 남긴다 — 세계는 손도 안 댄 상태인데.
            out = Base.invokelatest(r.prim.impl, r.args[1]...; r.args[2]...)
            # 🔴 반환값 읽기도 **이 `try` 안**이다. 밖에 두면 `getproperty` 가 던지는 반환값
            #    하나가 `enact_minted!` 를 기록 대신 예외로 끝내고, 호출자는 세계 상태를
            #    알 방법을 잃는다(`_step_status` 의 같은 날짜 주석).
            st = _step_status(r.prim.name, out)
            dt = _step_detail(out, r.prim.name)
        catch e
            push!(steps, (name = r.prim.name, status = :threw,
                          detail = first(split(sprint(showerror, e), "\n"))))
            # 🔴 던진 지점에서 멈춘다. 앞의 원시들은 이미 세계를 바꿨을 수 있고 undo 는 없다 —
            #    그래서 `partial = true` 다. `applied` 는 status 로만 판정하므로 여기서
            #    올리지 않는다: 던진 단계는 status 를 낸 적이 없다. 세계가 어떤 상태인지는
            #    `partial` 이 "모른다, 절반일 수 있다"로 말한다.
            #
            # 🔴 프론티어도 낡았을 수 있다. 던진 단계가 **무엇을 하다 던졌는지 모르므로**
            #    보수적으로 재개가 필요하다고 본다 — 반쯤 편집된 그래프 위에 옛 프론티어를
            #    남겨 두는 것이 이 자리의 최악이다(`ood_injection.jl`: "그래프는 바뀌었는데
            #    캐시가 옛 프론티어를 들고 있어 복구가 아무 효과가 없다, 예외는 안 난다").
            local rs_t, rs_d = _issue_resume!(env)
            # 🔴 던진 판에서도 재풀이는 **돈다**. 앞선 원시가 이미 배정 간선을 뗐을 수 있고,
            #    그 세계를 다시 안 풀면 정확히 판정 1 이 막으려는 사고(아무도 재배정하지 않은
            #    채 handled=true)가 절반쯤 편집된 세계 위에서 일어난다. 실패하면 그 사실이
            #    `resolve` 로 나가고 `handled` 가 false 가 되어 폴백이 돈다.
            #    ⚠️ 표면 판정은 **던지기 전까지 실제로 굴린 것들** 기준이다 — 던진 단계가
            #    무엇을 했는지는 모르므로 그 단계 자신도 포함한다(보수적).
            local rv_t, rv_d = _resolve_if_needed!(env, resolved[1:ri])
            return _r(admit_verdict, "body threw at $(r.prim.name) — 세계는 절반만 고쳐졌을 수 있다(undo 없음)" *
                              _resume_note(rs_t, rs_d) * _resolve_note(rv_t, rv_d);
                      steps = steps, applied = applied, partial = true,
                      touched = touched, resume = rs_t, resolve = rv_t)
        end
        # 🔴 `|=` 가 아니라 Kleene 선언이다 — `nothing` 이 오면 `|=` 는 MethodError 다.
        applied = _merge_applied(applied, _step_applied(r.prim.name, st))
        touched |= _step_touched_world(r.prim.name, st)
        need_resume |= _needs_cache_resume(r.prim.name, st)
        push!(steps, (name = r.prim.name, status = st, detail = dt))
    end

    # ---- (8) 스케줄 캐시 재개 — 조용한 미복구를 막는 한 걸음 --------------------------------
    # 🔴 여덟 중 다섯(`reform_stuck_teams!` · `recover_stalled_teams!` ·
    #    `force_advance_stuck_carrier!` · `forbid_heavy_cargo!` ·
    #    `release_pending_assignments!`)은 스스로
    #    `reset_cache_resume!` 를 부르지 않는다.
    #    그 사실을 모르고 `handled=true` 로 기본 복구 사슬을 건너뛰면, 세계는 고쳤는데
    #    프론티어가 낡은 채 남고 사건은 **이미 소비돼** 다시 오지 않는다 = 성공과 구별되지
    #    않는 미복구. 자세한 근거는 `PRIMITIVE_RESUMES_CACHE` 의 docstring 에 있다.
    resume_tag, resume_detail = need_resume ? _issue_resume!(env) :
        (touched ? (:not_needed_self, "") : (:not_needed_untouched, ""))
    # 🔴 삼상을 삼상으로 찍는다(2026-09-03 C1). "적응 안 했다" 와 "적응했는지 못 쟀다" 를
    #    한 문장으로 접으면, 생성 어휘 전체가 전자로 보이거나 후자로 보인다.
    local status_list = join(String.(string.([s.status for s in steps])), ",")
    quiet = applied === true ? "" :
            applied === false ?
        " — 🔴 불렸지만 어느 단계도 세계를 적응시키지 않았다(status: " * status_list * ")" :
        " — 🔴 적응이 일어났는지 **못 쟀다**: 생성 원시의 status 어휘가 선언돼 있지 않다" *
        "(status: " * status_list * ")"
    # ---- (9) 공통 MILP 재풀이 — 프롬프트의 약속을 참으로 만든다 (판정 1, 2026-09-02) --------
    # 🔴 재개 **뒤에** 부른다. 재개의 다섯 상태는 이미 게이트가 걸린 계약이고, 그 판정을
    #    재풀이가 밀어내면 안 된다. 재풀이 자신의 `commit_respec!(…; resume=true)` 는 그 위에서
    #    멱등이다(`_issue_resume!` 의 멱등성 문단).
    resolve_tag, resolve_detail = _resolve_if_needed!(env, resolved)
    return _r(admit_verdict, "body of $(length(names)) primitives$(quiet)" *
                      _resume_note(resume_tag, resume_detail) *
                      _resolve_note(resolve_tag, resolve_detail);
              steps = steps, applied = applied, touched = touched,
              resume = resume_tag, resolve = resolve_tag)
end
