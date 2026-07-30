# ============================================================================
#  이 파일은 "LLM 이 조절하는 설계 손잡이(knob)들의 데이터 스키마"를 정의.
#  ConstructionBots 시스템은 여러 손잡이(버퍼 크기, 팀 크기, 충돌 허용치, 목적 가중치 등)로
#  동작이 달라지는데, 그 손잡이 묶음이 NavigatorConfig, 목적축들 사이의 우선순위가
#  ObjectiveWeights. LLM 은 자연어 의도나 OOD 관찰을 읽고 이 값들을 (부분적으로) 채워 넣음.
#  이 파일은 순수 "데이터"라서 solver 와 얽히지 않고 단독으로 실행/테스트 가능.
#
#  Julia 문법 참고:
#   · Base.@kwdef struct : 각 필드에 기본값을 줄 수 있게 해주는 매크로(키워드 생성자 자동 생성).
#     예) NavigatorConfig(staging_buffer=1.5) 처럼 원하는 필드만 지정해 만들 수 있음.
#   · mutable struct : 만든 뒤에도 필드 값을 바꿀 수 있는 구조체.
#   · `:completion` 같은 :기호 = Symbol(가벼운 이름표 값). 문자열보다 비교가 빠름.
#   · Vector{Symbol} = Symbol 들의 배열. Dict{String,Any} = 문자열 키 / 아무 타입 값의 사전.
#   · `!` 로 끝나는 함수(update_from_dict!) = 인자를 직접 수정(in-place).
#   · String.(w.order), Symbol.(v) 의 점(.) = 배열 각 원소에 함수를 적용(브로드캐스트).
# ============================================================================
# config_schema.jl
# ConstructionBots LLM Design-Space Navigator — Knob Configuration Schema (minimal starter)
# See docs/llm_navigator_plan.md.
#
# THESIS: the objective must move beyond generation-time. A multi-robot
# manufacturing/assembly system is judged by SPEED, EFFICIENCY, ADAPTABILITY
# (plus completion as the feasibility-first axis). `NavigatorConfig` is the set of
# knobs the paper's modular stack exposes; `ObjectiveWeights` is how the LLM
# navigator trades those axes off. This is pure data — no coupling to the solver,
# so it stays runnable/testable on its own and is safe to `include`.

"""
    ObjectiveWeights

Priority / weighting across the four objective axes. Default is completion-first
lexicographic (preemptive): solve ① then fix and solve ②, etc.

Axes: `:completion` (① feasibility-first), `:speed` (② makespan/throughput),
`:efficiency` (③ utilization/energy/distance), `:adaptability` (④ stability/replan).
"""
# 네 가지 목적축(완주/속도/효율/적응성) 사이의 우선순위·가중치를 담는 구조체.
# 기본은 "완주 최우선"의 사전식(lexicographic) 순서: ①을 먼저 풀고, 그다음 ②, ③, ④ 순으로.
Base.@kwdef mutable struct ObjectiveWeights
    mode::Symbol = :lexicographic            # :lexicographic(우선순위 순차) 또는 :weighted(하나의 점수로 합산)
    order::Vector{Symbol} = [:completion, :speed, :efficiency, :adaptability]  # 사전식 모드에서의 축 우선순위
    # 아래 가중치는 mode == :weighted 일 때만 사용(각 축을 곱해 하나의 점수로 합침).
    w_completion::Float64   = 1.0e6          # ① 완주(feasibility) 최우선 — 그래서 가장 큰 값
    w_speed::Float64        = 1.0e3          # ② makespan / 처리량
    w_efficiency::Float64   = 1.0e1          # ③ 가동률 / 에너지 / 운반 거리
    w_adaptability::Float64 = 1.0e0          # ④ 일정 안정성 / 재계획 빈도
end

"""
    NavigatorConfig

One point in ConstructionBots' design space. Each field maps to a knob the paper's
conclusion names (buffer sizes, team configs, collision tolerances, objective
weights) plus robustness knobs (slack, spare capacity, redundant paths). The LLM
emits/edits this (often partially) from a NL intent or an OOD observation.
"""
# 설계 공간의 한 점(설정 하나)을 나타내는 구조체. 각 필드가 논문이 지목한 손잡이 하나에 대응.
# LLM 이 자연어 의도나 OOD 관찰을 보고 이 값들을 (보통 일부만) 채워/수정함.
Base.@kwdef mutable struct NavigatorConfig
    staging_buffer::Float64  = 1.0           # staging 원 반지름 배수(안전 ↔ 공간 효율의 절충)
    collision_tol::Float64   = 1.0           # RVO 반지름/이웃거리 배수(안전 ↔ 속도의 절충)
    max_team_size::Int       = 0             # 하위 팀당 로봇 수 상한. 0 = solver 기본값 사용
    slack_frac::Float64      = 0.0           # 최소 소요시간 대비 일정 여유(slack) 비율(견고함 ↔ 속도)
    spare_capacity::Int      = 0             # 고장 복구용으로 예비해 두는 로봇 수(적응성)
    redundant_paths::Bool    = false         # 예비(백업) 운반 경로를 미리 계획할지 여부
    objective::ObjectiveWeights = ObjectiveWeights()  # 위에서 정의한 목적축 우선순위
    source::String           = "default"     # 이 설정의 출처: "llm-intent" | "ood-respec" | "manual" | "default"
end

# ---- Dict / JSON (de)serialization so the LLM can read/write configs --------------
# 아래는 구조체 ↔ Dict(사전) 변환. LLM 은 JSON/Dict 로 설정을 읽고 쓰므로 이 다리가 필요.

# ObjectiveWeights → Dict. Symbol 은 JSON에 담기게 문자열(String)로 바꿔줌.
to_dict(w::ObjectiveWeights) = Dict{String,Any}(
    "mode" => String(w.mode),
    "order" => String.(w.order),
    "w_completion" => w.w_completion,
    "w_speed" => w.w_speed,
    "w_efficiency" => w.w_efficiency,
    "w_adaptability" => w.w_adaptability,
)

# NavigatorConfig → Dict. 중첩된 objective 는 다시 to_dict 로 사전화.
to_dict(c::NavigatorConfig) = Dict{String,Any}(
    "staging_buffer" => c.staging_buffer,
    "collision_tol" => c.collision_tol,
    "max_team_size" => c.max_team_size,
    "slack_frac" => c.slack_frac,
    "spare_capacity" => c.spare_capacity,
    "redundant_paths" => c.redundant_paths,
    "objective" => to_dict(c.objective),
    "source" => c.source,
)

# Update a @kwdef struct in place from a Dict (string OR symbol keys). Unknown keys
# are ignored with a warning — robust to noisy/partial LLM output. Partial dicts are
# fine: only provided knobs change, everything else keeps its default/current value.
# @kwdef 구조체를 Dict 로부터 제자리(in-place) 갱신. 키는 문자열이든 Symbol이든 됨.
# 모르는 키는 경고만 내고 무시 → LLM 이 지저분/부분적 출력을 내도 견고함.
# 부분 Dict 도 OK: 준 손잡이만 바뀌고 나머지는 기존/기본값 유지.
function update_from_dict!(obj, d::AbstractDict)
    fields = fieldnames(typeof(obj))     # 이 구조체가 가진 필드 이름들
    for (k, v) in d                       # 사전의 각 (키, 값) 쌍에 대해
        sym = Symbol(k)                   # 키를 Symbol 로 통일(문자열이어도 대응)
        if sym in fields                  # 실제 존재하는 필드일 때만 반영
            FT = fieldtype(typeof(obj), sym)   # 그 필드가 기대하는 타입
            cur = getfield(obj, sym)           # 현재 값
            if cur isa ObjectiveWeights && v isa AbstractDict
                update_from_dict!(cur, v)                 # 중첩된 objective 는 재귀로 갱신
            elseif FT === Symbol
                setfield!(obj, sym, Symbol(v))            # Symbol 필드는 값을 Symbol 로 변환해 저장
            elseif FT <: AbstractVector{Symbol}
                setfield!(obj, sym, Symbol.(v))           # Symbol 배열 필드는 각 원소를 Symbol 로 변환
            else
                setfield!(obj, sym, convert(FT, v))       # 그 외엔 기대 타입으로 변환해 저장
            end
        else
            @warn "update_from_dict!: ignoring unknown knob" key=k type=typeof(obj)  # 모르는 키는 무시(경고)
        end
    end
    return obj
end

"""
    navigator_config(d) -> NavigatorConfig

Build a config from a (possibly partial) Dict emitted by the LLM, merged onto
defaults. Example: `navigator_config(Dict("staging_buffer"=>1.5,
"objective"=>Dict("order"=>["completion","speed","adaptability","efficiency"])))`.
"""
# (부분적인) Dict 로부터 완전한 설정을 만드는 편의 함수: 기본값 위에 준 값만 덮어씀.
function navigator_config(d::AbstractDict; source::String="llm-intent")
    c = NavigatorConfig(; source=source)   # 기본값으로 설정을 만들고(출처 표시 포함)
    update_from_dict!(c, d)                 # 사전에 담긴 손잡이만 덮어쓴 뒤
    return c
end
