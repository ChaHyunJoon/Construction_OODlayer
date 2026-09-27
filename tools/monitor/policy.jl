# tools/monitor/policy.jl
# =============================================================================
# **결정 정책 레이어(공용)** — run_demo.jl(수동 루프)과 render_demo.jl(애니메이션 렌더)이
# 똑같은 결정을 내리도록 한 곳에 모은 파일. 여기만 고치면 두 엔진이 함께 바뀐다.
#
#   canonical : CB.canonical_respec 규칙 lookup (줄리아 내부)
#   oracle    : reference_policy.py 의 기준행동 a* 를 결정시점에 재계산해 집행(비교용 상한 lane)
#   surrogate : 배포 RandomForest      ┐ 파이썬 서비스 POST /decide 로 한 번에 받음
#   dspy      : MIPROv2 컴파일 gpt-4o  ┘
#
# 매 OOD 사건마다 **셋을 모두 계산해 기록**하고(UI 가 전환해 볼 수 있게), 실제로 실행되는 것은
# DEMO_POLICY 하나뿐이다. 서비스가 없으면 canonical 로 폴백하고 그 사실을 verdict 에 남긴다.
#
# ENV: DEMO_POLICY(canonical|noop|oracle|surrogate|dspy) · DSPY_URL · DEMO_ALL_POLICIES(0 이면 비교값 수집 생략)
# =============================================================================
import HTTP, JSON3, SHA
using Graphs

const POLICY   = lowercase(get(ENV, "DEMO_POLICY", "canonical"))
const DSPY_URL = rstrip(get(ENV, "DSPY_URL", "http://127.0.0.1:8077"), '/')

# ---- `/decide` 읽기 시한 (2026-09-05) -------------------------------------------------------
# 🔴 여기 있던 값은 **하드코딩 60 이었고, 그것이 유료 런 13 을 죽였다.** 증상은 서비스가
#    빈 결정을 냈다는 것처럼 보였지만(라우터가 "returned no decision: (no error field)"),
#    실제로는 클라이언트가 60초에 손을 뗀 것이다 — 서버는 그 뒤에 **정상 결정을 완성했다**
#    (그 런 직후 `/health` 의 `calls: 1, billed: 1` 이 그 완성된 호출 하나다).
#
# 왜 60 이 모자라는가 (실측, 2026-09-05, 라이브 `gpt-5.6-sol` · `/decide` 직접 프로브):
#   · 같은 zone 사건 한 건의 왕복 = **74.33초**. 응답은 온전했다
#     (`chosen=NOOP` · `tool_calls_n=1` · `error=nothing` · `tool_lane_error=nothing` ·
#      합성 레인까지 완주해 `tool_minted=true`).
#   · 그 왕복이 태운 LM 호출은 **넷**이다: macro + observe + design + compose
#     (`synthesis["stages"] == ["observe","design","compose"]`, 되먹임/재조합 없음)
#     ⟹ 호출당 약 18.6초.
#   · 한 `/decide` 의 **구조적 최대 경로는 일곱**이다(`synthesize.py` 의 `stages.append`
#     자리 여섯 + macro): observe · design · redesign · compose · 되먹임 design ·
#     재조합 compose. 같은 속도로 ≈ 130초.
#   · 300 = 그 최대 경로의 약 2.3배. 프로바이더 변동에 여유를 주되, 서비스가 진짜로 죽었을
#     때 런이 영원히 매달리지는 않는 값이다.
#
# ⚠️ 이 값을 다시 내리려면 **재야 한다.** 위 74.33 은 합성이 가장 짧은 경로로 끝난 판이라
#    이 사건 종류의 **하한**이지 상한이 아니다.
# ⚠️ 시한 초과는 재시도되지 않는다(실측: 런 13 이 `retries = 3` 인데도 `calls` 가 1 이었다).
#    그러므로 이 값을 올리는 것이 과금을 곱하지 않는다.
const DSPY_TIMEOUT_S = something(tryparse(Int, strip(get(ENV, "DSPY_TIMEOUT_S", ""))), 300)

# 🔴 마지막 `/decide` 전송이 **왜** 실패했는가. `service_decide` 는 실패를 `nothing` 으로
#    접는데(그 반환 계약은 호출자 여럿이 의존한다), 그러면 `policy_entry(nothing, …)` 의
#    `error` 가 빈 문자열이 되고 라우터는 "(no error field)" 만 찍는다 — 런 13 에서 실제로
#    진짜 사유(`TimeoutError: Connection closed after 60 seconds`)가 그렇게 사라졌다.
#    그 사유는 `@warn` 으로는 남았지만 **라우터의 죽는 메시지와 연결되지 않았다.**
#    ⟹ 반환 모양을 안 바꾸고 사유만 옆으로 나른다. `decide_all` 이 그것을 읽어 메시지에 싣는다.
const LAST_DECIDE_TRANSPORT_ERROR = Ref{String}("")

# ---- 순수 함수로 분리한 조각들 (2026-08-14) -------------------------------------------------
# 이 파일은 67KB 에 ENV·ConstructionBots 의존이라 **통째로는 단위검사가 안 된다.** 그래서
# 단위검사가 가능한 판단만 의존성 0 인 파일로 뺐다:
#   lane_select.jl : 레인 선택 분기표(3-way)        -> test_lane_select.jl
#   narrate.jl     : 레코드 -> 자연어 문장           -> test_narrate.jl
#   dp_lane.jl     : DEMO_POLICY=dp 전용 표 조회     (라우터/UI 에는 들어가지 않는다)
include(joinpath(@__DIR__, "lane_select.jl"))
include(joinpath(@__DIR__, "narrate.jl"))
include(joinpath(@__DIR__, "dp_lane.jl"))

"""
    routing_kind_of(truth) -> String

`OODTruth` 하나에 대한 라우팅 kind. `lane_select.jl` 의 순수 함수에 **이 파일이 아는 것**
(구상 타입과, battery 라면 그 심각도)을 먹여 준다.

🔴 왜 이 래퍼가 있나 (2026-08-30). 유도 지점이 **둘**이었다 — `service_decide` 의 페이로드
줄과 `decide_all` 의 라우터 줄. §A-1 은 둘을 같게 두는 것을 리뷰가 아니라 기계 게이트
(`test/service_decide_ships_routing_kind.jl` (2)(3)절)에 맡겼는데, 2026-08-30 에 battery 가
심각도로 갈리면서 **각 자리가 심각도를 꺼내는 코드까지** 같아야 하게 됐다. 표현이 길어질수록
두 자리가 갈릴 여지가 커지므로 아예 함수 하나로 접는다 — 이제 두 자리는 같은 이름을 부른다.
그 게이트는 그대로 남는다(래퍼가 있어도 호출을 **빠뜨리는** 것은 여전히 가능하다).

🔴 `truth.soc_after` 를 여기서만 읽는다. `lane_select.jl` 은 의존성 0 계약 위에 있어
`CB.BatteryTruth` 를 알면 안 되므로, 타입을 아는 쪽(이 파일)이 스칼라만 꺼내 넘긴다.
"""
routing_kind_of(truth) = routing_kind(
    String(nameof(typeof(truth))),
    truth isa CB.BatteryTruth ? truth.soc_after : nothing)

# =============================================================================
#  라우터 (2026-07-28 추가)
# =============================================================================
# 여기까지의 데모는 실행 정책을 DEMO_POLICY 로 **런 전체에 고정**했다. 그래서 화면의 정책 버튼은
# "사람이 골라 보는 비교 도구"였지, 시스템의 결정이 아니었다. 목표 설계는 그 반대다:
#
#     처음 보는 사건  -> LLM 이 자연어 관찰을 읽고 대응     (adaptive)
#     익숙한 사건    -> surrogate 가 0.1 ms 에 대응        (cost efficient)
#     **그 판별을 시스템이 사건마다 스스로 한다**
#
# 🔴 **세대 표식 (2026-08-29, §B-1 — novelty 축 삭제).** 2026-07-28~2026-08-29 사이의 이 절은
# 그 판별을 **covariate novelty**(`src/safety/novelty.jl` 의 conformal p-value)로 했다. 그 축은
# T11(`884aa9c9`)이 `select_lane` 의 **kind 색인 라우터**로 갈아치우면서 결정에서 완전히 끊겼고,
# 그 뒤로는 매 사건 계산만 되고 아무것도 정하지 않은 채 `rt["enabled"]` 로 *"novelty 축이 실행을
# 정했다"* 는 **거짓 주장**만 기록했다. §B-1 이 그 계산과 기록을 지웠다: `ROUTER_EPS` ·
# `install_novelty!()` · `router_enabled()` · `route_verdict` 의 `enabled`/`advisory`/`novel`/
# `novelty_measured`/`p`/`score`/`eps`/`would_route_to` 키. 오늘 레인을 정하는 것은 `routing_kind`
# 하나다(`decide_all` 의 `select_lane` 줄).
#   ⚠️ **옛 녹화와의 비교가 이 커밋에서 끊긴다** — 그 키들의 부재는 "값이 없다" 가 아니라
#      **"세대가 다르다"** 로 읽어야 한다. 두 세대를 같은 표에 섞지 말 것.
#   ⚠️ 판별기 **라이브러리**(`src/safety/novelty.jl`)는 그대로 산다 — 지운 것은 이 파일의
#      배선뿐이다. `event_descriptors_of`(아래)는 감지기를 안 읽으므로 LLM 페이로드용으로 계속
#      계산되고, 라이브러리의 게이트는 `tools/test_novelty.jl` · `tools/test_router.jl` 이다.
#   [역사] 그 축을 고른 근거(취향이 아니라 실측): 새 *종류* 탐지에서 forest 의 내부 이견은
#      recall 0.00 이다 — 처음 보는 영역에서 나무들은 근거가 없어 **똑같이** 엉뚱한 답을 지지하므로
#      합의율이 오히려 높아 "확신함" 으로 읽힌다. covariate novelty 는 "학습 입력 분포에서 얼마나
#      먼가" 를 재므로 recall 0.94(`md/DESIGN_ASSIMILATION.md` 4-c). 🔴 **이 실측은 아직 참이고,
#      그것이 대체 이유가 아니다** — 대체 이유는 §0-C 결정 1(판정 입력을 kind 하나로 줄인다)이다.
#
# ENV
#   DEMO_ROUTER  auto(기본) | 1 | 0
#                "0" 이면 라우터가 레인을 안 고르고 DEMO_POLICY 가 런 전체에 고정된다.
#                🔴 §B-1 이전의 auto 는 *"낯섦 감지기가 설치돼 있으면 켠다"* 였다 — 그 감지기
#                축이 사라졌으므로 **이제 auto 와 1 은 같은 뜻**이다(`router_drives()` 참조).
const ROUTER_MODE = lowercase(get(ENV, "DEMO_ROUTER", "auto"))

"""
    router_drives() -> Bool

**사람이 켠 손잡이만** 본다 — 설계서(`2026-08-20-reduced-state-ood-smdp-design.md`) §3 의
`ROUTER_DRIVES`. 보는 것은 `ROUTER_MODE`(`DEMO_ROUTER` env)와 `POLICY`(`DEMO_POLICY` env)
**둘뿐**이다.

🔴 `POLICY != "noop"` 항의 근거 (2026-08-06, STATUS §5 실측): `DEMO_POLICY=noop` 으로 돌린 런이
3건 모두 Replace 를 집행했다. 라우터가 켜져 그 런의 레인을 대신 골랐기 때문인데, 라우터의 레인은
surrogate/dspy 뿐이라 noop 은 **절대 실행될 수 없었다.** noop 은 정책 후보가 아니라 **통제 실험의
바닥선**이다 — 개입이 실제로 이득인지 재려면 아무도 이 레인을 대신 판단해 주면 안 된다. 그래서
여기서 라우팅 자체를 끈다.

🔴 [역사 · 2026-08-27 Fix round 1, Ruling R11] 이 함수는 `router_enabled()` 와 **구별하려고**
새로 만들어졌다. 그 함수는 `ROUTER_MODE ∈ {"1","auto"}` 일 때 `install_novelty!()` 를 불러
**교정 JSON 유무까지 나르는** 술어였고, 어휘 미달 격상 게이트를 그것으로 쓴 판에서 "교정에서
뗀다" 고 한 결합이 하나도 안 끊겼다. **2026-08-29 §B-1 이 그 두 함수를 지웠다** — novelty 축
자체가 없어졌으므로 이제 혼동할 상대가 없고, 이것이 라우터 손잡이의 유일한 술어다. 같은 커밋이
그 혼동의 재발을 막던 정적 검사 다섯(`tools/test_policy_escalation.jl` 의 T8·T8b·T9b·T9c·T9d)도
지웠다: 막으려던 함수가 더 이상 존재하지 않는다.
"""
router_drives() = ROUTER_MODE != "0" && POLICY != "noop"

# 여기가 "누가 매크로를 고르는가"를 결정하는 유일한 지점이다. 아래 세 함수만 보면 된다:
#   ood_features  : 결정 순간의 공개 상태(정답 누수 없음) — 오프라인 라벨러의 capture_features 와 동일 항목
#   dspy_decide   : 그 상태를 DSPy 서비스에 POST → 매크로 + 순위 + margin
#   decide_macro  : 정책에 따라 canonical / dspy 중 하나를 고르고, 실패 시 canonical 로 폴백

# 대상 로봇이 아직 안 끝낸 운반 투입 작업 수(피해 규모 대리지표). 라벨러의 _agent_pending_tasks 와 동일 로직.
function _agent_pending(env, agent)
    agent === nothing && return -1
    sched = env.sched; n = 0
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue
        v in env.cache.closed_set && continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1])) isa CB.FormTransportUnit || continue
        n += 1
    end
    return n
end

# 활성 로봇의 SoC 사전. 예비·반출예비·고장 로봇을 뺀다.
# 🔴 **소비처가 둘이고 같은 집합 위에서 읽어야 한다** — `_battery_fleet_features`(median·
#    higher_soc)와 `_smdp_state_features`(SMDP 상태의 `c` = 최소 SoC). 판정을 재구현하면
#    median 과 min 이 서로 다른 함대를 말하게 되고, 그 어긋남은 에러 없이 프롬프트로만 샌다.
#    (아래 두 🔴 블록이 이 제외 집합의 근거다 — 함수를 옮겼을 뿐 판정은 한 글자도 안 바뀌었다.)
function _active_nonspare_socs()
    local fleet = try CB.BATTERY_FLEET[] catch; nothing end
    (fleet === nothing || isempty(fleet.soc)) && return Dict{Any,Float64}()
    # 🔴 [Fix round 1, I-1] 창고 예비(spare)를 뺀다 — `init_battery_fleet!` 는 예비까지
    #    `fleet.soc` 에 soc0=1.0(안 닳음)으로 넣으므로, 안 빼면 "함대의 나머지가 더 낫다"는
    #    median·higher_soc_robots 둘 다 위로 새는 방향으로 거짓말을 한다. 같은 판정을
    #    `battery.jl` 의 `_pick_battery_target` 이미 쓰고 있다(:428-429, "예비를 절대 고르지
    #    않는 것이 요점") — 그 술어(`is_spare`/`is_recovery_spare`)를 그대로 재사용한다.
    #    재구현하면 두 판정이 갈라질 수 있다(이 레포가 이미 그 사고를 여러 번 냈다).
    # 🔴 [Fix round 2, S1 final wave / F-6] 위 둘만으로는 "체크아웃된(반출된) spare" 와
    #    "고장난 로봇" 이 안 빠졌다 — `replace_robot!` 은 교체 뒤 `spare` 를 `CHECKED_OUT_SPARES`
    #    에 넣고 물리적으로 은퇴시키지만(`_retire_spare_body!`), `is_recovery_spare` 가 보는
    #    `RECOVERY_SPARES` 는 그 반대쪽 role(`faulted`)에 찍힌다 — 그래서 은퇴한 `spare` 의
    #    `fleet.soc` 항목(=1.0, 절대 안 닳는다)이 "활성 로봇"으로 계속 잡혀서
    #    `robots_with_higher_soc` 라벨("active robots")이 죽은 고충전 로봇을 센다. 아직 교체
    #    안 된 고장 로봇도 마찬가지로 실제로는 못 움직인다. 새 술어를 짓지 않고 이미 있는
    #    접근자 둘(`checked_out_spares`/`faulted_robots`, 같은 파일 `ood_injection.jl`)을
    #    그대로 더 뺀다 — `_hz_excluded()`(`smdp/hazard.jl`)가 정확히 이 셋의 합집합이지만,
    #    hazard.jl 이 로드 안 된 순수 배터리 런에서는 그 함수가 없어 이 자리에서 부르면 죽는다.
    local excluded_ids = try
        Set{Any}(vcat(collect(keys(CB.faulted_robots())), collect(CB.checked_out_spares())))
    catch
        Set{Any}()
    end
    return Dict{Any,Float64}(
        id => s for (id, s) in fleet.soc
        if !(try CB.is_spare(id) || CB.is_recovery_spare(id) catch; false end) &&
           !(id in excluded_ids))
end

# 함대 SoC 통계만. 세계를 안 보므로 단위검사가 된다(`test/battery_load_features.jl`).
# 🔴 배터리 레이어가 꺼져 있으면 **빈 Dict** 다 — 0 으로 접지 않는다. "재 봤더니 0" 과
#    "안 쟀다" 는 다른 사건이고, 0 을 실으면 프롬프트가 모델에게 거짓말을 한다.
function _battery_fleet_features(agent)
    d = Dict{String,Any}()
    local nonspare = _active_nonspare_socs()
    isempty(nonspare) && return d
    local socs = collect(Float64, values(nonspare))
    local s = sort(socs); local n = length(s)
    d["battery_fleet_soc_median"] = isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2
    local mine = get(nonspare, agent, nothing)
    mine === nothing || (d["battery_higher_soc_robots"] = count(>(Float64(mine)), socs))
    return d
end

"""
    _smdp_state_features() -> Dict

SMDP 상태(사용자 정의 `{p, b, v, w, c, k}`)의 **두 축**만 만든다 — `b`(고장 로봇 수)와
`c`(활성 함대 최소 SoC). 나머지 넷은 `ood_features` 가 이미 싣는다:
`p` = `progress` · `v` = `spare_count` · `w` = `n_active` · `k` = `kind`.
(`d` = time-to-done 은 이 세대에서 **일부러 뺐다** — 결정 시점 추정량이 세계에 없다.
 `tplan.jl` 의 `T_plan_next` 는 λ 의 구간상수 경계이지 완료시간이 아니다.)

🔴 **결정 시점 값이다. 이름을 `smdp_*` 로 일부러 다르게 쓴다.** 라벨셋의 `min_soc` ·
`hz_break` 은 rollout 을 **완주한 뒤** 측정한 사후 필드다(`gen_oracle_dataset.jl` 의
"efficiency-axis labels" 블록 — 같은 결정 상태에서 `min_soc` 이 0.016 과 0.999 로 갈리는
것이 실측 증거다). 같은 이름을 재사용하면 그 leakage 가 조용히 피처로 들어온다.

🔴 `c` 를 `CB.battery_report().min_soc` 으로 만들지 말 것. 그 함수는 `fleet.soc` 전체를
보므로 **은퇴한 고충전 예비(soc=1.0, 안 닳는다)** 까지 센다. `_active_nonspare_socs()` 가
그 셋을 이미 빼 놓았고, median 과 같은 함대를 말해야 한다.

못 쟀으면 **키를 안 싣는다**(0 으로 접지 않는다 — 이 파일의 삼상 규약).
"""
function _smdp_state_features()
    d = Dict{String,Any}()
    local nb = try length(CB.faulted_robots()) catch; nothing end
    nb === nothing || (d["smdp_n_broken"] = nb)
    local nonspare = _active_nonspare_socs()
    isempty(nonspare) || (d["smdp_fleet_soc_min"] = minimum(values(nonspare)))
    return d
end

# 이 로봇이 아직 맡고 있는 운반 작업의 화물 질량. 순회는 `_agent_pending` 과 **같다** —
# 그 함수가 이미 "미완 RobotGo 중 후속이 FormTransportUnit 인 것"을 세므로, 여기서는 같은
# 후속 노드에 `_payload_mass` 를 걸기만 한다(추가 계산 없음).
# 🔴 `_payload_mass_measured` 의 가드가 받는 셋 중 하나가 `FormTransportUnit` 이다 — 그래서
#    후속 노드를 넘긴다. `RobotGo` 를 넘기면 가드가 던진다(이 함수의 단위검사 범위 밖 —
#    `test/battery_load_features.jl` 머리말 참조).
# 🔴 [Fix round 2, S1 final wave / F-7] `CB._payload_mass`(물리 회계 훅용)가 아니라
#    `CB._payload_mass_measured` 를 부른다 — 전자는 가드·형상실패를 **자체적으로** 0.0 으로
#    삼켜서 던지지 않으므로, 아래 try/catch 가 절대 안 걸리는 죽은 코드였다(Fix round 1,
#    I-6 이 지키려던 것을 실제로는 못 지켰다). 후자는 못 재면 던지고, 아래가 그것을 잡아
#    `mass_ok=false` 로 둘 다(`payload_max/total_kg`) 뺀다 — 삼상 규약("못 쟀다 ≠ 0").
function _battery_load_features(env, agent)
    d = Dict{String,Any}()
    agent === nothing && return merge(d, _battery_fleet_features(agent))
    local sched = env.sched
    local p = CB.BatteryParams()
    local n_jobs = 0
    local masses = Float64[]
    local mass_ok = true
    for v in Graphs.vertices(sched)
        local node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue
        v in env.cache.closed_set && continue
        local outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        local succ = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
        succ isa CB.FormTransportUnit || continue
        n_jobs += 1
        # 🔴 [Fix round 1, I-6] 못 잰 질량을 `0.0` 으로 접지 않는다(삼상 규약, `_battery_fleet_features`
        #    와 같은 층위). `pending_transports` 는 **개수**라 그래프 구조만으로 항상 잴 수 있으니
        #    그대로 두지만, `max`/`total` 은 부분측정 위에서 계산하면 그 자체가 거짓 사실이 된다 —
        #    하나라도 실패하면 둘 다 통째로 뺀다. `@warn`(`@info` 아님): run_demo.jl 이
        #    `global_logger(..., Logging.Warn)` 을 심어 `@info` 는 조용히 버려진다.
        try
            push!(masses, Float64(CB._payload_mass_measured(env, succ, p)))
        catch e
            @warn "_battery_load_features: _payload_mass_measured failed — payload_max/total_kg 를 뺀다 (못 쟀다 ≠ 0)" agent exception = e
            mass_ok = false
        end
    end
    if n_jobs > 0
        d["battery_pending_transports"] = n_jobs
        if mass_ok
            d["battery_payload_proxy_max"]   = maximum(masses)
            d["battery_payload_proxy_total"] = sum(masses)
        end
    end
    return merge(d, _battery_fleet_features(agent))
end

"""
    candidate_slot_upper_bound(env) -> Union{Nothing,Int}

결정 시점에 **배정 슬롯이 몇 개나 비어 있는가**의 상계. `nothing` 은 "못 쟀다"다.

🔴 이 값은 후보 `(v, v2)` **쌍**의 상계가 아니다. `formulate_milp` 의 Big-M 루프는 세
조건을 모두 만족하는 `(v, v2)` 쌍에만 `edge_costs` 를 채우는데, 그 첫 조건이
`outdegree(sched, v) < n_eligible_successors[v]` 다. 여기서는 **그 조건만** 통과하는
**정점(vertex)** 수를 센다 — 정점 하나가 여러 쌍에 기여할 수도, 하나도 기여하지 않을 수도
있으므로 이 카운트는 쌍의 개수를 어느 방향으로도 상계짓지 못한다. 나머지 둘(선행 여유 ·
템플릿 매치)을 복제하면 hot loop 의 판정식이 두 벌이 되고, 이 레포는 그런 두 벌이 조용히
갈리는 사고를 반복해 겪었다.
⟹ **0 이면 후보 간선이 증명 가능하게 0 이고, >0 이면 아무 결론도 안 준다.**

🔴 왜 이 값이 중요한가. `edge_costs` 가 비면 `get_objective_expr` 이 조기 반환해 목적식이
**순수 makespan 으로 후퇴한다.** 그러면 `EDGE_COST_MULTIPLIER` 든 payload 든 어떤 배수도
목적식에 닿지 못한다 — 결정 시점 재가격이 원리적으로 무효가 된다.

🔴 이 값은 **"MILP 가 돌았는가"를 주장하지 않는다.** 그건 `enact.jl` 의 센티넬이 잰다.
두 관측을 한 숫자로 섞지 말 것.

**순수하다** — `preprocess_project_schedule` 은 `sched` 만 읽고 아무것도 안 바꾼다.
"""
function candidate_slot_upper_bound(env)
    local sched = try env.sched catch; nothing end
    sched === nothing && return nothing
    return try
        local pp = CB.preprocess_project_schedule(sched)
        local nes = pp[3]                      # n_eligible_successors (8-튜플의 3번째)
        count(v -> Graphs.outdegree(sched, v) < nes[v], Graphs.vertices(sched))
    catch e
        @warn "candidate_slot_upper_bound: probe failed" exception = e
        nothing                                # 🔴 0 이 아니다 — 삼상 규약
    end
end

"""
    release_then_candidates(env) -> Union{Nothing,NamedTuple}

**release 를 먼저 하면 후보 배정 간선이 몇 개 열리는가** — 결정 시점에서, 세계를 안 건드리고.
`nothing` 은 "못 쟀다"다(삼상 규약: 0 과 절대 섞지 않는다).

🔴 왜 이 값인가 (실측 2026-09-01). `candidate_slot_upper_bound` 는 상계라 `>0` 이어도 아무
결론이 없다. 정확값을 정답원(`formulate_milp` 이 채우는 `LAST_EDGE_COSTS`)에서 직접 재보니
**세 판 전부 0** 이었고(tractor·colored_8x8, `:greedy`/`:milp` 무관), 단계별로는
조건②(`indegree(v2) < n_eligible_predecessors[v2]`)에서 3176 → 0 으로 전멸했다 = **받는 쪽이
포화**다. 그런데 `release_pending_assignments!` 로 미래 배정 엣지를 떼면 **0 → 2103** 으로
열린다. ⟹ 후보가 0 인 것은 스케줄의 성질이 아니라 **release 를 안 불렀기 때문**이고,
`rebalance_for_battery!`(`battery.jl:747`)가 그것을 안 불러서 자유도 0 인 판을 다시 풀고
`:rebalanced` 를 내는 침묵 성공이 난다.
⚠️ 그 실측은 전부 `return_env_before_sim=true`(t=0)다. **결정 시점(closed≫0)에서도 열리는지가
이 프로브가 답하는 유일한 물음이다.**

🔴 **비개입 계약** — `release_pending_assignments!` 는 스케줄만 건드리는 함수가 아니다:
`reset_slot_to_invalid!` 가 `replace_in_schedule!(sched, env.scene_tree, …)` 로 **scene_tree**
를 고치고 `get_unique_invalid_id` 로 **전역 `INVALID_ID_COUNTERS`** 를 내린다. 그래서
  (a) `sched` 와 `scene_tree` 를 **한 번의 `deepcopy` 로 함께** 뜬다 — 따로 뜨면 둘 사이의
      공유 참조가 끊겨 사본이 원본과 다른 세계가 된다.
  (b) 무효 ID 카운터를 스냅샷·복원한다. 안 하면 프로브가 발급한 음수 id 만큼 실제 런의
      id 발급이 밀려 **같은 시드가 다른 판을 만든다**(이 레포가 이미 데인 축).
검증(실측): 같은 env 에 두 번 불러 원본 `ne` 337 불변 · 카운터 `-48` 불변 · 두 호출 모두
`(after=2103, released=43)` — 멱등이고 직접(파괴적) 실험과 값이 같다. 🔴 최종 리뷰 F8 정정:
여기 있던 `before=0` 은 옛 시그니처의 잔재다 — 이 함수의 실제 반환에는 `before` 필드가
없다(아래 `function` 본문의 `(after = ..., released = ...)` 를 보라).
"""
function release_then_candidates(env)
    local saved_ids = copy(CB.INVALID_ID_COUNTERS)
    return try
        local sched_c, tree_c = deepcopy((env.sched, env.scene_tree))
        local shim = (sched = sched_c, scene_tree = tree_c, cache = env.cache)
        local removed = CB.release_pending_assignments!(shim, CB.build_invariant(env))
        # 🔴 센티넬. formulate 가 안 돌았는데 0 을 읽으면 "후보 0"(설계를 죽이는 관측)과
        #    "못 쟀다"가 구별이 안 된다.
        local sent = Dict{Tuple{Int,Int},Float64}()
        CB.LAST_EDGE_COSTS[] = sent
        CB.formulate_milp(CB.SparseAdjacencyMILP(), sched_c, tree_c;
                          optimizer = CB._respec_optimizer())
        CB.LAST_EDGE_COSTS[] === sent && return nothing
        (after = length(CB.LAST_EDGE_COSTS[]), released = length(removed))
    catch e
        @warn "release_then_candidates: probe failed" exception = e
        nothing
    finally
        empty!(CB.INVALID_ID_COUNTERS); merge!(CB.INVALID_ID_COUNTERS, saved_ids)
    end
end

# zone 이 "아직 안 끝난" staging 원을 얼마나 덮는지(0~1) = zone 의 진짜 severity.
function _zone_overlap(env, zkey)
    z = try CB.RESTRICTION_ZONES[][zkey] catch; nothing end
    z === nothing && return -1.0
    zc = Vector{Float64}(CB.get_center(z)[1:2]); zr = Float64(CB.get_radius(z))
    best = 0.0
    for (aid, ball) in env.staging_circles
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set) && continue      # PENDING staging 만
        bc = Vector{Float64}(CB.get_center(ball)[1:2]); br = Float64(CB.get_radius(ball))
        d = sqrt(sum((bc .- zc) .^ 2))
        d >= br + zr && continue
        area = if d <= abs(br - zr)
            π * min(br, zr)^2
        else
            a1 = acos(clamp((d^2 + zr^2 - br^2) / (2d * zr), -1.0, 1.0))
            a2 = acos(clamp((d^2 + br^2 - zr^2) / (2d * br), -1.0, 1.0))
            zr^2 * (a1 - sin(2a1) / 2) + br^2 * (a2 - sin(2a2) / 2)
        end
        best = max(best, area / (π * br^2))
    end
    return best
end

"결정 순간의 공개 상태만 뽑는다(시뮬 결과·오라클 라벨은 절대 포함하지 않음)."
function ood_features(env, truth)
    closed = length(env.cache.closed_set)
    total  = length(CB.get_nodes(env.sched))
    kind, agent = if truth isa CB.FaultTruth
        ("fault", truth.robot)
    elseif truth isa CB.BatteryTruth
        ("battery", truth.robot)
    elseif truth isa CB.ZoneTruth
        ("zone", nothing)
    else
        ("unknown", nothing)
    end
    d = Dict{String,Any}(
        "kind"          => kind,
        "spare_count"   => (try length(CB.active_spares()) catch; 0 end),
        "agent_pending" => _agent_pending(env, agent),
        "progress"      => total > 0 ? closed / total : 0.0,
        "n_active"      => length(env.cache.active_set),
        "closed_at_fire"=> closed,          # surrogate 피처
        # 2026-08-14: 새 22차원 조립기(surrogate_features.build_features)의 work_at_risk 분모가
        # `total_nodes - closed_at_fire` 다. 라벨 행에는 처음부터 있던 필드인데 이 payload 에만
        # 없었다 -- 안 보내면 서비스가 progress 에서 역산하고(항등식이라 값은 같다), closed=0 인
        # 순간에는 역산이 불가능해 work_at_risk 가 1.0 으로 포화한다. 그냥 실어 보낸다.
        "total_nodes"   => total,           # surrogate 피처
        "n_spare_cfg"   => 3,               # surrogate 피처(데모의 spare 설정 수준)
    )
    # ---- S2 창(window): release 뒤에 후보 배정 간선이 몇 개 열리는가 --------------------
    # 🔴 이 값이 0 이면 **재분배가 원리적으로 불가능한 시점**이다. 그 사건에서 정책이 NOOP 을
    #    내는 것은 오답이 아니다 — 평가는 이 값으로 층화한다.
    # 🔴 최종 리뷰 F8 정정: 여기 있던 "실측: closed≈247/287 부터 0" 이라는 임계값 서술은
    #    지웠다 — 사실이 아니라 **한 런의 관측**이었다. 같은 명령을 두 번 돌렸더니
    #    (246→38)·(247→0) 로 갈렸다(이 브랜치는 `bb1b88c4` 의 ID 내용기반 해시가 없어 런
    #    간 재현이 안 된다). 그리고 287 이라는 분모 자체가 이 픽스처(tractor, 10 로봇) 것이라
    #    다른 픽스처(Task 5/7, 305 노드)와 다르다 — "closed≈N 부터 닫힌다" 를 상수로 인용하지
    #    말 것. 창이 언제 닫히는지는 픽스처·시드마다 다시 재야 한다.
    # 🔴 `nothing`("못 쟀다")을 0("창이 닫혔다")으로 접지 않는다. 못 쟀으면 키를 안 싣는다.
    local _win = release_then_candidates(env)
    _win === nothing || (d["s2_after_release_candidates"] = _win.after)
    # ---- SMDP 상태의 b·c (2026-09-06) -------------------------------------------------
    # 🔴 **kind 분기 밖이다.** `{p,b,v,w,c,k}` 는 사건 종류와 무관하게 매 결정 epoch 에
    #    정의돼야 하는 상태다. battery 분기 안에 두면 zone·fault 판에서 두 축이 조용히
    #    사라지고, 프롬프트는 그 부재를 표시하지 않는다(= 상태가 아니라 배터리 부록이 된다).
    merge!(d, _smdp_state_features())
    if truth isa CB.BatteryTruth
        d["soc"] = Float64(truth.soc_after); d["severity"] = Float64(truth.soc_after)
        # 2026-08-31 (S1/T2): 적재/함대 사실. 값이 없으면 키가 아예 안 생긴다.
        merge!(d, _battery_load_features(env, agent))
    elseif truth isa CB.ZoneTruth
        local ov = _zone_overlap(env, truth.zone)
        d["zone_overlap"] = ov; d["severity"] = ov
        d["zone_radius"] = try Float64(CB.get_radius(CB.RESTRICTION_ZONES[][truth.zone])) catch; nothing end
        # STEP 3: 기하 **원시값**. zone_overlap 스칼라 하나로는 "무엇이 왜 막혔는가"를 말할 수 없어
        # 정책이 사실상 종류 이름만 보고 답할 수밖에 없었다. 진단기가 이미 계산한 술어를 그대로 준다.
        # ★ 최소수복 판정(verdict)은 **주지 않는다** — 그건 정답이라 오라클·게이트의 것이고,
        #   주는 순간 정책은 추론이 아니라 답을 읽게 된다(zone_diagnosis.jl 의 note).
        local zdg = try CB.ablation_exempt(:policy_payload) do
                CB.zone_diagnosis(env, truth.zone)
            end catch e
            @warn "[policy] zone_diagnosis failed -> 원시값 없이 진행" exception = e; nothing
        end
        if zdg !== nothing && zdg.exists
            d["zone_blocked"]           = zdg.n_blocked            # 구역이 덮은 미개시 조립체 수
            d["zone_restage_feasible"]  = zdg.n_restage_feasible   # 그중 옮길 자리가 있는 수
            d["zone_root_covered"]      = zdg.root_covered         # 갇힌 root 하역목표 수
            d["zone_root_total"]        = zdg.root_total
            d["zone_work_overlap"]      = zdg.n_work_overlap       # 겹친 미완 작업 디스크 수
            d["zone_teams_forming"]     = zdg.n_teams_forming      # 지금 형성 중인 운반팀 수
            d["zone_teams_covered"]     = zdg.n_teams_covered      # 그중 구역에 갇힌 팀 수
            d["zone_relocatable"]       = zdg.relocate_feasible    # 벗어날 강체이동이 존재하는가
            d["zone_relocate_norm"]     = isfinite(zdg.relocate_norm) ? zdg.relocate_norm : -1.0
            # ---- 막힘(blockage) 원시값 (2026-08-05) -------------------------------------
            # 위의 값들은 전부 **덮임**(coverage)이다. STEP 6 이 실측으로 보인 것: 덮임은 해로움이
            # 아니다(root 하역목표 8/8 을 삼켜도 완주했고 시간만 2.1배). 구역이 강제되는 곳은
            # enforce_restriction_zone_clearance! 한 곳뿐이고 거긴 **RVO 에이전트만** 스냅하므로,
            # 화물을 직접 옮기는 LiftIntoPlace 목표는 원리적으로 못 막힌다(zone_corridor.jl 상단).
            # 그래서 "막을 수 있는 목표"와 "그중 실제로 막힌 것"을 따로 싣는다. zone_diagnosis 가
            # 이미 계산해 둔 값이라 추가 계산 비용은 0이다. (-1 = 계산 안 됨 → 싣지 않는다.)
            if zdg.n_nav_goals >= 0
                d["zone_nav_goals"]        = zdg.n_nav_goals         # 막힐 수 있는 목표의 모수
                d["zone_nav_blocked"]      = zdg.n_nav_blocked       # 그중 지금 못 닫는 것
                d["zone_nav_engulfed"]     = zdg.n_nav_engulfed      #   포획볼이 배제원 안(확정)
                d["zone_nav_disconnected"] = zdg.n_nav_disconnected  #   목표는 비었는데 길이 끊김
                d["zone_agent_trapped"]    = zdg.n_agent_trapped     # 구역 안에 주차된 이동체 수
                # 막힌 노드 뒤에 걸려 함께 얼어붙는 미완 작업의 양. 이 값이 없으면 "120개 중 1개"가
                # 1/120 의 피해로 읽힌다 — 실측(2026-08-05): 두 LLM 프로그램이 모두 그렇게 읽고
                # "minimal impact, only one navigation goal" 이라며 NOOP 을 골랐다.
                d["zone_nav_downstream"]   = zdg.n_nav_downstream
                d["zone_unfinished_total"] = total - closed          # 위 값을 견줄 분모
                # ---- 종단성(terminality). 비율이 아니라 술어다 (2026-09-05) ----------------
                # 🔴 왜 이 칸이 필요한가(실측). 2026-09-05 의 두 라이브 zone 판에서 모델은
                #    NOOP 을 고르며 *"the exclusion zone minimally impacts the build"* 라고
                #    적었다. 그 판의 정답은 **완주 실패**다(tool-off 대조: PROJECT INCOMPLETE,
                #    270/305, t=5776). 프롬프트가 준 가장 강한 막힘 신호는
                #    `work frozen by those = 32` / `unfinished total = 251` 이었고, 그것은
                #    비율로 13% 라 "대부분 멀쩡하다"로 읽힌다 — 그리고 그 읽기는 **비율로서는
                #    틀리지 않았다**. 세계가 실제로 가진 사실은 비율이 아니라 술어였다:
                #    `project_complete(env)` 가 요구하는 ProjectComplete 정점이 막힌 노드의
                #    후방 폐포 안에 있다 = 구역이 사는 한 완주 판정은 원리적으로 불가능하다.
                # 🔴 삼상: `zone_diagnosis` 가 `nothing` 을 내면(막힘을 안 쟀다) **키를 안 싣는다**.
                #    false 로 접으면 "재 봤더니 완주는 안 막혔다"로 읽혀 정확히 반대의 거짓이 된다.
                # 🔴 판정(verdict)이 아니다 — 이건 선후행 그래프 사실이고, 무엇을 하라는 말은
                #    한 글자도 붙이지 않는다(zone_diagnosis.jl 의 note 와 같은 규약).
                if zdg.project_blocked !== nothing
                    d["zone_project_blocked"]         = zdg.project_blocked
                    d["zone_project_nodes_blocked"]   = zdg.n_completion_blocked
                    d["zone_project_nodes_open"]      = zdg.n_completion_open
                end
            end
        end
    else
        d["severity"] = 1.0
    end
    return d
end

"""
> 2026-08-24: 아래 zone 논의는 **역사 기록**이다. zone 은 LLM 결정 레인에서 제거됐고
> (spec §5.1) 이 함수에 zone 분기는 더 이상 없다.

    valid_macros(env, truth) -> Vector{String}

이 사건에서 **실제로 무언가를 할 수 있는** 매크로들. 빈 벡터를 돌려주면 서비스가 kind 별 기본표를 쓴다.

왜 여기서 계산하는가(2026-08-05 회귀 수정): legal 을 kind 로만 정하면 전제조건이 있는 팔을 표현할
수 없다. `ForbidZone`(→ `restage_all_blocked!`)은 **아직 시작하지 않은** 조립체의 적치원만 옮길 수
있어서, 빌드 중반에는 도메인이 비어 NOOP 과 같아진다. 그 사실 때문에 2026-08-03 에 zone 어휘가
`[NOOP, RelocateBuild]` 로 바뀌었는데(오라클 라벨링 기준으로는 옳다), 그 바람에 **데모의 zone 사건도**
전부 빌드 전체를 통째로 옮기는 RelocateBuild 로 답해졌다. 데모의 zone 은 정확히 반대 상황이다 —
주입기(inject_staging_zone!)가 **아직 시작 안 한** 조립체를 골라 심으므로 국소 재적치가 언제나 가능하다.
실측 결과 전역 이동은 조립이 시작된 뒤 |Δ|=3.19 m 로 판을 통째로 옮겨 운반체가 교착됐다
(streams/tractor__zone.jsonl 264/287 미완주 · ForbidZone 으로 답하던 옛 녹화는 전부 287 완주).

그래서 **구역이 조립체를 지목했으면 ForbidZone 을 메뉴에 되돌린다**. RelocateBuild 는 전제조건이
없으므로 항상 남겨 둔다(중앙 core zone 처럼 국소 재적치로는 못 푸는 경우가 실재한다). 둘 다 legal 일
때 무엇을 고를지는 정책(LLM/surrogate)의 몫이고, 고른 뒤의 안전은 dispatcher 가 책임진다 —
ForbidZone 은 restage 로 안 풀리면 `:residual_blocked` 에서 자동으로 whole-build 이동으로 격상된다.

**"도메인이 비면 빼자"는 처음 시도했다가 실측으로 접었다(2026-08-05)**: 이 데모의 존은 sim 전에
미시작 조립체를 골라 심지만 respec 이 처리되는 시점(closed≈54)은 이미 첫 배치 경계(46) 뒤라
`zone_blocked_assemblies` 가 **항상 비어 있다**. 그 게이트를 쓰면 공간형 팔이 RelocateBuild 하나만
남아 지금 고치려는 회귀가 그대로 재현된다. 그리고 같은 seed·같은 존으로 매크로만 교차해 재보면
도메인이 빈 ForbidZone(= 사실상 no-op)이 **closed 231 · 조립체 7/8**, 전역 이동이 **closed 136 ·
조립체 1/8** 이다. 싼 팔이 이 트윈에서 명백히 우세하므로 메뉴에서 지울 이유가 없다. 대신 실행부가
실제로 한 일은 verdict 에 그대로 남는다(`navigation detour · moved 0`) — 조용한 no-op 을 성공으로
포장하지 않는다는 8/3 의 문제의식은 어휘가 아니라 **보고**로 지킨다.
"""
function valid_macros(env, truth)
    # ---- battery: SwapBattery 를 메뉴에 올린다 (2026-08-06, Ch-A) --------------------------
    # 이 함수는 zone 이 아니면 빈 목록을 돌려주고 서비스의 kind 기본표에 맡겼는데, 그 기본표에
    # SwapBattery 가 없었다. 그래서 **라이브 데모의 배터리 사건에서는 현장 배터리 교체(cost 0.2)를
    # 정책이 고를 수조차 없었고**, 방전된 로봇을 살리려면 창고 본체를 먹는 Replace(1.0) 뿐이었다.
    # 두 팔의 소모 자원이 다르다는 것이 SwapBattery 를 따로 둔 이유이므로(spec_dsl.jl), 그 선택을
    # 지우면 battery 사건에서 잴 수 있는 결정 구조 자체가 사라진다.
    # 전제조건: 배터리 레이어가 켜져 있어야 SoC 복구가 의미를 갖는다. 없으면 메뉴에서 뺀다.
    # 🔴 2026-08-25 (최종 브랜치 리뷰 C2): 이 메뉴는 하드코딩 튜플
    # `["NOOP","Replace","SwapBattery"]` 였다. 판정 R-46 이 같은 파일의 `enactable_macros()`
    # 를 레지스트리 파생으로 고쳤지만 **420줄 위의 이 진짜 메뉴는 그대로 남았다.** 실측:
    # `ACTION_REGISTRY=` 를 이름 바꾼 레지스트리로 돌리면 `enactable_macros()` 는 따라가고
    # `valid_macros` 는 안 따라간다 — 에러 없이. 그런데 이 반환값이 곧 LLM 의 메뉴
    # (`service_decide` 의 payload["valid"]) · oracle/canonical 규칙의 메뉴 · 채점기가 읽는
    # 결정 기록의 `valid` 필드(`run_demo.jl`)다. 즉 어휘의 **하중을 받는** 사본이었다.
    # `enactable_macros()` 와 같은 로더로 유도한다.
    if truth isa CB.BatteryTruth
        local have_fleet = (try CB.BATTERY_FLEET[] !== nothing catch; false end)
        # ---- SoC 분할: 라벨 레인과 **같은 함수**를 쓴다 (2026-08-25) ---------------------------
        # 여기는 `kind_valid("battery")`(= 상한) 를 그대로 냈고, 라벨 레인
        # (`ood_mdp_shim.valid_actions`)만 SoC 로 메뉴를 갈랐다. 즉 같은 사건에서 라벨을 만든
        # 세계와 실제로 굴린 세계의 **행동공간이 달랐다**: mild 에서 이 레인은 `Replace` 를 고를
        # 수 있는데 라벨 격자엔 그 행이 없어, 그 결정이 surrogate 가 본 적 없는 팔로 남는다.
        # 분할 규칙과 손잡이 판독점을 어휘 단일 진실원으로 올렸다(`ActionRegistry.battery_arms`
        # · `soc_split_enabled`). 게이트: `test/battery_menu_lanes_agree.jl`.
        # policy.jl 은 navigator.jl 이 로드된 뒤에만 include 된다(run_demo.jl/render_demo.jl/
        # test_policy_{zone,oracle}.jl 이 전부 이 순서를 지킨다) — 심볼이 없으면 이제
        # UndefVarError 로 죽는다(2026-08-31 폴백 제거).
        local thr = Float64(CB.REPLACE_SOC_THRESHOLD[])
        local ids = ActionRegistry.battery_arms(Float64(truth.soc_after), thr,
                                                ActionRegistry.soc_split_enabled())
        if !have_fleet
            # 전제조건: 배터리 레이어가 켜져 있어야 SoC 복구가 의미를 갖는다. 꺼져 있으면
            # **battery 사건에서만** 말이 되는 팔(레지스트리의 `kinds` 가 battery 하나뿐인
            # 팔 = 오늘의 SwapBattery)을 뺀다. 다른 kind 에도 붙는 팔(NOOP·Replace)은 "로봇
            # 하나가 멈췄다" 는 사실만으로 성립하므로 남는다.
            # 이름을 리터럴로 적지 않는 이유는 위 주석 그대로다 — 어휘의 단일 진실원은
            # `action_registry.json` 이고, 리터럴은 그것의 두 번째 진실원이 된다.
            ids = [i for i in ids if length(collect(ActionRegistry.REGISTRY[i].kinds)) > 1]
        end
        return [ActionRegistry.NAME[i] for i in ids]
    end
    # 🔴 2026-08-24 (spec §5.1, Task 4): 여기 있던 `truth isa CB.ZoneTruth` 분기를 통째로 지웠다.
    # 그 분기는 `named`/`zone_diagnosis(...; check_restage=true)` 로 도메인을 재서
    # `["NOOP","ForbidZone","RelocateBuild"]` 또는 `["NOOP","RelocateBuild"]` 를 냈다 — 즉 zone 을
    # **LLM 이 결정할 사건**으로 만드는 자리였다. zone 은 이제 surrogate 학습 증거로만 쓰고
    # 결정 epoch 를 만들지 않는다. 위 docstring 의 zone 논쟁은 역사로 남겨 뒀다.
    # 🔴 2026-08-24 (spec §5.4, Task 5): `Deprioritize` 를 이 메뉴에서 뺐다. 배터리 사건의 개입
    # 팔은 이제 `Replace`(창고 예비 본체를 먹음)와 `SwapBattery`(현장 교체) 둘뿐이고, 배터리
    # 레이어가 꺼져 있으면 `Replace` 하나다.
    # ---- zone: 닫힌 어휘에 수복이 없다는 사실을 **메뉴로** 말한다 (2026-08-25) ---------------
    # Task 4 가 zone 분기를 지운 뒤 이 함수는 zone 에 `String[]` 을 돌려줬고, 그러면
    # `service_decide` 가 `payload["valid"]` 를 안 실어 서비스의 `_valid_for` 가
    # `VALID.get("zone", MACROS)` 로 **전체 3팔로 폴백**한다(레지스트리에 zone 키가 없으므로).
    # 실측(2026-08-25, gpt-4o): 구역 사건에서 LLM 이 `SwapBattery` 를 2순위로 올렸다. 그 팔은
    # `ZoneTruth` 에 `:robot` 이 없어 집행 사슬의 가드에 걸려 **아무 일도 안 하는데**, 결정
    # 기록에는 그 이름이 그대로 남는다 = 집행되지 않은 팔이 라벨이 된다.
    #
    # 그래서 정직한 메뉴를 명시적으로 낸다. 오늘 그 값은 `["NOOP"]` 이고, 뜻은 **"닫힌 어휘에
    # 이 구역의 수복이 없다"**(= `zone_diagnosis` 의 `:line_stop`). 이건 결함이 아니라 OOD 경계
    # 표식이고, 아래 `decide_all` 의 표현력 에스컬레이션이 붙잡아야 할 바로 그 신호다
    # (L2 제약 신설 레인이 인계받을 자리). 어휘에 zone 팔이 다시 생기면 자동으로 따라온다.
    #
    # 규약은 `ood_mdp_shim._zone_arms()` 와 **같다**(NOOP + 레지스트리의 zone 팔) — 두 레인이
    # 다른 규약을 쓰면 라벨 레인과 실행 레인의 메뉴가 갈린다.
    # 게이트: `test/policy_macro_binding.jl` (E).
    if truth isa CB.ZoneTruth
        return [ActionRegistry.NAME[i]
                for i in sort(unique(vcat(0, ActionRegistry.kind_valid(:zone))))]
    end
    return String[]          # 그 외 종류는 서비스 기본표 그대로
end

"""
    event_descriptors_of(env, truth) -> Vector{Float64}

종류 이름 없이 계산되는 물리 서술자 6개
`[harm, work_at_risk, resource_loss, recovery_capacity, progress, slack]`.

**이게 LLM 에게 문장과 함께 주는 숫자다.** 종류를 안 읽으므로 처음 보는 사건에도
그대로 계산된다 -- 새 DSL 종류를 발명할 필요 없이 숫자 6개만 채우면 되는 개방세계 경로.
🔴 **2026-08-29 (§B-1): "라우터의 입력" 이라는 말은 이제 거짓이다** — 이 값을 읽어 레인을 정하던
novelty 축이 삭제됐고, 오늘 레인을 정하는 것은 `routing_kind` 하나다. **이 함수는 그대로 남는다**:
LLM 페이로드(`descriptors`)가 이 값이고, 그 채널이 사라지면 LLM 은 문장 한 줄만 받는다
(2026-08-26 의 회귀, `test/route_descriptors_survive.jl`).
파이썬 features_agnostic.descriptors_from_row 와 계산이 같아야 교정이 의미를 갖는다(novelty.jl 주석) —
그 계약은 `tools/test_novelty.jl` 이 1e-9 로 대조하며 novelty **라이브러리**의 계약으로 살아 있다.
"""
function event_descriptors_of(env, truth)
    f = ood_features(env, truth)
    total = length(CB.get_nodes(env.sched))
    return CB.event_descriptors(;
        soc            = get(f, "soc", NaN),
        agent_pending  = get(f, "agent_pending", -1.0),
        zone_overlap   = get(f, "zone_overlap", -1.0),
        severity       = get(f, "severity", 0.0),
        n_active       = get(f, "n_active", 1.0),
        spare_count    = get(f, "spare_count", 0.0),
        closed_at_fire = get(f, "closed_at_fire", 0.0),
        total_nodes    = total,
        progress       = get(f, "progress", 0.0),
        # 🔴 2026-08-31 (S1/T1). `ood_features` 가 이미 싣는 값이다 — 새 계산이 없다.
        #    없으면 `-1.0`(못 쟀다)이고, 그때 서술자는 옛 공식으로 폴백한다.
        nav_blocked    = get(f, "zone_nav_blocked", -1.0),
        nav_downstream = get(f, "zone_nav_downstream", -1.0))
end

"""
    route_verdict(; desc, policy, drives_lane=router_drives()) -> Dict

라우팅 **기록** Dict 를 만든다. 키는 셋뿐이다: `"descriptors"` · `"drives_lane"` · `"reason"`.

🔴 **세대 표식 (2026-08-29, §B-1).** 이 함수는 그날까지 세 분기(교정 없음 · 서술자 없음 · 실제
novelty 판정)로 갈리며 `enabled`·`advisory`·`novel`·`novelty_measured`·`p`·`score`·`eps`·
`would_route_to`·`target` 을 함께 냈다. 그 축(covariate novelty)이 T11 에서 결정과 끊기고
§B-1 에서 삭제됐으므로 **분기 자체가 없어졌다.** 🔴 옛 녹화에 있는 그 키들의 부재는 "값이 없다"
가 아니라 **"세대가 다르다"** 다. 특히 `target` 은 **자리를 옮겼다** — 이제 `decide_all` 이
레인을 고른 직후에 쓴다(그 줄의 Ruling R2 주석이 두 세대의 뜻 차이를 적는다).

  · `descriptors` = 이 사건의 서술자 6개. 🔴 **교정 유무와 무관하게 실린다** —
    `event_descriptors_of` 는 감지기를 안 읽는다(그 docstring). 이것이 LLM 페이로드의 숫자
    채널이고, 그래서 novelty 축이 사라져도 이 계산은 그대로 산다. `desc === nothing`
    (계산 실패)일 때도 **키를 지우지 않는다** — "못 쟀다" 와 "안 실었다" 는 다른 사건이고,
    키가 없으면 소비처가 둘을 구분할 수 없다(2026-08-26).
  · `drives_lane` = 라우터가 이 런에서 레인을 고르는가(`router_drives()`; 사람이 켠 손잡이만).
  · `reason`      = 화면(`dashboard.html`)과 `run_demo.jl` 이 그대로 읽는 유일한 산문.

🔴 `reason` 이 `drives_lane` 을 보는 이유 (2026-08-27, 최종 리뷰 F3): 라우터가 레인을 몰고 있으면
"gate inactive" 도 "DEMO_POLICY=… fixed for the run" 도 **거짓이다.** 예전에 그 두 문장을 무조건
적었고 `dashboard.html` 이 그 문자열로 `ROUTER off` 를 렌더했다 — 라우터가 **실제로 레인을 고른
판에 대해.** 음성 대조까지 `tools/test_policy_escalation.jl` 의 T12/T12b/T12c 가 못박는다.

⚠️ `drives_lane` 의 기본값은 `router_drives()` 다(= `route()` 가 넘길 필요가 없다). 검사에서만
명시적으로 준다 — `ROUTER_MODE`/`POLICY` 가 `const` 라 같은 프로세스에서 ENV 로는 못 가른다.
"""
function route_verdict(; desc, policy::AbstractString,
                       drives_lane::Bool = router_drives())
    return Dict{String,Any}(
        "descriptors" => desc,
        "drives_lane" => drives_lane,
        "reason" => drives_lane ?
            "the router selects the lane (DEMO_ROUTER=$(ROUTER_MODE))" :
            "gate inactive (DEMO_POLICY=$(policy) fixed for the run)")
end

"""
    tool_choice_for(; novelty_measured::Bool, novel::Bool) -> Union{Nothing,String}

🔴 **생산 호출자가 0개다 (2026-08-29, 단일 채널 / T6).** 그리고 그것보다 강한 말이 필요하다:

  🔴 **이 게이팅은 더 이상 작동하지 않는다.** "함수가 안 불릴 뿐" 이 아니라, 불러도 아래
     진리표의 **세 행이 프로바이더 요청에서 한 값으로 붕괴한다** — T5 가 서비스의
     `TOOL_CHOICE_DEFAULT` 를 `"required"` 로 세웠으므로 `nothing`("그 키를 안 보낸다")이
     이제 **강제와 같은 뜻**이다. 강제를 끄는 자리는 이 함수가 아니라 서비스 호스트의
     `DSPY_TOOL_CHOICE` 하나다.

  ⚠️ 그래서 `test/tool_choice_gate.jl` (1)절이 **초록인 것을 "강제가 게이팅된다"의 증거로
     인용하지 말 것.** 그 절은 이 순수 함수의 반환값만 재고 그 **효과**는 안 잰다 — 같은
     종류의 함정을 이 레포는 이미 두 번 밟았다(소스만 읽는 게이트 셋, `tool_args_grounding.jl`).
     효과를 재는 것은 같은 파일 (3)절이고, 그 절은 T6 뒤 "**어떤 사건에서도 안 싣는다**" 를
     못박도록 다시 쓰였다.

  🔴 **함수와 진리표 시험은 남긴다** — 되돌릴 때(강제를 다시 라우터에 물릴 때) 필요하고,
     그때 필요한 것은 유도 규칙 자체이지 배선이 아니다.

이 사건의 `/decide` 요청에 실을 `tool_choice` 값. `nothing` 이면 **그 키를 아예 안 보낸다**.
의존성 0 — Bool 둘만 본다.
(옛 괄호 *"= 2026-08-29 이전과 바이트 단위로 같은 요청"* 은 **T5 이후 거짓이다** — 위 참조.)

| `novelty_measured` | `novel` | 결과 | 왜 |
|---|---|---|---|
| `false` | (무관) | `nothing` | **못 쟀다.** 강제는 `expressible` 을 지우므로, 모르는 채로 지우면 안 된다 |
| `true`  | `true`  | `nothing` | **낯설다** = unfamiliar OOD. 합성 레인(T2)의 유일한 방아쇠가 `expressible == false` 라, 강제해서 그 필드를 비우면 T2 가 영원히 안 돈다 |
| `true`  | `false` | `"required"` | **익숙하다.** 기존 tool 중 하나를 고르는 것이 전부인 사건이라, 호출을 요구해 `tool_called` 를 얻는다 |

🔴 **실측이 무조건 강제를 반증했다** (2026-08-28~29, 컨트롤러의 짝지은 유료 A/B — 같은 요청 ·
같은 빌드 · `DSPY_TOOL_CHOICE` 만 다르게). `required` 판에서 프로바이더가 tool 호출만 내고
message content 를 **비웠다**: `reasoning=""` · `expressible=null` · `chosen==""` 이 `coerced`
로 NOOP 이 됐다. 예외가 안 나므로 spec §4-1 의 `AdapterParseError` 구제는 **발화조차 안 한다.**
즉 **한 번의 호출로 두 채널을 같이 받을 수 없다.** 그래서 강제는 "고를 것만 남은" 사건에만 건다.

🔴 **한계 두 개 — 반드시 읽을 것.**

  ① 이 게이트는 **novelty 축 하나만** 본다. 어휘 미달 축(축 1)은 `escalation_target(pol, ...)`
     이 필요하고 `pol` 은 **바로 이 호출의 응답**에서 온다 — 요청을 만드는 시점에는 존재하지
     않는다(순환). ⟹ **novelty 로는 familiar 인데 어휘가 미달인 사건은 그대로 강제된다.**
  ② 원리적으로는 `/health` 의 `surro_support`(`dspy_service.py:939`, 기계가 읽는 목록)를
     요청 **전에** 읽어 축 1 을 사전 해소할 수 있다. **이번 범위 밖이다** — 구현하지 않았고,
     여기 한계로만 적는다.

🔴 **이 두 인자가 가리키던 novelty 축은 2026-08-29 §B-1 에서 삭제됐다** — `route_verdict` 는
`novelty_measured` 도 `novel` 도 더 이상 내지 않는다. 그래도 이 함수는 남긴다(위 "되돌릴 때
필요하다"): 그때 필요한 것은 유도 규칙이지 배선이 아니다. 🔴 다만 **되돌리려면 novelty 축 자체를
먼저 되살려야 한다** — 오늘 이 두 인자를 채워 줄 생산자가 레포에 하나도 없다.
"""
tool_choice_for(; novelty_measured::Bool, novel::Bool) =
    (novelty_measured && !novel) ? "required" : nothing


"""
    route(env, truth) -> Dict

이 사건의 **기록**을 만든다: LLM 페이로드가 읽는 서술자 6개 + 라우터 손잡이 상태.
돌려주는 Dict 는 그대로 monitor 레코드에 실려 UI 의 ROUTER 줄이 된다.

🔴 **이 함수는 더 이상 레인을 정하지 않는다 (2026-08-29, §B-1).** 레인을 정하는 것은 `decide_all`
의 `select_lane(kind = routing_kind(...), ...)` 한 줄이다. 이름이 남은 것은 소비처(`rt` ·
monitor 스트림 · dashboard 의 ROUTER 줄)가 이 Dict 를 그대로 읽기 때문이다.
[역사] 2026-07-28~2026-08-29 에는 여기서 covariate novelty p 를 계산해 `p < eps ? "dspy" :
"surrogate"` 로 보냈다(`install_novelty!()` → `CB.novelty_verdict` → `route_verdict`). T11 이
kind 색인 라우터로 그 판정을 갈아치웠고, §B-1 이 남아 있던 계산과 기록을 지웠다.
"""
function route(env, truth)
    # 🔴 서술자는 **항상** 계산한다. 교정값(novelty 감지기)을 안 읽으므로 라우터 설정과도
    # 무관하다(`event_descriptors_of` 의 docstring). 이것이 LLM 이 문장과 함께 받는 숫자
    # 채널이고, 이 계산이 조기 반환 **뒤에** 있어서 모든 LLM 결정이 문장 한 줄로 내려갔던 것이
    # 2026-08-26 의 회귀다 — `test/route_descriptors_survive.jl` 이 그 순서를 못박는다.
    desc = try event_descriptors_of(env, truth) catch e
        # 🔴 2026-08-29 (§B-1 fix round 1): 문구가 "-> router falls back" 이었다. **폴백하는 것이
        #    없다** — 옛 판에서는 이 실패가 novelty 판정을 못 하게 만들어 `route()` 가 조기 반환
        #    분기로 떨어졌는데, 그 분기가 삭제됐다. 오늘은 `desc = nothing` 이 그대로 실려 나가고
        #    (`route_verdict` 가 키를 안 지운다), 결과는 **LLM 이 숫자 채널을 못 받는 것**이다.
        @warn "event descriptor computation failed -> descriptors=nothing for this event " *
              "(the LLM payload loses its numeric channel; the lane is unaffected)" exception = e
        nothing
    end
    return route_verdict(desc = desc, policy = POLICY)
end

const DSPY_HEALTHY = Ref{Union{Nothing,Bool}}(nothing)

# ---- surrogate 의 kind 지원집합 (2026-08-29, T11) --------------------------------------------
# `/health` 본문의 `surro_kinds` 를 캐시한다. 🔴 **HTTP 호출은 한 건도 안 는다** —
# `dspy_ready()` 는 이미 `/health` 를 부르고 본문을 버리고 있었다. 그 본문을 읽을 뿐이다.
#
# ⚠️ 실패와 "아직 안 물었다" 를 가르는 것은 `DSPY_HEALTHY[]` 다 — `SURRO_KINDS[]` 의 `nothing`
#    은 언제나 **"못 쟀다"** 하나만 뜻한다(서비스가 없다 · 키가 없다 · 키가 null 이다).
#    `Set(String[])` 은 "쟀는데 비었다" 로 **다른 사건**이다. `select_lane` 이 그 둘을 가른다:
#    앞의 것은 죽고, 뒤의 것은 전부 dspy 로 간다.
const SURRO_KINDS = Ref{Union{Nothing,Set{String}}}(nothing)

"서비스 `/health` 의 `repair_ablation`(존 복구 base ablation). `nothing` = 못 읽었다."
const SERVICE_REPAIR_ABLATION = Ref{Union{Nothing,String}}(nothing)

"🔴 기동 단언: 서비스 레벨이 이 판의 레벨과 다르거나 못 읽으면 **첫 결정 전에** 죽는다."
function assert_service_repair_ablation()
    dspy_ready() || error("[ablation] DSPy service not ready at $(DSPY_URL) — cannot verify repair_ablation")
    got = SERVICE_REPAIR_ABLATION[]
    want = String(CB.REPAIR_ABLATION[])
    got == want || error("[ablation] service repair_ablation=$(repr(got)) != julia $(repr(want)) at $(DSPY_URL)")
    return nothing
end

"""
    surro_kinds() -> Union{Nothing,Set{String}}

surrogate 가 학습셋에서 본 kind 집합. `dspy_ready()` 가 `/health` 응답에서 캐시한다.
`nothing` = 못 쟀다 — `select_lane` 은 그때 **고르지 않고 죽는다**(§0-C 결정 3).

🔴 손으로 쓴 kind 목록을 여기에 두지 않는다. 서비스 쪽 `_load_surrogate` 가 **학습행에서**
유도하고(`test_surro_kinds.py` 의 리터럴 스캔이 그것을 지킨다), 줄리아는 그 값을 나르기만 한다.
두 번째 진실원을 만들면 학습셋이 바뀌어도 라우터가 안 따라간다.
"""
function surro_kinds()
    dspy_ready()            # 아직 안 물었으면 여기서 물어 캐시한다
    return SURRO_KINDS[]
end

"DSPy 서비스가 살아 있는지 한 번만 확인해 캐시한다(매 이벤트마다 찌르지 않도록)."
function dspy_ready()
    DSPY_HEALTHY[] === nothing || return DSPY_HEALTHY[]
    ok = try
        r = HTTP.get(DSPY_URL * "/health"; readtimeout = 5, retries = 0)
        if r.status == 200
            # 🔴 본문을 **여기서** 읽는다. 별도 호출을 만들면 이벤트당 HTTP 가 는다.
            #    파싱 실패는 "못 쟀다"(nothing)이지 서비스 장애가 아니다 — 두 값을 따로 둔다.
            # 🔴 2026-09-23 (Task 12 버그 수정): 본문은 **한 번만** 파싱한다 — `String(::Vector{UInt8})`
            #    는 바이트 벡터의 소유권을 가져가 비운다(Base 계약). 두 번째 `String(r.body)` 로
            #    다시 읽으면 빈 문자열을 파싱하게 되어 항상 던지고, `SERVICE_REPAIR_ABLATION[]` 가
            #    조용히 `nothing` 으로 떨어져 `assert_service_repair_ablation()` 이 매 라우터 런에서
            #    거짓으로 죽었다. `JSON3.read` 는 바이트 벡터를 직접 받으므로 `String(...)` 변환
            #    자체가 불필요하다.
            local h = try
                JSON3.read(r.body)
            catch
                nothing
            end
            SURRO_KINDS[] = try
                local ks = h === nothing ? nothing : get(h, :surro_kinds, nothing)
                ks === nothing ? nothing : Set(String.(ks))
            catch e
                @warn "[router] /health surro_kinds unreadable -> kind support unknown" exception = e
                nothing
            end
            SERVICE_REPAIR_ABLATION[] = try
                local ra = h === nothing ? nothing : get(h, :repair_ablation, nothing)
                ra === nothing ? nothing : String(ra)
            catch; nothing end
        end
        r.status == 200
    catch; false end
    DSPY_HEALTHY[] = ok
    # 🔴 2026-08-29 (Ruling R13): 문구가 `-> falling back to canonical` 이었다. **T11 이후
    #    canonical 폴백은 없다.** 서비스가 안 뜨면 위 `SURRO_KINDS[]` 가 `nothing`("못 쟀다")으로
    #    남고, 라우터가 도는 런은 `lane_select.jl` 의 `select_lane` 이 그 자리에서 판정을
    #    **거부하며 죽는다**(§0-C 결정 3 — 조용히 한쪽으로 떨어지면 그 런의 모든 행이 근거 없이
    #    "라우팅했다" 로 기록되므로 일부러 죽인다. `decide_all` 의 `surro_kinds()` 줄 주석 참조).
    #    계속 도는 것은 라우터가 꺼진 런(`DEMO_ROUTER=0` / `DEMO_POLICY=noop`)뿐이고, 그것은
    #    줄리아가 자기가 계산하는 레인이라 서비스가 필요 없다.
    #    옛 문구의 대가가 실제였다: 밤샘 스윕에서 이 줄을 보고 "폴백했겠지" 로 읽으면 실제로는
    #    죽은 런을 찾는 데 시간을 버린다.
    ok || @warn "DSPy service unreachable at $DSPY_URL -> surro_kinds unknown; a router-driven " *
                "run will DIE at select_lane (there is NO canonical fallback since T11). " *
                "Only DEMO_ROUTER=0 / DEMO_POLICY=noop runs can continue."
    return ok
end

# =============================================================================
# 🔴 원장 신원 (2026-09-22, retry-body 보존 Phase 1 / Task 4)
# =============================================================================
"""
    RUN_CTX

이 프로세스가 도는 **판의 신원**. `render_demo.jl` 이 스트림 경로를 정한 뒤 `set_run_ctx!` 로
한 번 채운다(키 목록의 정본은 그 호출이다: run_id·campaign_id·stream·case·event·zone·model·
lane·policy·router·seed·zone_seed·synth_fixture + `run_fingerprint` 의 세 키).
비어 있으면(시험·헤드리스) 원장 행의 `run_ctx` 가 `{}` 이고, 그것은 "모른다" 이다.

🔴 서비스는 seed·레인·판을 **모른다** — `MacroRequest` 에 필드가 없었고 페이로드도 안 실었다.
그래서 여기서 싣는다. 단순 `run_id`(예: `router__zone__s3`)는 모델 간에 겹치므로 **유일한
키가 아니다** — 조인은 이 dict 전체(campaign·모델·시드 둘·코드/설정 지문)로 한다.
"""
const RUN_CTX = Ref{Dict{String,Any}}(Dict{String,Any}())

"`RUN_CTX` 를 **통째로** 바꾼다(문자열 키). 인자가 없으면 비운다."
set_run_ctx!(; kw...) = (RUN_CTX[] = Dict{String,Any}(String(k) => v for (k, v) in kw); nothing)

const _RID_CTR = Threads.Atomic{Int}(0)

"""
    new_record_id() -> String

원장 행 id(24 hex). 🔴 **전역 RNG 를 안 쓴다** — `rand()` 한 번이 시뮬레이션의 추첨열을
밀어 같은 시드가 다른 세계가 된다. 시각·pid·프로세스 카운터의 SHA-256 이다.
🔴 **줄리아가 발급하는 이유:** `/decide` 는 `retries=3` 로 재전송된다. 서버가 만들면 한
결정이 다른 id 두 줄이 되고, 여기서 만들면 같은 id 두 줄이라 중복임이 보인다. 그 두 줄이
서로 다른 body 를 가질 수 있으므로 실제로 받은 응답은 서버가 처리마다 발급하는
`response_id` 와의 **쌍**으로 특정한다(`SYNTH_LANE_KEYS` 참조).
"""
new_record_id() = bytes2hex(SHA.sha256(string(time_ns(), "|", getpid(), "|",
                                              Threads.atomic_add!(_RID_CTR, 1))))[1:24]

"""
    _stamp_identity!(payload) -> payload

`/decide` 페이로드에 행 id 와 판 신원을 싣는다. 서비스는 그 둘을 원장 행에 찍는다.
🔴 `run_ctx` 는 `RUN_CTX[]` 의 **사본**이다 — 공유 dict 을 그대로 넣으면 페이로드 쪽 변경이
판 신원을 고치고, 뒤에 `set_run_ctx!` 가 돌면 이미 나간 페이로드의 기록이 흔들린다.
"""
function _stamp_identity!(payload::AbstractDict)
    payload["record_id"] = new_record_id()
    payload["run_ctx"]   = copy(RUN_CTX[])
    return payload
end

# =============================================================================
# 설정 지문의 ENV 분류 (2026-09-23, Task 6b · 외부 리뷰 R-B)
# =============================================================================
# render 경로(`src/**/*.jl`·`tools/monitor/*.jl`)가 읽는 **모든** ENV 이름은 아래 셋 중 하나에
# 명시돼 있어야 한다 — `test/config_digest_inventory.jl` 이 소스를 훑어 분류 안 된 이름이 나오면
# 빨개진다. 🔴 옛 규칙(접두사 안의 **설정된** env 만 해시)은 `RESTAGE_ZONE_MARGIN_FRAC` 을
# 0.5 → 1.5 로 바꿔도 지문이 같았다 — 엔진이 읽는 복구 손잡이가 접두사 밖에 있었다.
#   · result        결과를 바꾸는 이름. `name=<값 | "<unset>">` 으로 지문에 든다(`config_env`).
#                   판정이 애매하면 여기 둔다 — 잘못 넣은 대가는 지문이 조금 더 예민해지는 것뿐이다.
#   · cell_axis     셀 축·판 신원. `set_run_ctx!` 가 이미 따로 싣는다 → 지문에서 뺀다(셀 불변).
#   · observational 결과를 안 바꾸는 이름: 로그·디버그·출력 위치·포트·render 경로 밖 스크립트 전용.
# 새 손잡이는 만들 때 여기 등록한다. Phase 3 의 두 손잡이는 미리 result 로 넣었다.
const CONFIG_ENV_RESULT = [
    # 복구·재지정 손잡이 (접두사 밖 — R-B 가 짚은 구멍)
    "CARRIER_RESCUE", "ZONE_RESCUE", "RELOCATE_GATE", "ZONE_CAUSAL_RULE", "ZONE_DOMAIN_GATE",
    "ZONE_CHECK_PATHS", "RESTAGE_ZONE_MARGIN_FRAC", "RESTAGE_RING_STEP_FRAC",
    "RESPEC_DEPRIO_KAPPA", "ENERGY_OBJECTIVE", "SPARE_PRIORITY", "SPARE_DEPOT_DIST",
    "TEAM_PRIORITY", "USE_RESET", "LEGACY_RESTAMP", "OOD_NL_LEGACY", "LLM_NL_MODE", "CORE_FRAC",
    "REPAIR_ABLATION",         # 존 복구 base ablation 레벨(2026-09-23, 명세 §6) — none/translate/all
    # zone-repair-verification T8: off|shadow|enforce. shadow 는 원래 세계를 안 바꾸지만(시험이 잰다) enforce 는 활성
    # 세계를 commit worker 로 바꾼다 — 판의 의미가 갈리므로 result.
    "ZONE_REPAIR_VERIFICATION",
    # T9: 서비스 제안 source 의 팔(general|geometry)과 모델 예산(기본값 없음) — 결과를 바꾼다.
    "ZONE_REPAIR_ARM", "ZONE_REPAIR_MAX_TOTAL_TOKENS", "ZONE_REPAIR_MAX_COST_USD",
    # 최종 리뷰 C1·I3: 호출당 출력 상한과 observe/preflight worker wall(둘 다 기본값 없음) — 결과를 바꾼다.
    "ZONE_REPAIR_MAX_OUTPUT_TOKENS", "ZONE_REPAIR_PREFLIGHT_WALL_S",
    # 2026-09-23 레포 정리(100a7735)로 action_registry.jl 이 src/ 아래로 와서 스캐너 범위에 들어옴.
    # 둘 다 행동 어휘·메뉴를 바꾼다(레지스트리 경로 = 매크로 집합, SoC 분할 = battery 메뉴) → result.
    "ACTION_REGISTRY", "DS_BATTERY_SOC_SPLIT",
    # Phase 3 (Task 10·11) 예약 — 읽는 코드가 생기기 전부터 result 다
    "RESTAGE_NAV_BUFFER", "RESPEC_TRANSLATE_ON_INFEASIBLE",
    # 데모 동역학·사건 손잡이
    "DEMO_ANIM",               # save_animation 을 켠다 — 동역학 무관을 잰 적이 없으므로 result
    "DEMO_BATTERY_COURIER", "DEMO_BATTERY_STEPS", "DEMO_BSEVERE_FRAC", "DEMO_BSOC",
    "DEMO_COURIER_SPEED", "DEMO_DERATE", "DEMO_FAULT_SAFE", "DEMO_FAULT_STEPS",
    "DEMO_FORCE_MACRO", "DEMO_HAZARD", "DEMO_HAZARD_SEED", "DEMO_N", "DEMO_OOD_HI",
    "DEMO_OOD_LO", "DEMO_OOD_SEVFRAC", "DEMO_OOD_STREAM3",
    "DEMO_PROBE", "DEMO_PROBE_EVERY",   # 측정 fork 는 전역 RVO 를 오염시킨다(memory) — result
    "DEMO_REFORM", "DEMO_REFORM_MAX", "DEMO_ROBOTS", "DEMO_SPARES", "DEMO_STALL",
    "DEMO_STALL_SOC", "DEMO_SWAP_HALT", "DEMO_SYNTH_FIXTURE_KINDS", "DEMO_ZONE_AT",
    "DEMO_ZONE_CLOSED", "DEMO_ZONE_MODE", "DEMO_ZONE_PRESIM", "DEMO_ZONE_R", "DEMO_ZONE_R_MAX",
    "DEMO_ZONE_R_MIN", "DEMO_ZONE_SCALE",
    "MONITOR_INTERACTIVE", "MONITOR_REQUIRE_ZONE",   # 대화형 명령·존 요구는 판을 바꾼다
    # 정책·서비스
    "DP_GRID", "DP_VALUE", "DS_DEVIATE_ARM", "DS_DEVIATE_AT", "DSPY_TIMEOUT_S", "DSPY_URL",
]
const CONFIG_ENV_CELL_AXIS = [
    "DEMO_SEED", "DEMO_ZONE_SEED", "DEMO_OOD_SEED", "DEMO_OOD", "DEMO_ZONE", "DEMO_POLICY",
    "DEMO_ROUTER", "DEMO_MODEL", "DEMO_SYNTH_FIXTURE", "DEMO_CASE_TAG", "DEMO_CAMPAIGN_ID",
    "MONITOR_RUN_ID",
]
const CONFIG_ENV_OBSERVATIONAL = [
    # 출력 위치·로그·디버그
    "DEMO_OUT_DIR", "DEMO_SUMMARY", "DEMO_VERBOSE", "MONITOR_STREAM", "MONITOR_PORT",
    "MONITOR_WAIT", "MONITOR_COMMAND_FILE", "ANIM_FPS", "BATTERY_TINT_HOLD_FRAMES",
    "CB_VAR_DUMP", "NAV_DEBUG", "WEDGE_DEBUG", "REPLACE_DEBUG", "CARRIER_DIAG",
    "ORACLE_TRANSIT_DEBUG", "UNWEDGE_VERBOSE", "STALL_PROBE", "STALL_PROBE_OUT",
    # render 경로 밖 스크립트 전용(fit_rho · gen_ng1_pairs · check_grammar_roundtrip)
    "FIT_FILE", "FIT_MAXSTEP", "FIT_OUT", "FIT_ROBOTS", "FIT_SEED", "FIT_STALL",
    "NG1_N", "NG1_NGRID", "NG1_NMULT", "NG1_STEPS",
    "NG8_FORBIDAGENT_PROBE", "NG8_MAX_STEP", "NG8_OUT", "NG8_STEP_GRID",
    # 검증 하니스(zone-repair-verification T3, `src/verification/episode_replay.jl`) — 모드·출력·진단.
    # 동역학을 안 바꾼다(재생 게이트가 잰다) → 지문 제외.
    "ZRV_REPLAY_MODE", "ZRV_REPLAY_DIR", "ZRV_CHECKPOINT", "ZRV_TRACE_DETAIL", "ZRV_DIAG_INVENTORY",
    # T4 branch worker(`tools/monitor/repair_branch_worker.jl`) — 역할·분기 id·namespace 토큰·대기 한도·결과 위치·
    # 시험 탐침. `ZRV_BRANCH_ACTION` 은 분기 동작 파일이라 동역학을 바꾸지만 **같은 checkpoint 의 분기끼리 달라야**
    # 하는 값이다 — 지문에 넣으면 재개가 거절된다. 그 정체는 export 의 `action.file_sha256` 이 싣는다.
    "ZRV_BRANCH_ROLE", "ZRV_BRANCH_ID", "ZRV_BRANCH_TOKEN", "ZRV_BRANCH_ACTION", "ZRV_HOLD_MAX_S",
    "ZRV_RESULTS_DIR", "ZRV_PROBE_PORT", "ZRV_PROBE_PID", "ZRV_T4_HANG_WALL",
    # T6 격리 도구 집행 — 제안 파일(정체는 export 의 `enactment.proposal_sha256`)·모드·t0 계약 위치·후처리 실패 탐침.
    # ZRV_BRANCH_ACTION 과 같은 이유로 지문 밖이다.
    "ZRV_BRANCH_PROPOSAL", "ZRV_BRANCH_MODE", "ZRV_TASK_CONTRACT", "ZRV_PROBE_POSTPROCESS_FAIL",
    # 최종 리뷰 I5: 부모가 계산한 코드 신원 파일(분기는 git 을 못 읽는다 — 파일 digest 로 검증, `run_fingerprint`).
    "ZRV_CODE_IDENTITY",
    # T8 production 배선(`src/verification/repair_runtime.jl`) — fixture 후보 파일(정체는 certificate 의 제안 digest)·
    # 에피소드 출력 위치·campaign 인증 정지 파일 위치. ZRV_BRANCH_PROPOSAL 과 같은 이유로 지문 밖이다.
    "ZONE_REPAIR_PROPOSALS", "ZONE_REPAIR_DIR", "ZONE_REPAIR_CAMPAIGN_DIR",
    # 프로세스 기본값 — `BranchRunner.base_env` 가 worker 의 **새** env 에 그대로 옮긴다(설정 손잡이 아님).
    "HOME", "PATH", "USER",
]

# 보조 규칙: 이 접두사로 시작하는 **설정된** env 중 위 세 목록에 없는 것도 지문에 든다
# (예: `DS_HOTSWAP` — 줄리아 render 경로는 안 읽지만 같은 이름공간의 손잡이다).
const _CONFIG_ENV_PREFIXES = ("DEMO_", "DS_", "DSPY_", "TOOL_SYNTH", "SYNTH_")

# 설정 지문에서 **빼는** 키 = cell_axis ∪ observational (2026-09-22 R5a 의 셀 불변 규약을 잇는다).
const _CONFIG_ENV_EXCLUDED = Set([CONFIG_ENV_CELL_AXIS; CONFIG_ENV_OBSERVATIONAL])

# 드라이버가 campaign 마다 **명시** export 하는 복구 손잡이의 기본값. 값은 render 경로의 **실효**
# 기본값과 같아야 한다 — render_demo.jl 이 `ENV[…] = …` 로 쓰는 기본값이 있으면 그것, 없으면
# `get` 리터럴(`test/config_digest_inventory.jl` (6) 이 대조한다). 명시 export 하는 이유:
# 기본값이 코드에서 조용히 바뀌어도 격자는 campaign 이 적은 값으로 돈다 — 그 판은 코드 지문이
# 가르고, 설정 지문은 "무엇으로 돌았나" 를 평문으로 남긴다.
# 🔴 `RELOCATE_GATE` 는 **일부러 뺐다**: 기본값이 두 곳에서 다르다(`verifier.jl` 의 로드 시점
#    `Ref` 는 "0", `render_demo.jl` 의 `set_relocate_gate!` 는 "1") — 어느 값을 export 해도 한쪽의
#    현행 동작이 바뀐다. 설정 안 함(`<unset>`)으로 두고 지문에는 그대로 실린다.
const CONFIG_ENV_PINNED_DEFAULTS = Dict(
    "RESTAGE_ZONE_MARGIN_FRAC" => "0.5", "RESTAGE_RING_STEP_FRAC" => "0.34",
    "CARRIER_RESCUE" => "1",   # render_demo 가 없으면 "1" 을 **쓴다**(get 리터럴 "0" 이 아니다 — 최종 리뷰 C1)
    "ZONE_RESCUE" => "1",
    "ZONE_CAUSAL_RULE" => "0", "ZONE_DOMAIN_GATE" => "0", "ZONE_CHECK_PATHS" => "0",
    "ENERGY_OBJECTIVE" => "1", "SPARE_PRIORITY" => "1", "TEAM_PRIORITY" => "1",
    "RESPEC_DEPRIO_KAPPA" => "0.25",
    "RESTAGE_NAV_BUFFER" => "0", "RESPEC_TRANSLATE_ON_INFEASIBLE" => "0",
    "REPAIR_ABLATION" => "none",   # 존 복구 base ablation(2026-09-23) — repair_ablation_from_env 의 기본값
)

"""
    config_env(env = ENV) -> Dict{String,String}

설정 지문의 평문. `CONFIG_ENV_RESULT` 의 이름 **전부** → 설정값 또는 `"<unset>"`, 그리고 접두사
보조 규칙에 걸린 설정된 이름 → 값. `run_fingerprint` 가 `run_ctx.config_env` 로 싣고, 해시는
이 dict 의 정렬된 `name=value` 줄에서 나온다 — 두 판이 **어디서** 갈렸는지 복원할 수 있다.
"""
function config_env(env = ENV)
    local out = Dict{String,String}(k => (haskey(env, k) ? String(env[k]) : "<unset>")
                                    for k in CONFIG_ENV_RESULT)
    for (k, v) in env
        local ks = String(k)
        (haskey(out, ks) || ks in _CONFIG_ENV_EXCLUDED) && continue
        any(p -> startswith(ks, p), _CONFIG_ENV_PREFIXES) && (out[ks] = String(v))
    end
    return out
end

# 코드 지문이 보는 경로(저장소 뿌리 기준). 뿌리의 `Project.toml`·`Manifest.toml`(2026-09-22,
# R12)도 본다 — 의존성 판 고정이 바뀌면 같은 소스도 다른 엔진이다(추적 파일이라 diff 로 잡힌다).
# Shared decision code is under src/decision/ and is included in this inventory.
const _CODE_FINGERPRINT_PATHS = ("src", "tools", "test", "Project.toml", "Manifest.toml")

# 코드 지문이 보는 **untracked** 파일의 확장자 (2026-09-22, controller R5b). 추적 파일의 diff 는
# 확장자와 무관하게 전부 본다 — 이 거름은 untracked 에만 걸린다.
# 🔴 왜 거르나: `tools/` 아래 untracked 는 대부분 **데이터**다(2026-09-22 실측 239개·287 MB 중
#    213개가 `tools/monitor/streams_stale_*/*.jsonl`, 그 밖에 그림·애니·`sweeps.json` 류). 스윕
#    드라이버·분석 스크립트가 캠페인 도중 그런 파일을 다시 쓰거나, `DEMO_OUT_DIR` 가 `tools/`
#    안을 가리키면 코드는 그대로인데 digest 가 **셀마다 흔들린다**. (기본 `DEMO_OUT_DIR=""` 의
#    `tools/monitor/streams/`·`anim/` 은 `.gitignore` 에 있어 애초에 안 잡힌다.) 소스만 본다.
const _CODE_FINGERPRINT_EXTS = (".jl", ".py", ".sh", ".toml")

"""
    _code_dirty_digest(repo) -> String

추적 파일의 미커밋 편집(`git diff HEAD`)과 **추적 안 된 소스 파일**(`git ls-files --others
--exclude-standard` 중 확장자가 `_CODE_FINGERPRINT_EXTS` 인 것) 둘 다를 한 SHA-256 에 넣고
앞 16 hex 를 낸다. 둘 다 비면 `""`.
🔴 untracked 를 안 보면 새로 만든 소스(예: `stall_probe.jl`)가 달라도 지문이 같다 — 2026-09-22
   리뷰가 이 트리에서 실제로 짚은 구멍이다. 경로는 정렬하고, 파일마다 경로와 내용을 싣는다.
   못 읽는 파일은 경로 + `unreadable` 표식으로 싣는다(던지지 않는다).
git 자체가 실패하면 예외 — 호출자(`run_fingerprint`)가 `"unknown"` 으로 접는다.
"""
function _code_dirty_digest(repo::AbstractString)
    local tracked = read(pipeline(`git -C $repo diff --no-color --no-ext-diff HEAD -- $(_CODE_FINGERPRINT_PATHS)`;
                                  stderr = devnull))
    local untracked = sort!(filter!(!isempty, split(String(read(pipeline(
        `git -C $repo ls-files --others --exclude-standard -z -- $(_CODE_FINGERPRINT_PATHS)`;
        stderr = devnull))), '\0')))
    filter!(p -> any(e -> endswith(p, e), _CODE_FINGERPRINT_EXTS), untracked)
    (isempty(tracked) && isempty(untracked)) && return ""
    local ctx = SHA.SHA256_CTX()
    SHA.update!(ctx, tracked)                    # untracked 가 없으면 옛 지문(diff 의 해시)과 같다
    for p in untracked
        SHA.update!(ctx, codeunits(string("\0untracked\0", p, "\0")))
        local body = try
            read(joinpath(repo, p))
        catch
            Vector{UInt8}(codeunits("\0unreadable\0"))
        end
        SHA.update!(ctx, body)
    end
    return bytes2hex(SHA.digest!(ctx))[1:16]
end

"""
    code_identity(repo) -> Dict

I5(최종 리뷰): 코드 지문과 **그 지문이 덮는 파일들의 digest**. 부모(원래 세계 — git 을 읽을 수 있는 신뢰 프로세스)가 t0 에서
쓰고(`<parent>/code_identity.json`), 분기는 `.git`·git 설정을 못 읽으므로 git 대신 이 파일의 digest 를 **자기가 실제로 읽는
파일**과 대조해 같은 지문을 얻는다(`run_fingerprint` 의 `ZRV_CODE_IDENTITY`). 파일 집합 = `_CODE_FINGERPRINT_PATHS` 아래 추적 파일
전부 + 추적 안 된 소스(`_CODE_FINGERPRINT_EXTS`) — `_code_dirty_digest` 가 보는 것과 같은 범위.
"""
function code_identity(repo::AbstractString = normpath(joinpath(@__DIR__, "..", "..")))
    local fp = run_fingerprint(repo; env = Dict{String,String}())
    local tracked = split(String(read(pipeline(`git -C $repo ls-files -z -- $(_CODE_FINGERPRINT_PATHS)`; stderr = devnull))), '\0')
    local untracked = split(String(read(pipeline(
        `git -C $repo ls-files --others --exclude-standard -z -- $(_CODE_FINGERPRINT_PATHS)`; stderr = devnull))), '\0')
    filter!(p -> any(e -> endswith(p, e), _CODE_FINGERPRINT_EXTS), untracked)
    local files = Dict{String,String}()
    for p in Iterators.flatten((tracked, untracked))
        isempty(p) && continue
        local f = joinpath(repo, p)
        isfile(f) && (files[String(p)] = bytes2hex(SHA.sha256(read(f))))       # 추적되지만 지워진 파일은 diff 가 이미 싣는다
    end
    return Dict{String,Any}("schema" => "zrv-code-identity/1", "code_rev" => fp.code_rev,
                            "code_dirty_digest" => fp.code_dirty_digest, "files" => files)
end

"""
`ZRV_CODE_IDENTITY` 파일로 얻는 (code_rev, code_dirty_digest). 파일의 digest 가 **지금 디스크의 파일**과 하나라도 다르면(없음 포함)
`code_dirty_digest` 가 `identity-file-mismatch:…` 가 되어 신원 대조가 실패한다 — 넘겨받은 값을 검증 없이 믿지 않는다.
"""
function _verified_code_identity(repo::AbstractString, path::AbstractString)
    local d = try
        JSON3.read(read(path, String))
    catch e
        return ("unknown", "identity-file-unreadable:" * first(sprint(showerror, e), 120))
    end
    local bad = String[]
    for (p, want) in d.files
        local f = joinpath(repo, String(p))
        local got = isfile(f) ? bytes2hex(SHA.sha256(read(f))) : "missing"
        got == want || push!(bad, String(p))
    end
    isempty(bad) || return (String(d.code_rev), "identity-file-mismatch:$(length(bad)):" * first(sort!(bad)))
    return (String(d.code_rev), String(d.code_dirty_digest))
end

"""
    run_fingerprint(repo = <이 저장소>; env = ENV) -> NamedTuple

판을 만든 **코드와 설정**의 지문. 기동 때 한 번 계산해 `RUN_CTX` 에 합친다.
  · `code_rev`          — `git rev-parse HEAD`. 실패하면 `"unknown"`.
  · `code_dirty_digest` — `_code_dirty_digest`: `_CODE_FINGERPRINT_PATHS`(`src tools test` + 뿌리의
                          `Project.toml`·`Manifest.toml`) 아래 추적 파일의 미커밋 편집 +
                          추적 안 된 소스 파일(경로·내용). 깨끗하면 `""`, git 이 실패하면 `"unknown"`
                          (깨끗함과 **다른 값**이다).
                          🔴 HEAD 만 적고 미커밋 편집을 무시하면 같은 sha 가 다른 엔진이 된다
                          (이 트리는 여러 세션이 공유한다 — memory `concurrent-sessions-share-one-tree`).
  · `config_digest`     — `config_env(env)` 의 `KEY=VALUE` 줄을 정렬해 이은 것의 SHA-256 앞 16
                          hex. `CONFIG_ENV_RESULT` 전부(설정 안 됐으면 `<unset>`) + 접두사 보조.
                          **셀 불변**이다(cell_axis·observational 은 빠진다).
  · `config_env`        — 그 평문 dict(Task 6b) — 두 판이 어디서 갈렸는지 복원한다.
🔴 **전역 RNG 를 안 쓴다**, git 이 없거나 실패해도 **던지지 않는다**(런을 죽이지 않는다).
"""
function run_fingerprint(repo::AbstractString = normpath(joinpath(@__DIR__, "..", ".."));
                         env = ENV)
    local idf = get(env, "ZRV_CODE_IDENTITY", "")
    local rev, dirty
    if !isempty(idf)
        # I5: 분기(샌드박스, `.git` 못 읽음) — 부모가 계산해 넘긴 지문을 파일 digest 로 검증해서 쓴다.
        rev, dirty = _verified_code_identity(repo, idf)
    else
        rev = try
            readchomp(pipeline(`git -C $repo rev-parse HEAD`; stderr = devnull))
        catch
            "unknown"
        end
        dirty = try
            _code_dirty_digest(repo)
        catch
            "unknown"
        end
    end
    local ce = config_env(env)
    local cfg = bytes2hex(SHA.sha256(join(sort!([string(k, "=", v) for (k, v) in ce]), "\n")))[1:16]
    return (code_rev = rev, code_dirty_digest = dirty, config_digest = cfg, config_env = ce)
end

"""
    service_payload(env, truth; nl, descriptors, agents, zones, lanes) -> Dict

`/decide` 가 받는 관측 페이로드 **그 자체**(행 신원 도장 없음). `service_decide` 가 이것에 `_stamp_identity!` 를
얹어 보낸다. T9: 존 복구 검증 driver 의 일회용 observe worker(`RepairBranchWorker.observe_t0!`)가 t0 에서 같은 함수로
관측을 만든다 — 모델이 읽는 문장이 결정 레인과 한 벌이다. 세계를 바꾸지 않는다(부르는 것들이 전부 읽기이고,
`release_then_candidates` 는 사본에서 돈다).
"""
function service_payload(env, truth; nl::AbstractString = "", descriptors = nothing,
                         agents = nothing, zones = nothing, lanes = nothing)
    # payload = 예전 스키마 피처(surrogate 용) + nl/descriptors(LLM 용). 서비스는 nl 이 있으면
    # LLM 에게 **문장**을 주고, 없으면 예전처럼 파싱된 필드를 준다(하위호환).
    payload = ood_features(env, truth)
    isempty(nl) || (payload["nl"] = String(nl))
    # 데모의 기본은 **observation**: 주입기 문장 뒤에 붙는 "그러니 무엇을 하라" 절을 떼고 관찰만 준다.
    # 그 뒷절이 곧 canonical 정답이라, 그대로 주면 재는 것이 추론이 아니라 프롬프트 준수가 된다
    # (실측: 서술자가 harm=0.02 인데도 "restage 하라"를 따라 ForbidZone 을 골랐다).
    # 서비스는 별도 프로세스라 환경변수로는 못 미치므로 요청에 실어 보낸다. LLM_NL_MODE=raw 로 옛 동작.
    payload["nl_mode"] = lowercase(get(ENV, "LLM_NL_MODE", "observation"))
    # 라우터가 **판정에 쓴** kind (2026-08-29, §A-1). 위 `payload["kind"]` 와 **다른 함수**에서
    # 온다: `ood_features` 는 사건 타입을 자기 이름(`fault`/`battery`/`zone`)으로, 모르는 타입은
    # `"unknown"` 으로 부르고, `routing_kind` 는 LLM 레인으로 갈 것 전부에 `"unknown:"` 접두사를
    # 단다. **두 값이 갈리는 사건이 곧 OOD 사건이다.**
    # 이 줄이 없으면 라우터가 "처음 보는 사건이라 LLM 으로 보낸다" 고 판정해 놓고 그 판정을
    # 프롬프트에 한 글자도 안 싣게 되어, 모델은 자기가 아는 종류의 사건을 받았다고 읽는다.
    #
    # 🔴 왜 `agents`/`zones`/`lanes` 처럼 키워드로 안 받는가 (Ruling R1). 저 셋은 호출자만
    #    아는 값이라 키워드가 옳다. `routing_kind_of` 는 **`truth` 하나의 전총 순수 함수**이고
    #    (2026-08-30 부터 타입 이름 + battery 심각도를 본다 — `lane_select.jl` 의 상수 주석 참조)
    #    `decide_all` 의 라우터가 이미 같은 함수로 같은 값을 만든다. 여기서 유도하면 라우터와
    #    페이로드가 **구조적으로** 갈릴 수 없다 — 키워드로 받으면 호출자가 다른 값을 실을
    #    여지가 되살아나고, 그 갈림이 §A-1 이 지목한 결함 그 자체다.
    # 🔴 2026-09-07 정정. 여기 있던 *"`payload["kind"]` 는 한 글자도 안 건드린다 — surrogate
    #    피처가 그 열을 그렇게 배웠다"* 는 **거짓이다.** surrogate 는 `kind` 를 안 읽는다:
    #    `dspy_service._surro_row` 가 *"kind 는 **일부러 넣지 않는다** — 새 표현은 종류 이름을
    #    한 번도 읽지 않는다"* 고 적고 실제로 안 싣는다(`build_features` 는 `psi(macro)` 와
    #    `descriptors_from_row` 만 부르고, 후자는 계약상 `row['kind']` 를 절대 안 읽는다).
    #    `event_descriptors_of`(이 파일 :639)도 아홉 값을 뽑으며 `kind` 를 안 본다.
    #    ⟹ "surrogate 때문에 `kind` 를 못 건드린다" 는 제약은 **없다.** 같은 날 `else` 분기가
    #    `("fault", nothing)` → `("unknown", nothing)` 으로 바뀐 근거가 이것이다 — 그 리터럴의
    #    유일한 변명이 "surrogate 피처로는 옳다" 였는데 그 전제가 사라졌다.
    #    남은 `kind` 소비자는 셋뿐이고 전부 사소하다: `_valid_for(req.kind, MACROS)`(폴백일 뿐 —
    #    이 파일이 `valid` 를 항상 실으므로 실전 미도달) · `_state_line`(`nl` 없는 폴백 경로의
    #    `"OOD kind=%s"` 와 `soc`/`zone_overlap` 렌더 게이트) · `run_synthesis(kind=...)`(기록
    #    라벨. 발화 조건은 `expressible` 하나다).
    # 게이트: `test/service_decide_ships_routing_kind.jl`(본문) ·
    #        `src/respec/llm_service/test_routing_kind_reaches_the_prompt.py`(프롬프트).
    payload["routing_kind"] = routing_kind_of(truth)
    descriptors === nothing || (payload["descriptors"] = collect(Float64, descriptors))
    # 실재 로봇 목록. 서비스의 tool enum 이 이것만 쓴다 = 모델에게 **보여주는** id 가 이것뿐이다.
    # 🔴 2026-08-29 정정. 여기 있던 *"여기 없는 id 는 모델이 못 만든다"* 는 **거짓이다.**
    #    디코드 시점 차단은 이 레인에 **없다.** 실측: `format_as_litellm_function_call()` 이 내는
    #    `parameters` 의 키는 `{properties, required, type}` 뿐이고 `strict` 도
    #    `additionalProperties` 도 없다. dspy 3.3.0 의 `dspy.Tool` 에는 `strict` 필드 자체가
    #    없고, `tool_choice` 는 이 레인 어디서도 안 보낸다. 비-strict `enum` 에 프로바이더가
    #    문법 제약을 거는지는 **안 잰 프로바이더 동작**이라 라이브 호출 없이는 판정 못 한다.
    #    → 환각 id 방어를 이 채널에 기대지 말 것.
    # 🔴 2026-08-29 정정 2. 위 줄은 원래 *"거르는 자리는 받는 쪽(줄리아 경계)이다"* 로 닫혀
    #    있었다. **그것도 거짓이다** — 방향만 반대인 같은 종류의 과장이다(디코드 시점 집행을
    #    과장하는 대신 사후 집행을 과장한다). 오늘 이 레인의 tool 인자를 거르는 자리는
    #    **어디에도 없다.** 정확히는 셋으로 갈린다:
    #      ① 디코드 시점 집행: **없다**(위 실측).
    #      ② 접지를 집행할 그물은 **실재한다** — `grammar_ground_check` 는 `verify()` 안에서
    #         MILP 를 세우기 전(2b GROUNDING)에 실제로 불린다. 아스피레이션이 아니다.
    #      ③ 🔴 **그런데 그 그물은 이 레인을 아직 못 본다.** 그것은 `RespecProposal` 을 받고,
    #         `tool_args` 를 거기까지 나르는 것이 없다. 실측: 레포의 `.jl` 에서 `tool_args`/
    #         `tool_called` 를 **코드로 읽는 줄이 0개**다(주석에서 언급하는 자리는 바로 이
    #         블록뿐이므로, grep 이 1건을 내면 그건 이 주석 자신이다). 그리고 이 파일의
    #         🟡 2026-08-29 (Plan B / T1) 갱신: 이 문단의 마지막 줄은 *"`policy_entry` 는
    #         키 목록을 손으로 들고 있어 chosen·ranking·margin·rationale·scores·unsupported·
    #         label·available 여덟 개만 나른다"* 였다. **그 부분은 이제 낡았다** — `policy_entry`
    #         가 `TOOL_LANE_KEYS`(아래, 2026-08-29 T6 이후 **열하나**)를 두 분기 모두에서 나르고 `decide_all` 이
    #         `tool_lane` 필드로 노출한다. 🔴 **그러나 위 ③의 결론은 그대로 참이다**: 나르기만
    #         할 뿐 `RespecProposal` 까지 잇는 것은 아직 없으므로 `grammar_ground_check` 는
    #         여전히 이 레인을 못 본다. 그 연결은 T2 다.
    #    즉 tool 호출의 접지를 보증하는 층은 **오늘 없다.** 연결은 Plan B 의 경계 작업이다.
    #    (세 부분의 전체 서술과 근거는 스펙 §8 안전 스택 표 아래의 같은 날짜 정정.)
    agents === nothing || (payload["agents"] = agents)
    # 살아 있는 출입금지 구역 설명(2026-08-29, Plan B / T4b). `agents` 와 **정확히 같은 규약**:
    # 키워드로 받고, nothing 이 아닐 때만 싣는다 — 안 실으면 서비스의 `MacroRequest.zones` 가
    # None 으로 남아 `_zones_block` 이 빈 문자열을 내므로, 비-호출자의 프롬프트는 바이트 단위로 그대로다.
    #
    # 🔴 왜 방어 코드가 여기 없는가. 서비스 쪽 `zones: Optional[List[Dict[str, Any]]]` 는
    #    **잘못된 zones 를 422 로 떨어뜨린다**(degradation 이 아니다 — `test_zone_channel.py::
    #    test_zones_are_rejected_at_the_pydantic_boundary_when_malformed`). 즉 원소 하나라도
    #    dict 가 아니면 그 결정 요청이 통째로 죽는다. 그런데 이 자리에 가드를 두지 않는 것은
    #    게으름이 아니라 **`open_zone_descriptors` 의 출력이 구조적으로 항상 well-formed 이기**
    #    때문이다: 그 함수는 매 반복에서 `Dict{String,Any}(...)` 리터럴 하나만 push! 하므로
    #    원소는 언제나 JSON object 이고(→ 422 불가), 렌더러가 실제로 읽는 네 키는 전부 non-null
    #    이다 — `center` 는 `[Float64,Float64]`, `radius`/`work_reach` 는 `Float64`,
    #    `covers` 는 `String[]`(`ac === nothing && continue` 가 구멍을 막는다), `covers_root` 는
    #    `Bool`. null 이 **될 수 있는** 것은 `build_center`/`build_radius`/`max_shift` 셋뿐인데
    #    (`isempty(env.staging_circles)` 인 씬), 값 타입이 `Any` 라 pydantic 이 null 을 받고
    #    `_zones_block` 은 그 세 키를 **아예 렌더하지 않는다**. 그래서 이 채널로는 422 가 안 난다.
    zones === nothing || (payload["zones"] = zones)
    # 이 요청이 **실제로 청구하는** 레인 (2026-08-29, T11 / §0-C 충돌 ⑦). `agents`/`zones` 와
    # **정확히 같은 규약**: 키워드로 받고, `nothing` 이 아닐 때만 payload 에 싣는다 —
    # 안 실으면 서비스가 둘 다 계산한다(하위호환, 2026-08-29 이전과 바이트 동일).
    # 🔴 여기가 비용이 실제로 잘리는 자리다. surrogate 로 라우팅된 사건에서 이 키가 없으면
    #    서비스가 맨 앞에서 `macro(req)` 로 LLM 을 부른다 — `select_lane` 만 고쳐서는
    #    비용이 1원도 안 준다. 게이트: `test_decide_lanes.py`(LM 호출 델타 0).
    # ⚠️ 빈 목록도 **싣는다**. 서비스에서 `[]` 는 "아무 레인도 안 청구했다" 로 `None`(둘 다)과
    #    다른 사건이다 — falsy 로 접으면 그 구별이 여기서 죽는다.
    lanes === nothing || (payload["lanes"] = collect(String, lanes))
    # 🔴 **`tool_choice` 는 이 요청에 더 이상 실리지 않는다** (2026-08-29, 단일 채널 / T6).
    #    T-C 가 놓았던 `tool_choice = …` 키워드와 그 payload 줄을 여기서 지웠다. 이유는
    #    라우터 게이팅이 **의미를 잃었기 때문**이다: T5 가 서비스의 `TOOL_CHOICE_DEFAULT` 를
    #    `"required"` 로 세웠으므로, 요청이 그 키를 **안 실으면 강제된다**. 즉 예전 규약
    #    ("안 실으면 2026-08-29 이전과 바이트 동일") 은 이제 거짓이고, 여기서 `nothing` 을
    #    넘기는 것과 `"required"` 를 넘기는 것이 프로바이더 요청에서 **같은 값**이 된다.
    #    게이팅의 근거였던 *"강제는 `expressible` 을 지운다"* 는 T3 이 끊었다 — `expressible`
    #    은 이제 텍스트 채널이 아니라 **tool 인자**로 오므로 강제가 그것을 못 지운다.
    #    ⟹ 값을 유도해 실어 보내는 사슬 전체가 죽은 코드다. 유도 함수 `tool_choice_for`(위)는
    #    **되돌릴 때 필요해서 남겼고 생산 호출자가 0개다** — 그 docstring 이 그 사실을 진다.
    # 🔴 서비스 쪽 킬스위치는 그대로 살아 있다: `DSPY_TOOL_CHOICE` (환경변수 > 요청).
    #    강제를 끄려면 **서비스 호스트**에서 끈다. 실제로 실린 값은 응답의 `tool_choice` 표식에
    #    남으므로 행 하나만 보고 어느 레짐이었는지 갈린다.
    # 이 순간 **실제로 실행 가능한** 매크로만 legal 로 넘긴다(valid_macros 주석 참조).
    # 비어 있으면 서비스가 예전처럼 kind 별 기본표를 쓴다 = 기존 호출자 동작 그대로.
    local vm = valid_macros(env, truth)
    isempty(vm) || (payload["valid"] = vm)
    return payload
end

"상태를 서비스에 POST 하고 **학습형 정책 전부**(dspy + surrogate)의 결정을 한 번에 받는다. 실패하면 nothing."
function service_decide(env, truth; nl::AbstractString = "", descriptors = nothing,
                        agents = nothing, zones = nothing, lanes = nothing)
    dspy_ready() || return nothing
    payload = service_payload(env, truth; nl, descriptors, agents, zones, lanes)
    # 🔴 2026-09-22: 원장 행 id 와 판 신원. 재전송(`retries=3`)은 같은 페이로드를 다시 보내므로
    #    같은 `record_id` 로 도착한다 — 그것이 이 id 를 여기서 발급하는 이유다.
    _stamp_identity!(payload)
    # 🔴 이 전송의 사유칸을 **먼저 비운다.** 안 비우면 지난 사건의 실패 사유가 이번 사건의
    #    성공/실패에 눌러붙어, 라우터가 엉뚱한 사유를 찍는다.
    LAST_DECIDE_TRANSPORT_ERROR[] = ""
    try
        # retry_non_idempotent=true 가 꼭 필요하다: HTTP.jl 은 POST 를 기본적으로 재시도하지 않는데,
        # 이벤트 간격이 길어 keep-alive 연결이 죽어 있으면 첫 시도가 "stream is closed or unusable"로
        # 실패한다(실제로 두 번째 OOD 에서 그렇게 폴백됐다). 이 호출은 부작용이 없으므로 재시도해도 안전.
        # 🔴 `readtimeout` 은 상수가 아니라 `DSPY_TIMEOUT_S` 다 — 그 상수 위의 실측이 근거다.
        resp = HTTP.post(DSPY_URL * "/decide", ["Content-Type" => "application/json"],
                         JSON3.write(payload);
                         readtimeout = DSPY_TIMEOUT_S, retries = 3, retry_non_idempotent = true)
        if resp.status != 200
            # 🔴 비-200 도 사유다. 예전에는 이 자리가 조용한 `nothing` 이라 라우터가
            #    "(no error field)" 로 죽었다 — 상태코드는 이미 손에 있었는데도.
            LAST_DECIDE_TRANSPORT_ERROR[] = "HTTP $(resp.status) from /decide"
            return nothing
        end
        j = JSON3.read(String(resp.body))
        return j
    catch e
        # 🔴 사유를 **한 줄로** 남긴다. `showerror` 의 첫 줄만 남기면 `HTTP.RequestError` 에서
        #    진짜 원인이 통째로 죽는다(`enact.jl` 의 `_rewrite_once` 가 같은 자리에서 이미
        #    한 번 데였다) — 그래서 마지막 비지 않은 줄까지 본다.
        local _lines = filter(!isempty, strip.(split(sprint(showerror, e), "\n")))
        LAST_DECIDE_TRANSPORT_ERROR[] =
            isempty(_lines) ? string(typeof(e)) :
            (length(_lines) == 1 ? _lines[1] : _lines[1] * " | " * _lines[end])
        @warn "DSPy call failed" exception = e timeout_s = DSPY_TIMEOUT_S
        return nothing
    end
end

"canonical 규칙이 고른 매크로 이름(규칙표 그대로, 실행 가능성 미고려)."
function canonical_macro(truth)
    prop = try CB.canonical_respec(truth) catch; nothing end
    (prop === nothing || isempty(prop.constraints)) ? "NOOP" :
        string(typeof(prop.constraints[1]).name.name)
end

"""
    canonical_macro(env, truth) -> String

규칙표의 답을 **지금 실행 가능한 어휘로 투영**한 것.

왜 필요한가(2026-08-05): 규칙과 LLM 이 서로 다른 어휘를 보면 화면의 "규칙 vs LLM 불일치"가
판단의 차이가 아니라 **어휘가 갈린 아티팩트**가 된다. 2026-08-03 에 zone 팔이 ForbidZone →
RelocateBuild 로 바뀔 때 `canonical_respec(::ZoneTruth)`(baselines.jl)는 오프라인 채점 기준이라
일부러 남겨 뒀고, 그 뒤로 데모 로그에는 늘 `rule=ForbidZone, dspy=RelocateBuild` 가 찍혔다.

여기서는 `baselines.jl` 을 건드리지 않고(그건 오프라인 실험의 B1 기준선이다) **데모 표시·집행용
규칙**만 투영한다: 규칙이 고른 팔이 지금 도메인이 비어 아무것도 못 하면 **NOOP** 이라고 말한다.

왜 "더 센 팔로 격상"이 아닌가(2026-08-05 실측으로 반증됨): 처음에는 ForbidZone 이 불가능하면
RelocateBuild 로 올리려 했다. 그런데 같은 seed·같은 존으로 매크로만 교차해 재보니,
국소 복구 대상이 하나도 없는 판에서 **아무것도 안 함 = closed 231(조립체 7/8)** 인 반면
**빌드 전체 이동 = closed 136(조립체 1/8)** 이었다. 전역 이동은 공짜가 아니라 진행 중인 운반을
통째로 흔든다. 규칙(기준선)의 정직한 답은 "내 팔은 지금 할 일이 없다"이고, 그럼에도 개입할지는
정책(LLM/surrogate)이 판단할 문제다 — 기준선이 대신 도박하면 baseline 이 아니게 된다.
"""
function canonical_macro(env, truth)
    m = _macro_label(canonical_macro(truth))
    vm = valid_macros(env, truth)
    (isempty(vm) || m in vm) && return m
    return "NOOP"      # 규칙이 고른 팔이 지금 도메인이 비었다 = 규칙은 할 말이 없다
end

# ---- oracle lane: 기준 행동 a* 의 실행판 (2026-08-12) -----------------------------------
# `src/decision/core/reference_policy.py` 의 a* 규칙을 **결정 시점에** 계산한 것.
# 저쪽은 판이 끝난 뒤 decisions[] 를 읽는 사후 채점기라 실행 lane 이 될 수 없다.
#
# 왜 신설했는가(2026-08-12 진단): 이 함수가 없던 동안 `DEMO_POLICY=oracle` 은 아래 decide_all 의
# `enacted = "canonical"` 폴백(존재하지 않는 정책 키)으로 **조용히** 떨어졌다. 경고도 종료코드도
# 없이 요약 행만 `"policy":"oracle"` 로 남아, 이름만 oracle 인 canonical 판이 만들어졌다.
# 실측 증상은 a* 대비 결정 적중률 0/4 였다(정의상 4/4 여야 하는 lane).
#
# 매크로 이름 문자열은 일부러 reference_policy.py 와 **같은 리터럴**을 쓴다(레지스트리 경유 금지 —
# 경유하면 두 파일이 다른 이름 체계를 쓰게 된다). 두 구현이 갈려도 에러는 안 난다: 표의 `oracle`
# 행이 "a* 를 집행했다"는 이름으로 다른 것을 집행할 뿐이다.
#
# ★ a* 가 미정의인 자리에서는 **언제나 `canonical_macro` 로 위임한다. NOOP 이 아니다.**
#   (reform 사건 · 근거 없는 SoC 구간 · agent_pending 미기록 · zone_diagnosis 실패)
#   두 가지 이유가 겹친다:
#     1) reference_policy 는 정확히 같은 자리에서 a*=None(unscored)을 낸다. "Julia 가 위임한 사건"
#        과 "Python 이 채점에서 뺀 사건" 이 겹쳐야 "채점된 사건에서 oracle 적중률 1.0" 계약이 선다.
#     2) NOOP 으로 떨어지면 재형성이 필요한 교착을 그대로 두게 되고 **그것이 곧 미완주다**
#        (md/README.md §6: 복구를 되살린 처방이 DEMO_REFORM). canonical_macro 는 규칙의 답을 지금
#        실행 가능한 어휘로 투영하므로(바로 위 함수) 실행 불가능한 팔은 절대 내지 않는다.
#
# 아래 상수는 `reference_policy.py` 의 `BATTERY_DEEP_SOC` 와 **같은 값이어야 한다**(줄번호로
# 찾지 말 것 — 이 레포는 줄번호가 계속 밀린다. 심볼로 찾는다). 갈리면 그 사이 SoC 구간에서 두
# 구현이 다른 팔을 내고, 증상은 에러가 아니라 **oracle 레인의 결정 적중률이 1.0 미만**으로
# 나타난다.
#
# 왜 0.2 인가 (2026-08-25): `reference_policy.BATTERY_DEEP_SOC` 가 0.5 -> 0.2 로 내려갔는데
# (그쪽 주석대로 `src/navigator/ood_truth.jl` 의 `REPLACE_SOC_THRESHOLD` = 0.2 와 통일한
# 값이다) 이 상수만 0.5 로 남아 있었다. 그 사이 구간 `(0.2, 0.5]` 에서 oracle 레인은 팔을
# 내는데 파이썬 채점기는 같은 사건을 unscored 로 뺐다 — 실측: 현행 라벨셋
# `oracle/out/oracle_dataset.jsonl` 의 battery 행 27개 중 **18개**가 그 구간에 있다.
#
# 🔴 왜 리터럴인가 — 유도를 시도했고 **못 한다**. (추론이 아니라 배선 제약이다.)
#   · 파이썬 쪽 `BATTERY_DEEP_SOC` 는 다른 언어라 로드 시점에 읽을 수 없다.
#   · 줄리아 쪽 진실원 `CB.REPLACE_SOC_THRESHOLD[]` 로는 유도할 수 있어 **보이지만**, 이 파일은
#     `CB` 도 navigator 레이어도 없는 맨 모듈에서 로드될 수 있어야 한다:
#     `test/policy_macro_binding.jl` 의 (B)·(C) 양성대조가 정확히 그 형태
#     (`module _M; import HTTP, JSON3; include("policy.jl") end`)로 이 파일을 띄우고, 그 게이트는
#     `test/runtests.jl` 에 실려 있다. 최상위에서 `CB.` 를 만지면 그 게이트가 UndefVarError 로
#     빨개진다. `isdefined(...) ? ...[] : 0.2` 식 폴백은 **리터럴을 조용히 되살리는 것**이라
#     더 나쁘다(이 레포에 이미 셋 있다: battery.jl · hazard.jl · replace_robot.jl).
#
# 그래서 값은 리터럴로 두고 **둘을 묶는 일은 게이트가 한다**: `tools/test_policy_oracle.jl` 의
# 0절이 `reference_policy.py` 를 정규식으로 직접 읽어 이 상수와 대조한다. 그 게이트는
# 2026-08-25 부터 `test/runtests.jl` 에 배선돼 있다 — 그 전까지 **고아 게이트**였고, 그래서
# 이 회귀(0.5 대 0.2)가 최종 리뷰까지 살아남았다. 배선을 빼면 방어선이 사라진다.
const ORACLE_BATTERY_DEEP_SOC = 0.1      # == reference_policy.py `BATTERY_DEEP_SOC` (게이트: tools/test_policy_oracle.jl 0절)
# 🔴 2026-08-31 (S1/T3): 0.2 -> 0.1, REPLACE_SOC_THRESHOLD/BATTERY_DEEP_SOC 사다리 이동과 같이 옮긴다.
#    이 상수는 그 6+6 목록 밖에 있던 열세 번째 자리였다 -- 전체 스위트를 실제로 돌려서 잡았다
#    (tools/test_policy_oracle.jl 0절이 REPLACE_SOC_THRESHOLD 를 전혀 언급하지 않는 별도 게이트라서
#    grep 으로는 안 잡혔다).


# ---- "지금 운반체가 이동 중인가" 술어 (2026-08-13) ------------------------------------------
# **oracle 레인 전용이다.** 이 함수는 `oracle_macro` 만 부른다 — 공유 장부(RECOVERY_SPARES)를
# 건드리지 않으므로 noop/surrogate/dspy/canonical 의 결정은 한 비트도 바뀌지 않는다.
#
# 무엇을 재는가: RelocateBuild 는 **남아 있는 항법 목표 전부를 한 번에 평행이동**시킨다
# (verifier.jl RELOCATE_GATE: "it moves every future goal and staging circle at once, while
# carriers are mid-transit"). 그래서 위험한 상태는 "이 판에서 Replace 가 있었는가"(래치)가 아니라
# **복구 임무 중인 로봇이 지금 자기 발로 목표를 향해 가고 있는가** 다.
#
# 어느 로봇을 보는가: RECOVERY_SPARES 는 세 경로에서 채워지는데(replace_robot.jl:1182 · :1271 ·
# :1503) **창고 왕복이 있는 것은 :1503(hot_swap_robot! :via_depot) 하나뿐**이다. 앞의 둘은 이미
# 현장에 있던 예비를 스케줄에 접합할 뿐이라 "먼 창고에서 걸어 돌아오는 중" 이 아니다. 그 셋을
# 가르는 표식이 `DECOMMISSIONED_BODIES` 다 -- :via_depot 가지에서만(replace_robot.jl:1499)
# `mark_recovery_spare!` 와 **같은 자리에서** 기록된다. 그래서 게이트는
# `RECOVERY_SPARES ∩ keys(decommissioned_bodies())` 만 본다(읽기 전용 조회, 공유 상태 불변).
#
# 그 로봇이 아직 오는 중인가(`_nav_goal_targets` 로 — zone_diagnosis 가 이미 쓰는 같은 계산기다.
# 게이트와 진단이 서로 다른 기하를 보면 안 된다, verifier.jl:307 과 같은 원칙):
#   · 남은 항법 목표가 **없다**                    -> 도착(더 갈 곳이 없다)
#   · 운반팀에 **포획돼 있다**(_transport_unit_parent) -> 도착. 인계가 끝나 팀의 일부로 실려 간다;
#     이 상태에서는 RVO 주체도 팀이라 "혼자 걸어오는 중"이 아니다.
#   · 그 외: 남은 목표 중 **가장 가까운 것까지의 거리**가 제 몸 반경보다 멀면 = 아직 오는 중.
#     임의 상수가 아니라 그 에이전트의 반경(`_nav_goal_targets` 가 실어 주는 값)을 쓴다.
#
# 왜 "빌드 프레임 밖" 이 아닌가(2026-08-13 실측으로 기각): 프레임(남은 항법 목표의 중심·최대
# 이심거리)은 R≈20 으로 커서 depot(D=20)에서 나온 로봇도 몇 걸음 만에 안쪽으로 들어온다. 그
# 술어로 5판을 재보니 게이트가 **한 번도 발화하지 않아** 사실상 게이트 없는 상태(= df92c37
# 이전)로 되돌아갔고, 그 조건에서 완주하던 fault_zone s1/s5 가 다시 186/185 에서 멎었다.
#   실측(s1 closed=99):  spare R1 pos=[-8.01,0.93] 가장 가까운 목표까지 5.72, 팀 미포획 → 오는 중
#   실측(s14 closed=189): spare R5 팀에 포획됨, dgoal=0.0                       → 인계 완료
#
# 실패 시 **true(=이동 중)로 폴백**한다: 못 읽는 상태에서 전역 이동을 허용하는 쪽이 더 위험하다.
# ENV ORACLE_TRANSIT_DEBUG=1 이면 판정 근거를 남긴다(진단용, 동작 무영향).
function _recovery_in_transit(env)
    local spares = try CB.recovery_spares() catch; return true end
    isempty(spares) && return false                 # 복구 임무 중인 로봇이 아예 없다
    local navs = try CB._nav_goal_targets(env) catch; return true end
    local depot = try CB.decommissioned_bodies() catch; return true end
    local dbg = get(ENV, "ORACLE_TRANSIT_DEBUG", "0") == "1"
    local intransit = false
    for rid in spares
        local viadepot = haskey(depot, rid)          # 창고 왕복이 있었던 역할만 "돌아오는 중" 후보
        if !viadepot
            dbg && println("[oracle-transit]   R$(try rid.id catch; "?" end) via_depot=false -> moving=false")
            continue
        end
        local mine = [t for t in navs if t.kind === :robot && t.id == rid]
        isempty(mine) && continue                                  # 남은 항법 목표 없음 = 도착
        local captured = try CB._transport_unit_parent(env.scene_tree, rid) !== nothing catch; false end
        local dmin = minimum(t -> hypot(t.pos[1] - t.goal[1], t.pos[2] - t.goal[2]), mine)
        local tol  = max(maximum(t -> Float64(t.radius), mine), CB.capture_distance_tolerance())
        local mv   = !captured && dmin > tol
        mv && (intransit = true)
        # println 이다(@info 가 아니다): 실판은 log_level=Logging.Error 로 돌아 @info 가 삼켜진다.
        dbg && println("[oracle-transit]   R$(try rid.id catch; "?" end) goals=$(length(mine)) " *
                       "dmin=$(round(dmin,digits=2)) tol=$(round(tol,digits=2)) captured=$(captured) -> moving=$(mv)")
        (mv && !dbg) && return true
    end
    dbg && println("[oracle-transit] spares=$(length(spares)) -> in_transit=$(intransit)")
    return intransit
end

function oracle_macro(env, truth)
    vm = valid_macros(env, truth)
    if truth isa CB.BatteryTruth
        local soc = try Float64(truth.soc_after) catch; nothing end
        # NaN <= x 는 조용히 false 라 mild 가지로 새어 들어간다 -- reference_policy._finite_soc 와
        # 같은 게이트를 여기서도 통과시킨다.
        (soc === nothing || !isfinite(soc)) && return canonical_macro(env, truth)
        # 깊은 방전. D=20 사다리(n44_plus78_d20)에서 SwapBattery 가 세 칸(0.02·0.30·0.50)
        # 전부에서 이겼지만(0.02 = 완주 여부, 0.30·0.50 = makespan), 임계값이 0.2 로 내려가면서
        # **이 가지에 남는 것은 0.02 칸 하나뿐이다** — 나머지 두 칸은 아래 unscored 구간으로
        # 밀려났다(대가는 reference_policy.py 의 `BATTERY_DEEP_SOC` 대입부 주석에 적혀 있다).
        # SwapBattery 가 메뉴에 없는 배선에서는 Replace 가 그 자리를 대신한다 --
        # reference_policy.py `a_star` 의 `"SwapBattery" if ... else "Replace"` 와 같은 규칙.
        soc <= ORACLE_BATTERY_DEEP_SOC && return ("SwapBattery" in vm ? "SwapBattery" : "Replace")
        # SoC > ORACLE_BATTERY_DEEP_SOC 는 채점 근거가 없는 구간이다(사다리의 0.30·0.50 rung 이
        # 여기로 밀려났다 — 측정은 있었지만 임계값이 그 아래에 있다). reference_policy.py 의
        # 같은 자리가 이 구간을 unscored(a*=None)로 뺀다 -- 없는 정답을 지어내지 않는다.
        # ★ NOOP 이 아니라 canonical 위임이다(이 함수 위 ★ 주석).
        return canonical_macro(env, truth)
    elseif truth isa CB.FaultTruth
        local pend = try _agent_pending(env, truth.robot) catch; -1 end
        pend < 0 && return canonical_macro(env, truth)   # 미기록 = reference_policy.py:190 도 unscored
        # firegrid 실측은 완전 분리다(24/24, 18/18): "고장났으니 교체" 가 아니라 **일을 지고
        # 있었는가** 가 가른다.
        return pend > 0 ? "Replace" : "NOOP"
    elseif truth isa CB.ZoneTruth
        local zdg = try CB.ablation_exempt(:reference_label) do
                CB.zone_diagnosis(env, truth.zone)
            end catch; nothing end
        # 진단이 없거나 구역이 죽었으면 run_demo 요약의 zone_primitives 도 비고(아래 zone 블록이
        # 같은 조건으로 기록한다) reference_policy.py:199 가 그 사건을 unscored 로 뺀다.
        (zdg === nothing || !zdg.exists) && return canonical_macro(env, truth)
        # (1) **개입할 이유가 있는가** -- 여기까지는 reference_policy.py:203 과 글자 그대로 같다.
        #     막힌 것이 **항법 목표**이고 root 하역목표는 안 걸렸을 때만 공간형 팔이 값을 한다
        #     (zcausal_reform STEP 10: blk 279 완주 vs NOOP 254 정지 / cov 는 반대로 뒤집힌다).
        (zdg.n_nav_blocked > 0 && zdg.root_covered == 0) || return "NOOP"
        # ---------------------------------------------------------------------------------
        # (2) **그 팔이 지금 실제로 무엇을 할 수 있는가** (2026-08-13 추가)
        #     원칙은 이 저장소가 이미 적어 둔 것이다(dspy_service.py:96):
        #     "legal 은 kind 가 아니라 그 순간 그 팔이 실제로 무언가를 할 수 있는가로 정해져야 한다."
        #
        #     ⓐ ForbidZone 은 도메인이 비면 **별개의 팔이 아니다.** restage_all_blocked! 이
        #        :residual_blocked 를 내면 maybe_respecify! 가 자동으로 whole-build 평행이동으로
        #        격상한다. 2026-08-13 실측(zone s1, DEMO_FORCE_MACRO 교차): ForbidZone 판과
        #        RelocateBuild 판이 closed 270 · sim 138.425 · steps 5537 로 **완전히 같았고**,
        #        로그에 `[zone] staging=none final=translated` 가 남았다. 그래서 실제 선택지는
        #        "전역 평행이동인가 아닌가" 둘뿐이며, ForbidZone 은 `n_restage_feasible > 0`
        #        (= 실제로 옮길 조립체가 있다) 일 때만 자기 이름값을 한다.
        #
        #     ⓑ 전역 평행이동은 **빌드 프레임 밖에 돌아올 로봇이 없을 때만** 수복이다.
        #        verifier.jl RELOCATE_GATE 독스트링이 이미 그 위험을 적어 뒀다("it moves every
        #        future goal and staging circle at once, while carriers are mid-transit").
        #        depot 에서 몸체를 갈아 끼운 역할(hot_swap_robot! :via_depot)은 창고 자리에서 다시
        #        등장해 빌드까지 **걸어 돌아와야** 하고, 그 사실이 `mark_recovery_spare!` 로
        #        RECOVERY_SPARES 에 남는다. 그 상태에서 빌드를 통째로 옮기면 그 로봇의 목표가
        #        발밑에서 사라진다.
        #
        #        ‼ **[해소됨 2026-08-13] 이 자리에 있던 술어는 그 문장을 구현하지 않았다.**
        #          `!isempty(CB.recovery_spares())` 가 실제로 뜻한 것은 "지금 돌아오는 중인
        #          로봇이 있다" 가 아니라 **"이 판에서 Replace 가 한 번이라도 일어났는가"** 였다.
        #          런 범위(run-scoped)의 **단방향 래치**다. 근거:
        #            · ood_injection.jl:787-795 의 RECOVERY_SPARES 인터페이스는 `push!`
        #              (mark_recovery_spare!) 와 `empty!`(clear_recovery_spares!) 뿐이다 --
        #              **도착했다고 원소를 빼는 경로가 아예 없다.** clear_ 는 판 시작 시 초기화
        #              (demos.jl:792/1636/1744/2800)에서만 불린다.
        #            · 표식을 다는 곳도 depot 스왑만이 아니다: 평범한 예비 접합(spare-splice)
        #              Replace 경로인 replace_robot.jl:1182 와 :1271 이 이미 단다. depot 스왑
        #              (:1503)은 셋 중 하나일 뿐이다. 즉 창고 왕복이 없는 Replace 도 래치를 걸었다.
        #
        #          ⇒ **대가(실측 v1, results_oracle/ 210판):** `fault_zone` 22/30. 8개 미완주 중
        #            7개가 정확히 `Replace → ZoneTruth→NOOP` 모양으로 closed=285 에 멎었다.
        #            Replace 가 한참 전에 끝나 예비가 이미 도착했는데도 뒤따르는 zone 사건이
        #            전부 NOOP 을 받아 `n_nav_blocked > 0` 이 수복되지 않았고, 이 게이트가
        #            막으려던 바로 그 교착이 **반대편에서** 생겼다(전역 이동으로 목표를 지워
        #            stall 하는 대신, 아무것도 안 해서 막힌 채로 stall).
        #
        #          ⇒ **고친 방식: `_recovery_in_transit(env)` (위 정의).** RECOVERY_SPARES 에
        #            "도착하면 뺀다" 경로를 넣는 쪽이 '진짜' 수정이지만 **그 집합은 oracle 만
        #            읽는 것이 아니다**: route_planning.jl:200(RVO alpha) · ood_injection.jl:869
        #            /918/968(고장 표적 선정) · navigator/battery.jl:440 · mdp/hazard.jl:453 ·
        #            replace_robot.jl:1070 이 전부 읽는다. 원소를 빼면 **모든 레인의 물리와 고장
        #            표적이 바뀌어** 이미 커밋된 630판 noop/surrogate/dspy 스윕이 조용히 무효가
        #            된다. 그래서 술어를 **oracle 레인 안에서만** 다시 계산한다(공유 상태 불변).
        #            새 술어의 뜻: "복구 임무 중인 로봇이 지금 **혼자 목표를 향해 오는 중인가**"
        #            (팀에 포획됐거나 제 몸 반경 안에 목표가 있으면 도착). 인계가 끝나면 스스로
        #            풀리므로 래치가 아니다.
        #
        #        아래 실측은 위 정정과 무관하게 유효하다(둘 다 Replace 직후의 zone 사건이다):
        #        2026-08-13 실측(seed 1, 같은 구역·같은 Δ=[-1.75984, -1.60557]):
        #          battery_zone: closed=58 에 SwapBattery(창고 왕복 없음) → RECOVERY_SPARES 빈 채로
        #                        closed=100 에 RelocateBuild → **완주 291/313** (30.3 s)
        #          fault_zone  : closed=58 에 Replace(:via_depot)         → closed=99 에
        #                        RelocateBuild → **stall 186/313** (2판 소수점까지 동일)
        #        두 판의 zone_primitives 는 n_teams_forming(3 vs 5) 말고 **전부 동일**하다
        #        (nav_goals 112 · nav_blocked 3 · root 0/8 · n_restage_feasible 0 · relocate_feasible).
        #        즉 구역 기하만으로는 두 사건을 구분할 수 없다 — 구분하는 것은 "빌드 밖에 돌아올
        #        로봇이 있는가" 라는 **상태**다. 복구 사다리로는 못 푼다(DEMO_REFORM_MAX 6 → 186,
        #        12 → 191, 둘 다 stall).
        #
        #     ⚠ 이 가지는 **reference_policy.py 와 의도적으로 갈린다.** 저쪽은 RECOVERY_SPARES 를
        #       볼 수 없어(요약의 zone_primitives 에 그 칸이 없다) 언제나 RelocateBuild 를 낸다.
        #       그래서 Replace 가 선행한 zone 사건에서 oracle 레인의 결정 적중률은 1.0 미만이 된다.
        #       그 값을 1.0 으로 되돌리려면 reference_policy.py 의 zone 규칙도 같이 고쳐야 하는데,
        #       그러면 이미 발행된 표의 decision_acc 열이 전부 조용히 재채점된다
        #       (build_md_report.py:417 이 같은 이유로 그 파일을 고정해 뒀다). 그래서 **여기만**
        #       고치고 갈림을 보고서에 명시한다.
        # `returning` = "복구 임무 중인 로봇이 지금 빌드 프레임 밖에서 돌아오는 중인가".
        # 도착하면 스스로 풀린다(래치 아님). 정의는 위 `_recovery_in_transit` 참조.
        local returning = _recovery_in_transit(env)
        (!returning && zdg.relocate_feasible && "RelocateBuild" in vm) && return "RelocateBuild"
        (zdg.n_restage_feasible > 0 && "ForbidZone" in vm) && return "ForbidZone"
        return "NOOP"
    end
    # reform 등: 실측 격자가 없어 a* 가 미정의다(reference_policy.py:208 이 unscored 로 뺀다).
    return canonical_macro(env, truth)
end

# ---- 통제 실험용 강제 매크로 -----------------------------------------------------------
# DEMO_FORCE_MACRO=<이름> 이면 **어느 정책이 실행되든** 그 매크로를 집행한다.
# 용도는 하나뿐이다: "결과가 갈린 이유가 매크로인가 정책인가"를 가르는 교차 대조
# (같은 매크로를 다른 정책이 내게 해서 세계가 같은지 본다). 강제 사실은 verdict 에 남긴다 —
# 기록이 "canonical 이 RelocateBuild 를 골랐다"로 읽히면 그게 곧 거짓말이 되기 때문.
const FORCE_MACRO = strip(get(ENV, "DEMO_FORCE_MACRO", ""))

# 🔴 2026-08-24 (Task 6 · 컨트롤러 판정 R-42): FORCE_MACRO 는 **메뉴와 대조된 적이 없었다.**
# `macro_to_proposal` 이 모르는 이름은 아래쪽에서 조용히 **빈 제안**으로 떨어지고
# (`policy.jl` 맨 아래 `return CB.RespecProposal(CB.ConstraintSpec[], ...)`) `enact_applied`
# 가 false 로 남는데, 그 판의 결정 기록에는 `forced_macro=<그 이름>` 과 `chosen=<그 이름>` 이
# 그대로 찍힌다 — 즉 **고르지 않은(집행되지 않은) 팔을 골랐다고 적힌 판**이 만들어진다.
# 축 C 로 어휘가 3팔이 되면서 `Deprioritize`(Task 5) · `ForbidZone`·`RelocateBuild`(Task 4)
# 세 이름이 전부 이 상태가 됐고, `tools/smdp/gate_g6.py` 의 머리말이
# `DEMO_FORCE_MACRO=Deprioritize DEMO_OOD=battery` 를 재현 레시피로 적어 두고 있다 — 가상의
# 조합이 아니라 도달 가능한 설정이다. 그래서 **읽는 자리에서 바로, 시끄럽게** 죽인다.
#
# 🔴 2026-08-24 리뷰 라운드 1 (Important #2): 이 목록은 처음에 리터럴 튜플이었고
# `ReformTeam` 을 포함했다 -- 그 이름은 `action_registry.json` 이 2026-08-20 에 **삭제**한
# 팔이라, `DEMO_FORCE_MACRO=ReformTeam` 이 검사를 통과한 뒤 실제로 집행돼(`macro_to_proposal`
# → `run_demo.jl` 의 `mac == "ReformTeam"` 분기) **어휘 도장이 v4-3arms 인 판에 어휘 밖 팔이
# 라벨로 박히는** 결과를 냈다. 리터럴은 레지스트리의 네 번째 진실원이었다.
# 그래서 **레지스트리에서 유도한다** — Task 2 가 세운 단일 진실원 그대로.
# 바인딩은 `test/policy_macro_binding.jl` 이 지킨다(runtests.jl 에 실려 있다). 그 게이트는
# 세 방향을 전부 잰다: 리터럴 복원 · 레지스트리에만 팔이 늘어난 경우(= `macro_to_proposal`
# 분기 누락) · 아래 두 손잡이 중 하나의 검사만 지운 경우. 셋 다 변형으로 RED 를 확인했다.
#
# ⚠️ **상수가 아니라 함수다.** 두 가지 이유:
#    (1) `ActionRegistry.is_active` 자체가 의도적으로 함수다 — experimental 게이트
#        (`DS_COMBO_ARMS`)를 **호출 시점**에 읽어야 하고, 상수로 접으면 로드 순서에 따라
#        플래그가 조용히 무시된다(action_registry.jl 의 `is_active` 독스트링). 그 함수를
#        상수로 스냅샷하면 여기서 그 계약을 되돌리는 셈이다.
#    (2) `const` 로 두면 `test/smdp_global_inventory.jl` 의 RHS 머리 census 가 새 머리
#        (`Tuple`)를 보고 죽는다 — 그 게이트를 통과시키려면 `src/smdp/state_globals.jl`
#        (이번 라운드에 손대지 못하게 묶인 파일)에 새 hunk 를 얹어야 한다. 함수 정의는
#        최상위 바인딩을 새로 만들지 않으므로 그 census 의 대상이 아니다(실측: 아래 두
#        게이트 모두 초록).
isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(@__DIR__, "..", "..", "src", "decision", "core", "action_registry.jl"))
enactable_macros() = Tuple(ActionRegistry.NAME[i] for i in ActionRegistry.active_ids())
if !isempty(FORCE_MACRO) && !(FORCE_MACRO in enactable_macros())
    error("DEMO_FORCE_MACRO=\"$(FORCE_MACRO)\" 는 집행 가능한 매크로가 아니다 — 현행 메뉴는 " *
          join(enactable_macros(), " · ") * ". 모르는 이름은 빈 제안으로 떨어져 집행은 안 되는데 " *
          "결정 기록에는 '그 팔을 골랐다' 고 남는다(= 거짓 라벨). 오타/구세대 이름을 의심하라.")
end

# ---- 1-step deviation (DP 표집 전용) ---------------------------------------------------
# DS_DEVIATE_AT=k · DS_DEVIATE_ARM=<이름> 이면 **k 번째 결정에서만** 그 팔을 집행하고
# 나머지 결정은 실행 정책(canonical)이 고른 것을 그대로 쓴다.
#
# 왜 FORCE_MACRO 와 따로 두는가: FORCE_MACRO 는 판 전체를 덮는 통제 실험용이고, 그 의미는
# 그대로 남겨야 한다(기존 교차 대조가 그걸 쓴다). 여기서 조건을 붙이면 그 용도가 조용히
# 바뀐다. 두 손잡이가 동시에 켜지면 예외를 던진다 — 어느 쪽이 이겼는지 모르는 판을 만드는
# 것이 이 표집에서 제일 비싼 실패다.
#
# DS_DEVIATE_AT 파싱은 **끄는 것과 오타 낸 것이 같은 코드 경로여선 안 된다.** 이 레포에는
# 정확히 이 모양의 폴백(파싱 실패를 조용히 기본값으로 삼는 것)이 DS_HOTSWAP 하나만 빠뜨려도
# fault 발화율을 100%→23% 로 조용히 무너뜨린 전례가 있다(CLAUDE.md 2026-08-16). 빈 문자열/
# 미설정만 정상 OFF 다. 그 외(정수로 안 읽히는 값·0·음수)는 죽는다 — `something(tryparse(...), 0)`
# 은 그 셋을 전부 "OFF" 로 뭉갠다.
const _DEVIATE_AT_RAW = get(ENV, "DS_DEVIATE_AT", "")
const DEVIATE_AT = if isempty(_DEVIATE_AT_RAW)
    0
else
    local _v = tryparse(Int, _DEVIATE_AT_RAW)
    (_v === nothing || _v <= 0) &&
        error("DS_DEVIATE_AT=\"$(_DEVIATE_AT_RAW)\" 는 정수로 파싱되지 않거나 0 이하다 — " *
              "손잡이를 끄려면 아예 미설정/빈 문자열로 둬라.")
    _v
end
const DEVIATE_ARM = strip(get(ENV, "DS_DEVIATE_ARM", ""))

# 🔴 2026-08-24 (Task 6, 컨트롤러 판정 R-44): `FORCE_MACRO` 와 **정확히 같은 구멍**이 여기에도
# 있었다. 위 파싱 게이트는 `DS_DEVIATE_AT` 의 오타만 잡고 `DS_DEVIATE_ARM` 의 **이름**은 메뉴와
# 대조하지 않는다. 모르는 이름은 `macro_to_proposal` 에서 빈 제안으로 떨어져 집행이 안 되는데
# `should_deviate` 는 그 결정을 "deviated" 로 표시한다 — DP 표집이 **일어나지 않은 이탈**을
# 표본으로 삼게 된다. 같은 `enactable_macros()` 로 같은 자리에서 죽인다.
if !isempty(DEVIATE_ARM) && !(DEVIATE_ARM in enactable_macros())
    error("DS_DEVIATE_ARM=\"$(DEVIATE_ARM)\" 는 집행 가능한 매크로가 아니다 — 현행 메뉴는 " *
          join(enactable_macros(), " · ") * ". 모르는 이름은 빈 제안으로 떨어져 집행은 안 되는데 " *
          "그 결정은 '이탈했다' 고 표본에 남는다(= 거짓 라벨). 오타/구세대 이름을 의심하라.")
end

# ARM 만 있고 AT 이 없으면 언제나 설정 실수다(어느 결정에서 갈아 쓸지가 없다) — 조용한 완전
# canonical 판으로 새지 않게 여기서 잡는다.
!isempty(DEVIATE_ARM) && DEVIATE_AT <= 0 &&
    error("DS_DEVIATE_ARM=\"$(DEVIATE_ARM)\" 만 설정되고 DS_DEVIATE_AT 이 없다 — " *
          "그 조합은 언제나 설정 실수로 본다.")

if !isempty(FORCE_MACRO) && DEVIATE_AT > 0
    error("DEMO_FORCE_MACRO 와 DS_DEVIATE_AT 를 같이 켤 수 없다 — 집행 규칙이 둘이 된다.")
end

# 이 프로세스(=이 판)가 어느 레인인지 board.log 각각이 스스로 말하게 한다.
@info (DEVIATE_AT > 0 ? "[policy] deviation ON: at=$(DEVIATE_AT) arm=$(DEVIATE_ARM)" :
                        "[policy] deviation OFF (DS_DEVIATE_AT unset)")

const _DECISION_N = Ref(0)
_reset_decision_counter!() = (_DECISION_N[] = 0)
_next_decision_index!()    = (_DECISION_N[] += 1; _DECISION_N[])

"""
    should_deviate(at, arm, idx) -> String | nothing

`idx` 번째 결정에서 집행을 `arm` 으로 갈아쓸지. 갈아쓰지 않으면 `nothing`.
순수 함수다 — env·시뮬레이터 없이 검사된다(2026-08-14 의 `escalation_target` 과 같은 이유).
"""
should_deviate(at::Int, arm::AbstractString, idx::Int) =
    (at > 0 && !isempty(arm) && idx == at) ? String(arm) : nothing

# ConstraintSpec 타입 이름 → 매크로 이름 정규화(ReplaceAgent → Replace 등).
_macro_label(s) = s == "ReplaceAgent" ? "Replace" :
                  s == "ForbidZone" ? "ForbidZone" :
                  s == "ReformTeam" ? "ReformTeam" : s

"""
    escalation_target(pol, requested, allowed) -> (target::String, missing::Vector{String})

**표현력 격상** 판정. `requested` 정책이 이 사건의 유효 매크로 중 일부를 **표현조차 못 하면**
(학습 근거 0) LLM 으로 올린다. `target` 이 `"dspy"` 면 격상, `""` 면 그대로 둔다.

왜 순수 함수로 뽑았는가 (2026-08-14)
------------------------------------
이 판정이 `decide_all` 안에 인라인으로 있는 동안에는 env·truth·파이썬 서비스가 전부 살아
있어야만 검사할 수 있었고, 그래서 **한 번도 검사되지 않았다**. 그 사이 조건이
`pol[enacted]["available"]` 를 요구한 채로 남아 회귀가 조용히 들어왔다:
surrogate 가 "개입 후보가 전멸했다"(UNSUPPORTED)를 알리는 방법은 빈 chosen 이라
`available=false` 이고, 그러면 `enacted` 는 이 판정 **전에** 이미 canonical 로 떨어져 있다.
`pol["canonical"]` 에는 `unsupported` 키가 없으므로 게이트는 영원히 안 열렸다 —
격상이 존재하는 이유가 바로 그 사건인데도. 순수 함수면 Dict 만으로 검사된다
(`tools/test_policy_escalation.jl`).

판정 기준은 **요청된** 정책이다(enacted 가 아니다). 못 골라서 아예 못 쓰는 것은 격상의
**더 강한** 근거이지 약한 근거가 아니므로, `available` 은 요구하지 않는다.
"""
function escalation_target(pol, requested, allowed)
    haskey(pol, requested) || return ("", String[])
    local missing = String.(collect(get(pol[requested], "unsupported", String[])))
    isempty(missing) && return ("", String[])
    (allowed && requested != "dspy" &&
     haskey(pol, "dspy") && pol["dspy"]["available"]) || return ("", missing)
    return ("dspy", missing)
end


"""
    surrogate_support_measured(surro_entry, missing) -> Bool

surrogate 가 이 사건에서 **지원집합을 실제로 쟀는가**. 순수 함수다 — Dict 하나와 벡터 하나만
본다(`escalation_target` 과 같은 이유로 뽑았다: `decide_all` 안에 인라인이면 env·truth·파이썬
서비스가 전부 살아 있어야만 검사할 수 있고, 그래서 검사되지 않는다).

🔴 왜 필요한가 (2026-08-27, 최종 리뷰 F4). `supported = isempty(missing)` 은 Bool 하나라
**두 사건이 같은 값(true)으로 무너진다**:

```
지원집합 UNKNOWN(모델 미적재/서비스 부재) → unsupported=[] → supported=true → axis="none"
진짜로 전부 지원                          → unsupported=[] → supported=true → axis="none"
```

앞의 것은 축 1 이 **자기가 존재하는 이유인 그 실패 모드에서 스스로를 과소 집계**하는 것이다.
Task 4(`bdb0bdda`)가 파이썬에서 죽인 `set(range(5))` 붕괴가 언어 경계에서 그대로 살아 있었다:
파이썬의 3값 신호(`None` 못 쟀다 / `[]` 재서 없다 / `[이름]` 미달)가 `/decide` JSON 에서
뭉개져 나가고 Julia 는 `unsupported` 만 읽는다. Ruling R13 에 따라 `select_lane` 의 axis enum 은
**안 바꾸고**(그것은 Task 2 의 계약이자 하류 소비처의 계약이다) 구분을 **기록에** 남긴다.

판정은 **문자열 매칭이 아니라 구조**로 한다 — 에러 문구가 바뀌어도 안 깨진다:

  · `available == true` ⟹ 점수를 냈다 ⟹ 지원집합이 `None` 이 아니었다
    (`surrogate_rank` 는 `support is None` 이면 점수를 내기 전에 되돌아간다) ⟹ **쟀다**
  · `missing ≠ ∅`      ⟹ `UNSUPPORTED:` 규약이 나왔다 ⟹ 지원집합을 읽었다 ⟹ **쟀다**
  · 그 외(서비스 부재 · "support is unknown") ⟹ **못 쟀다**

✅ 2026-08-28(`ce48c1ce`) 고쳐짐: 서비스의 `if not scorable` 분기("no training support for any
valid macro")는 지원집합을 **읽었는데도** `UNSUPPORTED:` 접두사를 안 붙여 `/decide` 가
`unsupported: []` 를 싣는 문제가 있었다 — 그 사건이 여기서 "못 쟀다" 로 잘못 기록됐다(안전한
방향이지만 부정확). 지금은 `unsupported` 가 비지 않았으면 그 분기도 `UNSUPPORTED:` 규약을
그대로 낸다(`dspy_service.surrogate_rank`). 남은 경우는 `valid` 의 모든 이름이 레지스트리에
아예 없는(등록 안 된 매크로) 사건뿐이고, 그건 "지원 안 됨"과는 다른 사건이라 규약 밖 메시지를
유지한다 — 이 파일이 읽는 `missing ≠ ∅ ⟹ 쟀다` 계약과 여전히 합치한다(그 경우
`missing == ∅` 이므로 위 계약이 적용될 사건 자체가 없다).
"""
surrogate_support_measured(surro_entry, missing) =
    (get(surro_entry, "available", false) === true) || !isempty(missing)


"""
    TOOL_LANE_KEYS

DSPy 서비스가 `/decide` 의 `dspy` 본체에 싣는 **tool 레인 키 전부**
(`src/respec/llm_service/dspy_service.py` 의 `macro()` 반환 dict `:1029-1073`,
그리고 `/decide` 가 그것을 `out["dspy"]` 로 옮기는 `:1103-1107`).

🔴 목록을 두 벌 두지 않는다. `policy_entry` 의 **두 분기**와 `decide_all` 의 `tool_lane`
노출이 전부 이 하나를 읽는다 — 손으로 든 키 목록이 갈리는 것이 이 배선이 애초에 없었던 이유다
(`service_decide` 위 2026-08-29 정정 블록 참조).

🔴 **그래도 언어 경계에는 두 벌이 남는다** (2026-08-29 수정 라운드, F1). 위 튜플은 파이썬이
내는 이름의 **손으로 쓴 사본**이고, 파이썬에서 키를 이름 바꾸면 그 값은 여기서 조용히
`nothing`("못 쟀다")으로 도착한다 — 양쪽 게이트가 **전부 초록인 채로**. 그래서
`test/tool_lane_keys_survive.jl` 의 (5)절이 `.venv/bin/python` 으로 `dspy_service.py` 의
`out["dspy"]` dict 리터럴을 **AST 로 읽어** 이 튜플과 대조한다. `tools/test_policy_oracle.jl`
0절(`ORACLE_BATTERY_DEEP_SOC` ↔ `reference_policy.BATTERY_DEEP_SOC`)이 같은 자리에 이미
있는 같은 모양의 계약이다. 🔴 그 절은 파이썬에 못 닿으면 **skip 이 아니라 빨개진다** —
skip 은 같은 구멍에 단계만 더한 것이다.
"""
const TOOL_LANE_KEYS = ("tool_called", "tool_args", "tool_calls_n", "tools_offered",
                        "expressible", "native_fc", "tool_lane_error", "macro_tool_agree",
                        # ---- 2026-09-02 (귀속용 두 번째 질문) --------------------------------
                        # `expressible` 은 **NOOP 을 뺀** 메뉴를 묻고 이것은 **메뉴 전체**를
                        # 묻는다(옛 문구 그대로). 둘의 차이가 곧 "메뉴 artifact 의 크기" 다.
                        # 🔴 측정 전용 — 결정에는 안 쓴다. 그래도 결정 행에 실어야 사후에
                        # 층화해 읽을 수 있다.
                        "menu_expressible",
                        # ---- 2026-08-29 (Plan B / T-C): 레짐 표식과 그 대가 ------------------
                        # `tool_choice`  = 이 요청의 **첫 시도**에 실제로 실린 값
                        #                  (`"required"` | `"auto"` | … | `nothing` = 안 보냈다).
                        #                  🔴 이것 없이 거절률(C8 ②)을 세면 두 레짐의 행이 한
                        #                  표에 섞인다 — 강제 판에서 ②는 원리상 관측되지 않는다.
                        "tool_choice",
                        # ---- 2026-08-29 (단일 채널 / T6) ------------------------------------
                        # 🔴 `text_rescue` 는 **여기서 사라졌다.** 그 값이 주장하던 사건(강제가
                        #   텍스트 채널을 비웠고 2차 호출로 되찾았다)이 이 설계에 없다 — T3 이
                        #   텍스트 `OutputField` 다섯을 전부 지웠으므로 **되찾을 채널 자체가
                        #   없고**, T4 가 구제 코드와 그 키를 파이썬에서 지웠다. 옛 녹화의
                        #   `text_rescue` 열은 그대로 남는다(세대가 갈린 열이다) — 새 행과 한
                        #   표에 섞지 말 것.
                        #
                        # `decision_source` = "tool" | "no_tools" | "no_call".
                        #   🔴 **두 실패를 한 값으로 접지 않는다.** `no_tools` 는 우리가 메뉴를
                        #   못 만든 것이고 `no_call` 은 프로바이더가 `required` 계약을 어긴
                        #   것이다 — 원인도 대응도 다르다.
                        #   🔴 이 키의 **존재 자체**가 세대 표식이다: 없는 행은 이 설계
                        #   이전의 것이고, `macro_tool_agree` 와 `expressible` 이 다른 양을
                        #   재고 있으므로 한 표에 섞으면 안 된다.
                        #   ⚠️ `no_call` 은 **세 하위 사건**을 덮는다(T4 §0-B ⑪-a). 그 셋을
                        #   가르는 것은 `error` · `tool_lane_error` · `tool_calls_n` 이고,
                        #   그중 빈 응답 `AdapterParseError` 는 `tool_lane_error` 로 온다
                        #   (`error` 는 프로바이더 장애 전용이다 — spec §5-1).
                        # `tool_arg_error` = 인자 접지 실패 사유(`nothing` 이면 성공).
                        #   집행에서 뺀 이유가 R26(`expressible=false`)인지 접지 실패인지를
                        #   이 키가 가른다 — 둘 다 `tool_called === nothing` 이다.
                        #   🔴 **이 문자열로 실패 종류를 세지 말 것**(§0-B ④): 파이썬
                        #   `check_tool_args` 는 **처음 걸린 사유 하나만** 내고
                        #   `agent_outside_enum`(F10)이 순서상 마지막이라, 두 축이 동시에
                        #   틀리면 F10 은 보고되지 않는다 ⟹ 항상 과소집계다. 축마다 따로 셀 것.
                        #   🔴 그리고 `=== nothing` 을 "접지 성공" 으로 읽지 말 것(§0-B ⑤):
                        #   규약대로 만들어진 `no_intervention` 호출도 `nothing` 이다(접지할
                        #   것이 없다). 줄리아의 `ground_tool_args` 는 같은 호출에
                        #   `deferred:no_groundable_param` 을 낸다 — 두 레인이 같은 이름의
                        #   비율을 **다른 분모**로 계산하게 된다.
                        "decision_source", "tool_arg_error")

"""
    SYNTH_LANE_KEYS

DSPy 서비스가 `# ---- 합성 레인 (T2, Plan B / T6b)` 표식 **위**에 싣는 키 전부
(`src/respec/llm_service/synthesize.py` 의 `run_synthesis` → `synthesize_multi` 반환 dict,
그리고 `macro()` 의 최상위 `tool_minted`).
🔴 2026-09-03 정정: 예전 문구는 `maybe_synthesize` 를 가리켰는데 그 함수는 D8 로 **삭제됐다**
(`test_no_inventory.py` 가 부재를 지킨다). 입구는 `run_synthesis` 하나이고 **분기가 없다**.

🔴 **아홉이다, 여덟이 아니다** (2026-08-30 정정, T1). 애초 계획서에는 `params` 가 빠져 있었다 —
그 값이 없으면 T3/T4 의 인터프리터가 신설 도구의 원시연산에 넘길 키워드 인자를 못 받아,
`nothing` 인자로 원시연산을 부르다 던지는데 그 예외가 "성공" 으로 잘못 집계된다. 서비스는
`params` 를 성공 경로에서 이미 `synthesis` dict 안에 정확히 이 이름으로 싣고 있었다(실측).

🔴 **열이다** (2026-09-03, B1). `params` 는 실제로는 **값이 아니라 JSON 스키마**로 도착한다
(`{"agent": {"type": "string"}}`) — 그리고 도구 하나에 dict 하나라서 body 가 원시 둘 이상이면
어느 인자가 어느 원시의 것인지도 안 적힌다. `calls` 는 agent-3 이 body 와 **같은 순서로** 내는
`[{"primitive": ..., "args": {...}}]` 이고, 원시마다 자기 인자를 값으로 들고 온다.
🔴 2026-09-03 정정: `params` 를 남기는 근거가 예전엔 "단일 agent 레인이 이 키로 계속 도착한다"
였는데 **그 레인은 D8 로 삭제됐다**. 오늘의 근거는 둘이고 둘 다 현행 코드다 —
(a) `params` 는 등록 행의 **타입 스키마**다(`register_minted_primitive!(params=…)` →
    `bind_primitive_args` 의 `_param_type_reject` 가 그것을 읽는다). `calls` 는 값이지 스키마가
    아니므로 이 역할을 대신 못 한다.
(b) `calls` 가 `nothing` 인 판(이 필드를 아직 안 싣는 서비스 세대)에서 `enact_minted!` 이
    `params` 로 폴백하고 그 사실을 `args_from = :params` 로 기록한다.

🔴 `TOOL_LANE_KEYS` 와 **별개의 튜플이다.** 섞으면 `test/tool_lane_keys_survive.jl` (6)절이
정당하게 빨개진다 — 그 게이트는 파이썬 표식 **아래** 집합만 본다.

🔴 값의 출처가 둘이다. `tool_minted` 는 응답 최상위(`macro()` 의 반환 dict), 나머지 **아홉**은
`response["synthesis"]` 안이다(2026-09-03 정정: `calls` 가 들어오면서 여덟이 아홉이 됐다). 한 벌로 뭉개면 "합성 레인이 안 돌았다"(dict 자체가 없다)와
"돌았는데 값이 없다"(dict 안이 nothing)가 구분 불가능해진다.

🔴 이 열이 **항상 함께 도착하는 것이 아니다.** `synthesize_multi` 의 탈출 경로는
**여덟**이다(2026-09-03 재실측 두 번째 — "다섯" 은 삭제된 `maybe_synthesize` 의 숫자였고,
"일곱" 은 G1 거절이 들어오기 직전의 숫자다). 소스 순서로 이른 반환 일곱 —
(1) 플래그 꺼짐(`tool_minted="disabled"`) · (2) 🔴 G1 거절(`refused="no_compose_interface"`,
과금 0건이라 `stages==[]`) · (3) observe 실패 · (4) design 실패 · (5) redesign 실패 ·
(6) `expressible is not False`(발화 사건이 아니다) · (7) compose 실패 — 과 정상 종료
하나(`_finish_record`)다. 상세를 다 채우는 것은 마지막 하나뿐이고, 나머지 일곱은
`synthesis_event`·`synthesis_ran`·`synthesis_error`(또는 `refused`) 정도만 채운 채 나머지를
`nothing` 으로 남긴다.

⚠️ **`return` 문의 개수가 곧 탈출 경로의 개수가 아니다.** 그 함수 안의 `return` 은 아홉인데
하나는 중첩 클로저 `_design` 의 것이라 `synthesize_multi` 에서 나가지 않는다. `raise` 는
0개이고 마지막 문이 `return` 이라(암묵적 낙하 없음) 여덟이 전부다 — AST 로 셌고,
`test_synthesis_record_contract.py` 의 `test_the_exit_paths_helper_covers_every_semantic_exit`
가 그 수를 코드로 못박는다. 그 부재는 여기서도 "못 쟀다"(spec §9-2)로 그대로 nothing 이
된다 — 흔한 실행 경로이지 예외가 아니다.

🔴 **2026-09-03 (Task 9): `reach`·`missing_primitive` 를 빼고 다섯을 더했다.** agent-3 은
이제 인벤토리에서 조합하는 대신 **원시 자신을 Julia 코드로 쓴다**(D8) — "조합했는가" 를 재던
`reach`/`missing_primitive` 는 더 이상 나는 사실이 없고, 대신 나르는 것은 `impl_name`·
`impl_code`·`surface`·`reversible`·`wrote` 다섯이다. 위 문단들의 "아홉"·"열"·"reach"·
"missing_primitive" 서술은 그 이전 세대(조합 레인)를 가리키고, 지우지 않은 것은 이 파일의
역사 규약 때문이다.
🔴 **2026-09-04 (Wave A, W5): `mechanism` 이 들어왔다.** 이 키는 파이썬 기록에는 **처음부터
있었는데**(`synthesize.py` 의 `_SPEC_FIELDS = ("tool_name", "params", "mechanism")`) 이 튜플에
없어서 `_synth_view` 가 아예 안 실었다. 그 대가는 하나였고 컸다 — `enact.jl::_rewrite_once` 가
`/rewrite` 에 싣는 `spec` 이 **생산 경로에서 언제나 빈 문자열**이었다(Task 9 실측: 가짜 서버가
받은 payload 의 `spec` = `''`). 즉 D17 의 되먹임은 agent-3 에게 **명세 없이** "이 거절을
고쳐라" 를 보내고 있었고, 그 판의 실패율은 모델이 아니라 우리 배선의 수치다.
⚠️ 이 키는 `params` 와 **다른 것**을 나른다: `params` 는 등록 행이 읽는 타입 스키마이고
`mechanism` 은 agent-2 가 고른 **기전 산문**이다. 소비자도 다르다(전자는
`register_minted_primitive!`, 후자는 `/rewrite` 의 `spec`).

🔴 **2026-09-03 최종 리뷰 정정.** 여기 "이 다섯은 `register_minted_primitive!` 가 그대로 받는
키워드 이름과 같다 — 진실원 하나" 라고 적혀 있었는데 **다섯 중 셋이 거짓**이다. 그 함수의
키워드는 `name`·`code`·`params`·`surface`·`reversible` 이고, `impl_name`/`impl_code` 는
호출부(`enact.jl`)에서 `name =`/`code =` 로 **개명돼** 넘어가며 `wrote` 는 애초에 그 함수의
인자가 아니다. 실제로 이름이 같은 것은 `surface`·`reversible` 둘뿐이다. 개명이 일어나는
자리는 `enact_minted_decision!` 의 `CB.register_minted_primitive!(...)` 호출 **하나**이고,
그 한 자리가 이 경계 이름과 등록 키워드 사이의 유일한 사전이다.

🔴 **`wrote` 는 오늘 줄리아 소비자가 "결정에 쓰는" 자리가 없다** — 경계를 건너는 이유는
관측이다: 조기 반환 갈래(`impl_name === nothing`)의 `[minted]` 줄이 그것을 찍어
"agent-3 이 못 쓰겠다고 자기신고했다"(`false`)와 "그 필드를 못 읽었다"(`nothing`)를
가른다. 그 갈래에서 이미 찍는 `synthesis_event`·`synthesis_ran`·`synthesis_error`·
`tool_minted` 와 **같은 목적, 같은 자리**다. 판정에 안 쓰이므로 `enact.jl` 의 게이트는
`impl_name` 하나로 남는다(미끼를 둘로 늘리지 않는다).

🔴 **`refused` 도 건넌다** (2026-09-03 최종 리뷰). G1 거절(`"no_compose_interface"` ·
`"world_interface_unreadable: …"`)은 **돈을 쓰기 전에 돌아선 사건**인데, 이 키가 없으면
줄리아 쪽에서 그 판이 `synthesis_event=false, synthesis_ran=false` 로 도착해
"발화할 사건이 아니었다" 와 **바이트 동일**해진다 — 처방이 정반대인 두 사건이다(하나는
`world_interface.json` 을 고쳐야 하고 하나는 아무것도 안 해도 된다). 삼상이다:
`nothing`(가드가 안 돌았다) · `false`(돌았고 통과) · 문자열(사유). jsonl 에 남기는 것만으로는
부족한 이유는 라이브 판정이 렌더 로그로 이뤄지기 때문이다.

🔴 **`tool_minted` 는 전선에 두 번 실린다** (2026-09-03 최종 리뷰 정정). 위 "값의 출처가
둘이다" 문단은 이 키가 응답 **최상위에만** 있는 것처럼 적지만, `synthesis` dict **안에도**
같은 값이 있다(`dspy_service.py` 의 `/macro` 반환이 `"tool_minted": synthesis["tool_minted"]`
로 최상위 사본을 만든다). 진실원은 **합성 기록 안의 것**이고 최상위는 그 투영이다 —
`_synth_view` 는 최상위만 읽고(`k == "tool_minted" && continue`) 안쪽 사본은 안 읽으므로
줄리아 쪽에서 둘이 갈릴 자리는 없다. 사본이 사는 이유는 `TOOL_LANE_KEYS` 와의 경계
문단이 적는 그대로다(`out["dspy"]` 의 표식 위에 있어야 한다).

🔴 **2026-09-22 `record_id`·`response_id`** — 서비스가 원장 `/decide` 행에 찍은 두 id 이고
`synthesis` dict 안에 실려 온다. `record_id` 는 줄리아가 발급한 논리 요청 id(`new_record_id`)의
되돌림이고, `response_id` 는 서버가 **처리마다** 새로 발급한다 — HTTP 재전송은 같은
`record_id` 로 서로 다른 body 를 만들 수 있으므로 실제로 받은 응답은 그 **쌍**으로 특정한다.
집행부는 둘을 판정에 쓰지 않는다 — `record_id` 는 `/rewrite` 의 `parent_record_id` 로 나른다
(재시도 사슬의 조인 키; 그 배선은 Task 5 다).
파이썬 쪽은 `synthesize.py::_blank` 가 둘을 `None` 으로 선언한다(교차언어 게이트가 거기를 읽는다).
"""
const SYNTH_LANE_KEYS = ("tool_minted", "synthesis_event", "synthesis_ran", "synthesis_error",
                         "refused",
                         "tool_name", "mechanism", "body_names", "params", "calls",
                         "impl_name", "impl_code", "surface", "reversible", "wrote",
                         "record_id", "response_id")

# `synthesis` dict 안의 키 이름 → 결정 행의 키 이름. 이름이 다른 둘만 적는다
# (`ran`→`synthesis_ran`, `error`→`synthesis_error`). 나머지는 같은 이름이다(`params` 포함).
const _SYNTH_RENAME = Dict("synthesis_ran" => "ran", "synthesis_error" => "error")

"""
    _synth_view(resp) -> Dict{String,Any}

응답에서 합성 레인 키를 전부 뽑는다(`SYNTH_LANE_KEYS`, 오늘 열넷). `resp === nothing`
(레인 실패)이거나 합성 dict 이 없으면 전부 `nothing` 이다 — **키는 언제나 존재한다.**
🔴 개수를 여기 숫자로 다시 적지 않는다(이 파일에서 그 숫자가 세 번 낡았다) — 정본은
`SYNTH_LANE_KEYS` 튜플 자신이고 이 함수는 그것을 순회한다.

🔴 **`Symbol` 키로 읽는다, `String` 이 아니다** (2026-08-30, 전체 스위트 실측으로 잡음).
`tool_lane_fields`(바로 아래)와 같은 이유다: `tools/test_policy_escalation.jl` 의 `avail()` ·
`unavail()` 은 `policy_entry` 를 서비스 응답이 아니라 **NamedTuple** 로 부르고
(`policy_entry` 의 docstring 이 그 계약을 적는다: `get(b, :key, default)` 만 쓰므로 NamedTuple
로도 부를 수 있다), `get(::NamedTuple, ::String, default)` 는 메서드가 없다 — 처음 이 함수를
String 키로 짰을 때 전체 스위트가 바로 그 자리에서 `MethodError` 로 죽었다(실측). `JSON3.Object`
는 `Symbol`·`String` 둘 다 받으므로 `Symbol` 로 통일해도 그쪽은 잃는 것이 없다.
"""
function _synth_view(resp)
    d = Dict{String,Any}(k => nothing for k in SYNTH_LANE_KEYS)
    resp === nothing && return d
    d["tool_minted"] = get(resp, :tool_minted, nothing)
    s = get(resp, :synthesis, nothing)
    s === nothing && return d
    for k in SYNTH_LANE_KEYS
        k == "tool_minted" && continue
        src = get(_SYNTH_RENAME, k, k)
        d[k] = get(s, Symbol(src), nothing)
    end
    return d
end

# =============================================================================
# 🔴 시험 전용 오라클 우회 — `DEMO_SYNTH_FIXTURE` (2026-09-05)
# =============================================================================
"""
    SYNTH_FIXTURE_PATH

`DEMO_SYNTH_FIXTURE` env. 비어 있으면(기본) 이 파일은 **바이트 동일하게** 오늘과 같이
동작한다 — 아래 `synth_fixture_lane` 이 첫 줄에서 그대로 돌려준다.

🔴 **이것은 시험 장치이지 레인이 아니다.** 값이 켜진 런의 합성 레인은 모델이 쓴 것이
아니라 사람이 쓴 픽스처다. 그 사실이 로그와 산출물 양쪽에 남지 않으면 다음 세션이
오라클 런을 유료 런으로 읽는다 — 이 레포에 기록된 가장 나쁜 실패 모양이다. 그래서
이 손잡이는 **조용할 수 없게** 지어져 있다:
  · 파일을 못 읽으면 `error` 로 **런을 죽인다**(조용한 폴백 금지 — 폴백하면 그 런은
    "모델이 아무것도 안 냈다" 와 바이트 동일해진다).
  · 결정마다 배너를 stdout 에 찍는다.
  · `rt["synth_fixture"]` 로 라우터 기록(= 결정 행)에 경로와 해시를 남긴다.

🔴 **규약을 하나도 안 느슨하게 한다.** 픽스처는 `enact_minted_decision!` →
`register_minted_primitive!` → `check_impl_conventions` 를 모델의 출력과 **같은 코드로**
지난다. 통과 못 하면 그것이 관측이다.
"""
const SYNTH_FIXTURE_PATH = get(ENV, "DEMO_SYNTH_FIXTURE", "")

"""
    SYNTH_FIXTURE_KINDS

`DEMO_SYNTH_FIXTURE_KINDS`(쉼표 구분, 예: `zone`). 비어 있으면(기본) `nothing` 이고 픽스처는
오늘처럼 **모든 결정**에 꽂힌다 — 게이트 이전의 적용 범위와 실행 경로를 그대로 유지한다
(`synth_fixture_lane` 의 새 분기는 `SYNTH_FIXTURE_KINDS === nothing` 이면 안 탄다).

값이 있으면 픽스처는 `routing_kind`(앞의 `unknown:` 을 뗀 것)가 이 집합에 드는 결정에만 꽂힌다.
왜 (2026-09-22, R2b): 혼합 케이스(`all3` = fault+battery+zone)에서 합성은 zone 에서만 일어났다
(스윕 60판: BATTERY·FAULT 는 surrogate 매크로, ZONE 만 dspy+합성). 게이트가 없으면 zone 수리
body 가 battery·fault 결정에도 등록·집행되고, `handled` 가 그 결정의 SwapBattery/Replace 를
건너뛴다 — 스윕에 없던 개입이 생긴다.
"""
const SYNTH_FIXTURE_KINDS = let s = strip(get(ENV, "DEMO_SYNTH_FIXTURE_KINDS", ""))
    isempty(s) ? nothing : Set(String.(strip.(split(s, ","; keepempty = false))))
end
(SYNTH_FIXTURE_KINDS !== nothing && isempty(SYNTH_FIXTURE_PATH)) &&
    error("[synth-fixture] DEMO_SYNTH_FIXTURE_KINDS 가 켜졌는데 DEMO_SYNTH_FIXTURE 가 비었다")

"""
    synth_fixture_lane(sl, rt) -> Union{Nothing,Dict{String,Any}}

`sl`(생산 경로가 만든 합성 레인) 위에 픽스처 파일의 값을 덮어 돌려준다. 손잡이가
꺼져 있으면 `sl` 을 **그대로** 돌려준다(무동작).

픽스처 파일은 JSON 객체 하나이고, `SYNTH_LANE_KEYS` 에 있는 키만 읽힌다(그 밖의 키는
무시되고 그 사실이 배너에 찍힌다). 오늘 쓰는 것은 `impl_name`·`impl_code`·`params`·
`calls`·`surface`·`reversible`·`body_names`·`tool_name` 이다.
"""
function synth_fixture_lane(sl, rt = nothing)
    isempty(SYNTH_FIXTURE_PATH) && return sl
    if SYNTH_FIXTURE_KINDS !== nothing
        # 🔴 조용히 못 가르면 죽는다 — 게이트를 요구한 런이 게이트 없이 돌면 all3 재생이 무효다.
        rt === nothing && error("[synth-fixture] DEMO_SYNTH_FIXTURE_KINDS 게이트에는 rt(routing_kind)가 필요하다")
        local rk = String(get(rt, "routing_kind", ""))
        if !(replace(rk, r"^unknown:" => "") in SYNTH_FIXTURE_KINDS)
            println("[synth-fixture] gated OFF — routing_kind=", rk, " ∉ ", sort(collect(SYNTH_FIXTURE_KINDS)))
            rt["synth_fixture"] = Dict{String,Any}("gated_off" => true, "routing_kind" => rk)
            return sl
        end
    end
    local raw
    try
        raw = read(SYNTH_FIXTURE_PATH, String)
    catch e
        # 🔴 조용히 폴백하지 않는다. 픽스처를 요구한 런이 픽스처 없이 도는 것은
        #    "모델이 아무것도 안 냈다" 와 로그로 구별이 안 된다.
        error("[synth-fixture] DEMO_SYNTH_FIXTURE='$(SYNTH_FIXTURE_PATH)' 를 못 읽었다: " *
              first(split(sprint(showerror, e), "\n")))
    end
    local fx = try
        JSON3.read(raw)
    catch e
        error("[synth-fixture] '$(SYNTH_FIXTURE_PATH)' 가 JSON 객체가 아니다: " *
              first(split(sprint(showerror, e), "\n")))
    end
    local d = sl === nothing ? Dict{String,Any}(k => nothing for k in SYNTH_LANE_KEYS) :
              Dict{String,Any}(sl)
    local used = String[]
    for k in SYNTH_LANE_KEYS
        haskey(fx, Symbol(k)) || continue
        d[k] = fx[Symbol(k)]
        push!(used, k)
    end
    local ignored = [String(k) for k in keys(fx) if !(String(k) in SYNTH_LANE_KEYS)]
    local digest = bytes2hex(SHA.sha256(raw))[1:16]
    # ---- 배너. 매 결정마다, 무조건 ------------------------------------------------------
    println("=" ^ 78)
    println("🔴🔴🔴 [synth-fixture] ORACLE BYPASS ACTIVE — 이 판의 합성 레인은 **모델이 쓴 것이 아니다**")
    println("🔴 path=", SYNTH_FIXTURE_PATH, "  sha256[1:16]=", digest)
    println("🔴 impl_name=", repr(get(d, "impl_name", nothing)),
            "  body_names=", repr(get(d, "body_names", nothing)),
            "  surface=", repr(get(d, "surface", nothing)),
            "  reversible=", repr(get(d, "reversible", nothing)))
    println("🔴 keys_overridden=[", join(used, ", "), "]",
            isempty(ignored) ? "" : "  keys_ignored_not_in_SYNTH_LANE_KEYS=[" * join(ignored, ", ") * "]")
    println("🔴 규약 검사·타입 검사·게이트는 **하나도 완화되지 않았다** — 모델 출력과 같은 코드를 지난다")
    println("=" ^ 78)
    if rt !== nothing
        rt["synth_fixture"] = Dict{String,Any}(
            "path" => SYNTH_FIXTURE_PATH, "sha256_16" => digest,
            "keys_overridden" => used, "keys_ignored" => ignored,
            "impl_name" => get(d, "impl_name", nothing))
    end
    return d
end

"""
    _tool_args_dict(x)

`tool_args` 만 모양을 고정한다 — 나머지 일곱은 스칼라라 그대로 싣는다.

왜: 서비스가 보내는 것은 JSON 객체라 Julia 쪽에서 `JSON3.Object` 로 도착하는데, 그 타입은
`Dict{String,Any}` 가 아니다. 하류(T2 의 접지 `grammar_ground_check` 경로)가 `Dict{String,Any}`
로 읽을 것이므로 경계에서 한 번만 바꾼다.

실측(2026-08-29): 현행 tool 알파벳의 인자는 **전부 평평하다** — `tool_registry.py` 의 세 tool 이
받는 것은 `agent::String` 하나 또는 `reason::String` 하나뿐이라 중첩 객체가 나올 자리가 없다.
그래서 변환은 **얕다**: 값이 중첩 객체인 tool 이 생기면 그 값은 `JSON3.Object` 로 남는다.
(깊은 복사를 지금 짓지 않는 이유 = 오늘 재보면 그 사건이 도달 불가능하기 때문이고, 도달
가능해지는 순간이 곧 이 docstring 을 다시 읽어야 하는 순간이다.)

🔴 `nothing` 을 빈 Dict 로 접지 않는다. 다만 **그 이유를 정확히 적는다** (2026-08-29 수정
라운드, F5). 여기 있던 문구는 *"`nothing` 과 `Dict()` 가 'tool 을 안 불렀다' 와 '인자가
비었다' 를 가른다"* 였는데, 그것은 **측정보다 넓은 주장이었다**: 서비스의 성공 응답에서
`tool_args` 는 **절대 `null` 이 아니다** — `_first_tool_call` 이 호출이 없으면 `{}` 를 내고
(`dspy_service.py:_first_tool_call`), `pred is None` 인 폴백 경로도 `tool_args = {}` 로
초기화한다(`:1008`). 그러므로 이 층에서 `Dict()` 는 "안 불렀다" 와 "인자가 없는 tool 을
불렀다" 둘 다이고, 둘을 가르지 못한다.

🔴 소비자 규칙은 **`tool_called === nothing` 으로 가르는 것 하나뿐이다.**
(`tool_args` 의 빈 여부로 가르면 인자 없는 tool 을 부른 사건이 "안 불렀다" 로 샌다.)
`enact.jl` 의 `enact_target` 이 그 규칙을 쓴다.

그래도 접지 않는 이유는 남아 있다: `tool_args === nothing` 은 **서비스가 보낸 값이 아니라**
"이 레인에 그 키가 아예 없었다" 는 뜻이다(집행 레인이 dspy 가 아니었다 · 폴백 분기였다 ·
서비스가 그 키를 안 싣는 세대다). 그것을 `Dict()` 로 접으면 "레인이 안 돌았다" 가
"tool 을 안 부른 dspy 결정" 으로 둔갑한다. 가르는 키는 `tool_lane_view` 의 `"lane"` ·
`"lane_available"` 이다(그 docstring 에 삼분 규칙이 한 벌 있다).
"""
_tool_args_dict(x) = x === nothing ? nothing :
    (x isa AbstractDict{String} ? x : Dict{String,Any}(String(k) => v for (k, v) in pairs(x)))

"""
    tool_lane_fields(b) -> Vector{Pair{String,Any}}

`TOOL_LANE_KEYS` **열하나**를 `b`(서비스 응답 본체 또는 `nothing`)에서 뽑아 dict 조각으로 낸다.
(2026-08-29 T-C 가 `tool_choice` · `text_rescue` 를 더해 여덟에서 열이 됐고, 같은 날 T6 이
`text_rescue` 를 빼고 `decision_source` · `tool_arg_error` 를 더해 **열하나**가 됐다. 이 함수는
그 튜플을 그대로 도므로 개수를 코드가 다시 들고 있지는 않다 — 하중은
`test/tool_lane_keys_survive.jl` (0)절의 길이 검사와 (6)절의 교차언어 등호가 진다.)

🔴 **삼상 보존 (spec §9-2).** `nothing` = "못 쟀다", `false` = "재서 어긋났다". 여기서
`something(x, false)` 나 `Bool(x)` 로 감싸면 그 계약이 죽는다. 그러므로 **아무것도 접지
않는다.**

서비스가 실제로 `null` 을 낼 수 있는 키는 **넷**이다 (2026-08-29 수정 라운드, F4 —
여기 있던 *"`expressible` · `native_fc` · `macro_tool_agree` 셋 다"* 는 **거짓이었고**,
파이썬 쪽 docstring 과 정면으로 어긋나 있었다):

  · `tool_called`      — tool 을 안 불렀다 / 부를 수 없었다
  · `expressible`      — 어댑터가 bool 로 못 읽었다(`isinstance(..., bool)` 가 아니면 None)
  · `tool_lane_error`  — 레인이 실패하지 않았으면 None
  · `macro_tool_agree` — 비교할 왼쪽이나 오른쪽이 없다

🔴 **`native_fc` 도 이제 그 목록에 든다 — 다섯이다** (2026-08-29, 단일 채널 / T5·T6).
여기 있던 문장은 *"`native_fc` 는 그 넷에 들지 않는다 … 어떤 서비스 응답도 `native_fc: null`
을 만들지 못한다"* 였고, **그것은 이제 거짓이다.** T5 의 `no_tools` 조기 반환은 LM 을 **아예
안 부르고** 돌아오므로 그 행의 `native_fc` 는 `nothing`("못 쟀다")이지 `false`("물었는데 안
켜졌다")가 아니다. 두 값을 접으면 정확히 그 두 사건이 섞인다.
(그 아래의 옛 근거 — `_startup()` 이 늘 `_configure_dspy()` 를 먼저 돌리므로 `native_fc_active()`
자체는 언제나 `True`/`False` — 는 **여전히 참이다.** 바뀐 것은 그 함수를 **부르지 않고**
반환하는 경로가 생겼다는 것이다.)

그래서 Julia 쪽에서 `native_fc === nothing` 이 뜻하는 것은 "서비스가 못 쟀다" 가 **아니라**
셋 중 하나다: ① 집행 레인이 dspy 가 아니었다 ② dspy 항목이 폴백이었다 ③ 그 키를 안 싣는
세대의 응답이었다. ①②를 가르는 것은 `tool_lane_view` 의 `"lane"` · `"lane_available"` 이다.

🔴 두 분기가 **같은 키 집합**을 낸다. 키를 있을 때만 싣는 설계는 "키가 없다"와 "값이 null 이다"를
구분 불가능하게 만든다(Plan A 가 이미 밟은 presence-gated 결함). 레인이 안 돌았다는 사실은
이미 있는 `"available"` 키가 나른다 — 새 표식 키를 만들지 않는다.
"""
tool_lane_fields(b) = Pair{String,Any}[k => (k == "tool_args" ?
                                             _tool_args_dict(b === nothing ? nothing :
                                                             get(b, :tool_args, nothing)) :
                                             (b === nothing ? nothing : get(b, Symbol(k), nothing)))
                                       for k in TOOL_LANE_KEYS]

"""
    tool_lane_view(pol, enacted) -> Dict{String,Any}

`decide_all(...).tool_lane` 의 **본문 생산자**. `TOOL_LANE_KEYS` 전부에 **출처 두 개**를 더한다.
셋 다 **같은 `pol[enacted]` 항목 하나**에서 나온다 — 서로 다른 레인의 값이 한 dict 에 섞이지
않는다는 것이 이 함수가 존재하는 이유다.

  · `"lane"`           = `enacted` — 실제로 결정을 낸 레인 이름
  · `"lane_available"` = `pol[enacted]["available"]` — 그 레인 항목이 성공 분기였는가

🔴 **왜 더하는가** (2026-08-29 수정 라운드, F2). 레인 키만으로는 `tool_lane[k] === nothing` 이
**세 사건을 한 값으로 뭉갠다**. 이 dict 만 읽는 소비자는 셋을 가를 수 없었다:

  (a) 집행 레인이 dspy 가 **아니었다** → tool 레인이 애초에 없었다.
      (`pol["canonical"]` 등에는 그 키가 아예 없어 `get(..., nothing)` 이 전부 nothing 이다.)
  (b) 집행 레인이 dspy 인데 **그 항목이 폴백**이었다 → 레인이 돌다가 실패했다.
  (c) 집행 레인이 dspy 이고 항목도 성공인데 **서비스가 진짜 `null` 을 보냈다** → 못 쟀다.

**소비자 규칙 — 이 세 줄이 전부다(다른 곳에 사본을 두지 말 것):**

  (a) `tool_lane["lane"] != "dspy"`
  (b) `tool_lane["lane"] == "dspy" && tool_lane["lane_available"] !== true`
  (c) `tool_lane["lane"] == "dspy" && tool_lane["lane_available"] === true`

🔴 (b) 의 **대가를 여기 명시한다**(controller ruling R1, 그대로 둔다): 폴백 `policy_entry` 는
레인 키를 **전부 `nothing`** 으로 낸다 — 서비스가 실제로 **잰** `tool_lane_error` 문자열까지
접힌다. 그러므로 (b) 에서 `tool_lane["tool_lane_error"] === nothing` 은 "파싱 실패가 없었다"는
뜻이 **아니다**. 그 사건의 원문은 `policies["dspy"]["error"]` 와 서비스 응답에만 남는다.
(a) 에서도 마찬가지로 그것들은 "서비스가 못 쟀다" 가 아니라 "이 결정과 무관하다" 를 뜻한다.

🔴 이 키들은 이름도 뜻도 **안 바꾼다** — 하류(`enact.jl` 의 `enact_target`, `run_demo.jl` 의
결정 행)가 이미 읽고 있다. 더하기만 한다.
"""
function tool_lane_view(pol, enacted)
    local e = get(pol, enacted, nothing)
    local d = Dict{String,Any}(k => (e === nothing ? nothing : get(e, k, nothing))
                               for k in TOOL_LANE_KEYS)
    # 🔴 전부 **같은 항목**에서 뽑는다. `pol["dspy"]` 를 여기서 다시 읽으면 (a) 와 (c) 가
    #    도로 섞인다 — 그게 이 함수가 `pol` 과 `enacted` 를 같이 받는 이유다.
    d["lane"] = enacted
    d["lane_available"] = e === nothing ? nothing : get(e, "available", nothing)
    return d
end

"""
    policy_entry(b, label) -> Dict

서비스 응답 하나(`b`, 없으면 `nothing`)를 **`decide_all` 이 `pol[key]` 에 넣는 dict** 로 바꾼다.

왜 함수로 뽑았는가 (2026-08-14 최종 리뷰)
----------------------------------------
`escalation_target` 은 순수 함수로 뽑혀 검사되고 있었는데, **그 함수가 읽는 dict 를 만드는
쪽**은 `decide_all` 안에 인라인이라 검사되지 않았다. 그래서 `tools/test_policy_escalation.jl`
의 `unavail()` 은 이 dict 의 **손으로 쓴 복제본**이었고, 실측 확인: 아래 폴백 분기에서
`"unsupported" => miss0` 를 지워도 9개 검사가 전부 초록이었다(= 회귀가 그대로 복원된다).
복제본을 검사하면 복제본만 지켜진다 — 그래서 테스트가 **실제 생산자**를 부르도록 여기 뽑았다.

`b` 는 서비스 응답(JSON3 object) 또는 `nothing`. `get(b, :key, default)` 만 쓰므로 NamedTuple
로도 부를 수 있다(테스트가 그렇게 부른다).
"""
function policy_entry(b, label)
    if b !== nothing
        local err = get(b, :error, nothing)
        if err === nothing && !isempty(String(get(b, :chosen, "")))
            return Dict("chosen" => String(b.chosen),
                        "ranking" => String.(collect(get(b, :ranking, String[]))),
                        "margin" => (try Float64(b.margin) catch; nothing end),
                        "rationale" => String(get(b, :rationale, "")),
                        "scores" => get(b, :scores, nothing),
                        # 이 정책이 **아예 고를 수 없었던** 유효 매크로들(학습 근거 0).
                        # "NOOP 을 골랐다"와 "새 행동을 못 본다"는 전혀 다른 사건이다.
                        "unsupported" => String.(collect(get(b, :unsupported, String[]))),
                        "label" => String(get(b, :policy, label)), "available" => true,
                        # ---- tool 레인 키 (Plan B / T1·T-C, 2026-08-29) ------------------
                        # 여기까지가 배선이다. 집행부가 이 값을 **쓰는** 것은 T2 의 몫.
                        tool_lane_fields(b)...,
                        # ---- 합성 레인 키 (Plan B / T1, 2026-08-30) -----------------------
                        # 🔴 두 분기 **모두**에 넣는다(아래 폴백 분기도 참조) — 한쪽만 넣으면
                        # 실패한 판의 행에서 키가 사라져 "합성이 안 돌았다"로 잘못 읽힌다.
                        _synth_view(b)...)
        end
    end
    # ---- 폴백 dict 도 `unsupported` 와 **사유**를 싣는다 (2026-08-14 회귀 수정) ----------
    # 왜: 서비스가 "개입 후보가 전멸했다"를 알리는 방법은 `UNSUPPORTED:` + 빈 chosen 이라
    # 이 분기로 떨어진다. 여기서 unsupported 를 버리면 **표현력 격상 게이트**가
    # 정확히 그 사건에서 근거를 잃는다 — 게이트가 존재하는 이유가 그 사건인데도.
    # rationale 도 남긴다: 기록에 `fell_back=true` 만 있고 **어느 팔이 없었는지**가 없으면,
    # 나중에 이 폴백을 디버깅할 사람이 제일 먼저 찾을 정보가 빠져 있다.
    local miss0 = b === nothing ? String[] : String.(collect(get(b, :unsupported, String[])))
    local err0 = b === nothing ? "" : String(something(get(b, :error, nothing), ""))
    return Dict("chosen" => "", "ranking" => String[], "margin" => nothing,
                "rationale" => (isempty(miss0) ? err0 :
                                "no training support for " * join(miss0, ",")),
                "unsupported" => miss0, "error" => err0,
                "label" => label, "available" => false,
                # 🔴 폴백도 **같은 키 집합**을 낸다(전부 nothing). 키가 사라지면 소비자가
                # "레인이 안 돌았다"와 "레인이 돌았는데 값이 null 이다"를 못 가른다.
                tool_lane_fields(nothing)...,
                # 🔴 합성 레인도 같은 규약: 폴백 판에서도 아홉 키를 전부 nothing 으로 낸다.
                _synth_view(nothing)...)
end


"""
    blank_decision_diagnosis(e, body, transport_why) -> String

레인이 `available=false` 로 떨어진 사건의 **사유 한 줄**. `e` 는 `pol[lane]` 항목(또는
`nothing`), `body` 는 그 레인의 **날것 서비스 응답 본체**(`j[Symbol(lane)]`, 없으면 `nothing`),
`transport_why` 는 `LAST_DECIDE_TRANSPORT_ERROR[]`.

🔴 왜 진단값을 `e` 가 아니라 `body` 에서 읽는가. `policy_entry` 의 **폴백 분기는 tool 레인 키를
   일부러 전부 `nothing` 으로 낸다**(`tool_lane_fields(nothing)`) — 그 계약은
   `test/tool_lane_keys_survive.jl` 이 못박고 있고 뜻이 있다("레인이 안 돌았다"를 `available`
   하나로 가른다). 그런데 결정을 못 낸 사건은 `chosen == ""` 이라 **언제나** 그 분기로 가므로,
   서비스가 애써 계산한 판별키가 정확히 필요한 순간에 기록에서 사라져 있다. 여기서 `body` 를
   직접 읽으면 그 계약을 **건드리지 않고** 죽는 메시지에만 진짜 값을 실을 수 있다.

🔴 왜 이 함수가 있는가 (2026-09-05, 유료 런 13). 라우터가 죽으면서 찍은 것은
*"returned no decision: (no error field)"* 한 줄이었고, 그것으로는 **아무것도 가를 수 없었다.**
그런데 가를 재료는 그때 이미 전부 손에 있었다:

  · `LAST_DECIDE_TRANSPORT_ERROR[]` — 요청이 서비스에 **닿기는 했는가**. 런 13 의 진짜 사유
    (`TimeoutError: Connection closed after 60 seconds`)가 정확히 여기 있었는데 `@warn` 한 줄로만
    남고 죽는 메시지와 연결되지 않아, 다음 사람이 프로브를 돌려서야 알아냈다.
  · `decision_source` · `tool_lane_error` · `tool_calls_n` · `tools_offered` · `native_fc`
    · `tool_choice` — 서비스가 **답은 했는데 결정을 못 낸** 사건의 세 갈래를 가르는 키들이고,
    `tool_lane_fields` 가 이미 `e` 에 실어 뒀다(`dspy_service._blank_decision` 의 ⓐⓑⓒ 주석이
    그 규약의 진실원이다):
       ⓐ `error` 가 있다              = 프로바이더 장애
       ⓑ `tool_lane_error` 가 있다    = 빈/파싱 불가 응답 (계약 위반)
       ⓒ 둘 다 없고 `tool_calls_n==0` = 응답은 왔는데 tool 호출이 없다 (계약 위반)
    그리고 셋 중 **어느 것도 아닌** 네 번째가 런 13 이었다: 응답이 아예 안 왔다
    (전부 `nothing`) — 그 판을 이 함수는 transport 사유로 이름 붙인다.

⚠️ 값을 **접지 않는다.** `nothing`("못 쟀다")은 `n/a` 로 찍고 `false`("재서 어긋났다")는 `false`
   로 찍는다. 둘을 같은 글자로 찍으면 이 함수가 없애려는 그 모호함이 되돌아온다(spec §9-2).
"""
function blank_decision_diagnosis(e, body, transport_why)
    e === nothing && return "(lane absent from the service response)"
    local err = String(something(get(e, "error", ""), ""))
    local show1 = k -> begin
        local v = body === nothing ? nothing : get(body, Symbol(k), nothing)
        v === nothing ? "n/a" : string(v)
    end
    local parts = String["decision_source=" * show1("decision_source"),
                         "tool_lane_error=" * show1("tool_lane_error"),
                         "tool_calls_n=" * show1("tool_calls_n"),
                         "tools_offered=" * show1("tools_offered"),
                         "native_fc=" * show1("native_fc"),
                         "tool_choice=" * show1("tool_choice")]
    # 🔴 응답이 아예 안 온 판(런 13)은 위 여섯이 **전부 nothing** 이다. 그때 사유는 전송에 있고,
    #    그것을 앞세우지 않으면 여섯 개의 `n/a` 만 남아 예전과 똑같이 아무 말도 못 한다.
    local head = !isempty(err) ? err :
                 !isempty(transport_why) ? "no response from the service — " * transport_why :
                 "(no error field; the service answered but produced no decision)"
    return head * " [" * join(parts, " ") * "]"
end


"""
    decide_all(env, truth; nl="") -> (policies, enacted, router, ...)

**세 정책을 모두 계산**해 기록용 구조를 만든다. UI 가 "규칙이라면 / surrogate 라면 / LLM 이라면
무엇을 했을까"를 전환해 볼 수 있어야 하므로 매 사건마다 셋 다 남긴다.

실행될 정책(`enacted`)은 **라우터가 사건마다 고른다**(낯설면 LLM, 익숙하면 surrogate).
라우터가 꺼져 있으면 예전대로 DEMO_POLICY 로 런 전체 고정 -- 기존 데모 재현이 깨지지 않게.
"""
function decide_all(env, truth; nl::AbstractString = "")
    # ---- 후보 간선 상계 프로브 (2026-08-31, S1/T4) -----------------------------------------
    # S2(결정 시점 payload 재가격)의 전제조건을 결정 시점에 **비개입으로** 잰다.
    # 🔴 "못 쟀다"를 0 으로 찍지 않는다 — 그러면 "후보 0"(재가격이 원리적으로 무효라는 관측)과
    #    구별이 안 된다.
    local _slots = candidate_slot_upper_bound(env)
    println("[milp-probe] slots_upper_bound=", _slots === nothing ? "n/a" : string(_slots),
            " measured_at_closed=", (try string(length(env.cache.closed_set)) catch; "n/a" end))
    canon = canonical_macro(env, truth)     # 규칙표 → 지금 실행 가능한 어휘로 투영
    pol = Dict{String,Any}()
    pol["canonical"] = Dict("chosen" => canon, "ranking" => [canon],
                            "margin" => nothing, "rationale" => "rule lookup (severity threshold)",
                            "label" => "canonical", "available" => true)
    # no-adapt 바닥선(2026-08-05). DEMO_POLICY=noop 으로 고정해 돌리면 어떤 사건에도 개입하지
    # 않는다. "적응이 실제로 이득인가"를 재려면 이 바닥선이 있어야 하고, 없으면 완주율 비교의
    # 분모가 없다. 라우터는 이쪽으로 보내지 않는다(target 은 surrogate/dspy 뿐).
    pol["noop"] = Dict("chosen" => "NOOP", "ranking" => ["NOOP"], "margin" => nothing,
                       "rationale" => "no-adapt floor (never intervenes)",
                       "label" => "no-adapt", "available" => true)
    # ---- a* 집행 lane (2026-08-12) ----------------------------------------------------------
    # "천장을 정말 달릴 수 있었나"를 재는 다섯 번째 주자. 이 lane 의 **결정 적중률은 정의상 1.0**
    # 이라 성능 정보가 없다 -- 그 숫자는 Julia oracle_macro 와 Python reference_policy 가 일치하는지
    # 보는 자기검사 계기판이다. 정보가 있는 것은 그 결정을 실제로 집행했을 때의 완주율·시간·에너지다.
    # 라우터는 이쪽으로 보내지 않는다(target 은 surrogate/dspy 뿐) — noop 과 같은 통제 대조 lane 이다.
    local a_star = oracle_macro(env, truth)
    pol["oracle"] = Dict("chosen" => a_star, "ranking" => [a_star], "margin" => nothing,
                         "rationale" => "reference action a* (measured grids; see reference_policy.py)",
                         "label" => "oracle", "available" => true)

    # ---- DP 레인 (2026-08-14) -- **스윕 전용**, 라우터·UI 에서 제외 ---------------------------
    # `pol["dp"]` 를 DEMO_POLICY=dp 일 때만 만든다. 그러면 대시보드가 도는 판(router/canonical/…)
    # 에는 이 키가 아예 없어서 화면이 DP 를 그릴 수 없다 — Global Constraint 10 을 구조로 지킨다.
    # (조건을 안 걸고 매번 만들면 "화면에 안 그리기로 했다" 는 규약이 렌더러 쪽 약속으로만 남는다.)
    if POLICY == "dp"
        local dp_m, dp_why = dp_macro(env, truth)
        if isempty(dp_m)
            # 조용한 폴백 금지: 표를 못 읽은 **이유**를 그대로 rationale 에 싣는다. 그래야
            # FINAL.md 가 "커버리지가 낮아서" 와 "동점이라 보류" 를 구분해 셀 수 있다.
            pol["dp"] = Dict("chosen" => canon, "ranking" => [canon], "margin" => nothing,
                             "rationale" => "DP table miss (" * dp_why * ") → canonical rule",
                             "label" => "dp:table-miss→canonical", "available" => true,
                             "dp_miss" => dp_why)
        else
            pol["dp"] = Dict("chosen" => dp_m, "ranking" => [dp_m], "margin" => nothing,
                             "rationale" => "DP backward induction a* (" * dp_why * ")",
                             "label" => "dp", "available" => true, "dp_miss" => nothing)
        end
    end

    rt = route(env, truth)                        # ← 판정 기록(참고용). 라우팅은 아래 kind 축이 한다.
    desc = get(rt, "descriptors", nothing)

    # ---- kind 색인 라우터 (2026-08-29, T11 / §0-C 사용자 결정 1) -----------------------------
    # 🔴 판정 입력이 **kind 하나**다. 아는 kind → surrogate, 처음 보는 kind → LLM.
    #    `routing_kind` 는 `lane_select.jl` 의 전총 함수이고, `ood_features` 의 `"kind"` 와
    #    **일부러 다른 함수**다. 🔴 2026-09-07 정정: 여기 있던 근거 *"저쪽의 `else` 분기가
    #    모르는 타입에 `"fault"` 를 주는데 그건 surrogate 피처로는 옳다"* 는 두 번 낡았다 —
    #    그 분기는 이제 `"unknown"` 이고, surrogate 는 애초에 `kind` 를 안 읽는다(:866 참조).
    #    두 함수를 가르는 **살아 있는** 이유는 이것이다: `ood_features` 는 사건을 **자기 이름**
    #    으로 부르고(`zone` 은 `zone` 이다), `routing_kind` 는 **레인 표식**을 단다. 라우팅에
    #    앞의 것을 쓰면 표식이 사라져 갈림 자체가 관측 불가가 된다(§0-C 충돌 ①).
    #    ⚠️ 단 `select_lane` 의 판정은 접두사가 아니라 `kind in known_kinds` **집합 소속**
    #    하나뿐이다(그 함수 전문). 접두사는 판정의 원인이 아니라 표식의 통일이다 — 실측
    #    2026-09-07: 라벨셋 33행의 kind 는 `battery` 27 · `fault` 6 뿐이라 `"zone"` 은
    #    접두사가 없어도 집합에 없다.
    #    두 유도가 **severe battery·fault 에서** 같은 값임은
    #    `test/tool_choice_gate.jl` 의 교차 게이트가 못박는다 — 그게 없으면 `FaultTruth` 개명
    #    한 번에 전 사건이 dspy 로 간다.
    # ⚠️ 2026-08-30 부터 **일치하지 않는 kind 가 셋이다**: mild battery(`kind="battery"` vs
    #    `"unknown:battery_mild"`) · zone(`"zone"` vs `"unknown:zone"`) · 미지 타입
    #    (`"unknown"` vs `"unknown:<타입이름>"` — 2026-09-07 이전에는 `"fault"` 였다). 앞의 둘은
    #    이 날 **일부러 갈라 놓은 것**이고(사용자 결정: LLM 레인 표식을 `"unknown:"` 하나로 통일),
    #    그 게이트가 재는 일치 대상에서 빠져 있다. 갈림 자체는 §A-1 이 이미 배선한 사건이다.
    local rkind = routing_kind_of(truth)
    rt["routing_kind"] = rkind
    # 🔴 `surro_kinds()` 가 `nothing`(= 못 쟀다)이면 `select_lane` 이 **죽는다**. 조용히
    #    한쪽으로 떨어지면 그 런의 모든 행이 근거 없이 "라우팅했다" 로 기록된다.
    local sel = router_drives() ?
        select_lane(kind = rkind, known_kinds = surro_kinds(), policy = POLICY) :
        (lane = POLICY, axis = "fixed",
         reason = "router off — DEMO_POLICY=$(POLICY) is fixed for this run")
    rt["router_axis"] = sel.axis
    rt["lane_reason"] = sel.reason
    # 🔴 **세대 표식 (2026-08-29, §B-1 / Ruling R2).** 옛 녹화의 `target` 은 **novelty 축이
    #    보냈을 곳**이었고(`route_verdict` 안의 `drives ? would : policy`), 이 커밋 이후의
    #    `target` 은 **실제로 고른 레인**이다. `enacted` 와 항상 같다.
    #    🔴 **두 세대를 같은 표에 섞지 말 것.**
    #    왜 여기냐: novelty 축이 사라지면 옛 식(`route_verdict` 안)은 **언제나 `policy`** 로
    #    붕괴하는데, `run_demo.jl` 의 결정 행은 `router_target` 열을 계속 싣는다. 붕괴한 값이나
    #    `nothing` 이 그 열에 들어가면 **"이 결정에는 레인이 없었다"** 로 읽힌다 — 레인이 실제로
    #    있었던 판에 대해. 산출물이 자기가 아는 사실을 정직하게 적게 하는 것이 이 줄이고,
    #    레인을 아는 유일한 자리가 여기다(`sel` 이 정해진 직후).
    #    🔴 **스윕 게이트를 만족시키려고 쓰는 것이 아니다** (2026-08-29 fix round 1, Ruling R6):
    #    `sweep/llm_ood_eval.py::_router_drove` 는 `router_axis`/`router_drives` 도장이 있으면
    #    (`stamped`) `router_target` 분기에 **도달하지 않는다.** `run_demo.jl` 이 `router_axis`
    #    키를 매 결정에 싣기 때문에 T11 이후 산출물에서 그 분기는 **죽은 코드**다(실측: 합성
    #    행으로 `router_target` 을 통째로 빼도 `ok=True`). 그 게이트를 근거로 이 열을 정당화하면
    #    다음 사람이 잘못된 이유를 믿게 된다.
    rt["target"] = sel.lane
    # 기존 문구를 **덮어쓰지 않고 덧붙인다** — 판정 근거가 든 줄이 화면에서 사라지면 안 된다.
    rt["reason"] = get(rt, "reason", "") * " · LANE: " * sel.reason

    # ---- 고른 레인 **하나만** 청구한다 (2026-08-29, T11 / §0-C 충돌 ⑦) -----------------------
    # 🔴 여기가 비용이 실제로 잘리는 자리다. surrogate 는 DSPy 서비스 **안**에 살고 유일한
    #    통로가 `/decide` 인데, 그 함수는 맨 앞에서 `macro(req)` 로 LLM 을 부른다. 이 한 줄이
    #    없으면 "라우터가 비용을 자른다" 는 주장이 거짓이 된다(T10 이 서비스 쪽을 열었다).
    # canonical/noop/oracle/dp 는 줄리아가 자기가 계산하므로 서비스 호출이 **0건**이다 —
    # 옛 `DEMO_ALL_POLICIES` 생략 조건을 이 한 줄이 대체한다(그 손잡이는 T12 가 지운다).
    local want = sel.lane in ("dspy", "surrogate") ? [sel.lane] : String[]
    j = isempty(want) ? nothing :
        service_decide(env, truth; nl = nl, descriptors = desc,
                       agents = CB.open_agent_descriptors(env),
                       zones  = CB.open_zone_descriptors(env),
                       lanes  = want)

    # 폴백 라벨은 모델 이름을 박지 않는다 — 실제 라벨은 서비스가 돌려주는 b.policy 를 쓴다.
    # dict 조립은 `policy_entry`(위) 한 곳에만 있다.
    # 🔴 **청구한 레인만** 넣는다. 안 청구한 레인의 키가 `pol` 에 없다는 것이 곧 "안 물었다" 이고,
    #    `policy_entry(nothing, …)`(available=false)는 "물었는데 실패했다" 다 — 다른 사건이다.
    for key in want
        pol[key] = policy_entry((j !== nothing && haskey(j, Symbol(key))) ? j[Symbol(key)] : nothing,
                                key == "dspy" ? "dspy:LLM" : "surrogate:RandomForest")
    end

    enacted = sel.lane
    # 🔴 `fell_back` 은 **언제나 false 다** (2026-08-29, T11). 조용한 canonical 폴백을 없앤 것이
    #    §0-C 사용자 결정 3 이고, 아래가 그 결정의 집행이다. 필드는 산출물 스키마 하위호환을
    #    위해 남기지만 값이 하나로 붕괴했다 — 옛 녹화의 `fell_back=true` 행과 같은 표에 섞지 말 것.
    fell_back = false

    # ---- 시끄럽게 죽는 자리 (§0-C 사용자 결정 3) --------------------------------------------
    # 🔴 `try/catch` 로 이 사건만 건너뛰거나 `@error` 를 찍고 canonical 로 계속 도는 변형은
    #    전부 이 결정에 반한다 — 그러면 산출물이 "라우팅했다" 고 주장하면서 실제로는 규칙표가
    #    돈 행을 섞어 담게 되고, 그게 §0-C 가 지우려는 바로 그 상태다. 런이 죽는 것이
    #    이 설계에서 **의도된 신호**다(선례: F1, `011ed3c0`).
    if enacted in ("dspy", "surrogate")
        local e = get(pol, enacted, nothing)
        if e === nothing || e["available"] !== true
            # 🔴 `UNSUPPORTED:` 판정은 **날것의 `error` 로 가른다.** 아래 진단 문자열은 사유 앞에
            #    다른 것을 붙일 수 있으므로 그것으로 `startswith` 를 하면 이 분기가 조용히 죽는다.
            local raw = e === nothing ? "" : String(something(get(e, "error", ""), ""))
            # 🔴 `UNSUPPORTED:` 는 장애가 아니라 **도장과 어휘가 갈린 것**이라 메시지를 가른다.
            #    (kind 도장은 이 kind 를 배웠다고 말하는데 그 팔들이 매크로 지원집합에 없다.)
            startswith(raw, "UNSUPPORTED:") && error(
                "[router] '$(rkind)' is in the surrogate's train_kinds stamp, but its arms " *
                "are not in the macro support set ($(raw)). The stamp and the vocabulary " *
                "have diverged — regenerate the dataset or fix the vocab.")
            # 🔴 2026-09-05 (유료 런 13). 여기 있던 것은 `(no error field)` 한 줄이었고 그것으로는
            #    "서비스가 답을 못 냈다" 와 "답이 아예 안 왔다" 가 안 갈렸다. 가를 재료는 이미
            #    전부 있었다 — `blank_decision_diagnosis` 가 그것을 한 줄로 편다.
            # 🔴 날것의 응답 본체를 넘긴다 — `pol[enacted]` 이 아니다. 그 이유는
            #    `blank_decision_diagnosis` 의 docstring 이 진다(폴백 분기가 판별키를 지운다).
            local body = (j !== nothing && haskey(j, Symbol(enacted))) ? j[Symbol(enacted)] : nothing
            error("[router] lane '$(enacted)' was chosen for a '$(rkind)' event but " *
                  "returned no decision: " *
                  blank_decision_diagnosis(e, body, LAST_DECIDE_TRANSPORT_ERROR[]))
        end
    elseif !haskey(pol, enacted)
        # 고정 정책(라우터 OFF)이 존재하지 않는 레인을 가리키면 그것도 오설정이다.
        error("[router] DEMO_POLICY='$(enacted)' names a lane that was never computed")
    end

    # ---- zone 진단 — 🔴 **기록만 한다. 격상은 더 이상 없다** (2026-08-29, T12 / §0-C) --------
    # 옛 모양: 이 블록은 두 조건(`n_nav_blocked > 0` · `verdict === :line_stop`)에서 `enacted`
    # 를 `"dspy"` 로 올렸다. kind 축에서 **zone 은 이미 dspy** 이므로 그 두 분기의 가드
    # (`enacted != "dspy"`)가 절대 참이 안 되는 죽은 코드다. 지웠다.
    #
    # ✅ **남기는 것 둘.** 격상이 사라져도 *"왜 올렸어야 했는가"* 의 진단은 사후 감사의 유일한
    #    증거이므로 값으로 남긴다:
    #      · `zone_primitives` — 조건 없는 감사 증거(그대로).
    #      · `zone_verdict`    — `:line_stop` = "닫힌 어휘에 이 구역의 수복이 없다". **기록만**
    #                            하고 격상 판정으로는 쓰지 않는다.
    #
    # 🔴 `check_restage = true` 가 **하중을 진다.** `ood_features` 의 `zone_diagnosis(env, zone)`
    #    호출은 이 인자가 없어서 restage 가능성을 안 잰다. 이 줄을 지우면 `verdict` 가
    #    `:line_stop` 이 될 길이 사라지고, 아래 기록이 **에러 없이** 영원히 다른 값만 낸다.
    if truth isa CB.ZoneTruth
        local zdg = try
            CB.ablation_exempt(:monitor_record) do
                CB.zone_diagnosis(env, truth.zone; check_restage = true)
            end
        catch e
            @warn "[router] zone_diagnosis failed -> zone audit record skipped" exception = e
            nothing
        end
        if zdg !== nothing && zdg.exists
            # 판정 자체는 오라클의 것이라 정책에 주지 않는다. 여기 남기는 것은 **원시값**뿐이다.
            rt["zone_primitives"] = Dict(
                "n_blocked" => zdg.n_blocked, "n_restage_feasible" => zdg.n_restage_feasible,
                "root_covered" => zdg.root_covered, "root_total" => zdg.root_total,
                "n_teams_forming" => zdg.n_teams_forming, "n_teams_covered" => zdg.n_teams_covered,
                "relocate_feasible" => zdg.relocate_feasible,
                # 막힘(blockage) 원시값 — 위 전부가 coverage 이고 아래만 blockage 다.
                "n_nav_goals" => zdg.n_nav_goals, "n_nav_blocked" => zdg.n_nav_blocked,
                "n_nav_engulfed" => zdg.n_nav_engulfed,
                "n_nav_disconnected" => zdg.n_nav_disconnected,
                "n_agent_trapped" => zdg.n_agent_trapped,
                "n_nav_downstream" => zdg.n_nav_downstream,
                # 종단성 술어(2026-09-05). 삼상이라 `nothing` 이면 JSON 에 `null` 로 남는다 —
                # 감사 증거에서 "안 쟀다"와 "안 막혔다"가 구별돼야 한다.
                "n_completion_blocked" => zdg.n_completion_blocked,
                "n_completion_open" => zdg.n_completion_open,
                "project_blocked" => zdg.project_blocked)
            # Symbol 은 JSON 에 안 실리므로 String 으로.
            rt["zone_verdict"] = String(zdg.verdict)
        end
    end

    rt["enacted"] = enacted
    rt["fell_back"] = fell_back
    chosen = pol[enacted]["chosen"]

    # 이 판에서 몇 번째 결정인가. deviation 이 꺼져 있어도 센다 — 행에 남겨 두면
    # 나중에 "왜 그 칸에 표본이 없나" 를 로그만으로 답할 수 있다.
    didx = _next_decision_index!()
    rt["decision_index"] = didx

    # 통제 실험(FORCE_MACRO): 정책의 결정은 그대로 기록하고 집행만 덮어쓴다.
    forced = !isempty(FORCE_MACRO) && FORCE_MACRO != chosen
    if forced
        rt["forced_macro"] = FORCE_MACRO
        rt["forced_from"] = chosen
        @info "[policy] FORCED enactment $(chosen) → $(FORCE_MACRO) (DEMO_FORCE_MACRO, 통제 실험)"
        chosen = String(FORCE_MACRO)
    end

    # 1-step deviation: k 번째 결정에서만 갈아쓴다.
    dev = should_deviate(DEVIATE_AT, DEVIATE_ARM, didx)
    if dev !== nothing
        # 게이트가 이 인덱스에 걸렸다는 사실은 **팔이 바뀌었는지와 무관하게** 남긴다.
        # 안 남기면 "k 가 결정 수보다 커서 한 번도 안 걸린 판" 과 "걸렸는데 canonical 이 이미
        # 그 팔이었던 판" 이 로그에서 구분되지 않고, 둘 다 그 팔의 표본으로 잘못 라벨된다.
        rt["deviate_at"] = didx
        rt["deviate_arm"] = dev
        rt["deviated"] = (dev != chosen)
        rt["deviate_from"] = chosen
        # 이 사건에 그 팔이 **메뉴에 있는지**를 같이 남긴다. `valid_macros` 는 빈 배열로
        # "메뉴 없음(=서비스의 kind 기본표를 쓰라)"을 뜻한다 — `String[]` 을 "아무것도 유효하지
        # 않다"로 읽으면 안 된다. 그 규약은 `:413`(`isempty(vm) || (payload["valid"] = vm)`)과
        # `:460`(`(isempty(vm) || m in vm) && return m`)이 이미 쓰고 있다. FaultTruth·ReformTruth
        # 는 `valid_macros` 가 항상 `String[]` 을 돌려주므로(전용 메뉴가 없다는 뜻), 여기서
        # `isempty` 를 "유효" 로 안 세면 그 두 축의 deviation 이 무조건 invalid 로 찍힌다.
        # ⚠️ 이 키는 "메뉴 안에 있는가" 만 답한다 — "집행 사슬이 실제로 뭔가 했는가" 는 다른
        # 질문이고 `run_demo.jl` 의 `enact_applied` 가 그 진실원이다(메뉴가 비어 valid=true 인데
        # 사슬은 truth 타입 가드로 무동작일 수 있다, 예: fault 사건에 ForbidZone).
        local _vm = try valid_macros(env, truth) catch; String[] end
        rt["deviate_valid"] = isempty(_vm) || dev in _vm
        rt["deviate_valid"] ||
            @warn "[policy] DEVIATE #$(didx): $(dev) 는 이 사건($(typeof(truth).name.name))의 " *
                  "메뉴 $(_vm) 밖이다 — 정책이 애초에 고를 수 없는 팔로 갈아 끼웠다"
        if dev != chosen
            @info "[policy] DEVIATE #$(didx): $(chosen) → $(dev) (DS_DEVIATE_AT, 1-step)"
            chosen = dev
        else
            @info "[policy] DEVIATE #$(didx): 이미 $(chosen) — 집행 무변경 (DS_DEVIATE_AT, 1-step)"
        end
    end

    # 서비스가 돌려준 "각 producer 가 실제로 본 것" -- UI 가 나란히 보여줄 두 입력.
    if j !== nothing
        rt["llm_input"] = String(get(j, :llm_input, ""))
        rt["surrogate_input"] = String(get(j, :surrogate_input, ""))
        rt["llm_input_mode"] = String(get(j, :llm_input_mode, "parsed-fields"))
    end

    # 후보표: 실행 정책의 순위를 쓰되, 각 매크로를 어느 정책이 골랐는지 표시한다.
    ranking = pol[enacted]["ranking"]
    # 🔴 2026-08-29 (T11): `haskey` 가드가 필요해졌다. 라우터가 사건당 레인 **하나만** 부르므로
    #    `pol` 에 `"surrogate"`/`"dspy"` 키가 **없을 수 있다**(= "안 물었다"). 없는 것을 색인하면
    #    `KeyError` 로 죽는데, 그건 이 설계가 의도한 시끄러운 죽음이 아니라 그냥 결함이다.
    for m in [pol[k]["chosen"] for k in ("canonical", "surrogate", "dspy")
              if haskey(pol, k) && pol[k]["available"]]
        (isempty(m) || m in ranking) || push!(ranking, m)
    end
    (forced && !(chosen in ranking)) && push!(ranking, chosen)   # 강제 집행 매크로도 표에 보이게
    (get(rt, "deviated", false) && !(chosen in ranking)) && push!(ranking, chosen)   # deviate 로 갈아 쓴 매크로도 표에 보이게
    cands = [Dict("rank" => i, "macro" => m,
                  "score" => (i == 1 && pol[enacted]["margin"] !== nothing ?
                              "margin $(round(pol[enacted]["margin"]; digits = 2))" : ""),
                  "chosen" => (m == chosen),
                  "rule"   => (m == pol["canonical"]["chosen"]),
                  # 🔴 2026-08-29 (T11): 같은 `haskey` 가드. 안 부른 레인은 `pol` 에 키가 없다.
                  #    ⚠️ 이 열의 뜻이 좁아졌다 — 예전엔 "세 레인 중 누가 이 매크로를 골랐나"
                  #    였는데, 이제 계산된 레인이 둘(canonical + 고른 것)뿐이라 **비교 정보가
                  #    구조적으로 줄었다.** 옛 녹화와 같은 표에 섞지 말 것(§0-C 충돌 ④).
                  "by"     => join([k for k in ("canonical", "surrogate", "dspy")
                                    if haskey(pol, k) && pol[k]["available"] &&
                                       pol[k]["chosen"] == m], "+"),
                  "verified" => (m == chosen))
             for (i, m) in enumerate(ranking)]

    # 🔴 2026-08-29 (T11): `others`(= 안 부른 레인과의 불일치 목록)는 **사라졌다.** 라우터가
    #    사건당 레인 하나만 부르므로 비교할 값이 존재하지 않는다 — 예전 코드는 `pol[k]` 를
    #    무조건 색인해 지금은 `KeyError` 로 죽는다. 화면의 "DIFFERS from …" 줄도 같이 간다.
    #    ⟹ 이 커밋 **이전** 녹화와 그 줄에서 비교가 끊긴다(§0-C 충돌 ④, 되돌릴 수 없다).
    routed = router_drives() ? "ROUTED→$(enacted) ($(get(rt, "router_axis", "?"))) · " : ""
    verdict = routed * "ADMITTED · $(pol[enacted]["label"])" *
              (forced ? " · FORCED→$(FORCE_MACRO) (control run; policy chose $(rt["forced_from"]))" : "") *
              (get(rt, "deviated", false) ? " · DEVIATE→$(rt["deviate_arm"]) (1-step; policy chose $(rt["deviate_from"]))" : "")

    # ---- 자연어 서술 (2026-08-14, spec §4.1) --------------------------------------------------
    # 결정적 템플릿이다(LLM 호출 없음). 여기서 **찍어 넣는** 이유: 대시보드는 스트림을 그대로
    # 재생하므로, 화면(JS)에서 문장을 조립하면 단위검사 대상이 되지 않는다. 키 이름은 narrate.jl
    # 이 읽는 것과 정확히 같아야 한다.
    local _f = try ood_features(env, truth) catch; Dict{String,Any}() end
    local narrative = try
        narrate_event(Dict{String,Any}(
            "kind"          => get(_f, "kind", string(typeof(truth).name.name)),
            "severity"      => get(_f, "severity", nothing),
            # 종단성 술어(2026-09-05, task B2). zone 의 severity 는 겹침 면적비라 이 사건의
            # 해로움을 못 나른다 — narrate.jl 이 그 사실을 따로 적는다. 없으면 nothing(삼상).
            "zone_project_blocked" => get(_f, "zone_project_blocked", nothing),
            "soc"           => get(_f, "soc", nothing),
            "spare_count"   => get(_f, "spare_count", nothing),
            "agent_pending" => get(_f, "agent_pending", nothing),
            "progress"      => get(_f, "progress", nothing),
            "enacted"       => enacted,
            "macro_name"    => chosen,
            "fell_back"     => fell_back,
            # 🔴 2026-08-29 (T11): `requested` 라는 별개의 값이 없어졌다 — 라우터가 고른 레인이
            #    곧 집행된 레인이고(조용한 폴백이 사라졌다), 다르면 그 자리에서 죽는다.
            "requested"     => enacted,
            "policies"      => pol))
    catch e
        # 서술이 실패해도 결정은 계속한다. 다만 **빈 문자열로 조용히 덮지 않는다** — 화면이
        # "서술 없음" 과 "서술기가 죽었음" 을 구분할 수 있어야 한다.
        @warn "[narrate] narrate_event failed" exception = e
        ""
    end

    # ---- tool 레인 노출 (Plan B / T1, 2026-08-29) ---------------------------------------------
    # 🔴 **`pol["dspy"]` 가 아니라 `pol[enacted]` 다.** 실제로 결정을 낸 레인이 canonical /
    #    noop / oracle / surrogate 이면 LLM 의 tool 호출은 그 결정과 **아무 상관이 없다** —
    #    `pol["dspy"]` 에서 뽑으면 canonical 이 결정한 사건에서 LLM 의 tool 인자가 집행으로
    #    흘러드는 경로가 생긴다. 그 레인들의 dict 에는 레인 키가 아예 없으므로 `get(..., nothing)`
    #    이 전부 `nothing` 을 낸다 = "못 쟀다"(spec §9-2), `false` 가 아니다.
    #    삼분 규칙(레인이 없었다 / 레인이 실패했다 / 서비스가 null 을 냈다)과 두 출처 키는
    #    `tool_lane_view` 의 docstring 에 **한 벌만** 있다.
    local tool_lane = tool_lane_view(pol, enacted)

    # ---- 합성 레인 노출 (Plan B / T1, 2026-08-30) -----------------------------------------
    # 🔴 `tool_lane` 과 **같은 규약**: `pol[enacted]` 에서 뽑는다(`pol["dspy"]` 가 아니다).
    #    집행된 레인이 surrogate 였으면 이 값들은 전부 nothing 이고, 그것이 옳다 —
    #    surrogate 레인은 합성을 하지 않는다.
    local synth_lane = let e = get(pol, enacted, nothing)
        e === nothing ? nothing : Dict{String,Any}(k => get(e, k, nothing) for k in SYNTH_LANE_KEYS)
    end
    # ---- 🔴 시험 전용 오라클 우회 (2026-09-05, task-oracle) ---------------------------------
    #    `DEMO_SYNTH_FIXTURE` 가 켜져 있으면 **모델의 출력 자리에 픽스처를 꽂는다.** 나머지
    #    경로(등록 → 규약 검사 → 인자 바인딩 → 집행 → 재개 → 재풀이 → 세계 지문)는 한 줄도
    #    안 바뀐다. 이 우회는 **조용하지 않다** — `synth_fixture_lane` 이 매 결정마다 배너를
    #    찍고 `rt["synth_fixture"]` 로 산출물에도 도장을 남긴다. 이 레포의 최악의 실패
    #    모양이 "오라클 런을 모델 런으로 오독" 이다.
    synth_lane = synth_fixture_lane(synth_lane, rt)

    # 🔴 2026-08-29 (T11/T12): `llm_macro` 와 `agree` 는 **반사실**이다 — 안 부른 레인의 값을
    #    주장한다. 라우터가 사건당 레인 하나만 부르므로 그 값이 존재하지 않는다(§0-C 결정 4).
    #    필드는 **하위호환을 위해 남기되 `nothing` 으로 붕괴한다**: 소비자가 키 부재를 "값이
    #    없다" 가 아니라 **"세대가 다르다"** 로 읽을 수 있어야 하고, 키를 통째로 없애면
    #    옛 녹화를 읽는 코드가 `KeyError` 로 죽는 것과 구별이 안 된다.
    #    ⚠️ dspy 레인이 실제로 집행된 사건에서는 `llm_macro == chosen` 이므로 값이 있다.
    # 🔴 fix round 1 (controller): s2_after_release_candidates 는 `_f`(위에서 이미 계산한
    #    ood_features 결과)에서 재사용한다 -- release_then_candidates 를 여기서 다시 부르면
    #    결정마다 deepcopy+formulate_milp 가 세 번째로 도는 셈이라 안 된다. 삼상 규약: 못 쟀으면
    #    (키가 없으면) nothing 을 낸다 -- 0 으로 접지 않는다(아래 run_demo.jl 쪽에서도 같은 규약).
    return (macro_name = chosen, candidates = cands, policies = pol, enacted = enacted,
            policy = pol[enacted]["label"], rule_macro = pol["canonical"]["chosen"],
            llm_macro = (haskey(pol, "dspy") ? pol["dspy"]["chosen"] : nothing),
            verdict = verdict, router = rt,
            narrative = narrative, tool_lane = tool_lane, synth_lane = synth_lane,
            detail = pol[enacted]["rationale"], agree = nothing,
            s2_after_release_candidates = get(_f, "s2_after_release_candidates", nothing))
end



# ---- 고른 매크로 → DSL 제안(RespecProposal). 프레임워크 dispatcher 가 검증·실행한다. ----
# NOOP 은 "제약 없음"이 정답이므로 빈 제안을 돌려준다(= 개입하지 않음).
function macro_to_proposal(truth, macro_name::AbstractString; env = nothing, agent = nothing)
    rationale = "policy=$(POLICY) chose $(macro_name)"
    src = string(typeof(truth).name.name)
    # ---- 집행 대상 (2026-08-29, Plan B / T2b) ------------------------------------------
    # 🔴 `agent` 가 주어지면 그것을 쓴다. 그것이 두 번째 엔진(`render_demo.jl`)에서 LLM 의
    # tool 호출이 세계에 닿는 유일한 자리다 — `enact_recovery!` 는 `ReplaceAgent` 제약의
    # `.agent` 를 이미 존중하므로(그 자리는 이미 제안을 따른다), 끊겨 있던 곳은 정확히
    # 여기 하나다. 기본값이 `nothing` 이라 **기존 호출자는 한 줄도 안 바뀐다.**
    #
    # ⚠️ `hasproperty(truth, :robot)` 가드가 왜 필요했는가: `ZoneTruth` 에는 `robot` 필드가
    # 없고 `ReformTruth` 는 필드가 아예 없는 struct 라, 가드 없이 `truth.robot` 을 읽으면 던진다.
    # 그래서 가드를 없앤 게 아니라 **대상 계산으로 옮겼다**: agent 가 있으면 truth 에 `robot` 이
    # 없어도 집행 대상은 존재하고(실재하는 경우다), 둘 다 없으면 예전처럼 빈 제안으로 떨어진다.
    local tgt = agent !== nothing ? agent :
                (hasproperty(truth, :robot) ? truth.robot : nothing)
    if macro_name == "Replace" && tgt !== nothing
        return CB.RespecProposal(CB.ConstraintSpec[CB.ReplaceAgent(tgt, 0.0)], rationale, src)
    elseif macro_name == "SwapBattery" && tgt !== nothing
        # 2026-08-06: 이 분기가 없으면 정책이 SwapBattery 를 골라도 아래 빈 제안으로 떨어져
        # **조용히 NOOP 이 실행된다** — RelocateBuild 에서 한 번 겪은 것과 똑같은 실패 양식이다.
        return CB.RespecProposal(CB.ConstraintSpec[CB.SwapBattery(tgt)], rationale, src)
    # 🔴 2026-08-24 (spec §5.4, Task 5): 여기 있던 `Deprioritize` 분기(→ `CB.DeprioritizeAgent`)
    # 를 지웠다. 그 kind 가 DSL 에서 삭제됐고 `valid_macros` 의 배터리 메뉴에서도 빠졌다.
    # 🔴 2026-08-24 (spec §5.1, Task 4): 여기 있던 `ForbidZone` · `RelocateBuild` 두 분기를
    # 지웠다. zone 은 LLM 결정 레인에서 빠졌고 `valid_macros` 가 zone 메뉴를 더는 안 내므로
    # 그 이름이 여기 도달할 경로가 없다. (Julia 타입 `CB.ForbidZone`/`CB.RelocateBuild` 는
    # 시뮬레이터 쪽에 그대로 살아 있다 — 어휘에서만 빠졌다.)
    elseif macro_name == "ReformTeam"
        return CB.RespecProposal(CB.ConstraintSpec[CB.ReformTeam()], rationale, src)
    end
    return CB.RespecProposal(CB.ConstraintSpec[], rationale, src)   # NOOP / 적용 불가
end

# ---- 세 정책의 결정을 monitor respec 레코드로 기록(두 엔진 공용) ----
function record_decision!(env, truth, decision, nl)
    tgt = try
        truth isa CB.ZoneTruth ? string(truth.assembly) :
        hasproperty(truth, :robot) ? _rl(truth.robot) : ""
    catch; "" end
    kind = truth isa CB.FaultTruth ? "FAULT" : truth isa CB.BatteryTruth ? "BATTERY" :
           truth isa CB.ZoneTruth ? "ZONE" : "OOD"
    (truth isa CB.FaultTruth) && try CB.monitor_record_fault!(truth.robot) catch end
    try
        CB.monitor_record_respec!(; at = length(env.cache.closed_set),
            input = Dict("event" => kind, "target" => tgt,
                         "detail" => first(split(String(nl), "
")),
                         # nl = 관찰 **전문**. detail 은 첫 줄만이라 UI 가 문장을 온전히 못 보여줬다.
                         # 이게 LLM 이 실제로 읽는 채널이므로 화면에도 원문 그대로 있어야 한다.
                         "nl" => String(nl),
                         "policy" => decision.policy,
                         "rule_macro" => decision.rule_macro,
                         "llm_macro"  => decision.llm_macro,
                         "policies"   => decision.policies,
                         "enacted"    => decision.enacted,
                         # router = 이 사건을 왜 그쪽으로 보냈는지(p, eps, 판정, 각 producer 의 입력).
                         "router"     => (hasproperty(decision, :router) ? decision.router : nothing),
                         # 자연어 해석(spec §4.1). 결정 시점에 **찍어 넣는다** — 화면(JS)에서
                         # 조립하면 단위검사 대상이 되지 않고, 파이썬 후처리로 만들면 라이브
                         # 화면에 안 뜬다. 재스윕 이전 녹화에는 이 키가 없다(화면이 자리를 비운다).
                         "narrative"  => (hasproperty(decision, :narrative) ? decision.narrative : nothing),
                         "rationale" => decision.detail,
                         "agrees_with_rule" => decision.agree),
            candidates = decision.candidates,
            chosen = strip("$(decision.macro_name) $(tgt)"), verdict = decision.verdict)
    catch e
        @warn "record_decision! failed" exception = e
    end
end
