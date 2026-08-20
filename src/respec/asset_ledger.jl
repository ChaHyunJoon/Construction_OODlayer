# =============================================================================
# asset_ledger.jl  --  TWO-LEVEL IDENTITY: role (RobotID) vs physical asset.
#
# A `RobotID` is a ROLE — a station on the shop floor. The schedule, the transport
# team rosters, the scene-tree capture edges and the RVO id map all key on the role,
# and the role NEVER changes. What changes when a robot breaks is the physical ASSET
# filling that role: a different chassis is checked out of the depot and takes over.
#
# This mirrors how a real plant works. The work order goes to "station 7"; when the
# unit at station 7 fails, a replacement unit is installed and the work order is NOT
# rewritten. Crucially, the MAINTENANCE RECORD attaches to the unit's serial number,
# not to the station — which is precisely what this ledger stores.
#
# WHY A LEDGER AND NOT A DICT
# ---------------------------
# The previous record was `HOT_SWAP_ASSETS[role] = (...)`, a dictionary ASSIGNMENT.
# Swap the same role twice and the first record is silently gone. That is fine for a
# single demo build and fatal for a campaign: fleet ageing across repeated builds is
# exactly the history that gets overwritten. So this is append-only, and the current
# asset is DERIVED from the history rather than stored beside it.
#
# EVENT KINDS (physically distinct, deliberately not merged)
#   :asset_replacement — mechanical fault. A fresh body drives out of the depot and
#                        takes over the role; the failed body is recovered.
#   :battery_swap      — depletion only. SAME body, new battery, done in the field.
#   :tow_replacement   — mechanical fault while CARRYING. The failed body is towed out
#                        of the formed team and a fresh body takes its slot. Same role,
#                        so the roster is untouched — towing is a physical manoeuvre,
#                        not an identity operation.
#
# Note the third one is a MODE, not a decision: whether a tow is needed is forced by
# the world (is the robot mid-carry?), not chosen by the planner. Only
# `:asset_replacement` vs `:battery_swap` is a genuine choice, because the two consume
# different resources.
#
# -----------------------------------------------------------------------------
# [한국어 설명] 2단 정체성 — 역할(RobotID) vs 물리 자산(asset)
# -----------------------------------------------------------------------------
#  RobotID 는 "역할"이다 — 공장의 한 자리(station). 스케줄·팀 명부·씬트리 간선·RVO 맵이
#  전부 이 역할을 키로 쓰고, 역할은 절대 안 바뀐다. 로봇이 고장났을 때 바뀌는 것은 그
#  자리를 채우는 "물리적 개체"다: 창고에서 다른 본체가 나와 그 자리를 이어받는다.
#
#  실제 공장과 같다. 작업지시서는 "7번 자리"에 내려가고, 7번 자리의 장비가 고장나면 새
#  유닛을 넣되 지시서를 다시 쓰지는 않는다. 그리고 정비기록은 자리가 아니라 **유닛
#  일련번호**에 붙는다 — 이 장부가 저장하는 게 정확히 그것이다.
#
#  왜 딕셔너리가 아니라 장부인가:
#    이전 기록은 `HOT_SWAP_ASSETS[역할] = (...)` 즉 딕셔너리 "대입"이었다. 같은 역할이
#    두 번 교체되면 첫 기록이 조용히 사라진다. 빌드 한 판이면 괜찮지만, 여러 판을 이어
#    돌리는 캠페인에서는 치명적이다 — 추적하려는 "함대 노화"가 바로 그 사라지는 이력이다.
#    그래서 append-only 로 쌓고, "지금 자산"은 저장하지 않고 이력에서 유도한다.
#
#  사건 종류 (물리적으로 다르므로 일부러 합치지 않음):
#    :asset_replacement — 기계 고장. 창고에서 새 본체가 나와 역할 인계, 고장 본체는 회수.
#    :battery_swap      — 방전만. 같은 본체, 배터리만 현장 교체.
#    :tow_replacement   — 운반 중 기계 고장. 고장 본체를 팀에서 견인해 빼내고 새 본체가
#                         그 슬롯에 들어감. 역할이 같으므로 명부는 안 건드림 —
#                         견인은 물리적 동작이지 정체성 연산이 아니다.
#
#  [문법 참고]
#   · struct ... end        : 값을 담는 틀(파이썬 dataclass 비슷). @with_kw 없이 기본 생성자 사용.
#   · Union{X,Nothing}      : "X 이거나 아직 없음". 아직 안 끝난 배치의 t_out 에 사용.
#   · findlast(f, v)        : 조건 f 를 만족하는 마지막 원소의 인덱스(없으면 nothing).
#   · v[i] = ...            : 배열 원소 교체. 여기서는 "열린 배치를 닫을" 때 씀.
# =============================================================================

"""
    AssetAssignment

One period during which a physical asset filled a role. `t_out === nothing` means the
assignment is still open (this asset is the one currently in the role).

- `role`   — the stable `RobotID` the schedule/teams/scene tree key on
- `asset`  — the physical body serving that role for this period
- `t_in` / `t_out` — sim step the asset was installed / removed
- `event`  — why this period started (`:initial`, `:asset_replacement`,
             `:battery_swap`, `:tow_replacement`)
- `cause`  — the failure that triggered it (`:fault`, `:battery`, `:none`)
- `soc_at_swap` — SoC of the outgoing asset when it was pulled (`nothing` if unknown)
- `position` — 2D world spot where the swap happened
"""
# 한 물리 자산이 한 역할을 채우고 있던 "기간" 한 건. t_out === nothing 이면 아직 진행 중(=현재 자산).
struct AssetAssignment
    role::AbstractID                       # 안 바뀌는 역할 id(스케줄·팀·씬트리·RVO 가 쓰는 것)
    asset::AbstractID                      # 그 기간 동안 그 역할을 채운 물리 개체
    t_in::Int                              # 투입된 sim step
    t_out::Union{Int,Nothing}              # 빠진 sim step (nothing = 아직 현역)
    event::Symbol                          # 이 기간이 시작된 이유
    cause::Symbol                          # 촉발한 고장 종류 (:fault / :battery / :none)
    soc_at_swap::Union{Float64,Nothing}    # 빠져나간 자산의 SoC(모르면 nothing)
    position::Vector{Float64}              # 교체가 일어난 2D 위치
end

# 전체 장부(append-only). 순서 = 시간 순.
const ASSET_LEDGER = Ref(Vector{AssetAssignment}())

# 현재 sim step. 엔진에 전역 스텝 카운터가 없어서(스텝은 매번 인자로만 전달됨) 여기에 하나 둔다.
# `ood_inject_step!`(매 스텝 호출)이 갱신하므로 장부가 "언제 교체됐는지"를 적을 수 있다.
# 0 = 아직 시작 안 함/모름. 이 값이 없으면 캠페인에서 교체 간격을 계산할 수 없다.
const SIM_STEP = Ref(0)
set_sim_step!(k::Integer) = (SIM_STEP[] = Int(k); nothing)
_current_sim_step() = SIM_STEP[]

# 시계 단일 진실원 (spec §3.3 Clock · §11-8). 예전에는 시계가 셋이었다 —
# SIM_STEP · HazardState.t/.step · run_demo._SIM_STEP. Courier.step_out/step_swap 이
# **절대 스텝 인덱스**이므로 시계가 갈리면 배송이 과거나 미래에 도착한다.
# 초 단위가 필요한 소비처는 이 함수를 쓴다 — dt 를 각자 곱하지 말 것.
sim_time(dt::Real) = Float64(dt) * SIM_STEP[]

# 빌드/캠페인 시작 시 장부 비우기.
reset_asset_ledger!() = (empty!(ASSET_LEDGER[]); nothing)
# 장부 전체를 그대로 돌려주는 접근자.
asset_ledger() = ASSET_LEDGER[]

"""
    asset_of(role) -> AbstractID

The asset currently filling `role`. Falls back to `role` itself when the ledger has no
entry — generation 0 is the body the role was born with, so an untouched fleet needs no
ledger rows at all.
"""
# 지금 이 역할을 채우고 있는 자산. 장부에 기록이 없으면 역할 자신(=최초 본체, 0세대)을 반환.
function asset_of(role::AbstractID)
    i = findlast(a -> a.role == role && a.t_out === nothing, ASSET_LEDGER[])
    return i === nothing ? role : ASSET_LEDGER[][i].asset
end

"""
    asset_generation(role) -> Int

How many times the BODY behind `role` has been exchanged. `0` = still the original
body. This is the number to render on the robot: "same R7, third chassis".

Counts body-changing events only. A `:battery_swap` keeps the same chassis, so it is a
maintenance row in the ledger but NOT a new generation — the first version of this
function counted every non-`:initial` row and reported a battery swap as a new body.
"""
# 이 역할의 "본체"가 몇 번 교체됐는지. 0 = 아직 최초 본체. 화면에 표시할 세대 값.
# 본체가 바뀌는 사건만 센다 — 배터리 교체는 같은 본체이므로 정비 기록일 뿐 새 세대가 아니다
# (초판은 :initial 이 아닌 모든 행을 세어 배터리 교체를 새 본체로 잘못 보고했다).
const _BODY_CHANGING_EVENTS = (:asset_replacement, :tow_replacement)
asset_generation(role::AbstractID) =
    count(a -> a.role == role && a.event in _BODY_CHANGING_EVENTS, ASSET_LEDGER[])

"""
    asset_history(role) -> Vector{AssetAssignment}

Every assignment period for `role`, oldest first — the role's maintenance record.
"""
# 이 역할의 모든 배치 기간(오래된 것부터) = 그 자리의 정비 이력.
asset_history(role::AbstractID) = [a for a in ASSET_LEDGER[] if a.role == role]

"""
    record_asset_swap!(role, new_asset; event, cause=:none, step=0, soc=nothing,
                       position=Float64[0.0, 0.0]) -> AssetAssignment

Close the role's currently-open assignment (if any) at `step` and append the new one.
Append-only: nothing is ever overwritten, so a role swapped five times keeps five rows.

For `:battery_swap` pass `new_asset = asset_of(role)` — the body does NOT change, only
the battery. The row still gets written, because a battery swap is a maintenance event
that a campaign must be able to count.
"""
# 이 역할의 "열려 있던" 배치를 step 에서 닫고, 새 배치를 덧붙인다. 덮어쓰기 없음(다섯 번 교체하면 다섯 행).
# 배터리 교체는 new_asset 에 현재 자산을 그대로 넘긴다 — 본체는 안 바뀌지만 정비 사건이므로 행은 남긴다.
function record_asset_swap!(role::AbstractID, new_asset::AbstractID;
                            event::Symbol, cause::Symbol = :none, step::Int = 0,
                            soc::Union{Real,Nothing} = nothing,
                            position = Float64[0.0, 0.0])
    led = ASSET_LEDGER[]
    # 같은 역할의 아직 안 닫힌 배치를 찾아 t_out 을 채워 닫는다(구조체가 불변이라 새로 만들어 교체).
    i = findlast(a -> a.role == role && a.t_out === nothing, led)
    if i !== nothing
        old = led[i]
        led[i] = AssetAssignment(old.role, old.asset, old.t_in, step,
                                 old.event, old.cause, old.soc_at_swap, old.position)
    end
    rec = AssetAssignment(role, new_asset, step, nothing, event, cause,
                          soc === nothing ? nothing : Float64(soc),
                          Vector{Float64}(position))
    push!(led, rec)
    return rec
end

"""
    swap_event_kind(; cause, captured) -> Symbol

The physically correct event name for a swap, from the failure `cause` and whether the
robot was mid-carry. This is the single place the taxonomy lives, so the enactment, the
renderer and the dump cannot disagree about what happened.

    battery, any        -> :battery_swap        (same body, new battery, in the field)
    fault,   carrying   -> :tow_replacement     (tow the dead body out of the team)
    fault,   free       -> :asset_replacement   (fresh body drives out of the depot)

`captured` is a fact about the world, not a choice — which is why the tow variant is a
mode here and not a separate action in the planner's vocabulary.
"""
# 원인(cause)과 "운반 중인가(captured)"로부터 물리적으로 올바른 사건 이름을 정한다.
# 분류가 여기 한 곳에만 있어야 실행부·렌더러·덤프가 서로 다른 말을 하지 않는다.
function swap_event_kind(; cause::Symbol, captured::Bool)
    cause === :battery && return :battery_swap      # 방전이면 본체는 그대로, 배터리만
    captured && return :tow_replacement             # 운반 중 기계고장이면 견인해서 빼냄
    return :asset_replacement                       # 그 외 기계고장이면 창고서 새 본체
end

"""
    asset_ledger_summary() -> Vector{NamedTuple}

Per-role rollup for a HUD or a dump row: current asset, generation, and how many of
each event kind the role has seen. Roles that were never touched do not appear.
"""
# 역할별 요약(HUD/덤프용): 현재 자산, 세대, 사건 종류별 횟수. 한 번도 안 건드린 역할은 안 나옴.
function asset_ledger_summary()
    roles = unique(a.role for a in ASSET_LEDGER[])
    return [(role = r,
             asset = asset_of(r),
             generation = asset_generation(r),
             replacements = count(a -> a.role == r && a.event === :asset_replacement, ASSET_LEDGER[]),
             tows         = count(a -> a.role == r && a.event === :tow_replacement, ASSET_LEDGER[]),
             battery_swaps = count(a -> a.role == r && a.event === :battery_swap, ASSET_LEDGER[]))
            for r in roles]
end
