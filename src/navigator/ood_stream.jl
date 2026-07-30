# ============================================================================
#  [한국어 설명 상자 — 처음 읽는 사람용]
#  이 파일이 하는 일: 한 번의 시뮬레이션 동안 OOD(분포 밖 사건)를 "여러 번, 무작위 시점에" 터뜨리는
#    스트림(stream)을 심는다. 기본 스케줄러는 트리거를 딱 한 번만 쏘지만, 실제 적응형 운용은 사건이
#    예측 못 할 시점마다 계속 도착하고 LLM은 그때마다 다시 계획해야 한다.
#  프로젝트에서의 역할: LLM/surrogate 재명세 층이 "반복 적응 재계획"을 견디는지 시험하는 부하 생성기.
#  세 가지 OOD 종류를 섞어 심는다:
#    :fault   — 로봇 고장          (→ ReplaceAgent / 재배정, fault_action)
#    :battery — 배터리 열화(SoC↓)  (→ 에너지 인지 replan이 경로 재조정, battery_action)
#    :zone    — 통행금지 구역 출현  (→ ForbidZone / restage, zone_action)
#  발화 시점은 "빌드 진척도(닫힌 노드 수, closed-node count)" 임계값 기준 — 기계/속도가 달라도 재현되게.
#  채점을 위해 세 종류 모두 정답(truth)을 기록한다. 특히 battery는 심각도로 갈린다(REPLACE_SOC_THRESHOLD):
#    깊은 방전 → 하드 Replace, 가벼운 열화 → 소프트 Deprioritize.
#  평소 실행엔 영향 없음(호출하기 전까지 잠들어 있음).
#
#  Julia 문법 참고(처음 보는 사람용):
#   · 함수가 함수를 반환: `battery_action(...)`는 `env -> String` 클로저(closure)를 돌려줌.
#     `return function (env) ... end` = 이름 없는 내부 함수를 만들어 반환(나중에 env를 받아 실행됨).
#   · `!` 로 끝나는 이름: 상태를 바꾸는 함수(record_ood_truth!, schedule_random_ood! 등).
#   · `BATTERY_FLEET[]` : Ref(참조상자)의 내용물 꺼내기. []로 현재 값을 읽음.
#   · `x === nothing` : "값 없음" 정체 비교. `A === nothing || B` = A가 nothing이 아닐 때만 B 실행(단축평가).
#   · `argmax(f, xs)` : xs 중 f(x)가 최대인 원소를 돌려줌. comprehension `[.. for .. if ..]`으로 걸러 담기.
#   · 키워드 인자 `f(; a=1, b=2)`, `::Vector{Symbol}` 타입 지정, `Symbol("zone_rand_$(i)")` 문자열→심볼.
# ============================================================================

# ood_stream.jl
# ConstructionBots LLM Design-Space Navigator — MULTI-EVENT random OOD stream.
#
# The base scheduler (respec/ood_injection.jl) fires ONE trigger once. Real adaptive operation
# means OOD events keep arriving at unpredictable times; the LLM must re-plan at EACH one. This
# file registers MANY one-shot triggers at random build-progress points, mixing the three OOD
# kinds, so a single run exercises repeated adaptive replanning:
#   :fault   — a robot breaks down            (-> ReplaceAgent / reassign, via fault_action)
#   :battery — a robot's battery degrades     (-> SoC drop; energy-aware replan re-routes it)
#   :zone    — a no-go zone appears           (-> ForbidZone / restage, via zone_action)
#
# Each trigger uses build-PROGRESS thresholds (closed-node counts) rather than raw sim steps:
# reproducible across machines/speeds (same rationale as schedule_ood_at_closed!). Truth is
# recorded for ALL THREE kinds (grounding eval): :fault and :zone via the ood_truth.jl wrappers,
# and :battery via `battery_action` below, which logs a `BatteryTruth(robot, soc_after)`. The
# battery canonical is SEVERITY-SPLIT (see REPLACE_SOC_THRESHOLD): a deep discharge grounds as a
# hard Replace, a mild degradation as a soft Deprioritize.
#
# Depends on (all in-module by include order): schedule_ood_at_closed! (ood_injection.jl),
# fault_action / zone_action (navigator/ood_truth.jl), inject_battery_fault! (navigator/battery.jl).
# Inert until called — normal runs are unaffected.

"""
    battery_action(; target=nothing, soc_drop=0.6) -> (env -> String)

A scheduled-OOD action that drops a robot's battery SoC mid-sim. Returns the NL event and lets the
injector (`ood_inject_step!`) enqueue it (so we pass `enqueue=false` to avoid a double push). It ALSO
records the ground-truth label `BatteryTruth(robot, soc_after)` into `OOD_TRUTH_LOG` (evaluator-only),
so battery events are scored in decision-quality just like fault/zone. The canonical response is
severity-split at `REPLACE_SOC_THRESHOLD` (deep discharge -> Replace, degradation -> Deprioritize),
resolved from the recorded `soc_after` by `truth_key(::BatteryTruth)`.
"""
# 시뮬레이션 도중 한 로봇의 배터리 SoC를 떨어뜨리는 스케줄용 액션. env를 받는 클로저를 반환한다.
# 자연어 사건설명(nl)을 돌려주고, 동시에 정답 라벨 BatteryTruth(robot, soc_after)를 로그에 기록해 채점에 씀.
# 인자: target(대상 로봇, 없으면 발화 시점에 자동 선택), soc_drop(떨어뜨릴 양).
function battery_action(; target=nothing, soc_drop::Float64=0.6)
    return function (env)                                 # 나중에 env를 받아 실행될 내부 함수(클로저)
        fleet  = BATTERY_FLEET[]                          # 배터리 fleet(전역 Ref) 꺼내기(없으면 nothing)
        before = fleet === nothing ? Dict{Any,Float64}() : copy(fleet.soc)  # 드롭 전 SoC 스냅샷(누가 떨어졌는지 비교용)
        # enqueue=false: 주입기(ood_inject_step!)가 이 nl을 넣어주므로 여기서 또 넣으면 이중 push가 됨→막음.
        nl = inject_battery_fault!(env; target=target, soc_drop=soc_drop, enqueue=false)
        (nl === nothing || isempty(nl)) && return nl        # no fleet / no eligible robot -> no truth  # fleet/대상 없으면 정답도 없음
        # Identify the robot that was hit (the given target, or the one whose SoC just dropped) and
        # log its POST-drop SoC so the evaluator can score the right severity class.
        # 실제로 타격받은 로봇을 찾는다: 지정 target이 있으면 그것, 없으면 방금 SoC가 떨어진 로봇.
        rid = target
        if rid === nothing && fleet !== nothing
            dropped = [id for (id, s) in fleet.soc if get(before, id, s) - s > 1e-9]  # 드롭 전후 차이가 유의미한 로봇들
            rid = isempty(dropped) ? nothing :
                  argmax(id -> get(before, id, 0.0) - fleet.soc[id], dropped)          # 가장 많이 떨어진 로봇 선택
        end
        # rid와 fleet이 둘 다 유효할 때만 정답 기록(|| 단축평가: 앞이 참이면 record 건너뜀).
        (rid === nothing || fleet === nothing) ||
            record_ood_truth!(nl, BatteryTruth(rid, fleet.soc[rid]))   # 드롭 후 SoC를 정답으로 기록(심각도 채점의 근거)
        return nl
    end
end

# [lo, hi] 구간에 n개의 진척도 임계값을 고르게 뿌리되 각 점에 무작위 흔들림(jitter)을 주고 정렬해 반환.
function _random_progress_points(n::Int, lo::Int, hi::Int, rng)
    n <= 0 && return Int[]                                    # 개수가 0 이하면 빈 배열
    hi <= lo && return fill(max(lo, 1), n)                    # 구간이 없으면 같은 값 n개로 채움
    span = hi - lo                                            # 구간 폭
    pts = Int[]
    for i in 1:n
        base = lo + round(Int, span * (i - 0.5) / n)         # i-th evenly spaced slot center  # i번째 균등 슬롯의 중심
        jit  = round(Int, (2 * rand(rng) - 1) * span / (2n)) # ± half-slot jitter  # 반슬롯 범위의 ± 무작위 흔들림
        push!(pts, clamp(base + jit, lo, hi))                # 흔든 값을 [lo,hi]로 자름(clamp)
    end
    return sort(pts)                                          # 오름차순 정렬(진척 순서대로 발화)
end

"""
    schedule_random_ood!(; n=3, kinds=[:fault,:battery,:zone], closed_lo=4, closed_hi=40,
                           seed=nothing, soc_drop=0.6) -> Vector{OODTrigger}

Register `n` one-shot OOD triggers at random build-progress points in `[closed_lo, closed_hi]`
(closed-node counts), each a randomly chosen kind from `kinds`. Returns the triggers. Call once
after the env/schedule are built and BEFORE stepping. Combine with `init_battery_fleet!` +
`install_battery_objective_hook!` so the per-event replans are battery/energy-aware.

Reproducible when `seed` is given. Zone keys are auto-numbered (`:zone_rand_1`, …) so multiple
zones coexist. `:battery` events need an initialized fleet (otherwise they no-op harmlessly).

Battery SEVERITY is drawn per event so BOTH canonical classes occur: with probability
`battery_severe_frac` the event is a DEEP discharge (`severe_soc_drop`, default 1.0 -> SoC floor 0,
below `REPLACE_SOC_THRESHOLD` -> canonical Replace); otherwise a mild degradation (`soc_drop` ->
canonical Deprioritize). Set `battery_severe_frac=0` to recover the old always-degradation behaviour.
"""
# n개의 일회성 OOD 트리거를 [closed_lo, closed_hi] 진척 구간의 무작위 지점에 심는다(종류는 kinds에서 무작위).
# env/스케줄을 다 만든 뒤, 스텝을 돌리기 전에 한 번 호출. seed를 주면 재현 가능.
# battery는 매 사건마다 심각도를 뽑아 심함(severe_soc_drop, 깊은 방전→Replace)/약함(soc_drop→Deprioritize) 둘 다 나오게 함.
# battery_severe_frac=0으로 두면 예전처럼 항상 약한 열화만 발생.
function schedule_random_ood!(; n::Int=3, kinds::Vector{Symbol}=[:fault, :battery, :zone],
        closed_lo::Int=4, closed_hi::Int=40, seed::Union{Nothing,Int}=nothing,
        soc_drop::Float64=0.6, battery_severe_frac::Float64=0.5, severe_soc_drop::Float64=1.0,
        safe_fault::Bool=false, fault_obstacle::Union{Nothing,Bool}=nothing)
    # seed 없으면 전역 난수, 있으면 seed 고정 난수생성기(재현성). Union{Nothing,Int}=둘 중 하나 타입.
    rng = seed === nothing ? Random.GLOBAL_RNG : Random.MersenneTwister(seed)
    points = _random_progress_points(n, closed_lo, closed_hi, rng)  # 발화할 진척 지점들
    triggers = OODTrigger[]
    zone_ct = 0                                              # zone 키에 붙일 일련번호(여러 zone 공존용)
    for (i, p) in enumerate(points)
        kind = kinds[rand(rng, 1:length(kinds))]            # 이 지점의 OOD 종류를 kinds에서 무작위 선택
        action = if kind == :fault
            # `safe_fault` -> only ever break a SOLO transporter (no has_edge crash); recommended when
            # the replace path is exercised (distributed replace needs a cleanly-replaceable target).
            # safe_fault=true면 단독(SOLO) 운반체만 고장냄(has_edge 크래시 회피). replace 경로 시험 시 권장.
            #
            # `fault_obstacle` : 고장난 로봇 자리를 통행 장애물로 남길지. nothing 이면 기존 기본값을 그대로
            # 쓴다(이 파일의 옛 호출부 동작 보존). 대시보드 데모는 false 를 준다 -- 고장은 자산 건강 사건이지
            # 암묵적 공간 배제 구역이 아니고, 남기면 Break+Zone 합성 케이스에 숨은 두 번째 존이 생긴다.
            fault_obstacle === nothing ? fault_action(; safe = safe_fault) :
                                         fault_action(; safe = safe_fault, obstacle = fault_obstacle)
        elseif kind == :battery
            drop = rand(rng) < battery_severe_frac ? severe_soc_drop : soc_drop  # 심각도 추첨: 확률적으로 깊은/약한 방전
            battery_action(soc_drop=drop)                    # picks a healthy robot at fire time  # 발화 시점에 건강한 로봇을 고름
        else
            zone_ct += 1
            zone_action(key=Symbol("zone_rand_$(zone_ct)"))  # smaller zone (size already shrunk)  # 문자열→심볼로 고유 키 생성
        end
        push!(triggers, schedule_ood_at_closed!(p, action)) # 진척 p에 도달하면 action을 쏘도록 등록
    end
    return triggers
end

"""
    schedule_random_faults!(; n=3, closed_lo=4, closed_hi=40, seed=nothing) -> Vector{OODTrigger}

Convenience: `schedule_random_ood!` restricted to robot-breakdown events (the classic OOD), at
`n` random progress points. Each faults whichever robot is active then, so targets are random too.
"""
# 편의 함수: schedule_random_ood!를 로봇 고장(:fault)만으로 제한(고전적 OOD). 발화 때 활동 중인 로봇이 대상이라 대상도 무작위.
schedule_random_faults!(; n::Int=3, closed_lo::Int=4, closed_hi::Int=40,
        seed::Union{Nothing,Int}=nothing) =
    schedule_random_ood!(; n=n, kinds=[:fault], closed_lo=closed_lo, closed_hi=closed_hi, seed=seed)
