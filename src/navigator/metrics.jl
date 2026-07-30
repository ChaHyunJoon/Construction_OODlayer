# ============================================================================
#  [한국어 설명 상자 — 처음 읽는 사람용]
#  이 파일이 하는 일: 한 번의 시뮬레이션 실행 결과를 "여러 축(axis)의 숫자 묶음"으로 정리하고,
#    그 숫자들을 축별 비용(cost)으로 접어 두 실행 중 어느 쪽이 더 나은지 판정한다.
#  프로젝트에서의 역할: 원 논문은 "생성 시간(generation_time)"만 쟀지만, 이 프로젝트의 LLM navigator는
#    ① 완주(completion) ② 속도(speed) ③ 효율(efficiency) ④ 적응성(adaptability) 네 축을 함께 최적화한다.
#    이 파일이 그 4축 측정치(RunMetrics)와 비교 규칙(is_better)을 정의한다. generation_time은 오직 논문과의
#    비교를 위해 남겨둠(4축 점수에는 절대 안 섞음).
#  중요한 설계 원칙: "안 잰 축이 결과를 지배하면 안 된다". 그래서 측정 안 된 값(NaN)은 _z로 0 취급하고,
#    higher-better(높을수록 좋은) 지표는 비용 합에 억지로 접지 않고 따로 보고한다.
#
#  Julia 문법 참고(처음 보는 사람용):
#   · Base.@kwdef struct : 필드마다 기본값을 줄 수 있게 해주는 매크로. RunMetrics(completion_rate=0.9) 식 호출 가능.
#   · `field::Float64 = NaN` : 타입 지정(::Float64) + 기본값(= NaN). NaN = "숫자 아님/미측정" 표시자.
#   · f(m::RunMetrics) : m이 RunMetrics 타입일 때만 적용되는 메서드(다중 디스패치).
#   · `getfield(c, k)` : 필드를 :심볼 이름 k로 동적 접근. k는 :completion 같은 심볼(이름표).
#   · `Tuple(getfield(c,k) for k in order)` : comprehension 결과를 튜플로 — 순서(order)대로 값 뽑기.
#   · `;` 로 시작하는 인자 목록 f(; a, b) : 키워드 인자(순서 무관, 이름으로 넘김).
#   · 삼항 연산자 `조건 ? A : B` : 조건이 참이면 A, 아니면 B.
# ============================================================================

# metrics.jl
# ConstructionBots LLM Design-Space Navigator — multi-axis RunMetrics (minimal starter)
# See docs/llm_navigator_plan.md.
#
# THESIS: replace the paper's generation-time-only measurement with a multi-axis
# objective the LLM navigator can optimize:
#   ① completion  ② speed  ③ efficiency  ④ adaptability
# `generation_time` is kept ONLY for comparison against the original paper.
#
# `compute_metrics` is a PURE function over primitive inputs (no coupling to solver
# internals) so it is runnable/testable immediately. A thin `metrics_from_schedule`
# adapter sketches how to fill it from a solved schedule; accessors marked (?) must
# be verified against your build before relying on them.

"""
    RunMetrics

Outcome of one ConstructionBots run, grouped by the three improvement axes the
system must optimize (plus completion). Lower-is-better for cost-like fields;
`throughput`, `robot_utilization`, `completion_rate` are higher-is-better.
"""
# 한 번의 실행 결과를 담는 구조체. 4개 개선 축(+완주)별로 필드를 묶어 둠. 비용류 필드는 낮을수록 좋고,
# throughput·robot_utilization·completion_rate는 높을수록 좋다. 미측정 필드는 NaN(기본값).
Base.@kwdef struct RunMetrics
    # --- ① COMPLETION (feasibility-first) ---
    # ① 완주(가장 먼저 보는 축): 얼마나 지었나 / 쓸 만한 계획이 나왔나.
    completion_rate::Float64   = NaN    # placed / total parts (under OOD, may be < 1)  # 놓은 부품 / 전체 부품(OOD 상황이라 1 미만일 수 있음)
    feasible::Bool             = false  # solver returned a usable plan                 # 풀이기가 쓸 만한 계획을 냈는가
    # --- ② SPEED (execution, NOT generation) ---
    # ② 속도(실제 실행 시간이지, 계획 생성 시간이 아님).
    makespan::Float64          = NaN    # build completion time                         # 빌드 완료까지 걸린 시간(makespan)
    throughput::Float64        = NaN    # parts placed per unit time                    # 단위시간당 놓은 부품 수(처리량)
    # --- ③ EFFICIENCY ---
    # ③ 효율: 에너지·이동거리·놀림·배터리 균등도.
    robot_utilization::Float64 = NaN    # mean busy fraction over the horizon           # 로봇들이 바쁜 시간 비율 평균(높을수록 좋음)
    energy::Float64            = NaN    # total actuation energy [J] (= battery total_energy_J)  # 총 구동 에너지[J]
    handling_distance::Float64 = NaN    # total transport distance                      # 총 운반 거리
    min_soc::Float64           = NaN    # worst per-robot State-of-Charge (battery margin; HIGHER = safer)  # 최악 로봇의 SoC(배터리 여유; 높을수록 안전)
    soc_spread::Float64        = NaN    # max−min SoC across robots (wear-leveling; LOWER = more even)      # 로봇 간 SoC 격차(균등마모; 낮을수록 고름)
    # --- ④ ADAPTABILITY ---
    # ④ 적응성: OOD가 터졌을 때 얼마나 빠르고 안정적으로 회복하는가.
    replan_latency::Float64    = NaN    # wall-clock to produce a repaired plan         # 고친 계획을 만드는 데 걸린 벽시계 시간
    schedule_deviation::Float64= NaN    # Σ|t0 − t0_prev| + assignment churn (stability)  # 이전 대비 시작시각 변화합 + 배정 뒤바뀜(안정성; 낮을수록 좋음)
    reaction_latency::Float64  = NaN    # STEPS from OOD fire -> first admitted adaptation (lower better)  # OOD 발생→첫 대응 승인까지 스텝 수(낮을수록 좋음)
    time_to_recover::Float64   = NaN    # STEPS from OOD fire -> build progress resumes (lower better)     # OOD 발생→빌드 진척 재개까지 스텝 수(낮을수록 좋음)
    recovery_rate::Float64     = NaN    # fraction of OOD events survived w/o permanent stall (HIGHER better)  # 영구 정지 없이 넘긴 OOD 비율(높을수록 좋음)
    replan_count::Float64      = NaN    # # structural replans invoked (churn volume)   # 구조적 재계획을 몇 번 했나(뒤척임 양)
    verifier_escape_rate::Float64 = NaN # admitted-but-infeasible rate (safety; LOWER better)  # 승인됐지만 실은 불가능한 계획 비율(안전; 낮을수록 좋음)
    # --- cost / practicality (reported ALONGSIDE, never folded into the 4-axis scalar) ---
    # --- 비용/실용성: 4축 점수에 절대 안 섞고, 옆에 따로 보고만 함 ---
    decision_latency::Float64  = NaN    # wall-clock PER adaptation decision (LLM ~s vs MARL ~ms)  # 대응 결정 1건당 벽시계 시간(LLM은 초, MARL은 밀리초)
    # --- reference / bookkeeping ---
    # --- 참고/기록용 ---
    generation_time::Float64   = NaN    # the paper's ONLY current metric — kept for comparison  # 원 논문의 유일한 지표 — 비교용으로만 보관
    n_robots::Int              = 0      # 로봇 수
    n_parts::Int               = 0      # 부품 수
end

# _z: NaN이면 0.0, 아니면 그대로 실수화. "안 잰 축이 결과를 지배하지 않게" NaN을 0으로 눌러주는 핵심 도우미.
_z(x::Real) = isnan(x) ? 0.0 : float(x)   # NaN-as-0 so unmeasured axes don't dominate

"""
    compute_metrics(; ...) -> RunMetrics

Pure constructor from primitive run outputs.

Required: `t0`, `tF` (node start/end time vectors), `n_parts`, `placed_parts`,
`robot_busy_time` (per-robot busy time vector), `transport_distance`.
Optional: `energy`, `generation_time`, `replan_latency`, `feasible`,
`t0_prev` + `assignment_churn` (for schedule deviation / stability).
"""
# 원시 실행 출력(시작/끝 시각 벡터, 부품 수 등)만으로 RunMetrics를 만드는 순수 함수(풀이기 내부에 안 얽힘).
# 모든 인자가 키워드(; 뒤). 필수: t0/tF/n_parts/placed_parts/robot_busy_time/transport_distance.
# 선택: energy·generation_time·replan_latency·feasible·t0_prev+assignment_churn(안정성용) 등.
function compute_metrics(; t0, tF, n_parts::Integer, placed_parts::Integer,
        robot_busy_time, transport_distance::Real,
        energy::Real=NaN, generation_time::Real=NaN, replan_latency::Real=NaN,
        feasible::Bool=true, t0_prev=nothing, assignment_churn::Integer=0,
        min_soc::Real=NaN, soc_spread::Real=NaN,
        reaction_latency::Real=NaN, time_to_recover::Real=NaN, recovery_rate::Real=NaN,
        replan_count::Real=NaN, verifier_escape_rate::Real=NaN, decision_latency::Real=NaN)

    mk   = isempty(tF) ? NaN : float(maximum(tF))                # makespan = 모든 종료시각 중 최댓값(비면 NaN)
    thru = (isfinite(mk) && mk > 0) ? placed_parts / mk : NaN    # 처리량 = 놓은 부품 / makespan (0 나눗셈 방지)
    nr   = length(robot_busy_time)                               # 로봇 수 = 바쁜시간 벡터 길이
    util = (nr > 0 && isfinite(mk) && mk > 0) ? sum(robot_busy_time) / (nr * mk) : NaN  # 가동률 = 총바쁜시간 /(로봇수×makespan)
    comp = (n_parts > 0) ? placed_parts / n_parts : NaN          # 완주율 = 놓은 부품 / 전체 부품

    dev = NaN
    if t0_prev !== nothing                                       # 이전 시작시각이 주어졌을 때만 편차 계산
        n = min(length(t0), length(t0_prev))                    # 두 벡터 중 짧은 길이만큼만 비교
        # .- / abs. / float. 의 점(.)은 "원소별(broadcast)" 연산. Σ|t0-이전t0| + 배정 뒤바뀜 수.
        dev = sum(abs.(float.(t0[1:n]) .- float.(t0_prev[1:n]))) + assignment_churn
    end

    return RunMetrics(
        completion_rate=comp, feasible=feasible,
        makespan=mk, throughput=thru,
        robot_utilization=util, energy=float(energy), handling_distance=float(transport_distance),
        min_soc=float(min_soc), soc_spread=float(soc_spread),
        replan_latency=float(replan_latency), schedule_deviation=dev,
        reaction_latency=float(reaction_latency), time_to_recover=float(time_to_recover),
        recovery_rate=float(recovery_rate), replan_count=float(replan_count),
        verifier_escape_rate=float(verifier_escape_rate), decision_latency=float(decision_latency),
        generation_time=float(generation_time), n_robots=nr, n_parts=Int(n_parts),
    )
end

# ---- objective: the four axes as single costs (lower = better) --------------------
# NOTE: axes are summed-raw here; normalization/scaling is itself a tuning knob —
# revisit once Step 1 produces real metric ranges.

"""
    axis_costs(m) -> NamedTuple

Collapse `RunMetrics` into one scalar cost per axis (lower = better), so they can be
ordered lexicographically or scalarized.
"""
# RunMetrics를 축별 "비용" 하나씩(낮을수록 좋음)으로 접어 준다. 이후 사전식 정렬이나 가중합에 쓰임.
function axis_costs(m::RunMetrics)
    completion   = 1.0 - _z(m.completion_rate)                                  # ① minimize uncompleted  # 미완주 비율(1-완주율) 최소화
    speed        = _z(m.makespan)                                               # ② minimize makespan     # makespan 자체가 비용
    # ③ efficiency: energy + distance + idle + WEAR-LEVELING (soc_spread). soc_spread is NaN-as-0
    #    so runs without battery data are unaffected; with battery on, uneven SoC is penalized.
    # 효율 비용 = 에너지 + 이동거리 + 놀린정도(1-가동률) + SoC격차. 배터리 데이터 없으면 soc_spread=0이라 무영향.
    efficiency   = _z(m.energy) + _z(m.handling_distance) + (1.0 - _z(m.robot_utilization)) + _z(m.soc_spread)
    # ④ adaptability: churn/latency + reaction & recovery TIME (all cost-like, NaN-as-0 so
    #    runs without an adaptation log are unaffected). recovery_RATE is higher-better and is
    #    reported separately (NOT folded here, to preserve the "unmeasured axes don't dominate"
    #    invariant — a 1−0 penalty would wrongly punish runs lacking the field).
    # 적응성 비용 = 스케줄편차 + 재계획지연 + 반응지연 + 회복시간(모두 비용류; recovery_RATE는 높을수록 좋아 여기 안 넣음).
    adaptability = _z(m.schedule_deviation) + _z(m.replan_latency) +
                   _z(m.reaction_latency) + _z(m.time_to_recover)
    return (completion=completion, speed=speed, efficiency=efficiency, adaptability=adaptability)
end

# 사전식(lexicographic) 정렬 키를 order 순서대로 튜플로 만든다. 튜플끼리 `<` 하면 앞 축부터 차례로 비교됨.
"Lexicographic sort key in `weights.order` (use with `<` on the returned tuples)."
function lexicographic_key(m::RunMetrics, order::Vector{Symbol})
    c = axis_costs(m)
    return Tuple(getfield(c, k) for k in order)   # order의 각 심볼 이름으로 해당 축 비용을 뽑아 튜플화
end

# 가중합 목적값 = Σ(축가중치 × 축비용). weights.mode == :weighted 일 때 사용.
"Scalarized objective `Σ w_axis · cost_axis` (used when `weights.mode == :weighted`)."
function scalarized(m::RunMetrics, w)   # w::ObjectiveWeights (config_schema.jl)  # w는 축별 가중치 묶음
    c = axis_costs(m)
    return w.w_completion*c.completion + w.w_speed*c.speed +
           w.w_efficiency*c.efficiency + w.w_adaptability*c.adaptability
end

"""
    is_better(a, b, weights) -> Bool

True if metrics `a` beats `b` under the objective. Infeasible plans always lose.
Dispatches on `weights.mode` (:lexicographic or :weighted).
"""
# a가 b보다 목적함수상 더 나은가? 실현 불가능한 계획은 무조건 진다. weights.mode에 따라 비교 방식이 갈림.
function is_better(a::RunMetrics, b::RunMetrics, weights)
    a.feasible != b.feasible && return a.feasible           # feasible always wins  # 실현가능 여부가 다르면 가능한 쪽 승(&&로 조기반환)
    if weights.mode == :lexicographic                       # 사전식: 앞 축부터 차례로 비교
        return lexicographic_key(a, weights.order) < lexicographic_key(b, weights.order)
    else                                                    # 가중합: 하나의 스칼라 비용으로 비교
        return scalarized(a, weights) < scalarized(b, weights)
    end
end

# ---- thin adapter from a solved schedule (verify accessors before relying on it) ---
#
# Fill the metric-vector from a solved OperatingSchedule. `get_tF` is confirmed
# (essential_tg_coponents.jl: `makespan(sched)=maximum(get_tF(sched))`). The (?)
# inputs (busy time, transport distance, placed count) are left as kwargs because
# their accessors are not yet verified — pass them in from the sim for now.
# 이미 풀린 스케줄(sched)에서 지표를 뽑아 채우는 얇은 어댑터. 아직 검증 안 된 접근자(?)는 인자로 받아 넘긴다.
function metrics_from_schedule(sched; n_parts::Integer, placed_parts::Integer,
        robot_busy_time, transport_distance::Real, t0=nothing, kwargs...)
    tF = collect(get_tF(sched))                 # confirmed accessor  # 확인된 접근자로 종료시각 벡터 얻기
    t0v = t0 === nothing ? zeros(length(tF)) : collect(t0)   # TODO: get_t0(sched) (?)  # 시작시각 미지정이면 0으로 채움
    # 나머지 키워드(kwargs...)는 그대로 compute_metrics로 흘려보냄(... = 가변 키워드 전달).
    return compute_metrics(; t0=t0v, tF=tF, n_parts=n_parts, placed_parts=placed_parts,
        robot_busy_time=robot_busy_time, transport_distance=transport_distance, kwargs...)
end
