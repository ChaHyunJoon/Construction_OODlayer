#!/usr/bin/env python3
"""
surrogate 가 배터리 사건에서 SwapBattery 를 고른 판과 Replace 를 고른 판의 **결과**를 가른다.

왜: 배포 모델은 SwapBattery 가 시간을 안 쓰던 시절 라벨로 학습됐다. 배송이 붙은 뒤에도 같은
빈도로 그 팔을 고른다면, 그 선택이 이제 손해인지 이득인지가 다음 사이클의 결정 근거다.
이 스크립트는 **재학습하지 않는다** — 재학습이 필요한지를 판정할 숫자만 만든다.

스키마 정정 (2026-08-16, task-7 실행 시 확인):
- 브리핑 초안은 `results_4pol/*.jsonl` 행의 `decisions[]` 원소에 `truth_type` 키가 있다고
  가정했다. 실제 키 이름은 **`truth`** 다(`truth_type` 은 존재하지 않는다). 값은 그대로
  `"BatteryTruth"` 형태라 `str(...).startswith("Battery")` 필터 로직은 유효하고 키 이름만 고쳤다.
  확인 방법:
    .venv/bin/python -c "
    import json; r=json.loads(open('results_4pol/battery.jsonl').readline())
    print(sorted(r)); print(json.dumps((r.get('decisions') or [{}])[0], ensure_ascii=False)[:400])"
- `macro` 는 그대로 맞다 — 그것이 **집행된(enacted) 매크로**다. `decisions[].llm` 은 LLM 의
  *제안*이지 집행값이 아니므로 절대 쓰지 않는다.
  ★ 2026-08-16 정정 — 예전 판의 "**21% 부풀린다**(324 vs 267)" 는 이 세대의 값이 아니고,
  더 중요하게는 **부풀린다는 방향 자체가 레인마다 다르다**. 이번 배송 세대에서 실측하면:
    · 전체 집계: `llm` **329** vs 집행 `macro` **277** = **+18.8%** (부풀림)
    · **surrogate 레인만**: `llm` **102** vs 집행 `macro` **165** — 오히려 **적게 센다**
      (`llm` 은 `dspy_service` 가 낸 제안이고 surrogate 의 집행과는 다른 레인이라, 이 레인에서는
      `llm` 을 쓰면 이 스크립트의 주제인 SwapBattery 선택이 38% **누락**된다).
  즉 `llm` 을 쓰면 안 되는 이유는 "일정 비율로 부풀어서" 가 아니라 **다른 것을 재기 때문**이다.
  (`llm` 은 canonical 레인에서도 115 를 세는데 canonical 은 SwapBattery 를 한 번도 집행하지
  않는다 — 그것이 이 필드가 집행값이 아니라는 가장 짧은 증거다.)
  재현: `.superpowers/sdd/2026-08-15-swapbattery-courier-resweep/count_courier.py`(미커밋) 또는
  이 스크립트가 마지막에 찍는 `llm 필드 대조` 절.
- 병합 파일 `results_4pol/*.jsonl` (case 당 1개, 7개) 에도 `decisions[]` 가 그대로 실려 있음을
  확인했다 — 샤드 `rows.jsonl` 로 갈아탈 필요가 없어 브리핑 원안대로 병합 파일을 읽는다.
- `r.get("policy")`, `r.get("complete")`, `r.get("makespan")` 은 모두 실제 스키마에 존재하는
  키였다(수정 불필요).

방법론적 한계 (반드시 읽을 것): 판 하나에 배터리 결정 말고도 fault/reform/zone 결정이 섞여
있을 수 있다. 이 스크립트가 세는 완주율/makespan 은 "그 판 전체의 결과"이지 "그 배터리 결정
하나만의 결과"가 아니다 — 다른 결정이 판의 운명을 갈랐을 수 있다는 교란을 줄이려고
BATTERY_CASES 를 배터리가 실제로 낀 4개 case 로 제한했지만, 그 안에서도 case `all`·
`fault_battery`·`battery_zone` 은 여전히 다종 사건 판이다. 인과가 아니라 상관을 재는 도구다.

★★ 2026-08-16 (수정 라운드) — **결정 가중과 판 가중을 섞지 말 것. 여기서 실제로 새어 나갔다.**

  §A 표의 `n` 은 **결정 수**이지 판 수가 아니다. 그런데 그 옆의 `완주율`·`makespan 중앙` 은
  **판의 결과**다. 즉 이 표는 "판 하나의 결과를 그 판이 그 팔을 고른 횟수만큼 반복해서 센다."
  귀결이 크다 — 이 세대에서:
    · 결정 가중 완주율 격차(SwapBattery − Replace) = **−8.3pp**
    · 판 가중 완주율 격차                          = **−1.8pp**
  같은 데이터인데 4.6배 차이다. **−8.3pp 는 효과 크기가 아니라 가중 아티팩트다.**

  두 개의 독립된 메커니즘이 그것을 만든다:
   ① **한 판이 두 팔을 다 쓴다.** surrogate 의 120판 중 **52판**이 SwapBattery 와 Replace 를
      둘 다 집행한다. "≥1 SwapBattery ⇒ SwapBattery 판" 같은 판 분류 규칙을 쓰면 그 52판이
      통째로 SwapBattery 쪽으로 가고 Replace 쪽 n 이 18판으로 쪼그라든다. 결정 가중으로 두면
      그 52판은 **같은 하나의 결과를 양쪽 버킷에 동시에 넣는다** — SwapBattery 결정의 56%,
      Replace 결정의 79% 가 거기서 나온다. 그 안에서 잰 "격차" 는 구성상 아티팩트다.
   ② **판당 결정 수가 팔마다 다르다.** 미완주 판이 결정을 더 많이 내면 그 판의 실패가
      여러 번 세어진다.

  그래서 이 스크립트는 이제 **세 가지 가중을 나란히 찍는다**: §A 결정 가중(비교용으로 남긴다,
  이제 `n(결정)` 이라고 이름표를 단다) · §B 판 가중 · §C 시드 짝 대조. 하나만 인용하지 말 것.

★★ §C — **canonical 이 시드 짝 baseline 이다(이 측정에서 가장 강한 설계).**
  세 레인이 **같은 `(case, seed)`** 를 돌고, canonical 은 SwapBattery 를 **한 번도** 집행하지
  않는다(실측 0회). 그래서 같은 시드의 canonical 판은 "SwapBattery 를 안 골랐다면" 의 실제
  실현이다 — 짝지어 빼면 case 난이도·시드 난이도가 소거된다.
  ⚠️ 그러나 **짝을 그냥 풀링하면 안 된다.** zone 이 낀 case 에서는 surrogate 가 zone 결정에서도
  canonical 과 갈리고 그 차이가 배터리 차이보다 자릿수가 크다(실측: `battery_zone` 의 Δ 중앙이
  두 팔 모두 −27~−28 s). 그래서 §C 는 **case 로 층화**하고, zone 이 안 낀 두 case
  (`battery`·`fault_battery`)에서 **판당 SwapBattery 집행 횟수별 용량-반응**을 찍는다.
  그 층에서 집행 0회 판은 Δ 가 **정확히 0.00** 이다(= surrogate 가 canonical 과 같은 팔만
  고르면 궤적이 바이트 동일하다). 그것이 이 대조의 내부 통제다 — 0 이 아닌 Δ 는 갈린 선택에
  귀속된다.
"""
import json, glob, collections, statistics, sys

BATTERY_CASES = {"battery", "all", "fault_battery", "battery_zone"}
# zone 이 안 낀 두 case — §C 의 용량-반응은 여기서만 읽는다(docstring §C 의 ⚠️ 참조).
ZONE_FREE = ("battery", "fault_battery")

rows = []
for p in glob.glob("results_4pol/*.jsonl"):
    case = p.split("/")[-1][:-6]
    if case not in BATTERY_CASES:
        continue
    for line in open(p):
        r = json.loads(line)
        r["_case"] = case
        rows.append(r)


def bat_decisions(r):
    """그 판의 **배터리 진실**에 대한 결정들. `truth` 가 맞는 키다(docstring 스키마 정정)."""
    return [d for d in (r.get("decisions") or [])
            if str(d.get("truth", "")).startswith("Battery")]


def arms_of(r):
    return {d.get("macro") for d in bat_decisions(r)}


def n_swap(r):
    return sum(1 for d in bat_decisions(r) if d.get("macro") == "SwapBattery")


def med(xs):
    return statistics.median(xs) if xs else float("nan")


# 시드 짝의 키. `world_seed` 는 이 스윕에서 상수(1)이지만 키에 넣어 둔다 — 나중에 갈리면
# 조용히 잘못 짝지어지는 것을 막는다.
def seed_key(r):
    return (r["_case"], r.get("world_seed"), r.get("ood_seed"))


# ================= §A. 결정 가중 (기존 표 — n 의 이름표만 고쳤다) =====================
by_arm = collections.defaultdict(lambda: {"n": 0, "complete": 0, "makespan": []})
for r in rows:
    for d in bat_decisions(r):
        s = by_arm[(r.get("policy"), d.get("macro"))]
        s["n"] += 1
        if r.get("complete"):
            s["complete"] += 1
            if r.get("makespan"):
                s["makespan"].append(r["makespan"])

print("§A. 결정 가중 — 🔴 n 은 **결정 수**이지 판 수가 아니다.")
print("    완주율/makespan 은 **판**의 결과이므로, 이 표는 한 판의 결과를 그 판이 그 팔을")
print("    고른 횟수만큼 반복해서 센다. 효과 크기로 인용하지 말 것(§B 를 볼 것).")
print(f'{"policy":<11}{"macro":<15}{"n(결정)":>9}{"완주율":>9}{"makespan 중앙":>14}')
for (pol, mac), s in sorted(by_arm.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
    rate = s["complete"] / s["n"] if s["n"] else 0.0
    print(f"{str(pol):<11}{str(mac):<15}{s['n']:>9}{rate:>8.1%}{med(s['makespan']):>14.1f}")

sw = by_arm.get(("surrogate", "SwapBattery"), {"n": 0})
rp = by_arm.get(("surrogate", "Replace"), {"n": 0})
print()
print(f"surrogate 배터리 **결정**: SwapBattery {sw['n']} · Replace {rp['n']}")
if sw["n"] == 0:
    print("→ surrogate 가 SwapBattery 를 한 번도 안 골랐다. 라벨 stale 문제가 아니라 "
          "지원집합/게이트 문제일 수 있다 — test_surrogate_support.py 를 볼 것.")
    sys.exit(0)

# ================= §B. 판 가중 =========================================================
print()
print("=" * 78)
print("§B. 판 가중 — 같은 데이터를 **판 하나 = 관측 하나**로 다시 센다.")
for pol in ("surrogate", "dspy"):
    lane = [r for r in rows if r.get("policy") == pol]
    withbat = [r for r in lane if bat_decisions(r)]
    sw_any = [r for r in withbat if "SwapBattery" in arms_of(r)]
    sw_only = [r for r in withbat if arms_of(r) == {"SwapBattery"}]
    rp_only = [r for r in withbat if arms_of(r) == {"Replace"}]
    mixed = [r for r in withbat if {"SwapBattery", "Replace"} <= arms_of(r)]

    def rate(bs):
        k = sum(1 for r in bs if r.get("complete"))
        return k, len(bs), (k / len(bs) if bs else float("nan"))

    print(f"\n  [{pol}] 전체 {len(lane)}판 · 배터리 결정이 있는 판 {len(withbat)}")
    a, b = rate(sw_any), rate(rp_only)
    c = rate(sw_only)
    print(f"    규칙 '≥1 SwapBattery ⇒ SwapBattery 판':")
    print(f"      SwapBattery {a[0]}/{a[1]} = {a[2]:.1%}   Replace {b[0]}/{b[1]} = {b[2]:.1%}"
          f"   격차 {100*(a[2]-b[2]):+.1f}pp")
    print(f"    한 팔만 쓴 판으로 제한:")
    print(f"      SwapBattery {c[0]}/{c[1]} = {c[2]:.1%}   Replace {b[0]}/{b[1]} = {b[2]:.1%}"
          f"   격차 {100*(c[2]-b[2]):+.1f}pp")
    print(f"      makespan 중앙(완주판, 판 단위): SwapBattery "
          f"{med([r['makespan'] for r in sw_only if r.get('complete')]):.1f}"
          f" · Replace {med([r['makespan'] for r in rp_only if r.get('complete')]):.1f}")
    # 혼합 판이 결정 가중을 어떻게 오염시키는가 — 숫자로 남긴다.
    msw = sum(1 for r in mixed for d in bat_decisions(r) if d.get("macro") == "SwapBattery")
    mrp = sum(1 for r in mixed for d in bat_decisions(r) if d.get("macro") == "Replace")
    tsw = by_arm[(pol, "SwapBattery")]["n"]
    trp = by_arm[(pol, "Replace")]["n"]
    print(f"    🔴 두 팔을 다 쓴 판 **{len(mixed)}개** — 이 판들은 같은 하나의 결과를 양쪽에 넣는다:")
    print(f"       SwapBattery 결정의 {msw}/{tsw} = {msw/tsw:.0%} · "
          f"Replace 결정의 {mrp}/{trp} = {mrp/trp:.0%} 가 여기서 나온다.")
    # case-mix 교란이 어느 쪽에 유리한가 — 방향을 주장하지 말고 계산한다.
    bycase = collections.defaultdict(list)
    for r in lane:
        bycase[r["_case"]].append(r)
    caserate = {k: sum(1 for r in v if r.get("complete")) / len(v) for k, v in bycase.items()}
    print("    case 별 판 완주율: " + " · ".join(
        f"{k} {v:.1%}" for k, v in sorted(caserate.items())))
    for nm, bs in (("Replace", rp_only), ("SwapBattery(≥1)", sw_any), ("SwapBattery 순수", sw_only)):
        exp = sum(caserate[r["_case"]] for r in bs) / len(bs) if bs else float("nan")
        dist = dict(collections.Counter(r["_case"] for r in bs))
        print(f"      {nm:<16} case 분포 {dist} → case-mix 기대 baseline {exp:.1%}")
    print("      ↑ 두 baseline 이 비슷하면 case-mix 교란은 **중립**이다 — "
          "'교란이 판정을 강화한다'고 쓰지 말 것.")

# ================= §C. 시드 짝 canonical 대조 ==========================================
print()
print("=" * 78)
print("§C. 시드 짝 대조 — canonical 을 같은 (case, seed) 의 baseline 으로 쓴다.")
canon = {seed_key(r): r for r in rows if r.get("policy") == "canonical"}
n_canon_swap = sum(1 for r in rows if r.get("policy") == "canonical"
                   for d in bat_decisions(r) if d.get("macro") == "SwapBattery")
print(f"  canonical 이 집행한 SwapBattery: **{n_canon_swap}회** "
      f"— 0 이어야 이 대조가 성립한다(0 이 아니면 아래를 인용하지 말 것).")

for pol in ("surrogate", "dspy"):
    lane = [r for r in rows if r.get("policy") == pol]
    withbat = [r for r in lane if bat_decisions(r)]
    sw_only = [r for r in withbat if arms_of(r) == {"SwapBattery"}]
    rp_only = [r for r in withbat if arms_of(r) == {"Replace"}]
    print(f"\n  [{pol}] 완주 — 같은 시드에서 두 레인을 나란히:")
    for nm, bs in (("SwapBattery 만 쓴 시드", sw_only), ("Replace 만 쓴 시드", rp_only)):
        k = sum(1 for r in bs if r.get("complete"))
        ck = sum(1 for r in bs if canon[seed_key(r)].get("complete"))
        print(f"    {nm:<22} n={len(bs):>3}   {pol} {k}/{len(bs)}   canonical {ck}/{len(bs)}")

    print(f"  [{pol}] makespan Δ(= {pol} − 같은 시드 canonical), case 로 층화, 양쪽 완주한 짝만:")
    for case in sorted(BATTERY_CASES):
        def deltas(bs):
            out = []
            for r in bs:
                c = canon[seed_key(r)]
                if r["_case"] == case and r.get("complete") and c.get("complete"):
                    out.append(r["makespan"] - c["makespan"])
            return out
        x, y = deltas(sw_only), deltas(rp_only)
        fx = f"{med(x):+7.2f}(n={len(x)})" if x else "       —"
        fy = f"{med(y):+7.2f}(n={len(y)})" if y else "       —"
        print(f"    {case:<14} SwapBattery {fx:>16}   Replace {fy:>16}")
    print("    ⚠️ zone 이 낀 case 는 zone 결정 차이가 배터리 차이를 압도한다 — 풀링 금지.")

    print(f"  [{pol}] 🔴 **용량-반응** — zone 이 안 낀 {ZONE_FREE} 만, 판당 SwapBattery 집행 횟수별:")
    buckets = collections.defaultdict(list)
    for r in lane:
        if r["_case"] not in ZONE_FREE or not bat_decisions(r):
            continue
        c = canon[seed_key(r)]
        if r.get("complete") and c.get("complete"):
            buckets[min(n_swap(r), 3)].append(r["makespan"] - c["makespan"])
    for k in sorted(buckets):
        lbl = f"{k}+" if k == 3 else str(k)
        print(f"    SwapBattery {lbl:>2}회 → Δmakespan 중앙 {med(buckets[k]):+6.2f} s "
              f"(n={len(buckets[k])})")
    if 0 in buckets:
        z = [d for d in buckets[0] if d != 0.0]
        print(f"    ↑ 내부 통제: 집행 0회 판 {len(buckets[0])}개 중 Δ≠0 인 판 **{len(z)}개** "
              f"— 0 이면 같은 팔을 고른 판은 궤적이 바이트 동일하다는 뜻이고, "
              f"0 이 아닌 Δ 는 갈린 선택에 귀속된다.")

# ================= §D. llm 필드 대조 (docstring 의 정정 근거) ==========================
print()
print("=" * 78)
print("§D. `decisions[].llm` 은 집행값이 아니다 — 레인마다 방향이 다르다.")
print(f'{"policy":<12}{"집행 macro":>11}{"llm 제안":>10}{"차":>10}')
for pol in ("canonical", "surrogate", "dspy", None):
    sel = rows if pol is None else [r for r in rows if r.get("policy") == pol]
    m = sum(1 for r in sel for d in bat_decisions(r) if d.get("macro") == "SwapBattery")
    l = sum(1 for r in sel for d in bat_decisions(r) if d.get("llm") == "SwapBattery")
    print(f'{(pol or "전체 합"):<12}{m:>11}{l:>10}{(f"{(l-m)/m:+.1%}" if m else "n/a"):>10}')

# ================= §E. 선택 편향의 방향 ================================================
# "SwapBattery 판이 더 나쁜 것은 애초에 더 위태로운 상태에서 골라서다" 라는 대안 설명을
# 배제하려면 **선택 시점의 상태**를 봐야 한다. 방향을 주장하지 말고 계산한다.
print()
print("=" * 78)
print("§E. 선택 시점의 상태 — 어느 팔이 더 위태로운 판에서 불려 나오나(결정 단위).")
print(f'{"policy":<12}{"macro":<14}{"n":>5}{"soc 중앙":>10}{"soc 평균":>10}{"progress 중앙":>14}')
for pol in ("surrogate", "dspy"):
    for arm in ("SwapBattery", "Replace"):
        ds = [d for r in rows if r.get("policy") == pol
              for d in bat_decisions(r) if d.get("macro") == arm]
        socs = [d["soc"] for d in ds if d.get("soc") is not None]
        progs = [d["progress"] for d in ds if d.get("progress") is not None]
        if not ds:
            continue
        print(f'{pol:<12}{arm:<14}{len(ds):>5}{med(socs):>10.2f}'
              f'{(statistics.mean(socs) if socs else float("nan")):>10.2f}{med(progs):>14.2f}')
print("  ↑ SwapBattery 의 soc 가 Replace 보다 **높으면**, 그 팔은 덜 위태로운 상태에서")
print("    불려 나오고도 결과가 나쁘다는 뜻이다 — 선택 편향은 판정을 약화시키지 않는다.")
