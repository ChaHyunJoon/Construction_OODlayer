#!/usr/bin/env python
"""
features_agnostic.py -- KIND-AGNOSTIC feature representation for the surrogate.

WHY THIS FILE EXISTS
====================
The deployed featurizer (`e1_analyze.featurize`) encodes the OOD **class name** into the
feature vector FOUR separate times:

  1. explicit `kind_fault / kind_battery / kind_zone / kind_zoneblk` one-hots
  2. `soc`           sentinel: -1 for every non-battery row   (battery <-> the rest)
  3. `zone_overlap`  sentinel: -1 for every non-zone row      (zone    <-> the rest)
  4. `agent_pending` sentinel: -1 for every zone row          (zone    <-> the rest)

Because of (2)-(4), DELETING THE ONE-HOTS ACHIEVES NOTHING: the sentinel pattern alone
reconstructs the class exactly (a leakage audit recovers the class name from the legacy feature
matrix with accuracy 1.000, chance 0.333). A held-out kind therefore arrives as an all-zeros
one-hot AND an unprecedented sentinel pattern -- a region of feature space with no training
support at all.

HOW MUCH THIS ACTUALLY COSTS (measured, not assumed)
    An earlier session reported leave-one-kind-out regret ~1.0 for the legacy representation.
    THAT NUMBER DOES NOT REPRODUCE HERE and should not be quoted. Measured on 60 instances with
    the deployed decision path (valid-mask gating, cost-aware lambda=3), legacy LOKO regret is
    0.120 and this file's representation is 0.100 -- a real and statistically significant
    improvement (CI [+0.005, +0.040]), but a modest one, not a collapse-to-rescue story.
    See artifacts_openworld/README.md for the confirmed table and the retraction list.

Worse, `severity` is not merely uninformative across kinds -- it is ACTIVELY MISLEADING,
because its physical meaning inverts:

    kind      severity means            harmful direction
    --------  ------------------------  ------------------
    fault     1.0 consequential / 0.0 idle   HIGH is harmful
    battery   post-drop SoC (0.05 .. 0.6)    LOW  is harmful   <-- INVERTED
    zoneblk   zone offset (0.0 .. ~1.1)      HIGH is harmful

A model that learns "high severity -> intervene" from fault rows does exactly the WRONG
thing on battery rows. No amount of extra data fixes a feature whose sign flips by class.

THE FIX (this file)
===================
Re-express every event as PHYSICAL DESCRIPTORS that carry the same meaning and the same
sign in every class, with no sentinels:

    harm               [0,1]  how damaging the event is (1 = maximally damaging), ALWAYS
                              monotone in the same direction
    work_at_risk       [0,1]  how much work the event threatens, in units of ONE ROBOT'S
                              AVERAGE SHARE of the remaining work
    resource_loss      [0,1]  how much of the AFFECTED ROBOT'S capability was lost
                              (0 when the event involves no robot at all)
    recovery_capacity  [0,1]  spare provisioning relative to the active fleet
    progress           [0,1]  build progress when the event fired
    slack              [0,1]  remaining parallelism (active fleet / reference fleet)

REVISION 2026-07-28 -- three formulas changed (the count did not). Why, in one place:

  (a) `work_at_risk` divided by ALL the remaining work. A robot that died holding 4 of 255
      remaining tasks scored 0.016 -- "negligible". Handed those numbers, gpt-4o-mini flipped
      ALL 18 deep-discharge instances from Replace to NOOP, quoting "minimal impact on overall
      work at risk". The denominator is now ONE ROBOT'S SHARE (pending/n_active), so the same
      event scores 0.345. A build does not stall in proportion to fleet percentage.
  (b) `resource_loss` had the same fleet-size denominator (0.043 for a dead robot). Removed.
  (c) `harm` read `severity` on a fault. That field is the EXPERIMENTER'S ANSWER KEY in the
      dumps (fault=1.0 / faultidle=0.0, hardcoded in gen_oracle_dataset.jl) and a constant 1.0
      in deployment (policy.jl). So a representation leaning on it looked good in evaluation and
      could not work in the field: measured, a harm-only feature set goes 0.067 -> 0.167 LOIO
      regret once severity is held at its deployment value. `harm` is now 1.0 for any fault, and
      telling harmful from harmless faults is `work_at_risk`'s job -- a MEASURABLE quantity.

  Measured effect (descriptor_ablation.py, 60 instances): LOIO regret 0.082 -> 0.033, and
  unchanged whether or not the answer key is present. Novel-kind detection recall (the router's
  job) 0.67 -> 1.00 on zoneblk.

  NOTE `resource_loss` was briefly deleted as redundant -- once its denominator is gone it equals
  `harm` for agent events, and dropping it cost nothing on decision quality. Restoring it was
  necessary because it is the ONLY descriptor carrying "is this event attached to a robot or to a
  region" (it is 0 for spatial events), which is what makes a never-seen ZONE look novel to a
  detector trained on ROBOT events. Deleting it halved novel-kind recall (0.67 -> 0.33).
  Lesson worth keeping: a feature can be redundant for CHOOSING and essential for DETECTING.

ARCHITECTURAL PAYOFF (this is the point, not just tidier features)
==================================================================
Once the surrogate lives in DESCRIPTOR space rather than CLASS-NAME space, the LLM's job for
a genuinely novel OOD class changes from the impossible

    "invent a new DSL kind, and a new enactment path for it"

to the tractable

    "read the NL observation and estimate 6 numbers"

which is exactly the kind of grounded estimation an LLM is good at. The surrogate then scores
the candidate macros zero-shot, with NO retraining, because the new event lands inside the
descriptor ranges the model already learned from the other classes.

HONEST LIMIT (do not oversell this)
===================================
Descriptor transfer works only when the held-out class's correct response is a macro the model
HAS seen. You cannot generalise to an ACTION never observed: hold out every zone row and macro
3 (ForbidZone) has zero training support, so its value is unlearnable by construction. That
case MUST fall through to the oracle/verify-all fallback. `action_repr="descriptor"` below
softens this by describing macros compositionally (cost / soft / restores-capacity / spatial),
so an unseen action is scored BY ANALOGY -- but analogy is not evidence, and the fallback stays
the safety net. LOKO is reported split by regime in `openworld_experiments.py loko`.

--------------------------------------------------------------------------------------------
[한국어 설명]
이 파일이 하는 일: surrogate 의 입력 특징(feature)을 "OOD 종류 이름"이 아니라 "물리량"으로 다시 쓴다.

왜 필요한가:
  기존 featurize 는 종류(kind)를 네 번 인코딩한다 — ① kind one-hot 4열, ② soc 가 battery 아니면 -1,
  ③ zone_overlap 이 zone 아니면 -1, ④ agent_pending 이 zone 이면 -1. 그래서 one-hot 만 지워도
  센티넬(-1) 패턴만으로 종류가 완벽히 복원된다 = 아무 효과 없음.
  게다가 severity 는 종류마다 의미가 뒤집힌다(fault 는 클수록 나쁨, battery 는 작을수록 나쁨).
  fault 에서 배운 규칙이 battery 에서 정반대로 작동한다 → 데이터를 아무리 늘려도 못 고침.

무엇으로 바꾸나: 모든 종류에서 의미와 부호가 같은 6개 물리 서술자(harm / work_at_risk /
  resource_loss / recovery_capacity / progress / slack). 센티넬 없음.

설계상 이득: 새로운 OOD 가 왔을 때 LLM 이 해야 할 일이 "새 DSL 종류를 발명하라"(불가능)에서
  "관찰을 읽고 숫자 6개를 추정하라"(LLM 이 잘하는 일)로 바뀐다. 그러면 surrogate 가 재학습 없이
  zero-shot 으로 점수를 매길 수 있다.

[2026-07-28 수정] 개수는 그대로지만 **계산식 3개가 바뀌었다.** 자세한 근거는 위 영문 REVISION 절.
  ① work_at_risk 의 분모: "남은 일 전체" → "로봇 한 대 평균 몫".
     죽은 로봇이 4/255 = 0.016 = '별일 아님'으로 보이던 문제. 이 숫자를 준 LLM 은 깊은 방전
     18건 전부에서 교체 대신 방치를 골랐다("전체 위태로운 일에 미치는 영향이 최소"라고 적으면서).
     이제 4/(255/22) = 0.345.
  ② resource_loss 에서 /함대크기 제거(같은 병).
  ③ harm 이 고장 사건에서 severity 를 **안 읽는다.** 그 값은 덤프에선 실험자가 붙인 정답표이고
     실전에선 항상 1.0 인 상수라, 그걸 읽는 표현은 평가에서만 좋아 보이고 현장에서 무너진다
     (실측: 배포 조건에서 LOIO 0.067 → 0.167). 유해/무해 고장 구분은 work_at_risk 가 맡는다.
  실측 효과: LOIO regret 0.082 → 0.033(정답표 유무와 무관하게 동일), 새 종류 탐지율 0.67 → 1.00.

  주의: resource_loss 를 한 번 지웠다가 되살렸다. 결정 품질로는 harm 과 중복이라 지워도 손해가
  없었지만, **"이 사건이 로봇에 붙었나 공간에 붙었나"를 담는 유일한 축**이라 지우자 새 종류
  탐지율이 반토막(0.67→0.33) 났다. 결정에는 불필요해도 판별에는 필수인 특징이 있다.

정직한 한계: 이 전이는 "정답 macro 를 모델이 이미 본 적 있을 때"만 통한다. zone 을 통째로 빼면
  ForbidZone(macro 3)은 학습 근거가 0이라 원리적으로 예측 불가 → 반드시 오라클 fallback 으로 떨어져야 함.

[문법 참고]
  - np.clip(x, lo, hi)      : 값을 [lo,hi] 범위로 자름.
  - pd.Series.apply(f)      : 열의 각 원소에 함수 f 적용.
  - math.isnan(v)           : v 가 NaN(값 없음)인지.
  - df.get("c", default)    : 열이 없으면 default 를 쓰는 안전한 열 접근.
--------------------------------------------------------------------------------------------
"""
import math

import numpy as np
import pandas as pd

# 전체 macro 목록과 개입 비용(e1_analyze / export_surrogate 와 동일한 값이어야 함).
MACROS = [0, 1, 2, 3, 4, 7, 8]
# 5·6 은 조합 팔(DS_COMBO_ARMS=1 일 때만 생성된다). gen_oracle_dataset.jl 의 MACRO_COST 와
# **같은 값**이어야 한다 — 구성 primitive 비용의 합(_PRIMITIVE_TABLE 참조).
# 7 = RelocateBuild(빌드 전체 평행이동). zone 사건의 기본 개입 팔로 3(ForbidZone)을 대체한다 —
# 3 은 closed≈46 이후 옮길 수 있는 조립체가 없어 NOOP 과 동일해지기 때문(oracle/ood_mdp_shim.jl 참조).
# 전역 개입이라 조립체 하나만 옮기는 ForbidZone(1.0)보다 비싸다.
# 8 = SwapBattery(현장 배터리 교체). 배터리는 재고 관리를 안 하므로(무제한, 비용만) 개입 중 가장
# 싸다. Replace(1.0)보다 확실히 싸야 "싸게 살릴까 비싸게 살릴까"가 진짜 선택이 된다.
MACRO_COST = {0: 0.0, 1: 1.0, 2: 0.3, 3: 1.0, 4: 1.0, 5: 1.8, 6: 0.8, 7: 1.5, 8: 0.2}

# 참조 함대 크기: slack 을 [0,1] 로 정규화할 때 쓰는 상수(현 트랙터 트윈의 최대 활성 로봇 수 기준).
FLEET_REF = 30.0


def _f(v, default=math.nan):
    """JSON 이 문자열로 준 'NaN'/'Inf'/None 을 float 으로 되돌린다(없으면 default)."""
    if v is None:
        return default
    if isinstance(v, str):
        if v in ("NaN", "nan"):
            return math.nan
        if v in ("Inf", "inf"):
            return math.inf
        try:
            return float(v)
        except ValueError:
            return default
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _finite(v):
    """유한한 실수인가(NaN/Inf/센티넬 -1 아님)."""
    x = _f(v)
    return isinstance(x, float) and math.isfinite(x)


# ==========================================================================================
#  단일 행 -> 물리 서술자
# ==========================================================================================
def descriptors_from_row(row):
    """한 행(dict 또는 pandas Series)에서 kind-agnostic 물리 서술자 6개를 계산한다.

    핵심 규칙: **종류 이름(row['kind'])을 절대 읽지 않는다.** 어떤 필드가 유한한 값인지로만
    사건의 물리적 성격을 판별한다. 그래야 처음 보는 종류에도 같은 코드가 그대로 돈다.

      - soc 가 유한         -> 에이전트의 "능력 저하" 사건 (배터리류)
      - agent_pending >= 0  -> 특정 에이전트에 귀속된 사건 (고장/배터리류)
      - zone_overlap >= 0   -> 공간 영역 사건 (구역류)
    """
    soc = _f(row.get("soc"))
    zov = _f(row.get("zone_overlap"), -1.0)
    apend = _f(row.get("agent_pending"), -1.0)
    sev = _f(row.get("severity"), 0.0)
    n_active = max(1.0, _f(row.get("n_active"), 1.0))
    spare = max(0.0, _f(row.get("spare_count"), 0.0))
    closed_at_fire = _f(row.get("closed_at_fire"), 0.0)
    total_nodes = _f(row.get("total_nodes"), 0.0)
    progress = _f(row.get("progress"), 0.0)

    has_soc = math.isfinite(soc)
    is_spatial = math.isfinite(zov) and zov >= 0.0
    is_agent = math.isfinite(apend) and apend >= 0.0

    # 남은 일의 총량(0 나눗셈 방지). 이게 work_at_risk 의 분모.
    pending_total = total_nodes - closed_at_fire
    if not math.isfinite(pending_total) or pending_total <= 0:
        pending_total = 1.0

    # ---- harm: "얼마나 나쁜 사건인가" [0,1], 항상 클수록 나쁨 -----------------------------
    # 배터리류: 잔량이 낮을수록 나쁨 -> 1-soc 로 부호를 뒤집어 다른 종류와 방향을 맞춘다.
    # 공간류: 덮은 비율 자체가 곧 피해 정도.
    # 고장류: **1.0 (능력 100% 상실)**. 예전에는 severity 를 그대로 읽었는데, 그 severity 는
    #   학습 덤프에서 실험자가 손으로 붙인 정답표(fault=1.0 / faultidle=0.0)이고
    #   실제 배포(policy.jl)에서는 모든 고장에 1.0 인 상수다. 즉 harm 이 "유해한 고장 vs 무해한
    #   고장"을 가르고 있었다면 그건 학습 때만 통하는 지름길이었다. 실측: severity 를 배포와 같이
    #   1.0 으로 고정하면 harm 에만 의존하는 표현의 LOIO regret 이 0.067 -> 0.167 로 무너진다
    #   (descriptor_ablation.py 의 B). 그래서 여기서는 정답표를 아예 읽지 않는다.
    #   유해/무해를 가르는 일은 아래 work_at_risk 가 **측정값으로** 맡는다.
    # 그 외(어느 것도 해당 없는 미지의 사건): 달리 근거가 없으므로 주어진 severity 를 쓴다
    #   (개방세계 경로에서는 LLM 이 관찰을 읽고 채워 넣는 자리).
    if has_soc:
        harm = 1.0 - soc
    elif is_spatial:
        harm = zov
    elif is_agent:
        harm = 1.0
    else:
        harm = sev
    harm = float(np.clip(harm, 0.0, 1.0))

    # ---- work_at_risk: 이 사건이 위협하는 일의 크기 [0,1] ---------------------------------
    # 분모가 바뀌었다. 예전에는 "남은 일 **전체**"로 나눴다:
    #       4개 작업 / 남은 255개 = 0.016   -> 죽은 로봇이 "별일 아님"으로 보였다.
    # 이제는 "로봇 **한 대 평균 몫**"으로 나눈다:
    #       4개 작업 / (255/22) = 4*22/255 = 0.345
    # 뜻: "평균적인 로봇 한 대가 지고 있는 몫에 비해, 이 로봇이 얼마나 많은 일을 쥐고 있나".
    # 1.0 이면 평균 몫 이상을 혼자 쥐고 있다는 뜻. 함대가 커져도 의미가 희석되지 않는다.
    #
    # 왜 이게 중요한가: 이 값이 유해한 고장(일을 쥔 로봇)과 무해한 고장(노는 로봇)을 가르는
    # **유일하게 측정 가능한** 신호다. 빌드가 멈추는 이유는 그 로봇이 함대의 4% 라서가 아니다.
    # 공간 사건이면 zone_overlap 이 이미 "미완 staging 중 덮인 비율"이라 그대로 같은 의미.
    if is_agent:
        per_robot_share = max(1e-9, pending_total / n_active)
        war = apend / per_robot_share
    elif is_spatial:
        war = zov
    else:
        war = 0.0
    work_at_risk = float(np.clip(war, 0.0, 1.0))

    # ---- resource_loss: "그 로봇이 잃은 능력" [0,1] ---------------------------------------
    # 분모(/함대크기)를 없앴다. 예전 (1-soc)/n_active 는 죽은 로봇을 4% 로 보이게 했다.
    # 이제는 그냥 (1-잔량) = 그 로봇이 잃은 능력. 고장이면 1.0, 배터리 5% 면 0.95.
    # **공간 사건(구역)은 로봇에 붙은 사건이 아니므로 0.**
    #
    # 한 번 뺐다가 되살린 이유(2026-07-28):
    #   결정 품질만 보면 이 값은 harm 과 중복이다 -- 빼도 LOIO 0.033 로 동일했다.
    #   그러나 **낯섦 판별(라우터)** 에서는 이 값이 "로봇에 붙은 사건 vs 공간에 붙은 사건"을
    #   담는 유일한 축이다. 빼자 새 종류 탐지율이 zoneblk 0.67 -> 0.33 으로 반토막 났고,
    #   되살리자 1.00 이 되었다(옛 정의보다도 좋다).
    #   교훈: **결정에 불필요한 특징이 판별에는 필수일 수 있다.** 두 소비자의 요구가 다르다.
    if is_agent:
        capability_left = soc if has_soc else 0.0
        resource_loss = 1.0 - float(np.clip(capability_left, 0.0, 1.0))
    else:
        resource_loss = 0.0
    resource_loss = float(np.clip(resource_loss, 0.0, 1.0))

    # ---- recovery_capacity: 복구 자원 여유 [0,1] -----------------------------------------
    recovery_capacity = float(spare / max(1.0, spare + n_active))

    # ---- slack: 남은 병렬성 [0,1] ---------------------------------------------------------
    slack = float(np.clip(n_active / FLEET_REF, 0.0, 1.0))

    return {
        "harm": harm,
        "work_at_risk": work_at_risk,
        "resource_loss": resource_loss,
        "recovery_capacity": recovery_capacity,
        "progress": float(np.clip(progress, 0.0, 1.0)),
        "slack": slack,
    }


# 실제로 쓰는 서술자 6개. 2026-07-28 에 harm / work_at_risk / resource_loss 의 **계산식**이 바뀌었다
# (개수는 그대로). 각각의 이유는 descriptors_from_row 안의 해당 주석에 있다.
# 이 목록만 바꾸면 featurize/교정/게이트가 함께 따라온다. 순서가 곧 Julia 쪽 event_descriptors 의
# 반환 순서다 -- 둘이 어긋나면 교정이 무의미해지므로 tools/test_novelty.jl 이 1e-9 로 대조한다.
STATE_DESCRIPTORS = ["harm", "work_at_risk", "resource_loss",
                     "recovery_capacity", "progress", "slack"]


# ==========================================================================================
#  액션(macro)의 kind-agnostic 서술자
# ==========================================================================================
# macro 를 이름표(one-hot) 대신 "무엇을 하는 행동인가"로 기술한다. 5개 macro 를 유일하게 구분하면서도
# 축을 공유하므로, 학습 때 못 본 액션도 유사한 축 조합으로 유추(analogy)될 여지가 생긴다.
#   a_cost              : 개입 비용(=MACRO_COST)
#   a_intervenes        : 아무것도 안 하는가(0) vs 개입하는가(1)
#   a_soft              : 하드 제약 없이 비용만 조정하는 부드러운 개입인가
#   a_restores_capacity : 잃은 실행 자원을 되돌리는가(스페어 투입)
#   a_relocates_work    : 일/배치를 옮겨서 푸는가
#   a_spatial           : 공간 기하를 건드리는가
ACTION_DESCRIPTORS = ["a_cost", "a_intervenes", "a_soft",
                      "a_restores_capacity", "a_relocates_work", "a_spatial"]

_ACTION_TABLE = {
    #        cost, intervenes, soft, restores, relocates, spatial
    0: (0.0, 0.0, 0.0, 0.0, 0.0, 0.0),   # NOOP
    1: (1.0, 1.0, 0.0, 1.0, 0.0, 0.0),   # Replace       : 스페어로 능력 복원
    2: (0.3, 1.0, 1.0, 0.0, 0.0, 0.0),   # Deprioritize  : 소프트, 비용만 조정
    3: (1.0, 1.0, 0.0, 0.0, 1.0, 1.0),   # ForbidZone    : 일을 공간적으로 옮김
    4: (1.0, 1.0, 0.0, 0.0, 1.0, 0.0),   # ReformTeam    : 팀 구성을 옮김(비공간)
    7: (1.5, 1.0, 0.0, 0.0, 1.0, 1.0),   # RelocateBuild : 빌드 전체를 공간적으로 옮김(ForbidZone 의 전역판)
}


def action_descriptors(macro):
    """macro 번호 -> 액션 서술자 dict."""
    vals = _ACTION_TABLE.get(int(macro), (0.0,) * 6)
    return dict(zip(ACTION_DESCRIPTORS, vals))


# ==========================================================================================
#  조합 행동의 서술자 ψ(a)  — PLAN_ACTION_GROWTH.md §4 [3]
# ==========================================================================================
# 왜 필요한가: 지금 액션은 5개 매크로에 대한 one-hot 이라, 6번째 행동을 넣으면 모델 입력 차원이
# 바뀌어 재학습 없이는 아무것도 못 한다. 이건 이 저장소의 사고가 아니라 one-hot 을 쓰는 모든
# 시스템의 구조적 귀결이고(Chandak et al., "Lifelong Learning with a Changing Action Set", AAAI'20),
# 문헌이 제시한 탈출구는 행동을 **id 가 아니라 효과(서술자) 공간의 점**으로 적는 것이다.
# 그러면 새 행동은 ψ-공간의 새 점일 뿐이고 차원이 바뀌지 않는다.
#
# 엔진은 이미 다중 spec 을 받는다 -- RespecProposal.constraints 는 Vector 이고
# replan.jl 이 `for c in proposal.constraints` 로 순회한다. 즉 조합 행동은 오늘 실행 가능하다.
#
# **primitive 6개** (src/respec/spec_dsl.jl). 이 중 ForbidAgent 와 ForbidWindow 는
# 매크로로 노출조차 안 되어 있다(= 놀고 있는 primitive).
_PRIMITIVE_TABLE = {
    #                       cost, intervenes, soft, restores, relocates, spatial, consumes_spare, reversible, scope
    "ReplaceAgent":        (1.0, 1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0),
    "DeprioritizeAgent":   (0.3, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0),
    "ForbidZone":          (1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 2.0),
    "ReformTeam":          (1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 3.0),
    # --- 아직 매크로로 노출되지 않은 primitive ---
    "ForbidAgent":         (0.8, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0),
    "ForbidWindow":        (0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0),
    # RelocateBuild: 구역은 그대로 두고 작업영역 **전체**를 강체이동. ForbidZone 과 같은 공간축이지만
    # scope 가 전역(3)이고 되돌릴 수 없다(reversible=0) — 이미 옮겨간 자리에서 빌드가 계속되므로.
    "RelocateBuild":       (1.5, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 3.0),
    # SwapBattery: 같은 본체에 배터리만 교체. restores=1(건강 회복)이지만 ReplaceAgent 와 달리
    # consumes_spare=0 (창고 본체를 안 먹음) — 이 한 칸이 두 팔을 가르는 축이다. 되돌릴 필요가
    # 없는 국소 개입이라 reversible=1, scope=1(로봇 하나).
    "SwapBattery":         (0.2, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0),
}

# ψ 의 축. 앞 6개는 기존 ACTION_DESCRIPTORS 와 **완전히 같은 이름·같은 값**이어야 한다
# (기존 실험과의 비교 가능성 = 회귀 방지). 뒤 3개가 조합을 표현하기 위해 추가된 축이다.
#   a_n_specs        : 조합의 크기 (1, 2, 3...)
#   a_consumes_spare : 스페어를 소모하는가 <- **전환비용의 핵심**. "지금 쓰면 다음에 없다"를
#                      모델이 표현할 수 있게 하는 축(myopia 문제와 여기서 만난다).
#                      오늘의 5매크로에서는 a_restores_capacity 와 값이 일치하지만, 새 primitive
#                      에서는 갈라진다(예: 스페어를 안 쓰는 능력복원, 스페어를 쓰는 선제배치).
#   a_reversible     : 되돌릴 수 있는가 (조합에서는 AND -- 하나라도 비가역이면 비가역)
#   a_scope          : 영향 범위 (1대=1 / 구역=2 / 전역=3)
PSI_AXES = ACTION_DESCRIPTORS + ["a_n_specs", "a_consumes_spare", "a_reversible", "a_scope"]

# 매크로 -> primitive 조합. 기존 5개는 전부 **spec 하나**다(그래서 조합축이 통째로 비어 있다).
MACRO_SPECS = {
    0: [],                       # NOOP
    1: ["ReplaceAgent"],
    2: ["DeprioritizeAgent"],
    3: ["ForbidZone"],
    4: ["ReformTeam"],
    # 조합 행동 예시(A1 스모크 대상). 여기 추가해도 **모델 입력 차원은 변하지 않는다** — 이게 요점.
    5: ["ForbidAgent", "ReformTeam"],
    6: ["DeprioritizeAgent", "ForbidWindow"],
    7: ["RelocateBuild"],        # zone 사건의 기본 개입 팔(3 을 대체). spec 하나짜리.
}


def psi(action):
    """행동 -> ψ 벡터(dict). action 은 매크로 번호(int)이거나 primitive 이름들의 리스트.

    집계 규칙 -- 왜 이렇게 정했는지가 중요하다(임의로 정하면 조합의 의미가 흐려진다):
      cost            : 합   (두 제약을 걸면 두 번 개입한 것)
      intervenes      : max  (하나라도 개입하면 개입)
      soft            : min  (하나라도 하드 제약이면 그 조합은 더 이상 소프트가 아니다)
      restores/relocates/spatial/consumes_spare : max (하나라도 그 성질이면 그 성질)
      reversible      : min  (AND -- 하나라도 못 되돌리면 조합 전체가 비가역)
      scope           : max  (가장 넓은 범위가 조합의 범위)
      n_specs         : len
    """
    if isinstance(action, (list, tuple)):
        names = list(action)
    else:
        names = MACRO_SPECS.get(int(action), [])

    if not names:                                  # NOOP
        return dict(zip(PSI_AXES, (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)))

    v = [_PRIMITIVE_TABLE[n] for n in names if n in _PRIMITIVE_TABLE]
    if not v:
        return dict(zip(PSI_AXES, (0.0,) * len(PSI_AXES)))
    cols = list(zip(*v))                           # 축별 열
    out = {
        "a_cost":              float(sum(cols[0])),
        "a_intervenes":        float(max(cols[1])),
        "a_soft":              float(min(cols[2])),
        "a_restores_capacity": float(max(cols[3])),
        "a_relocates_work":    float(max(cols[4])),
        "a_spatial":           float(max(cols[5])),
        "a_n_specs":           float(len(v)),
        "a_consumes_spare":    float(max(cols[6])),
        "a_reversible":        float(min(cols[7])),
        "a_scope":             float(max(cols[8])),
    }
    return {k: out[k] for k in PSI_AXES}


def psi_regression_check():
    """ψ 가 기존 5매크로에서 옛 표와 **한 자리도 다르지 않은지** 검사한다.

    이게 깨지면 조합 확장이 기존 실험 숫자를 조용히 바꾼 것이므로, 비교가 전부 무효가 된다.
    """
    bad = []
    for m in (0, 1, 2, 3, 4):
        old = action_descriptors(m)
        new = psi(m)
        for k in ACTION_DESCRIPTORS:
            if abs(float(old[k]) - float(new[k])) > 1e-12:
                bad.append((m, k, old[k], new[k]))
    return bad


# ==========================================================================================
#  DataFrame 전체 featurize
# ==========================================================================================
# ==========================================================================================
#  STEP 3: 공간 사건의 기하 원시값(primitive) 블록
# ------------------------------------------------------------------------------------------
#  `zone_overlap` 스칼라 하나로는 "덮였다"까지만 말할 수 있고 **무엇이 왜 막혔는지**는 표현하지
#  못한다. 그래서 정책은 구역 사건에서 사실상 종류 이름만 보고 답할 수밖에 없었다.
#  생성기(gen_oracle_dataset.jl)가 이제 진단기의 술어를 그대로 행에 싣는다. 여기서 그것을 읽는다.
#
#  ★ 판정(verdict)은 여기 없다. 그건 정답이므로 오라클/게이트의 것이고, 특징에 넣으면 모델이
#    추론이 아니라 답을 베끼게 된다(zone_diagnosis.jl 의 note).
#
#  기본은 **꺼짐**이다: 이 열을 넣으면 특징 차원이 바뀌어 이미 export 된 서로게이트·novelty 교정과
#  호환되지 않는다. 옛 덤프에는 열 자체가 없으므로 그때는 -1 sentinel 로 채워져 "모름"이 된다.
ZONE_PRIMITIVES = ["zone_blocked", "zone_restage_feasible", "zone_work_overlap",
                   "zone_teams_forming", "zone_teams_covered",
                   "zone_relocatable", "zone_relocate_norm"]


def zone_primitives_from_row(row):
    """행에서 기하 원시값 7개를 읽는다. 없거나 zone 사건이 아니면 -1(=모름/해당없음)."""
    out = {}
    for k in ZONE_PRIMITIVES:
        out[k] = _f(row.get(k), -1.0)
        if not math.isfinite(out[k]):
            out[k] = -1.0
    return out


def featurize_agnostic(df, action_repr="onehot", include_valid=True,
                       include_zone_primitives=False):
    """kind-agnostic 특징행렬을 만든다.

    Parameters
    ----------
    action_repr : "onehot"     -- macro 를 기존처럼 one-hot 5열로 (기존과 공정 비교용)
                  "descriptor" -- macro 를 6개 서술자로 (미지 액션 유추 가능성 실험용)
                  "both"       -- 둘 다
    include_valid : `macro_in_valid`(이 상태에서 그 macro 가 적용 가능한가) 열을 넣을지.
                    이건 종류 이름이 아니라 "액션 적용가능성"이라 정당한 정보다.
    include_zone_primitives : 구역 사건의 기하 원시값 7열(ZONE_PRIMITIVES)을 넣을지.
                    기본 False = 기존 특징행렬과 **완전히 동일**(배포된 모델과 호환).

    반환: pandas DataFrame (행 순서는 입력과 동일)
    """
    X = pd.DataFrame(index=df.index)

    # ---- 상태 서술자 -------------------------------------------------------------------
    desc = [descriptors_from_row(df.iloc[i]) for i in range(len(df))]
    for name in STATE_DESCRIPTORS:
        X[name] = [d[name] for d in desc]

    # ---- 액션 표현 ---------------------------------------------------------------------
    if action_repr in ("onehot", "both"):
        for m in MACROS:
            X[f"macro_{m}"] = (df.macro.astype(int) == m).astype(float).values
    if action_repr in ("descriptor", "both"):
        adesc = [action_descriptors(m) for m in df.macro.astype(int).values]
        for name in ACTION_DESCRIPTORS:
            X[name] = [a[name] for a in adesc]
    if action_repr in ("psi", "both_psi"):
        # ψ: 조합까지 표현하는 확장 서술자. 행에 `spec_seq`(primitive 이름 리스트)가 있으면
        # 그걸 쓰고, 없으면 매크로 번호로 되돌아간다 -- 옛 덤프도 그대로 읽힌다.
        seqs = df["spec_seq"] if "spec_seq" in df.columns else [None] * len(df)
        acts = [s if isinstance(s, (list, tuple)) and len(s) else int(m)
                for s, m in zip(seqs, df.macro.astype(int).values)]
        pdesc = [psi(a) for a in acts]
        for name in PSI_AXES:
            X[name] = [p[name] for p in pdesc]
    if action_repr == "both_psi":
        for m in MACROS:
            X[f"macro_{m}"] = (df.macro.astype(int) == m).astype(float).values

    # ---- 공간 사건의 기하 원시값(opt-in) --------------------------------------------------
    if include_zone_primitives:
        zp = [zone_primitives_from_row(df.iloc[i]) for i in range(len(df))]
        for name in ZONE_PRIMITIVES:
            X[name] = [z[name] for z in zp]

    # ---- 적용가능성 게이트 --------------------------------------------------------------
    if include_valid:
        from e1_analyze import _valid_list  # 순환 import 피하려 여기서 지연 import
        vmask = df.get("valid_mask", pd.Series([[]] * len(df), index=df.index))
        X["macro_in_valid"] = [
            1.0 if int(m) in _valid_list(v) else 0.0
            for m, v in zip(df.macro, vmask)
        ]

    return X


# ==========================================================================================
#  진단: 이 표현이 정말 kind 를 안 흘리는가?
# ==========================================================================================
def kind_leakage_report(df, featurizer, name="features"):
    """특징행렬만으로 kind 를 얼마나 잘 맞힐 수 있는지 측정한다(누출 감사).

    accuracy 가 1.0 이면 그 표현은 종류를 완벽히 복원한다 = kind-agnostic 이 아니다.
    무작위 추측 수준(1/n_kinds)에 가까울수록 종류 정보가 지워진 것.
    단, 물리적으로 종류가 다르면 서술자도 다른 게 정상이므로 0 을 목표로 하진 않는다 --
    이 수치는 "one-hot/센티넬 같은 공짜 지름길이 남아있는가"를 잡는 용도.
    """
    from sklearn.ensemble import RandomForestClassifier
    from sklearn.model_selection import cross_val_score

    X = featurizer(df)
    y = df.kind.astype(str).values
    n_kinds = len(set(y))
    if n_kinds < 2:
        return {"name": name, "acc": float("nan"), "chance": float("nan"), "n_kinds": n_kinds}
    clf = RandomForestClassifier(n_estimators=200, random_state=0)
    # 행 단위 5-fold (instance 누출은 여기선 중요치 않음 -- 지름길 존재 여부만 본다)
    acc = float(np.mean(cross_val_score(clf, X.values, y, cv=min(5, n_kinds + 2))))
    return {"name": name, "acc": acc, "chance": 1.0 / n_kinds, "n_kinds": n_kinds}


if __name__ == "__main__":
    import sys

    from e1_analyze import featurize as featurize_legacy
    from e1_analyze import load

    path = sys.argv[1] if len(sys.argv) > 1 else "oracle/out/graded_hs_all.jsonl"
    df = load(path)
    print(f"loaded {len(df)} rows, {df.instance.nunique()} instances from {path}\n")

    print("=" * 78)
    print("KIND-LEAKAGE AUDIT  (can the feature matrix alone recover the class name?)")
    print("=" * 78)
    for fn, nm in [(featurize_legacy, "legacy featurize"),
                   (lambda d: featurize_agnostic(d, "onehot"), "agnostic (onehot action)"),
                   (lambda d: featurize_agnostic(d, "descriptor"), "agnostic (descriptor action)")]:
        r = kind_leakage_report(df, fn, nm)
        flag = "LEAKS" if r["acc"] > 0.9 else ("reduced" if r["acc"] > r["chance"] + 0.15 else "clean")
        print(f"  {nm:32s} kind-recovery acc={r['acc']:.3f}  (chance={r['chance']:.3f})  -> {flag}")

    print("\n" + "=" * 78)
    print("DESCRIPTOR RANGES PER KIND  (do the classes now share a common scale?)")
    print("=" * 78)
    D = pd.DataFrame([descriptors_from_row(df.iloc[i]) for i in range(len(df))])
    D["kind"] = df.kind.values
    with pd.option_context("display.width", 160):
        print(D.groupby("kind")[STATE_DESCRIPTORS].agg(["min", "max"]).round(3))
