#!/usr/bin/env python3
"""surrogate 의 21차원 feature 조립기 (spec §3.4).

  상태 6  (features_agnostic.STATE_DESCRIPTORS) — kind 불변, 부호 일관
  행동 10 (features_agnostic.PSI_AXES)          — macro 를 이름표가 아니라 '무엇을 하는가' 로
  교차 5                                        — 물리적 의미가 있는 것만

왜 kind one-hot 을 안 넣는가: 넣으면 처음 보는 OOD kind 에서 one-hot 이 전부 0 인
미지원 영역이 되어 무너진다. 이 시스템의 존재 이유가 처음 보는 사건 대응이다.
`resource_loss × a_restores_capacity` 가 kind 를 대신하면서 일반화까지 얻는 경로다.

왜 legacy e1_analyze.featurize 를 안 쓰는가: `severity` 의 물리적 의미가 kind 마다
부호가 뒤집힌다(fault 高=위험, battery 低=위험). fault 에서 배운 규칙이 battery 에서
정확히 반대로 작동한다 — 데이터를 더 모아도 안 고쳐진다(features_agnostic.py 헤더).

왜 21개인가: 학습셋이 286행이다. 행당 13.6개로, 교차항을 남발하면 과적합으로 돌아온다.

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from features_agnostic import (STATE_DESCRIPTORS, PSI_AXES, psi,   # noqa: E402
                               descriptors_from_row)

# (상태축, 행동축) — 물리적 근거가 있는 교차만.
INTERACTIONS = [
    ("resource_loss",     "a_restores_capacity"),   # 핵심: 잃은 능력 × 되돌리는 행동
    ("harm",              "a_intervenes"),          # 무해한 사건에 개입하면 손해
    ("recovery_capacity", "a_consumes_spare"),      # 예비가 없으면 Replace 를 못 쓴다
    ("work_at_risk",      "a_scope"),               # 큰 일일 때만 전역 개입이 값을 한다
    ("slack",             "a_soft"),                # 병렬성이 남을 때만 soft 가 통한다
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
