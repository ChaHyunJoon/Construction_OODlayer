#!/usr/bin/env python3
"""surrogate 의 22차원 feature 조립기 (spec §3.4 + 2026-08-14 교차항 1개 추가).

  상태 6  (features_agnostic.STATE_DESCRIPTORS) — kind 불변, 부호 일관
  행동 10 (features_agnostic.PSI_AXES)          — macro 를 이름표가 아니라 '무엇을 하는가' 로
  교차 6                                        — 물리적 의미가 있는 것만

왜 kind one-hot 을 안 넣는가: 넣으면 처음 보는 OOD kind 에서 one-hot 이 전부 0 인
미지원 영역이 되어 무너진다. 이 시스템의 존재 이유가 처음 보는 사건 대응이다.
`resource_loss × a_restores_capacity` 가 kind 를 대신하면서 일반화까지 얻는 경로다.

왜 legacy e1_analyze.featurize 를 안 쓰는가: `severity` 의 물리적 의미가 kind 마다
부호가 뒤집힌다(fault 高=위험, battery 低=위험). fault 에서 배운 규칙이 battery 에서
정확히 반대로 작동한다 — 데이터를 더 모아도 안 고쳐진다(features_agnostic.py 헤더).

왜 22개인가: spec §3.4 의 21개 + `resource_loss × a_cost`(아래 근거). 예산은 그대로 지킨다 —
§3.4 의 13.6행/feature 는 286행 기준이고, 현행 라벨셋은 355행이라 22개에서도 16.1행/feature 다.

행 필터링 책임 (Task 4 가 발견한 제약, 이 모듈은 그 어느 것도 하지 않는다):
  이 모듈의 `build_features(rows)` 는 이미 로드·필터링된 dict 목록을 받는다 — 그 자체로는
  아무 필터링도, JSON 파일 읽기도 하지 않는다. **호출자**가 책임지는 것:
    1. 행은 `e1_analyze.load()` 를 통해 읽어야 한다 — `makespan`(143행) · `soc`/`zone_radius`
       (220/235행)이 JSON 문자열 "Inf"/"NaN" 으로 온다. 그 변환을 `load()` 가 한다; 우회하는
       pandas 읽기는 object-dtype 문자열 컬럼을 만들어 여기서 조용히 죽거나 오염시킨다.
    2. 10개 stub 행(`fired == False`, 미발화 control 런인데 complete=true 로 표시됨)은
       `build_features` 를 호출하기 **전에** 제외해야 한다 — `fired` 로 거른다(가장 저렴하고
       세 판별자 중 권장). 이 함수는 `fired` 필드를 보지 않는다 — 이미 걸러졌다고 가정한다.
  왜 여기서 안 하는가: 이 함수의 입력 계약은 "라벨 행 dict 목록"이지 "라벨 파일 경로"가
  아니다(브리프의 `build_features(rows)` 시그니처). 로딩·필터링을 여기 섞으면 이 모듈이
  파일 포맷에 결합되고, Task 6 이 이미 필터링된 다른 출처(예: 테스트 픽스처)로 재사용할 수 없게
  된다. 대신 이 파일의 단위검사는 필터링 없이 최소 행 dict 로만 돈다 — 그 결정을 그대로 반영한다.
  실 데이터셋에 대한 필터링 적용은 `wm_datasets.RELABEL_20260814` 를 읽는 호출부(Task 6, 또는
  이 리포의 sanity-check 스크립트)의 몫이다.
"""
import os
import sys

import pandas as pd

# 2026-08-18 폴더 분류: 옆 폴더(core/ 등)의 모듈을 맨이름으로 import 하려고 코드 폴더
# 전부를 sys.path 에 올린다(근거·쓰는 법은 core/wmpath.py 머리말). 분류 전에는 이 자리가
# `sys.path.insert(0, <이 파일 폴더>)` 한 줄이었다 — 그때는 모든 py 가 한 폴더였다.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import wmpath                                            # noqa: E402,F401
from features_agnostic import (STATE_DESCRIPTORS, PSI_AXES, psi,   # noqa: E402
                               descriptors_from_row)

# (상태축, 행동축) — 물리적 근거가 있는 교차만.
INTERACTIONS = [
    ("resource_loss",     "a_restores_capacity"),   # 핵심: 잃은 능력 × 되돌리는 행동
    ("harm",              "a_intervenes"),          # 무해한 사건에 개입하면 손해
    ("recovery_capacity", "a_consumes_spare"),      # 예비가 없으면 Replace 를 못 쓴다
    ("work_at_risk",      "a_scope"),               # 큰 일일 때만 전역 개입이 값을 한다
    ("slack",             "a_soft"),                # 병렬성이 남을 때만 soft 가 통한다
    # ---- 2026-08-14 추가 (22번째). SwapBattery 가 교차항 블록에서 NOOP 과 충돌하는 것을 깬다.
    #
    # 무엇이 문제였나: 위 5개 중 팔 1(Replace)과 팔 8(SwapBattery)을 건드리는 교차는
    # `recovery_capacity × a_consumes_spare` 하나뿐인데, 그 축에서 a_consumes_spare(8)=0.0 =
    # a_consumes_spare(0) 이라 **SwapBattery 가 NOOP 의 값을 그대로 갖는다.** 그래서 헤드 A 는
    # fault 50건에서 배운 "예비 소모 × 복구여력 ⇒ 이 팔이 빌드를 살린다"를 SwapBattery 에는
    # 적용하지 못하고, 대신 NOOP 의 증거를 물려받아 완주확률을 ~1%p 깎았다. C_fail 절벽이
    # 그 1%p 를 200 J 넘게 증폭한다(dĴ/dP ≈ −20,500 J). psi(8) 결함의 잔재다 — Task 1 이 ψ 축은
    # 고쳤지만 교차항 블록은 여전히 8 을 0 위로 접는다.
    #
    # 왜 `a_reversible` 이 아닌가 (지시된 축에서 벗어난 유일한 지점, 실측 근거):
    #   a_reversible 은 NOOP=1.0 · Replace=0.0 · SwapBattery=**1.0** 이다. 즉 8 이 여전히
    #   NOOP 과 값이 같고, 충돌 쌍이 (8,0) 에서 (8,0) 으로 그대로다 — 극성만 뒤집힐 뿐
    #   "SwapBattery 에 Replace·NOOP 둘 다와 다른 값을 준다"는 판정 기준을 만족하지 못한다.
    #   ψ 10축 중 8 을 **두 팔 모두와** 가르는 축은 `a_cost` 하나뿐이다(0.0 / 1.0 / 0.2).
    #
    # 왜 `resource_loss × a_cost` 인가 (물리적 근거, 결과를 보기 전에 적는다):
    #   "잃은 능력을 되돌리는 데 얼마를 치르는가". spec §3.4 가 핵심으로 지목한 상태축
    #   resource_loss 를 비용축과 짝지은 것으로, 첫 교차항의 자연스러운 짝이다.
    #   물리적으로 이것이 바로 배터리와 고장을 가르는 축이다: 두 사건 모두 resource_loss 가
    #   높지만, 배터리는 **싼** 복구(SwapBattery, 0.2)로 충분하고 하드 고장은 **비싼** 복구
    #   (Replace, 1.0)를 요구한다. kind 이름 없이 "싸게 살릴까 비싸게 살릴까"를 표현하는 축이며,
    #   그 선택이 이 과제 전체가 다루는 결정 그 자체다.
    ("resource_loss",     "a_cost"),
]

FEATURE_NAMES = (list(STATE_DESCRIPTORS) + list(PSI_AXES) +
                 ["%s__x__%s" % (s, a) for s, a in INTERACTIONS])


def build_features(rows):
    """rows: 라벨 행(dict) 목록. 각 행은 최소한 `macro` 와 상태 서술자 계산에 필요한 필드를 갖는다.

    이 함수는 로딩도 필터링도 하지 않는다 — 위 모듈 docstring 의 "행 필터링 책임" 절이
    호출자가 해야 할 일(`e1_analyze.load()` 로 읽기, `fired` 로 stub 제외)을 명시한다.

    반환: 열 순서가 FEATURE_NAMES 와 **정확히** 같은 DataFrame.
    (순서가 흔들리면 배포 쪽 조립기와 조용히 어긋난다 — 그게 이 저장소의 반복된 사고다.)
    """
    out = []
    for r in rows:
        s = descriptors_from_row(r)                 # kind-agnostic 상태 서술자
        a = psi(int(r["macro"]))                    # 행동 서술자 (Task 1 이 macro 8 을 고쳤다)
        row = {}
        for k in STATE_DESCRIPTORS:
            row[k] = float(s[k])
        for k in PSI_AXES:
            row[k] = float(a[k])
        for sk, ak in INTERACTIONS:
            row["%s__x__%s" % (sk, ak)] = float(s[sk]) * float(a[ak])
        out.append(row)
    return pd.DataFrame(out, columns=FEATURE_NAMES).fillna(0.0)
