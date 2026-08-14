"""배포 surrogate 의 **매크로 지원 집합** 계약 테스트.

왜 이 테스트가 필요한가: 학습 근거가 없는 매크로는 dspy_service.surrogate_rank 에서 후보에서
탈락한다. 그래서 어휘가 빠지면 에러가 아니라 **성능으로만** 샌다 -- RESULTS_LLM7H §5-f 에서
배포 surrogate 가 규칙과 5판 전부 바이트 동일한 결과를 낸 것이 그 증상이었다.
지원 집합은 주장이 아니라 검사여야 한다.

────────────────────────────────────────────────────────────────────────────────────────────
이 파일에는 **두 계약**이 있다 (2026-08-14 최종 리뷰에서 두 번째가 추가됐다)
────────────────────────────────────────────────────────────────────────────────────────────
§A (기존) `N44_PLUS78` — 2026-08-06~08-13 배포 학습셋. `wm_datasets.resolve()` 로 읽으므로
   `$WM_DATASET` 으로 덮인다. **역사적 계약이라 그대로 둔다**: 그 세대의 숫자가 이 지원
   집합 위에서 측정됐고, 그 파일이 조용히 줄어들면 그 숫자들이 재현되지 않는다.

§B (2026-08-14 추가) `RELABEL_20260814` — **지금 배포되는** 학습셋
   (`dspy_service.SURRO_DATA`). §A 만으로는 이 파일의 docstring 이 약속한 것을 하나도 지키지
   못했다: §A 는 은퇴한 데이터셋 위에서 `{0,1,2,3,4} ⊆ support` 를 보는데 **배포 지원 집합은
   `{0,1,2,7,8}`** 이라, 배포 지원이 `{0}` 으로 붕괴해도 §A 는 초록이었다. 게다가 §A 는
   `$WM_DATASET` 으로 덮이는 경로인데, `eval_surrogate_v2.py:37` 과 `dspy_service.py:179-180`
   은 정확히 그 경로를 **의도적으로 거부**한다(환경변수 하나로 옛 라벨이 다시 들어오는 것을
   막으려고). 계약 테스트가 배포가 거부하는 경로로 읽고 있었던 것이다.
   그래서 §B 는 상수를 직접 쓰고, 지원 집합을 **정확히** `{0,1,2,7,8}` 로 못박는다
   (⊆ 가 아니라 == 다. 더 줄어드는 것도, 조용히 늘어나는 것도 계약 위반이다).

   §B 가 지키는 **알려진 능력 회귀**(숨기지 않고 못박는다): 매크로 4(ReformTeam)·3(ForbidZone)
   행이 이 라벨셋에 **0줄**이다. 4 가 지원에서 빠지면 배포 서비스가 그 팔을 후보에서 걸러
   `ReformTruth` 사건에 개입을 낼 수 없다 — 630판 스윕 기준 **511건**의 ReformTruth 결정이
   그 영향을 받는다(그 결정들은 `UNSUPPORTED` 규약으로 폴백한다: dspy_service.py 의
   "개입 후보 전멸" 분기 + policy.jl 의 표현력 격상). 이 사실이 **테스트로** 남아 있어야
   다음 세대가 "3·4 는 원래 없었나 보다" 로 지나가지 않는다.
"""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import wm_datasets
from surrogate_data import load_training_frame

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


print("== §A 은퇴한 학습셋(N44_PLUS78)의 매크로 지원 — 역사적 계약 ==")
path = wm_datasets.resolve(None, default=wm_datasets.N44_PLUS78)
X, y, support, n_inst = load_training_frame(path)
check("데이터셋이 존재한다", os.path.exists(path), path)
check("instance 수 >= 60", n_inst >= 60, "n=%d" % n_inst)
check("SwapBattery(8) 학습 근거 있음", 8 in support, "support=%s" % sorted(support))
check("기존 5팔 보존", {0, 1, 2, 3, 4} <= support, "support=%s" % sorted(support))
check("X/y 길이 일치", len(X) == len(y), "%d vs %d" % (len(X), len(y)))
check("RelocateBuild(7) 학습 근거 있음", 7 in support, "support=%s" % sorted(support))
check("instance 수 == 68 (n44_plus8 62 + fzgrid_0806 6)", n_inst == 68, "n=%d" % n_inst)

# ==========================================================================================
#  §B  **배포** 학습셋(RELABEL_20260814)의 지원 집합을 정확히 못박는다 (2026-08-14)
# ==========================================================================================
# 배포와 **같은 경로로** 읽는다: 상수 직접 사용(`resolve()` 금지 = $WM_DATASET 무시) +
# `eval_surrogate_v2.load_rows`(fired 필터). dspy_service._load_surrogate 가 support 를
# 만드는 식과 글자 그대로 같다 — 여기서 다시 쓰면 검사와 배포가 갈린다.
print()
print("== §B 배포 학습셋(RELABEL_20260814)의 매크로 지원 — 현행 계약 ==")
DEPLOYED_SUPPORT = {0, 1, 2, 7, 8}
KNOWN_ABSENT = {3, 4}          # ForbidZone(3) · ReformTeam(4) — 아래 회귀 검사 참조

rel_path = wm_datasets.abspath(wm_datasets.RELABEL_20260814)
check("배포 라벨셋이 존재한다", os.path.exists(rel_path), rel_path)

from eval_surrogate_v2 import load_rows          # noqa: E402  (배포와 같은 로더)
rel_rows, rel_meta = load_rows(rel_path)
rel_support = {int(r["macro"]) for r in rel_rows}

check("배포 지원 집합이 **정확히** {0,1,2,7,8} 이다 (⊆ 가 아니라 ==)",
      rel_support == DEPLOYED_SUPPORT, "support=%s" % sorted(rel_support))
check("SwapBattery(8)·RelocateBuild(7) 학습 근거 있음",
      {7, 8} <= rel_support, "support=%s" % sorted(rel_support))
check("ForbidZone(3)·ReformTeam(4) 는 **알려진 부재**다 — 조용히 생기지도, 이 사실이 "
      "잊히지도 않게 못박는다 (매크로 4 부재 = 스윕 511건의 ReformTruth 결정이 폴백)",
      KNOWN_ABSENT.isdisjoint(rel_support), "support=%s" % sorted(rel_support))
check("행 수 355 / instance 155 (stub 10행 제거 후)",
      rel_meta["rows_after_fired_filter"] == 355 and rel_meta["instances"] == 155,
      "rows=%d inst=%d" % (rel_meta["rows_after_fired_filter"], rel_meta["instances"]))

# 이 테스트가 **배포가 실제로 읽는 파일**을 보고 있는가. 서비스가 다른 상수로 옮겨가면
# 위 검사들은 초록인 채로 아무것도 안 지키게 된다 — 그 경로를 텍스트로 막는다
# (dspy 를 import 하지 않고 검사하려고 소스를 읽는다: audit_action_vocab.py 와 같은 수법).
_svc_path = os.path.join(os.path.dirname(HERE), "src", "respec", "llm_service", "dspy_service.py")
_svc = open(_svc_path, encoding="utf-8").read()
check("dspy_service 가 여전히 RELABEL_20260814 을 배포 학습셋으로 고정한다",
      "SURRO_DATA = wm_datasets.abspath(wm_datasets.RELABEL_20260814)" in _svc, _svc_path)

sys.exit(1 if FAILED else 0)
