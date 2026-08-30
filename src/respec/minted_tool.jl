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

원시가 **성공 계열 상태를 돌려주면서 그 tool 이 노린 적응은 일으키지 않은** 경우들.
`applied` 판정이 이 표 하나만 본다.

🔴 이 표가 없으면 조용한 폴백이 된다. 실측(2026-08-30): 존이 이미 비어 있으면
`translate_whole_build!` 는 Δ=[0,0] 을 계산하고 `:already_clear` 를 돌려주는데, 그 함수의
주석은 호출자에게 이것을 "성공"으로 취급하라고 적는다 — 그대로 `applied = true` 로 실으면
**바이트 단위로 동일한 세계**가 "존을 치웠다"는 증거로 결정 행에 남는다.

출처(둘 다 `src/respec/restage_zone.jl` 의 docstring 과 status 삼항식에서 그대로 옮겼다):
  · `restage_all_blocked!`   → `:none`(막힌 조립체가 없다) `:infeasible`(하나도 못 놓았다)
                                `:residual_blocked`(옮길 수 없는 목표가 존 안에 남았다)
  · `translate_whole_build!` → `:no_staging`(적치원이 없다) `:infeasible`(갈 곳이 없다)
                                `:already_clear`(Δ=0, 이미 비어 있었다)
                                `:residual_blocked`(옮겼는데도 존이 안 비었다)
  평범한 성공은 `:partial`/`:restaged_all` 과 `:translated` 뿐이다.

⚠️ `translate_whole_build!` 의 `:residual_blocked` 는 **빌드를 실제로 옮긴다** — 세계는
   변했다. 그런데도 여기 있는 이유는 `applied` 가 "세계의 바이트가 변했나"가 아니라
   "이 tool 이 노린 적응이 일어났나"를 재기 때문이다. 세밀한 사실은 잃지 않는다:
   그 단계의 실제 status 가 `steps` 에 그대로 실린다.
"""
const SILENT_SUCCESS_STATUSES = Dict{String,Set{Symbol}}(
    "restage_all_blocked"   => Set([:none, :infeasible, :residual_blocked]),
    "translate_whole_build" => Set([:no_staging, :infeasible, :already_clear, :residual_blocked]),
)

"""
    _step_applied(prim_name, status) -> Bool

한 단계가 "무언가 했다"고 셀 수 있는가. `SILENT_SUCCESS_STATUSES` 에 적힌 상태만 거짓이다.

🔴 표에 없는 원시·상태는 **참**이다(보수적). 모르는 것을 "아무 일도 안 했다"로 세면
집행이 조용히 없던 일이 된다 — 이 파일이 막으려는 바로 그 실패 모양이다.
"""
_step_applied(prim_name::AbstractString, status::Symbol) =
    !(status in get(SILENT_SUCCESS_STATUSES, String(prim_name), Set{Symbol}()))

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
        haskey(prim.params, String(k)) && (kw[Symbol(k)] = v)
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

"호출 결과에서 status 를 읽는다. 🔴 필드 접근을 `hasproperty` 로 감싼다 — `restage_all_blocked!`
는 `:none` 일 때만 4-필드가 아니라 **3-필드**를 돌려준다(residual 없음). 맨손으로 만지면
그 자리에서 던지고, 집행부의 `try` 가 그 예외를 `:admit`/집행됨으로 보고한다."
_step_status(out) = hasproperty(out, :status) ? Symbol(getproperty(out, :status)) : :no_status_field

_brief_val(x) = x isa AbstractVector ? string(length(x)) : string(x)
_step_detail(out) = join([string(f, "=", _brief_val(getproperty(out, f)))
                          for f in (:moved, :failed, :residual, :delta) if hasproperty(out, f)], " ")

"""
    enact_minted!(env, truth, synth) -> NamedTuple

합성된 tool 의 body 를 집행한다. 반환:
`(verdict, reason, applied, partial, steps, undo)`. T4 가 읽는다.

| `verdict` | 뜻 |
|---|---|
| `:admit` | body 의 모든 원시가 해석·집행가능·바인딩됐고 **하나도 빠짐없이 불렸다** |
| `:reject` | 아무것도 부르기 **전에** 돌아섰다 — 세계는 손대지 않았다 |
| `:deferred` | 집행할 사건이 아니었다(`reach != "composed"`, 합성 기록 없음) |

`applied` 와 `partial` 은 verdict 와 **다른 것**을 잰다(spec §9-2 — "불렀는데 아무 일도 없었다"
와 "부르지 않았다"는 다른 사건이고 반환값에서 구분돼야 한다):

| 필드 | 참일 때 |
|---|---|
| `applied` | 불린 단계 중 **하나라도** `SILENT_SUCCESS_STATUSES` 밖의 status 를 냈다 |
| `partial` | 어떤 단계가 **던졌다** — 세계는 절반만 고쳐졌을 수 있고 되돌릴 방법이 없다 |

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
    _r(v, why; steps = NamedTuple[], applied = false, partial = false) =
        (verdict = v, reason = why, applied = applied, partial = partial,
         steps = steps, undo = :none)

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
    for r in resolved
        local out
        try
            out = r.prim.impl(r.args[1]...; r.args[2]...)
        catch e
            push!(steps, (name = r.prim.name, status = :threw,
                          detail = first(split(sprint(showerror, e), "\n"))))
            # 🔴 던진 지점에서 멈춘다. 앞의 원시들은 이미 세계를 바꿨을 수 있고 undo 는 없다 —
            #    그래서 `partial = true` 다. `applied` 는 status 로만 판정하므로 여기서
            #    올리지 않는다: 던진 단계는 status 를 낸 적이 없다. 세계가 어떤 상태인지는
            #    `partial` 이 "모른다, 절반일 수 있다"로 말한다.
            return _r(:admit, "body threw at $(r.prim.name) — 세계는 절반만 고쳐졌을 수 있다(undo 없음)";
                      steps = steps, applied = applied, partial = true)
        end
        st = _step_status(out)
        applied |= _step_applied(r.prim.name, st)
        push!(steps, (name = r.prim.name, status = st, detail = _step_detail(out)))
    end
    quiet = applied ? "" :
        " — 🔴 불렸지만 어느 단계도 세계를 적응시키지 않았다(status: " *
        join(String.(string.([s.status for s in steps])), ",") * ")"
    return _r(:admit, "body of $(length(names)) primitives$(quiet)";
              steps = steps, applied = applied)
end
