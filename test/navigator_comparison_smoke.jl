# ============================================================================
#  이 파일이 하는 일: OOD(분포 밖 이벤트) 대응 "컨트롤러 비교" 스택 전체를 빠르게 검증하는 smoke 테스트.
#  프로젝트 속 역할: LLM/surrogate re-spec 레이어와 여러 baseline(B0~B5, MARL 등)을 공정하게
#  비교하는 로직(지표 계산·정규화 lift·집계·robustness sweep)이 맞는지, "가짜(mock) 하부"로 확인.
#  즉 실제 MILP/LDraw 빌드를 돌리지 않고, 제안(proposal) 품질만 흉내 내서 비교 배관만 점검함.
#  핵심 개념:
#   · Controller = OOD 상황을 받아 "무엇을 할지"(DSL 제안)를 내는 정책. B0=아무것도 안 함(floor),
#     B3=oracle(정답), 그 사이에 규칙기반/랜덤/LLM/MARL 등이 늘어섬(ladder).
#   · decision_quality(...).grounded = 제안이 실제 진짜 이벤트(truth)에 올바로 대응했는지.
#   · lift_normalized : floor(0)~oracle(1) 사이로 성능을 0~1 로 정규화한 값.
#   · DSL 액션: ReplaceAgent(로봇 교체), ForbidZone(금지구역), DeprioritizeAgent(후순위), ReformTeam(팀 재편) 등.
#  Julia 문법 참고:
#   · const CB = ConstructionBots : 긴 모듈명을 짧은 별칭 CB 로. 이후 CB.foo 로 접근.
#   · @__DIR__ : 이 소스 파일이 있는 디렉터리 경로. joinpath 로 상대경로를 안전하게 이어붙임.
#   · @test 표현식 / @testset "이름" begin...end : 테스트 매크로/묶음.
#   · x isa T : x 가 타입 T 인지 판정. && / || 는 단축평가(앞이 정해지면 뒤 생략).
#   · f(a; k=v) 세미콜론 뒤 = 키워드 인자. (field = val, ...) 는 이름붙은 필드로 구조체 생성.
#   · Dict(k => v for x in xs) : 컴프리헨션으로 딕셔너리 생성. NamedTuple 필드는 .name 으로 접근.
#   · ≈ (\approx) : isapprox 연산자. atol/rtol 로 부동소수 오차 허용.
# ============================================================================

# test/navigator_comparison_smoke.jl
# Exercises the controller-comparison stack (metrics, baselines B0–B5, Controller
# abstraction, normalized lift, aggregation, robustness sweep) against the REAL DSL /
# OOD-truth types via a MOCK downstream — so the whole comparison logic is verified
# WITHOUT a live MILP/LDraw build. For the live pipeline, wire `run_pipeline` to the
# real enact+solve+measure path.
#
#   julia +lts --project=. test/navigator_comparison_smoke.jl

using ConstructionBots
using Test
const CB = ConstructionBots  # ConstructionBots 를 CB 로 줄여 부름

# Load the whole navigator layer in dependency order.
# navigator 레이어(비교 스택 구현) 소스를 의존성 순서대로 로드.
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

@test CB.navigator_loaded()  # navigator 레이어가 제대로 로드됐는지 먼저 확인

# ---- MOCK downstream: proposal quality -> RunMetrics ------------------------------
# q = 0 (no/blank proposal) .. 0.5 (grounded-but-wrong) .. 1 (correctly grounded).
# Every axis is monotone in q so the FLOOR (B0, q=0) and ORACLE (best correct, q=1)
# bracket the scale and normalized lift lands in [0,1].
# 가짜 하부 시뮬레이터: 제안(proposal)의 품질 q(0~1)를 매기고, 모든 지표를 q에 단조롭게 반응하도록 만들어 RunMetrics 로 돌려줌.
# (실제 빌드를 돌리는 대신, 비교 로직만 시험할 수 있게 함. q=0 아무것도 안 함, q=0.5 대응했지만 틀림, q=1 정답.)
function mock_pipeline(instance, proposal)
    q = 0.0  # 기본은 "아무 대응 없음" 품질
    if proposal !== nothing && !isempty(proposal.constraints)  # 제안이 있고 제약(액션)이 비어있지 않으면
        dq = CB.decision_quality(proposal.constraints, [instance.truth])  # 진짜 이벤트에 맞게 대응했는지 채점
        q = dq.grounded ? 1.0 : 0.5  # 올바로 grounding 되면 1, 대응은 했지만 틀렸으면 0.5
    end
    return CB.RunMetrics(  # q 에 따라 좋아지는(단조) 가짜 지표들을 만들어 반환
        completion_rate  = 0.5 + 0.5q,      # 완료율: q 클수록 높음(0.5~1.0)
        feasible         = true,            # 실행가능 여부(여기선 항상 참)
        makespan         = 120.0 - 30q,     # 총 완료시간: q 클수록 짧음(좋음)
        throughput       = 1.0 + q,         # 처리량: q 클수록 높음
        robot_utilization= 0.5 + 0.5q,      # 로봇 가동률
        energy           = 1000.0 - 300q,   # 소비 에너지: q 클수록 적음
        handling_distance= 500.0 - 100q,    # 총 이동/취급 거리: q 클수록 짧음
        schedule_deviation = 50.0 - 40q,    # 스케줄 이탈: q 클수록 적음
        reaction_latency = 20.0 - 15q,      # 반응 지연: q 클수록 짧음
        time_to_recover  = 30.0 - 20q,      # 복구까지 걸린 시간
        recovery_rate    = q,               # 복구 성공률(= q)
        n_robots = 10, n_parts = 20,        # 규모 정보(로봇 10, 부품 20)
    )
end

# ---- instances: real truths + NL (one B2-parseable, one paraphrased) --------------
# 테스트용 인스턴스들: 각 인스턴스 = (진짜 이벤트 truth) + (그걸 서술한 자연어 nl). 컨트롤러는 nl 만 보고 대응하고, 채점은 truth 로 함.
r3 = CB.RobotID(3); r5 = CB.RobotID(5); asm = CB.AssemblyID(1)  # 테스트에 쓸 로봇 3·5번, 조립체 1번 ID
# NL that MATCHES B2's _FAULT_RE template (B2 succeeds) ...
nl_fault_template = "Robot R3 has broken down at (12.0, -4.5). Dispatch the nearest backup robot."  # B2 정규식 템플릿에 딱 맞는 문장(규칙기반이 성공)
# ... and a paraphrase that does NOT match (B2 fails -> the LLM/rule earns its keep)
nl_fault_paraphrase = "Unit three just died near coordinate twelve, minus four; please send help."  # 같은 뜻이지만 템플릿과 안 맞는 의역(B2 실패 → LLM 가치 증명)

instances = [
    (truth = CB.FaultTruth(r3, Float64[12.0, -4.5], 0.0), nl = nl_fault_template),      # 로봇 고장(정확 위치) + 템플릿 문장
    (truth = CB.FaultTruth(r5, Float64[3.0, 3.0], 0.0),    nl = nl_fault_paraphrase),   # 로봇 고장 + 의역 문장
    (truth = CB.BatteryTruth(r3, 0.5, 0.0),                nl = "Robot R3 battery degraded to ~50%."),  # 배터리 저하(SoC 0.5)
    (truth = CB.ZoneTruth(:z1, Float64[0.0,0.0], 2.0, asm),nl = "A safety exclusion zone is now active."),  # 안전 금지구역 발생
]

# ---- mock LLM + MARL decision functions (both ~correct on grounding) --------------
# 가짜 LLM: 자연어 nl 을 정답 truth 에서 되찾아 표준(canonical) 제안으로 번역(실제론 llm_bridge 가 함, 여기선 유능한 번역기 흉내).
truth_of = Dict(inst.nl => inst.truth for inst in instances)  # nl → truth 역참조 표(가짜 LLM 이 커닝하는 용도)
llm_fn(nl) = CB.canonical_respec(truth_of[nl])  # nl 을 받아 그 truth 의 표준 대응 제안을 반환(모든 종류 처리)
# MARL: the learned macro head, emulated as a ctx -> proposal that grounds correctly on
# the trained kinds (fault/battery) but ABSTAINS on the held-out kinds (zone/reform) —
# exactly the generalization gap the fairness split is meant to expose.
# 가짜 MARL(학습된 정책): 학습한 종류(fault/battery)엔 옳게 대응하지만, held-out(zone/reform)엔 기권(nothing) — 일반화 격차를 드러내는 장치.
function marl_fn(ctx)
    t = ctx.truth
    (t isa CB.FaultTruth || t isa CB.BatteryTruth) && return CB.canonical_respec(t)  # 학습한 종류면 대응(단축평가: 참일 때만 return)
    return nothing  # 그 외(zone/reform)엔 기권
end

# 비교 대상 컨트롤러 묶음 구성: 기본 baseline(B0~B5) + 위에서 만든 가짜 LLM/MARL 을 꽂음.
controllers = CB.default_controllers(; llm = llm_fn,
    marl = CB.MARLController(policy = marl_fn, label = "MARL"))

# 컨트롤러 사다리(ladder)에 기대한 8개 baseline/정책이 모두 들어있는지 확인.
@testset "controller ladder is complete" begin
    names = [CB.name(c) for c in controllers]  # 각 컨트롤러의 이름 목록(컴프리헨션)
    for want in ["B0_noadapt","B1_canonical","B3_oracle","B2_regex","B5_random","B4_reactive","LLM","MARL"]
        @test want in names  # 기대한 각 이름이 실제로 존재하는지
    end
end

# decision_quality 채점이 4가지 OOD 종류(fault/zone/reform/battery)를 모두 올바로 판정하는지 검증.
@testset "decision quality covers ALL OOD kinds" begin
    # correct spec per kind grounds; nothing/blank misses.
    @test CB.decision_quality([CB.ReplaceAgent(r3,0.0)], [CB.FaultTruth(r3,Float64[0,0],0.0)]).grounded  # 고장 → 로봇 교체 = 정답
    @test CB.decision_quality([CB.ForbidZone(asm,:z1)], [CB.ZoneTruth(:z1,Float64[0,0],2.0,asm)]).grounded  # 금지구역 → ForbidZone = 정답
    @test CB.decision_quality([CB.ReformTeam()], [CB.ReformTruth()]).grounded  # 팀 재편 필요 → ReformTeam = 정답
    # BATTERY is severity-split at REPLACE_SOC_THRESHOLD (=0.2): a mild degradation (SoC>0.2) grounds
    # against the soft Deprioritize; a deep discharge (SoC<=0.2) grounds against the hard Replace.
    # 배터리는 심각도(SoC)로 정답이 갈림: 임계값 0.2 초과=가벼운 저하→후순위(Deprioritize)가 정답, 0.2 이하=방전→교체(Replace)가 정답.
    @test CB.decision_quality([CB.DeprioritizeAgent(r3,50.0)], [CB.BatteryTruth(r3,0.5,0.0)]).grounded  # SoC 0.5(가벼움) → 후순위 = 정답
    @test CB.decision_quality([CB.ReplaceAgent(r3,0.0)],       [CB.BatteryTruth(r3,0.1,0.0)]).grounded  # SoC 0.1(방전) → 교체 = 정답
    # wrong severity class both ways is NOT grounded:
    # 심각도 분류를 틀리면 양방향 모두 오답(grounded 아님):
    @test !CB.decision_quality([CB.ForbidAgent(r3,0.0)],        [CB.BatteryTruth(r3,0.5,0.0)]).grounded  # hard-remove a merely-degraded robot  # 가벼운 저하인데 강제 제거 = 오답
    @test !CB.decision_quality([CB.DeprioritizeAgent(r3,50.0)], [CB.BatteryTruth(r3,0.1,0.0)]).grounded  # only soft-bias a flat robot  # 방전인데 후순위만 = 오답
    # empty proposal against a real event -> missed
    @test !CB.decision_quality(Any[], [CB.FaultTruth(r3,Float64[0,0],0.0)]).grounded  # 진짜 이벤트에 빈 제안 = 놓침(오답)
end

# 정규화 lift 의 양 끝점 검증: 아무 대응 없음(floor)=0, 정답(oracle)=1 로 딱 떨어지는지.
@testset "normalized lift endpoints" begin
    floor  = mock_pipeline(instances[1], nothing)                          # q=0  # 아무 제안 없음 → 최저 기준
    oracle = mock_pipeline(instances[1], CB.canonical_respec(instances[1].truth))  # q=1  # 정답 제안 → 최고 기준
    ln_floor  = CB.lift_normalized(floor,  floor, oracle)   # floor 를 floor~oracle 사이로 정규화 → 0 이어야
    ln_oracle = CB.lift_normalized(oracle, floor, oracle)   # oracle 을 정규화 → 1 이어야
    @test isapprox(ln_floor.mean, 0.0; atol=1e-6)   # doing nothing == 0 lift
    @test isapprox(ln_oracle.mean, 1.0; atol=1e-6)  # matching oracle == 1 lift
end

# 전체 비교 실행(compare_controllers) 결과의 순위/대소관계가 기대대로 나오는지 검증.
@testset "full comparison + ranking" begin
    cmp = CB.compare_controllers(controllers, instances; run_pipeline = mock_pipeline, seed = 7)  # 모든 컨트롤러를 인스턴스들에 돌려 비교(seed 로 랜덤 고정)
    byname = Dict(s.name => s for s in cmp.summaries)  # 이름으로 요약을 찾기 쉽게 딕셔너리화
    @test length(cmp.summaries) == length(controllers)  # 컨트롤러 수만큼 요약이 나와야

    # floor sits at ~0; oracle detectors at ~1.
    @test isapprox(byname["B0_noadapt"].lift_mean, 0.0; atol=1e-6)  # B0(무대응)은 lift 0 근처
    @test byname["B1_canonical"].lift_mean > 0.9  # B1(정답 표준대응)은 거의 1
    @test byname["B4_reactive"].lift_mean ≈ byname["B0_noadapt"].lift_mean  # B4==B0 at proposal level  # B4(반응형)는 제안 수준에선 B0 와 동일

    # a competent LLM beats no-adaptation; MARL beats no-adaptation too ...
    @test byname["LLM"].lift_mean  > byname["B0_noadapt"].lift_mean  # 유능한 LLM 은 무대응보다 나음
    @test byname["MARL"].lift_mean > byname["B0_noadapt"].lift_mean  # MARL 도 무대응보다는 나음
    # ... but MARL ABSTAINS on held-out (zone) kinds, so on this mixed set the zero-shot
    # LLM (which handles all kinds) should be >= MARL — the fairness-split gap made visible.
    # 단, MARL 은 held-out(zone)에 기권하므로, 모든 종류를 다루는 zero-shot LLM 이 이 혼합셋에서 MARL 이상이어야(공정성 격차 가시화).
    @test byname["LLM"].lift_mean >= byname["MARL"].lift_mean - 1e-9

    # B2 grounding F1 is imperfect (it whiffs the paraphrased fault); LLM grounding is perfect.
    @test byname["B2_regex"].grounding_f1_mean < byname["LLM"].grounding_f1_mean  # B2(정규식)는 의역을 놓쳐 F1 이 LLM 보다 낮음
    # cost axis is reported and reflects the asymmetry (LLM ~s, MARL ~ms)
    @test byname["LLM"].decision_latency > byname["MARL"].decision_latency  # 비용축: LLM(초 단위)이 MARL(밀리초)보다 느림
end

# 통계 집계/robustness 헬퍼들(신뢰구간·짝비교·breakdown point·이벤트→지표 변환·난이도 sweep)이 맞게 도는지 검증.
@testset "aggregation + robustness helpers" begin
    ci = CB.bootstrap_ci([1.0, 1.0, 1.0, 1.0]; seed=1)  # 부트스트랩 신뢰구간
    @test isapprox(ci.mean, 1.0; atol=1e-9) && ci.lo ≤ ci.mean ≤ ci.hi  # 평균 1, 하한≤평균≤상한
    pd = CB.paired_delta([1.0,1.0,1.0], [0.0,0.0,0.0]; seed=1)  # 두 정책의 짝지은 차이
    @test pd.delta ≈ 1.0 && pd.win_rate == 1.0  # 평균 차이 1, 승률 100%
    # breakdown point: completion crosses 0.5 between difficulty 2 (0.7) and 3 (0.4);
    # linear interpolation -> 2 + (0.5-0.7)/(0.4-0.7) = 2 + 2/3.
    # breakdown point: 완료율이 0.5 아래로 내려가는 난이도를 선형보간으로 추정(난이도 2에서 0.7, 3에서 0.4 → 2+2/3).
    @test CB.breakdown_point([1.0,2.0,3.0,4.0], [0.9,0.7,0.4,0.1]) ≈ (2 + 2/3) atol=1e-6
    @test CB.breakdown_point([1.0,2.0], [0.9,0.8]) == Inf   # never breaks in range  # 범위 내에서 안 무너지면 Inf

    # adaptation-from-events + splice into RunMetrics (the model.ood_events -> metrics bridge)
    # OOD 이벤트 로그 → 적응 지표 변환, 그리고 RunMetrics 에 끼워넣기(model.ood_events → metrics 다리).
    events = [(step=10, kind=:fault, closed_at=3, recovered_step=14),
              (step=20, kind=:zone,  closed_at=6, recovered_step=-1)]   # one recovered, one not  # 하나는 복구됨, 하나는 미복구(-1)
    a = CB.adaptation_from_events(events)
    @test a.n_events == 2 && a.n_recovered == 1  # 이벤트 2개 중 1개 복구
    @test a.recovery_rate ≈ 0.5                  # 복구율 0.5
    @test a.time_to_recover ≈ 4.0                       # 14-10 over the single recovered event  # 복구된 1건의 14-10=4
    rm2 = CB.with_adaptation(CB.RunMetrics(completion_rate=0.9), events)  # 기존 지표에 적응 지표를 합침
    @test rm2.recovery_rate ≈ 0.5 && rm2.completion_rate ≈ 0.9   # override + preserve  # 적응값은 덮고, 완료율은 보존

    # robustness sweep: harder levels drop more instances to abstain -> lower completion.
    # robustness sweep: 난이도를 올리며 완료율 곡선을 그림(어려울수록 기권 증가 → 완료율 하락).
    make_instances(d) = [instances[1] for _ in 1:Int(d)]   # trivial difficulty=count stub  # 난이도 d = 인스턴스 개수로 단순화한 stub
    sw = CB.robustness_sweep(controllers, make_instances, [1.0, 2.0, 3.0];
                             run_pipeline = mock_pipeline, seed = 3)
    @test haskey(sw.curves, "LLM") && length(sw.curves["LLM"]) == 3  # LLM 곡선이 3개 난이도만큼 존재
    @test haskey(sw.breakdown, "B0_noadapt")  # breakdown 결과에 B0 항목 존재
end

println("navigator comparison smoke OK")  # 여기까지 예외 없이 오면 성공 표시 출력
