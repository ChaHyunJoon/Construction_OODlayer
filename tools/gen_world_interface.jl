# 생성 agent 가 코드를 쓰기 위해 보는 세계 인터페이스. (2026-09-03, 설계 §4)
#
# 🔴 손으로 적지 않는다. `primitive_registry.json` 과 같은 패턴 — Julia 가 생성하고 두
#    언어가 읽는 한 파일이며, 게이트가 현행 코드와의 일치를 지킨다.
using ConstructionBots
using InteractiveUtils     # subtypes
import JSON3
import Markdown            # _status_meanings — docstring 의 표시된 목록을 AST 로 읽는다
import DataStructures      # OrderedDict — access 색인의 키 순서를 구조로 고정한다
const CB = ConstructionBots

# 🔴 navigator 층은 **런타임 include** 다(`src/navigator/navigator.jl`). 그것 없이는
#    `battery_report` 가 아예 정의되지 않아(실측: UndefVarError) 아래 method_entries 의
#    `isdefined` 검사에서 조용히 빠진다 — 산출물이 export 목록과 어긋난다.
#    집행 경로도 같은 include 를 한다(`tools/monitor/render_demo.jl:18`), 그러므로
#    생성기와 런타임이 **같은 모듈**을 본다. 비용은 1.9초(실측).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

"""
    _infer_return(f, tt) -> Union{Nothing,Type}

반환 타입 유도의 **단 하나의 자리**. `nothing` 은 "말할 수 없다" 이고, 그것은
`Any`("세계가 아무것도 약속하지 않는다") 와 **다른 상태다** — `_method_returns` 의 삼상
판정이 그 구분 위에 서 있고, 두 상태를 한 철자로 접으면 산출물이 거짓을 말한다.

`nothing` 이 되는 세 경우(전부 213 메서드에서 실측):
* `Base.return_types` 가 던진다 — 시그니처를 튜플 타입으로 못 만든다;
* 결과가 **하나가 아니다**(13건). 우리가 준 시그니처가 그 함수의 메서드 여럿에 맞았다는
  뜻이라, 어느 것이 **이 메서드**의 반환인지 귀속할 수 없다. 하나를 고르거나 합치는 것은
  기계가 안 본 것을 지어내는 짓이다;
* 결과가 `Union{}`(3건). "이 호출은 반환하지 않는다" 인데, 기본값 없는 키워드를 가진
  메서드를 **위치인자만으로** 재면 여기 걸린다 — 즉 프로브의 인공물일 수 있어 진실로
  광고할 수 없다.
"""
function _infer_return(f, tt)
    rts = try
        Base.return_types(f, tt)
    catch
        return nothing
    end
    length(rts) == 1 || return nothing
    rt = only(rts)
    rt === Union{} && return nothing
    return rt
end

"""
    _render_return(rt) -> String

유도된 타입 하나를 문자열로 **자르지 않고** 적는다. NamedTuple 이면 필드째 편다
(`battery_report()`), 아니면 타입 자체가 곧 계약이다
(`ood_event_target()` → `Union{Nothing, BotID{DeliveryBot}}`).

🔴 **절단이 없다는 것이 규칙이다**(판정 R-RET3). 넓은 `Union` 을 잘라 `Union{A, B}` 로
적으면 그것은 요약이 아니라 **거짓**이다 — 진실보다 좁게 읽힌다. 실측하면 오늘 자를 것도
없다: 213 메서드의 유도된 반환 중 `Union` 의 최대 항수는 **3** 이고 가장 긴 문자열은
`zone_diagnosis` 의 25필드 NamedTuple(708자) 하나다. 상한을 두면 지금 아무 이득도 없이
나중에 조용히 거짓말하는 장치만 남는다.
"""
function _render_return(rt)
    (rt isa DataType && rt <: NamedTuple) || return string(rt)
    return "(" * join([string(n, "::", t)
                       for (n, t) in zip(fieldnames(rt), fieldtypes(rt))], ", ") * ")"
end

"""
    _returns_string(f, sig) -> String

**앰비언트 접근자**의 반환 모양. 🔴 리뷰 m5: 옛 판은 `battery.jl` 의 반환 NamedTuple 을
손으로 베껴 `AMBIENT_ROOTS` 에 문자열로 들고 있었다 — 기계가 아무것도 안 보므로 드리프트가
조용히 모델의 프롬프트에 실린다. 이제 진실원이 `_infer_return`/`_render_return` 둘이고
메서드 쪽(`_method_returns`)도 **같은 둘**을 쓴다 — 같은 사실의 두 번째 철자는 이 레포가
반복해 밟은 드리프트의 자리다.

🔴 **조용한 폴백을 두지 않는다.** 앰비언트 목록은 손으로 유지되는 **둘**이라 좁은 반환
타입을 선언하는 것이 접근자 쪽의 책임이고, 이 함수가 그 책임의 게이트다 — 유도가 안 되거나
`Any` 면 큰 소리로 죽는다(run1~run4 를 죽인 실패: run4 는 `AbstractID` 자리에 bare `Int64`).
⚠️ 메서드 213개에는 같은 엄격함을 쓸 수 없다(38개가 실제로 `Any` 로 유도된다) — 거기 규칙은
`_method_returns` 가 따로 적는다.
⚠️ 결정성: 같은 코드·같은 줄리아에서 재현된다(세 프로세스 실측, 바이트 동일). 흔들리면
게이트 (2) 의 바이트 비교가 **빨개진다** — 조용히 새지 않는다.
"""
function _returns_string(f, sig)
    rt = _infer_return(f, sig)
    rt === nothing && error("앰비언트 접근자의 반환 타입이 하나로 유도되지 않는다: ", f)
    rt === Any && error("앰비언트 접근자의 반환 타입이 Any 다 — 반환 주석을 좁혀라: ", f)
    return _render_return(rt)
end

"""
앰비언트 세계 상태 — `PlannerEnv` 에 없지만 세계인 것. **손으로 유지되는 유일한 목록**이고,
그래서 게이트 `(7)` 이 "접근자가 `names(CB)` 에 있다" 를, 게이트 `(8)` 이 "집행 프로세스가
그것을 실제로 로드한다" 를 지킨다.

🔴 `precondition` 은 선택 필드가 아니다(리뷰 I4, 게이트 (7) 이 강제한다). 전제조건 없이
   광고하면, 모델이 그대로 부르고 body 가 던진 것이 기록에 `verdict=reject
   world_maybe_dirty=true` = **모델의 저작 실패**로 남는다 — 사실은 우리 프롬프트의 누락이다.
   실측: `BATTERY_FLEET[] === nothing`(배터리 회계는 opt-in 이라 이것이 기본값)에서
   `battery_report()` 는 `MethodError: no method matching battery_report(::Nothing)` 를
   던진다. 프로덕션 호출자 둘(`render_demo.jl`·`run_demo.jl`)이 전부 try/catch 로 감싸고
   `battery_metrics_kwargs` 는 `fleet === nothing` 을 먼저 검사한다.
"""
const AMBIENT_ROOTS = [
    (name = "battery fleet", accessor = "battery_report()",
     returns = _returns_string(CB.battery_report, Tuple{CB.BatteryFleet}),
     precondition = "only when ConstructionBots.BATTERY_FLEET[] !== nothing. Battery " *
                    "accounting is opt-in and OFF by default; calling the accessor with " *
                    "no fleet throws MethodError. Check it first and report `nothing` " *
                    "for the unmeasured case instead of letting the call throw."),
    # 🔴 S3 (2026-09-04, 사용자 결정 = option B). 네 런 연속으로 주조 body 가 **식별자 환각**
    #    으로 죽었다(run4: `fault_robot_and_reassign!(env, 1)` — `AbstractID` 자리에 bare
    #    `Int64`). 원인은 모델의 부주의가 아니라 우리 프롬프트의 구멍이다: OOD 사건의 자연어는
    #    "Robot R7" 이라는 **렌더**만 주고, 세계 어디에도 "그 사건이 때린 로봇의 id" 를 묻는
    #    길이 없었다. 그래서 세계가 스스로 답하게 한다.
    #    반환 타입이 이 항목의 존재 이유다 — `Union{Nothing, BotID{DeliveryBot}}` 가
    #    프롬프트에 실려야 모델이 "이것은 id 객체이지 Int 가 아니다" 를 읽는다.
    (name = "current OOD event target", accessor = "ood_event_target()",
     returns = _returns_string(CB.ood_event_target, Tuple{}),
     precondition = "always callable (no fleet, no accounting flag, no argument). It " *
                    "returns `nothing` when no OOD event has been injected yet, or when " *
                    "the injection found no eligible robot -- `nothing` means NOT " *
                    "RECORDED and is never a valid robot. Check for `nothing` first; " *
                    "otherwise the value IS the robot id object the current event hit, " *
                    "ready to pass straight to verbs that want an AbstractID (e.g. " *
                    "fault_robot_and_reassign!(env, ood_event_target())). Never " *
                    "construct a robot id from the event text -- \"Robot R7\" is a " *
                    "rendering, not an id."),
]

_unwrap(T) = T isa UnionAll ? Base.unwrap_unionall(T) : T

# 🔴 `Union` 에는 `nameof` 가 없다 — `apply_cmd!(node::Union{TransportUnitGo,RobotGo}, …)`
#    의 렌더가 정확히 여기서 MethodError 로 죽는다(실측).
function _tname(T)
    S = _unwrap(T)
    S isa DataType ? string(nameof(S)) : string(T)
end

# F2 (Task 2 이후: 고정점 폐포 `world_type_closure()` 전체의 문지기다, 1단계 전개가 아니다).
# 폐포가 몇 단계를 따라가든 ConstructionBots(또는 그 하위 모듈)가 **정의한** 타입만 받는다.
# `Dict`/`Set` 같은 Base 컨테이너는 `isstructtype` 이 true 라 전개 후보에 걸리지만, 그
# 슬롯 레이아웃(`slots`·`keys`·`vals`·`ndel`·`count`·`age`·`idxfloor`·`maxprobe`, `dict`)은
# 모델이 다룰 세계가 아니다 — 모델이 필요한 것은 컨테이너의 **원소 타입**(필드의 `type`
# 문자열에 이미 `Dict{AbstractID,Ball2}` 로 실린다)이지 해시테이블 내부 구현이 아니다.
# 그 내부를 WORLD TYPES 로 얹으면 모델이 해시테이블을 직접 주무르라는 초대장이 된다.
# 🔴 이 필터를 풀면 폐포가 폭발한다(실측: 깊이 2 에서 1,302타입, 깊이 3 에서 25,160타입) —
# `world_type_closure` 의 while 루프가 CB 밖으로 한 걸음도 못 나가게 막는 것이 바로 이 함수다.
function _defined_in_cb(S)
    S isa DataType || return false
    m = parentmodule(S)
    while true
        m === CB && return true
        pm = parentmodule(m)
        pm === m && return false   # Base/Main 까지 올라갔는데 CB 가 없었다
        m = pm
    end
end

"""
    _type_candidates!(acc, T, d=0)

필드 타입 하나에서 "모델이 알아야 할 타입" 을 전부 뽑아 `acc` 에 넣는다.
`Dict{AbstractID,Ball2}` 는 자기 자신 + `AbstractID` + `Ball2` 를 낳는다.
`TypeVar` 는 상한(`ub`)으로 내려간다. `Union` 은 양쪽으로 갈라진다.
`d` 는 **타입 매개변수 중첩**의 상한이지 폐포의 깊이가 아니다 — 폐포는 고정점이다.
"""
function _type_candidates!(acc, T, d = 0)
    d > 4 && return acc
    T isa TypeVar && return _type_candidates!(acc, T.ub, d + 1)
    if T isa Union
        _type_candidates!(acc, T.a, d + 1); _type_candidates!(acc, T.b, d + 1); return acc
    end
    S = _unwrap(T)
    S isa DataType || return acc
    push!(acc, S)
    for p in S.parameters
        (p isa Type || p isa TypeVar) && _type_candidates!(acc, p, d + 1)
    end
    return acc
end

"""
    world_type_closure() -> Vector{DataType}

`PlannerEnv` **와 `PlannerEnv` 를 인자로 받는 모든 메서드의 인자 타입**을 씨앗으로,
CB 소유 타입만 따라가는 고정점. 이름으로 정렬해 반환한다.

🔴 **씨앗에 메서드 인자를 넣는 이유**(설측). 필드만 따라가면 49타입이고
`PlannerEnv` 를 받는 23개 메서드 중 13개만 호출 가능해진다. 메서드 인자까지 넣으면
67타입이고 **23개 전부**가 열린다 — 새로 열리는 11개는 전부 `apply_cmd!`(7)·
`close_node!`(4) 로, 스케줄 노드를 실제로 여닫고 명령을 먹이는 유일한 공개 경로다.
(리뷰 라운드 1: 계획서의 "66"은 Task 1 이전 — `PlannerEnv`의 무타입 `Dict` 둘을 그냥
`Dict`로 되돌리고 재본 수다. Task 1 이 그 둘을 `Dict{AbstractID,VelocityController}`·
`Dict{AbstractID,Bool}`로 좁히며 `VelocityController` 하나가 폐포에 새로 들어와 67이 됐다.)

🔴 **CB-only 필터는 절대 풀지 않는다.** 실측: 풀면 깊이 2 에서 1,302타입,
깊이 3 에서 25,160타입이다.

🔴 **`_CURATED_SEEDS` 가 왜 있나** (S4, 2026-09-04, 실측). 위 프록시("메서드가 `PlannerEnv`
를 인자로 받는다")는 **충분조건이지 필요조건이 아니다** — 그것이 보는 것은 시그니처의
**주석**이고, respec 층의 세계 동사들은 `env` 를 무타입(`Any`)으로 받는다. 그래서
`release_pending_assignments!(env, invariant::InvariantSpec; …)` 를 export 해도 씨앗
루프가 그 메서드를 아예 **안 본다**: `InvariantSpec` 이 폐포에 안 들어오고 `callable`
이 `false` 가 되어, 방금 광고한 동사가 `FUNCTIONS THAT NEED SOMETHING YOU CANNOT
OBTAIN YET` 아래 렌더된다 = 광고가 무동작이 된다(실측: export 만 한 산출물에서
`release_pending_assignments!` 의 `callable == false`).

🔴 **프록시를 넓히는 것은 이 자리에서 할 결정이 아니다** [실측 2026-09-04]. "첫 위치인자의
**이름**이 `env` 인 메서드도 씨앗" 으로 넓히면 폐포가 **67 → 82** 가 되고, 새로 들어오는
열다섯이 respec DSL 문법 전체다(`RespecProposal` · `ConstraintSpec` · `LinearConstraint` ·
`Disjunction` · `VarRef` · `ForbidZone` · `ForbidAgent` · `ForbidWindow` ·
`ForbidHeavyCargo` · `ReplaceAgent` · `ReformTeam` · `RelocateBuild` · `TranslateBuild` ·
`SwapBattery` · `InvariantSpec`). 그러면 `verify` · `commit_respec!` 이 통째로 열려
**모델이 보는 표면이 이 태스크가 재려는 것과 다른 것**이 된다 — 설계 D6 의 측정을 오염시키는
변경이고, 하려면 별도 결정이다.

⟹ 그래서 **광고된 메서드가 요구하는 타입만** 손으로 씨앗에 넣는다. `AMBIENT_ROOTS` 와
같은 패턴이다(손으로 유지되는 목록 + 게이트). 이 목록을 지키는 것은
`test/world_interface_closure.jl` 의 testset
`"(9) 🔴 S4: 재배정 동사가 실제로 호출 가능하게 렌더된다"` 이고, 그 testset 이 동시에
**넓히기가 일어나지 않았다**(respec 문법이 여전히 폐포 밖이다)를 잰다.
⚠️ 여기 이름을 더하는 것은 모델이 보는 표면을 넓히는 것이다 — 광고(`export`) 없이 더하면
아무 효과도 없고, 광고와 함께 더하면 그 게이트를 다시 판정해야 한다.
"""
const _CURATED_SEEDS = Any[CB.InvariantSpec]

function world_type_closure()
    seeds = Any[CB.PlannerEnv]
    append!(seeds, _CURATED_SEEDS)
    for n in sort(names(CB))
        isdefined(CB, n) || continue
        f = getfield(CB, n)
        f isa Function || continue
        for m in methods(f)
            Ts = collect(_unwrap(m.sig).parameters)[2:end]
            any(T -> _unwrap(T) === CB.PlannerEnv, Ts) || continue
            for T in Ts; _type_candidates!(seeds, T); end
        end
    end
    seen = Dict{String,DataType}()
    frontier = copy(seeds)
    while !isempty(frontier)
        S = _unwrap(popfirst!(frontier))
        S isa DataType || continue
        # 🔴 리뷰 라운드 1 픽스. `S` 는 발견된 자리에 따라 파라메트릭 타입의 **서로 다른
        #    구체 인스턴스**일 수 있다(예: `CachedElement{Ball2}` 대 `CachedElement{Transformation}`)
        #    — 같은 이름으로 `seen`에 접히므로, 정준화 없이는 "누가 먼저 팝됐나"가 산출물의
        #    필드 타입 문자열을 결정해 버린다(실측: `popfirst!`→`pop!` 하나로
        #    `CachedElement.element`가 `CoordinateTransformations.Transformation`→`G`로 뒤집힘).
        #    고정: 발견된 구체 인스턴스가 무엇이든 `.name.wrapper`를 다시 풀어 그 타입의
        #    **제네릭 바디**(타입변수 그대로인 선언형, 예: `CachedElement{E}`)로 정준화한다.
        #    이러면 같은 이름이 갖는 후보가 전부 같은 객체로 수렴해 프런티어 순서와 무관해진다
        #    — "누가 이기는가" 를 정하는 타이브레이크가 아니라 애초에 경합을 없앤다.
        #    대가: 필드가 자기 타입 매개변수를 그대로 쓰면(`element::E`) 렌더가 구체 타입 대신
        #    바로 그 타입변수를 보인다(`element :: E`) — 정보는 줄지만 결정적이고, 이미
        #    `LiftIntoPlace.entity :: C`가 오늘도 그 모양이다(비파라메트릭 타입은
        #    `S.name.wrapper`가 자기 자신이라 변화 없음).
        S = _unwrap(S.name.wrapper)
        n = _tname(S)
        (haskey(seen, n) || !_defined_in_cb(S)) && continue
        seen[n] = S
        nexts = Any[]
        if isabstracttype(S)
            append!(nexts, subtypes(S))
        else
            try
                for ft in fieldtypes(S); _type_candidates!(nexts, ft); end
            catch
                # 🔴 구상 타입인데 fieldtypes 가 던지는 모양은 오늘 없다. 던지면
                #    그 타입은 필드 없이 실린다 — 조용한 폴백이 아니라 아래 type_entry
                #    가 같은 판정을 다시 하고 정직하게 빈 fields 를 낸다.
            end
        end
        append!(frontier, nexts)
    end
    # 🔴 `subtypes` 의 순서는 계약이 아니다. 정렬해야 게이트 (2) 의 바이트 비교가 산다.
    return DataType[seen[k] for k in sort(collect(keys(seen)))]
end

"""
    type_entry(T) -> Dict

구상 타입이면 `fields`, 추상 타입이면 `subtypes`. **둘 다 실지 않는다** —
독자(시험 (2)·파이썬 렌더)가 어느 쪽인지로 분기한다.

🔴 `fieldnames(SceneTreeEdge)` 는 `ArgumentError: type does not have a definite
   number of fields` 를 **던진다**(실측). 추상 타입에 필드를 물으면 안 된다.
"""
function type_entry(T)
    S = _unwrap(T)
    isabstracttype(S) && return Dict(
        "name" => _tname(S),
        "subtypes" => sort(String[_tname(U) for U in subtypes(S)]))
    return Dict(
        "name" => _tname(S),
        "fields" => [Dict("name" => string(f), "type" => string(t))
                     for (f, t) in zip(fieldnames(S), fieldtypes(S))])
end

"""
    _kwarg_types(m::Method) -> Dict{String,String}

키워드 인자의 **선언 타입**을 기계로 유도한다. 위치인자는 `m.sig` 가 들고 있지만 키워드는
안 들고 있다 — `Base.kwarg_decl(m)` 이 주는 것은 **이름뿐**이고, 타입은 컴파일러가 만든
**body 함수**(`Base.bodyfunction(m)`)의 시그니처에 산다. 그 시그니처의 모양은
`Tuple{bodyself, kw1, kw2, …, typeof(f), pos1, …}` 이고 `Base.method_argnames` 가
같은 자리에 이름을 준다 — 키워드 블록과 위치인자 블록을 가르는 것은 `typeof(f)` 자리의
**빈 이름**(`Symbol("")`)이다(실측: `f7(::Foo; margin::Float64)` 에서 nms 가
`[#f7#5, :margin, Symbol(""), Symbol("")]`).

🔴 **이 함수가 왜 있나** (2026-09-05). 유료 런 여섯이 죽은 자리가 전부 **키워드**였는데
(`agent` 에 bare `Int64`, `zone_keys` 에 좌표 튜플, dict 키에 `"R1"`), 광고된 시그니처는
위치인자에만 타입을 싣고 키워드는 이름만 실었다. 즉 모델이 지어내야 했던 바로 그 자리가
프롬프트에서 유일하게 타입이 없는 자리였다. 산문 규칙은 세 번 재어 실패를 **옮기기만**
했으므로, `returns` 때와 같은 기계적 처방을 쓴다 — 선언에 있는 진실을 그대로 광고한다.

🔴 **삼상 규율은 생성기에도 적용된다.** 유도가 안 되는 자리(body 함수가 없다 · body
메서드가 하나가 아니다 · 이름이 kwarg 목록과 안 맞는다 · 선언 타입이 `Any` 다 ·
`kwargs...` 슬러프다)는 **오늘과 같이 이름만** 렌더한다. 지어낸 타입을 싣느니 없는 채로
두는 쪽이 낫다 — `Any` 를 싣는 것은 위치인자 쪽(`_sig_string`)과 같은 이유로 정보 0에
줄만 늘리는 짓이고, 지어낸 타입은 그 자체가 이 파일이 없애려는 실패다.

⚠️ `Base.bodyfunction` 은 Base 내부 API 다(Documenter 가 같은 용도로 쓴다). 던지면
빈 사전으로 물러난다 — 조용한 **거짓**이 아니라 조용한 **부재**이고, 부재는 오늘의 렌더다.
⚠️ 결정성: body 함수의 시그니처도 argnames 도 선언 순서이고 집합 순회가 끼지 않는다.
흔들리면 `test/world_interface_current.jl` 의 testset (2) 바이트 비교가 빨개진다.
"""
function _kwarg_types(m::Method)
    out = Dict{String,String}()
    kws = try Set(String.(Base.kwarg_decl(m))) catch; return out end
    isempty(kws) && return out
    bf = try Base.bodyfunction(m) catch; nothing end
    bf === nothing && return out
    bms = collect(methods(bf))
    length(bms) == 1 || return out          # 하나가 아니면 어느 것이 이 메서드의 body 인지 모른다
    bm = only(bms)
    bsig = Base.unwrap_unionall(bm.sig)
    bsig isa DataType || return out
    Ts  = collect(bsig.parameters)
    nms = Base.method_argnames(bm)
    n = min(length(Ts), length(nms))
    for i in 2:n                            # 1 = body 자신
        nm = String(nms[i])
        isempty(nm) && break                # `typeof(f)` 자리 = 키워드 블록의 끝
        nm in kws || continue               # `kwargs...` 슬러프(body 이름은 `kwargs`)는 여기서 빠진다
        ts = string(Ts[i])
        ts == "Any" && continue             # 위치인자와 같은 규칙 — `x::Any` 는 정보가 0이다
        out[nm] = ts
    end
    return out
end

"""
    _sig_string(m) -> String

메서드 하나를 **모델이 호출을 쓸 수 있는 모양**으로 렌더한다: `(env::PlannerEnv; min_ready, snap_all)`.

🔴 **왜 `string(m.sig)` 이 아닌가** (2026-09-03 최종 리뷰 I3). 그 표현은 `Tuple{typeof(f), Any}`
   다 — 메서드 **전부**가 그 모양이었다. 인자 **이름이 없고 키워드가 통째로 없다.**
   이 산출물의 존재 이유는 모델이 이 함수들을 **부르는 코드를 쓰는 것**인데, 부를 때 필요한
   두 가지가 정확히 그 둘이다. `Base.method_argnames` 와 `Base.kwarg_decl` 이 둘 다 준다.

🔴 **결정성**(게이트 (2) 가 새 서브프로세스 재생성물과 바이트 비교한다). 세 자리 다 안정적이다:
   `unwrap_unionall(m.sig).parameters` 는 선언 순서, `method_argnames` 도 선언 순서,
   `kwarg_decl` 도 선언 순서다. 정렬이나 집합 순회가 끼지 않는다.

⚠️ 이름이 없는 인자(`f(::Int)`)는 `method_argnames` 가 `#unused#` 같은 젠심을 준다 —
   그런 이름은 `_` 로 정규화한다. 젠심을 그대로 실으면 모델이 그것을 인자 이름으로 읽는다.
⚠️ `Any` 는 타입 주석을 **안 붙인다**. 다수가 타입 없이 선언돼 있고, `x::Any` 는
   정보가 0인데 줄만 길게 만든다.
"""
function _sig_string(m::Method)
    sig = Base.unwrap_unionall(m.sig)
    Ts  = collect(sig.parameters)[2:end]        # 첫째는 typeof(f)
    nms = Base.method_argnames(m)               # 첫째는 #self#
    parts = String[]
    for (i, T) in enumerate(Ts)
        nm = length(nms) >= i + 1 ? String(nms[i + 1]) : ""
        (isempty(nm) || startswith(nm, "#")) && (nm = "_")
        ts = string(T)
        push!(parts, ts == "Any" ? nm : string(nm, "::", ts))
    end
    kws = Base.kwarg_decl(m)
    # 🔴 키워드에도 타입을 싣는다 (2026-09-05). 유도 못 한 이름은 **오늘과 같이 이름만** —
    #    `_kwarg_types` 의 삼상 규율이 그 판정의 유일한 자리다.
    kwt = isempty(kws) ? Dict{String,String}() : _kwarg_types(m)
    kwparts = String[]
    for k in kws
        s = String(k)
        push!(kwparts, haskey(kwt, s) ? string(s, "::", kwt[s]) : s)
    end
    return "(" * join(parts, ", ") *
           (isempty(kwparts) ? "" : "; " * join(kwparts, ", ")) * ")"
end

# ── 🔴 여기 있던 **정밀도 등급**(N2, `_PATH_SINGULAR`/`_PATH_ROLE_KEYS`/`_PATH_POPULATION`/
#    `_PATH_LOOKUP_KEYS`)은 삭제됐다 (판정 R33, 2026-09-04). 남겨 두면 안 되는 이유를
#    실측과 함께 적어 둔다 — 이 레포는 같은 종류의 거짓 전제를 세 번 물려받았다.
#
#    그 규칙은 "`Dict{K,V}` 의 `V` 가 CB 소유 타입이면 그 키집합은 역할을 이름한다" 였다.
#    **살아 있는 `PlannerEnv` 에서 반상관이다**(tractor.mpd / 10로봇 / seed 1):
#      · `keys(env.agent_policies)`   V=`VelocityController`(CB) → 1등급, 1위로 승격.
#        실제 키: {BotID 18, TemplatedID{TransportUnitNode} 27} = **로봇 40%**
#      · `keys(env.staging_circles)`  V=`LazySets.Ball2`(서드파티) → 최하등급, 컷 아래.
#        실제 키: **8/8 이 `AssemblyID`** = `restage_assembly!` 의 전제조건 집합 그 자체
#      · `keys(env.agent_parent_build_step_active)`(V=`Bool`, 최하등급)은 400스텝에서
#        `agent_policies` 와 **키 집합이 같다**(wave-b-review 실측; 이 라운드는 t=0 에서만
#        재유도했고 거기서는 둘 다 관측 가능하다) — 값 타입이 다를 뿐 정밀도가 동일하다.
#    즉 판별자가 완벽히 정밀한 출처를 강등하고 섞인 출처를 승격했다.
#
# 🔴 **그리고 정적으로는 가를 수 없다**(재유도 실측): `AbstractID` 를 내는 아홉 경로의
#    선언된 **산출 타입은 9/9 가 `ConstructionBots.AbstractID`** 하나다(distinct = 1).
#    컨테이너 선언이 다른 것은 **값** 타입뿐이고 그것이 바로 위에서 반상관으로 측정된 축이다.
#    ⟹ 선언에는 정밀도 정보가 **0비트** 있다. 생성기에는 살아 있는 env 가 없고(설계상 그렇다),
#    그래서 옳은 처방은 더 나은 순위가 아니라 **순위를 안 매기는 것**이다: 목록은 사전순으로
#    싣고 아무것도 자르지 않는다(`_MAX_PATHS` 참조). 모델이 고른다.
#
# ⚠️ 같은 이유로 **홉 수 타이브레이크도 없앴다**(리뷰 I-2). 옛 정렬 키 `(등급, 홉, 경로)` 는
#    hop 0 이라는 이유만으로 `for x in env.active_build_steps` 를 3위 → 2위로 올렸는데,
#    t=0 에서 n=0 은 이 라운드가 재유도했고, 400스텝에서 n=3 이며 **셋 다 scene tree 밖**
#    이라는 것은 wave-b-review 의 실측이다.
#    "실행시각에 비어 있다" 는 여기서 원리적으로 못 잰다(살아 있는 env 가 없다) — 그래서
#    고침은 그것을 뒤로 미는 더 나은 순위가 아니라 **아무것도 안 자르는 것**이다.
#    컷이 없으면 순서가 뭘 놓치게 만들지 않으므로 이 축의 위험이 소멸한다.

"""
    access_index(closure) -> AbstractDict{String,Vector{String}}

폐포의 각 타입에 대해 `env` 로부터 그 값을 얻는 **경로 문자열**들. 필드 그래프의 순수
순회이므로 결정적이다. 컨테이너는 원소를 꺼내는 모양으로 적는다 —
`Vector{T}` 는 `…[i]`, `Dict{K,V}` 는 `keys(…)`/`values(…)`.

🔴 이 색인이 §1.2 의 실패를 정면으로 겨냥한다: 모델이 지어낸 것은 전부 "그 값을 어디서
   얻는지 안 적힌" 타입이었다.

🔴 **목록의 순서는 사전순이다 — 그리고 그것이 주장의 전부다** (판정 R33). 위 블록이
   실측으로 적은 대로, 어느 경로가 더 정밀한 id 를 내는지는 **선언에서 유도할 수 없다**
   (아홉 경로의 선언된 산출 타입이 9/9 동일). 그래서 순서는 의미를 나르지 않고,
   상한도 이제 아무것도 안 자른다(`_MAX_PATHS`) — 위치를 순위로 읽을 여지를 없앤다.

🔴 **결정성은 구조로 지킨다**(게이트 (2) 가 새 서브프로세스 재생성물과 바이트 비교한다).
   세 자리 다 순회 순서와 무관하다: (a) 경로 문자열이 경로의 구조만의 함수이고 유일하므로
   사전순은 **전순서**다, (b) 같은 경로가 두 번 발견되면 `Set` 에 한 번만 남는다 —
   저장하는 부가 정보가 없으므로 발견 순서가 남을 자리 자체가 없다(예전 판은 `(등급, 홉)`
   튜플의 사전식 최솟값을 취했고 docstring 은 그것을 "등급의 최솟값" 이라 잘못 적었다 —
   리뷰 m-2), (c) 키 순서는 `OrderedDict` + 정렬이다 — 맨 `Dict` 는 삽입 순서(= BFS 발견
   순서)가 해시 레이아웃에 남으므로 결정적이긴 해도 그 결정성이 우연에 가깝다.
   섭동 대조(BFS→DFS · 필드 순서 역전 · 폐포 쪽까지)와 양성 대조는 보고서에 적는다 —
   🔴 **여기에 그 날짜와 줄 수를 박지 않는다**(리뷰 m-1: 상한이나 필드가 바뀌면 조용히 낡는다).
"""
function access_index(closure)
    want = Set(String[_tname(S) for S in closure])
    # 타입 이름 -> 경로 집합. 🔴 `Vector` 가 아니라 `Set` 인 이유는 위 (b) 다 — 같은 경로를
    # 두 번 발견해도 흔적이 안 남는다(순서를 나르는 부가 정보를 아예 안 들고 있다).
    out  = Dict{String,Set{String}}()
    function add!(n, p)
        n in want || return nothing
        push!(get!(out, n, Set{String}()), p)
        return nothing
    end
    # 너비 우선. 경로가 길어지면 모델에게 쓸모가 없으므로 3 홉에서 끊는다.
    frontier = Tuple{DataType,String,Int}[(CB.PlannerEnv, "env", 0)]
    seen = Set{String}(["PlannerEnv"])

    # 🔴 **중첩 컨테이너는 재귀로 푼다** (Task 4 실측 정정, 계획서의 1단계 분기를 대체한다).
    #    계획서 판은 `Vector{Dict{Int,SceneTreeEdge}}`(= `SceneTree.inedges` 의 실제 타입)의
    #    안쪽 `Dict` 를 **구조체로 착각해 필드로 내려갔고**, 그래서 산출물에
    #    `env.scene_tree.inedges[i].vals[i]` 라는 **해시테이블 내부 경로**가 실렸다(실측).
    #    그 경로는 이 파일이 `_defined_in_cb` 로 막기로 한 바로 그것이고, 게다가 `Dict.vals`
    #    는 빈 슬롯이 `#undef` 라 순회 자체가 안전하지 않다. 옳은 경로는
    #    `values(env.scene_tree.inedges[i])` 다.
    # 🔴 같은 이유로 **CB 밖 구조체의 필드로는 한 걸음도 내려가지 않는다** —
    #    `_defined_in_cb` 가 폐포에서 하는 역할을 여기서도 한다.
    function visit!(U, path, hop, d = 0)
        (U isa DataType && d <= 3) || return
        if U <: AbstractVector && length(U.parameters) >= 1
            visit!(_unwrap(U.parameters[1]), string(path, "[i]"), hop, d + 1)
        elseif U <: AbstractDict && length(U.parameters) >= 2
            K = _unwrap(U.parameters[1])
            V = _unwrap(U.parameters[2])
            K isa DataType && add!(_tname(K), string("keys(", path, ")"))
            visit!(V, string("values(", path, ")"), hop, d + 1)
        elseif U <: AbstractSet && length(U.parameters) >= 1
            E = _unwrap(U.parameters[1])
            E isa DataType && add!(_tname(E), string("for x in ", path))
        else
            add!(_tname(U), path)
            (_defined_in_cb(U) && !(_tname(U) in seen)) &&
                (push!(seen, _tname(U)); push!(frontier, (U, path, hop + 1)))
        end
        return nothing
    end

    while !isempty(frontier)
        (S, path, hop) = popfirst!(frontier)
        hop >= 3 && continue
        isabstracttype(S) && continue
        for (f, ft) in zip(fieldnames(S), fieldtypes(S))
            visit!(_unwrap(ft), string(path, ".", f), hop)
        end
    end
    # 🔴 결정성: 경로 목록도 키도 사전순이다. 여기서 순서가 나르는 주장은 **없다**(R33).
    ord = DataStructures.OrderedDict{String,Vector{String}}()
    for k in sort(collect(keys(out)))
        ord[k] = sort!(collect(out[k]))
    end
    return ord
end

const _SCALARISH = (Real, AbstractString, Symbol, Bool, Char)

"""
    _OBTAINABLE_FOREIGN

폐포 **밖**(= CB 가 정의하지 않은)인데 **광고된 접근자가 이미 손에 쥐여 주는** 타입 이름들.

🔴 왜 이 목록이 따로 있나 (나-1, 2026-09-05, 유료 런 19·20 실측). `get_center` 를 export 만
   하면 S4 와 바이트 동일한 무동작이 된다: 재생성물에서 `callable == false` 라 렌더가 그것을
   `FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET` 아래 실었고, 그 자리는 모델이
   "지금은 못 부른다" 로 읽는다. 그런데 런 19 의 body 는 **정확히 그 함수를 부르려다** 죽었다
   (`get_center(::Pair{Symbol, Ball2})`).

🔴 그리고 그 `callable == false` 는 **거짓 진술**이었다. `restriction_zones()` 는
   `Dict{Symbol, Ball2}` 를 돌려주고 그 자신이 광고돼 있으며, 2026-09-05 의 `element_type`
   이후로는 `yields: Pair{Symbol, Ball2}` 까지 적혀 있다 — 즉 그 값은 손에 들어온다.
   폐포에만 없었을 뿐이다.

🔴 **타입 폐포를 넓히지 않는다.** `world_type_closure` 의 `_defined_in_cb` 게이트는 그대로다
   — 넓히면 `WORLD TYPES` 절에 LazySets 내부가 통째로 들어와 모델이 보는 표면이 이 레인이
   재려는 것과 달라진다(S4 가 프록시 넓히기를 재고 버린 것과 같은 근거). 여기서 바꾸는 것은
   **한 술어의 참값**뿐이다: "이 인자를 손에 넣을 수 있는가".

⚠️ `AMBIENT_ROOTS`·`_CURATED_SEEDS` 와 같은 패턴이다 — 손으로 유지되는 목록 + 게이트.
   이름을 더하는 것은 모델이 보는 표면을 넓히는 것이므로 그 게이트를 다시 판정해야 한다.
⚠️ 이름은 `_tname` 의 철자다 — 즉 `nameof` 의 **맨 이름**(`"Ball2"`)이지 정규화된
   `"LazySets.Ball2Module.Ball2"` 가 아니다. `reach` 도 같은 철자를 쓰므로 두 판정이 한
   어휘를 공유한다(실측: 정규화 이름으로 적으면 이 목록이 조용한 무동작이 된다).
"""
const _OBTAINABLE_FOREIGN = Set{String}(["Ball2"])

"""
이 인자 타입이 **폐포 멤버십(또는 스칼라/Any)** 기준을 통과하는가 (설계 §6.2 의 판정).

🔴 리뷰 I2: `Vararg{Any}` 는 `isa DataType` 가 **false** 라 아래 `S isa DataType ||
   return false` 에 걸려 통째로 떨어졌다 — `Any` 는 true 인데 `Vararg{Any}` 는 false 였다.
   그래서 `set_desired_global_transform!(n::SceneNode, args...)` 처럼 **경로가 이미 있는**
   세계 변경자 다섯이 "obtain 할 수 없다" 쪽에 실렸다. 모델이 조립체를 옮기려는데 유일한
   공개 변경자가 못 부른다고 적혀 있으면, L3 이 0 인 이유가 어휘가 아니라 이 한 줄이 된다.
"""
function _arg_obtainable(T, reach)
    T isa Core.TypeofVararg && return _arg_obtainable(Base.unwrapva(T), reach)
    T isa Union && return _arg_obtainable(T.a, reach) && _arg_obtainable(T.b, reach)
    S = _unwrap(T)
    S === Any && return true
    S === CB.PlannerEnv && return true
    S isa DataType || return false
    S === Nothing && return true
    any(P -> S <: P, _SCALARISH) && return true
    _tname(S) in _OBTAINABLE_FOREIGN && return true      # 🔴 (나-1): 폐포 밖이지만 손에 들어온다
    return _tname(S) in reach
end

"""렌더가 인자 하나에 실을 경로의 상한 — 오늘은 **트립와이어이지 절단기가 아니다**
(Ruling R11 → R33).

R11 이 `first(ps)` 하나를 넷으로 올렸다. 근거는 옳았다: `AbstractID` 는 경로가 아홉인데
하나로 접으면 사전순 첫째가 뽑히고, 그것은 의미순이 아니라 **동전던지기에 답의 옷을
입힌 것**이다. 그런데 넷으로 자르는 것도 같은 문제를 5분의 4 크기로 남긴다 — 무엇을
남길지 고르려면 **어느 경로가 더 정밀한가** 를 알아야 하는데, 위 `access_index` 앞의
블록이 실측으로 적은 대로 그 판정은 **선언에서 유도할 수 없다**(아홉 경로의 선언된 산출
타입이 9/9 동일하고, 유일하게 갈리는 값 타입은 실제 조성과 **반상관**이다).

🔴 **판정 R33 의 처방: 자르지 않는다.** 인자 하나가 아홉 줄을 받는다. 그러면 프롬프트가
   정당화할 수 없는 순위를 암시하지 않고, 컷이 없앴던 것들이 돌아온다 —
   `keys(env.staging_circles)`(= `restage_assembly!` 의 전제조건 집합, 실측 8/8 `AssemblyID`),
   `vtx_map` 둘, 그리고 설계 §6.2 가 이름 댄 `env.sched.vtx_ids[i]`.

⚠️ 그래서 이 상수는 **오늘 아무것도 안 문다**(최댓값 9 < 12). 남겨 두는 이유는 프롬프트가
   무한정 자라는 것을 막기 위해서이고, 물게 되면 `test/world_interface_closure.jl` 의
   testset (8) 이 **빨개진다** — 조용히 사전순으로 몇 개를 고르는 대신. 상한을 올리거나
   내리는 것은 그 게이트를 통과해야 하는 결정이다.

⚠️ 대가는 프롬프트 길이다. 실측치는 보고서에 적는다(🔴 여기에 숫자를 박지 않는다 —
   필드가 하나 늘면 조용히 낡는다. 리뷰 m-1).
"""
const _MAX_PATHS = 12

"""
    _arg_sourceable(T, acc) -> Bool

이 인자의 **값을 실제로 손에 넣을 수 있는가**. `_arg_obtainable`(폐포 **멤버십**)보다 강한
주장이다 — 여기서 보는 것은 `acc`(= `env` 로부터의 실제 경로)다. 리터럴로 쓸 수 있는 것
(스칼라·`Nothing`·`Any`)과 하네스가 주는 `env` 는 경로가 필요 없다.
"""
function _arg_sourceable(T, acc)
    T isa Core.TypeofVararg && return _arg_sourceable(Base.unwrapva(T), acc)
    # Union 은 **한 갈래만** 손에 넣어도 호출할 값이 생긴다 (`_arg_obtainable` 의 `&&` 와 다르다).
    T isa Union && return _arg_sourceable(T.a, acc) || _arg_sourceable(T.b, acc)
    S = _unwrap(T)
    (S === Any || S === CB.PlannerEnv || S === Nothing) && return true
    S isa DataType || return false
    any(P -> S <: P, _SCALARISH) && return true
    return !isempty(get(acc, _tname(S), String[]))
end

"""
    _missing_types(Ts, acc) -> Vector{String}

이 메서드를 부르려면 필요한데 **얻는 방법이 없는** 인자 타입들. 설계 §6.2 의
`missing: <타입>` 이 이것이고, 두 표제 **모두**가 이것을 싣는다:

* 둘째 표제(못 부른다)에서는 "폐포 밖이라 못 부른다" 의 이름이고,
* 첫째 표제(부를 수 있다)에서는 🔴 **표제가 32건에 대해 하는 거짓 약속**을 갚는다 —
  "every argument is obtainable from env" 아래에 경로 없는 인자를 가진 항목이 앉아 있었고,
  모델이 `apply_cmd!(node, twist, env)` 를 쓰려다 `node` 의 출처를 못 찾고 placeholder 를
  쓰는 것이 정확히 설계 §1.2, 즉 D11 이 없애려던 실패다(리뷰 I1).

⚠️ 이름은 `_tname` 이다 — WORLD TYPES 블록·`access` 색인과 **같은 어휘**여야 모델이 이어
   읽는다(따라서 `AbstractVector` 는 `AbstractArray` 로 적힌다).
"""
function _missing_types(Ts, acc)
    ns = String[]
    for T in Ts
        _arg_sourceable(T, acc) && continue
        push!(ns, _tname(T isa Core.TypeofVararg ? Base.unwrapva(T) : T))
    end
    return sort!(unique!(ns))
end

"""
    tt_of(m::Method) -> Union{Nothing,Type}

메서드의 인자 튜플 타입. 🔴 **진실원 하나** — `_method_returns` 와 `method_entries` 가
같은 계산을 두 벌 들면 그 둘이 갈리는 날 `returns` 와 `element_type` 이 **서로 다른
시그니처**에 대한 사실이 된다.
"""
function tt_of(m::Method)
    try
        sig = Base.unwrap_unionall(m.sig)
        sig isa DataType || return nothing
        return Tuple{collect(sig.parameters)[2:end]...}
    catch
        return nothing
    end
end

"""
    _method_returns(f, m::Method) -> Union{Nothing,String}

메서드 하나의 반환 모양. 🔴 이 필드는 2026-09-05 이전에 **메서드 항목에 아예 없었다** —
`returns` 는 `ambient` 두 항목에만 있었고, 그래서 광고된 213 메서드 전부에 대해 모델은
반환 모양을 한 글자도 못 봤다. 유료 런 6 이 그 구멍에서 죽었다: 모델이 tier-1 동사를 부르고
**그 반환을 안 보고** `:success` 를 무조건 냈다(세계 delta 는 6축 전부 0이었다). 반환에
상태가 실려 있다는 것이 보이면 그것을 확인하는 것이 유도 가능해진다.

🔴 **삼상 판정 (판정 R-RET1/R-RET2/R-RET3).** `_returns_string`(앰비언트)은 유도가 안 되면
던지지만 여기서는 던질 수 없다 — 그러면 생성기가 아예 안 돈다. 대신 **세 상태를 안 섞는다**:

| 상태 | 산출물 | 렌더 | 뜻 |
|---|---|---|---|
| 유도됨, `Any` 아님 | `"returns" => "…"` | `->  …` | 세계가 이 모양을 약속한다 |
| 유도됨, `Any` (38건) | `"returns" => "Any"` | `->  Any` | 세계가 **아무것도 약속하지 않는다** |
| 유도 불가 (16건) | **필드 없음** | 화살표 없음 | 기계가 **말할 수 없었다** |

R-RET1: `Any` 를 **정직하게 싣는다**. 앰비언트가 `Any` 를 거절하는 이유(손으로 유지되는
두 항목이니 좁히는 것이 접근자 저자의 책임이다)는 213 메서드에 안 통한다. 그리고 여기서
`Any` 를 빼면 그것이 곧 **부재와의 융합**이다 — "유도했더니 Any" 와 "유도 못 했다" 가 산출물
에서 구별 불가가 되고, 그 순간 이 필드의 부재는 아무 정보도 안 나른다.
R-RET2: 유도 불가는 **필드 자체를 뺀다**. 빈 문자열이나 `"unknown"` 을 실으면 모델이 그것을
타입으로 읽는다(이 레포는 이미 그 모양으로 데었다 — 지어낸 이름은 `KeyError` 로 죽는다).
R-RET3: **절단하지 않는다** — `_render_return` 의 docstring 이 근거를 적는다.

⚠️ 비용은 생성시각뿐이다: `Base.return_types` 를 213 메서드에 도는 데 실측 +42초
(41초 → 83초). 산출물은 두 언어가 읽는 정적 파일이므로 런타임 비용은 0이다.
⚠️ 결정성: 세 프로세스에서 바이트 동일(실측). 흔들리면 게이트 (2) 가 빨개진다.
"""
function _method_returns(f, m::Method)
    tt = tt_of(m)
    tt === nothing && return nothing
    rt = _infer_return(f, tt)
    rt === nothing && return nothing
    return _render_return(rt)                # `Any` 도 여기서 정직하게 "Any" 가 된다
end

"""
    _defining_expr(m::Method) -> Union{Nothing,Expr}

`m` 을 정의한 **소스의 top-level 식**. 못 찾으면 `nothing`.

🔴 왜 소스를 읽나 (2026-09-05, 유료 런 16·19). 타입 유도는 `translate_whole_build!` 의 반환을
   맨 `NamedTuple` 로 **넓혀 버린다** — 필드도 상태 어휘도 한 글자도 안 남는다. 런 16 의 body 는
   그 자리에서 `fallback.status == :success` 라고 **지어냈고**, 그 함수는 `:success` 를 내는
   경로가 아예 없어서 **빌드를 실제로 옮겨 놓고도 무조건 던졌다**(`n_staging_moved=8`,
   그리고 `error(...)`). 반대로 `restage_all_blocked!` 은 필드가 광고돼 있었고 모델은
   `outcome.failed`·`outcome.residual` 을 **맞게** 썼다. ⟹ 모델은 우리가 광고한 것은 맞게
   쓰고 광고 안 한 것만 지어낸다. 그러므로 유도가 넓어지는 자리를 **소스에서** 메운다.

⚠️ `Base.find_source_file` 이 `nothing`/부재를 낼 수 있고 `Meta.parseall` 은 던질 수 있다.
   둘 다 `nothing` 으로 접는다 — 생성기가 한 메서드 때문에 안 도는 일은 없어야 한다.
"""
function _defining_expr(m::Method)
    p = Base.find_source_file(String(m.file))
    (p === nothing || !isfile(p)) && return nothing
    top = try Meta.parseall(read(p, String); filename = p) catch; return nothing end
    top isa Expr || return nothing
    # 🔴 `module`/`begin` 안쪽까지 내려간다. 평평한 파일만 가정하면 패키지 소스의 다수를
    #    조용히 놓치고, 그 침묵은 "이 메서드엔 상태가 없다" 로 **거짓 판독**된다.
    pick(ex) = begin
        best = nothing; bestline = -1; ln = 0
        for a in ex.args
            if a isa LineNumberNode; ln = a.line; continue; end
            (a isa Expr && ln <= m.line && ln > bestline) || continue
            best = a; bestline = ln
        end
        best === nothing && return nothing
        if best.head === :module
            inner = findfirst(a -> a isa Expr && a.head === :block, best.args)
            inner === nothing || return something(pick(best.args[inner]), best)
        elseif best.head === :toplevel || best.head === :block
            return something(pick(best), best)
        end
        return best
    end
    return pick(top)
end

"""
    _status_symbols(m::Method) -> Union{Nothing,Vector{String}}

이 메서드가 `status` 자리에 실을 수 있는 **심볼 리터럴 전부**. 못 유도하면 `nothing`.

규칙 하나: 소스의 `status = <rhs>` 를 전부 찾고(직접 대입도, NamedTuple 안의
`(status = …, )` 도 같은 `Expr(:(=), :status, rhs)` 다), 그 `rhs` **안쪽 어디든** 나타나는
심볼 리터럴을 모은다. 삼항 연쇄가 그 안에 있으므로 갈래가 전부 잡힌다.

🔴 **`Expr(:., obj, QuoteNode(name))` 의 둘째 인자로는 안 내려간다.** 필드 접근의 *이름*은
   반환값이 아니다 — 안 막으면 `status = res.status` 한 줄이 `:status` 를 어휘에 넣는다
   (2026-09-05 실측: `restage_all_blocked!` 에서 정확히 그 오탐이 났다).

⚠️ **이것은 구문적 상계다.** 도달 불가한 갈래를 포함할 수 있고, **다른 함수가 만들어 준
   상태는 못 본다**(`status = res.status` 가 그 모양이다 — 그 판에서 이 표는 그 함수의
   어휘를 안 싣는다). 그래서 렌더 문구가 "one of" 가 아니라 **`observed in source`** 다:
   모델이 이것을 폐집합으로 읽고 `else` 를 오류로 처리하면 안 된다.

🔴 삼상: 비면 **필드를 안 만든다**(`_method_returns` 의 R-RET2 와 같은 규약). `[]` 를 실으면
   "상태 어휘가 없다" 는 **주장**이 되는데 우리는 그것을 안 쟀다 — 소스를 못 읽었을 뿐이다.
"""
function _status_symbols(m::Method)
    ex = _defining_expr(m)
    ex === nothing && return nothing
    acc = Set{Symbol}()
    harvest(x) = begin
        if x isa QuoteNode
            x.value isa Symbol && push!(acc, x.value)
        elseif x isa Expr
            # 필드 이름은 값이 아니다 — `a.b` 의 `b` 로는 안 내려간다.
            x.head === :. ? harvest(first(x.args)) : foreach(harvest, x.args)
        end
    end
    walk(x) = begin
        x isa Expr || return
        x.head === :(=) && length(x.args) == 2 && x.args[1] === :status && harvest(x.args[2])
        foreach(walk, x.args)
    end
    walk(ex)
    isempty(acc) && return nothing
    return sort!(String[string(s) for s in acc])
end

const _STATUS_MEANINGS_MARK = "Status (advertised to the tool lane):"

_md_blocks(x) = x isa Markdown.MD ? reduce(vcat, (_md_blocks(c) for c in x.content); init = Any[]) : Any[x]

"""
    _docstring_of(m::Method) -> Union{Nothing,String}

정의 바로 앞의 docstring. 런타임 문서 조회(`Base.Docs.doc`)를 쓰지 않는 이유(실측, 2026-09-22):
이 레포는 docstring 과 `function` 사이에 한국어 주석 줄을 끼우는 관례가 있고, 그러면 파서가
docstring 을 정의에 **안 붙인다** — `restage_all_blocked!` 는 `No documentation found` 였다. 그래서
소스를 직접 읽는다: 정의 직전의 최상위 항목이 문자열이면 그것이고, 붙어 있으면(`@doc` 매크로 호출)
그 셋째 인자다. 평평한 파일만 본다(모자라면 `nothing` — 삼상 규약상 키를 안 만든다).
"""
function _docstring_of(m::Method)
    p = Base.find_source_file(String(m.file))
    (p === nothing || !isfile(p)) && return nothing
    top = try Meta.parseall(read(p, String); filename = p) catch; return nothing end
    top isa Expr || return nothing
    best = nothing; bestprev = nothing; bestln = -1; prev = nothing; ln = 0
    for a in top.args
        a isa LineNumberNode && (ln = a.line; continue)
        (ln <= m.line && ln > bestln) && (best = a; bestprev = prev; bestln = ln)
        prev = a
    end
    if best isa Expr && best.head === :macrocall && length(best.args) >= 4 &&
       best.args[1] == GlobalRef(Core, Symbol("@doc")) && best.args[3] isa AbstractString
        return String(best.args[3])
    end
    return bestprev isa AbstractString ? String(bestprev) : nothing
end

"""
    _status_meanings(m::Method) -> Union{Nothing,Vector{String}}

각 status 기호의 **뜻**. docstring 에 `$(_STATUS_MEANINGS_MARK)` 문단을 **명시적으로 둔**
함수에서만, 바로 뒤의 목록(`- `:sym` — 뜻`)을 수확한다. 표시가 없으면 `nothing`(키를 안 만든다).

🔴 왜 (2026-09-22, results/2026-09-22-r2-body-replay ③ · r3): `status seen in source:` 는 기호만
   실었다. `restage_all_blocked!` 의 `:none` 을 모델은 "존이 다 치워졌다" 로 읽었고(엔진 docstring
   도 그렇게 **틀리게** 적고 있었다), 재시도 6판의 첫 시도 body 가 그 자리에서 translate 로 안
   올라갔다.
🔴 docstring 을 통째로 싣지 않는다 — 광고되는 문장은 모델에 대한 **주장**이고, 검증 안 된 산문이
   주장이 되면 세계에 없는 결과를 약속한다. 표시한 문단만, 사람이 참인지 보고 쓴 것만 나간다.
🔴 수확한 기호가 `_status_symbols` 에 없으면 **에러**다: 소스에서 사라진 상태의 뜻이 광고에 남는
   것(낡은 주장)을 생성 시점에 막는다. 반대로 소스의 기호 일부에 뜻이 없는 것은 허용한다 — 렌더가
   "seen in source" 기호를 따로 싣는다.
"""
function _status_meanings(m::Method)
    ss = _status_symbols(m)
    ss === nothing && return nothing
    doc = _docstring_of(m)
    doc === nothing && return nothing
    blocks = _md_blocks(Markdown.parse(doc))
    k = findfirst(b -> b isa Markdown.Paragraph && occursin(_STATUS_MEANINGS_MARK, Markdown.plain(b)), blocks)
    k === nothing && return nothing
    (k < length(blocks) && blocks[k + 1] isa Markdown.List) ||
        error("[status_meanings] $(m.name): '$(_STATUS_MEANINGS_MARK)' 다음에 목록이 없다")
    out = String[]
    for item in blocks[k + 1].items
        t = replace(strip(Markdown.plain(Markdown.MD(item))), r"\s+" => " ")
        mm = match(r"^`:(\w+)`\s*—\s*(.+)$", t)
        mm === nothing && error("[status_meanings] $(m.name): 목록 항목 모양이 `- `:sym` — 뜻` 이 아니다: $t")
        String(mm[1]) in ss ||
            error("[status_meanings] $(m.name): :$(mm[1]) 는 소스의 status 기호($(ss))에 없다 — 낡은 뜻")
        push!(out, string(":", mm[1], " = ", mm[2]))
    end
    return isempty(out) ? nothing : sort!(out)
end

"""
    _arg_coercions(m::Method) -> Union{Nothing,Vector{String}}

**타입이 안 붙은 위치 인자**를 이 메서드의 소스가 무엇으로 바꿔 쓰는지. 못 유도하면 `nothing`.

🔴 왜 존재하나 (2026-09-05, 유료 런 19·20·22). 세 판이 같은 문장으로 죽었다 —
   `Vector{Float64}(::TransformNode)` · `Vector{Float64}(::AffineMap)` ×2. 런 22 의 body 는
   (나-1)이 광고한 `global_transform(goal_config(node))` 를 **맞게** 쓴 다음 그 결과를
   `free_space_status(start, goal, …)` 에 넘겼다. 그 시그니처의 `start`·`goal` 은 **무타입**이라
   광고가 "좌표를 꺼내는 길"은 알려 주고 "받는 쪽이 원하는 모양"은 한 글자도 안 알려 줬다.
   그 사이의 변환은 **callee 의 body 에 이미 적혀 있다**: `Vector{Float64}(goal)[1:2]`.
   ⟹ 유도가 (여기서는 `Any` 로) 넓어지는 자리를 소스에서 메우는, `_status_symbols` 와 같은 수선이다.

규칙 하나: 선언 타입이 `Any` 인 위치 인자 이름을 모으고, 소스에서 **그 이름 하나만**을 받는 호출
`C(name)` 중 `C` 가 타입처럼 생긴 것(대문자로 시작하는 심볼, 또는 `T{…}`)을 모은다. 그 호출 바로
바깥이 첨자면(`C(name)[1:2]`) 첨자까지 적는다 — **길이 요구가 거기 있다**(평면 점이라는 사실).

🔴 `Any` 인 인자가 하나도 없으면 소스를 **읽지도 않는다**. 파일 파싱은 메서드마다 도는 비용이고,
   이 판정은 타입만으로 먼저 배제된다.

⚠️ **구문적 상계다.** 다른 함수가 대신 변환해 주는 경우(`h(g(x))`)는 못 본다. 그래서 렌더 문구가
   "must be" 가 아니라 `coerced in source` 다 — 모델이 이것을 폐집합으로 읽으면 안 된다.

🔴 삼상: 무타입 인자가 없거나 변환을 못 찾으면 **키를 안 만든다**(`[]` 를 실으면 "변환이 없다" 는
   주장이 되는데 우리는 그것을 안 쟀다).
"""
function _arg_coercions(m::Method)
    Ts  = collect(Base.unwrap_unionall(m.sig).parameters)[2:end]
    nms = Base.method_argnames(m)
    untyped = Set{Symbol}()
    for (i, T) in enumerate(Ts)
        T === Any || continue
        length(nms) >= i + 1 || continue
        nm = nms[i + 1]
        startswith(String(nm), "#") && continue      # 이름 없는 인자의 젠심은 이름이 아니다
        push!(untyped, nm)
    end
    isempty(untyped) && return nothing
    ex = _defining_expr(m)
    ex === nothing && return nothing
    acc = Set{String}()
    typeish(C) = (C isa Symbol && isuppercase(first(String(C)))) ||
                 (C isa Expr && C.head === :curly)
    # `C(name)` 이면 그 인자 이름을, 아니면 `nothing`.
    conv(x) = (x isa Expr && x.head === :call && length(x.args) == 2 &&
               x.args[2] isa Symbol && x.args[2] in untyped && typeish(x.args[1])) ?
              x.args[2] : nothing
    walk(x) = begin
        x isa Expr || return
        if x.head === :ref && length(x.args) >= 2
            a = conv(x.args[1])
            if a !== nothing
                push!(acc, string(a, " <- ", x))     # 첨자까지 붙은 원문 그대로
                foreach(walk, x.args[2:end])         # 변환 자체는 이미 실었다 — 두 번 안 싣는다
                return
            end
        end
        a = conv(x)
        a === nothing || push!(acc, string(a, " <- ", x))
        foreach(walk, x.args)
    end
    walk(ex)
    isempty(acc) && return nothing
    return sort!(collect(acc))
end

"""
    _nt_names(x) -> Union{Nothing,Vector{Symbol}}

`x` 가 NamedTuple 리터럴이면 그 필드 이름, 아니면 `nothing`. 두 표기를 다 받는다:
`(; a = 1, b = 2)` 는 `Expr(:parameters, …)`, `(a = 1, b = 2)` 는 `Expr(:(=), …)`.

🔴 `_returned_fields` 의 안쪽 클로저였다. `_returns_are_exhaustive` 가 **같은 판정**을 써야
   하므로 최상위로 올렸다 — 두 벌을 두면 갈리고, 갈리면 "완전하다" 는 주장이 조용히 거짓이 된다.
   (같은 이유로 `_RETURN_CONTRACT_DESC` 가 파이썬 쪽에서 상수 하나로 묶여 있다.)
"""
function _nt_names(x)
    (x isa Expr && x.head === :tuple) || return nothing
    got = Symbol[]
    for a in x.args
        if a isa Expr && a.head === :parameters
            for kw in a.args
                (kw isa Expr && kw.head === :kw && kw.args[1] isa Symbol) &&
                    push!(got, kw.args[1])
            end
        elseif a isa Expr && a.head === :(=) && a.args[1] isa Symbol
            push!(got, a.args[1])
        end
    end
    isempty(got) ? nothing : got
end

"""
    _returned_fields(m::Method) -> Union{Nothing,Vector{String}}

이 메서드가 **return 자리에서** 짓는 NamedTuple 의 필드 이름 전부. 못 유도하면 `nothing`.

🔴 왜 존재하나 (2026-09-05, 유료 런 23·26). run23 의 body 가 자기 주석에 원인을 적었다:
   *"No query returns the blocked schedule-node objects directly, so inspect the active
   unfinished frontier and test each cargo-navigation path."* — 그래서 탐지를 손수 짰고,
   `env.cache.active_set` 으로 걸렀는데 존 주입기는 **일부러 active 가 아닌 목표**를 고른다
   ⟹ 빈손 ⟹ 던졌다. 그런데 그 질의는 **있다**: `zone_blockage(...).blocked` 가 막힌 노드마다
   `(vtx, id, kind, status)` 를 돌려준다. 없었던 것은 질의가 아니라 **광고**다 —
   `Base.return_types` 가 맨 `NamedTuple` 로 넓어져 필드가 한 글자도 안 실렸다.
   같은 넓어짐이 런 16 을 죽인 `translate_whole_build!` 에도 있었다(`_status_symbols` 가
   그 절반을 갚았고, 이것이 나머지 절반이다).

🔴 **return 위치의 리터럴만** 센다. 안 그러면 body 중간에서 짓는 남의 튜플이 섞인다 —
   `zone_blockage` 는 `push!(blocked, (vtx = …, id = …, kind = …, status = …))` 로 **원소**를
   짓는데, 그 넷을 최상위 필드로 광고하면 거짓말이 된다(실측으로 확인: return 위치로 좁히니
   그 넷이 안 섞였다).

⚠️ **구문적 상계다.** 갈래마다 필드 집합이 다를 수 있고 이것은 그 **합집합**이다 — 한 번의
   호출이 전부를 돌려준다는 뜻이 아니다. 그래서 문구가 `fields seen in source` 다.

🔴 삼상: 못 유도하면 **키를 안 만든다**. 그리고 호출부가 **유도가 맨 `NamedTuple` 일 때만**
   묻는다 — 타입이 이미 필드를 말하고 있으면 이것은 둘째 진실원이고, 둘이 갈리는 날 아무도
   못 잡는다(규약 6 이 `soc` 에서 걷어낸 것과 같은 결함 부류).
"""
function _returned_fields(m::Method)
    ex = _defining_expr(m)
    ex === nothing && return nothing
    # NamedTuple 리터럴이면 필드 이름, 아니면 `nothing`. 두 표기를 다 받는다:
    # `(; a = 1, b = 2)` 는 `Expr(:parameters, …)`, `(a = 1, b = 2)` 는 `Expr(:(=), …)`.
    # 🔴 누산기와 **다른 이름**이어야 한다. 안쪽 이름이 `acc` 면 그것은 새 지역변수가 아니라
    #    바깥 함수의 `acc` 를 가리키고(줄리아의 클로저 포획), 호출마다 누산기가 초기화돼
    #    **마지막 return 의 필드만** 남는다. 실측 2026-09-05: `translate_whole_build!` 의
    #    세 갈래 중 `detail` 이 조용히 사라졌고, 최상위 함수로 쓴 프로토타입과 견주지
    #    않았으면 그 침묵을 "그 필드가 없다"로 읽었을 것이다.
    names_of = _nt_names
    acc = Set{Symbol}()
    walk(x) = begin
        x isa Expr || return
        if x.head === :return && length(x.args) == 1
            ns = names_of(x.args[1])
            ns === nothing || union!(acc, ns)
        end
        foreach(walk, x.args)
    end
    walk(ex)
    isempty(acc) && return nothing
    return sort!(String[string(s) for s in acc])
end

"""
    _returns_are_exhaustive(m::Method) -> Bool

`_returned_fields` 가 거둔 목록이 이 메서드의 **모든** 반환 경로를 덮는가.

🔴 왜 존재하나 (2026-09-05, 난수 존 시드 1). 주조 body 가 `zone_blockage(...).n_nav_blocked`
   를 읽고 던졌다 — 그 필드는 `zone_diagnosis` 것이지 `zone_blockage` 것이 아니다. 그런데
   렌더 문구가 `fields seen in source:` 라, **삼상 규율상 목록에 없는 이름은 "없다" 가 아니라
   "모른다"** 다. 모델의 읽기가 옳았고 우리 광고가 덜 말한 것이다. 수확이 실제로 모든 반환
   경로를 덮는 자리에서는 그렇게 말해 줘야 **부재가 판단 근거**가 된다.

보수적으로 판정한다 — 확신할 수 없으면 **거짓**이다. 과소주장은 삼상을 지키지만, 과대주장은
모델을 없는 사실 위에 세운다(이 레인이 갚고 있는 바로 그 부채다):
  · 중첩 함수·클로저·`do` 블록 안의 `return` 은 **이 메서드의 반환이 아니다** — 안 내려간다.
  · 남은 `return` 이 하나라도 NamedTuple 리터럴이 아니면 거짓(인자 없는 `return` 포함).
  · 본문의 **마지막 문장이 `return` 이 아니면 거짓.** 줄리아는 마지막 식을 암묵 반환하는데
    `_returned_fields` 는 `Expr(:return, …)` 만 거두므로, 꼬리가 return 이 아니면 그 경로는
    애초에 수확되지 않았다 — 그 상태로 "완전하다" 고 말하면 거짓말이다.
  · 짧은 형(`f(x) = …`)은 본문이 블록이 아니라 거짓이다. 그 경우 `_returned_fields` 도
    `nothing` 을 내므로 이 값이 실릴 자리 자체가 없다.
"""
function _returns_are_exhaustive(m::Method)
    ex = _defining_expr(m)
    ex === nothing && return false
    isfn(x) = x isa Expr && (x.head === :function || x.head === :-> || x.head === :do ||
                             (x.head === :(=) && !isempty(x.args) && x.args[1] isa Expr &&
                              x.args[1].head === :call))
    (ex isa Expr && ex.head === :function && length(ex.args) >= 2) || return false
    body = ex.args[2]
    (body isa Expr && body.head === :block) || return false
    ok = Ref(true); n = Ref(0)
    walk(x) = begin
        x isa Expr || return
        isfn(x) && return                                  # 남의 반환이다
        if x.head === :return
            n[] += 1
            (length(x.args) == 1 && _nt_names(x.args[1]) !== nothing) || (ok[] = false)
            return
        end
        foreach(walk, x.args)
    end
    foreach(walk, body.args)
    ok[] || return false
    n[] >= 1 || return false
    tail = nothing
    for a in body.args
        a isa LineNumberNode && continue
        tail = a
    end
    return tail isa Expr && tail.head === :return
end

"""
    _field_element_fields(m::Method) -> Union{Nothing,Vector{String}}

반환 NamedTuple 의 어떤 필드가 **NamedTuple 의 벡터**일 때, 그 **원소**의 필드 이름.
못 유도하면 `nothing`. 모양: `"blocked[] :: (id, kind, status, vtx)"`.

🔴 왜 존재하나 (2026-09-05, 유료 런 27·28·29). (라)가 `zone_blockage(...).blocked` 를
   광고하자 **세 판 다 그것을 찾아 썼다** — 개입은 도달했다. 그리고 **세 판 다 똑같이**
   그것을 *id 의 목록*으로 읽었다(`env.sched.vtx_map[blocked_id]` · `node.id in blocked_ids`).
   실제 원소는 `(vtx, id, kind, status)` 라 매칭이 전부 빗나갔고, 셋 다 빈손으로 끝났다
   (`"a reported blocked goal is absent from the schedule"` · `"found 0"` · 잰 무동작).
   ⟹ 필드 **이름**만 광고하고 그 안의 **모양**을 안 광고하면, 모델은 그 필드에 손을 뻗은
   다음 바로 거기서 넘어진다. 광고는 손이 닿는 데까지 이어져야 한다.

규칙 하나: return 자리의 NamedTuple 에서 `field = <지역변수>` 짝을 모으고, 그 지역변수에
`push!(var, (a = …, b = …))` 하는 자리에서 원소의 필드 이름을 수확한다. 두 조각이 **같은
메서드 안**에 있어야 하므로 남의 튜플이 섞이지 않는다.

⚠️ **구문적 상계다** — 갈래마다 원소 모양이 다를 수 있고 이것은 합집합이다(`zone_blockage`
   은 `:engulfed`·`:disconnected` 두 자리에서 같은 모양을 push 한다). 그래서 렌더 문구가
   `elements seen in source` 다.

🔴 삼상: 짝을 못 찾거나 `push!` 가 없으면 **키를 안 만든다**.
⚠️ 오늘 이 둘의 원소 타입은 광고에서 맨 `Vector{NamedTuple}` 이라 **둘째 진실원이 아니다**
   (타입이 침묵하는 자리를 메운다). 누군가 그 타입을 좁히는 날 시험 (9e)가 그것을 알린다.
"""
function _field_element_fields(m::Method)
    ex = _defining_expr(m)
    ex === nothing && return nothing
    names_in(x) = begin
        (x isa Expr && x.head === :tuple) || return nothing
        got = Symbol[]
        for a in x.args
            kws = (a isa Expr && a.head === :parameters) ? a.args : Any[a]
            for kw in kws
                (kw isa Expr && (kw.head === :kw || kw.head === :(=)) &&
                 kw.args[1] isa Symbol) && push!(got, kw.args[1])
            end
        end
        isempty(got) ? nothing : got
    end
    # return 자리의 `field = <지역변수>` 짝. 값이 Symbol 인 것만 — 리터럴이나 식은 벡터가 아니다.
    f2v = Pair{Symbol,Symbol}[]
    collect_pairs(x) = begin
        (x isa Expr && x.head === :tuple) || return
        for a in x.args
            kws = (a isa Expr && a.head === :parameters) ? a.args : Any[a]
            for kw in kws
                (kw isa Expr && (kw.head === :kw || kw.head === :(=)) &&
                 kw.args[1] isa Symbol && kw.args[2] isa Symbol) &&
                    push!(f2v, kw.args[1] => kw.args[2])
            end
        end
    end
    wr(x) = begin
        x isa Expr || return
        x.head === :return && length(x.args) == 1 && collect_pairs(x.args[1])
        foreach(wr, x.args)
    end
    wr(ex)
    isempty(f2v) && return nothing
    vars = Set{Symbol}(last(p) for p in f2v)
    acc = Dict{Symbol,Set{Symbol}}()
    wp(x) = begin
        x isa Expr || return
        if x.head === :call && length(x.args) == 3 && x.args[1] === :push! &&
           x.args[2] isa Symbol && x.args[2] in vars
            ns = names_in(x.args[3])
            ns === nothing || union!(get!(acc, x.args[2], Set{Symbol}()), ns)
        end
        foreach(wp, x.args)
    end
    wp(ex)
    isempty(acc) && return nothing
    out = String[]
    seen = Set{Symbol}()
    for (fld, var) in sort!(f2v; by = p -> string(first(p)))
        (fld in seen || !haskey(acc, var)) && continue
        push!(seen, fld)
        push!(out, string(fld, "[] :: (",
                          join(sort!(String[string(s) for s in acc[var]]), ", "), ")"))
    end
    isempty(out) ? nothing : out
end

"""
    _element_type(rt) -> Union{Nothing,String}

이 반환을 **순회하면 무엇이 나오는가**. 못 말하면 `nothing`.

🔴 왜 (2026-09-05, 유료 런 19). 그 판의 둘째 body 가
   `MethodError: no method matching get_center(::Pair{Symbol, Ball2})` 로 죽었다 —
   `active_restriction_zones()` 를 `collect` 하면 **`Pair` 가 나오는데**, 우리가 광고한
   타입은 `Base.Generator{Dict{Symbol,Ball2}, var"#817#818"}` 이라 원소가 무엇인지 한 글자도
   안 알려줬다. 반환 **타입**은 있었고 반환 **원소**가 없었다.

두 경로다. 둘 다 기계다:
  · `Base.Generator{I,F}` — 안쪽 함수를 `eltype(I)` 위에서 유도한다(실측: `Pair{Symbol, Ball2}`).
  · 그 밖 — `eltype(rt)`.

🔴 `eltype(rt) === rt` 인 판은 **안 싣는다.** 줄리아는 순회 불가 타입에 대해 `eltype(T) = T`
   를 주므로(`eltype(Int64) === Int64`), 그것을 실으면 스칼라마다 "순회하면 자기 자신이
   나온다" 는 무의미한 줄이 213개 붙는다. `Any` 도 안 싣는다 — 약속이 없다.
"""
function _element_type(rt)
    et = try
        if rt isa DataType && rt <: Base.Generator && length(rt.parameters) >= 2
            I, F = rt.parameters[1], rt.parameters[2]
            isdefined(F, :instance) || return nothing
            r = try Base.return_types(F.instance, Tuple{eltype(I)}) catch; return nothing end
            length(r) == 1 || return nothing
            only(r)
        else
            eltype(rt)
        end
    catch
        return nothing
    end
    (et === Any || et === rt || et === Union{}) && return nothing
    return _render_return(et)
end

"""
    method_entries(reach, acc) -> Vector{Dict}

각 메서드에 **호출 가능성**(`callable`)과 **인자마다의 도달 경로**(`argpaths`)를 붙인다.
`callable` 은 "모든 인자를 `env` 에서(또는 스칼라로) 손에 넣을 수 있다" 는 뜻이고,
`argpaths` 는 그 손에 넣는 방법을 `이름 <- 경로` 로 적은 줄들이다.

⚠️ **둘은 같은 강도의 주장이 아니다.** `callable` 이 보는 것은 `reach`(= 폐포 **멤버십**)이고
   `argpaths` 가 보는 것은 `acc`(= 실제 **경로**)다. 폐포에는 있는데 `env` 로부터의 경로가
   아직 없는 타입이 있으므로 — 오늘 `callable` 인 것의 다수가 `argpaths` 가 비어 있다 —
   `callable=true` 를 "이 줄만 보고 바로 부를 수 있다" 로 읽으면 안 된다. 그 강한 주장을
   나르는 것은 **`argpaths` 가 비어 있지 않은 항목**뿐이다.

🔴 그 정직함이 줄리아 주석에만 있고 모델이 읽는 표제에는 반대로 적혀 있던 것이 리뷰 I1 이다.
   그래서 셋째 필드 `missing` 을 같이 싣는다(`_missing_types`) — 렌더는 두 표제 **모두**에
   그것을 적으므로, 프롬프트와 이 주석이 같은 것을 말한다.

⚠️ `argpaths` 는 `callable` 인 항목에만 붙는다(설계 §6.2 의 둘째 표제 모양은 경로 줄이 없다).
   못 부르는 것의 "무엇이 없나" 는 `missing` 이 나른다.
"""
function method_entries(reach, acc)
    out = Dict{String,Any}[]
    for n in sort(names(CB))
        isdefined(CB, n) || continue
        f = getfield(CB, n)
        f isa Function || continue
        for m in methods(f)
            Ts = collect(Base.unwrap_unionall(m.sig).parameters)[2:end]
            callable = all(T -> _arg_obtainable(T, reach), Ts)
            paths = String[]
            if callable
                nms = Base.method_argnames(m)
                for (i, T) in enumerate(Ts)
                    S = _unwrap(T)
                    (S === CB.PlannerEnv || S === Any) && continue
                    ps = get(acc, _tname(S), String[])
                    isempty(ps) && continue
                    nm = length(nms) >= i + 1 ? String(nms[i + 1]) : "_"
                    startswith(nm, "#") && (nm = "_")
                    # Ruling R11 → R33: 하나로 접지도, 정밀도순으로 자르지도 않는다.
                    # `ps` 는 이미 사전순이고 상한은 오늘 안 문다 — 판정식이 여기 없다는
                    # 사실(진실원 하나)은 그대로다.
                    for p in first(ps, _MAX_PATHS)
                        push!(paths, string(nm, " <- ", p))
                    end
                end
            end
            e = Dict{String,Any}("name" => string(n), "signature" => _sig_string(m),
                                 "callable" => callable, "argpaths" => paths,
                                 "missing" => _missing_types(Ts, acc))
            # 🔴 삼상: 유도 못 한 반환은 **키를 안 만든다**(`_method_returns` 의 표 참조).
            r = _method_returns(f, m)
            r === nothing || (e["returns"] = r)
            # 🔴 2026-09-05. 유도가 **넓어지는 자리**를 두 기계 사실로 메운다(런 16·19 가
            #    각각 그 자리에서 죽었다). 같은 삼상 규약: 못 유도하면 키를 안 만든다.
            ss = _status_symbols(m)
            ss === nothing || (e["status_symbols"] = ss)
            sm = _status_meanings(m)
            sm === nothing || (e["status_meanings"] = sm)
            ac = _arg_coercions(m)
            ac === nothing || (e["arg_coercions"] = ac)
            # 🔴 **유도가 아무 말도 못 했을 때만** 소스로 내려간다. 타입이 이미 필드를
            #    말하고 있으면 이것은 둘째 진실원이다(`_returned_fields` 의 docstring).
            if r == "NamedTuple"
                rf = _returned_fields(m)
                if rf !== nothing
                    e["returned_fields"] = rf
                    # 🔴 삼상: **참일 때만** 키를 만든다. 키가 없는 것은 "불완전하다" 가
                    #    아니라 "완전한지 못 말한다" 이고, 렌더가 그 둘을 같은 문구로 낸다.
                    _returns_are_exhaustive(m) && (e["returned_fields_complete"] = true)
                end
            end
            # 🔴 게이트를 안 건다. 오늘 이 자리의 원소 타입은 광고에서 맨
            #    `Vector{NamedTuple}` 이라 타입이 **침묵**하고, 그래서 둘째 진실원이 아니다
            #    (`returned_fields` 와 다른 점이다 — 그쪽은 타입이 말할 수 있는 자리였다).
            fe = _field_element_fields(m)
            fe === nothing || (e["field_element_fields"] = fe)
            rt = _infer_return(f, tt_of(m))
            if rt !== nothing
                et = _element_type(rt)
                et === nothing || (e["element_type"] = et)
            end
            push!(out, e)
        end
    end
    # 결정적 정렬 (Ruling R-SORT): Julia 의 method-table 순회 순서는 보장된 계약이
    # 아니다. testset (2) 가 새 서브프로세스 재생성물과 커밋된 사본을 바이트째 비교하므로,
    # 이 정렬이 없으면 그 비교가 실행마다 이유 없이 흔들릴 수 있다.
    # F6: `alg=MergeSort` 로 명시 — 기본 정렬은 안정 정렬이 아니다. 오늘의 항목들은
    # (name, signature) 쌍이 우연히 전부 유일해서 불안정 정렬로도 바이트가 재현됐을 뿐이고,
    # 그 유일성은 계약이 아니다(같은 이름·같은 시그니처 문자열을 내는 두 메서드가 생기면
    # 불안정 정렬은 둘의 순서를 실행마다 바꿀 수 있다) — 안정 정렬이면 그 경우에도 항상
    # `methods()` 가 준 순서를 보존해 재현성이 구조로 유지된다.
    sort!(out, by = e -> (e["name"], e["signature"]), alg = MergeSort)
    return out
end

closure = world_type_closure()
types   = Dict{String,Any}[type_entry(T) for T in closure]
acc     = access_index(closure)
reach   = Set(String[_tname(S) for S in closure])

dst = length(ARGS) >= 1 ? ARGS[1] :
      normpath(joinpath(@__DIR__, "..", "src", "decision", "core",
                        "world_interface.json"))
open(dst, "w") do io
    JSON3.pretty(io, Dict("types" => types,
                          "access" => acc,
                          "methods" => method_entries(reach, acc),
                          "ambient" => [Dict("name" => a.name, "accessor" => a.accessor,
                                             "returns" => a.returns,
                                             "precondition" => a.precondition)
                                        for a in AMBIENT_ROOTS]))
end
println("wrote ", dst)
