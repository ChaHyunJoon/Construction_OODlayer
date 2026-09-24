# =============================================================================
# episode_checkpoint.jl — 전체 checkpoint capture/export/import (T2). 설계 §5·§2·§3.1.
#
# 로드: 독립 모듈이다(`RepairTypes` 와 같은 모양). ConstructionBots 를 import 하지 않는다 —
#   잡을 모듈은 호출자가 `modules` 로 넘긴다(production 은 `[CB, Main]`: render_demo.jl·policy.jl·
#   enact.jl 이 Main 에 스크립트 전역을 둔다). 🔴 production 경로에는 아직 배선하지 않았다(T8).
#
# 🔴 세 원칙
#   1. **한 객체 그래프.** env 와 전역을 하나의 `serialize` 로 쓴다 — 전역마다 따로 deepcopy 하면
#      env 가 가리키는 노드와 전역이 가리키는 노드가 갈라진다(설계 §5). 복원은 deserialize 한 새
#      그래프를 **살아 있는 const 컨테이너 안에 setfield! 로 옮겨 심는다**(재구축하지 않는다 —
#      Dict 를 empty!/merge! 로 다시 채우면 용량이 달라 순회 순서가 바뀐다).
#   2. **목록은 반사(reflection)로 만든다.** 이름표(`STATE_GLOBALS`)는 사람이 적은 목록이라 빠질 수
#      있고, 이 파일이 그 표에 기대면 표의 구멍이 인증의 구멍이 된다. 대상 모듈의 **모든** 바인딩 중
#      바뀔 수 있는 것(비-const 전역 전부 + 가변 내용을 가진 const)을 잡는다. 빼는 것은
#      `EXCLUDED_TYPES` 와 `_skip_binding` 에 사유와 함께 적힌 것뿐이다.
#   3. **동일성 증거는 정준 행(canonical lines)이다.** `SimState.state_hash`·반올림 해시를 쓰지
#      않는다. 정준 행은 그래프를 결정적 순서로 걷고 부동소수는 왕복 정확한 repr 로, 공유 참조는
#      **첫 방문 경로**로 적는다 — 그래서 포인터 없이도 alias 구조까지 같은지 본다(프로세스 독립).
#      `artifact_sha256` 은 파일 바이트의 digest(= 이 파일이 그 파일인가), `block_sha256` 은 블록별
#      정준 행 digest(= 이 세계가 그 세계인가)다. 둘은 다른 주장이다.
#
# ⚠️ 이 파일이 **못 하는 것**(→ `certification_gaps` 에 사유로 남는다, 조용히 덮지 않는다):
#   - RVO native 상태(PyCall rvo2): T3 adapter 전까지 `:native` 블록은 pending 이다.
#   - 실행 루프의 지역 변수(step k, no-progress 계수기, dispatch cursor): 전역이 아니라 스택에 산다.
#     t0 hook(T3)이 `loop_state` 로 넘겨야 하고, 안 넘기면 인증 불가다.
#   - 원본 task contract(T5), 존 주입 전/후 digest(T3).
#   - 대상 모듈 밖(의존 패키지)의 전역은 훑지 않는다.
# =============================================================================
isdefined(@__MODULE__, :RepairTypes) || include(joinpath(@__DIR__, "repair_types.jl"))

module EpisodeCheckpointIO

using Serialization, Random, SHA, JSON3
import ..RepairTypes: EpisodeCheckpoint, Fingerprints, CHECKPOINT_BLOCKS, certification_gaps

const CHECKPOINT_FORMAT = "episode-checkpoint/1"

"""
복원 수치 허용오차. **0.0 이다** — 직렬화는 무손실이고 부동소수는 비트 그대로 돌아와야 한다.
0 이 아닌 값이 필요한 비교(재생·재계산 궤적, T3)는 `diff_worlds(...; atol)` 에 **자기 상수를 명시해**
넘긴다. 이 기본값을 올려서 복원 결함을 가리지 말 것.
"""
const RESTORE_FLOAT_ATOL = 0.0

# ---- 대상 목록 -----------------------------------------------------------------------------
"상태가 아닌 가변 타입(사유): 컴파일된 정규식은 Ptr 을 들고 불변 패턴이고, 락은 동기화 도구다."
const EXCLUDED_TYPES = (Regex, Base.AbstractLock)

"""
블록 배정(설계 §5 표). 여기 없는 전역은 `:globals`. `:native` 의 `adapter=:pending` 은 **직렬화하지
않고** 인증 불가 사유로 남긴다(PyObject 를 Serialization 이 조용히 Ptr 바이트로 쓰는 것을 막는다).
"""
const GLOBAL_BLOCK = Dict{Symbol,Symbol}(
    :RESPEC_QUEUE => :events_rng, :OOD_SCHEDULE => :events_rng, :HAZARD_STATE => :events_rng,
    :OOD_EVENT_TARGET => :events_rng, :OOD_TRUTH_LOG => :events_rng, :SIM_STEP => :execution,
    :RVO_ID_GLOBAL_MAP => :native, :RVO_SIM_WRAPPER => :native, :RVO_PYTHON_MODULE => :native,
    :MONITOR_IO => :ledger_boundary, :RUN_CTX => :ledger_boundary, :_RID_CTR => :ledger_boundary)

"RVO native 핸들. T3 가 export/import adapter 를 만들기 전까지 checkpoint 는 인증 불가다."
const NATIVE_PENDING = Set([:RVO_SIM_WRAPPER, :RVO_PYTHON_MODULE])

"""
원장 sink: 실제 스트림 파일 핸들. 분기(shadow) 출력이 실제 원장에 쓰면 안 되므로 **복원 시 떼어낸다**
(`nothing`). 떼기 전 이름·위치는 artifact 에 감사용으로 남긴다. 정준 행에서는 둘 다 `ledger_sink` 로
보인다 — 원본과 분기의 sink 가 다른 것은 설계다(설계 §5 원장 경계). T4 가 shadow sink 를 다시 꽂는다.
"""
const LEDGER_SINKS = Set([:MONITOR_IO])

"대상 모듈과 그 자식 모듈(자신 제외)."
function _module_tree(mods)
    out = Module[]
    walk(m) = (m in out || m === @__MODULE__) ? nothing : begin
        push!(out, m)
        for n in names(m; all = true)
            isdefined(m, n) || continue
            c = getfield(m, n)
            c isa Module && c !== m && parentmodule(c) === m && walk(c)
        end
    end
    foreach(walk, mods)
    return out
end

_holds_mutable(@nospecialize v) =
    v isa Union{String,Symbol} ? false :
    ismutable(v) ? true :
    (!isbits(v) && any(i -> isdefined(v, i) && _holds_mutable(getfield(v, i)), 1:nfields(v)))

"잡지 않는 바인딩의 사유. `nothing` = 잡는다."
function _skip_binding(m::Module, n::Symbol)
    s = String(n)
    startswith(s, "#") && return "compiler/docs internal"
    isdefined(m, n) || return "undefined"
    v = getfield(m, n)
    v isa Module && return "module"
    v isa Type && isconst(m, n) && return "type"
    any(T -> v isa T, EXCLUDED_TYPES) && return "excluded type $(typeof(v))"
    isconst(m, n) && !_holds_mutable(v) && return "const immutable"
    return nothing
end

struct GlobalEntry
    mod::Module
    name::Symbol
    isconst::Bool
    block::Symbol
    handling::Symbol     # :graph | :native_pending | :ledger_sink
end

"""
    global_inventory(modules) -> Vector{GlobalEntry}

반사로 만든 전역 목록. 정렬 순서가 정준 행의 방문 순서이므로 결정적이어야 한다.
"""
function global_inventory(modules)
    out = GlobalEntry[]
    for m in _module_tree(modules), n in sort!(collect(names(m; all = true)); by = String)
        _skip_binding(m, n) === nothing || continue
        h = n in NATIVE_PENDING ? :native_pending : n in LEDGER_SINKS ? :ledger_sink : :graph
        push!(out, GlobalEntry(m, n, isconst(m, n), get(GLOBAL_BLOCK, n, :globals), h))
    end
    sort!(out; by = e -> (join(fullname(e.mod), "."), String(e.name)))
end

_gkey(e::GlobalEntry) = join(fullname(e.mod), ".") * "." * String(e.name)

# ---- env 분할 -----------------------------------------------------------------------------
"task_world 로 가는 env 필드(원본 작업·기하). 나머지 env 필드는 전부 `:execution` — 새 필드도 자동으로 잡힌다."
const TASK_WORLD_FIELDS = (:sched, :scene_tree, :staging_circles)

_env_blocks(env) = (
    task_world = [f for f in fieldnames(typeof(env)) if f in TASK_WORLD_FIELDS],
    execution  = [f for f in fieldnames(typeof(env)) if !(f in TASK_WORLD_FIELDS)])

# ---- 정준 행 -------------------------------------------------------------------------------
# 타입 이름은 **호출자 문맥과 무관하게** 적는다: `string(T)` 는 Main 이 무엇을 `using` 했는지에 따라
# `SimpleDiGraph{Int64}` 이기도 `Graphs.SimpleGraphs.SimpleDiGraph{Int64}` 이기도 하다 — 교차 프로세스
# 시험([9])이 정확히 이 차이로 빨개졌다(실측). 이 모듈을 문맥으로 고정한다.
const _TNAME = IdDict{Any,String}()
_tname(@nospecialize T) = get!(() -> sprint(show, T; context = :module => @__MODULE__), _TNAME, T)

_leaf_token(@nospecialize x) =
    x isa AbstractFloat ? "F:$(_tname(typeof(x))):$(repr(x))" :
    x isa Union{Integer,Char,Nothing,Missing,Symbol,String} ? "V:$(_tname(typeof(x))):$(repr(x))" : nothing

_key_seg(@nospecialize k) = k isa Union{Symbol,String,Integer} ? "[$(repr(k))]" : nothing

mutable struct _Walk
    lines::Vector{String}
    seen::IdDict{Any,String}
    opaque::Vector{String}      # 직렬화로 옮길 수 없는 값의 경로
end

function _walk!(w::_Walk, path::String, @nospecialize x)
    t = _leaf_token(x)
    t === nothing || return push!(w.lines, path * "\t" * t)
    x isa Module && return push!(w.lines, path * "\tM:" * join(fullname(x), "."))
    x isa Type && return push!(w.lines, path * "\tT:" * _tname(x))
    T = typeof(x)
    if ismutable(x)
        r = get(w.seen, x, nothing)
        r === nothing || return push!(w.lines, path * "\t@ref " * r)
        w.seen[x] = path
    end
    if x isa Ptr || (T <: Base.IO && !(x isa IOBuffer)) || x isa Task
        push!(w.opaque, path * " :: " * _tname(T))
        return push!(w.lines, path * "\tOPAQUE:" * _tname(T))
    end
    if x isa Function && startswith(String(nameof(T)), "#")
        # 익명 closure: 타입 이름은 역직렬화 때마다 새로 생긴다(`__deserialized_types__`, 실측) — 이름
        # 대신 메서드 정의 위치와 포획 값으로 적는다.
        push!(w.lines, path * "\tFn:" * join(sort!(["$(m.file):$(m.line)" for m in methods(x)]), ","))
        for (i, f) in enumerate(fieldnames(T))
            isdefined(x, i) ? _walk!(w, "$(path).$(f)", getfield(x, i)) :
                              push!(w.lines, "$(path).$(f)\t#undef")
        end
    elseif x isa AbstractDict
        push!(w.lines, path * "\tD:$(_tname(T)):$(length(x))")
        for (i, (k, v)) in enumerate(x)       # 순회 순서가 곧 행 순서 — 순서가 바뀌면 행이 바뀐다
            seg = _key_seg(k)
            seg === nothing && (_walk!(w, "$(path){$(i)}.key", k); seg = "{$(i)}")
            _walk!(w, path * seg, v)
        end
    elseif x isa AbstractSet
        push!(w.lines, path * "\tS:$(_tname(T)):$(length(x))")
        for (i, v) in enumerate(x)
            _walk!(w, "$(path){$(i)}", v)
        end
    elseif x isa Array                         # 범위·뷰 같은 게으른 배열은 아래 필드 경로(원소를 펼치지 않는다)
        push!(w.lines, path * "\tA:$(_tname(T)):$(size(x))")
        for i in eachindex(x)
            isassigned(x, i) ? _walk!(w, "$(path)[$(i)]", x[i]) :
                               push!(w.lines, "$(path)[$(i)]\t#undef")
        end
    else
        push!(w.lines, path * "\tO:" * _tname(T))
        for (i, f) in enumerate(fieldnames(T))
            isdefined(x, i) ? _walk!(w, "$(path).$(f)", getfield(x, i)) :
                              push!(w.lines, "$(path).$(f)\t#undef")
        end
    end
    return nothing
end

"""
    world_lines(env; modules, loop_state=nothing, task_contract=nothing, fingerprints=nothing)
        -> (; lines, opaque, fields)

세계 전체를 정준 행으로 편다. 방문 순서 = 블록 순서(`CHECKPOINT_BLOCKS`) → 블록 안의 고정 순서.
`fields[i] = (block, field_name, first_line)` — 필드마다 연속 구간이다. **읽기만 한다**(capture
무부작용 시험이 이 성질을 잰다).
"""
function world_lines(env; modules, loop_state = nothing, task_contract = nothing,
                     fingerprints = nothing, rng = copy(Random.default_rng()))
    w = _Walk(String[], IdDict{Any,String}(), String[])
    fields = Tuple{Symbol,String,Int}[]
    field!(b, name, x) = (push!(fields, (b, name, length(w.lines) + 1)); _walk!(w, name, x))
    eb = _env_blocks(env)
    inv = global_inventory(modules)
    gwalk(b) = for e in inv
        e.block === b || continue
        k = "globals." * _gkey(e)
        e.handling === :graph ? field!(b, k, getfield(e.mod, e.name)) :
            (push!(fields, (b, k, length(w.lines) + 1));
             push!(w.lines, k * "\t" * (e.handling === :native_pending ? "ADAPTER_PENDING:T3" : "LEDGER_SINK")))
    end
    field!(:model_code, "fingerprints", fingerprints)
    for f in eb.task_world; field!(:task_world, "env.$(f)", getfield(env, f)); end
    field!(:task_world, "task_contract", task_contract)
    for f in eb.execution; field!(:execution, "env.$(f)", getfield(env, f)); end
    field!(:execution, "loop_state", loop_state); gwalk(:execution)
    gwalk(:globals)
    field!(:events_rng, "rng.default", rng); gwalk(:events_rng)
    gwalk(:native)
    gwalk(:ledger_boundary)
    return (; lines = w.lines, opaque = w.opaque, fields)
end

function _sha(lines)
    ctx = SHA.SHA256_CTX()
    for l in lines
        SHA.update!(ctx, codeunits(l)); SHA.update!(ctx, (0x0a,))
    end
    return bytes2hex(SHA.digest!(ctx))
end

_spans(lines, fields) = [(b, f, s, i < length(fields) ? fields[i+1][3] - 1 : length(lines))
                         for (i, (b, f, s)) in enumerate(fields)]

"블록별 정준 digest. 모든 블록이 키로 나온다(빈 블록도 — 빠진 블록과 구분하려고)."
function block_digests(lines, fields)
    acc = Dict(b => String[] for b in CHECKPOINT_BLOCKS)
    for (b, _, s, e) in _spans(lines, fields); append!(acc[b], @view lines[s:e]); end
    Dict(b => _sha(v) for (b, v) in acc)
end

"필드별 정준 digest(`env.sched`, `globals.ConstructionBots.RESTRICTION_ZONES`, `rng.default` …)."
field_digests(lines, fields) = Dict(f => _sha(@view lines[s:e]) for (_, f, s, e) in _spans(lines, fields))

# ---- 필드별 차이 --------------------------------------------------------------------------
function _float_close(ta, tb, atol)
    (startswith(ta, "F:") && startswith(tb, "F:")) || return false
    pa, pb = split(ta, ':'; limit = 3), split(tb, ':'; limit = 3)
    pa[2] == pb[2] || return false
    a, b = parse(Float64, pa[3]), parse(Float64, pb[3])
    return a === b || abs(a - b) <= atol
end

function _line_diff(a, b, atol)
    a == b && return nothing
    pa, ta = split(a, '\t'; limit = 2)
    pb, tb = split(b, '\t'; limit = 2)
    pa == pb && _float_close(ta, tb, atol) && return nothing
    return pa == pb ? "$(pa): $(ta)  !=  $(tb)" : "$(a)  !=  $(b)"
end

"""
    diff_worlds(A, B; atol = RESTORE_FLOAT_ATOL, per_field = 3) -> Vector{String}

`A`, `B` = `world_lines` 의 결과. **필드별로** 줄을 맞춰 비교한다(한 필드의 길이가 바뀌어도 뒤 필드의
보고가 밀리지 않는다). 부동소수는 `atol` 안이면 같다 — 그 밖의 모든 토큰(ID·graph·queue·RNG·alias
`@ref`)은 **정확히** 같아야 한다. 필드마다 첫 `per_field` 개 차이와 길이 차이를 적는다.
"""
function diff_worlds(A, B; atol::Real = RESTORE_FLOAT_ATOL, per_field::Int = 3)
    span(W) = Dict(f => (s, e) for (_, f, s, e) in _spans(W.lines, W.fields))
    sa, sb = span(A), span(B)
    out = String[]
    for f in unique!([[x[2] for x in A.fields]; [x[2] for x in B.fields]])
        haskey(sa, f) && haskey(sb, f) ||
            (push!(out, "$(f): only in $(haskey(sa, f) ? "A" : "B")"); continue)
        la, lb = view(A.lines, sa[f][1]:sa[f][2]), view(B.lines, sb[f][1]:sb[f][2])
        n = 0
        length(la) == length(lb) || (push!(out, "$(f): $(length(la)) lines != $(length(lb)) lines"); n += 1)
        for i in 1:min(length(la), length(lb))
            d = _line_diff(la[i], lb[i], atol)
            d === nothing && continue
            n >= per_field && (push!(out, "$(f): … more"); break)
            push!(out, d); n += 1
        end
    end
    return out
end

print_diff(io::IO, d::Vector{String}) =
    isempty(d) ? println(io, "[checkpoint] no difference") :
                 foreach(l -> println(io, "[checkpoint] ≠ ", l), d)

# ---- 직렬화 --------------------------------------------------------------------------------
# (1) Dict 레이아웃 보존. 표준 Serialization 은 Dict 를 (k,v) 로 쓰고 sizehint! 한 새 표에 다시 넣는다 —
#     용량이 달라져 **순회 순서가 바뀐다**(시험 [8] 이 실측한다). 여기서는 Dict 를 내부 배열째 쓰고,
#     읽은 뒤 모든 키가 제자리에서 찾아지는지 검사한다. 키 해시가 이 프로세스에서 다르면(포인터 기반
#     해시) 그 표만 rehash 하고 개수를 돌려준다 — 순서가 바뀌었는지는 정준 행 비교가 판정한다.
# (2) SubArray 보존. 표준은 뷰를 **잘라낸 사본**으로 쓴다(부모 공유가 사라진다 — ActionRegistry 의
#     JSON3 객체가 tape 를 뷰로 공유한다, 실측). 구조체 그대로 쓴다.
# (3) const 닻(anchor). const 바인딩은 다시 묶을 수 없다(컴파일된 코드가 옛 객체를 인라인한다). 그래서
#     const 가 가리키는 가변 객체들을 payload **맨 앞에** 쓰고, 읽을 때 각 객체의 내용을 살아 있는
#     객체에 옮긴 뒤 역참조 표의 그 칸을 **살아 있는 객체로 바꿔 끼운다** — 뒤에 오는 env·전역의
#     모든 참조가 새 사본이 아니라 살아 있는 객체를 가리키게 된다(env↔전역 alias 보존).
#     ⚠️ 한계: 닻 A 안에 다른 닻 B 가 먼저 중첩돼 쓰이면 A 속의 그 참조는 B 의 사본으로 남는다.
#     조용히 넘어가지 않는다 — 정준 행의 `@ref` 가 달라져 `verify_world` 가 잡는다.
mutable struct CkptSerializer{I<:IO} <: Serialization.AbstractSerializer
    io::I
    counter::Int
    table::IdDict{Any,Any}
    pending_refs::Vector{Int}
    known_object_data::Dict{UInt64,Any}
    version::Int
    dicts::Vector{Dict}
    live_keys::Vector{String}          # 읽을 때: 이 프로세스의 const 닻 이름(순서까지 같아야 한다)
    live::Vector{Any}                  # 읽을 때: 그 살아 있는 객체들
    transplanted::IdDict{Any,Any}      # 새 사본 → 살아 있는 객체
    CkptSerializer(io::I, live_keys = String[], live = Any[]) where {I<:IO} =
        new{I}(io, 0, IdDict(), Int[], Dict{UInt64,Any}(), Serialization.ser_version, Dict[],
               live_keys, live, IdDict{Any,Any}())
end

Serialization.serialize(s::CkptSerializer, d::Dict) = Serialization.serialize_any(s, d)
Serialization.serialize(s::CkptSerializer, v::SubArray{T,N,A}) where {T,N,A<:Array} =
    Serialization.serialize_any(s, v)
function Serialization.deserialize(s::CkptSerializer, T::Type{Dict{K,V}}) where {K,V}
    d = invoke(Serialization.deserialize, Tuple{Serialization.AbstractSerializer,DataType}, s, T)
    push!(s.dicts, d)
    return d
end

struct _Anchors
    keys::Vector{String}
    objs::Vector{Any}
end

function Serialization.serialize(s::CkptSerializer, a::_Anchors)
    Serialization.serialize_type(s, _Anchors, false)
    serialize(s, a.keys)
    write(s.io, Int64(length(a.objs)))
    foreach(o -> serialize(s, o), a.objs)
end

function Serialization.deserialize(s::CkptSerializer, ::Type{_Anchors})
    keys = deserialize(s)
    bykey = Dict(zip(s.live_keys, s.live))
    Set(keys) == Set(s.live_keys) || error("restore: const anchors differ from this process: " *
        "only in artifact $(first(setdiff(keys, s.live_keys), 5)), " *
        "only live $(first(setdiff(s.live_keys, keys), 5))")
    for i in 1:read(s.io, Int64)
        x = deserialize(s)
        live = bykey[keys[i]]
        x === live && continue                          # 같은 객체를 가리키는 두 번째 const
        slot = findfirst(v -> v === x, s.table)
        _restore_inplace!(live, x)
        slot === nothing || (s.table[slot] = live)
        s.transplanted[x] = live
    end
    return _Anchors(keys, Any[bykey[k] for k in keys])
end

"const 전역이 붙잡는 가변 객체(닻)들 — 불변 껍데기(closure·tuple·Set·JSON3 객체)는 필드로 내려간다."
function _anchors(inv)
    keys, objs = String[], Any[]
    leaf!(k, v) = v isa Union{String,Symbol} ? nothing :
        ismutable(v) ? (push!(keys, k); push!(objs, v); nothing) :
        isbits(v) ? nothing :
        foreach(i -> isdefined(v, i) && leaf!("$(k).$(fieldname(typeof(v), i))", getfield(v, i)),
                1:nfields(v))
    for e in inv
        e.handling === :graph && e.isconst && leaf!(_gkey(e), getfield(e.mod, e.name))
    end
    return keys, objs
end

function _foreach_child(f, @nospecialize x)
    x isa Union{Module,Type,String,Symbol} && return
    if x isa AbstractDict
        for (k, v) in x; f(k); f(v); end
    elseif x isa AbstractSet
        foreach(f, x)
    elseif x isa Array
        for i in eachindex(x); isassigned(x, i) && f(x[i]); end
    else
        for i in 1:nfields(x); isdefined(x, i) && f(getfield(x, i)); end
    end
end

"""
닻을 **후위 순서**로 늘어놓는다: 다른 닻을 품은 닻은 그 닻 뒤에 온다. 그래야 품은 쪽이 읽힐 때 안쪽
닻이 이미 살아 있는 객체로 바꿔 끼워져 있다(ActionRegistry 의 `REGISTRY` 와 `_RAW` 가 JSON3 tape
배열을 공유한다 — 이름순이면 `REGISTRY` 가 먼저 쓰여 tape 사본을 붙잡는다, 실측). 닻끼리 순환하면
순서로 풀 수 없다 — 그 경우는 `verify_world` 가 `@ref` 차이로 잡는다.
"""
function _anchor_order(objs)
    idx = IdDict{Any,Int}()
    for (i, o) in enumerate(objs); haskey(idx, o) || (idx[o] = i); end
    seen = IdDict{Any,Nothing}()
    out = Int[]
    function visit(x)
        isbits(x) && return
        if ismutable(x)
            haskey(seen, x) && return
            seen[x] = nothing
        end
        _foreach_child(visit, x)
        ismutable(x) && (i = get(idx, x, 0)) > 0 && push!(out, i)
    end
    foreach(visit, objs)
    dup = [i for i in eachindex(objs) if !(i in out)]   # 같은 객체를 가리키는 두 번째 const 이름
    return [out; dup]
end

"자리 검사를 통과 못 한 Dict 는 rehash 하고 그 개수를 돌려준다(옮겨 심은 Dict 는 살아 있는 쪽을 본다)."
function _fix_dicts!(s::CkptSerializer)
    n = 0
    for d0 in s.dicts
        d = get(s.transplanted, d0, d0)
        ok = all(i -> !Base.isslotfilled(d, i) || Base.ht_keyindex(d, d.keys[i]) == i,
                 eachindex(d.slots))
        ok || (Base.rehash!(d, length(d.keys)); n += 1)
    end
    return n
end

function _serialize_bytes(x)
    io = IOBuffer(); s = CkptSerializer(io)
    Serialization.writeheader(s); serialize(s, x)
    return take!(io)
end

function _deserialize_bytes(bytes; live_keys = String[], live = Any[])
    s = CkptSerializer(IOBuffer(bytes), live_keys, live)
    x = deserialize(s)
    return x, _fix_dicts!(s)
end

# ---- 복원 ---------------------------------------------------------------------------------
"살아 있는 가변 객체 `live` 의 내용을 새 그래프의 `v` 로 바꾼다(정체성은 live 를 유지)."
function _restore_inplace!(live, v)
    T = typeof(live)
    typeof(v) === T || error("restore: type drift $(T) vs $(typeof(v))")
    live === v && return nothing
    if live isa Array
        live isa Vector || error("restore: non-vector const array $(T) (unsupported)")
        resize!(live, length(v))
        for i in eachindex(v)
            isassigned(v, i) ? (live[i] = v[i]) : error("restore: #undef in Vector (unsupported)")
        end
    elseif ismutable(live)
        for i in 1:fieldcount(T)
            isdefined(v, i) || (isdefined(live, i) ?
                error("restore: $(T).$(fieldname(T, i)) is #undef in the artifact") : continue)
            if isconst(T, i)
                _restore_inplace!(getfield(live, i), getfield(v, i))
            elseif Base.isfieldatomic(T, i)
                setfield!(live, i, getfield(v, i), :sequentially_consistent)
            else
                setfield!(live, i, getfield(v, i))
            end
        end
    else
        error("restore: $(T) is immutable — anchors must be mutable")
    end
    return nothing
end

# ---- capture / export / import ------------------------------------------------------------
"""
    CheckpointCapture

`capture_checkpoint` 의 결과. `bytes` 가 artifact 이고 나머지는 그 artifact 에 대한 주장이다.
`gaps` 가 비어 있지 않으면 이 checkpoint 로는 인증할 수 없다.
"""
struct CheckpointCapture
    bytes::Vector{UInt8}
    artifact_sha256::String
    block_sha256::Dict{Symbol,String}
    field_sha256::Dict{String,String}
    lines::Vector{String}
    fields::Vector{Tuple{Symbol,String,Int}}
    gaps::Vector{String}
    inventory::Vector{GlobalEntry}
end

"""
    capture_checkpoint(env; modules, loop_state=nothing, task_contract=nothing,
                       fingerprints=nothing) -> CheckpointCapture

env·대상 모듈의 전역·기본 RNG 를 **한 번의 serialize** 로 쓴다. 세계와 RNG 를 바꾸지 않는다.

`loop_state` = t0 hook 이 넘기는 실행 루프 지역 상태(step 번호·no-progress 계수기·dispatch cursor).
`nothing` 이면 인증 불가 사유가 된다 — 이 함수는 스택을 볼 수 없다.
"""
function capture_checkpoint(env; modules, loop_state = nothing, task_contract = nothing,
                            fingerprints = nothing)
    rng = copy(Random.default_rng())
    inv = global_inventory(modules)
    W = world_lines(env; modules, loop_state, task_contract, fingerprints, rng)
    lines, opaque, fields = W.lines, W.opaque, W.fields
    gaps = String[]
    append!(gaps, ["native: $(_gkey(e)) — RVO adapter pending (T3)"
                   for e in inv if e.handling === :native_pending])
    append!(gaps, ["unserializable: $(p)" for p in opaque])
    loop_state === nothing && push!(gaps, "execution: runtime loop cursor not supplied (t0 hook, T3)")
    task_contract === nothing && push!(gaps, "task_world: original task contract not supplied (T5)")
    fingerprints === nothing && push!(gaps, "model_code: fingerprints not supplied")
    sinks = Dict{String,Any}()
    for e in inv
        e.handling === :ledger_sink || continue
        v = getfield(e.mod, e.name)
        io = v isa Base.RefValue ? v[] : v
        sinks[_gkey(e)] = io === nothing ? nothing : string(io)
    end
    # 닻이 **맨 앞**이다 — 뒤의 env·전역이 닻을 역참조로 가리켜야 복원 때 살아 있는 객체로 이어진다.
    vars = [(fullname(e.mod), e.name, getfield(e.mod, e.name))
            for e in inv if e.handling === :graph && !e.isconst]
    akeys, aobjs = _anchors(inv)
    ord = _anchor_order(aobjs)
    payload = (format = CHECKPOINT_FORMAT, anchors = _Anchors(akeys[ord], aobjs[ord]), vars = vars,
               env = env, loop_state = loop_state, task_contract = task_contract,
               fingerprints = fingerprints, rng = rng, ledger_sinks = sinks)
    bytes = _serialize_bytes(payload)
    copy(Random.default_rng()) == rng || error("capture advanced the RNG")   # 자기 검사
    return CheckpointCapture(bytes, bytes2hex(sha256(bytes)), block_digests(lines, fields),
                             field_digests(lines, fields), lines, fields, gaps, inv)
end

_resolve(modules, fname) = begin
    i = findfirst(m -> fullname(m) == fname, _module_tree(modules))
    i === nothing && error("restore: module $(join(fname, ".")) is not loaded in this process")
    _module_tree(modules)[i]
end

"""
    restore_checkpoint!(bytes; modules)
        -> (; env, loop_state, task_contract, fingerprints, n_dicts_rehashed)

artifact 를 이 프로세스의 세계로 옮긴다: const 가 붙잡은 가변 객체(닻)는 제자리에, 비-const 전역은 재바인딩,
기본 RNG 는 `copy!`, 원장 sink 는 떼어낸다(`nothing`). 반환 env 를 써야 한다 — 호출자가 들고 있던
env 는 옛 세계다.
"""
function restore_checkpoint!(bytes::Vector{UInt8}; modules)
    live_keys, live = _anchors(global_inventory(modules))
    p, nfix = _deserialize_bytes(bytes; live_keys, live)      # const 닻은 여기서 제자리 복원된다
    p.format == CHECKPOINT_FORMAT || error("restore: format $(p.format) != $(CHECKPOINT_FORMAT)")
    for (fname, n, v) in p.vars
        m = _resolve(modules, fname)
        isdefined(m, n) || error("restore: $(join(fname, ".")).$(n) no longer exists")
        isconst(m, n) && error("restore: $(n) became const")
        setglobal!(m, n, v)
    end
    for e in global_inventory(modules)
        e.handling === :ledger_sink || continue
        r = getfield(e.mod, e.name)
        r isa Base.RefValue ? (r[] = nothing) : error("restore: ledger sink $(e.name) is not a Ref")
    end
    copy!(Random.default_rng(), p.rng)
    return (; env = p.env, loop_state = p.loop_state, task_contract = p.task_contract,
            fingerprints = p.fingerprints, n_dicts_rehashed = nfix)
end

"""
    export_checkpoint(dir, checkpoint_id, env; modules, t0_hook, zone_dispatch_in_progress,
                      fingerprints, loop_state=nothing, task_contract=nothing,
                      pre_injection_sha256="", post_injection_sha256="")
        -> (EpisodeCheckpoint, CheckpointCapture)

`<dir>/<id>.jls`(artifact) 와 `<id>.fields.json`(블록·필드 digest, gaps, 전역 목록)을 쓴다.
주입 전/후 digest 가 비어 있으면(T3 전) 그것도 인증 불가 사유다.
"""
function export_checkpoint(dir, checkpoint_id, env; modules, t0_hook, zone_dispatch_in_progress,
                           fingerprints::Fingerprints, loop_state = nothing,
                           task_contract = nothing, pre_injection_sha256 = "",
                           post_injection_sha256 = "")
    c = capture_checkpoint(env; modules, loop_state, task_contract, fingerprints)
    isempty(pre_injection_sha256) && push!(c.gaps, "events_rng: pre-injection state digest not supplied (T3)")
    isempty(post_injection_sha256) && push!(c.gaps, "events_rng: post-injection state digest not supplied (T3)")
    mkpath(dir)
    path = joinpath(dir, checkpoint_id * ".jls")
    write(path, c.bytes)
    open(joinpath(dir, checkpoint_id * ".fields.json"), "w") do io
        JSON3.write(io, Dict("format" => CHECKPOINT_FORMAT, "checkpoint_id" => checkpoint_id,
            "artifact_sha256" => c.artifact_sha256,
            "block_sha256" => Dict(String(k) => v for (k, v) in c.block_sha256),
            "field_sha256" => c.field_sha256, "gaps" => c.gaps,
            "globals" => [Dict("name" => _gkey(e), "block" => String(e.block),
                               "const" => e.isconst, "handling" => String(e.handling))
                          for e in c.inventory]))
    end
    cp = EpisodeCheckpoint(checkpoint_id, t0_hook, zone_dispatch_in_progress, fingerprints,
                           path, c.artifact_sha256, c.block_sha256, pre_injection_sha256,
                           post_injection_sha256, copy(c.gaps))
    return cp, c
end

"""
    import_checkpoint(cp; modules) -> (; env, loop_state, task_contract, fingerprints,
                                         n_dicts_rehashed, mismatched_blocks)

파일 digest 가 `cp.artifact_sha256` 과 다르면 **에러**(다른 파일이다). 복원 뒤 세계를 다시 정준 행으로
펴서 블록 digest 를 기록값과 대조한다 — 원본이 없는 다른 프로세스에서도 되는 검사다.
`mismatched_blocks` 가 비어 있지 않으면 복원이 불완전하다 → 인증 불가로 다룰 것.
"""
function import_checkpoint(cp::EpisodeCheckpoint; modules)
    bytes = read(cp.artifact_path)
    got = bytes2hex(sha256(bytes))
    got == cp.artifact_sha256 ||
        error("import: artifact digest $(got) != recorded $(cp.artifact_sha256) — not the captured file")
    r = restore_checkpoint!(bytes; modules)
    return (; r..., mismatched_blocks = verify_world(cp, r; modules))
end

"""
    verify_world(cp, w; modules) -> Vector{Symbol}

`w` = `(; env, loop_state, task_contract, fingerprints)`(복원 결과 또는 살아 있는 세계). 지금 세계의
블록 정준 digest 가 checkpoint 의 기록과 다른 블록들을 돌려준다. 비어 있어야 복원이 정확하다.
"""
function verify_world(cp::EpisodeCheckpoint, w; modules)
    W = world_lines(w.env; modules, loop_state = w.loop_state,
                    task_contract = w.task_contract, fingerprints = w.fingerprints)
    now = block_digests(W.lines, W.fields)
    return Symbol[b for b in CHECKPOINT_BLOCKS if get(now, b, "") != get(cp.block_sha256, b, "")]
end

end # module EpisodeCheckpointIO
