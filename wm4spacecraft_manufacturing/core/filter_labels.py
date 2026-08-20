"""구세대 라벨셋에서 은퇴한 팔의 행을 **빼기만** 한다 (spec §8·§11-6).

  872행 − 65(구 macro 5) − 65(구 macro 6) = 742행 / 260 instance (98 아니다 — 아래 참고).
  구 macro 3(ForbidZone)은 원래 0행이라 손실이 없다.

🔴 **정수 remap 을 하지 않는다.** id 를 0..5 로 다시 매기면 구세대 macro 3 행이
ReformTeam 으로, 5 행이 SwapBattery 로 **에러 없이** 재해석된다. 3·5·6 을 영구 결번으로
두면 구세대 파일은 조회 실패로 죽고, 그게 우리가 원하는 실패 모양이다(spec §2.4).

🔴 **원본을 덮어쓰지 않는다.** 새 파일로 파생하고 도장을 찍는다.

  python filter_labels.py oracle/out/relabel_2026-08-16.jsonl oracle/out/relabel_2026-08-19.jsonl

🔴 **Task 6b (task-6-review.md 가 찾은 두 Critical 결함)**: `macro` 열만 빼고 `valid_mask` 를
그대로 두면(원래 Task 6 이 한 일) 은퇴 팔이 메뉴 필드를 통해 소비처에 계속 닿는다 —
`surrogate_gates.max_cost_menu_policy` 가 이 데이터셋에서 은퇴 macro 5 를 65 instance 에서
고르고, `e1_analyze.instance_arms_complete` 는 65 instance/260행을 조용히 버린다(에러 없이).
그래서 여기서는 **`valid_mask` 등 메뉴를 나르는 모든 필드에서도** 은퇴 id 를 뺀다.
데이터 전수 조사(2026-08-20) 결과 `macro` 외에 은퇴 id 를 나를 수 있는 필드는 `valid_mask`
하나뿐이다 — 872행의 전체 키 집합에서 리스트 타입 필드를 모두 뽑아보면 `raw_*`(로봇/화물/
구역/스테이지별 관측 배열)뿐이고 그건 macro id 와 무관하다.

`RETIRED_MACROS` 는 이제 `action_registry.RETIRED`(Task 5 가 export, dict[int, str])에서
온다 — 하드코드가 아니다. 타입이 dict 라 등식 비교 전에 `frozenset(...)` 으로 감싼다
(`frozenset({3,5,6}) == {3: "..."}` 는 거짓이다). 이 파일이 **전제하는** 값(3,5,6)과 registry
의 실제값이 어긋나면 import 시점에 죽는다 — 조용히 registry 값을 받아써서 "은퇴 표식을
조용히 재해석하는" 실패 모양이 되는 것을 막는다.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import action_registry  # noqa: E402

# 영구 결번 (spec §11-6). 이제 action_registry.RETIRED(dict[int,str])에서 온다.
RETIRED_MACROS = frozenset(action_registry.RETIRED)
assert RETIRED_MACROS == frozenset({3, 5, 6}), (
    "action_registry.RETIRED 이 이 파일이 전제하는 {3,5,6} 과 다르다: %s. "
    "registry 가 바뀌었거나 이 파일의 전제가 낡았다는 뜻이다 — 조용히 넘어가지 말 것."
    % sorted(RETIRED_MACROS))


def _strip_retired(valid_mask):
    """valid_mask(메뉴) 리스트에서 은퇴 id 를 뺀다. None/리스트가 아니면 그대로 둔다
    (`wm_datasets.py` 주석: valid_mask 가 없는 행은 사건 미발화 stub 이라 규약이 다르다)."""
    if not isinstance(valid_mask, list):
        return valid_mask
    return [m for m in valid_mask if int(m) not in RETIRED_MACROS]


def filter_rows(rows):
    """(살아남은 행, 카운터). 행마다 vocab 도장을 찍고 valid_mask 에서도 은퇴 id 를 뺀다.
    macro 컬럼은 remap 하지 않는다(존재하는 id 는 그대로, 존재하지 않아야 할 id 는 행째 drop).

    보존 불변식: 입력 행은 kept 이거나 dropped_by_macro 에 세어지거나 — 제3의 길이 없다.
    이 assert 가 없으면 세지 않은 drop(예: 조건 없는 continue)이 자기정합적인 요약과 함께
    조용히 통과한다(task-6-review.md 2-c' 의 음성 대조가 실측한 그 실패 모양)."""
    kept, dropped = [], {}
    for row in rows:
        m = row.get("macro")
        if m in RETIRED_MACROS:
            dropped[m] = dropped.get(m, 0) + 1
            continue
        row = dict(row)
        if "valid_mask" in row:
            row["valid_mask"] = _strip_retired(row["valid_mask"])
        row["vocab"] = action_registry.VOCAB
        kept.append(row)
    diag = {"kept": len(kept), "dropped_by_macro": dropped, "stamped": len(kept)}
    total_dropped = sum(dropped.values())
    if len(kept) + total_dropped != len(rows):
        raise AssertionError(
            "보존 불변식 위반 — kept(%d) + dropped(%d) != 입력(%d). 세지 않은 drop 이 있다."
            % (len(kept), total_dropped, len(rows)))
    return kept, diag


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    if os.path.abspath(src) == os.path.abspath(dst):
        raise SystemExit("원본을 덮어쓸 수 없다 — 새 파일로 파생할 것: %s" % dst)
    with open(src, encoding="utf-8") as fh:
        rows = [json.loads(l) for l in fh if l.strip()]
    kept, diag = filter_rows(rows)
    with open(dst, "w", encoding="utf-8") as fh:
        for r in kept:
            # separators 를 입력 파일의 무공백 직렬화 스타일에 맞춘다(json.dumps 기본값은
            # ", "/": " 라 행마다 +96B 가 붙는다 — Task 6 리뷰가 지적한 점). vocab 추가·
            # valid_mask 정리 때문에 바이트 동일은 애초에 불가능하지만(모든 행이 최소
            # vocab 필드를 얻는다), 그 두 변경 밖의 스타일 차이는 없앤다.
            fh.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
    inst = len({r.get("instance_id", r.get("instance")) for r in kept})
    print("입력 %d행 → 출력 %d행 / instance %d" % (len(rows), diag["kept"], inst))
    print("제거: %s" % diag["dropped_by_macro"])
    print("도장: vocab=%s (%d행)" % (action_registry.VOCAB, diag["stamped"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
