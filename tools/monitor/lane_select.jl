# tools/monitor/lane_select.jl
# =============================================================================
# 라우터의 **레인 선택 분기표**. 순수 함수 하나뿐이고 의존성이 없다 — policy.jl 은 67KB 에
# ENV·ConstructionBots 의존이라 통째로는 단위검사가 안 되기 때문에, 판단 규칙만 여기로 뺀다.
#
# 3-way 인 이유 (2026-08-14):
#   예전에는 타깃이 {surrogate, dspy} 뿐이었다(policy.jl:350). 그런데 surrogate 가 그 팔을
#   지원하지 않으면 dspy 로만 에스컬레이션하고(:754), dspy 가 죽어 있으면 :730 에서 조용히
#   canonical 로 떨어졌다. 즉 **canonical 은 이미 사실상 세 번째 주자인데 판정에는 그 사실이
#   안 적혔다.** 여기서 명시적으로 적는다.
#
# DP 는 여기 없다(Global Constraint 10): DP 의 a* 는 오프라인 표집 + backward induction 의
# 산물이라 "결정 시점에 이미 표가 있다" = 그 사건을 미리 다 굴려봤다는 뜻이다. 실행 정책과
# 같은 줄에 세우면 비교가 무의미해진다.
# =============================================================================

"""
    select_lane(; novel, available, supported, policy) -> (lane, reason, axis)

- `novel`     : novelty 판정 (p < eps). ⚠️ **축 2 의 임시 자리지킴**이다 — 설계서
                `2026-08-27-vocabulary-indexed-router-design.md` §3 의 축 2 는 conformal
                구간 겹침이고, 그것이 생기면 이 인자가 교체된다.
- `available` : 레인 가용성 Dict, 예 `Dict("surrogate"=>true, "dspy"=>false, "canonical"=>true)`
- `supported` : surrogate 가 이 사건의 팔을 **학습셋에서 지원하는가** (= 축 1)
- `policy`    : DEMO_POLICY. `"noop"` 이면 라우팅하지 않는다(통제 바닥선)

`axis` 는 **어느 조건이 이 판정을 냈는가**를 데이터로 남긴다:
`"control"` · `"vocabulary_gap"` · `"novelty"` · `"none"`.

🔴 왜 축을 반환하나 (2026-08-27): 예전에는 발화 조건이 `reason` 산문 안에만 있어서, 두 축의
발화 집합이 얼마나 겹치는지 재려면 문자열을 역파싱해야 했다. 그 숫자가 설계서 R5 다 —
완전히 겹치면 축 하나는 잉여다.

🔴 왜 어휘 미달이 1순위인가: novelty 는 **상태**가 낯선지를 보고 어휘 미달은 **행동을 표현할
수 있는지**를 본다. 후자는 novelty 교정 파일과 무관한 사실이고, 무엇보다 **경계를 움직이는
축**이다 — 새 매크로는 정의상 지원 밖이고 학습되면 정의상 안이다. 순서가 뒤집히면 같은
사건이 "낯설어서 올렸다" 로 기록되는데 사실은 "그 팔을 배운 적이 없어서" 다.

`reason` 은 화면 ROUTER 줄에 그대로 나가므로 영어로 쓴다(이 저장소의 화면 문구 규약).
"""
function select_lane(; novel::Bool, available::AbstractDict, supported::Bool,
                     policy::AbstractString)
    up(k) = get(available, k, false) === true

    # noop 은 후보가 아니라 통제 실험의 바닥선이다. 개입이 실제로 이득인지 재려면 아무도
    # 이 레인을 대신 판단해 주면 안 된다.
    policy == "noop" && return (lane = "noop", axis = "control",
        reason = "no-adapt floor — routing disabled for this control lane")

    # ---- 축 1: 어휘 미달 -----------------------------------------------------------------
    if !supported
        up("dspy") && return (lane = "dspy", axis = "vocabulary_gap",
            reason = "the surrogate has no training support for this arm → escalate to LLM")
        return (lane = "canonical", axis = "vocabulary_gap",
            reason = "the surrogate has no training support for this arm " *
                     "and the LLM lane is unavailable → canonical rule")
    end

    # ---- 축 2 (임시: novelty) ------------------------------------------------------------
    if novel
        up("dspy") && return (lane = "dspy", axis = "novelty",
            reason = "novelty p < eps — never seen this before → ask the LLM")
        return (lane = "canonical", axis = "novelty",
            reason = "novelty p < eps → LLM, but the LLM lane is unavailable → canonical rule")
    end

    up("surrogate") && return (lane = "surrogate", axis = "none",
        reason = "arms are supported and the state is familiar → surrogate")

    up("dspy") && return (lane = "dspy", axis = "none",
        reason = "familiar, but the surrogate lane is unavailable → LLM")

    return (lane = "canonical", axis = "none",
        reason = "familiar, but both the surrogate and LLM lanes are unavailable → canonical rule")
end
