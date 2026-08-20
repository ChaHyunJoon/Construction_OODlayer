"""구세대 라벨셋에서 은퇴한 팔의 행을 **빼기만** 한다 (spec §8·§11-6).

  872행 − 65(구 macro 5) − 65(구 macro 6) = 742행 / 260 instance (98 아니다 — 아래 참고).
  구 macro 3(ForbidZone)은 원래 0행이라 손실이 없다.

🔴 **정수 remap 을 하지 않는다.** id 를 0..5 로 다시 매기면 구세대 macro 3 행이
ReformTeam 으로, 5 행이 SwapBattery 로 **에러 없이** 재해석된다. 3·5·6 을 영구 결번으로
두면 구세대 파일은 조회 실패로 죽고, 그게 우리가 원하는 실패 모양이다(spec §2.4).

🔴 **원본을 덮어쓰지 않는다.** 새 파일로 파생하고 도장을 찍는다.

  python filter_labels.py oracle/out/relabel_2026-08-16.jsonl oracle/out/relabel_2026-08-19.jsonl

⚠️ **`action_registry.RETIRED` 는 아직 존재하지 않는다 (2026-08-19 실측).** 이 태스크(6)가
계획서 순번상 태스크 5(3/5/6 을 registry 에 `"retired": true` 로 표시하고 `RETIRED` 를
export 하는 일) 보다 **먼저** 실행됐다 — controller progress.md: "Task 5 deliberately NOT
started yet ... Ruling M again: Task 4 review + Task 6 implementer dispatched concurrently."
실측: `action_registry.py` 에 `RETIRED` 심볼이 없고, `action_registry.json` 의 `vocab` 은
아직 `"v1-9arms"`이며 매크로 3/5/6 어디에도 `"retired"` 필드가 없다(전부 `None`).
그래서 이 모듈은 **이 태스크가 필터링하기로 정해진 바로 그 집합**을 여기 하드코드한다 —
`action_registry.*` 를 건드리는 것은 이 태스크의 범위 밖(surface 제한)이다.
태스크 5가 나중에 착지해 `action_registry.RETIRED` 를 export 하면, 그 값과 아래
`RETIRED_MACROS` 가 **일치하는지 사람이 대조할 것** — 다르면 조용히 넘어가지 말고 둘 중
하나가 틀렸다는 뜻으로 다뤄야 한다(이 파일이 자동으로 갈아타면 이 파일 자체가 "은퇴 표식을
조용히 재해석하는" 바로 그 실패 모양이 된다).
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import action_registry  # noqa: E402

# 영구 결번 (spec §11-6). action_registry.RETIRED 가 아직 없어(위 docstring) 여기 하드코드한다.
RETIRED_MACROS = frozenset({3, 5, 6})


def filter_rows(rows):
    """(살아남은 행, 카운터). 행마다 vocab 도장을 찍는다. macro 컬럼은 손대지 않는다."""
    kept, dropped = [], {}
    for row in rows:
        m = row.get("macro")
        if m in RETIRED_MACROS:
            dropped[m] = dropped.get(m, 0) + 1
            continue
        row = dict(row)
        row["vocab"] = action_registry.VOCAB
        kept.append(row)
    return kept, {"kept": len(kept), "dropped_by_macro": dropped, "stamped": len(kept)}


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
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    inst = len({r.get("instance_id", r.get("instance")) for r in kept})
    print("입력 %d행 → 출력 %d행 / instance %d" % (len(rows), diag["kept"], inst))
    print("제거: %s" % diag["dropped_by_macro"])
    print("도장: vocab=%s (%d행)" % (action_registry.VOCAB, diag["stamped"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
