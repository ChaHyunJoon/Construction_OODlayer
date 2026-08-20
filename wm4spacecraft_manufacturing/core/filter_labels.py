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

**도장 (2026-08-19)**: 살아남는 행마다 `vocab`(= `action_registry.VOCAB`) 과
`dynamics`(행의 `hz_seed` 에서 **유도** — `_dynamics_from_row` 참조) 를 찍는다.
🔴 **`objective_hash` 는 안 건드린다** — 이 필터는 목적함수를 바꾸지 않았으므로 행이 이미
가진 (구세대) 해시가 그 행에 대한 참이다. 현행 해시로 갈아 끼우면 구세대 행이 신세대로
위장한다. 세 도장이 각각 무엇을 주장하는지는 `.claude/CLAUDE.md` §2026-08-19 의 표에 있다.

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


def _dynamics_from_row(row):
    """행이 **이미 나르는 증거**에서 동역학 도장을 유도한다 — 지어내지 않는다.

    `gen_oracle_dataset.jl` 은 행마다 `hz_seed` 를 낸다(`:1844`·`:2118`):
    `"hz_seed" => (hz_seed === nothing ? -1 : hz_seed)`. 그리고 `hz_seed` 가 non-nothing 인
    것은 `DS_MC_K > 1` 일 때뿐이고(`:1827`·`:2094`), `CB.enable_hazard!` 는 그때만 불린다
    (`:1025`·`:1361`). 따라서

        hz_seed == -1  <=>  HAZARD_ENABLED[] == false  <=>  dynamics_stamp() == "hazard-off"

    (`src/smdp/hazard.jl:155`·`:166`).

    🔴 `hz_seed` 가 없는 행에서는 **추측하지 않고 죽는다.** 동역학 도장을 짐작으로 찍으면
    이 도장이 막으려는 바로 그 실패(낡은 행이 신세대로 위장하는 것)를 이 함수가 만들게 된다.
    🔴 같은 이유로 이 필터는 `objective_hash` 를 **건드리지 않는다.** 행의 해시는 그 행을 만든
    런의 목적함수 세대이고, 필터는 목적함수를 바꾸지 않았다. 현행 해시로 갈아 끼우면 구세대
    행이 신세대 도장을 달게 된다(`.claude/CLAUDE.md` §2026-08-19). `vocab` 을 찍는 것은 다른
    경우다 — 이 필터가 은퇴 팔을 실제로 걷어내 그 행을 v2-6arms 에 **맞춰 놓았기** 때문이다."""
    if "hz_seed" not in row:
        raise AssertionError(
            "행에 hz_seed 가 없어 dynamics 를 유도할 수 없다 — 도장을 짐작으로 찍지 않는다. "
            "instance=%r" % (_instance_key(row),))
    return "hazard-off" if int(row["hz_seed"]) == -1 else "hazard-on"


def _strip_retired(valid_mask):
    """valid_mask(메뉴) 리스트에서 은퇴 id 를 뺀다. None/리스트가 아니면 그대로 둔다
    (`wm_datasets.py` 주석: valid_mask 가 없는 행은 사건 미발화 stub 이라 규약이 다르다)."""
    if not isinstance(valid_mask, list):
        return valid_mask
    return [m for m in valid_mask if int(m) not in RETIRED_MACROS]


def _instance_key(row):
    return row.get("instance_id", row.get("instance"))


def _instance_groups(rows):
    g = {}
    for row in rows:
        g.setdefault(_instance_key(row), []).append(row)
    return g


# instance-level 파생 집계 목록. 2026-08-20 derived-field sweep(task-6b-review)이 이 필드
# 하나만 필터로 낡는다는 것을 확인했다 — macro id 스캔이 못 잡은 이유는 이게 리스트가 아니라
# 정수 **집계**이기 때문.
#
# 🔴 **여기 이름을 추가하기 전에 읽을 것 (final-review D-1 이 지적한 함정).** 이 목록의 필드는
# 전부 **"그 instance 의 생존 행 수"** 라는 **한 가지** 뜻이어야 한다 — `_fix_cross_arm_aggregates`
# 가 전부 그 값으로 덮어쓰기 때문이다. 뜻이 다른 필드(예: "서로 다른 매크로 수", "완주한 팔 수")
# 를 여기 넣으면 필터가 그 필드를 **조용히 부순다**. 그래서 `_assert_aggregate_premise` 가
# **입력 데이터에서** 그 전제를 먼저 검사한다 — 뜻이 다른 필드는 실물에서 즉시 빨개진다.
CROSS_ARM_AGGREGATE_FIELDS = ("arms_labeled",)


def _fix_cross_arm_aggregates(kept):
    """arms_labeled 는 "그 instance 에서 실제로 라벨된 팔 수" = 그 instance 의 생존 행 수다.
    필터가 macro 5/6 행을 빼면 남은 행 수가 줄지만 이 필드는 필터 이전 값 그대로 남아
    낡는다(리뷰 실측: 65 instance/260행에서 6으로 낡음, 실제 생존 행은 4). kept 로 그룹화해
    다시 센다."""
    for group in _instance_groups(kept).values():
        n = len(group)
        for row in group:
            for f in CROSS_ARM_AGGREGATE_FIELDS:
                if f in row:
                    row[f] = n


def _assert_aggregate_premise(rows):
    """**필터를 걸기 전** 입력에서, 이 목록의 필드가 정말 "그 instance 의 행 수"인지 확인한다.

    `_fix_cross_arm_aggregates` 는 목록의 모든 필드를 생존 행 수로 덮어쓴다. 그러니 뜻이 다른
    필드가 목록에 들어오면 그 필드는 조용히 부서지고, 부순 값을 다시 세어 보는 어떤 사후 검사도
    그것을 **확인해 줄 뿐**이다(항진). 그 실패 모양을 막는 유일한 자리는 **덮어쓰기 이전의
    입력**이다 — 여기서 전제가 깨지면 그 필드는 애초에 이 목록에 있으면 안 되는 것이다."""
    for inst, group in _instance_groups(rows).items():
        n_in = len(group)
        for row in group:
            for f in CROSS_ARM_AGGREGATE_FIELDS:
                if f in row and row[f] != n_in:
                    raise AssertionError(
                        "CROSS_ARM_AGGREGATE_FIELDS 전제 위반 — instance %r 의 %s=%r 인데 "
                        "입력 행 수는 %d 다. 이 필드는 '그 instance 의 행 수'가 아니므로 "
                        "생존 행 수로 덮어쓰면 조용히 부서진다 — 목록에서 뺄 것."
                        % (inst, f, row[f], n_in))


def _surviving_counts_from_input(rows):
    """instance 별 생존 행 수를 **입력에서 따로 유도**한다: (입력 행 수) − (은퇴 id 로 버려질 행 수).

    🔴 요점은 `_fix_cross_arm_aggregates` 가 쓴 공식(`len(kept 그룹)`)을 **다시 부르지 않는
    것**이다. 이전 판의 사후 검사는 같은 공식을 다시 돌려 대조했으므로 "쓰기를 건너뛴 것"만
    잡을 수 있었고 **틀린 공식은 원리적으로 못 잡았다**(final-review D-1). 이 유도는 출력이
    아니라 입력을 보므로 공식이 틀리면 값이 갈린다."""
    seen, dropped = {}, {}
    for row in rows:
        inst = _instance_key(row)
        seen[inst] = seen.get(inst, 0) + 1
        if row.get("macro") in RETIRED_MACROS:
            dropped[inst] = dropped.get(inst, 0) + 1
    return {inst: n - dropped.get(inst, 0) for inst, n in seen.items()}


def _assert_cross_arm_aggregates_fresh(rows, kept):
    """`_fix_cross_arm_aggregates` 의 결과를 **독립적으로 유도한 기대값**과 전수 대조한다.
    기대값은 출력(`kept`)이 아니라 입력(`rows`)에서 나온다 — 위 `_surviving_counts_from_input`."""
    expected = _surviving_counts_from_input(rows)
    for row in kept:
        inst = _instance_key(row)
        n = expected[inst]
        for f in CROSS_ARM_AGGREGATE_FIELDS:
            if f in row and row[f] != n:
                raise AssertionError(
                    "cross-arm aggregate 부패 — instance %r: %s=%r 인데 입력에서 독립적으로 "
                    "유도한 생존 행 수는 %d 다" % (inst, f, row[f], n))


def filter_rows(rows):
    """(살아남은 행, 카운터). 행마다 vocab·dynamics 도장을 찍고 valid_mask 에서도 은퇴 id 를 뺀다.
    macro 컬럼은 remap 하지 않는다(존재하는 id 는 그대로, 존재하지 않아야 할 id 는 행째 drop).
    kept 확정 후 instance-level 파생 집계(`arms_labeled` 등)를 생존 행 수로 다시 센다 —
    macro id 스캔으로는 안 잡힌다(리스트가 아니라 정수 집계라서, task-6b-review 실측).

    보존 불변식: 입력 행은 kept 이거나 dropped_by_macro 에 세어지거나 — 제3의 길이 없다.
    이 assert 가 없으면 세지 않은 drop(예: 조건 없는 continue)이 자기정합적인 요약과 함께
    조용히 통과한다(task-6-review.md 2-c' 의 음성 대조가 실측한 그 실패 모양)."""
    _assert_aggregate_premise(rows)   # 덮어쓰기 **이전**에 전제부터 — 위 docstring 참조
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
        row["dynamics"] = _dynamics_from_row(row)
        kept.append(row)
    diag = {"kept": len(kept), "dropped_by_macro": dropped, "stamped": len(kept)}
    total_dropped = sum(dropped.values())
    if len(kept) + total_dropped != len(rows):
        raise AssertionError(
            "보존 불변식 위반 — kept(%d) + dropped(%d) != 입력(%d). 세지 않은 drop 이 있다."
            % (len(kept), total_dropped, len(rows)))
    _fix_cross_arm_aggregates(kept)
    _assert_cross_arm_aggregates_fresh(rows, kept)  # 전수 + **입력에서 독립 유도한** 기대값
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
    dyn = sorted({r["dynamics"] for r in kept})
    print("도장: vocab=%s · dynamics=%s (%d행). objective_hash 는 안 건드린다(구세대 행 그대로)."
          % (action_registry.VOCAB, "|".join(dyn), diag["stamped"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
