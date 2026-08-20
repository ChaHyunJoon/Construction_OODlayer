#!/usr/bin/env python3
"""반사실 표집기 — 판 하나에서 **한 결정만** 팔을 갈아 끼워 **(칸, 팔, c, 다음칸)** 전이 표본을
만든다.

무엇을 재는가 (이름을 정확히 붙인다)
====================================
★ 이 머리말의 날짜 표기에 대하여 — **같은 날의 수정이 "2026-08-17" 과 "2026-08-15" 두 이름으로
적혀 있다.** 오타가 아니라 이 레포의 규약이다: 결과 세대 번호(문서·계획서의 날짜)가 시스템
시계보다 앞서 있어, 같은 작업일의 수정이 계획서 날짜(2026-08-17)로도 시스템 시각(2026-08-15)
으로도 적힌다. 결과 문서 `md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md` 머리말이 같은 사실을
적어 두었다. **두 날짜를 서로 다른 세대로 읽지 말 것** — 순서는 "n차 수정" 번호가 정한다.

★ 2026-08-17: 판 전체 고정(`DEMO_FORCE_MACRO`)에서 **1-step deviation** 으로 바꿨다.
한 rollout 은 canonical 정책으로 굴러가되, `pick_k(case, seed)` 가 그 (case, seed) 에서
결정론적으로 고른 **k 번째 결정 하나만** 지정한 팔로 갈아 집행한다(`DS_DEVIATE_AT=k` ·
`DS_DEVIATE_ARM=<이름>`, `tools/monitor/policy.jl` 이 그 훅을 해석한다). 나머지 결정은 전부
canonical 이 고른 대로 나간다.

**왜 바꿨나.** 구세대(판 전체를 `DEMO_FORCE_MACRO=<팔>` 로 고정)는 표집 판의 **83.1%**
(완주율 16.9%, 2026-08-16 실측)가 미완주로 죽었다 — 한 팔을 판 끝까지 강제하면 그 팔이
장기적으로 막다른 길이어도 되돌릴 수 없기 때문이다(§1-A). 그러면 표본이 죽는 궤적 근처로
쏠려 (칸,팔) 전이의 대다수가 dead_end 종단값만 본다. 1-step deviation 은 판을 canonical 로
계속 굴리고 **딱 한 결정**만 반사실로 바꾸므로, 판은 canonical 이 완주할 수 있었던 만큼
완주하고 그 한 칸에서의 반사실 비교만 얻는다. 구세대 상수-팔 표본은
`samples_gen_constantarm_2026-08-16.jsonl` 로 이름 붙여 보존했다(비교용, 지우지 않는다).

★ 2026-08-17 리뷰 수정 — **라벨은 판이 아니라 결정을 따른다.**
초판은 전이 행 전부를 그 판의 deviation 목표 팔(`arm_id`/`arm_name`)로 라벨했다. 그런데 엔진이
그 팔을 집행한 것은 **정확히 결정 k 하나**이고 나머지는 canonical 이 고른 대로 나간다 — 그래서
`i<k` 결정은 7팔에서 바이트 동일한데 라벨만 다른 가짜 동점을 만들고(R3 가 판 단위로 죽이려던
동점이 결정 단위로 되살아난 것), `i>k` 결정은 갈라진 궤적 위의 canonical 행동을 그 팔로
잘못 귀속시킨다(혼입). 고침: **각 전이는 그 결정에서 실제로 집행된 매크로(`d["macro"]`)로
라벨한다.** 그리고 (case, seed) 마다 rows 를 낸 판 중 **arm_id 최솟값**을 "owner" 로 정해
owner 만 전 결정을 내고, owner 가 아닌 판은 owner 의 canonical prefix 와 겹치는 `decision_index
< k` 를 버리고 `>= k` 만 낸다(중복 제거).

★ 2026-08-17 4차 수정 — **두 무집행 신호는 서로 다른 세계다. 하나로 합치면 안 된다.**
3차까지는 `enact_applied == False` 와 `deviated == False` 를 "무집행" 하나로 묶고 그중 arm_id
최솟값 하나만 대표로 남겼다. 그 전제("둘 다 canonical 과 바이트 동일")는 **거짓**이다:

  · **클래스 A — `deviated is False`.** 강제한 팔이 canonical 이 그 결정에서 이미 고르려던
    것과 같았다(policy.jl:1031 `rt["deviated"] = (dev != chosen)`) ⇒ 이 판은 **canonical 과**
    바이트 동일하다.
  · **클래스 B — `enact_applied is False`.** 집행 사슬(run_demo.jl:352-457)의 **어떤 분기도
    안 탔다** ⇒ 결정 k 에서 세계가 그대로다 ⇒ 이 판은 **NOOP 팔 판과** 바이트 동일하지
    canonical 과는 다르다. canonical 이었다면 자기 매크로의 분기(hot-swap·rebalance·restage·
    reform)를 실제로 탔을 것이므로, canonical 의 매크로가 NOOP 이 아닌 한 클래스 B 는
    canonical 에서 갈라진다.

실측이 그 차이를 이미 보여줬다(2차 스모크, 같은 (case,seed)): arm1(`deviated=false`, A)은
`n_decisions=4, complete=True` 인데 arm3(`enact_applied=false`, B)은 `n_decisions=14,
complete=False` 였다 — "둘 다 canonical 과 바이트 동일" 이면 있을 수 없는 차이다.
합쳐서 `min()` 을 취하면 클래스 B 의 팔 id 가 대체로 더 작아(zone: 1,2,8 이 B / reform:
1,2,3,7,8 이 B) **owner 와 중복인 판을 대표로 남기고 유일한 canonical 판을 버린다.**

그래서 둘을 **별개의 등가류**로 다룬다(상세: `_deviation_class`·`_pick_deviation_representatives`
·`rows_to_samples` 의 docstring). 중복 제거 규칙 자체는 두 클래스에 **하나**다 — **그 세계를
이미 `i=0` 부터 전부 내고 있는 판이 있으면 꼬리 대표를 두지 않고, 없을 때만 하나(arm_id
최솟값)에 꼬리를 남긴다.** 다른 것은 "누가 그 세계를 들고 있느냐" 뿐이다:
  · 클래스 A 의 그 판 = **owner 가 클래스 A 일 때의 owner**.
  · 클래스 B 의 그 판 = **NOOP 팔 판** 또는 **owner 가 클래스 B 일 때의 owner**.
`deviate_valid` 로는 어느 쪽도 못 거른다 — fault·reform 축은 `valid_macros` 가 항상 빈 리스트라
`deviate_valid` 가 사실상 항상 true 다(2026-08-17 2차 리뷰).

★ 2026-08-15 7차 수정 — **deviation 행은 중복이 아니다. 중복 제거는 꼬리에만 한다.**
6차까지는 클래스 A/B 로 판정된 비owner 판을 (대표 하나를 빼고) **판 통째로** 뺐다. 그 배제가
같이 버린 것이 **결정 k 행**이고, 그 행은 그 판이 만드는 관측 중 유일무이한 것이다: 판마다
자기 팔을 k 에서 강제하므로 그 행의 라벨(`d["macro"]`)이 그 팔이고, **같은 칸에서 그 팔을 내는
판은 다른 데 없다.** 보존된 588판 실측:

    판 all_s11_a1  k=8  macro=Replace       deviate_arm=Replace       deviated=True enact_applied=False
    판 all_s11_a2  k=8  macro=Deprioritize  deviate_arm=Deprioritize  deviated=True enact_applied=False
    판 all_s11_a3  k=8  macro=ForbidZone    deviate_arm=ForbidZone    deviated=True enact_applied=False

같은 칸·같은 k 에 **서로 다른 세 팔**이다(전부 클래스 B). 이걸 버리는 것은 중복 제거가 아니라
§1-B(한 칸이 여러 팔을 보게 한다)가 겨냥한 바로 그 관측을 버리는 것이었다 — 실측 귀결이 단일팔
칸 27/49 → 23/48(목표 ≤5)로 사실상 안 움직인 것이다.

진짜 중복은 **꼬리(`decision_index > k`)뿐**이다: 무동작 deviation 뒤에는 결정 k 에서 세계가
안 바뀌었으니 꼬리가 NOOP 팔 판(클래스 B) 또는 canonical(클래스 A)의 궤적을 그대로 되밟는다.

**그래서 규칙을 이렇게 고쳐 적는다 — `deviation 행은 절대 중복이 아니다. 발화한 판은 전부 자기
결정 k 행을 낸다. 중복 제거는 꼬리에만 적용한다.`** 서로 다른 팔 라벨은 서로 **다른 (cell, arm)
버킷**에 들어가므로 팔이 갈린 행끼리는 `_se = std/√n`(`dp_solve.py:88`, `_se()`)을 흔들지 않는다.

⚠️ **그러나 "그러므로 `se` 팽창이 없다" 는 말은 틀렸다 — 아래 §꼬리 중복 잔여를 볼 것.**
같은 팔 라벨을 단 중복 꼬리는 같은 버킷에 쌓이므로 `n` 을 부풀리고 `se` 를 줄인다.

§꼬리 중복 잔여 — 이 dedup 은 새는다 (2026-08-17 최종 리뷰, **고치지 않고 이름 붙인다**)
====================================================================================
dedup 의 술어는 `enact_applied` 인데(`_deviation_class` 의 클래스 B), §5-E 가 적어 둔 대로
그 플래그는 **"효과 지점에 도달했다"** 이지 **"세계가 바뀌었다"** 가 아니다. 분기를 타고도
아무것도 안 바꾼 판(`ForbidZone`/`RelocateBuild` 의 `already_clear`, `ReformTeam` 의
`:error`+`:no_wedge`)은 `"real"` 로 분류돼 **꼬리를 전부 낸다.**

이번 세대 실측(`_sample_work/` 587판 + `samples.jsonl` 2258행, 재현 스크립트는 결과 문서 §5-G):

  · `"real"` 로 분류된 판 **170**개 중 **107**개가 같은 (case,seed) 의 다른 발화 판과
    **바이트 동일한 꼬리**를 낸다(deviation 전용 필드 제외 후 결정 열 비교).
  · 꼬리 행 1521개 중, 같은 (case,seed) 안에서 `(cell, arm, c, next_cell, terminal_value)` 가
    다른 판의 행과 **똑같은** 행이 **601행**(= 중복군 370개의 여분 사본 합). 중복을 만드는
    팔 조합은 `(0,2)·(0,2,4)·(0,4)·(3,7)` — §5-E 가 "도달했지만 안 바꿨다" 로 지목한 바로 그
    분기들이다.
  · **현행 표에 대한 영향은 0칸이다.** 중복 꼬리를 합쳐서 `solve_backward_hierarchical` 을
    다시 풀면 66칸 전부에서 `a_star`·`unresolved_reason` 이 그대로다(확정 19칸 유지). 그래서
    **재표집은 필요 없다** — 술어를 넓히는 것은 표집 의미를 바꾸는 변경이라 별도 결정 사항이다.

즉 남은 잔여는 **`n` 과 `se` 의 과신**이지 `a_star` 의 오류가 아니다. 그리고 여러 팔이 그
자리에서 실제로 무동작이라 값이 같다면 그건 제조된 동점이 아니라 **진짜 동점**이고, 그대로
기록하는 것이 정직한 결과다 — 다만 현행 표의 동점 대다수는 그것이 아니라 `n=1` 자동 동점이다
(결과 문서 §3-D).

2026-08-15 부터 `run_demo.jl` 이 **결정마다 (sim_t, 누적 energy, closed)** 를
남기므로, 연속한 두 결정 사이의 구간 비용 `c_k` 와 다음 칸 `s̃′` 가 실제로 만들어진다. 그래서
이 표집기가 내는 것은 판 단위 J 하나가 아니라 **전이 목록**이고, `dp_solve.py` 는 그 위에서
진짜 Bellman backward induction 을 푼다.

    c_k = Δmakespan_k + w_E · Δenergy_k        (완주 분기 형태로 **고정**)
    V(goal) = 0,   V(dead_end) = J − c_prefix − Σ_k c_k        (종단에서 차액을 정산)

**왜 러닝 코스트를 완주 분기로 고정하는가.** `objective.J` 의 두 분기는 러닝 코스트가 다르다 —
완주는 `makespan + w_E·energy`(구간에 정확히 가법적), 미완주는
`C_fail + C_unclosed·unclosed + tie_eps·makespan`(**에너지가 아예 안 들어간다**). 그런데 결정
시점에는 그 판이 완주할지 모른다. 그래서 러닝 코스트는 한 형태로 고정하고, 두 분기의 차액을
**종단값 하나로** 정산한다. 이건 발명이 아니라 정산이고, 발명이 아님을 아래 §충실성 게이트가
기계로 못박는다.

★ `c_prefix` — 계획서(2026-08-15) 대비 유일한 편차이자 필수 정정
==============================================================
항등식 `Σ_k c_k = makespan + w_E·energy` 는 구간이 **판의 시작 (t=0, e=0) 부터** 덮일 때만
참이다. 그런데 결정 k=1..n 이 만드는 구간은 `[t_1, T]` 뿐이고 **`[0, t_1]` — 첫 결정 이전 —
이 빠진다.** 이 구간을 `c_1` 에 접어 넣으면 *결정이 내려지기도 전에 발생한 비용*이 첫 팔에
귀속된다. 그 양은 판마다 다르므로(사건 발화 시각이 case/seed 마다 다르다) 같은 칸에 모인
표본들에 서로 다른 상수가 실려 **Q 에 편향**이 된다 — 즉 배분 규칙을 지어내는 것이 된다.
그래서 접지 않고 **`c_prefix` 라는 판 단위 상수로 이름 붙여 분리**한다.

  · DP 는 `c_prefix` 를 쓰지 않는다. `V(s̃_1)` 은 정의상 **첫 결정부터의 cost-to-go** 이고,
    `c_prefix` 는 어떤 정책도 바꿀 수 없는(첫 결정 이전의) 상수다.
  · 대신 충실성 게이트가 그것을 명시적으로 포함한다:  `c_prefix + Σc_k + terminal == J_row`.
    게이트의 강도는 계획서 원안과 같다 — 빠진 항을 0 으로 두지 않고 **재서 넣기** 때문이다.

§충실성 게이트 — 이 파일에서 가장 중요한 것
==========================================
판마다 두 항등식을 확인한다. 하나라도 어긋나면 그 판을 **버리지 않고 표시해서 세고**, 그런
판이 하나라도 있으면 표집 종료 시 **exit 1** 이다.
    (1) 텔레스코핑:  c_prefix + Σc_k  ==  makespan + w_E·energy
    (2) 정산:        c_prefix + Σc_k + terminal_value  ==  objective.J_row(row)
(1) 은 두 분기 모두에서 비자명하다(구간 원자료가 실제로 종단값과 맞는지 본다). (2) 는 미완주
분기에서는 terminal_value 의 정의상 자명하지만, 완주 분기에서는 `terminal_value = 0` 이라
**J 의 완주식 자체를 검사**한다. 합성 판 단위검사는 `test_cost_decomposition.py`.

요청 칸이 아니라 **착지 칸**으로 라벨한다 (원 설계 §4.2·§5)
==========================================================

요청 칸이 아니라 **착지 칸**으로 라벨한다 (원 설계 §4.2·§5)
==========================================================
칸을 세우는 ψ 를 새로 짓지 않는다. 기존 case/seed 조합이 자연히 만드는 상태를 굴리고, **주입
후 실제 상태에서 φ̃ 를 다시 계산해** 착지한 칸의 표본으로 센다. 어떤 조합으로도 표본이 안 생기는
칸은 UNREACHABLE 로 남고 값을 지어내지 않는다.

사용법
    ../../.venv/bin/python sample_grid.py --jobs 24 --seeds 1,2,3,4,5,6,7,8,9,10
"""
# ※ 이 파일이 이름으로 인용하는 아래 md 문서는 2026-08-18 md 통합에서 내려갔다 —
#    (md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md)
#    복구 SHA 는 `md/README.md` §9-A.
import argparse
import collections
import json
import math
import os
import shutil
import subprocess
import sys
import threading
import time
import zlib
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.join(HERE, "..")
REPO = os.path.join(WM, "..")
# 2026-08-18 폴더 분류: objective 는 ../core/ 로, llm_ood_eval 은 ../sweep/ 으로 갔다.
# 코드 폴더 전부를 sys.path 에 올려 맨이름 import 를 유지한다(근거는 ../core/wmpath.py).
sys.path.insert(0, os.path.join(WM, "core"))
import wmpath                                                 # noqa: E402,F401
sys.path.insert(0, HERE)

import objective                                              # noqa: E402
from derive_grid import cell_key, state_of, load_grid         # noqa: E402

PY = os.path.join(REPO, ".venv", "bin", "python")
DSPY_URL = os.environ.get("DSPY_URL", "http://127.0.0.1:8090")

CASES = ["battery", "fault", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]

# `pick_k` 의 n_hint 기본값. 제외율(R3)을 결정하는 유일한 손잡이라 리터럴로 여러 곳에 복붙하지
# 않는다 — `run_board`/`main --n-hint`/`test_deviation_plan.py` 가 전부 이 하나를 본다.
DEFAULT_N_HINT = 8

# 팔 메뉴는 `action_registry.json` 에서 온다 — 630판 로그의 `valid` 를 읽으면 FaultTruth/
# ReformTruth 가 빈 리스트라 그 축이 **조용히 0팔**이 된다(원 설계 §3.3).
#
# ---- 2026-08-16: 하드코딩한 5팔을 없앴다 -------------------------------------------------
# 무엇이 잘못이었나. 예전 메뉴는 `want = ("0","1","2","7","8")` = **배포 학습셋의 support 를
# 그대로 베낀 것**이었다. 그런데 그 support 는 "이긴 팔"이 아니라 "굴려서 라벨한 팔"이고
# (`dspy_service.py:229` 가 학습 행의 macro 열에서 유도한다), 재라벨(2026-08-14)이 reform
# 인스턴스를 0건 만들면서 `ReformTeam(4)` 과 `ForbidZone(3)` 이 거기서 빠져 있었다.
#
# 그래서 DP 는 **셋 중 가장 좁은 레인(surrogate)에 메뉴를 맞춘 셈**이 됐고, 그러면 천장이 될 수
# 없다: 2026-08-15 실측에서 실행 레인은 Reform 사건에 `ReformTeam` 을 1182회 집행하는데 DP 는
# 그 팔을 볼 수조차 없어 Reform 축 gap 이 13/13 = 100% 였고, 표집 판 338개가 전부 reform 에서
# 죽었다(V 중앙값 4418.6). 비교가 성립하지 않는 축이었다.
#
# 이제 어휘의 진실원에서 받는다. 실험 팔(5·6)은 `is_active()` 가 DS_COMBO_ARMS 로 건다 —
# 즉 이 함수는 **환경이 정한 활성 집합**을 그대로 따르고, 여기서 다시 좁히지 않는다.
# ---- 실행 레인이 **집행할 수 있는** 이름 (2026-08-16, 2026-08-17 정정) ---------------------
# 이 표집의 한 판에서 갈아 끼우는 그 이름을 실제로 해석하는 것은 `tools/monitor/run_demo.jl` 의
# `handle_ood!` 문자열 디스패치가 **아니다** — 소비처는 `tools/monitor/policy.jl:668` 의
# `FORCE_MACRO` / `DEVIATE_ARM` 디스패치뿐이다(`grep -rn "DEMO_FORCE_MACRO" src tools
# wm4spacecraft_manufacturing` 로 확인, `handle_ood!` 에는 그 분기가 없다). 거기 분기가 없는
# 이름을 주면 if-사슬을 그냥 통과해 **아무 일도 일어나지 않는다** = 그 결정은 canonical 이 고른
# 대로 나가서 갈아치우기가 조용히 무효가 된다. 그건 결정을 재는 게 아니라 동점을 제조하는
# 것이고(ood_mdp_shim `_zone_arms` 가 같은 이유로 arm 3 을 뺐던 그 실패), DP 의 (칸,팔) 표본만
# 얇아진다.
#
# 조합 팔 5·6 이 정확히 이 경우다: 오라클 라벨 레인에는 `combo_to_proposal` 이 있어 실재하지만
# 실행 레인에는 구현이 없다. 그래서 `DS_COMBO_ARMS=1` 이어도 여기서는 뺀다 — 다만 **조용히**
# 빼지 않는다(Global Constraint 10). 아래 arm_menu 가 제외 사실을 이름으로 찍는다.
ENACTABLE_NAMES = {"NOOP", "Replace", "Deprioritize", "ForbidZone",
                   "ReformTeam", "RelocateBuild", "SwapBattery"}


def arm_menu():
    import action_registry as reg
    active = [(i, reg.MACRO_NAME[i]) for i in reg.ACTIVE_MACROS]
    menu = [(i, n) for i, n in active if n in ENACTABLE_NAMES]
    dropped = [(i, n) for i, n in active if n not in ENACTABLE_NAMES]
    if dropped:
        print("[arm_menu] 실행 레인이 집행할 수 없어 제외: %s"
              % ", ".join("%d=%s" % (i, n) for i, n in dropped))
        print("[arm_menu]   (tools/monitor/policy.jl:668 의 FORCE_MACRO/DEVIATE_ARM 디스패치에 그 "
              "이름의 분기가 없다 — 넣으면 canonical 과 바이트 동일한 판이 된다)")
    print("[arm_menu] 팔 %d개: %s" % (len(menu), ", ".join("%d=%s" % t for t in menu)))
    return menu


def _default_id_by_name():
    """`rows_to_samples` 의 `id_by_name` 기본값 — 이름->id. `arm_menu()` 와 같은 필터
    (ENACTABLE_NAMES ∩ 활성 매크로)를 쓰지만 **출력하지 않는다**(판마다 부르면 로그가
    588번 반복된다). `main()` 은 이미 뽑은 `arm_menu()` 결과에서 직접 만들어 넘기므로 이
    경로를 안 탄다 — 이건 그 인자를 안 주는 호출자(단위검사)를 위한 안전망이다."""
    import action_registry as reg
    return {reg.MACRO_NAME[i]: i for i in reg.ACTIVE_MACROS if reg.MACRO_NAME[i] in ENACTABLE_NAMES}


# ---- §8.7 gap 의 원인 문장 — **표본이 스스로 말하게 한다** ---------------------------------
# (2026-08-17 최종 리뷰 Critical 3)
#
# 무엇이 잘못이었나. 이 문장이 `build_compare_table.py` 와 `fill_results_doc.py` 에 **리터럴로**
# 박혀 있었다. 그래서 원인 ①(표집 팔 메뉴에 실행 레인의 ReformTeam 이 없다)이 2026-08-16 에
# 닫히고, 원인 ③(전이 표본이 상수-팔 rollout 에서만 나온다)이 **바로 이 표집기의 이번 세대로
# 제거된** 뒤에도, 헤드라인 아티팩트(`artifacts_4pol/COMPARE.md`·`compare.html`)가 **자기가
# 이미 없앤 전제를 계속 주장했다.** 손으로 적은 해석은 데이터가 바뀌어도 안 바뀐다.
#
# 그래서 문장을 데이터에서 유도한다. 판정 입력은 표본 행의 `sampling_mode` 다 —
# `rows_to_samples` 가 행마다 찍고(`"one_step_deviation"`), 구세대 표본은 `"transition"` 이다.
# 솔버 종류(`value.json` 의 `solver`)와는 **다른 축**이라 둘을 섞지 않는다.
SAMPLING_MODE = "one_step_deviation"          # 이 표집기가 행에 찍는 값(단일 진실원)
SAMPLING_MODE_CONSTANT_ARM = "transition"     # 구세대(판 전체 한 팔) 표본이 찍던 값


def samples_sampling_mode(path=None):
    """`samples.jsonl` 이 어느 표집 세대인가. 반환: 모드 문자열 · `"mixed:<...>"` · `None`.

    세대가 섞여 있으면 **하나를 골라 주지 않는다** — 그 자체가 보고해야 할 사실이다
    (Global Constraint 10). 파일이 없거나 필드가 없으면 None."""
    path = path or os.path.join(HERE, "samples.jsonl")
    modes = set()
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                m = json.loads(line).get("sampling_mode")
                if m:
                    modes.add(m)
    except (OSError, json.JSONDecodeError):
        return None
    if not modes:
        return None
    if len(modes) > 1:
        return "mixed:" + ",".join(sorted(modes))
    return modes.pop()


def gap_cause_note(sampling_mode):
    """§8.7 gap 의 **아직 살아 있는** 원인 목록. 소비처 두 곳이 같은 문장을 쓰게 하는 진실원."""
    if sampling_mode == SAMPLING_MODE:
        return ("남은 원인은 **둘**이다 — ② φ̃ 추상화 손실 · ④ **deviation 칸 밖은 여전히 한 팔만 "
                "본다**(결정 `k` 이전·이후에만 닿는 칸은 canonical 이 고른 팔 하나뿐이라 argmin 이 "
                "없다). 처음 적었던 세 원인 중 ①(표집 팔 메뉴에 실행 레인이 쓰는 매크로가 없다)은 "
                "2026-08-16 에 `arm_menu()` 가 `action_registry.json` 에서 7팔을 받으며 닫혔고, "
                "③(전이 표본이 상수-팔 rollout 에서만 나온다)은 **이 표집 세대**"
                "(`sampling_mode=one_step_deviation`)가 없앴다 — 그 둘을 아직 원인으로 적으면 "
                "이 아티팩트가 자기가 이미 없앤 전제를 주장하는 것이 된다. **원인별로 쪼갠 "
                "수치는 이 세대에 없다** — 그 분해를 내던 리포터는 2026-08-18 정리에서 삭제됐다. "
                "해석은 `md/README.md` §9-A(내린 문서와 복구 SHA).")
    if sampling_mode == SAMPLING_MODE_CONSTANT_ARM:
        return ("2026-08-15 실측에서 셋으로 갈렸다 — ① 표집 팔 메뉴에 실행 레인이 쓰는 매크로가 "
                "없는 축(ReformTeam) · ② φ̃ 추상화 손실 · ③ 전이 표본이 여전히 상수-팔 rollout "
                "에서만 나온다는 구조적 한계. **원인별로 쪼갠 수치는 이 세대에 없다** — 그 분해를 "
                "내던 리포터는 2026-08-18 정리에서 삭제됐다. 해석은 `md/README.md` §9-A.")
    return ("표본의 `sampling_mode` 가 %r 라 원인 목록을 유도할 수 없다 — 원인 구성을 쪼개던 "
            "리포터는 2026-08-18 정리에서 삭제됐고 이 세대에는 그 수치가 없다."
            % (sampling_mode,))


# ---- deviation 위치 배분 -----------------------------------------------------------------
# 판마다 deviation 을 **하나만** 넣는다. 판 수를 늘리지 않기 위해서다(588판 = 현행과 동일 비용).
# 그 대신 위치 k 를 (case, seed) 에서 흩뿌려 깊이를 덮고, **한 (case,seed) 안에서는 모든 팔이
# 같은 k 를 쓴다** — 그래야 일곱 팔이 같은 칸에 착지해서 그 칸에 argmin 이 생긴다(§1-B).
# 즉 깊이 다양성은 seed 축이 만들고, 팔 비교 가능성은 seed 를 고정해서 만든다. 두 목적을
# 같은 축에 얹으면(팔마다 다른 k) 둘 다 잃는다.
#
# 난수를 안 쓴다: 재현이 이 표집의 계약이고(README 함정), 시드 상태를 하나 더 들고 다니면
# 그 자체가 재현 실패의 원인이 된다.
def pick_k(case, seed, arm_id, n_hint):
    """이 판에서 몇 번째 결정을 갈아쓸지. 1-기반. arm_id 는 **일부러 안 쓴다**(위 주석).

    zlib.crc32 를 쓰는 이유: 내장 hash() 는 문자열에 대해 PYTHONHASHSEED 로 프로세스마다
    달라진다. 표집 워커는 별개 프로세스라 그걸 쓰면 판마다 다른 k 가 나와 재현이 깨진다.
    """
    del arm_id
    h = zlib.crc32(("%s|%d" % (case, int(seed))).encode())
    return 1 + (h % max(1, int(n_hint)))


def run_board(case, seed, arm_id, arm_name, outroot, world_seed=1, n_hint=DEFAULT_N_HINT):
    """판 하나를 **k 번째 결정만** 그 팔로 굴린다. 반환: (rows 경로 또는 None, k)."""
    k = pick_k(case, seed, arm_id, n_hint)
    outdir = os.path.join(outroot, "%s_s%d_a%d" % (case, seed, arm_id))
    rows = os.path.join(outdir, "rows.jsonl")
    if os.path.exists(rows) and os.path.getsize(rows) > 0:
        return rows, k                                 # 재개: 이미 끝난 판은 다시 굴리지 않는다
    os.makedirs(outdir, exist_ok=True)
    env = dict(os.environ)
    env.update(
        # ★ DEMO_FORCE_MACRO 를 **쓰지 않는다**. 판 전체 고정이 §1-A 의 83.1% 미완주 원인이었다.
        # 대신 canonical 정책이 판을 굴리다가 k 번째 결정에서만 policy.jl 이 이 팔로 갈아 집행한다.
        DS_DEVIATE_AT=str(k),
        DS_DEVIATE_ARM=arm_name,
        DS_HOTSWAP="1",                                # 실행 레인(run_demo.jl:557)과 같은 세계로
                                                        # 굴린다 — 안 켜면 fault 대상 피커가 죽어
                                                        # 발화율이 100%→23% 로 조용히 샌다(실측)
        DEMO_ALL_POLICIES="0",
        JULIA_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1",
        OMP_NUM_THREADS="1", MKL_NUM_THREADS="1")
    env.pop("DEMO_FORCE_MACRO", None)                  # 부모 환경에 남아 있으면 policy.jl 이 죽는다
                                                        # (FORCE_MACRO + DEVIATE_AT 동시 ON 은 error)
    cmd = [PY, os.path.join(WM, "llm_ood_eval.py"), "run",
           "--case", case, "--seeds", str(seed), "--policies", "canonical",
           "--out", rows, "--dspy-url", DSPY_URL, "--router", "0",
           "--world-seed", str(world_seed)]
    with open(os.path.join(outdir, "board.log"), "w") as lg:
        rc = subprocess.call(cmd, stdout=lg, stderr=subprocess.STDOUT, cwd=WM, env=env)
    if rc != 0 or not os.path.exists(rows) or os.path.getsize(rows) == 0:
        return None, k
    return rows, k


# ---- 판별 매니페스트 (2026-08-17 최종 리뷰 Important 4) -----------------------------------
# 왜 필요한가. 판정 #1(표집 판 완주율 505/587 = 86.0%)은 **판 단위** 지표인데, 그 근거가 오직
# `_sample_work/*/rows.jsonl` 에만 있었고 그 디렉토리는 2.4GB 라 `.gitignore:73` 이 뺀다.
# `samples.jsonl` 로는 복원되지 않는다 — 꼬리 중복 제거 때문에 587판 중 **467판만** 표본에
# 나타나고(82.4%) 팔별 분포도 다르다. 즉 레포를 clone 한 사람은 헤드라인 판정을 **검증할 수
# 없었다.** 그래서 판마다 한 줄짜리 요약을 `samples.jsonl` 옆에 같이 낸다(수백 KB).
#
# 표본을 만들지 않고 매니페스트만 다시 낼 수도 있다: `--manifest-only`. 보존된 판 원자료를
# 다시 읽을 뿐이라 **재시뮬레이션이 아니다.**
MANIFEST_FIELDS = ("board_id", "case", "seed", "arm_id", "arm_name", "complete",
                   "n_decisions", "crashed", "deviate_at", "deviation_fired",
                   "closed", "total", "objective_hash", "energy_objective")


def write_board_manifest(out_path, workroot, jobs, n_hint=DEFAULT_N_HINT):
    """판별 한 줄 매니페스트를 쓴다. 반환: (총 판 수, 완주 판 수).

    `jobs` 가 기대 목록(진실원)이고, 그 밖에 workroot 에 남은 디렉토리는 **조용히 넘기지 않고**
    이름과 수로 찍는다(Global Constraint 10). 판 원자료가 없거나 비어 있으면 `crashed=true` 로
    적는다 — 엔진이 죽은 판을 "완주 안 함" 과 섞지 않기 위해서다."""
    expected, recs = set(), []
    for case, seed, arm_id, arm_name in jobs:
        bid = "%s_s%d_a%d" % (case, seed, arm_id)
        expected.add(bid)
        p = os.path.join(workroot, bid, "rows.jsonl")
        rec = dict.fromkeys(MANIFEST_FIELDS)
        rec.update(board_id=bid, case=case, seed=seed, arm_id=arm_id, arm_name=arm_name,
                   crashed=True, deviate_at=pick_k(case, seed, arm_id, n_hint),
                   deviation_fired=False)
        row = None
        if os.path.exists(p) and os.path.getsize(p) > 0:
            try:
                row = json.loads(open(p).readline())
            except (OSError, json.JSONDecodeError):
                row = None
        if row is not None:
            ds = list(row.get("decisions") or [])
            fired = _fired_decision(ds)
            rec.update(crashed=False, complete=bool(row.get("complete")), n_decisions=len(ds),
                       deviation_fired=fired is not None,
                       closed=row.get("closed"), total=row.get("total"),
                       objective_hash=row.get("objective_hash"),
                       energy_objective=row.get("energy_objective"))
            if fired is not None and fired.get("deviate_at") is not None:
                rec["deviate_at"] = fired["deviate_at"]
        recs.append(rec)

    stray = sorted(d for d in (os.listdir(workroot) if os.path.isdir(workroot) else [])
                   if d not in expected and os.path.isdir(os.path.join(workroot, d)))
    if stray:
        print("[매니페스트] ⚠️ 기대 목록 밖 작업 디렉토리 %d개 — 매니페스트에 넣지 않는다: %s%s"
              % (len(stray), ", ".join(stray[:8]), " …" if len(stray) > 8 else ""))

    with open(out_path, "w") as f:
        for r in recs:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    # 판정 #1 의 분모는 **엔진이 실제로 판을 낸 수**다(크래시 판은 "완주 못 함" 이 아니라
    # "굴러가지도 못함" 이라 별도 사건이다 — §5-B). 두 분모를 다 찍어 오독을 막는다.
    n_crash = sum(1 for r in recs if r["crashed"])
    n_ran = len(recs) - n_crash
    n_ok = sum(1 for r in recs if r["complete"])
    by_arm = collections.defaultdict(lambda: [0, 0])
    for r in recs:
        if r["crashed"]:
            continue
        by_arm[r["arm_name"]][1] += 1
        if r["complete"]:
            by_arm[r["arm_name"]][0] += 1
    print("\n[매니페스트] 계획 %d판 · 엔진이 낸 판 %d · 완주 %d = **%.1f%%**(판정 #1 의 분모) · "
          "크래시 %d  ->  %s"
          % (len(recs), n_ran, n_ok, 100.0 * n_ok / max(n_ran, 1), n_crash, out_path))
    for name, (ok, tot) in sorted(by_arm.items(), key=lambda t: (-t[1][0] / max(t[1][1], 1), t[0])):
        print("[매니페스트]   %-14s %d/%d = %.1f%%" % (name, ok, tot, 100.0 * ok / max(tot, 1)))
    return n_ran, n_ok


def _terminal_energy(row):
    """4pol 레인은 에너지를 **최상위가 아니라 `battery` 하위**에 낸다(objective.J_row 가 두
    스키마를 다 읽는 이유가 이것이다). 최상위만 보면 조용히 None 이 되어 표에서 에너지 열이
    통째로 비는데, 그건 "에너지를 안 썼다" 가 아니라 "잘못된 키를 봤다" 다."""
    e = row.get("energy_J")
    if e is None:
        e = (row.get("battery") or {}).get("total_energy_J")
    return e


def _finite(x):
    try:
        return x is not None and math.isfinite(float(x))
    except (TypeError, ValueError):
        return False


FIDELITY_TOL = 1e-6


def new_report():
    """충실성 게이트의 집계. `boards_bad > 0` 이면 표집이 exit 1 한다.

    `decisions`/`decisions_unstateable` 은 게이트를 통과한 판의 **결정 전부**(owner/R3/
    enact_applied 로 더 좁히기 전)를 센다 — 그래야 이 분모가 `boards`/`boards_bad` 와 같은
    도메인(실행된 모든 판)을 본다(2026-08-17 리뷰 Important 2). 표본으로 좁힌 뒤 세면 비율이
    실제보다 좋아 보이는데 그 사실이 출력에 안 남는다.

    owner/비-owner 는 (case, seed) 마다 rows 를 낸 판 중 arm_id 최솟값을 owner 로 정한
    것(`main()` 이 결정)이다(2026-08-17 리뷰 Critical 1) — owner 만 전 결정을 내고, 나머지
    필드는 owner 가 아닌 판에서 무엇을 얼마나 뺐는지를 센다. 전부 **다른 사건**이라 따로 센다:
      - `boards_no_deviation`/`no_deviation_by_arm` : owner 아닌 판인데 deviation 이 한 번도
        안 걸림(k > 그 판의 결정 수, "미발화") → owner 도 그 k 에서 안 걸렸을 것이므로 owner 가
        이미 canonical 이다. 낼 `k` 행 자체가 없다. **대표 후보에 안 넣는다.**
      ★ **2026-08-15 7차: 아래 클래스 카운터는 판이 아니라 그 판의 꼬리를 센다.** 발화한 판은
        클래스와 무관하게 **전부 자기 결정 k 행을 낸다**(그 행은 중복이 아니다 — 머리말 ★7차).
        갈리는 것은 꼬리(`decision_index > k`)를 냈느냐뿐이다. "판을 배제했다"고 읽히는 이름은
        이제 거짓이라 전부 `..._tail_dropped` 로 바꿨다.
      - **클래스 A**(`deviated == False`, = canonical 과 바이트 동일. 2026-08-17 4차 수정에서
        클래스 B 와 분리했다 — 머리말 참조):
          · `boards_class_a_representative`/`class_a_representative_by_arm` : 그 (case,seed) 의
            클래스 A **꼬리 대표**로 뽑혀 꼬리까지 낸 판(비owner 규칙 그대로 `i >= k`).
          · `boards_class_a_tail_dropped`/`class_a_tail_dropped_by_arm` : 꼬리 대표가 아니라서
            **꼬리만** 뺀 클래스 A 판(결정 k 행은 냈다). 그 꼬리는 대표(또는 owner)의 꼬리와
            바이트 동일한 중복이다. (owner 자신이 클래스 A 면 꼬리 대표를 **아예 안 뽑으므로**
            그 (case,seed) 의 클래스 A 판은 전부 여기로 온다 — owner 가 canonical 을 `i=0` 부터
            이미 전부 내고 있다.)
      - **클래스 B**(`enact_applied == False` 이고 `deviated != False`, = 꼬리가 **NOOP 팔 판과**
        바이트 동일하지 canonical 과는 아니다):
          · `boards_class_b_representative`/`class_b_representative_by_arm` : 그 세계를 들고 있는
            판(NOOP 팔 판 · owner 가 클래스 B 면 owner)이 **둘 다 없을 때만** 뽑히는 꼬리 대표.
          · `boards_class_b_tail_dropped`/`class_b_tail_dropped_by_arm` : 그 세계를 이미 들고 있는
            판(NOOP 팔 판 또는 클래스 B 인 owner)이 있어서 **꼬리만** 뺀 판(결정 k 행은 냈다).
      - `deviation_rows_kept_from_suppressed`/`deviation_rows_kept_by_arm` : 위 두
        `..._tail_dropped` 판에서 **실제로 살아남은 결정 k 행**의 수(팔 이름별). 6차까지는 이
        행들이 통째로 사라졌다 — 이 카운터가 "꼬리만 뺐지 판을 뺀 게 아니다"를 로그에서 직접
        보이는 자리다. 칸으로 라벨할 수 없거나(`cells[i] is None`) 집행 이름이 `arm_menu` 밖이면
        그 행은 여전히 안 나가므로, 이 수는 `boards_*_tail_dropped` 합보다 작을 수 있다.
      - `decisions_dropped_tail_dup` : 위 판들에서 중복이라 뺀 **꼬리 결정** 수(판이 아니라 결정
        단위). `decisions_dropped_prefix_dup`(비owner 의 `< k` prefix)과는 다른 사건이다.
        ⚠️ **`deviate_valid` 로는 어느 클래스도 못 거른다** — `deviate_valid` 는 `isempty(valid_macros)
        || dev in valid_macros`(policy.jl:413·:556 규약: 빈 메뉴 = 제한 없음)라서, `valid_macros`
        가 FaultTruth·ReformTruth 에 **항상 빈 리스트**를 주는 한 그 두 축에서 `deviate_valid` 는
        사실상 항상 `true` 다. 그걸로 배제하면 fault·reform 축이 통째로 빈 격자가 된다(1차
        구현의 버그, 실측으로 잡혔다).
      - `boards_deviate_valid_false`/`deviate_valid_false_by_arm` : 배제에는 안 쓴다(정보성) —
        `deviate_valid == False` 인 판(메뉴가 실재하는데 그 밖, 주로 zone 사건)을 그냥 세어
        둔다. `valid=True, applied=False` 로 갈리는 판이 §1-B 가 묻는 정확한 사건이라, 두 신호가
        어긋나는 빈도를 로그로 답할 수 있어야 한다.
      - `enact_applied_missing` : `enact_applied` 키 자체가 없는 구세대 run_demo.jl 산출물(모르는
        것을 아는 척 배제하지 않고 통과시킨 판의 수) — Task 1 완료 후엔 0 이어야 정상.
      - `decisions_dropped_prefix_dup` : owner 아닌 판에서 `decision_index < k` 라 owner 의
        prefix 와 중복이라 뺀 **결정** 수(판이 아니라 결정 단위로 센다).
      - `dropped_unknown_macro` : 그 결정에서 실제로 집행된 매크로(`d["macro"]`)가 `id_by_name`
        (= arm_menu() 밖)에 없어 **그 행만** 버린 것 — 판 전체를 버리지 않는다(GC10).
      - `owner_boards`/`non_owner_transitions` : owner 판 수 · owner 아닌 판에서 낸 전이 수.
    게이트 자체의 판정 대상(`boards`/`boards_bad`)은 위 어떤 제외와도 무관하게 실행된 판 전체를
    계속 본다."""
    return {"boards": 0, "boards_bad": 0, "decisions": 0, "decisions_unstateable": 0,
            "by_reason": collections.Counter(), "examples": [], "max_resid": 0.0,
            "boards_no_deviation": 0, "no_deviation_by_arm": collections.Counter(),
            "boards_class_a_representative": 0,
            "class_a_representative_by_arm": collections.Counter(),
            "boards_class_a_tail_dropped": 0,
            "class_a_tail_dropped_by_arm": collections.Counter(),
            "boards_class_b_representative": 0,
            "class_b_representative_by_arm": collections.Counter(),
            "boards_class_b_tail_dropped": 0,
            "class_b_tail_dropped_by_arm": collections.Counter(),
            "deviation_rows_kept_from_suppressed": 0,
            "deviation_rows_kept_by_arm": collections.Counter(),
            "boards_deviate_valid_false": 0,
            "deviate_valid_false_by_arm": collections.Counter(),
            "enact_applied_missing": 0, "owner_boards": 0, "non_owner_transitions": 0,
            "decisions_dropped_prefix_dup": 0, "decisions_dropped_tail_dup": 0,
            "dropped_unknown_macro": collections.Counter()}


def decompose_board(row, w_E=None, cfg=None):
    """판 하나 -> 구간 분해. **순수 함수 — 시뮬을 부르지 않는다.**

    반환 dict:
        ok             : 두 항등식이 모두 성립했나 (충실성 게이트가 세는 값)
        reason         : ok 가 아닐 때 **이름**. 조용히 버리지 않는다.
        c_prefix       : [0, t_1] 구간 비용. DP 는 쓰지 않는다(위 ★ 절).
        cs             : [c_1 .. c_n]. c_k 는 결정 k 에서 k+1(마지막은 종단)까지.
        terminal       : "goal" | "dead_end"
        terminal_value : 완주 0.0 / 미완주 J − c_prefix − Σc. J 채점 불가면 None.
        J, sum_c, resid_telescope, resid_settle, n_decisions

    `cs[k]` 는 `decisions[k]` 의 팔이 집행된 뒤 다음 결정까지 실제로 든 비용이다. 러닝
    코스트는 **완주 분기 형태로 고정**한다 — 결정 시점에는 그 판이 완주할지 모르기 때문이다.
    """
    cfg = cfg if cfg is not None else objective.load()
    if w_E is None:
        w_E = objective.energy_weight(cfg)

    ds = list(row.get("decisions") or [])
    n = len(ds)

    # 종단값. makespan 은 4pol/MC 두 레인의 키 이름이 달라 J_row 와 같은 폴백을 쓴다.
    T = row.get("makespan")
    if T is None:
        T = row.get("sim_seconds")
    E_T = _terminal_energy(row)

    try:
        J = objective.J_row(row)
        j_reason = None
    except objective.ObjectiveError as e:
        # 채점 불가 판은 **버리지 않고 이름으로 남긴다.** 조용히 빼면 표가 낙관 편향된다.
        J, j_reason = None, "J_unscorable: " + str(e)[:120]

    base = {"c_prefix": None, "cs": [], "J": J, "sum_c": None,
            "resid_telescope": None, "resid_settle": None, "n_decisions": n,
            "terminal": ("goal" if row.get("complete") else "dead_end"),
            "terminal_value": None, "w_E": w_E, "makespan": T, "energy_J": E_T}

    if not (_finite(T) and _finite(E_T)):
        # 구간 원자료가 없으면 분해가 성립하지 않는다. 값을 지어내지 않는다.
        return dict(base, ok=False, reason="terminal_missing: makespan=%r energy_J=%r" % (T, E_T))
    T, E_T = float(T), float(E_T)

    for i, d in enumerate(ds):
        if not (_finite(d.get("sim_t_at")) and _finite(d.get("energy_at_J"))):
            return dict(base, ok=False,
                        reason="decision_%d_missing: sim_t_at=%r energy_at_J=%r"
                               % (i, d.get("sim_t_at"), d.get("energy_at_J")))

    ts = [float(d["sim_t_at"]) for d in ds]
    es = [float(d["energy_at_J"]) for d in ds]

    # 결정 목록은 `_DECISIONS` 에 시간순으로 append 된 것이라 이미 정렬돼 있다. 그래도 확인한다 —
    # 어긋나면 정렬해서 덮는 대신 **이름으로 멈춘다**(순서가 틀렸다면 그건 계측의 결함이다).
    for i in range(1, n):
        if ts[i] < ts[i - 1] - FIDELITY_TOL:
            return dict(base, ok=False,
                        reason="sim_t_not_monotone at %d: %r < %r" % (i, ts[i], ts[i - 1]))
    if n and ts[-1] > T + FIDELITY_TOL:
        return dict(base, ok=False,
                    reason="last_decision_after_terminal: %r > makespan %r" % (ts[-1], T))

    # 판의 시작은 (t=0, e=0) 이다. c_prefix 가 그 구간을 덮고, 나머지를 c_k 가 덮는다.
    c_prefix = (ts[0] - 0.0) + w_E * (es[0] - 0.0) if n else (T + w_E * E_T)
    cs = []
    for i in range(n):
        t1, e1 = (ts[i + 1], es[i + 1]) if i + 1 < n else (T, E_T)
        cs.append((t1 - ts[i]) + w_E * (e1 - es[i]))
    sum_c = sum(cs)

    # (1) 텔레스코핑 항등식 — 러닝코스트의 합이 **objective 가 말하는 완주 분기 값**과 같은가.
    #
    # ⚠️ 기준값을 `T + w_E*E_T` 로 직접 쓰면 안 된다. 그러면 양변이 같은 w_E 를 쓰므로 잔차가
    # w_E 와 무관하게 **언제나 정확히 0** 이 되어, 이 검사가 아무것도 막지 못한다. 미완주
    # 분기에서는 terminal_value 가 정의상 차액을 흡수하므로 (2) 도 자명해지고, 결국 그 분기
    # 전체가 무검사로 남는다. (단위검사 T-06d 가 이 결함을 잡았다.)
    #
    # 그래서 기준값은 **objective.J 의 완주 분기를 직접 불러서** 받는다 — 계획서가 말하는
    # "러닝 코스트를 완주 분기로 고정한다" 가 문자 그대로 이 한 줄이다. 공식을 복제하지 않으므로
    # J 에 항이 추가되면 여기서 즉시 잔차가 벌어진다(audit_objective.py 항목 1 의 취지와 같다).
    # closed/total 은 objective.J 의 **완주 분기가 쓰지 않는** 인자라 결측이어도 기준값이
    # 흔들리지 않는다(미완주 분기에서만 쓰인다). 그래도 시그니처가 요구하므로 0 으로 채운다.
    running_ref = objective.J(complete=True, closed=int(row.get("closed") or 0),
                              total=int(row.get("total") or row.get("total_nodes") or 0),
                              makespan=T, energy_J=E_T, cfg=cfg)
    resid_tel = c_prefix + sum_c - running_ref

    terminal = "goal" if row.get("complete") else "dead_end"
    if J is None:
        return dict(base, ok=False, reason=j_reason, c_prefix=c_prefix, cs=cs,
                    sum_c=sum_c, resid_telescope=resid_tel, terminal=terminal)
    # 종단 정산. 완주는 0(그래서 (2)가 J 의 완주식 자체를 검사한다), 미완주는 차액.
    tv = 0.0 if row.get("complete") else (J - c_prefix - sum_c)
    resid_set = c_prefix + sum_c + tv - J

    ok = abs(resid_tel) < FIDELITY_TOL and abs(resid_set) < FIDELITY_TOL
    return dict(base, ok=ok,
                reason=(None if ok else
                        "fidelity_violation: telescope=%.3e settle=%.3e" % (resid_tel, resid_set)),
                c_prefix=c_prefix, cs=cs, sum_c=sum_c, terminal=terminal,
                terminal_value=tv, resid_telescope=resid_tel, resid_settle=resid_set)


# ---- 두 등가류(클래스 A/B)의 **꼬리** 대표 선정 (2026-08-17 4차 · 2026-08-15 7차 수정) ------
# ★ 이 절이 정하는 것은 **꼬리(`decision_index > k`)를 누가 내느냐** 뿐이다. 결정 k 행은 어떤
# 선정 결과와도 무관하게 **발화한 판이 전부 낸다** — 그 행은 그 판이 k 에서 강제한 팔로
# 라벨되므로 어느 판과도 중복이 아니다(머리말 ★7차 수정, 실측 세 판 인용).
#
# 라벨이 판이 아니라 결정을 따르게 된 뒤(Critical 1), owner 가 아닌 판들의 `i > k` 꼬리가
# **서로 바이트 동일**하면 그 행들은 같은 (cell,arm) 버킷에 정보 0 인 중복으로 쌓인다 —
# dp_solve._decide 의 `se = std/√n` 을 정보 없이 낮춰 tie 를 가짜 a* 로 뒤집는다(§1-B 재발).
# 그래서 "꼬리가 서로 바이트 동일한 판" 마다 꼬리 대표 하나만 남긴다. 문제는 **무엇과 동일한가**
# 이고, 3차까지 그것을 하나로 합쳐 뒀던 것이 4차에서 고친 결함이다(머리말 ★4차 수정 참조):
#
#   · 클래스 A (`deviated is False`) — 강제한 팔이 canonical 이 이미 고르려던 것과 같았다.
#     이 판의 꼬리는 **canonical 과** 바이트 동일하다.
#   · 클래스 B (`enact_applied is False`) — 집행 사슬이 어떤 분기도 안 탔다. 결정 k 에서 세계가
#     안 바뀌었으므로 이 판의 꼬리는 **NOOP 팔 판과** 바이트 동일하다. canonical 과는 다르다
#     (canonical 이었다면 자기 매크로의 분기를 실제로 탔을 것이다).
#
# 꼬리 대표 규칙은 두 클래스에 **하나**다: **그 세계를 이미 `i=0` 부터 전부 내고 있는 판이
# 있으면 꼬리 대표를 두지 않는다**(있으면 대표 꼬리는 그 판 꼬리의 정확한 복제일 뿐이다).
# 없을 때만 하나(arm_id 최솟값)에 꼬리를 남긴다 — 안 그러면 그 세계가 통째로 안 잡힌다.
# 클래스마다 다른 것은 "누가 그 세계를 들고 있느냐" 뿐이다:
#   · A 의 그 판 = **owner 가 클래스 A 일 때의 owner**(owner 는 항상 전 결정을 낸다). 반대로
#     owner 가 실제로 deviate 했으면 owner 의 `i >= k` 는 canonical 이 아니므로 클래스 A 판이
#     canonical 연속의 유일한 운반자다 — 그때 하나를 남긴다.
#   · B 의 그 판 = **NOOP 팔 판**(= arm_menu() 에서 이름이 "NOOP" 인 팔. 숫자를 하드코딩하지
#     않는다) **또는 owner 가 클래스 B 일 때의 owner**. 둘 다 없을 때만 하나를 남긴다.
#     (2026-08-17 5차: owner 쪽 대칭 예외가 빠져 있어, NOOP 판이 크래시하고 owner 가 클래스 B 인
#     (case,seed) 에서 대표 하나가 owner 꼬리의 복제로 남았다 — A 쪽에서 이미 막은 것과 같은 결함.)
#
# 미발화 판(발화한 결정이 아예 없음, k > 결정 수)은 낼 **결정 k 행 자체가 없고**(그래서 ★7차의
# "발화한 판은 전부 k 행을 낸다"에 걸리지 않는다) 어느 클래스도 아니라 대표 후보가 **아니다**
# — 그 경우 owner 도 같은 k 에서 안 걸렸으므로 owner 자체가 이미 canonical 이다.
def _fired_decision(ds):
    """이 판의 decisions 리스트에서 deviation 게이트가 걸린 결정 하나(있으면)를 돌려준다.
    없으면 None. `rows_to_samples` 의 owner/R3/클래스 분기와 대표 선정(`_board_deviation_status`)
    이 같은 정의를 쓰게 하는 단일 진실원이다 — 둘이 따로 판정 로직을 가지면 드리프트가 생긴다."""
    fired = [d for d in ds if d.get("deviate_at") is not None]
    return fired[0] if fired else None


def _deviation_class(fired_d):
    """발화한 결정 하나가 **어느 등가류**인가. `"A"` | `"B"` | `None`(실제로 갈린 판).

    `"A"` = `deviated is False` — 강제한 팔이 canonical 이 그 결정에서 이미 고르려던 것과
    같았다(policy.jl:1031 `rt["deviated"] = (dev != chosen)`). 이 판은 **canonical 과** 바이트
    동일하다.

    `"B"` = `enact_applied is False` — run_demo.jl 의 집행 사슬(:352-457)이 그 이름에 대해
    **어떤 분기도 안 탔다.** 결정 k 에서 세계가 안 바뀌었으므로 이 판은 **NOOP 팔 판과** 바이트
    동일하다 — canonical 과는 **다르다**(canonical 이었다면 자기 매크로의 분기를 탔을 것이므로,
    canonical 의 매크로가 NOOP 이 아닌 한 여기서 갈라진다).

    **A 가 우선한다**(둘 다 False 인 판은 A). `deviated is False` 면 강제 대입 자체가 무변경이라
    "집행 사슬이 뭘 했는가" 와 무관하게 그 판은 canonical 이기 때문이다 — 그리고 그 경우 B 로도
    한 번 더 세면 같은 판이 두 등가류에 들어가 중복 집계가 된다.

    `enact_applied` 키가 아예 없고 `deviated` 도 False 가 아니면 `None` 을 돌려준다 — 모르는
    것을 아는 척 배제하지 않는다(호출자가 `enact_applied_missing` 으로 센다)."""
    if fired_d.get("deviated") is False:
        return "A"
    if fired_d.get("enact_applied") is False:
        return "B"
    return None


def _board_deviation_status(rows_path):
    """판 하나의 deviation 상태를 §충실성 게이트 없이 가볍게 스캔한다. 반환:
    `"no_fire"`(발화 없음) | `"A"` | `"B"`(위 `_deviation_class`) | `"real"`(발화했고 실제로 갈림).

    `main()` 이 (case,seed) 마다 대표를 정하려면 **그 조합의 판 전부를 먼저 훑어야** 한다 —
    `rows_to_samples` 는 그 판 자체를 이미 처리하는 시점에야 이걸 알아서 대표 선정에 못 쓴다
    (owner 가 클래스 A 인지, NOOP 판이 살아 있는지도 그 시점엔 알 수 없다).
    `decompose_board` 의 산수(J·c_prefix 등)는 안 돈다 — 대표 후보 여부는 그 판의 비용 분해가
    맞는지와 무관하고, 여기서 그것까지 하면 판을 두 번 여는 비용만 는다. 파일이 없거나 비어
    있으면(엔진 실패 등) `"no_fire"` 로 본다 — 대표 후보에서 안전하게 빠진다."""
    try:
        for line in open(rows_path):
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            fired_d = _fired_decision(list(r.get("decisions") or []))
            if fired_d is None:
                return "no_fire"
            return _deviation_class(fired_d) or "real"
    except (OSError, json.JSONDecodeError):
        pass
    return "no_fire"


def rows_to_samples(rows_path, case, seed, arm_id, arm_name, axes, k=None, is_owner=True,
                     is_class_representative=False, id_by_name=None, report=None):
    """판 하나 -> **전이 표본**.

    ★ 2026-08-17 리뷰 Critical 1. 각 전이는 **그 결정에서 실제로 집행된 매크로**
    (`d["macro"]`)로 라벨한다 — 판의 deviation 목표 팔(`arm_id`/`arm_name`)이 아니다.
    엔진은 그 팔을 결정 k 딱 하나에서만 집행하므로, 판 전체를 그 팔로 라벨하면
    `decision_index < k`(canonical 이 이미 정한 대로 나간 결정)를 그 팔에 가짜로 귀속시키고
    (R3 가 판 단위로 죽이려던 동점이 결정 단위로 되살아난다), `decision_index > k` 도 갈라진
    궤적 위의 canonical 행동을 그 팔로 잘못 귀속시킨다(혼입, argmin 편향).

    그래서 (case, seed) 마다 **owner 판**(그 조합에서 rows 를 낸 판 중 arm_id 최솟값 —
    `main()` 이 정해서 `is_owner` 로 넘긴다) 만 결정 전부를 낸다. owner 가 아닌 판은:
      - `decision_index < k` 인 결정은 owner 의 canonical prefix 와 바이트 동일한 중복이라
        뺀다(`decisions_dropped_prefix_dup`).
      - deviation 이 한 번도 안 걸렸으면(어떤 결정도 `deviate_at` 이 non-null 이 아님, k > 그
        판의 결정 수, "미발화") 판 전체가 owner 와 겹치므로 **아무것도 안 낸다**(R3,
        `boards_no_deviation`) — owner 도 같은 k 에서 안 걸렸을 것이므로 owner 가 이미
        canonical 이고, 대표가 따로 필요 없다.
      - 걸렸는데 **클래스 A 또는 B**(`_deviation_class`, 아래 §등가류 절)면, `main()` 이 넘긴
        `is_class_representative`(= 그 (case,seed) 에서 **자기 클래스의 꼬리 대표**로 뽑혔는가)를
        본다. ★ **어느 쪽이든 결정 k 행은 낸다**(2026-08-15 7차) — 갈리는 것은 꼬리뿐이다:
          - **True** — 비owner 규칙 그대로(`i >= k`) 꼬리까지 낸다
            (`boards_class_a_representative` / `boards_class_b_representative`).
          - **False** — 꼬리(`i > k`)는 대표(A) 또는 NOOP 팔 판(B)의 꼬리와 바이트 동일한
            중복이라 뺀다. **결정 k 행 하나만 낸다**
            (`boards_class_a_tail_dropped` / `boards_class_b_tail_dropped` +
            `deviation_rows_kept_from_suppressed` · `decisions_dropped_tail_dup`).
        `enact_applied` 키가 아예 없고 `deviated` 도 False 가 아니면(Task 1 미완료 구세대
        산출물) 어느 클래스도 아니라 배제하지 않고 통과시키되 `enact_applied_missing` 으로
        센다(모르는 것을 아는 척 배제하지 않는다).

        ⚠️ **`deviate_valid` 로는 클래스를 안 가른다(2026-08-17 2차 리뷰로 정정).** 처음엔
        `deviate_valid`(그 팔이 `valid_macros(env, truth)` 안에 있는가)로 걸렀는데, 실측으로
        드러난 문제: `valid_macros` 는 `BatteryTruth`·`ZoneTruth` 에만 실제 리스트를 주고
        `FaultTruth`·`ReformTruth` 에는 **항상 빈 리스트**를 준다. `policy.jl` 의 규약(`:413`·
        `:556`)은 "빈 메뉴 = 제한 없음" 이라 `deviate_valid = isempty(vm) || dev in vm` 이고,
        그러면 fault·reform 축에서 `deviate_valid` 는 **사실상 항상 true** 다 — 그걸로는 아무것도
        못 거르고, 배제 로직이 살아있는 것처럼 보이지만 그 두 축에서는 절대 발화하지 않는다.
        `deviate_valid` 는 지우지 않는다 — 진단 키로 그대로 남기고(아래), 클래스 판정과는 별개로
        `deviate_valid == False` 인 판(메뉴가 실재하는데 그 밖, 주로 zone 사건) 자체의 빈도를
        `boards_deviate_valid_false` 로 정보성으로 센다 — 두 신호(메뉴 멤버십·실제 집행)가
        어긋나는 사건(`valid=True, applied=False`, §1-B 가 묻는 것)을 로그만으로 답할 수 있어야
        한다.

    § 등가류 A/B (2026-08-17 4차 수정) — **중복 제거는 꼬리에만 적용한다(2026-08-15 7차).**
    ★ **지배 문장: deviation 행은 절대 중복이 아니다 — 발화한 판은 전부 자기 결정 k 행을 낸다.
    중복 제거되는 것은 꼬리(`decision_index > k`)뿐이다.** 판마다 자기 팔을 k 에서 강제하므로
    그 행의 라벨(`d["macro"]`)이 그 팔이고, 같은 칸에서 그 팔을 내는 판이 다른 데 없다 —
    보존된 588판에서 같은 칸·같은 k 에 클래스 B 판 셋이 `Replace`/`Deprioritize`/`ForbidZone`
    **서로 다른 세 라벨**로 앉아 있었다(머리말 ★7차 인용). 6차까지 이 판들을 통째로 뺀 것이
    §1-B(한 칸이 여러 팔을 보게 한다)가 겨냥한 관측을 그대로 버리고 있었다.
    서로 다른 팔 라벨은 서로 **다른 (cell, arm) 버킷**에 들어가므로 `_se = std/√n` 논증은 이
    행들에 걸리지 않고, 여러 팔이 그 자리에서 실제로 무동작이라 값이 같다면 그건 **진짜 동점**
    이다(제조된 동점이 아니다).

    **라벨이 실제 집행 매크로가 된 뒤로는**(위 Critical 1) 서로 바이트 동일한 판들의 `i > k`
    **꼬리**가 **같은 (cell,arm) 버킷에 정보 0 인 중복으로 쌓인다** — `dp_solve._decide` 의
    `se = std/√n` 을 인위적으로 낮춰 tie 를 가짜 a* 로 뒤집는다(§1-B 재발). 그래서 **꼬리** 대표를
    하나만 남기는데, 규칙은 두 클래스에 **하나**다 — **그 세계를 이미 `i=0` 부터 전부 내고 있는
    판이 있으면 꼬리 대표를 두지 않는다**(그러면 대표 꼬리는 그 판 꼬리의 정확한 복제다).
    클래스마다 다른 것은 **무엇과 동일한가 = 누가 그 세계를 들고 있느냐** 뿐이다:

      · **클래스 A**(`deviated is False`) = 꼬리가 **canonical 과** 바이트 동일. 그 세계를 들고
        있는 판은 **owner 가 클래스 A 일 때의 owner** 다 — 그러면 꼬리 대표 **0개**. 반대로
        owner 자신이 실제로 deviate 했다면 canonical 연속을 들고 있는 건 클래스 A 판들뿐이라
        하나(arm_id 최솟값)에 꼬리를 남긴다. (한 (case,seed) 에 클래스 A 판은 최대 하나다 —
        판마다 강제하는 팔이 다르고 `deviated is False` 는 그 팔이 canonical 의 **유일한** 선택과
        같았다는 뜻이므로.)
      · **클래스 B**(`enact_applied is False`, A 가 아닐 때) = 꼬리가 **NOOP 팔 판과** 바이트
        동일. canonical 과는 다르다 — canonical 이었다면 자기 매크로의 집행 분기(hot-swap·
        rebalance·restage·reform)를 탔을 것이다. 그 세계를 들고 있는 판은 **NOOP 팔 판** 또는
        **owner 가 클래스 B 일 때의 owner** 이고, 둘 다 없을 때만 하나에 꼬리를 남긴다.

    3차까지는 이 둘을 "무집행" 하나로 묶어 통째로 `min()` 을 취했다 — 클래스 B 의 팔 id 가 대체로
    더 작아서 **owner 와 중복인 판을 대표로 남기고 유일한 canonical 판을 버렸다**(zone 축·reform
    축에서 사실상 상시 발생). 실측 반증은 머리말 ★4차 수정 절에 있다.
    꼬리 대표 선정 자체는 `main()` 이 `_pick_deviation_representatives` 로 (owner 선정과 같은
    결정론: 풀 전체에서 `min()`) 하고, 이 함수는 그 결과를 `is_class_representative` 로 받기만
    한다.

    `id_by_name` 은 실제 집행 매크로 이름 -> id 사전(`main()` 이 `arm_menu()` 결과로 만든다,
    기본값은 `_default_id_by_name()`). 거기 없는 이름이 나온 결정은 **그 행만** 버리고
    `dropped_unknown_macro` 로 센다(Global Constraint 10 — 판 전체를 버리지 않는다).

    `k` 는 `run_board` 가 이 판에 준 deviation 목표 인덱스(`pick_k` 의 반환값) — 각 전이 행에
    `board_deviate_at` 으로 그대로 찍힌다(진단용, `dp_solve.py` 는 이 키를 안 읽는다).

    `report` 는 `new_report()` 가 만든 충실성+제외 집계."""
    if id_by_name is None:
        id_by_name = _default_id_by_name()
    out = []
    rep = report if report is not None else new_report()
    for line in open(rows_path):
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        board_id = "%s_s%d_a%d" % (case, seed, arm_id)
        dec = decompose_board(r)
        rep["boards"] += 1
        if not dec["ok"]:
            rep["boards_bad"] += 1
            rep["by_reason"][str(dec["reason"]).split(":")[0]] += 1
            if len(rep["examples"]) < 20:
                rep["examples"].append((board_id, dec["reason"]))
            # 분해가 성립하지 않은 판에서는 전이를 만들지 않는다. **버리는 것이 아니라**
            # 위 카운터에 이름으로 남고, main() 이 그 수를 세어 exit 1 한다.
            continue
        rep["max_resid"] = max(rep["max_resid"],
                               abs(dec["resid_telescope"]), abs(dec["resid_settle"]))

        ds = list(r.get("decisions") or [])

        # 칸으로 라벨할 수 없는 결정은 그 자리에 None 으로 남긴다 — 앞 전이의 next_cell 이
        # 조용히 "그 다음 결정" 으로 건너뛰면 전이 그래프가 실제와 달라진다.
        #
        # Important 2(2026-08-17 리뷰): 이 카운트는 owner/R3/enact_applied 로 더 좁히기 **전**에
        # 한다 — `decisions`/`decisions_unstateable` 이 `boards`/`boards_bad` 와 같은 도메인
        # (게이트를 통과한 판 전체)을 보게 하기 위해서다.
        cells = []
        for d in ds:
            st = state_of(d, axes)
            cells.append(cell_key(st) if st is not None else None)
        rep["decisions"] += len(ds)
        rep["decisions_unstateable"] += sum(1 for c in cells if c is None)

        # ---- owner/R3/클래스 대표: 어느 결정 범위를 낼지 결정한다 (Critical 1 + 4·7차 수정) --
        # `drop_tail` = 이 판의 꼬리(`decision_index > k`)가 다른 판 꼬리의 복제라서 뺀다.
        # 결정 k 행 자체는 **어떤 경우에도 안 뺀다**(2026-08-15 7차, 위 §등가류 지배 문장).
        drop_tail = False
        if is_owner:
            rep["owner_boards"] += 1
            start_i = 0                       # owner 는 항상 전 결정을 낸다
        else:
            if k is None:
                raise ValueError("rows_to_samples: is_owner=False 인데 k 가 없다 — "
                                  "non-owner 필터는 k(deviation 목표 인덱스)를 요구한다")
            fired_d = _fired_decision(ds)
            if fired_d is None:
                # R3(미발화): 이 판에서 deviation 이 한 번도 안 걸렸다(k > 결정 수) — owner 도
                # 같은 k 에서 안 걸렸을 것이므로 owner 가 이미 canonical 이다. 대표 후보가 아니다
                # (main() 이 대표 풀에 안 넣는다). 조용히 버리지 않는다: 팔 이름별로 센다.
                rep["boards_no_deviation"] += 1
                rep["no_deviation_by_arm"][arm_name] += 1
                continue
            # 정보성 카운터: deviate_valid == False 자체의 빈도(클래스 판정에는 안 쓴다). 두
            # 신호가 어긋나는 사건(메뉴엔 있는데 집행 사슬이 no-op)이 몇 개인지 로그로 답하려고.
            if fired_d.get("deviate_valid") is False:
                rep["boards_deviate_valid_false"] += 1
                rep["deviate_valid_false_by_arm"][arm_name] += 1
            if fired_d.get("enact_applied") is None and fired_d.get("deviated") is not False:
                # Task 1(run_demo.jl)이 아직 enact_applied 를 안 내는 구세대 산출물이고, deviated
                # 로도 클래스를 판정할 수 없다 — 모르는 것을 아는 척 배제하지 않는다. 통과
                # 시키되 수를 남긴다(Task 1 완료 후 0이어야 정상).
                rep["enact_applied_missing"] += 1
            cls = _deviation_class(fired_d)
            if cls == "A":
                # 꼬리가 canonical 과 바이트 동일한 판. 꼬리 대표 하나만 남긴다(위 §등가류
                # docstring) — owner 자신이 클래스 A 면 main() 이 꼬리 대표를 아예 안 뽑아 전부
                # 여기로 온다(owner 가 이미 canonical 을 i=0 부터 전부 내고 있다).
                # ★ 어느 쪽이든 결정 k 행은 낸다 — 그 행은 이 판이 k 에서 강제한 팔로 라벨되고
                # 그 (칸,팔) 을 내는 판이 다른 데 없다(2026-08-15 7차).
                if is_class_representative:
                    rep["boards_class_a_representative"] += 1
                    rep["class_a_representative_by_arm"][arm_name] += 1
                    # 꼬리 대표는 비owner 규칙 그대로(i >= k) 전부 방출 — 아래로 흘려보낸다.
                else:
                    rep["boards_class_a_tail_dropped"] += 1
                    rep["class_a_tail_dropped_by_arm"][arm_name] += 1
                    drop_tail = True
            elif cls == "B":
                # 꼬리가 **NOOP 팔 판과** 바이트 동일한 판(canonical 과는 다르다). 그 세계를 이미
                # 전부 내고 있는 판(NOOP 팔 판, 또는 owner 가 클래스 B 면 owner)이 있으면 꼬리를
                # 뺀다 — main() 이 둘 다 없을 때만 꼬리 대표를 하나 뽑는다. 결정 k 행은 낸다.
                if is_class_representative:
                    rep["boards_class_b_representative"] += 1
                    rep["class_b_representative_by_arm"][arm_name] += 1
                else:
                    rep["boards_class_b_tail_dropped"] += 1
                    rep["class_b_tail_dropped_by_arm"][arm_name] += 1
                    drop_tail = True
            start_i = None
            for i, d in enumerate(ds):
                didx = d.get("decision_index")
                didx = didx if didx is not None else (i + 1)
                if didx >= k:
                    start_i = i
                    break
            if start_i is None:
                # fired 가 있었는데 k 이상인 decision_index 가 하나도 없다 — 이론상 안 일어나야
                # 하지만 안전망으로 이름을 남기고 아무것도 안 낸다.
                rep["boards_no_deviation"] += 1
                rep["no_deviation_by_arm"][arm_name] += 1
                continue

        n_before = len(out)
        _bat = r.get("battery") or {}
        for i, d in enumerate(ds):
            if i < start_i:
                # owner 아닌 판에서 owner 의 prefix 와 중복이라 뺀 결정(판이 아니라 결정 단위).
                rep["decisions_dropped_prefix_dup"] += 1
                continue
            if drop_tail and i > start_i:
                # 클래스 A/B 인데 꼬리 대표가 아닌 판의 꼬리 — 다른 판 꼬리의 바이트 복제라 뺀다.
                # `i == start_i`(= 결정 k)는 여기 안 걸린다: 그 행은 중복이 아니다(§등가류).
                rep["decisions_dropped_tail_dup"] += 1
                continue
            if cells[i] is None:
                continue                       # 이 결정은 칸이 없다(표본이 안 된다). 위에서 셌다.
            macro_name = d.get("macro")
            macro_id = id_by_name.get(macro_name)
            if macro_id is None:
                # arm_menu() 밖의 이름이 집행됐다 — 그 행만 버리고 이름별로 센다(GC10).
                rep["dropped_unknown_macro"][str(macro_name)] += 1
                continue
            is_last = (i + 1 == len(ds))
            nxt_cell = None if is_last else cells[i + 1]
            out.append({
                # ---- backward induction 이 읽는 네 값 --------------------------------------
                # Critical 1: 라벨은 이 결정에서 실제로 집행된 매크로다 — 판의 deviation 목표
                # 팔(arm_id/arm_name 인자)이 아니다.
                "cell": cells[i], "arm": macro_id, "arm_name": macro_name,
                "c": dec["cs"][i],
                "next_cell": nxt_cell,
                "terminal": (dec["terminal"] if is_last else None),
                "terminal_value": (dec["terminal_value"] if is_last else None),
                # 다음 결정은 있는데 **칸으로 라벨할 수 없는** 경우. V 를 0 으로 두면 미지의
                # 미래가 공짜가 되므로, 솔버가 dangling 으로 세게 이름을 남긴다.
                "next_unstateable": (not is_last and nxt_cell is None),
                # ---- 상수-팔 판(2026-08-14)과 **나란히 비교**하기 위한 판 단위 J ------------
                # solve_constant_arm() 이 이 열을 그대로 읽는다. 두 세대를 한 표본 파일로
                # 비교할 수 있어야 이번 작업이 무엇을 바꿨는지 말할 수 있다(계획 Task 7).
                "cost": dec["J"], "unscorable": (None if dec["J"] is not None else dec["reason"]),
                "c_prefix": dec["c_prefix"], "board_sum_c": dec["sum_c"],
                "capped": False, "sampling_mode": SAMPLING_MODE,
                # ---- 진단 전용(2026-08-17 리뷰). dp_solve.py 는 이 키들을 안 읽는다 ----------
                "board_deviate_at": k, "is_owner": is_owner,
                "decision_index": d.get("decision_index"),
                "deviated": d.get("deviated"), "deviate_from": d.get("deviate_from"),
                "deviate_valid": d.get("deviate_valid"),
                "seed": seed, "case": case, "at": d.get("at"),
                "enacted_macro": d.get("macro"),
                "complete": bool(r.get("complete")), "closed": r.get("closed"),
                "total": r.get("total"), "makespan": r.get("makespan"),
                "energy_J": dec["energy_J"], "energy_per_closed": _bat.get("energy_per_closed"),
                "objective_hash": r.get("objective_hash"),
                "energy_objective": r.get("energy_objective"),
                "board_id": board_id,
                "board_n_decisions": len(ds),
            })
        if not is_owner:
            rep["non_owner_transitions"] += len(out) - n_before
            if drop_tail:
                # 꼬리를 뺀 판에서 **실제로** 살아남은 결정 k 행의 수(0 또는 1). 0 이 되는 경우가
                # 있다: 그 결정이 칸으로 라벨이 안 되거나(cells[i] is None) 집행 이름이 arm_menu
                # 밖이면 그 행은 위에서 이미 빠진다. 판 수가 아니라 **행 수**를 세는 이유가 그것
                # 이다 — "꼬리만 뺐다"는 주장을 로그가 실제 행으로 뒷받침해야 한다.
                kept = len(out) - n_before
                rep["deviation_rows_kept_from_suppressed"] += kept
                if kept:
                    rep["deviation_rows_kept_by_arm"][arm_name] += kept
    return out


def _pick_deviation_representatives(boards, owner_arm, noop_arm_id):
    """(case, seed) 마다 **클래스 A·B 각각의 꼬리 대표**를 고른다(2026-08-17 4차 · 2026-08-15
    7차 수정) — owner 선정(`main()` 의 `owner_arm`)과 같은 결정론 원칙: 후보를 다 모은 뒤
    `min()` 으로 고르지, 도착 순서·첫 발견 순서에 기대지 않는다. 입력 순서를 섞어도 결과가 같다.

    ★ **이 함수가 정하는 것은 꼬리(`decision_index > k`)를 누가 내느냐 뿐이다**(2026-08-15 7차).
    결정 k 행은 이 반환값과 무관하게 **발화한 판이 전부 낸다** — 판마다 자기 팔을 k 에서
    강제하므로 그 행의 라벨이 그 팔이고, 그 (칸,팔) 을 내는 판이 다른 데 없어 중복이 아니다.
    "대표로 안 뽑혔다" = "꼬리를 안 낸다" 이지 "그 판을 뺀다" 가 아니다.

    `boards`: `[(case, seed, arm_id, rows_path), ...]` — **엔진이 성공한 판 전부**(owner 포함).
    owner 를 미리 빼면 안 된다: "owner 자신이 클래스 A 인가"(A 대표를 뽑을지 말지)와 "NOOP 팔
    판이 살아 있는가"(B 대표를 뽑을지 말지)를 이 함수가 알아야 하기 때문이다. 3차 구현이
    owner 를 미리 걸러 넘긴 것이 owner 상태를 영영 못 보게 만든 원인이었다.
    `owner_arm`: `{(case,seed): arm_id}`. `noop_arm_id`: `arm_menu()` 에서 **이름이 "NOOP" 인**
    팔의 id(숫자를 하드코딩하지 않는다. 메뉴에 NOOP 이 없으면 `None` — 그러면 "NOOP 판 없음"
    으로 취급되어 클래스 B 꼬리 대표가 하나 남는다).

    반환: `{(case, seed): {"A": arm_id, "B": arm_id}}` — 꼬리 대표가 있는 클래스의 키만 들어간다.

    ★ **두 클래스는 규칙이 하나다: 그 세계를 이미 전부 내고 있는 판이 있으면 꼬리 대표를 두지
    않는다.** (두 예외가 서로 다른 특칙처럼 보이면 다음 사람이 하나를 지운다 — 같은 원칙의 두
    얼굴이다.) 어느 판이 그 세계를 들고 있느냐만 클래스마다 다르다:
      · A(= 꼬리가 canonical 과 바이트 동일) — 그 세계를 들고 있는 판은 **owner 가 클래스 A 일
        때의 owner** 다. 그러면 0개. 아니면 비owner 클래스 A 중 arm_id 최솟값 하나. (한
        (case,seed) 에 클래스 A 판은 최대 하나다 — 판마다 강제하는 팔이 다르고 `deviated is
        False` 는 그 팔이 canonical 의 유일한 선택과 같았다는 뜻이므로.)
      · B(= 꼬리가 NOOP 팔 판과 바이트 동일) — 그 세계를 들고 있는 판은 **NOOP 팔 판**이거나
        **owner 가 클래스 B 일 때의 owner** 다. 둘 중 하나라도 있으면 0개. 둘 다 없을 때만
        비owner 클래스 B 중 arm_id 최솟값 하나(2026-08-17 5차: owner 쪽 대칭 예외를 추가했다 —
        NOOP 판이 크래시하고 owner 가 클래스 B 면 대표 꼬리가 owner 꼬리의 정확한 복제였다).
    **미발화 판**(`_board_deviation_status` == "no_fire")은 낼 결정 k 행 자체가 없고 어느 클래스도
    아니라 후보에 안 들어간다 — 그 경우 owner 도 같은 k 에서 안 걸렸을 것이므로 owner 자체가 이미
    canonical 이다. 한 (case,seed) 에 꼬리 대표가 하나도 없으면 그 키가 반환 dict 에 아예 없다
    (호출자는 `.get(cs, {})` 로 물어야 한다) — 그래도 그 판들은 각자 결정 k 행을 낸다."""
    cand = collections.defaultdict(lambda: {"A": [], "B": []})
    owner_class = {}
    noop_board_alive = {(c, s) for c, s, aid, p in boards if aid == noop_arm_id}
    for c, s, aid, p in boards:
        status = _board_deviation_status(p)
        if aid == owner_arm.get((c, s)):
            # owner 는 대표 후보가 아니다(항상 전 결정을 낸다). 그러나 owner 가 **어느 클래스인지**
            # 는 그 클래스의 대표를 뽑을지 말지를 가르므로 **반드시 본다** — owner 가 이미 그
            # 세계를 `i=0` 부터 전부 내고 있으면 대표는 그 꼬리의 복제일 뿐이다.
            owner_class[(c, s)] = status
            continue
        if status in ("A", "B"):
            cand[(c, s)][status].append(aid)
    # GC10: 오늘 도달 불가한 배치(NOOP 팔 판이 살아 있는데 owner 가 아니다)를 코드로 방어하지는
    # 않되, 일어나면 조용히 넘어가지 않도록 이름으로 남긴다 — 그 경우 "NOOP 판이 그 세계를 낸다"
    # 는 전제가 깨진다(비owner NOOP 판은 꼬리 대표가 아니면 자기 결정 k 행만 내고 꼬리를 안 낸다).
    stray = sorted(cs for cs in noop_board_alive if owner_arm.get(cs) != noop_arm_id)
    if stray:
        print("[표집] ⚠️ NOOP 팔 판(id=%s)이 살아 있는데 owner 가 아닌 (case,seed) %d개: %s%s"
              % (noop_arm_id, len(stray), stray[:5], " …" if len(stray) > 5 else ""))
    out = {}
    for cs, byclass in cand.items():
        picks = {}
        if byclass["A"] and owner_class.get(cs) != "A":
            picks["A"] = min(byclass["A"])
        if byclass["B"] and cs not in noop_board_alive and owner_class.get(cs) != "B":
            picks["B"] = min(byclass["B"])
        if picks:
            out[cs] = picks
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=24)
    ap.add_argument("--seeds", default="1,2,3,4,5,6,7,8,9,10")
    ap.add_argument("--cases", default=",".join(CASES))
    ap.add_argument("--work", default=os.path.join(HERE, "_sample_work"))
    ap.add_argument("--out", default=os.path.join(HERE, "samples.jsonl"))
    ap.add_argument("--keep-work", action="store_true")
    ap.add_argument("--n-hint", type=int, default=DEFAULT_N_HINT,
                     help="pick_k 의 n_hint — deviation 미발화(R3) 제외율을 결정하는 유일한 "
                          "손잡이(기본 %d = 실측 결정 수 중앙값)" % DEFAULT_N_HINT)
    ap.add_argument("--manifest-only", action="store_true",
                     help="시뮬레이션을 돌리지 않고 보존된 --work 의 rows.jsonl 만 훑어 "
                          "판별 매니페스트(boards.jsonl)를 다시 낸다. 표본 파일은 안 건드린다.")
    a = ap.parse_args()

    seeds = [int(x) for x in a.seeds.split(",") if x.strip()]
    cases = [c for c in a.cases.split(",") if c.strip()]
    arms = arm_menu()
    id_by_name = {n: i for i, n in arms}          # 라벨링(Critical 1)이 쓰는 이름->id
    grid = load_grid()
    axes = grid["axes"]

    jobs = [(c, s, aid, an) for s in seeds for c in cases for (aid, an) in arms]
    print("표집 계획: case %d x seed %d x 팔 %d = **%d 판**, 병렬 %d, n_hint=%d"
          % (len(cases), len(seeds), len(arms), len(jobs), a.jobs, a.n_hint))
    print("팔 메뉴 (action_registry.json):", ", ".join("%d:%s" % x for x in arms))
    os.makedirs(a.work, exist_ok=True)

    if a.manifest_only:
        # 보존된 판 원자료만 다시 읽는다 — 시뮬레이션도, 표본 재생성도 하지 않는다.
        write_board_manifest(os.path.join(os.path.dirname(a.out) or ".", "boards.jsonl"),
                             a.work, jobs, n_hint=a.n_hint)
        return

    t0 = time.time()
    done = {"n": 0, "fail": 0}
    # 엔진 크래시를 팔 이름별로 센다(Step 6). ReformTeam 이 표집 판의 15.5% 에서 엔진을 죽이는
    # 것으로 알려져 있다(§1-16) — deviation 모드에서 그 팔은 판당 한 번만 집행되므로 빈도가
    # 떨어질 것으로 예상되지만, 뭉뚱그리면 "왜 Reform 축이 얇은가"를 로그로 답할 수 없다.
    #
    # 스레드 안전(2026-08-17 리뷰 Minor): `work()` 는 최대 `a.jobs`(기본 24) 스레드에서 동시에
    # 불린다. `done["n"] += 1` 류의 비원자적 read-modify-write 는 증가가 샐 수 있고, GC10 이
    # 정확하길 요구하는 팔별 실패 수가 조용히 낮아진다. 락으로 두른다.
    lock = threading.Lock()
    fail_by_arm = collections.Counter()

    def work(j):
        c, s, aid, an = j
        p, k = run_board(c, s, aid, an, a.work, n_hint=a.n_hint)
        with lock:
            done["n"] += 1
            if p is None:
                done["fail"] += 1
                fail_by_arm[an] += 1
            n_done, n_fail = done["n"], done["fail"]
        if n_done % 25 == 0:
            el = time.time() - t0
            print("  %d/%d 판  (실패 %d)  경과 %.1f분  예상 총 %.1f분"
                  % (n_done, len(jobs), n_fail, el / 60,
                     el / 60 * len(jobs) / max(n_done, 1)), flush=True)
        return (j, p, k)

    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        results = list(ex.map(work, jobs))

    # 엔진 크래시는 exit 0 이되 수가 로그에 남는다 — 충실성 위반(boards_bad, exit 1)과는 다른
    # 사건이다(Global Constraint 4: 조용히 빼지 않는다).
    print("[표집] 판 %d개 중 엔진 실패 %d개" % (len(jobs), sum(fail_by_arm.values())))
    for name, n in sorted(fail_by_arm.items(), key=lambda t: -t[1]):
        print("[표집]   %-14s %d" % (name, n))

    # ---- owner 판 결정 (2026-08-17 리뷰 Critical 1) ---------------------------------------
    # (case, seed) 마다 rows 를 낸 판 중 **arm_id 최솟값**을 owner 로 정한다. `min()` 은 삽입
    # 순서와 무관하게 값 자체로 고르므로 dict/list 순서에 기대지 않는다(결정론적).
    by_cs = collections.defaultdict(list)
    for (c, s, aid, an), p, k in results:
        if p is not None:
            by_cs[(c, s)].append(aid)
    owner_arm = {cs: min(aids) for cs, aids in by_cs.items()}

    # ---- 클래스 A/B **꼬리** 대표 결정 (2026-08-17 4차 · 2026-08-15 7차 수정) ----------------
    # ★ 여기서 정하는 것은 꼬리(`decision_index > k`)를 누가 내느냐 뿐이다 — 결정 k 행은 발화한
    # 판이 전부 낸다(그 행은 그 판이 강제한 팔로 라벨돼 중복이 아니다).
    #
    # 성공한 판을 **owner 포함해서 전부** 넘긴다 — "owner 자신이 클래스 A 인가"(A 꼬리 대표를
    # 뽑을지)와 "NOOP 팔 판이 살아 있는가"(B 꼬리 대표를 뽑을지)를 그 함수가 알아야 하기
    # 때문이다(3차 구현은 owner 를 미리 걸러 넘겨 owner 상태를 영영 못 봤다). 실제 클래스 판정은
    # `_fired_decision`/`_deviation_class` 하나만 쓰므로 rows_to_samples 와 드리프트가 없다.
    #
    # NOOP 팔 id 는 **이름으로** 메뉴에서 찾는다(Global Constraint 4 — 매크로 id 를 하드코딩하지
    # 않는다). 메뉴에 NOOP 이 없으면 그 사실을 이름으로 찍는다(GC10): 그때는 "NOOP 판 없음" 이
    # 되어 클래스 B 꼬리 대표가 하나씩 남는다.
    noop_arm_id = next((i for i, n in arms if n == "NOOP"), None)
    if noop_arm_id is None:
        print("[표집] ⚠️ arm_menu() 에 NOOP 팔이 없다 — 클래스 B(집행 사슬 무동작) 판의 세계를 "
              "들고 있는 판이 없으므로 (case,seed) 마다 클래스 B 꼬리 대표를 하나씩 남긴다")
    all_success = [(c, s, aid, p) for (c, s, aid, an), p, k in results if p is not None]
    representative_arm = _pick_deviation_representatives(all_success, owner_arm, noop_arm_id)

    samples = []
    n_boards_ok = 0
    rep = new_report()
    for (c, s, aid, an), p, k in results:
        if p is None:
            continue
        n_boards_ok += 1
        is_owner = (aid == owner_arm[(c, s)])
        # 자기 클래스(A 든 B 든)의 **꼬리 대표**로 뽑혔는가. 한 판은 클래스가 하나뿐이라
        # (`_deviation_class` 에서 A 가 우선) 두 값 중 하나와만 일치할 수 있다. False 여도 그
        # 판은 자기 결정 k 행을 낸다 — 안 내는 것은 꼬리뿐이다(2026-08-15 7차).
        is_rep = (not is_owner) and aid in representative_arm.get((c, s), {}).values()
        samples.extend(rows_to_samples(p, c, s, aid, an, axes, k, is_owner=is_owner,
                                        is_class_representative=is_rep,
                                        id_by_name=id_by_name, report=rep))

    # 위 rows_to_samples 가 이미 표본에서 뺀 것들을 조용히 넘기지 않고 이름·수로 찍는다
    # (Global Constraint 4). 전부 서로 다른 사건이라 따로 찍는다 — fail_by_arm(엔진 크래시),
    # no_deviation(owner 아닌 판에서 게이트 미발화 = 낼 k 행 자체가 없다), 클래스 A/B 의 **꼬리**
    # 중복(판이 아니라 꼬리만 뺀다), dropped_unknown_macro(집행된 이름이 arm_menu 밖).
    #
    # ★ 2026-08-15 7차: "판 배제" 라고 찍던 줄을 전부 "꼬리 배제" 로 고쳤다. 그 판들은 자기
    # 결정 k 행을 내고 있으므로 배제됐다고 찍으면 그건 로그의 거짓말이다.
    if rep["boards_no_deviation"]:
        print("\n[표집] deviation 미발화로 제외한 판(owner 아님) %d개 (k > 결정 수 — 낼 결정 k "
              "행 자체가 없다):" % rep["boards_no_deviation"])
        for name, n in sorted(rep["no_deviation_by_arm"].items(), key=lambda t: -t[1]):
            print("[표집]   %-14s %d" % (name, n))

    print("\n[표집] 클래스 A (deviated=False, 꼬리가 **canonical 과** 바이트 동일) — 꼬리 대표 "
          "%d판 · 꼬리를 뺀 판 %d개 (owner 자신이 클래스 A 면 꼬리 대표를 안 뽑는다). "
          "**두 경우 다 결정 k 행은 낸다.**"
          % (rep["boards_class_a_representative"], rep["boards_class_a_tail_dropped"]))
    for name, n in sorted(rep["class_a_representative_by_arm"].items(), key=lambda t: -t[1]):
        print("[표집]   꼬리 대표 %-14s %d" % (name, n))
    for name, n in sorted(rep["class_a_tail_dropped_by_arm"].items(), key=lambda t: -t[1]):
        print("[표집]   꼬리 배제 %-14s %d" % (name, n))

    print("\n[표집] 클래스 B (enact_applied=False, 꼬리가 **NOOP 팔 판과** 바이트 동일 — "
          "canonical 과는 다르다) — 꼬리 대표 %d판(NOOP 판도 없고 owner 도 클래스 B 가 아닌 "
          "(case,seed) 뿐) · 그 세계를 이미 들고 있는 판(NOOP 팔 판 또는 owner)이 있어 꼬리를 "
          "뺀 판 %d개. **두 경우 다 결정 k 행은 낸다.**"
          % (rep["boards_class_b_representative"], rep["boards_class_b_tail_dropped"]))
    for name, n in sorted(rep["class_b_representative_by_arm"].items(), key=lambda t: -t[1]):
        print("[표집]   꼬리 대표 %-14s %d" % (name, n))
    for name, n in sorted(rep["class_b_tail_dropped_by_arm"].items(), key=lambda t: -t[1]):
        print("[표집]   꼬리 배제 %-14s %d" % (name, n))

    # 6차까지 통째로 사라지던 행들. 이 줄이 "판을 뺀 게 아니라 꼬리만 뺐다"의 기계적 증거다.
    print("\n[표집] 꼬리를 뺀 판에서 **살려 둔 deviation 행**(그 판이 k 에서 강제한 팔로 라벨 — "
          "그 (칸,팔) 을 내는 판이 다른 데 없다) %d행 · 뺀 꼬리 결정 %d개:"
          % (rep["deviation_rows_kept_from_suppressed"], rep["decisions_dropped_tail_dup"]))
    for name, n in sorted(rep["deviation_rows_kept_by_arm"].items(), key=lambda t: -t[1]):
        print("[표집]   %-14s %d" % (name, n))

    if rep["enact_applied_missing"]:
        print("\n[표집] enact_applied 키 없음(Task 1 run_demo.jl 구세대) %d판 — "
              "Task 1 완료 후엔 0이어야 정상" % rep["enact_applied_missing"])

    # 정보성(클래스 판정에는 안 씀): deviate_valid==False 자체의 빈도 — 메뉴 멤버십과 실제
    # 집행이 어긋나는 사건(valid=True, applied=False)이 몇 개인지 로그로 답할 수 있게.
    if rep["boards_deviate_valid_false"]:
        # "주로 zone 사건" 이라고 적어 뒀던 줄을 고쳤다(2026-08-17 최종 리뷰). 587판 실측 분포는
        # ForbidZone 29 · ReformTeam 28 · Replace/SwapBattery/Deprioritize 각 16 · RelocateBuild 13
        # 으로 **어느 축에도 쏠려 있지 않다** — zone 만의 현상이라고 읽으면 안 된다.
        print("\n[표집] deviate_valid=False 인 판(정보성, 배제 안 함) %d개 "
              "(메뉴 밖 — 특정 축에 쏠리지 않는다. 아래 팔별 분포를 볼 것):"
              % rep["boards_deviate_valid_false"])
        for name, n in sorted(rep["deviate_valid_false_by_arm"].items(), key=lambda t: -t[1]):
            print("[표집]   %-14s %d" % (name, n))

    if rep["dropped_unknown_macro"]:
        print("\n[표집] arm_menu 밖 이름이라 버린 행 %d개 (판이 아니라 그 결정 하나만):"
              % sum(rep["dropped_unknown_macro"].values()))
        for name, n in sorted(rep["dropped_unknown_macro"].items(), key=lambda t: -t[1]):
            print("[표집]   %-14s %d" % (name, n))

    print("\n[표집] owner 판(그 case·seed 에서 arm_id 최솟값) %d개 · owner 아닌 판이 낸 전이 %d개 "
          "· owner 의 prefix 와 중복이라 뺀 결정 %d개"
          % (rep["owner_boards"], rep["non_owner_transitions"],
             rep["decisions_dropped_prefix_dup"]))

    # 세대 단일성: 표본이 두 세대에서 오면 멈춘다. 섞인 값을 표에 각인시키지 않는다.
    gens = {(r.get("objective_hash"), r.get("energy_objective")) for r in samples}
    if len(gens) > 1:
        sys.exit("표본에 세대가 %d 종 섞여 있다: %s" % (len(gens), gens))

    # ---- §충실성 게이트 -------------------------------------------------------------------
    # 배분 규칙을 지어내면 그 규칙이 곧 결과가 된다. 그래서 "지어내지 않았다"를 여기서 기계로
    # 못박는다. 어긋난 판이 하나라도 있으면 뒤의 모든 숫자가 무효이므로 exit 1 이다.
    #
    # ★ 2026-08-17 최종 리뷰 — **게이트를 출력·정리 앞으로 옮겼다.** 예전에는 이 검사가
    # `open(a.out,"w")` 와 `shutil.rmtree(a.work)` **뒤에** 있었다. 그래서 위반한 런이
    #   (1) 직전의 **정상 `samples.jsonl` 을 덮어쓰고**,
    #   (2) `--keep-work` 없이 돌았다면 위반을 진단할 **판 원자료까지 지운 뒤**
    # exit 1 했다 — 게이트가 자기 증거를 파괴한 셈이다. 이제 위반이면 **아무것도 쓰지 않고
    # 아무것도 지우지 않고** 멈춘다. 종료 코드와 메시지는 그대로다.
    print("\n§분해 충실성: 판 %d 중 어긋남 %d · 최대잔차 %.3e (허용 %.0e) · 미상태화 결정 %d/%d"
          % (rep["boards"], rep["boards_bad"], rep["max_resid"], FIDELITY_TOL,
             rep["decisions_unstateable"], rep["decisions"]))
    for k, v in sorted(rep["by_reason"].items()):
        print("    %-24s %d" % (k, v))
    for bid, why in rep["examples"]:
        print("    예: %s -> %s" % (bid, why))

    if rep["boards_bad"]:
        print("[표집] 위반이므로 %s 를 쓰지 않고 작업 디렉토리(%s)도 지우지 않는다 — "
              "직전 표본과 진단용 판 원자료를 보존한다." % (a.out, a.work))
        sys.exit("분해 충실성 위반 %d판 — 그 뒤의 모든 숫자가 무효다(exit 1)." % rep["boards_bad"])

    with open(a.out, "w") as f:
        for r in samples:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    write_board_manifest(os.path.join(os.path.dirname(a.out) or ".", "boards.jsonl"),
                         a.work, jobs, n_hint=a.n_hint)

    by_cell = collections.Counter(r["cell"] for r in samples)
    by_cell_arm = collections.Counter((r["cell"], r["arm"]) for r in samples)
    n_unscorable = sum(1 for r in samples if r["cost"] is None)
    n_terminal = sum(1 for r in samples if r["terminal"] is not None)
    n_next_unstateable = sum(1 for r in samples if r.get("next_unstateable"))
    print("\n판 %d/%d 성공 · 전이 %d행 · 칸 %d개 · (칸,팔) 쌍 %d개"
          % (n_boards_ok, len(jobs), len(samples), len(by_cell), len(by_cell_arm)))
    print("  종단 전이 %d · 다음칸 미상태화 %d · J 채점불가 표본 %d (버리지 않고 표시)"
          % (n_terminal, n_next_unstateable, n_unscorable))
    print("관측 격자 대비 커버리지: %d / %d = %.1f%%"
          % (len(by_cell), grid["n_observed_cells"],
             100.0 * len(by_cell) / max(grid["n_observed_cells"], 1)))

    print("벽시계 %.1f분  ->  %s" % ((time.time() - t0) / 60, a.out))

    if not a.keep_work:
        shutil.rmtree(a.work, ignore_errors=True)


if __name__ == "__main__":
    main()
