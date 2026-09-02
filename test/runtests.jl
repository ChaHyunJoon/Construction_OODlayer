# ============================================================================
#  이 파일이 하는 일: 패키지 전체 테스트의 "진입점(entry point)". `julia --project -e 'using Pkg; Pkg.test()'`
#  로 실행하면 이 파일이 돌며, 아래 @testset 들이 각 하위 테스트 파일을 include 해서 순서대로 돌림.
#  프로젝트 속 역할: IDs / Potential Fields / Twist / Demo 네 묶음을 한 번에 검증.
#  여기서는 여러 테스트가 공통으로 쓰는 헬퍼 array_isapprox(배열 근사비교)도 정의함.
#  Julia 문법 참고:
#   · using X : 패키지 X 를 불러와 이름을 현재 범위로 가져옴.
#   · @testset "이름" begin ... end : 테스트 묶음. 안의 @test 결과를 모아 요약 보고(중첩 가능).
#   · @inline function f(...) where {F<:AbstractFloat} : F 는 타입 파라미터(제네릭). where 로 F 를
#     "부동소수 하위 타입"으로 제약. @inline = 컴파일러에 인라인 힌트.
#   · f(x::AbstractArray{F}) vs f(x::AbstractArray{F}, y::F) : 인자 타입만 다른 두 메서드(다중 디스패치) —
#     "배열 vs 배열" 비교와 "배열 vs 단일값" 비교를 같은 이름으로 구분.
#   · zip(x,y) : 두 배열을 짝지어 동시 순회. eps(F) = F 타입의 기계 정밀도(아주 작은 수).
# ============================================================================

using ConstructionBots

using StaticArrays
using CoordinateTransformations
using GeometryBasics
using Rotations

using Graphs
using LazySets
using LinearAlgebra

using Test
using Logging

# Set logging level
global_logger(SimpleLogger(stderr, Logging.Warn))  # 테스트 중 로그는 Warn 이상만 출력(수다스러운 로그 억제)

# 두 배열 x, y 를 원소별로 근사 비교하는 헬퍼(길이 다르면 false). 테스트 전반에서 재사용.
@inline function array_isapprox(x::AbstractArray{F},
                  y::AbstractArray{F};
                  rtol::F=sqrt(eps(F)),   # 상대 허용오차(기본: 정밀도의 제곱근)
                  atol::F=zero(F)) where {F<:AbstractFloat}  # 절대 허용오차(기본 0)

    # Easy check on matching size
    if length(x) != length(y)  # 길이부터 다르면 비교 불가 → 바로 false
        return false
    end

    for (a,b) in zip(x,y)  # 두 배열을 짝지어 순회
        if !isapprox(a,b, rtol=rtol, atol=atol)  # 한 쌍이라도 오차범위 벗어나면
            return false
        end
    end
    return true  # 모두 근사 일치
end

# Check if array equals a single value
# 위 array_isapprox 의 다른 버전: 배열 x 의 모든 원소가 하나의 값 y 에 근사한지 검사(다중 디스패치).
@inline function array_isapprox(x::AbstractArray{F},
                  y::F;
                  rtol::F=sqrt(eps(F)),
                  atol::F=zero(F)) where {F<:AbstractFloat}

    for a in x  # 원소를 하나씩 y 와 비교
        if !isapprox(a, y, rtol=rtol, atol=atol)
            return false
        end
    end
    return true
end

# Define package tests
# 전체 테스트를 담는 최상위 묶음 — 아래 네 하위 묶음을 순서대로 include 해서 실행.
@testset "ConstructionBots Tests" begin
    @testset "IDs" begin                 # 노드 ID 생성 테스트
        include("test_ids.jl")
    end
    @testset "Potential Fields" begin     # potential field(충돌회피/유도) 테스트
        include("test_potential_fields.jl")
    end
    @testset "Twist" begin                # twist(속도)로 자세 이동 테스트
        include("test_twist.jl")
    end

    @testset "Demo" begin                 # 실제 레고 빌드 데모를 끝까지 돌리는 통합 테스트
        include("test_demo.jl")
    end

    # 2026-08-24 (spec §5.5, Task 6): grounding 키가 남은 두 사건(fault·battery)에 맞는지.
    # `emitted_key` 에 `SwapBattery` 분기가 없으면 battery grounding 이 **에러 없이** 0 이 된다.
    @testset "OOD grounding keys" begin
        include("ood_truth_keys.jl")
    end

    # 2026-08-24 (Task 6 수정 라운드 1, 판정 R-46): `policy.jl` 의 집행 가능 매크로 화이트리스트가
    # `action_registry.json`(어휘 단일 진실원)에 묶여 있는지. 리터럴로 되돌아가면 어휘 밖 팔이
    # **에러 없이** 집행돼 판에 거짓 라벨로 박힌다.
    @testset "policy macro whitelist ↔ action registry" begin
        include("policy_macro_binding.jl")
    end

    # 2026-08-26 (tool-lane step A, Task 1): event_descriptors_of 의 결과가 route() 의 반환에
    # "descriptors" 키로 실리는지. 이 키가 빠지면 LLM 이 문장 한 줄만 받고 숫자 서술자를 못
    # 받는다(교정 유무와 서술자 계산이 한 게이트에 묶였던 옛 결함의 재발 방지).
    # 🔴 2026-08-29 (§B-1): novelty 축이 삭제되어 `route()` 에 **분기 자체가 없어졌으므로**
    # 그 파일의 명제는 더 강하게 성립한다("교정 없이도 산다" → "교정이라는 개념이 없다").
    @testset "router descriptors survive (교정이라는 개념 없이)" begin
        include("route_descriptors_survive.jl")
    end

    # 2026-08-26 (tool-lane step A, Task 2 — 리뷰 라운드 1 F2 · 라운드 2 G1+G2 · 라운드 4 J1-J5):
    # `service_decide` 의 `agents` kwarg 와 `decide_all` 호출부의 `CB.open_agent_descriptors(env)`
    # 는 `policy_macro_binding.jl` · `battery_menu_lanes_agree.jl` · `tools/test_policy_oracle.jl`
    # · `tools/test_policy_escalation.jl` 어느 게이트도 실행하지 않는 코드 경로였다(실측: 두 줄을
    # 각각 `error(...)`로 바꿔치기해도 넷 다 초록).
    # 🔴 라운드 1 은 이 구멍을 **부분적으로만** 메웠다 — kwarg 선언과 `open_agent_descriptors`
    # 원시 함수만 잰 세 어서션은, payload 조립 줄(policy.jl:~550)도 `decide_all` 호출부 줄
    # (policy.jl:~1134)도 한 번도 안 태운다(실측: `env.sched` 로 되돌린 원래 버그를 되살려도
    # Pass 5/5 로 그대로 초록이었다). 라운드 2 가 네 번째 어서션을 더했다 — `decide_all(env,
    # truth)` 를 직접 실행해 그 두 줄을 **실제로** 태우고, 나가는 요청 본문의 `"agents"` 를 잰다.
    # 🔴 라운드 4 (J1)가 **그 요청을 가로채는 방식**을 바꿨다. 라운드 2~3 은 `HTTP.post` 를
    # **패키지 제네릭 해적질**로 덮어썼다 — 그 정의 하나가 메서드를 셋 심는데(위치인자 메서드 ·
    # `Core.kwcall` 정렬 메서드 · 본체) 라운드 3 의 `Base.delete_method` 는 첫째만 지웠고, 이
    # 레포의 실제 호출자는 전부 키워드 인자를 넘겨 둘째로 디스패치한다(실측: "지웠다" 뒤에도
    # 해적 메서드가 실제 키워드 호출에 계속 응답했다). 지금은 그 파일이 **로컬 `HTTP.serve!`
    # 서버**를 커널이 고른 임시 포트(`listenany=true`)에 띄우고, `ENV["DSPY_URL"]` 을
    # `policy.jl` 의 `include` 동안에만 그리로 돌린 뒤 `finally` 에서 원래 값으로 되돌린다 —
    # **어떤 패키지 제네릭에도 메서드를 심지 않는다.** 그래서 이 게이트 뒤에 오는 인프로세스
    # 시험이 스텁에 걸릴 일이 없다. 왜 그게 중요한가(라운드 5 L4 로 범위를 좁힌 서술):
    # ⚠️ 2026-08-29 정정: 아래 서술의 **기전**은 바뀌었다 — `replan.jl` 이 예외를 3회 재시도로
    # 삼키던 `llm_to_proposal` 호출은 Anthropic 레인과 함께 삭제됐다. 하지만 **결론은 그대로**
    # 다: 그 자리의 심각도 분기(soft→`:noop`, critical→`engage_fallback!`)가 producer 경로에
    # 그대로 남아 있어, 조용한-실패 위험은 여전히 soft 이벤트 경로 하나다. (옛 기전 서술:)
    # `replan.jl` 이 `llm_to_proposal` 의 예외를 3회 재시도로 삼키고, 끝내 실패하면
    # **`_event_criticality(event) === :soft` 인 경우에만**(`:740`) `@warn` 하나 남기고
    # `:noop` 을 돌려준다(`:742`) — critical 이벤트는 `engage_fallback!` 후 `:fallback`(`:746`),
    # 즉 line-stop 이지 침묵이 아니다. 그러니 조용한-실패 위험은 **soft 이벤트 경로 하나**다:
    # 그 경로 위의 인프로세스 시험이 스텁에 걸리면 "초록인데 아무것도 안 재는" 상태가 된다.
    # 실측 환경을 밝혀 둔다(라운드 5 L5): 두 줄을 각각 `error(...)`로 바꾼 것과 원래 버그
    # (`env.sched`)를 되살린 것이 이 게이트를 빨갛게 만드는 것은 **스크래치패드 오버레이 사본을
    # `julia +lts --project=. <파일>` 로 단독 실행해서** 쟀다(수정 라운드 2·4 보고서). 이
    # 배선(`Pkg.test()`) 안에서의 초록 기준선은 라운드 5 가 따로 쟀다 —
    # `service_decide ships agents | 10  10`, 스위트 264 pass / 0 fail / 1 error / 265
    # total. 단독 초록이 스위트 초록의 증거가 아니라는 것은 라운드 4 가 실제로 밟은 함정이다
    # (`import Sockets` 가 `Pkg.test()` 샌드박스에서 안 풀려 게이트가 통째로 에러였다).
    @testset "service_decide ships agents" begin
        include("service_decide_ships_agents.jl")
    end

    # 2026-08-29 (Plan B / T4b): 파이썬 서비스는 `MacroRequest.zones` 를 이미 선언하고
    # 프롬프트에 렌더하는데(5d39eebe) Julia 쪽에서 **아무도 그 값을 안 실었다** —
    # 필드가 선언돼 있으나 휴면이었다. 이 게이트는 `decide_all` 을 실제로 실행해 나간 요청
    # 본문의 `"zones"` 를 잰다(위 agents 게이트와 같은 루프백 서버 방식 — 8077 로는 한
    # 요청도 안 나간다). 단독 `32 pass`. 변이 실측: payload 조립 줄 삭제 · `decide_all`
    # 호출부 kwarg 삭제 각각 `28 pass / 2 fail / 2 error`.
    # ⚠️ 이 파일도 agents 게이트처럼 자기 env 를 짓는다(실측: 단독 1:46 중 테스트 블록 14.6s
    #    — 나머지는 패키지 로드 + `run_lego_demo`). 스위트 시간이 그만큼 는다.
    @testset "service_decide ships zones" begin
        include("service_decide_ships_zones.jl")
    end

    # 2026-08-29 (§A-1): kind 색인 라우터는 처음 보는 `OODTruth` 타입을
    # `routing_kind="unknown:<타입이름>"` 으로 알아보고 LLM 으로 보내는데, **그 판정이
    # 페이로드에 한 글자도 안 실렸다** — 본문의 `kind` 는 `ood_features` 의 `else` 분기라
    # `"fault"` 이고, 모델은 자기가 처음 보는 사건을 받았다는 것을 모른 채 답했다. 이 게이트는
    # 위 두 게이트와 **같은 루프백 서버 방식**으로 나간 요청 본문을 붙잡아, 모르는 타입 하나의
    # **같은 본문 안에서** `routing_kind="unknown:MeteorTruth"` 와 `kind="fault"` 가 함께
    # 서 있는지 잰다(그 비대칭이 §A-1 의 측정 대상이고, `kind` 는 surrogate 피처라 안 고친다).
    # 단독 `19 pass`. 변이 실측(`/tmp` 오버레이 사본, 레포는 안 건드렸다): `service_decide` 의
    # payload 조립 줄 하나를 지우면 `12 pass / 3 fail / 4 error` — (1)(2) 두 절이
    # `haskey(body,"routing_kind")` 와 `KeyError: :routing_kind` 로 빨개진다.
    # ⚠️ 이 파일도 위 둘처럼 자기 env 를 짓는다 — 스위트 시간이 그만큼 는다.
    @testset "service_decide ships routing_kind" begin
        include("service_decide_ships_routing_kind.jl")
    end

    # 2026-08-29 (Plan B / T1 · T-C): DSPy 서비스가 이미 내던 tool 레인 키를 Julia 의
    # `policy_entry` 가 전부 떨어뜨리고 있었다. (T-C 가 `tool_choice` · `text_rescue` 를 더해
    # **여덟에서 열**이 됐다.) 이 게이트는 그 열 개가
    # `decide_all(...).tool_lane` 까지 **값까지 그대로** 오는지, 그리고 spec §9-2 의 삼상
    # (`nothing`="못 쟀다" ≠ `false`="재서 어긋났다")이 언어 경계에서 살아남는지 잰다.
    # 바로 위 게이트와 **같은 패턴**이다 — 루프백에 진짜 HTTP 서버를 띄우고 `DSPY_URL` 을
    # policy.jl include 동안에만 그리로 돌린다(패키지 제네릭 해적질 없음, 8077 로 나가는
    # 요청 없음 = 유료 OpenAI 호출 없음). 같은 이유로 `Sockets` 를 직접 import 하지 않는다
    # (그 함정이 위 게이트를 이 배선 안에서 통째로 에러로 만든 이력이 있다).
    @testset "tool lane keys survive to decide_all" begin
        include("tool_lane_keys_survive.jl")
    end

    # 2026-08-30 (Plan B / T1): DSPy 서비스는 이미 `synthesis` dict(합성 레인, 아홉 키 —
    # `tool_minted` 는 응답 최상위, 나머지 여덟은 `synthesis` 안, `params` 포함)를 내고
    # 있었는데 Julia 에 소비자가 0개였다. 이 게이트는 `policy_entry` 의 성공·실패 두 분기가
    # `SYNTH_LANE_KEYS` 아홉을 전부 나르는지 잰다. `tool_lane_keys_survive.jl` 과 달리 루프백
    # HTTP 서버가 필요 없다 — `policy_entry` 를 손으로 만든 JSON3 픽스처로 직접 부른다
    # (policy.jl 은 standalone include 가능, `using ConstructionBots` 불필요, 실측).
    @testset "synth lane keys survive to policy_entry" begin
        include("synth_lane_keys_survive.jl")
    end

    # 🔴 2026-08-29 (Plan B / T-C): `tool_choice="required"` 는 공짜가 아니다 — 컨트롤러가 같은
    # 요청·같은 빌드로 그 손잡이만 갈라 유료 2콜을 냈고, 강제 판에서 프로바이더가 message
    # content 를 **비웠다**(`reasoning=""` · `expressible=null` · `chosen=""` → coerced NOOP,
    # **예외 없음**). 그래서 강제는 라우터가 **familiar 라고 실제로 잰** 사건에만 걸기로 했다.
    # 🔴 2026-08-29 (§B-1): 그 판정을 내던 novelty 축이 삭제됐다 — `route_verdict` 는
    # `novelty_measured` 도 `novel` 도 더 이상 내지 않으므로, 그 세 상태를 재던 절과 그 전제
    # (감지기 부재)를 재던 절을 **지웠다**(그 파일 머리말이 무엇을 왜 지웠는지 적는다).
    # 이 게이트가 지금 재는 것 셋: `tool_choice_for` 진리표 3상태 전수(순수 함수의 계약만
    # 남았다 — 채울 생산자가 없다) · 🔴 **나가는 요청 본문**에 그 키가 없다는 사실(= 게이팅이
    # 죽었다) · `service_decide` 의 적재 규약과 단일 채널 키 집합.
    # 위 두 게이트와 같은 루프백 패턴이다 — 8077 로 나가는 요청 0건 = 유료 호출 0건.
    @testset "router-gated tool_choice" begin
        include("tool_choice_gate.jl")
    end

    # 🔴 2026-08-29 (Plan B / T2): **이 계획의 분수령**을 지키는 게이트. T2 이전까지 집행
    # 사슬은 `CB.hot_swap_robot!(env, truth.robot; ...)` — 주입기가 **이미 아는 값** — 을
    # 썼고, 그래서 LLM 의 tool 호출은 세계에 대해 인과가 없었다. 이 게이트가 재는 명제는
    # 하나다: `tool_args` 의 agent 가 `truth.robot` 과 **다를 때**, 세계는 `truth.robot` 이
    # 아니라 LLM 이 고른 agent 에서 바뀐다. ⚠️ 두 값이 같은 시험은 배선 전후로 똑같이
    # 통과하므로 아무것도 재지 않는다 — 그래서 이 파일은 A ≠ B 를 잡고 두 로봇의 SoC 를
    # 서로 다른 값으로 벌려 둔다.
    # 같이 지키는 것: 접지 실패(`resolve_agent_id` 가 열거 밖 문자열을 거절)와 그 폴백이
    # **기록되는지**(R2/R6 — 조용한 폴백은 "LLM 이 골랐다" 와 "주입기가 알려줬다" 를 같은
    # 관측으로 만든다), 그리고 R16(팔이 강제/이탈된 판에서는 tool 의 agent 를 안 쓴다).
    # 🔴 서비스를 **아예 안 부른다**(집행 함수를 직접 부른다) — 8077 로 나가는 요청 0건.
    @testset "enactment uses the LLM's agent" begin
        include("enact_uses_llm_agent.jl")
    end

    # 🔴 2026-08-29 (Plan B / T3): LLM 이 낸 `tool_args` 를 거르는 자리는 오늘 이 레인에
    # `CB.ground_tool_args` **하나뿐이다** — 디코드 시점 차단이 없고(dspy 3.3.0 의 `dspy.Tool`
    # 에는 `strict` 필드 자체가 없다) 두 번째 방어선 `grammar_ground_check` 는
    # `RespecProposal` 을 받아 tool 레인을 못 본다. 그러니 이 게이트가 약하면 방어선이 없는
    # 것과 같다. 재는 것 둘: (a) 판정이 **삼상이고 셋 다 도달 가능한가**(둘만 닿으면 그것은
    # 거짓말이 하나 든 이상 상태다), (b) 🔴 spec §4-1 — `reject` 가 **결정을 지우지 않는가**
    # (매크로는 그대로 `truth.robot` 으로 집행된다). 서비스는 안 부른다 — 8077 요청 0건.
    @testset "tool args grounding — 삼상 판정" begin
        include("tool_args_grounding.jl")
    end

    # 🔴 2026-08-29 (Plan B / T5): spec §8 의 ④ 실효성 층. 앞의 셋(①문법·②접지·③안전)을
    # 전부 통과한 편집이 **관측된 막힘에 실제로 닿았는가** 를 `zone_corridor.jl` 의 순수
    # 술어로 집행 **전후** 재서 판정한다. 재는 명제 하나: 이 층은 세계의 *상태* 가 아니라
    # 편집이 만든 *차이* 를 잰다 — 사후 상태만 보면 "고쳤다"와 "고칠 것이 없었다"가 같은
    # 관측이 되고, 전 측정을 사후로 옮기면 `resolves` 가 도달 불가가 된다(변이시험 둘 다
    # T5 보고서에 실측 RED 출력이 있다). 값 다섯이 전부 도달 가능한지도 여기서 지킨다
    # (`resolves` · `inert` · `deferred:no_efficacy_measure`(R10) · `deferred:not_enacted`).
    # 같은 파일이 `emitted_keys`(= `CB.emitted_key` 를 **불러서** 대조, 리터럴 금지)와
    # `reasoning`(글자 그대로, 절단 없음)도 지킨다. 서비스는 안 부른다 — 8077 요청 0건.
    @testset "efficacy measures the edit (Plan B / T5)" begin
        include("efficacy_measures_the_edit.jl")
    end

    # 🔴 2026-08-29 (Plan B / T2b): **두 번째 엔진**(`tools/monitor/render_demo.jl`)에도 같은
    # 인과를 잇는다. T2 는 `run_demo.jl` 레인만 고쳤고 render 레인은 `macro_to_proposal` 이
    # `truth.robot` 으로 제안을 만들어 LLM 의 tool 호출이 세계에 대해 인과가 없었다. 이제
    # 두 엔진이 **같은 함수**(`enact.jl` 의 `enact_target`)를 부르므로 R16(강제/이탈 팔
    # 거절)과 R2/R6(폴백 기록)이 한쪽에서만 조용히 썩을 수 없다.
    # 🔴 `render_demo.jl` 은 스크립트라 include 가 불가능하다 — 그래서 이 게이트는
    # `policy_producer` 의 **원문 텍스트를 뽑아 실행한다**(복제본을 재지 않는다). 같은 수법으로
    # `run_demo.jl` 의 결정 행 조립부(`this_decision` … `merge!(this_decision, _e.row)`)도
    # 실행해서, `enact_decision!` 이 낸 row 가 **결정 행까지 살아 도착하는지**를 값으로 잰다
    # (`enact_uses_llm_agent.jl` (9) 는 row 본체를, (10) 은 호출부의 존재를 지킨다 — 그 둘의
    # **합류**가 성립하는지는 아무도 안 쟀다). 서비스는 안 부른다 — 8077 요청 0건.
    @testset "render lane uses the LLM's agent (Plan B / T2b)" begin
        include("render_lane_uses_llm_agent.jl")
    end

    # 🔴 2026-08-29: 여기 있던 게이트 "llm_producer grounds the agent (Plan B / T2c)" 는
    # **삭제됐다** — 그것이 지키던 `render_demo.jl` 의 `llm_producer`(`DEMO_LLM=1`) 레인이
    # Anthropic 레인과 함께 사라졌기 때문이다(그 레인은 `llm_to_proposal` 로 :8000 의 파이썬
    # `/propose` 서비스를 불렀고, 그 서비스의 유일한 구현이 `anthropic.Anthropic()` 이었다).
    # 지키는 대상이 없는 게이트는 초록이어도 아무것도 안 지킨다.
    # ⚠️ 위 T2b 게이트는 그대로다: 이 엔진에 남은 유일한 producer 인 `policy_producer` 가
    # `enact_target` 뒤로 들어가 있다는 성질을 계속 잰다.

    # 2026-08-27: lane_select.jl 은 의존성 0 인 순수 함수인데 게이트가 배선돼 있지 않았다.
    # 🔴 2026-08-29 (T11 → §B-1): 이 묶음의 옛 이름 *"vocabulary gap outranks novelty"* 와
    # *"축 1(어휘 미달)이 이 함수의 우선순위에 얹힌다"* 는 서술은 **둘 다 낡았다.** T11 이 두 축
    # (어휘 미달 · novelty)을 **kind 색인 라우터 하나**로 갈아치웠고, §B-1 이 novelty 축을
    # 지웠다 — 우선순위라고 부를 두 축이 이제 없다. 그 파일이 실제로 재는 것은 `select_lane` 의
    # kind 분기표 전수와 `routing_kind` 의 전총성이다.
    @testset "lane selection — kind 색인 라우터 분기표" begin
        include(normpath(joinpath(@__DIR__, "..", "tools", "monitor", "test_lane_select.jl")))
    end

    # 🔴 2026-08-25 (최종 브랜치 리뷰 F1): 아래 셋은 **레지스트리 파생과 도장 계약을 지키는
    # 게이트인데 이 진입점에 실려 있지 않았다** — 누가 손으로 `julia +lts --project=.
    # test/<파일>.jl` 를 칠 때만 돌았다. "돌지 않는 게이트" 는 "실패할 수 없는 게이트" 의
    # 사촌이다(이 계획이 후자를 여섯 개 찾았다). 셋 다 단독 실행에서 초록임을 확인하고 싣는다.
    #   smdp_action_name_smoke : gen_oracle_dataset.jl 의 ACTION_NAME/MACRO_COST 가 레지스트리
    #                            파생인가 (리터럴이 되살아나면 라벨 행에 틀린 이름·비용이 찍힌다)
    #   smdp_stamp_smoke       : 어휘 도장 v4-3arms · 동역학 도장 · surrogate 산출물 도장
    #   smdp_hazard_knobs      : D-3/D-4/D-5 손잡이와 λ 단일 진실원, 라벨 레인 == 실행 레인
    @testset "SMDP action-name derivation" begin
        include("smdp_action_name_smoke.jl")
    end
    @testset "SMDP stamps" begin
        include("smdp_stamp_smoke.jl")
    end
    @testset "SMDP hazard knobs" begin
        include("smdp_hazard_knobs.jl")
    end

    # 🔴 2026-08-25: 방전 정지가 **결정 epoch 를 만들지 않는다**는 계약. 지운 `_fire_battery_stall!`
    # 이 되살아나거나, 정지 기록(`STALLED_ROBOTS`)이 같이 지워지면 빨개진다 — 후자는 스케줄 DAG
    # 교착의 유일한 사후 증거를 잃는 것이라 전자만큼 비싸다.
    @testset "battery stall raises no OOD" begin
        include("battery_stall_no_ood.jl")
    end

    # 🔴 2026-08-25: zone 주입 게이트가 어휘(`case_kinds`)에서 분리돼 있는가. `:zone in kinds` 로
    # 되돌아가면 주입기 넷이 다시 도달 불가가 된다(2026-08-24~25 동안 실제로 그랬다).
    @testset "zone injection gate" begin
        include(normpath(joinpath(@__DIR__, "..", "tools", "monitor", "test_zone_gate.jl")))
    end

    # 🔴 2026-08-25: battery 메뉴의 SoC 분할이 **두 레인에서 같은가**. 라벨 레인만 갈랐던 시절엔
    # mild 에서 실행 레인이 라벨 격자에 없는 팔을 골랐다(= surrogate 가 본 적 없는 팔).
    # 같은 파일이 mild 가 NOOP-only 라는 설계 결정(= L2 인계 표식)도 함께 지킨다 — "mild 는
    # 닫힌 어휘에 수복이 없다" testset 이 그것이고, `ae7e935c` 이후 손 안 대고 그대로다.
    # 🔴 2026-08-31: `test/mild_menu_is_noop_only.jl`(T8, "mild 는 NOOP 하나뿐" (1)(2)(3))이
    # 지워졌다 — 사용자가 mild 하게 닳은 로봇을 저부하 조립으로 라우팅할 수 있게 그 설계를
    # 의도적으로 뒤집을 예정이라 그 게이트가 앞길을 막았다. 미기록 soc 를 다루던 명제 (4)도
    # 이 파일로 옮겨 아래에 살아 있다.
    # 🔴 **정정 (2026-09-01, S1 final wave / F-3)**: 이전 판의 이 주석은 "(4)만 옮겨와 살아
    # 있다"고 적어 (1)(2)까지 잃은 것처럼 읽혔는데, 그건 거짓이었다 — (1)(2)("mild 는
    # NOOP-only")는 파일 삭제와 무관하게 위 testset이 계속 지키고 있었다(옮겨온 게 아니라
    # 애초에 여기 따로 있었다). 🔴 **재정정 (2026-09-01, correction pass C-2)**: 바로 위
    # "실제로 게이트 없이 남은 것은 명제 (3) 뿐"도 **거짓이었다** — 세 번째로 틀린 서술.
    # **실측**: `action_registry.jl :: soc_split_enabled` 기본값을 `"1"` → `"0"` 으로 뒤집으면
    # `soc_ladder_is_coherent.jl` (1)이 아니라 이 파일의 첫 testset("실행 레인 == 어휘
    # 단일 진실원")이 빨개진다(3 passed / 3 failed) — `live_menu` 가 `soc_split_enabled()` 를
    # 거치고 `registry_menu` 는 `split=true` 리터럴을 넘기므로 그 기본값에서 갈린다.
    # **`mild_menu_is_noop_only.jl` 삭제로 게이트를 잃은 명제는 없다** — (1)(2)는 위
    # testset이, (3)은 방금 잰 첫 testset이, (4)는 F-1c testset이 지킨다.
    @testset "battery menu lanes agree" begin
        include("battery_menu_lanes_agree.jl")
    end

    # 2026-08-31 (S1/T1): 공간 사건의 harm 이 덮임(면적비)이 아니라 막힘에서 나오는가.
    # 2026-08-30 라이브 판에서 프롬프트가 자기모순이었다 — 기하 블록은 "32/251 이 얼어붙었다"
    # 고 적는데 서술자는 harm=0.00 이었고, 모델의 reason 이 그 0 을 인용하며 NOOP 을 골랐다.
    @testset "zone harm is blockage" begin
        include("zone_harm_is_blockage.jl")
    end

    # 2026-08-31 (S1/T2): battery 사건이 payload/함대 사실을 싣는가. 🔴 이 게이트는 함대 절만
    # 잰다 — 운반 작업 순회는 진짜 env 가 필요하므로 여기 없다(파일 머리말이 그 경계를 적는다).
    @testset "battery load features" begin
        include("battery_load_features.jl")
    end

    # 2026-08-31 (S1/T3): 라우팅 경계·메뉴 경계·정지 임계·두 엔진 기본값·라벨 레인이 하나의
    # 사다리인가. 🔴 이 게이트가 없던 동안 (0.1, 0.2] 구간이 죽어 있었다 — LLM 레인으로
    # 가면서 개입 팔을 다 갖는 구간이라 합성이 구조적으로 발화 불가였다.
    @testset "SoC ladder is coherent" begin
        include("soc_ladder_is_coherent.jl")
    end

    # 2026-08-31 (S1/T4): 결정 시점 후보 간선 상계 프로브가 세계를 안 건드리는가.
    # 🔴 이 프로브는 상계만 낸다 — 0 이면 결론이고 >0 이면 아무 결론도 아니다(파일 머리말).
    @testset "MILP slot probe is pure" begin
        include("milp_slot_probe_is_pure.jl")
    end

    # 🔴 2026-08-25: `DS_BSOC` 기본 사다리의 모든 칸이 채점 가능한 deep 구간인가(= 팔을 비교할 수
    # 있는가). mild 칸이 다시 들어오면 대조가 0인 행이 생기고, 칸이 하나로 줄면 2026-08-05 에
    # 고친 "심각도 축이 점 하나" 결함이 재현된다 — 두 어서션이 각각 그 둘을 막는다.
    @testset "battery ladder is deep-only" begin
        include("battery_ladder_is_deep_only.jl")
    end

    # 2026-08-29 (Plan B / B0): `primitive_registry.json` 은 T2(tool 합성)의 원시 연산
    # 알파벳인데, 그 소비자(T2)가 아직 안 지어졌다. 소비자 없는 레지스트리는 아무도 안 읽는
    # JSON 이고 조용히 썩는다 — 그리고 썩은 채로 B3 에 도착하면 "합성기가 이상한 tool 을
    # 만든다"라는 증상으로 나타나 원인 추적이 길어진다. 이 게이트가 그 사이를 버틴다:
    # 레지스트리가 이름 짓는 impl·gate·predicate 가 전부 오늘 CB 에서 해석되는가, 그리고
    # spec §7-2 의 "채점 어휘와 섞지 않는다"가 이름 공간 수준에서 지켜지는가.
    # 변이 4종(impl 오타 · gate 오타 · 채점 어휘와 이름 충돌 · when_to_use 공백)으로
    # 실제로 빨개지는 것을 확인했다 — `PRIMITIVE_REGISTRY` 로 오염 사본을 물려서 쟀다.
    @testset "primitive registry resolves" begin
        include("primitive_registry_resolves.jl")
    end

    # 2026-08-30 (T2): 위 게이트는 이름이 CB 심볼표에 `isdefined` 인지만 잰다. 이 게이트는
    # 그 이름을 실제로 부를 수 있는 callable 로 해석하는 `CB.resolve_primitive` 자체를
    # 잰다 — 미지 이름의 거부, harness_args 전달, 레지스트리 부재시 하드 스톱까지 포함해서.
    @testset "minted tool resolves" begin
        include("minted_tool_resolves.jl")
    end

    # 2026-08-30 (T3): 위 둘은 **이름**만 잰다. 이 게이트는 그 이름을 실제 호출로 바꾸는
    # `bind_primitive_args`·`enact_minted!` 를 잰다. 재는 것 셋이 특히 중요하다:
    #  · 🔴 알파벳 19 중 **실제로 부를 수 있는 것은 8** 이다(연언지 셋: harness·arity·kwargs).
    #    (2026-09-02 실측: 표 19 · 집행 가능 8. 연언지 (i) 만 보면 `harness_args ⊆ {"env"}`
    #    로는 16, `BINDABLE_HARNESS_ARGS = {"env","invariant"}` 로는 17 이 통과한다 — 즉
    #    (i) 만 믿으면 **여덟 개**가 호출 시점 `MethodError` 로 죽고 집행부의 `try` 가 그것을
    #    `:admit`/집행됨으로 보고한다 = 거절보다 나쁜 거짓 admit. 실제 사유 분포도 실측이다:
    #    `:arity` 9 · `:harness` 2.) 이 게이트가 그 **8** 을 이름으로 못 박는다.
    #  · 🔴 2026-09-02 (cargo-ban T7) 알파벳 교체 1:1 — `reprice_agent_by_payload` 가 나가고
    #    `forbid_heavy_cargo` 가 들어왔다. **개수는 19/8 그대로이고 이름 집합만 갈렸다** —
    #    그래서 개수만 세는 게이트는 이 변경에 침묵한다. `ENACTABLE_TODAY` 와
    #    `REGISTRY_SURFACE_TODAY` 가 **이름으로** 못 박는 것이 그 침묵을 막는다.
    #  · 🔴 `zone_keys` 를 String 으로 넘기면 `Dict{Symbol,Ball2}` 소비자들이 조용히 걸러
    #    `zones == []` 가 되고 `translate_whole_build!` 가 `:already_clear` 를 낸다 =
    #    맞는 답이 "존을 치웠다"는 거짓 증거로 둔갑한다. 호출 전에 Symbol 강제 + 생존 검사.
    #  · 🔴 "불렀는데 아무 일도 없었다"(`applied=false`)와 "부르지 않았다"(`:reject`)와
    #    "던져서 세계가 절반이다"(`partial=true`)와 "못 쟀다"(`:unreadable_return`)는 서로
    #    다른 사건이다(spec §9-2). 파생 `world_maybe_dirty` 가 앞의 둘을 합쳐서 나른다.
    #    조용한 성공 표는 **집행 가능한 여덟 전부**를 덮어야 한다 — 처음 둘만 채웠을 때
    #    넷이 아무 일도 안 하고 `applied=true` 를 냈고, 그중 `force_advance_stuck_carrier!`
    #    는 `CARRIER_RESCUE` 미설정(= 기본 환경)이면 언제나 `:disabled` 다.
    #  · 🔴 레지스트리의 이름→impl 짝과 params 키를 못 박는다. 그 둘을 안 재면 params 에
    #    키를 더하거나 impl 을 다른 함수로 돌리는 편집이 **스위트 전부 초록인 채로**
    #    LLM 이 부를 수 있는 표면을 넓힌다(`primitive_registry_resolves.jl` 은 `params` 가
    #    존재하는지만 보지 키를 안 본다).
    # 변이 18종(명제 12 + 세부 6)으로 각각 빨개지는 것을 확인했다 — task-3-report.md 에 트랜스크립트.
    @testset "minted tool enacts" begin
        include("minted_tool_enacts.jl")
    end

    # 2026-08-30 (T4): 위 셋은 `CB.enact_minted!` 까지를 잰다. 이 게이트는 **렌더 레인의
    # 배선**을 잰다 — `enact.jl::enact_minted_decision!`. 재는 것 넷이 특히 중요하다:
    #  · 🔴 `handled` 는 `(:admit) && applied` 가 **아니라** `(:admit) && world_maybe_dirty` 다.
    #    1단계가 세계를 바꾸고 2단계가 던진 판은 `applied=false` 인데 세계는 이미 편집돼
    #    있다(`undo === :none`). 그 반쯤 고쳐진 세계 위에 기본 복구 사슬을 얹는 것은 안 얹는
    #    것보다 나쁘다.
    #  · 🔴 `[minted]` 줄은 **모든 경로**에서 찍힌다(조기 반환·예외 포함). `policy_producer` 는
    #    OOD 마다 도달하지 않으므로(`is_reform_alarm` · `truth_for_event` 조회 실패), 조건부로
    #    찍으면 줄의 부재가 원인 셋을 갖게 되어 다음 태스크가 못 가른다.
    #  · 🔴 레지스트리가 망가져 `PRIMITIVE_TABLE` 이 `error(...)` 를 내도 던지지 않는다.
    #    새면 `maybe_respecify!` 의 producer `try` 가 잡아 비-`:soft` 사건에서
    #    `engage_fallback!`(= 라인 정지)이 걸리고 로그는 JSON 오타 대신 OOD 를 탓한다.
    #  · 🔴 MILP 프로브는 센티넬이다 — 재풀이가 없으면 `n_candidate_edges` 를 숫자로 안 찍는다.
    # 서비스 호출 0건 · `render_demo.jl` 실행 0회(순수 함수 게이트).
    @testset "minted tool wiring (tools/monitor/test_minted_wiring.jl)" begin
        include(normpath(joinpath(@__DIR__, "..", "tools", "monitor", "test_minted_wiring.jl")))
    end

    # 🔴 2026-08-25 (R-66): `tools/test_policy_oracle.jl` 는 위 F1 배선에서 **빠진 네 번째
    # 고아 게이트**였다. 그 결과 `policy.jl` 의 `ORACLE_BATTERY_DEEP_SOC` 가 0.5 로 남아
    # `reference_policy.BATTERY_DEEP_SOC`(0.2)와 갈린 회귀가 최종 리뷰까지 살아남았다
    # (실효: `(0.2, 0.5]` 구간에서 oracle 레인은 팔을 내고 파이썬 채점기는 unscored 로 뺀다).
    # 두 언어의 그 임계값을 묶는 것은 이 게이트 0절 하나뿐이다 — 줄리아 쪽에서 파이썬 상수를
    # 유도할 수 없기 때문이다(이유는 policy.jl 의 그 상수 위 주석).
    #
    # 🔴 **하위 프로세스로 부른다(include 가 아니다).** 그 파일은 스크립트라 마지막 줄이
    # `exit(nfail == 0 ? 0 : 1)` 이다. 여기서 `include` 하면 초록일 때 `exit(0)` 이 걸려
    # **뒤따르는 테스트가 하나도 안 돌았는데 Pkg.test 는 성공으로 보인다** — include 배선은
    # 그 자체로 "실패할 수 없는 게이트" 를 하나 더 만드는 셈이다. 하위 프로세스는 종료코드를
    # 그대로 나르고, 그 파일이 심는 전역 로거·ENV 도 이쪽으로 새지 않는다.
    @testset "policy oracle lane (tools/test_policy_oracle.jl)" begin
        gate = normpath(joinpath(@__DIR__, "..", "tools", "test_policy_oracle.jl"))
        repo = normpath(joinpath(@__DIR__, ".."))
        @test isfile(gate)
        logf = tempname()
        ok = success(pipeline(`$(Base.julia_cmd()) --project=$(repo) $(gate)`;
                              stdout = logf, stderr = logf))
        txt = isfile(logf) ? read(logf, String) : ""
        # 요약 줄은 언제나 보여 준다(초록이어도 몇 개를 쟀는지가 보여야 한다).
        for l in split(txt, '\n')
            occursin("policy oracle lane:", l) && println("    ", strip(l))
        end
        ok || println("---- tools/test_policy_oracle.jl 전체 출력 ----\n", txt)
        @test ok
    end

    # 🔴 2026-08-27 (최종 리뷰 F1): `tools/test_policy_escalation.jl` 은 **다섯 번째 고아
    # 게이트**였다. Task 2 는 `tools/monitor/test_lane_select.jl` 을 여기 배선했는데, Task 3 이
    # T7·T7b·T8·T8b·T9·T9b 여섯을 더한 이 파일은 `runtests.jl` 에도 어떤 하네스에도 없었다 —
    # 이 브랜치가 스스로 내건 Global Constraint("새 Julia 테스트는 반드시 runtests.jl 에
    # 배선한다") 위반이고, 바로 위 R-66 블록이 2026-08-25 에 기록한 **같은 실패**의 재발이다.
    # T9/T9b/T9c 가 R11 회귀(어휘 미달 격상이 novelty 교정 파일에 다시 묶이는 것)의 유일한
    # 방어선인데 사람이 손으로 쳐야만 돌았다.
    #
    # 🔴 **하위 프로세스로 부른다(include 가 아니다).** 위 R-66 주석과 같은 이유다: 그 파일은
    # 스크립트라 마지막 줄이 `exit(nfail == 0 ? 0 : 1)` 이고, `include` 하면 초록일 때
    # `exit(0)` 이 그 자리에서 걸려 **뒤따르는 테스트가 하나도 안 돌았는데 Pkg.test 는 성공으로
    # 보인다.** 하위 프로세스는 종료코드를 그대로 나르고, 그 파일이 심는 전역 로거·ENV 도
    # 이쪽으로 새지 않는다(그 파일은 policy.jl 을 include 하므로 ROUTER_MODE/POLICY const 를
    # 자기 모듈에 만든다).
    @testset "policy escalation gate (tools/test_policy_escalation.jl)" begin
        gate = normpath(joinpath(@__DIR__, "..", "tools", "test_policy_escalation.jl"))
        repo = normpath(joinpath(@__DIR__, ".."))
        @test isfile(gate)
        logf = tempname()
        # 🔴 `JULIA_LOAD_PATH` 를 **지운다**(이 배선을 하자마자 실측으로 드러난 함정).
        # `Pkg.test()` 는 자기 임시 테스트 환경을 `JULIA_LOAD_PATH` 로 심는데, 그 값에는
        # `@stdlib` 가 없다. 자식 julia 는 그것을 물려받으므로 `--project=$(repo)` 를 줘도
        # **선언 안 된 stdlib 를 못 찾는다** — 이 게이트는 `using InteractiveUtils`(T8/T9 의
        # 정적 검사가 쓰는 `@code_lowered`)를 하는데 `Project.toml` 에는 그 stdlib 가 없다
        # (Manifest 1.10.11 고정이라 `Pkg.add` 로 넣을 수도 없다).
        # 실측: LOAD_PATH 를 물려받으면 `ArgumentError: Package InteractiveUtils not found`
        # 로 즉사해 게이트가 **한 검사도 못 돌고** 빨개진다. 지우면 기본
        # `@:@v#.#:@stdlib` 가 복원되어 헤더가 문서화한 단독 실행과 같은 세계가 된다.
        cmd = addenv(`$(Base.julia_cmd()) --project=$(repo) $(gate)`,
                     "JULIA_LOAD_PATH" => nothing)
        ok = success(pipeline(cmd; stdout = logf, stderr = logf))
        txt = isfile(logf) ? read(logf, String) : ""
        # 요약 줄("전부 통과 (N)" / "N개 실패 / M개 통과")은 초록이어도 보여 준다 — 몇 개를
        # 쟀는지가 안 보이면 게이트가 조용히 0개로 줄어들어도 아무도 모른다.
        for l in split(txt, '\n')
            (occursin("전부 통과", l) || occursin("개 실패", l)) && println("    ", strip(l))
        end
        ok || println("---- tools/test_policy_escalation.jl 전체 출력 ----\n", txt)
        @test ok
    end

    # 2026-09-01 (S2 최종 리뷰 F1): edge_cost_multiplier 의 3인자 확장(SoC 훅 뒤에 payload
    # 훅을 곱하는 자리)이 이제 모든 MILP·greedy edge-cost 호출부에 앉아 있다 — 이 파일은
    # 그 전역 회귀 가드다(훅 없으면 3인자 == 2인자 바이트 동일). 씬을 안 짓고 ~0.9s.
    @testset "payload edge multiplier is a global-regression guard" begin
        include("payload_edge_multiplier.jl")
    end

    # 2026-09-01 (S2 최종 리뷰 F1): reprice_agent_by_payload! 의 설치·삼상 규약을 잰다.
    # 씬을 안 짓고 ~1.5s. 🔴 여기 있던 `CB.include(.../minted_tool.jl)` 은 파일
    # 안에서 삭제했다(중복 include 가 운영 메서드 ~5개를 스위트 안에서 재정의했다) — 자세한
    # 내용은 그 파일의 마지막 testset 주석.
    # 🔴 2026-09-02 (cargo-ban T7): 이 원시는 **알파벳에서 빠졌다**(레지스트리에서만; 구현과
    # 이 시험은 음성 대조로 남는다 — 실측상 argmin 을 못 움직이는 재료를 모델에게 주지 않는다).
    # 그래서 이 파일의 "알파벳 결선" testset 은 **부재를 못 박는 쪽으로 뒤집혔고**, 필수 kwarg
    # 구멍은 그 자리를 이어받은 `forbid_heavy_cargo` 로 옮겨 그대로 기록된다.
    @testset "payload reprice install" begin
        include("payload_reprice_install.jl")
    end

    # 2026-09-01 (cargo-ban T6): release_pending_assignments! 의 `agent` 범위 인자.
    # 기본값 보존(= 오늘과 바이트 동일) · 좁힘의 정확성 · faulted×agent 금지를 못 박는다.
    # 🔴 씬을 짓는다(tractor/10대/closed=60) — 한 번만 짓고 fork 로 복제한다.
    @testset "scoped release" begin
        include("scoped_release.jl")
    end

    # 2026-09-02 (cargo-ban T2): 제약 종류 `ForbidHeavyCargo` — 타입 계약 · 컴파일러가 실제로
    # 행을 추가하는가(G-1, 0행이면 빨강) · `RESPEC_SCENE_TREE` 배선과 복원 · 결정론적 동점
    # 처리 · `cargo_burden_after` 의 삼상 규약.
    # 🔴 씬을 짓는다(tractor/10대/closed=60) — 한 번만 짓고 formulate 만 반복한다.
    @testset "ForbidHeavyCargo" begin
        include("forbid_heavy_cargo.jl")
    end

    # 2026-09-02 (cargo-ban T3): 지속 화물 금지 보관소 `STANDING_CARGO_BANS` 와 **모든**
    # formulate_milp 이 그것을 읽는다는 계약. G-5(= `extra_constraints = nothing` 인
    # `rebalance_for_battery!` 모양의 formulate 도 금지를 읽는가 + 금지 전에는 그 로봇이 그
    # 화물을 **가져갔다**는 양성 대조) · G-6(`:state` 등록과 롤아웃 리셋).
    # 🔴 씬을 짓고 **실제로 푼다**(tractor/10대/closed=60, 좁힌 release → OPTIMAL ~0.2s).
    #    🔴 이 파일은 `STANDING_CARGO_BANS` 를 채운다 — 스스로 `finally` 로 비우지만, 뒤에
    #    다른 시험을 넣을 때는 그 전역이 비어 있는지 의심할 것(모든 formulate 가 읽는다).
    @testset "cargo ban store" begin
        include("cargo_ban_store.jl")
    end

    # 2026-09-02 (cargo-ban T4): 화물 금지의 **수명** — 금지는 그 로봇의 배터리가 갈리는 순간까지
    # 산다(술어가 아니라 사건). G-3 은 두 방향을 함께 잰다: 교체된 로봇은 풀리고, **다른 로봇의
    # 금지는 살아남는다**(후자가 `clear_all_cargo_bans!()` 식 과잉 해제를 잡는다). 교체 전에 둘
    # 다 걸려 있다는 양성 대조가 "지울 것이 없어서 초록" 을 막는다.
    # 🔴 여기서 세는 3 단언은 **자식 프로세스 게이트**다 — 진짜 시험 20 단언은 깨끗한 프로세스
    #    안에서 돈다. 이유(스위트 꼬리에서 HEAD 코드 `_soc_of` 가 세그폴트한다 — navigator.jl
    #    중복 include 로 `const BATTERY_FLEET` 이 재정의되기 때문)는 그 파일 머리말에 실측과
    #    스택트레이스까지 적혀 있다. 자식이 일찍 죽으면 sentinel 이 없어 부모가 빨개진다.
    #    씬은 짓지만 전진시키지 않는다(수명 계약은 스케줄 진행과 무관) — MILP 를 안 푼다.
    @testset "cargo ban lifetime" begin
        include("cargo_ban_lifetime.jl")
    end

    # 2026-09-02 (cargo-ban T5): **고장 수습이 마모 평준화를 이긴다** — `fault_robot_and_reassign!`
    # 본문 전체가 금지를 끈 채 돌고 `finally` 로 되살린다(이른 return 이 여럿이라 손으로 복원을
    # 심으면 하나를 빠뜨린다). 보험이지 관측된 결함에 대한 대응이 **아니다**(그 함수의 주석 참조).
    # 🔴 이 시험의 급소: `released_faulted` 레짐에서는 예외가 없어도 금지가 0 행을 낸다(Task 1
    #    실측). 그래서 행 수가 아니라 **그 formulate 시점의 보관소 내용물**을 잰다 — 옵티마이저
    #    팩토리 스파이가 formulate 마다 보관소 스냅샷을 남기고, 같은 판에서 "행 수로는 못 가른다"
    #    (49308 == 49308)는 것 자체를 양성 대조로 단언한다(파일 머리말).
    #    씬을 짓고 closed=60 까지 전진시킨 뒤 **실제로 푼다**(mip_rel_gap 5.0 — 목적값 인용 금지).
    @testset "cargo ban fault exception" begin
        include("cargo_ban_fault_exception.jl")
    end

    # 2026-09-02 (cargo-ban T8): **종단** — 주조된 tool 의 body(release + forbid_heavy_cargo)가
    # `enact_minted!` 로 집행되면 **그 로봇이 실제로 그 화물을 잃는다**(게이트 G-2).
    # 🔴 판정은 `binding` 이 아니라 `JuMP.value(Xa[u,v2]) > 0.5` **+ 음성 대조**다: 아무것도 안
    #    누른 대조에서도 A 가 이미 묶인 정점 2~11개를 잃고(재풀이 잡음), release 가 표적 슬롯을
    #    solve 전에 무효 id 로 되돌려 `binding` 에는 잃을 것이 남지 않는다(Task 1 실측, S-4.4).
    #    두 팔은 **같은 env·같은 그래프**를 보고 commit 을 안 한다 — 다른 것은
    #    `STANDING_CARGO_BANS[]` 하나뿐이다.
    # 🔴 공허한 초록 방지: release 가 슬롯을 실제로 뗐는지, 금지가 **행을 실제로 걸었는지**
    #    (`nconstr` 차이 > 0)를 먼저 단언한다. 변이(금지 제거) 확인 완료 — 그때 빨개진다.
    #    씬을 짓고 closed=60 까지 전진시킨 뒤 **두 번 푼다**(좁힌 release 라 각 OPTIMAL ~0.2s).
    #    솔버 전역 둘(HiGHS + 빈 속성)을 빌렸다 `finally` 로 되돌린다.
    @testset "cargo ban moves work" begin
        include("cargo_ban_moves_work.jl")
    end
end
