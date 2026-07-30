# =============================================================================
#  tools/test_novelty.jl -- Julia<->Python PARITY for the covariate-novelty gate.
#
#  Run:  julia +lts --project=. tools/test_novelty.jl [path/to/novelty_calibration.json]
#
#  WHY PARITY IS THE WHOLE TEST
#  ----------------------------
#  Every offline result used to justify this gate (compare_detectors.py's finding that covariate
#  novelty -- not value residual -- is the drift signal) was produced by the PYTHON detector. If
#  the Julia re-implementation drifts numerically, those results no longer describe the thing
#  actually running, and the justification silently evaporates. So the exporter ships probe
#  vectors together with their Python-computed score and p-value, and this file requires
#  agreement to 1e-9 -- including on deliberately shifted probes that exercise the clipping path.
#
#  Also checked: the gate's DIRECTION (novel -> small p -> escalate), the fail-open default, and
#  descriptor parity for the six physical quantities.
#
#  [한국어] 이 테스트의 핵심은 "파이썬과 숫자가 같은가"다. 이 게이트를 정당화하는 오프라인 실험은
#    전부 파이썬 구현으로 나왔으므로, Julia 포팅이 조금이라도 어긋나면 그 근거가 실제 돌아가는
#    물건을 설명하지 못하게 된다. 그래서 exporter 가 (입력, 파이썬 결과) 쌍을 같이 실어 보내고
#    여기서 1e-9 이내 일치를 요구한다. 방향성(낯설수록 p 작음)과 fail-open 기본값도 함께 검사.
# =============================================================================
using ConstructionBots
const CB = ConstructionBots
using JSON3

const PASS = Ref(0)
const FAIL = Ref(0)
function check(name, ok, detail = "")
    ok ? (PASS[] += 1; println("  [PASS] ", name, detail == "" ? "" : "   $detail")) :
         (FAIL[] += 1; println("  [FAIL] ", name, detail == "" ? "" : "   $detail"))
    return ok
end
banner(t) = println("\n" * "="^74 * "\n" * t * "\n" * "="^74)

const CAL_PATH = isempty(ARGS) ?
    joinpath(dirname(pkgdir(CB)), "wm4spacecraft_manufacturing", "novelty_calibration.json") :
    ARGS[1]

banner("SETUP")
if !isfile(CAL_PATH)
    println("  calibration not found: $CAL_PATH")
    println("  produce it with:  python export_novelty_calibration.py")
    println("  (the dataset it uses is defined in wm4spacecraft_manufacturing/wm_datasets.py)")
    exit(1)
end

# ---- fail-open: 감지기를 설치하기 전에는 게이트가 의견을 내지 않아야 한다 -------------------
CB.clear_novelty_detector!()
let v = CB.novelty_verdict([0.5, 0.1, 0.05, 0.3, 0.2, 0.7])
    check("G0 no detector installed -> :no_gate (fail-open)", v.decision === :no_gate,
          "decision=$(v.decision)")
end

det = CB.load_novelty_detector(CAL_PATH)
CB.set_novelty_detector!(det)
println("  ", CB.novelty_report())

blob = JSON3.read(read(CAL_PATH, String))

# =============================================================================
banner("P  --  numerical parity with the Python detector")
# =============================================================================
let max_ds = 0.0, max_dp = 0.0, n = 0
    for probe in blob.probes
        x = Float64[Float64(v) for v in probe.x]
        s = CB.novelty_score(det, x)
        p = CB.conformal_pvalue(det, s)
        max_ds = max(max_ds, abs(s - Float64(probe.score)))
        max_dp = max(max_dp, abs(p - Float64(probe.p)))
        n += 1
    end
    check("P1 novelty_score matches Python", max_ds < 1e-9,
          "max |dscore| = $(max_ds) over $n probes")
    check("P2 conformal p-value matches Python", max_dp < 1e-9,
          "max |dp| = $(max_dp) over $n probes")
end

# =============================================================================
banner("G  --  gate semantics")
# =============================================================================

# G1: 교정 평균 자체는 가장 덜 낯설어야 한다(점수 0 에 가깝고 p 는 큼).
let x = det.mu
    s = CB.novelty_score(det, x)
    v = CB.novelty_verdict(x)
    check("G1 calibration mean is minimally novel", s < 1e-9 && v.decision === :trust,
          "score=$(round(s, digits=12)) p=$(round(v.p, digits=3)) -> $(v.decision)")
end

# G2: 멀리 밀어낸 점은 낯설어야 하고, 게이트가 escalate 를 내야 한다.
let x = det.mu .+ 6.0 .* det.sd
    v = CB.novelty_verdict(x)
    check("G2 far-shifted point escalates", v.decision === :escalate,
          "score=$(round(v.score, digits=3)) p=$(round(v.p, digits=4)) -> $(v.decision)")
end

# G3: 단조성 -- 평균에서 멀어질수록 점수는 커지고 p 는 작아져야 한다(뒤집히면 게이트가 무의미).
let scores = Float64[], ps = Float64[]
    for k in 0.0:0.5:6.0
        x = det.mu .+ k .* det.sd
        push!(scores, CB.novelty_score(det, x))
        push!(ps, CB.conformal_pvalue(det, scores[end]))
    end
    mono_s = all(scores[i] <= scores[i+1] + 1e-12 for i in 1:length(scores)-1)
    mono_p = all(ps[i] >= ps[i+1] - 1e-12 for i in 1:length(ps)-1)
    check("G3a score increases with distance from calibration", mono_s)
    check("G3b p-value decreases with distance", mono_p,
          "p: $(round.(ps[1:min(5,end)], digits=3)) ...")
end

# G4: eps 를 명시하면 그 값이 alpha 를 덮어써야 한다.
let x = det.mu
    v_loose = CB.novelty_verdict(x; eps = 0.999)     # 거의 모든 것을 novel 로 취급
    v_tight = CB.novelty_verdict(x; eps = 1e-9)      # 거의 아무것도 novel 아님
    check("G4 eps overrides the default alpha",
          v_loose.decision === :escalate && v_tight.decision === :trust,
          "loose=$(v_loose.decision) tight=$(v_tight.decision)")
end

# =============================================================================
banner("D  --  live descriptor construction (the LLM-fillable interface)")
# =============================================================================

# D1: 이름 순서가 파이썬 STATE_DESCRIPTORS 와 정확히 같아야 교정 벡터와 짝이 맞는다.
check("D1 feature order matches the calibration",
      det.feature_names == ["harm", "work_at_risk", "resource_loss",
                            "recovery_capacity", "progress", "slack"],
      string(det.feature_names))

# D2: 고장 사건 = "soc 0 인 배터리 사건"으로 통합되는지(설계의 핵심 통합 축).
#     2026-07-28 이전에는 resource_loss(3번)로 검사했다. 그 값은 이제 함대크기로 안 나누므로
#     고장/방전 모두 1.0 이 되어 여전히 통과하지만, 통합의 본래 의미가 더 잘 드러나는 harm(1번)으로
#     옮겼다 -- 둘 다 "능력 100% 상실"이라 harm=1.0 에서 만난다.
let d_fault = CB.event_descriptors(; agent_pending = 5, n_active = 22, spare_count = 12,
                                     closed_at_fire = 50, total_nodes = 313, severity = 1.0,
                                     progress = 0.16)
    d_batt0 = CB.event_descriptors(; soc = 0.0, agent_pending = 5, n_active = 22, spare_count = 12,
                                     closed_at_fire = 50, total_nodes = 313, progress = 0.16)
    check("D2 fault == battery(soc=0) on harm", abs(d_fault[1] - d_batt0[1]) < 1e-12,
          "fault=$(round(d_fault[1], digits=5)) batt0=$(round(d_batt0[1], digits=5))")
end

# D2b: **유해한 고장과 무해한 고장은 work_at_risk 로 갈려야 한다.**
#      예전에는 harm 이 severity 를 읽어서 갈랐는데, 그 severity 는 학습 덤프에만 있는 정답표이고
#      실제 배포에서는 모든 고장에 1.0 인 상수였다. 그래서 harm 은 이제 둘을 구분하지 않는 것이 옳고
#      (D3 에서 그 사실을 명시적으로 확인한다), 구분은 "그 로봇이 일을 쥐고 있었는가"가 맡는다.
let busy = CB.event_descriptors(; agent_pending = 5, n_active = 22, closed_at_fire = 50,
                                  total_nodes = 313, severity = 1.0)
    idle = CB.event_descriptors(; agent_pending = 0, n_active = 22, closed_at_fire = 50,
                                  total_nodes = 313, severity = 1.0)   # 같은 severity!
    check("D2b harmful vs harmless fault separated by work_at_risk (not by the answer key)",
          busy[2] > idle[2] + 0.1 && abs(busy[1] - idle[1]) < 1e-12,
          "work_at_risk $(round(busy[2],digits=3)) vs $(round(idle[2],digits=3)); " *
          "harm $(round(busy[1],digits=3)) == $(round(idle[1],digits=3))")
end

# D3: harm 의 방향이 모든 종류에서 같아야 한다(부호 반전 버그가 되살아나면 여기서 잡힘).
#     고장은 빠졌다: 이제 harm 이 severity(=정답표)를 안 읽으므로 유해/무해 고장이 둘 다 1.0 이다.
#     그건 버그가 아니라 의도이고, 그 구분은 D2b 가 work_at_risk 에서 검사한다.
let deep = CB.event_descriptors(; soc = 0.05, agent_pending = 3, n_active = 22)
    mild = CB.event_descriptors(; soc = 0.60, agent_pending = 3, n_active = 22)
    zblk = CB.event_descriptors(; zone_overlap = 0.31, n_active = 22)
    zhrm = CB.event_descriptors(; zone_overlap = 0.00, n_active = 22)
    ok = deep[1] > mild[1] && zblk[1] > zhrm[1]
    check("D3 harm is monotone in the SAME direction for battery and zone", ok,
          "battery $(round(deep[1],digits=2))>$(round(mild[1],digits=2)) | " *
          "zone $(round(zblk[1],digits=2))>$(round(zhrm[1],digits=2))")
end

# D3b: harm 이 **정답표를 안 읽는다**는 것을 명시적으로 못박는다.
#      severity 만 1.0 <-> 0.0 으로 바꿔도 고장 사건의 harm 은 변하면 안 된다. 이게 변하면
#      학습 때만 존재하는 라벨이 다시 특징으로 새어 들어온 것이다(예전 정의의 실제 결함).
let a = CB.event_descriptors(; agent_pending = 5, severity = 1.0, n_active = 22)
    b = CB.event_descriptors(; agent_pending = 5, severity = 0.0, n_active = 22)
    check("D3b harm does NOT read the experimenter's severity label on a fault",
          abs(a[1] - b[1]) < 1e-12, "severity 1.0 -> harm $(a[1]) / severity 0.0 -> harm $(b[1])")
end

# D4: 모든 서술자가 [0,1] 안에 있어야 한다(극단 입력에도).
let ok = true
    for d in (CB.event_descriptors(; soc = -5.0, agent_pending = 9999, n_active = 1,
                                     spare_count = 1e6, closed_at_fire = 1e6,
                                     total_nodes = 1.0, progress = 5.0),
              CB.event_descriptors(; zone_overlap = 99.0, n_active = 1e6),
              CB.event_descriptors())
        all(0.0 - 1e-12 .<= d .<= 1.0 + 1e-12) || (ok = false)
    end
    check("D4 descriptors stay within [0,1] on extreme input", ok)
end

# =============================================================================
banner("E  --  escalation gate (uncertainty first, novelty as backup)")
# =============================================================================

# E1: decision_margin -- 1등과 2등이 붙어 있을수록 0 에 가까워야 한다.
let
    check("E1a clear winner -> margin near 1", CB.decision_margin([10.0, 1.0, 0.5]) > 0.85,
          "margin=$(round(CB.decision_margin([10.0,1.0,0.5]), digits=3))")
    check("E1b near tie -> margin near 0", CB.decision_margin([10.0, 9.9, 1.0]) < 0.05,
          "margin=$(round(CB.decision_margin([10.0,9.9,1.0]), digits=3))")
    check("E1c all equal -> maximal uncertainty", CB.decision_margin([5.0, 5.0, 5.0]) == 0.0)
    check("E1d single candidate -> no uncertainty", CB.decision_margin([3.0]) == 1.0)
end

# E2: vote_disagreement -- 앙상블이 갈릴수록 1 에 가까워야 한다.
let unanimous = [[9.0, 1.0], [8.0, 2.0], [7.0, 3.0]],          # 전원 1번 후보 지지
    split     = [[9.0, 1.0], [1.0, 9.0], [9.0, 1.0], [1.0, 9.0]]  # 반반
    check("E2a unanimous ensemble -> disagreement 0", CB.vote_disagreement(unanimous) == 0.0)
    check("E2b evenly split ensemble -> disagreement 0.5",
          abs(CB.vote_disagreement(split) - 0.5) < 1e-12,
          "d=$(CB.vote_disagreement(split))")
    check("E2c empty ensemble -> 0 (no signal, not a crash)", CB.vote_disagreement([]) == 0.0)
end

# E3: 게이트 결합 규칙 -- 불확실이 1순위, novelty 는 보조, 아무 신호 없으면 fail-open.
CB.clear_novelty_detector!()
let v = CB.escalation_verdict()
    check("E3a no signals at all -> :no_signal, do not escalate",
          v.escalate == false && v.reason === :no_signal)
end
let v = CB.escalation_verdict(values = [10.0, 9.95, 1.0])
    check("E3b tight decision escalates as :uncertain_decision",
          v.escalate && v.reason === :uncertain_decision,
          "margin=$(round(v.margin, digits=4))")
end
let v = CB.escalation_verdict(values = [10.0, 1.0, 0.5])
    check("E3c confident decision does not escalate",
          v.escalate == false && v.reason === :confident)
end
CB.set_novelty_detector!(det)
let far = det.mu .+ 6.0 .* det.sd
    v = CB.escalation_verdict(descriptors = far, values = [10.0, 1.0, 0.5])
    check("E3d familiar-looking decision but novel input -> :novel_input",
          v.escalate && v.reason === :novel_input,
          "p=$(round(v.p, digits=4))")
end
let v = CB.escalation_verdict(descriptors = det.mu,
                              member_values = [[9.0, 1.0], [1.0, 9.0], [9.0, 1.0], [1.0, 9.0]])
    check("E3e split ensemble escalates even on an in-distribution input",
          v.escalate && v.reason === :uncertain_decision,
          "disagreement=$(v.disagreement)")
end

CB.clear_novelty_detector!()

# =============================================================================
banner("F  --  calibration validation (a WRONG file must fail loudly, not load)")
# =============================================================================
# 왜 이 절이 있는가: 교정파일은 "이 분포에서 정상이란 이것"을 굳혀 놓은 물건이다. 서술자 정의나
# 데이터셋이 바뀌면 그 파일은 '조금 틀린' 게 아니라 **무의미**해지는데, 예전 로더는 아무 검사도
# 없이 그냥 로드해서 계속 자신 있는 p-value 를 냈다. 그러면 라우터가 존재하지 않는 분포에 맞춘
# 밴드로 판정을 계속한다 -- 에러도, 경고도 없이. 그래서 아래 여섯 가지 훼손은 전부 즉시
# CalibrationError 여야 한다. (좋은 파일은 여전히 로드돼야 하므로 그것도 함께 확인한다.)
let blob = JSON3.read(read(CAL_PATH, String)),
    base = Dict(String(k) => v for (k, v) in pairs(blob)),
    tmp  = mktempdir()

    function rejects(name, dict)
        p = joinpath(tmp, name * ".json")
        open(io -> JSON3.write(io, dict), p, "w")
        ok, detail = try
            CB.load_novelty_detector(p)
            false, "loaded without error"
        catch e
            e isa CB.CalibrationError ? (true, "") : (false, "threw $(typeof(e))")
        end
        check(name, ok, detail)
    end

    rejects("F1 pre-versioning file (no format_version)",
            filter(kv -> kv.first != "format_version", base))
    rejects("F2 unknown format_version",
            merge(base, Dict("format_version" => 99)))
    rejects("F3 renamed descriptor",
            merge(base, Dict("feature_names" => ["harm", "work_at_risk", "resource_loss",
                                                 "recovery_capacity", "progress", "SLACK_v2"])))
    # 순서만 바뀌어도 mu/sd 가 다른 축에 붙는다 -- 이름 집합만 보면 못 잡는 경우.
    rejects("F4 reordered descriptors (same names)",
            merge(base, Dict("feature_names" => ["work_at_risk", "harm", "resource_loss",
                                                 "recovery_capacity", "progress", "slack"])))
    rejects("F5 truncated mu (corrupt shape)",
            merge(base, Dict("mu" => collect(blob.mu)[1:3])))
    rejects("F6 empty cal_scores (degenerate p-values)",
            merge(base, Dict("cal_scores" => Float64[])))

    ok = try
        CB.load_novelty_detector(CAL_PATH); true
    catch
        false
    end
    check("F7 the real calibration still loads", ok)
end

CB.clear_novelty_detector!()
banner("SUMMARY")
println("  $(PASS[]) passed, $(FAIL[]) failed")
FAIL[] == 0 || exit(1)
