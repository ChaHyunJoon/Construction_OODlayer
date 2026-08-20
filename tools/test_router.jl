# tools/test_router.jl
# =============================================================================
# 라우터(“이 사건을 LLM 에게 보낼 것인가, surrogate 에게 보낼 것인가”)의 자기점검.
#
# 왜 이 파일이 필요한가
# ---------------------
# 판별기 자체(src/safety/novelty.jl)는 tools/test_novelty.jl 이 이미 검사한다. 그런데 그 파일이
# 있는데도 **아무도 호출하지 않아서** 데모의 실행 정책은 계속 DEMO_POLICY 로 런 전체에 고정돼
# 있었다 — 라이브러리는 통과하는데 시스템은 라우팅을 안 하는 상태. 그 간극을 막는 것이 이 파일이다.
# 여기서 검사하는 것은 "감지기가 맞게 계산하는가"가 아니라 **"라우터가 옳은 쪽으로 보내는가"**다.
#
# 시뮬레이터를 돌리지 않는다(판정은 서술자 6개에만 의존하므로 숫자 수준에서 전부 검증 가능).
#
# 실행:  julia +lts --project=. tools/test_router.jl
# =============================================================================
using ConstructionBots
const CB = ConstructionBots
import Statistics

const CALIB = get(ENV, "NOVELTY_CALIB",
                  joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing",   # tools/ -> repo 루트 (wm4 는 repo 내부)
                           "novelty", "novelty_calibration.json"))

npass = 0; nfail = 0
function check(name, ok, detail = "")
    global npass, nfail
    ok ? (npass += 1) : (nfail += 1)
    println("  [", ok ? "PASS" : "FAIL", "] ", name, isempty(detail) ? "" : "  -- " * detail)
end

println("[data] calibration = ", CALIB)

# ---------------------------------------------------------------------------------------------
# T1  감지기가 없으면 라우터는 **꺼진 채로** 있어야 한다(fail-open).
#     이 성질이 있어야 이 기능을 넣는 것만으로 기존 데모가 바뀌지 않는다.
# ---------------------------------------------------------------------------------------------
CB.clear_novelty_detector!()
v0 = CB.novelty_verdict([0.5, 0.5, 0.5, 0.5, 0.5, 0.5])
check("T1 감지기 없으면 게이트 비활성(fail-open, 판단 거부 안 함)",
      v0.decision === :no_gate && v0.novel == false)

# ---------------------------------------------------------------------------------------------
# T2  교정 파일 적재
# ---------------------------------------------------------------------------------------------
det = CB.load_novelty_detector(CALIB)
CB.set_novelty_detector!(det)
check("T2 교정 적재 + 서술자 이름이 파이썬 featurizer 와 동일",
      det.feature_names == ["harm", "work_at_risk", "resource_loss",
                            "recovery_capacity", "progress", "slack"],
      join(det.feature_names, ","))

# ---------------------------------------------------------------------------------------------
# T3  익숙한 입력(교정집합의 평균 근처)은 surrogate 로 가야 한다.
# ---------------------------------------------------------------------------------------------
v_fam = CB.novelty_verdict(det.mu)
check("T3 학습 분포 한복판 = 익숙함 → surrogate", !v_fam.novel,
      "p=$(round(v_fam.p; digits=3)) ≥ alpha=$(det.alpha)")

# ---------------------------------------------------------------------------------------------
# T4  처음 보는 입력은 LLM 으로 가야 한다.
#     "처음 본다"를 흉내내는 방법: 학습 때의 각 서술자 범위에서 여러 표준편차 벗어난 점.
#     (실제 새 종류가 서술자 공간에서 하는 일이 바로 이것이다.)
# ---------------------------------------------------------------------------------------------
x_novel = det.mu .+ 6.0 .* det.sd
v_nov = CB.novelty_verdict(x_novel)
check("T4 학습 범위 밖 = 처음 보는 사건 → LLM", v_nov.novel,
      "p=$(round(v_nov.p; digits=4)) < alpha=$(det.alpha)")

# ---------------------------------------------------------------------------------------------
# T5  판정이 단조로워야 한다: 멀어질수록 p 가 작아진다(= 더 낯설다).
#     이게 깨지면 임계값을 조정한다는 행위 자체가 의미를 잃는다.
# ---------------------------------------------------------------------------------------------
ps = [CB.novelty_verdict(det.mu .+ k .* det.sd).p for k in (0.0, 1.0, 2.0, 4.0, 8.0)]
check("T5 학습 분포에서 멀어질수록 p 가 단조 감소", issorted(ps; rev = true),
      join(round.(ps; digits = 3), " → "))

# ---------------------------------------------------------------------------------------------
# T6  event_descriptors 가 세 종류 모두에서 [0,1] 안의 유한한 6개를 낸다.
#     라우터 입력이 NaN/범위밖이면 게이트가 조용히 무의미해진다.
# ---------------------------------------------------------------------------------------------
cases = Dict(
    "fault"   => CB.event_descriptors(; soc = NaN, agent_pending = 4, zone_overlap = -1.0,
                                        severity = 1.0, n_active = 22, spare_count = 12,
                                        closed_at_fire = 58, total_nodes = 313, progress = 0.19),
    "battery" => CB.event_descriptors(; soc = 0.05, agent_pending = 4, zone_overlap = -1.0,
                                        severity = 0.05, n_active = 22, spare_count = 12,
                                        closed_at_fire = 58, total_nodes = 313, progress = 0.19),
    "zone"    => CB.event_descriptors(; soc = NaN, agent_pending = -1.0, zone_overlap = 0.8,
                                        severity = 0.8, n_active = 22, spare_count = 12,
                                        closed_at_fire = 58, total_nodes = 313, progress = 0.19),
)
allgood = all(all(isfinite.(d)) && all(0.0 .<= d .<= 1.0) for d in values(cases))
check("T6 세 종류 모두 유한하고 [0,1] 인 서술자 6개", allgood,
      join(["$k=$(round.(v; digits=2))" for (k, v) in cases], "  "))

# ---------------------------------------------------------------------------------------------
# T7  **데모 설정 검사**: 교정에서 뺀 종류만 LLM 으로, 나머지는 surrogate 로 가야 한다.
#
#     이 검사가 필요한 이유: 기본 교정(novelty_calibration.json)은 세 종류 전부로 맞춰져 있어서
#     데모의 어떤 사건도 낯설지 않다 -> 라우터가 배선돼 있어도 LLM 이 한 번도 안 불리고, 화면에서는
#     "아무 일도 안 일어나는" 것처럼 보인다. 라우팅을 보이려면 교정이 그 종류를 몰라야 한다:
#         python novelty/export_novelty_calibration.py <데이터> --exclude=zoneblk \
#                --out=novelty/novelty_calibration_no_zoneblk.json
#     그리고 NOVELTY_CALIB 로 그 파일을 가리킨다.
# ---------------------------------------------------------------------------------------------
targets = Dict(k => (CB.novelty_verdict(d).novel ? "dspy" : "surrogate") for (k, d) in cases)
println("      라우팅 결과: ", join(["$k → $(targets[k])" for k in sort(collect(keys(targets)))], ", "))
excluded = Set(String[String(x) for x in get(det.meta, "excluded_kinds", String[])])
if isempty(excluded)
    check("T7 (참고) 교정이 전 종류를 포함 → 낯선 사건이 없어 전부 surrogate 로 감",
          all(v == "surrogate" for v in values(targets)),
          "데모에서 라우팅을 보려면 --exclude=<kind> 로 교정을 다시 뽑을 것")
else
    # 데모 시나리오: zoneblk 를 뺐으면 zone 사건만 LLM 으로 가야 한다.
    want_llm = "zoneblk" in excluded ? ["zone"] : String[]
    ok = all(targets[k] == "dspy" for k in want_llm) &&
         all(targets[k] == "surrogate" for k in keys(targets) if !(k in want_llm))
    check("T7 뺀 종류만 LLM 으로, 나머지는 surrogate 로 라우팅", ok,
          "excluded=" * join(sort(collect(excluded)), ",") * " · " *
          join(["$k→$(targets[k])" for k in sort(collect(keys(targets)))], " "))
end

# ---------------------------------------------------------------------------------------------
# T8  eps 를 키우면 더 많이 LLM 으로 간다(운영 손잡이가 실제로 동작하는가).
# ---------------------------------------------------------------------------------------------
# 🔴 2026-08-20 — 탐침을 교정에서 **유도**한다. 예전에는 `mu .+ 2.0 .* det.sd` 리터럴이었는데,
# 모든 축에서 z=2 이므로 score = sqrt(mean(2²)) = **2.000 으로 데이터와 무관하게 고정**된다.
# 그래서 이 검사가 실제로 재던 것은 "eps 손잡이가 동작하는가" 가 아니라
# **"교정집합에 score 2.0 을 넘는 점이 있는가"** 였다 — 여유가 늘 얇았고(2.206 vs 2.0 = 10% ·
# 2.223 vs 2.0 = 11%), 발화점 격자 교정으로 갈아끼우자 max=1.990 이 되어 **−0.5% 로 뒤집혔다.**
# 그때도 손잡이 자체는 멀쩡했다(T5 가 p 0.994→0.404→0.006 로 이미 보인다).
# 이제 `k = median(cal_scores)` 로 잡는다. 모든 축이 z=k 이므로 score == k 이고, p 는 교정
# 분포의 한복판(≈0.5)에 떨어져 어떤 교정에서도 0.01 과 0.99 **사이**에 있다.
# 그리고 그 전제를 **명시적으로 단언한다** — 픽스처가 못 받쳐주면 조용히 오측정하지 말고 빨개져야 한다.
k   = Statistics.median(det.cal_scores)
mid = det.mu .+ k .* det.sd
p_mid = CB.conformal_pvalue(det, CB.novelty_score(det, mid))
check("T8-premise 탐침의 p 가 두 eps 사이에 있다(안 그러면 T8 은 손잡이를 못 잰다)",
      0.01 < p_mid < 0.99, "k=$(round(k; digits=3)) → p=$(round(p_mid; digits=4))")
strict = CB.novelty_verdict(mid; eps = 0.01).novel
loose  = CB.novelty_verdict(mid; eps = 0.99).novel
check("T8 eps 손잡이가 동작(엄격하면 덜, 느슨하면 더 LLM 으로)", !strict && loose,
      "eps=0.01 → $(strict ? "LLM" : "surrogate") / eps=0.99 → $(loose ? "LLM" : "surrogate")")

CB.clear_novelty_detector!()      # 다음 테스트에 영향 주지 않게 정리
println("\n", npass, " PASS / ", nfail, " FAIL")
exit(nfail == 0 ? 0 : 1)
