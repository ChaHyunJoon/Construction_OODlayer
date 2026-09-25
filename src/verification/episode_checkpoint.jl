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
#   - RVO native 상태(PyCall rvo2): T3 adapter(`NATIVE_ADAPTERS` → `CB.rvo_export_state`/
#     `rvo_import_state!`)가 옮긴다. 옮길 수 없는 둘(`globalTime_`, `KdTree` 순열)은 rvo_interface.jl
#     머리말이 근거를 적고, 순열은 **분기 의무**(`native_obligations`, RVOTieWatch)로 넘어간다.
#   - 실행 루프의 지역 변수(step k, no-progress 계수기, dispatch cursor): 전역이 아니라 스택에 산다.
#     t0 hook(T3 `episode_replay.jl`)이 `loop_state` 로 넘겨야 하고, 안 넘기면 인증 불가다.
#   - 원본 task contract(T5). 존 주입 전/후 digest 는 호출자가 넘긴다(T3 hook 이 넘긴다).
#   - 대상 모듈 밖(의존 패키지)의 전역은 훑지 않는다 — 대신 **로드된 모든 의존 모듈을 분류해 적는다**:
#     `DEPENDENCY_ALLOWLIST`(사유 있는 이름 목록)·`_jll`·stdlib 이 아닌 모듈은 gap 이다(T2 minor, T3).
#     `Base.ENV` 는 예외적으로 잡는다(런타임에 `get(ENV, …)` 로 읽는 손잡이가 있다 — `ENV_ADAPTER`).
# =============================================================================
isdefined(@__MODULE__, :RepairTypes) || include(joinpath(@__DIR__, "repair_types.jl"))

module EpisodeCheckpointIO

using Serialization, Random, SHA, JSON3
import ..RepairTypes: EpisodeCheckpoint, Fingerprints, CHECKPOINT_BLOCKS, certification_gaps

const CHECKPOINT_FORMAT = "episode-checkpoint/2"   # /2 (T3): native adapter·ENV·의존 모듈 분류

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
    :MONITOR_IO => :ledger_boundary, :RUN_CTX => :ledger_boundary, :_RID_CTR => :ledger_boundary,
    # 모니터 기록부(대시보드 원장): sink 가 붙어 있을 때만 쌓인다 — 떼어낸 분기에서는 안 자란다(설계).
    :MONITOR_NODE_T => :ledger_boundary, :MONITOR_HANDOFF_T => :ledger_boundary,
    :MONITOR_RESPEC => :ledger_boundary, :MONITOR_RESPEC_HISTORY => :ledger_boundary,
    :MONITOR_RECOVERY_LOG => :ledger_boundary, :MONITOR_FAULTED => :ledger_boundary)

"adapter 가 없는 native 핸들(직렬화하지 않고 항상 gap). T3 이후 비어 있다 — 새 핸들이 생기면 여기 넣는다."
const NATIVE_PENDING = Set{Symbol}()

"""
native adapter: 전역 이름 → (export, import) 함수 이름. 함수는 그 전역을 정의한 모듈(`e.mod`)에서 찾는다
(이 모듈은 CB 를 import 하지 않는다). export 는 `(; state, residual, gaps)` 를 돌려주는 **읽기 전용**
함수이고 `state` 가 정준 행이 된다. import 는 `state` 로 핸들을 다시 만들고 분기 의무 객체를 돌려준다.
"""
const NATIVE_ADAPTERS = Dict{Symbol,Tuple{Symbol,Symbol}}(
    :RVO_SIM_WRAPPER => (:rvo_export_state, :rvo_import_state!))
"다른 adapter 가 함께 옮기는 native 핸들 → 그 adapter 의 전역 이름."
const NATIVE_COVERED = Dict{Symbol,Symbol}(:RVO_PYTHON_MODULE => :RVO_SIM_WRAPPER)

"""
하니스 계측(세계 상태가 아님): 프로세스마다 **자기 것**을 설치하므로 잡지도 복원하지도 않는다.
잡으면 capture 프로세스의 훅이 resume 프로세스에 되살아난다. 모듈 이름은 자식 모듈 보행에서 뺀다.
"""
const HARNESS_GLOBALS = Set([:HARNESS_HOOK, :RVO_RECORD_BUILDS,
                            :ENGINE_STEP_ADAPTER])                                                       # T6: 도구 body 의 step → trusted adapter
const HARNESS_MODULES = Set([:EpisodeCheckpointIO, :EpisodeReplay, :BranchRunner, :RepairBranchWorker,   # T4: supervisor·worker 하니스
                             :TaskContract, :EffectValidation, :ToolProposalGate,                       # T5: 신뢰 판정(세계 상태 없음)
                             :ToolExecution])                                                           # T6: 격리 집행 하니스

"""
대상 모듈 밖의 로드된 의존 모듈 분류(T2 minor). 전역을 훑지 **않는** 대신, 이름과 사유를 fields.json 에
남기고 목록 밖 모듈은 gap 으로 올린다 — 새 의존성이 조용히 들어오지 못한다. 사유는 "이 모듈의 전역이
에피소드 동역학을 나르지 않는다" 는 주장이고, 그 주장의 **증거는 T3 전 구간 재생 게이트**다(목록이 틀리면
복원 분기의 궤적이 원본과 갈린다). `_jll`(바이너리 경로 래퍼)과 stdlib 은 규칙으로 분류한다 —
stdlib 중 상태를 나르는 둘은 따로 잡는다: `Random` 기본 RNG(`rng.default`), `Base.ENV`(`ENV_ADAPTER`).
"""
const DEPENDENCY_ALLOWLIST = Dict{String,Vector{String}}(
    "solver binding: optimizer objects are created per solve inside the target modules; module globals are option tables/caches" =>
        ["JuMP", "MathOptInterface", "MathOptIIS", "MutableArithmetics", "HiGHS", "GLPK", "Gurobi", "ECOS"],
    "python bridge: interpreter handle; the only Python object the runtime reads is the rvo2 simulator (native adapter)" =>
        ["PyCall", "Conda", "VersionParsing"],
    "io/serialization/network: connection pools and codecs; the pi0 continuation makes no network call" =>
        ["HTTP", "HTTPExt", "MbedTLS", "OpenSSL", "URIs", "BitFlags", "ConcurrentUtilities",
         "ExceptionUnwrapping", "SimpleBufferStream", "LoggingExtras", "CodecBzip2", "CodecZlib",
         "TranscodingStreams", "JLD2", "FileIO", "MsgPack", "JSON", "JSON3", "StructTypes", "Parsers",
         "FFMPEG", "Inflate"],
    "visualization/progress output only (headless runs have no visualizer)" =>
        ["MeshCat", "Colors", "ColorTypes", "Compose", "Measures", "RecipesBase",
         "RotationsRecipesBaseExt", "ProgressMeter", "FixedPointNumbers"],
    "pure data structures/math: no mutable module state read by the simulation" =>
        ["AliasTables", "ArnoldiMethod", "CEnum", "CommonSubexpressions", "Compat",
         "CompatLinearAlgebraExt", "CoordinateTransformations", "CRlibm", "DataAPI", "DataStructures",
         "DiffResults", "DiffRules", "DocStringExtensions", "EnumX", "ErrorfreeArithmetic", "ExprTools",
         "FastRounding", "ForwardDiff", "ForwardDiffStaticArraysExt", "GeometryBasics", "Graphs",
         "HashArrayMappedTries", "IntervalArithmetic", "IrrationalConstants", "IterTools", "JLLWrappers",
         "LazySets", "LDrawParser", "LogExpFunctions", "MacroTools", "MetaGraphs", "Missings", "NaNMath",
         "OrderedCollections", "Parameters", "PrecompileTools", "Preferences", "PtrArrays", "Quaternions",
         "ReachabilityBase", "RealDot", "Reexport", "Requires", "Rotations", "RoundingEmulator",
         "ScopedValues", "SetRounding", "SimpleTraits", "SortingAlgorithms", "SpatialIndexing",
         "SpecialFunctions", "StaticArrays", "StaticArraysCore", "StaticArraysStatisticsExt", "StatsAPI",
         "StatsBase", "UnPack", "UnPackExt"])

"""
`Base.ENV` adapter. 값은 비밀이 아닌 키만 artifact 에 싣고(복원 때 맞춘다), 비밀 모양 키는 **값의
sha256 만** 싣는다(값을 쓰지 않는다 — 복원하지 않고 대조만). 하니스·출력 경로·세션 잡음 키는 뺀다:
분기마다 다른 것이 설계다(출력 디렉터리, 모드 스위치).
"""
const ENV_IGNORE_PREFIX = ("ZRV_", "TMUX", "TERM", "SSH_", "XDG_", "DBUS_", "LC_", "GPG_", "VSCODE", "CLAUDE")
const ENV_IGNORE = Set(["_", "PWD", "OLDPWD", "SHLVL", "DISPLAY", "WINDOWID", "COLUMNS", "LINES",
    "DEMO_OUT_DIR", "DEMO_SUMMARY", "MONITOR_STREAM", "MONITOR_RUN_ID", "STALL_PROBE_OUT",
    "TMPDIR"])   # TMPDIR (T4): 분기마다 자기 디렉터리 — 출력 위치와 같은 뜻
_env_ignored(k) = k in ENV_IGNORE || any(p -> startswith(k, p), ENV_IGNORE_PREFIX)
_env_secret(k) = occursin(r"KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL"i, k)
env_snapshot() = sort!([(k, _env_secret(k) ? "sha256:" * bytes2hex(sha256(v)) : v)
                        for (k, v) in ENV if !_env_ignored(k)]; by = first)

"""
원장 sink: 실제 스트림 파일 핸들. 분기(shadow) 출력이 실제 원장에 쓰면 안 되므로 **복원 시 떼어낸다**
(`nothing`). 떼기 전 이름·위치는 artifact 에 감사용으로 남긴다. 정준 행에서는 둘 다 `ledger_sink` 로
보인다 — 원본과 분기의 sink 가 다른 것은 설계다(설계 §5 원장 경계). T4 가 shadow sink 를 다시 꽂는다.
"""
const LEDGER_SINKS = Set([:MONITOR_IO])

"""
대상 모듈과 그 자식 모듈(하니스 모듈 제외). 🔴 `Base`·`Core` 는 **자식으로 보행하지 않는다**:
`parentmodule(Base) === Main` 이라 `modules` 에 Main 을 넣으면 Base 의 모든 전역(메서드 표·컴파일러
캐시)이 딸려 들어온다 — T3 첫 tractor capture 가 이것으로 110 GB 를 먹었다(`Base._NAMEDTUPLE_NAME.mt…`).
Base 전역 중 에피소드 상태는 기본 RNG(`rng.default`)와 `ENV`(`ENV_ADAPTER`)뿐이고 둘은 따로 잡는다.
"""
function _module_tree(mods)
    out = Module[]
    walk(m) = (m in out || m === Base || m === Core || nameof(m) in HARNESS_MODULES) ? nothing : begin
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
    n in HARNESS_GLOBALS && return "harness hook (each process installs its own)"
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
    handling::Symbol     # :graph | :native_adapter | :native_covered | :native_pending | :ledger_sink
end

_handling(n) = n in NATIVE_PENDING ? :native_pending : haskey(NATIVE_ADAPTERS, n) ? :native_adapter :
               haskey(NATIVE_COVERED, n) ? :native_covered : n in LEDGER_SINKS ? :ledger_sink : :graph

"native adapter 의 export 결과(`(; state, residual, gaps)`). 함수는 그 전역의 모듈에서 찾는다."
_native_export(e) = Base.invokelatest(getfield(e.mod, NATIVE_ADAPTERS[e.name][1]))
_native_import!(e, d) = Base.invokelatest(getfield(e.mod, NATIVE_ADAPTERS[e.name][2]), d.state, d.residual)

"""
    dependency_modules(modules) -> Vector{NamedTuple{(:name, :class, :reason)}}

로드된 최상위 모듈 중 대상(과 Core/Base/Main)이 아닌 것의 분류. `class = :unlisted` 가 gap 이다.
"""
function dependency_modules(modules)
    roots = Set(Base.moduleroot(m) for m in modules)
    reason = Dict(n => r for (r, ns) in DEPENDENCY_ALLOWLIST for n in ns)
    out = NamedTuple{(:name, :class, :reason),Tuple{String,Symbol,String}}[]
    for m in Base.loaded_modules_array()
        (parentmodule(m) === m && !(m in roots) && !(m in (Core, Base, Main))) || continue
        n = String(nameof(m)); p = pathof(m)
        push!(out, endswith(n, "_jll") ? (name = n, class = :jll, reason = "binary artifact wrapper: library paths set at __init__") :
            (p === nothing || startswith(p, Sys.STDLIB)) ?
                (name = n, class = :stdlib, reason = n == "Random" ? "default RNG captured as rng.default" :
                                                   "stdlib: no episode state read by the simulation") :
            haskey(reason, n) ? (name = n, class = :allowlisted, reason = reason[n]) :
                                (name = n, class = :unlisted, reason = "not scanned and not allowlisted"))
    end
    sort!(out; by = x -> x.name)
end

"""
    global_inventory(modules) -> Vector{GlobalEntry}

반사로 만든 전역 목록. 정렬 순서가 정준 행의 방문 순서이므로 결정적이어야 한다.
"""
function global_inventory(modules)
    out = GlobalEntry[]
    for m in _module_tree(modules), n in sort!(collect(names(m; all = true)); by = String)
        _skip_binding(m, n) === nothing || continue
        push!(out, GlobalEntry(m, n, isconst(m, n), get(GLOBAL_BLOCK, n, :globals), _handling(n)))
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

# 🔴 값으로 적는 두 가지(T3 교차 프로세스 재생이 드러냈다):
#   · `SubString` — 부모 문자열의 **보이지 않는 꼬리**(예: `readchomp` 가 자른 "\n")가 직렬화로 보존되지
#     않는다(역직렬화 사본은 잘린 부분만 갖는다). 관측 가능한 값은 부분 문자열뿐이다.
#   · JSON3 객체/배열 — tape 배열의 **미사용 꼬리가 초기화되지 않은 메모리**라 프로세스마다 다르다
#     (`ActionRegistry.REGISTRY[..].tape.parent[153]` = 0xffffffff vs 0x0). 의미는 JSON 값이다.
_leaf_token(@nospecialize x) =
    x isa AbstractFloat ? "F:$(_tname(typeof(x))):$(repr(x))" :
    x isa Union{Integer,Char,Nothing,Missing,Symbol,String} ? "V:$(_tname(typeof(x))):$(repr(x))" :
    x isa SubString{String} ? "V:SubString{String}:$(repr(x))" :
    x isa Union{JSON3.Object,JSON3.Array} ? "J:$(JSON3.write(x))" : nothing

_key_seg(@nospecialize k) = k isa Union{Symbol,String,Integer} ? "[$(repr(k))]" : nothing

mutable struct _Walk
    lines::Vector{String}
    seen::IdDict{Any,String}
    opaque::Vector{String}      # 직렬화로 옮길 수 없는 값의 경로
end

"""
정준 행 상한. 넘으면 **경로를 적고 에러**다 — 세계가 폭주하는 그래프(불변 구조의 반복 전개 등)를 조용히
메모리로 받아내지 않는다(T3 첫 tractor capture 가 상한 없이 110 GB 를 먹었다).
"""
const MAX_WORLD_LINES = Ref(20_000_000)
"경로 길이 상한(바이트). 경로는 첫 방문 깊이만큼 자라므로 깊은 사슬은 행 수보다 먼저 메모리를 먹는다."
const MAX_PATH_BYTES = Ref(4096)

function _walk!(w::_Walk, path::String, @nospecialize x)
    length(w.lines) > MAX_WORLD_LINES[] &&
        error("world_lines: more than $(MAX_WORLD_LINES[]) canonical lines — runaway at $(first(path, 400))")
    ncodeunits(path) > MAX_PATH_BYTES[] &&
        error("world_lines: path longer than $(MAX_PATH_BYTES[]) bytes (object graph nested too deep) at $(first(path, 400)) … $(last(path, 300))")
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
        e.handling === :native_adapter ? field!(b, k, _native_export(e).state) :
            (push!(fields, (b, k, length(w.lines) + 1));
             push!(w.lines, k * "\t" * (e.handling === :native_pending ? "ADAPTER_PENDING" :
                                        e.handling === :native_covered ? "NATIVE_COVERED_BY:$(NATIVE_COVERED[e.name])" :
                                        "LEDGER_SINK")))
    end
    field!(:model_code, "fingerprints", fingerprints)
    for f in eb.task_world; field!(:task_world, "env.$(f)", getfield(env, f)); end
    field!(:task_world, "task_contract", task_contract)
    for f in eb.execution; field!(:execution, "env.$(f)", getfield(env, f)); end
    field!(:execution, "loop_state", loop_state); gwalk(:execution)
    gwalk(:globals)
    field!(:globals, "globals.Base.ENV", env_snapshot())
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
    dependencies::Vector{NamedTuple{(:name, :class, :reason),Tuple{String,Symbol,String}}}
    native_residual::Dict{String,Any}     # 옮기지 못했고 동역학 비관여이거나 분기 의무로 넘긴 값
end

"JSON 용 요약: 큰 재연 이력(`builds`)은 빼고 나머지 residual 필드만(이력은 .jls payload 에 있다)."
residual_summary(r) = Dict(k => (v isa NamedTuple ? Base.structdiff(v, NamedTuple{(:builds,)}) : v) for (k, v) in r)

"""
분기 의무: checkpoint 만으로는 보장할 수 없고 **복원된 분기가 끝날 때** 확인해야 하는 조건. import 결과의
`native_handles` 로 확인한다. 하나라도 어기면 그 분기는 원본 궤적 재현을 주장할 수 없다.
"""
const NATIVE_OBLIGATIONS = [
    "RVO KdTree permutation: restored exactly when native_residual.kd_known (build-history replay, " *
    "handle.kd_restored == true); otherwise the branch is certifiable only if the RVOSimHarness handle " *
    "reports ties == [] (tie watch from import until the next RVO rebuild)"]

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
    append!(gaps, ["native: $(_gkey(e)) — no native adapter"
                   for e in inv if e.handling === :native_pending])
    native = Dict{String,Any}()
    for e in inv
        e.handling === :native_adapter || continue
        x = _native_export(e)
        native[_gkey(e)] = (state = x.state, residual = x.residual)
        append!(gaps, x.gaps)
    end
    deps = dependency_modules(modules)
    append!(gaps, ["globals: dependency module $(d.name) — $(d.reason)" for d in deps if d.class === :unlisted])
    append!(gaps, ["unserializable: $(p)" for p in opaque])
    loop_state === nothing && push!(gaps, "execution: runtime loop cursor not supplied (t0 hook)")
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
               fingerprints = fingerprints, rng = rng, ledger_sinks = sinks, native = native,
               process_env = [(k, v) for (k, v) in env_snapshot() if !_env_secret(k)])
    bytes = _serialize_bytes(payload)
    copy(Random.default_rng()) == rng || error("capture advanced the RNG")   # 자기 검사
    return CheckpointCapture(bytes, bytes2hex(sha256(bytes)), block_digests(lines, fields),
                             field_digests(lines, fields), lines, fields, gaps, inv, deps,
                             Dict(k => v.residual for (k, v) in native))
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
    inv = global_inventory(modules)
    for e in inv
        e.handling === :ledger_sink || continue
        r = getfield(e.mod, e.name)
        r isa Base.RefValue ? (r[] = nothing) : error("restore: ledger sink $(e.name) is not a Ref")
    end
    # 🔴 전역(특히 RVO_ID_GLOBAL_MAP·RVO 기본값 전역)이 먼저 복원된 **뒤에** native 를 다시 만든다.
    handles = Dict{String,Any}()
    for e in inv
        e.handling === :native_adapter || continue
        haskey(p.native, _gkey(e)) || error("restore: native state for $(_gkey(e)) missing in the artifact")
        handles[_gkey(e)] = _native_import!(e, p.native[_gkey(e)])
    end
    # ENV: 비밀이 아닌 키를 capture 때 값으로 맞춘다(없던 키는 지운다). 비밀 키는 대조만(verify_world).
    want = Dict(p.process_env)
    for (k, _) in collect(ENV)
        _env_ignored(k) || _env_secret(k) || haskey(want, k) || delete!(ENV, k)
    end
    for (k, v) in want; ENV[k] = v; end
    copy!(Random.default_rng(), p.rng)
    return (; env = p.env, loop_state = p.loop_state, task_contract = p.task_contract,
            fingerprints = p.fingerprints, n_dicts_rehashed = nfix, native_handles = handles,
            ledger_sinks = p.ledger_sinks)
end

"""
    attach_shadow_sinks!(r, dir; modules) -> Vector{String}

import 가 떼어낸 원장 sink 중 **capture 때 붙어 있던 것**에 분기 전용 파일(`<dir>/shadow_<이름>.jsonl`)을
다시 꽂는다. 🔴 떼어낸 채로 두면 재생이 원본과 갈린다: 모니터의 관측 코드가 캐시 논리 시계
(`_CACHE_TIMESTAMP_COUNTER`)를 전진시키므로, sink 가 없는 분기는 그 호출을 건너뛰어 시계가 2~3 뒤처졌다
(T3 행렬: tractor zone s27·all3 s29·xwing zone s27, 궤적·결과는 같았다). 원본 원장에는 쓰지 않는다.
"""
function attach_shadow_sinks!(r, dir; modules)
    out = String[]
    for e in global_inventory(modules)
        e.handling === :ledger_sink || continue
        get(r.ledger_sinks, _gkey(e), nothing) === nothing && continue
        path = joinpath(dir, "shadow_" * String(e.name) * ".jsonl")
        getfield(e.mod, e.name)[] = open(path, "w")
        push!(out, path)
    end
    return out
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
            "native_residual" => residual_summary(c.native_residual), "native_obligations" => NATIVE_OBLIGATIONS,
            "dependency_modules" => [Dict("name" => d.name, "class" => String(d.class),
                                          "reason" => d.reason) for d in c.dependencies],
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
`native_handles` 는 분기 의무(`NATIVE_OBLIGATIONS`)를 확인할 객체들이다(RVO: `RVOTieWatch`).
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
