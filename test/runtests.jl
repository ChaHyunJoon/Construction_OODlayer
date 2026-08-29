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

    # 2026-08-26 (tool-lane step A, Task 1): 교정 파일이 없어도 event_descriptors_of 의
    # 결과가 route() 의 모든 반환 분기에 "descriptors" 키로 실리는지. 이 키가 빠지면 LLM 이
    # 문장 한 줄만 받고 숫자 서술자를 못 받는다(교정 유무와 서술자 계산이 한 게이트에 묶였던
    # 옛 결함의 재발 방지).
    @testset "router descriptors survive a missing calibration" begin
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
    # `replan.jl:726` 이 `llm_to_proposal` 의 예외를 3회 재시도로 삼키고, 끝내 실패하면
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

    # 2026-08-29 (Plan B / T1): DSPy 서비스가 이미 내던 tool 레인 키 8개를 Julia 의
    # `policy_entry` 가 전부 떨어뜨리고 있었다. 이 게이트는 그 8개가
    # `decide_all(...).tool_lane` 까지 **값까지 그대로** 오는지, 그리고 spec §9-2 의 삼상
    # (`nothing`="못 쟀다" ≠ `false`="재서 어긋났다")이 언어 경계에서 살아남는지 잰다.
    # 바로 위 게이트와 **같은 패턴**이다 — 루프백에 진짜 HTTP 서버를 띄우고 `DSPY_URL` 을
    # policy.jl include 동안에만 그리로 돌린다(패키지 제네릭 해적질 없음, 8077 로 나가는
    # 요청 없음 = 유료 OpenAI 호출 없음). 같은 이유로 `Sockets` 를 직접 import 하지 않는다
    # (그 함정이 위 게이트를 이 배선 안에서 통째로 에러로 만든 이력이 있다).
    @testset "tool lane keys survive to decide_all" begin
        include("tool_lane_keys_survive.jl")
    end

    # 2026-08-27: lane_select.jl 은 의존성 0 인 순수 함수인데 게이트가 배선돼 있지 않았다.
    # 축 1(어휘 미달)이 이 함수의 우선순위에 얹히므로 이제 하중을 받는다.
    @testset "lane selection — vocabulary gap outranks novelty" begin
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
    # 같은 파일이 mild 가 NOOP-only 라는 설계 결정(= L2 인계 표식)도 함께 지킨다.
    @testset "battery menu lanes agree" begin
        include("battery_menu_lanes_agree.jl")
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
end
