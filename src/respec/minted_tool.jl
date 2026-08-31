# =============================================================================
# 합성된 tool 의 집행. (2026-08-30, T2·T3 / spec §3-1, §5)
#
# LLM 은 **코드를 생성하지 않는다.** 기존 원시의 호출 시퀀스만 조합한다. 이 파일은 그
# 시퀀스를 받아 `primitive_registry.json` 을 통해 실제 CB 함수로 해석하고 집행한다.
#
# 🔴 알파벳은 레지스트리이지 CB 의 심볼 표가 아니다. `isdefined(CB, Symbol(name))` 로
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

const _PRIM_TABLE = Ref{Union{Nothing,Dict{String,Any}}}(nothing)

_primitive_registry_path() = get(ENV, "PRIMITIVE_REGISTRY",
    normpath(joinpath(@__DIR__, "..", "..", "wm4spacecraft_manufacturing",
                      "core", "primitive_registry.json")))

"내부용. 테스트가 경로를 갈아 끼운 뒤 캐시를 비우는 자리."
_reset_primitive_table!() = (_PRIM_TABLE[] = nothing; nothing)

"""
    PRIMITIVE_TABLE() -> Dict{String,Any}

`name => 레지스트리 항목` 표. 첫 호출에 읽고 캐시한다.

🔴 파일이 없으면 **던진다.** 빈 표를 돌려주면 모든 body 가 "미지 원시"로 보이고 원인이
레지스트리 부재라는 사실이 기록에서 사라진다 — `action_registry.jl` 과 같은 규약.
"""
function PRIMITIVE_TABLE()
    _PRIM_TABLE[] === nothing || return _PRIM_TABLE[]
    path = _primitive_registry_path()
    isfile(path) || error("primitive_registry 를 못 찾았다: $(path). " *
                          "PRIMITIVE_REGISTRY 로 경로를 줄 수 있다.")
    reg = JSON3.read(read(path, String))
    tbl = Dict{String,Any}()
    for p in reg["primitives"]
        tbl[String(p["name"])] = p
    end
    _PRIM_TABLE[] = tbl
    return tbl
end

"""
    resolve_primitive(name) -> Union{Nothing,NamedTuple}

원시 이름 하나를 해석한다. 레지스트리에 **없으면 `nothing`** 이다 — 조용히 통과시키지
않는다. 있으면 `(name, impl, surface, harness_args, params, reversible, enactable,
unenactable_why)`.

🔴 `enactable` 은 "이 원시를 `bind_primitive_args` 가 만드는 인자로 **실제로 부를 수
있는가**"다(연언지 셋은 `_enactability` 를 보라). 오늘 레지스트리 19 중 **6** 만 참이다.
집행부는 이것이 거짓인 원시를 **부르기 전에** 거절한다 — 부르면 `MethodError` 가 나고
`try` 가 그것을 "집행됐다"로 보고해서 거짓 admit 이 된다.
"""
function resolve_primitive(name::AbstractString)
    tbl = PRIMITIVE_TABLE()
    haskey(tbl, String(name)) || return nothing
    p = tbl[String(name)]
    sym = Symbol(String(p["impl"]))
    isdefined(@__MODULE__, sym) || error(
        "레지스트리가 이름 짓는 impl 이 CB 에 없다: $(p["impl"]) (원시 $(name)). " *
        "test/primitive_registry_resolves.jl 이 이걸 잡았어야 한다.")
    f = getfield(@__MODULE__, sym)
    f isa Function || error("$(p["impl"]) 이 callable 이 아니다 (원시 $(name))")
    harness = String[String(a) for a in get(p, "harness_args", [])]
    prms    = Dict{String,Any}(String(k) => v for (k, v) in pairs(get(p, "params", Dict())))
    en, why = _enactability(f, harness, prms)
    return (name           = String(name),
            impl           = f,
            surface        = String(p["surface"]),
            harness_args   = harness,
            params         = prms,
            reversible     = Bool(get(p, "reversible", false)),
            enactable      = en,
            unenactable_why = why)
end

"""
    _enactability(impl, harness_args, params) -> (Bool, Symbol)

이 원시를 `bind_primitive_args` 가 만드는 인자로 **실제로 부를 수 있는가**. `false` 면
둘째 값이 어느 연언지가 깨졌는지 말한다(`:harness`/`:multimethod`/`:arity`/`:kwargs`).
통과하면 `(true, :ok)`.

🔴 연언지는 **셋**이다. `harness_args ⊆ {"env"}` 하나만 보면(2026-08-30 실측) 19 중 15 가
집행 가능으로 표시되는데 실제로 부를 수 있는 것은 **6** 뿐이다. 나머지 9 는 호출 시점에
`MethodError` 로 죽고, 집행부의 `try` 는 그것을 `:admit`/집행됨으로 보고한다 — 거절보다
나쁘다(거짓 admit). 그래서 부르기 전에 시그니처를 직접 읽는다:

  (i)   `harness_args` 가 전부 `"env"` 여야 한다. 바인더가 아는 harness 인자는 `env` 하나다
        (`bind_primitive_args` 의 같은 날짜 주석 — `milp`·`proposal` 은 **solve 를 돌려야만**
        공급되는데 알파벳에 solve 하는 원시가 없다). 빈 `harness_args` 는 이 절을 공짜로
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
    all(a == "env" for a in harness_args) || return (false, :harness)
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
`applied` 판정이 이 표 하나만 본다. 🔴 키는 **집행 가능한 원시 여섯 전부**여야 한다 —
게이트 (11) 이 `keys(SILENT_SUCCESS_STATUSES) == ENACTABLE_TODAY` 를 못 박으므로,
어휘에 집행 가능한 원시가 하나 늘면 이 표를 채우기 전까지 빨갛다.

🔴 이 표가 없거나 비면 조용한 폴백이 된다. 처음 이 표를 둘만 채웠을 때(2026-08-30 리뷰가
잡음) **집행 가능한 여섯 중 넷**이 아무 일도 안 하고 `applied = true` 를 냈다 — 그중
`force_advance_stuck_carrier!` 는 `CARRIER_RESCUE != "1"`, 즉 **기본 환경**에서 항상
`:disabled` 다. 손 안 댄 환경의 매 런이 "적응했다"로 기록됐을 것이다.

출처 — 여섯 원시의 `return` 문을 전부 읽어서 적었다(추측 없음):
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
    UNMEASURABLE_STATUSES

"불렸는데 **무슨 일이 났는지 읽을 수 없었다**"를 뜻하는 status 들. 🔴 이것은 절대
`applied = true` 가 아니다 — 모양을 못 읽었다는 것은 세계가 변했는지 **모른다**는 뜻이고,
모르는 것을 "적응했다"로 기록하면 결정 행이 거짓말을 한다. 표에 없는 원시/상태의 보수적
기본값(참)보다 이쪽이 먼저다.
"""
const UNMEASURABLE_STATUSES = Set{Symbol}([:unreadable_return])

"""
    _step_applied(prim_name, status) -> Bool

한 단계에서 **노린 적응이 일어났는가**. 판정 순서는 셋이다:
 1. `UNMEASURABLE_STATUSES` — 못 쟀다 → **거짓**(모르는 것을 성공으로 세지 않는다).
 2. `SILENT_SUCCESS_STATUSES` — 조용한 성공 → 거짓.
 3. 그 외 → 참(보수적). ⚠️ 집행 가능한 원시 여섯은 게이트 (11) 이 (2)의 표에 전부 있음을
    강제하므로, 이 기본값은 그 여섯에 대해서는 **도달할 수 없는 자리**다. 미래에 어휘가
    늘면 표가 비어 있는 동안 게이트가 먼저 빨개진다.
"""
_step_applied(prim_name::AbstractString, status::Symbol) =
    status in UNMEASURABLE_STATUSES ? false :
    !(status in get(SILENT_SUCCESS_STATUSES, String(prim_name), Set{Symbol}()))

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
되는가**이고, 그 질문에 대해 진행 메모는 무관하다. 🔴 키는 **집행 가능한 원시 여섯 전부**여야 한다(게이트가 `keys(...) ==
ENACTABLE_TODAY` 를 못 박는다).

🔴 **왜 `SILENT_SUCCESS_STATUSES` 와 별개의 표인가** (2026-08-30 T4 리뷰).
한 status 가 동시에 "노린 적응은 안 일어났다"이고 "그런데 세계는 이미 건드렸다"일 수 있다.
표 하나로는 그 둘을 못 나른다. 실제 사고: `translate_whole_build!` 의 `:residual_blocked` 는
`_apply_uniform_translation!` 이 **이미 빌드를 통째로 옮긴 뒤**에 나오는 상태인데, 표가 하나뿐일
때 `applied=false → partial=false → world_maybe_dirty=false` 가 되어 **"세계가 깨끗하다"고
보고하는 옮겨진 빌드**가 됐다. 오늘은 로그의 거짓말이지만(`macro_to_proposal` 에 zone 분기가
없어 폴백이 이중 편집을 못 한다), zone 매크로가 어휘로 돌아오는 순간 그것이 **제어 흐름**이 된다.

🔴 **불변식: 원시마다 `WORLD_UNCHANGED ⊆ SILENT_SUCCESS`.** 세계를 안 건드렸으면 노린 적응도
당연히 안 일어났다. 이 포함이 `applied ⟹ world_maybe_dirty` 를 보장하고, T4 의
`handled = (:admit) && world_maybe_dirty` 가 `applied` 판정보다 **넓다**는 성질을 준다.
게이트가 여섯 전부에 대해 이 포함을 잰다.

출처 — 여섯 원시의 소스에서 "첫 세계 편집 전에 돌아서는가"를 읽어서 적었다(추측 없음):
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
"""
const WORLD_UNCHANGED_STATUSES = Dict{String,Set{Symbol}}(
    "restage_all_blocked"         => Set([:none, :infeasible]),
    "translate_whole_build"       => Set([:no_staging, :infeasible]),
    "force_advance_stuck_carrier" => Set([:disabled, :no_carrier]),
    "recover_stalled_teams"       => Set([:no_team, :stuck, :disabled, :no_carrier]),
    "resolve_schedule_wedge"      => Set([:not_applicable, :no_wedge]),
    "reform_stuck_teams"          => Set([:moved_none]),
)

"""
    _step_touched_world(prim_name, status) -> Bool

한 단계가 **세계에 손을 댔을 수 있는가**. `_step_applied` 와 판정 순서가 **일부러 다르다**:

 1. `UNMEASURABLE_STATUSES` — 못 쟀다 → 🔴 **참**(보수적). `_step_applied` 는 같은 자리에서
    거짓을 낸다. 비대칭이 옳다: 반환 모양을 못 읽었다는 것은 "적응했다고 셀 수 없다"인
    동시에 "세계가 깨끗하다고 말할 수도 없다"이다. 두 질문의 안전한 답이 반대편이다.
 2. `WORLD_UNCHANGED_STATUSES` 에 있으면 거짓.
 3. 그 외 → 참(보수적).
"""
_step_touched_world(prim_name::AbstractString, status::Symbol) =
    status in UNMEASURABLE_STATUSES ? true :
    !(status in get(WORLD_UNCHANGED_STATUSES, String(prim_name), Set{Symbol}()))

"""
    PRIMITIVE_RESUMES_CACHE

원시가 세계를 고친 뒤 **스스로 `reset_cache_resume!` 를 부르는가**. 🔴 키는 집행 가능한
원시 여섯 전부여야 한다(게이트가 `keys(...) == ENACTABLE_TODAY` 를 못 박는다).

🔴 **왜 이 표가 필요한가** (2026-08-30 T4 리뷰, CRITICAL).
`enact_minted!` 은 `r.prim.impl(env)` 를 **날것으로** 부른다. 여섯 중 셋은 스케줄 캐시를
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
"""
const PRIMITIVE_RESUMES_CACHE = Dict{String,Bool}(
    "restage_all_blocked"         => true,
    "translate_whole_build"       => true,
    "resolve_schedule_wedge"      => true,
    "reform_stuck_teams"          => false,
    "recover_stalled_teams"       => false,
    "force_advance_stuck_carrier" => false,
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
집행 가능한 여섯이 실제로 받는 타입 있는 키워드는 셋이다
(`reform_stuck_teams!(env; min_ready::Int, snap_all::Bool)` ·
`force_advance_stuck_carrier!(env; tol::Float64)`). LLM 이 `{"snap_all": "true"}` 나
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
    bind_primitive_args(prim, ctx) -> Union{String, Tuple{Tuple,NamedTuple}}

한 원시의 실제 호출 인자를 만든다. 문자열이면 **거절 사유**다. 순수 함수 — 세계를 안 건드린다.

`ctx` 는 `(env, truth, params)`. `params` 는 합성기가 낸 평평한 스칼라 dict 이다
(`synthesize.py` 가 `params_flat` 으로 제약하고 기록한다).

🔴 **`harness_args` 가 계약이다.** 레지스트리가 `["env"]` 라고 적은 원시는 `env` 를 첫
위치인자로 받는다. 이 표가 없으면 19개 원시의 서로 다른 시그니처를 손으로 두 벌 적게 되고,
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
`{agent, light_bias}` 는 `reprice_agent_by_payload` 의 것이고 `commit_respec` 은 둘 다
모른다). 그러므로 여기서는 **이 원시가 선언한 키만 골라 넘긴다**. 어느 원시도 모르는 키가
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
        else
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
        kw[Symbol(k)] = v
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
        kw[:zone_keys] = ks
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
    _step_status(prim_name, out) -> Symbol

호출 결과에서 status 를 읽는다. 세 갈래다:
 1. `status` 필드가 있으면 그것.
 2. `COUNT_RETURN_PRIMITIVES` 이고 `Integer` 면 개수로 읽어 `:moved`/`:moved_none`.
 3. 그 밖 = **모양을 못 읽었다** → `:unreadable_return`(= `applied` 거짓, "못 쟀다").

🔴 필드 접근을 `hasproperty` 로 감싼다 — `restage_all_blocked!` 는 `:none` 일 때만
4-필드가 아니라 **3-필드**를 돌려준다(residual 없음).

🔴 그리고 그 위를 다시 `try` 로 감싼다. `hasproperty` 가 참이어도 `getproperty` 가 던지는
반환값이 있을 수 있고, 그 예외가 여기서 새어 나가면 `enact_minted!` 가 **기록 대신
예외**로 끝난다 — 호출자는 세계가 어떤 상태인지 알 방법이 없어진다. 오늘의 여섯에는
그런 반환이 없지만 이 계획의 뒤 태스크가 어휘에 원시를 하나 더한다.

🔴 예전 이름 `:no_status_field` 는 **`applied = true`** 로 흘렀다(2026-08-30 리뷰가 잡음).
읽을 수 없는 모양은 "세계가 변했다"가 아니라 "변했는지 모른다"이다.
"""
function _step_status(prim_name, out)
    try
        hasproperty(out, :status) && return Symbol(getproperty(out, :status))
        if String(prim_name) in COUNT_RETURN_PRIMITIVES && out isa Integer
            return out > 0 ? :moved : :moved_none
        end
        return :unreadable_return
    catch
        return :unreadable_return
    end
end

_brief_val(x) = x isa AbstractVector ? string(length(x)) : string(x)

"단계 기록에 실을 한 줄. 🔴 읽을 수 없는 모양이면 **그 모양을 이름으로 적는다** — 그래야
`applied=false` 가 \"재서 아무 일도 없었다\"가 아니라 \"못 쟀다\"로 읽힌다."
function _step_detail(out)
    try
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
    enact_minted!(env, truth, synth) -> NamedTuple

합성된 tool 의 body 를 집행한다. 반환:
`(verdict, reason, applied, partial, world_maybe_dirty, steps, undo, resume)`. T4 가 읽는다.

| `verdict` | 뜻 |
|---|---|
| `:admit` | body 의 모든 원시가 해석·집행가능·바인딩됐고 **하나도 빠짐없이 불렸다** |
| `:reject` | 아무것도 부르기 **전에** 돌아섰다 — 세계는 손대지 않았다 |
| `:deferred` | 집행할 사건이 아니었다(`reach != "composed"`, 합성 기록 없음) |

`applied` 와 `partial` 은 verdict 와 **다른 것**을 잰다(spec §9-2 — "불렀는데 아무 일도 없었다"
와 "부르지 않았다"는 다른 사건이고 반환값에서 구분돼야 한다):

| 필드 | 뜻 |
|---|---|
| `applied` | **노린 적응이 일어났다** — 불린 단계 중 하나라도 `SILENT_SUCCESS_STATUSES` 에도 `UNMEASURABLE_STATUSES` 에도 없는 status 를 냈다. "세계의 바이트가 변했나"가 **아니다** |
| `partial` | 어떤 단계가 **던졌다** — 세계는 절반만 고쳐졌을 수 있고 되돌릴 방법이 없다 |
| `world_maybe_dirty` | `touched`(`_step_touched_world`) 또는 `partial` — "세계에 손을 댔을 수 있는가". 다음 태스크가 **이미 더러워진 세계 위에 폴백을 쌓아도 되나**를 이 필드로 정한다. ⚠️ `applied` 가 **아니다**: `translate_whole_build!` 의 `:residual_blocked` 는 `applied=false` 인데 빌드를 이미 옮겼다(2026-08-30 T4 리뷰) |
| `resume` | 스케줄 캐시 재개 판정 다섯 상태: `:issued` · `:failed` · `:not_needed_self` · `:not_needed_untouched` · `:none`(아무것도 안 불렀다). 🔴 여섯 중 셋이 스스로 재개하지 않아 여기서 대신 부른다 — 안 부르면 세계는 고쳐졌는데 프론티어가 낡아 **성공과 구별되지 않는 미복구**가 된다 |

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
    _r(v, why; steps = NamedTuple[], applied = false, partial = false,
       touched = false, resume = :none) =
        (verdict = v, reason = why, applied = applied, partial = partial,
         world_maybe_dirty = touched || partial, steps = steps, undo = :none,
         resume = resume)

    # ---- (1)(2) 집행할 사건인가 ------------------------------------------------------------
    synth === nothing && return _r(:deferred, "no synthesis record")
    reach = _synth_get(synth, "reach", nothing)
    reach == "composed" || return _r(:deferred,
        "reach=$(reach === nothing ? "nothing" : reach) — needs_primitive/미측정은 집행하지 않는다")

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

    params = Dict{String,Any}(String(k) => v for (k, v) in pairs(_synth_get(synth, "params", Dict())))

    # ---- (5) body 전체를 본 뒤에야 "아무도 모르는 인자"를 판정한다 --------------------------
    # 원시 단위로 거절하면 정상 body 가 두 번째 원시에서 죽는다(`bind_primitive_args` 주석).
    # ⚠️ 조용히 버리지 않는 이유: 버리면 LLM 이 준 인자가 없는 것처럼 집행되고, 결정 행에는
    #    그 인자가 그대로 남아 기록과 세계가 어긋난다.
    let known = reduce(union, [Set(keys(p.params)) for p in prims]; init = Set{String}())
        for k in keys(params)
            k in known || return _r(:reject, "arg matches no primitive in body: $(k)")
        end
    end

    # ---- (6) 인자를 전부 바인딩한다. 여기까지 통과해야 한 발이라도 집행한다 ------------------
    ctx = (env = env, truth = truth, params = params)
    resolved = Any[]
    for p in prims
        b = bind_primitive_args(p, ctx)
        b isa String && return _r(:reject, "$(b) (원시 $(p.name))")
        push!(resolved, (prim = p, args = b))
    end

    # ---- (7) 집행 단계 ---------------------------------------------------------------------
    steps = NamedTuple[]
    applied = false
    touched = false        # 세계에 손을 댔을 수 있는가 (`applied` 와 다른 질문)
    need_resume = false    # 스스로 재개하지 않는 원시가 세계를 건드렸는가
    for r in resolved
        local st, dt
        try
            out = r.prim.impl(r.args[1]...; r.args[2]...)
            # 🔴 반환값 읽기도 **이 `try` 안**이다. 밖에 두면 `getproperty` 가 던지는 반환값
            #    하나가 `enact_minted!` 를 기록 대신 예외로 끝내고, 호출자는 세계 상태를
            #    알 방법을 잃는다(`_step_status` 의 같은 날짜 주석).
            st = _step_status(r.prim.name, out)
            dt = _step_detail(out)
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
            return _r(:admit, "body threw at $(r.prim.name) — 세계는 절반만 고쳐졌을 수 있다(undo 없음)" *
                              _resume_note(rs_t, rs_d);
                      steps = steps, applied = applied, partial = true,
                      touched = touched, resume = rs_t)
        end
        applied |= _step_applied(r.prim.name, st)
        touched |= _step_touched_world(r.prim.name, st)
        need_resume |= _needs_cache_resume(r.prim.name, st)
        push!(steps, (name = r.prim.name, status = st, detail = dt))
    end

    # ---- (8) 스케줄 캐시 재개 — 조용한 미복구를 막는 한 걸음 --------------------------------
    # 🔴 여섯 중 셋(`reform_stuck_teams!` · `recover_stalled_teams!` ·
    #    `force_advance_stuck_carrier!`)은 스스로 `reset_cache_resume!` 를 부르지 않는다.
    #    그 사실을 모르고 `handled=true` 로 기본 복구 사슬을 건너뛰면, 세계는 고쳤는데
    #    프론티어가 낡은 채 남고 사건은 **이미 소비돼** 다시 오지 않는다 = 성공과 구별되지
    #    않는 미복구. 자세한 근거는 `PRIMITIVE_RESUMES_CACHE` 의 docstring 에 있다.
    resume_tag, resume_detail = need_resume ? _issue_resume!(env) :
        (touched ? (:not_needed_self, "") : (:not_needed_untouched, ""))
    quiet = applied ? "" :
        " — 🔴 불렸지만 어느 단계도 세계를 적응시키지 않았다(status: " *
        join(String.(string.([s.status for s in steps])), ",") * ")"
    return _r(:admit, "body of $(length(names)) primitives$(quiet)" *
                      _resume_note(resume_tag, resume_detail);
              steps = steps, applied = applied, touched = touched, resume = resume_tag)
end
