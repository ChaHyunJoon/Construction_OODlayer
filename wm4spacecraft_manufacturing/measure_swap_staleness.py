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
  *제안*이지 집행값이 아니므로 절대 쓰지 않는다(구세대에서 SwapBattery 카운트를 21% 부풀린다:
  324 vs 실제 267 — `count_courier.py` 참조).
- 병합 파일 `results_4pol/*.jsonl` (case 당 1개, 7개) 에도 `decisions[]` 가 그대로 실려 있음을
  확인했다 — 샤드 `rows.jsonl` 로 갈아탈 필요가 없어 브리핑 원안대로 병합 파일을 읽는다.
- `r.get("policy")`, `r.get("complete")`, `r.get("makespan")` 은 모두 실제 스키마에 존재하는
  키였다(수정 불필요).

방법론적 한계 (반드시 읽을 것): 판 하나에 배터리 결정 말고도 fault/reform/zone 결정이 섞여
있을 수 있다. 이 스크립트가 세는 완주율/makespan 은 "그 판 전체의 결과"이지 "그 배터리 결정
하나만의 결과"가 아니다 — 다른 결정이 판의 운명을 갈랐을 수 있다는 교란을 줄이려고
BATTERY_CASES 를 배터리가 실제로 낀 4개 case 로 제한했지만, 그 안에서도 case `all`·
`fault_battery`·`battery_zone` 은 여전히 다종 사건 판이다. 인과가 아니라 상관을 재는 도구다.
"""
import json, glob, collections, statistics, sys

BATTERY_CASES = {"battery", "all", "fault_battery", "battery_zone"}
by_arm = collections.defaultdict(lambda: {"n": 0, "complete": 0, "makespan": []})

for p in glob.glob("results_4pol/*.jsonl"):
    case = p.split("/")[-1][:-6]
    if case not in BATTERY_CASES:
        continue
    for line in open(p):
        r = json.loads(line)
        for d in (r.get("decisions") or []):
            if str(d.get("truth", "")).startswith("Battery"):
                key = (r.get("policy"), d.get("macro"))
                s = by_arm[key]
                s["n"] += 1
                if r.get("complete"):
                    s["complete"] += 1
                    if r.get("makespan"):
                        s["makespan"].append(r["makespan"])

print(f'{"policy":<11}{"macro":<15}{"n":>5}{"완주율":>9}{"makespan 중앙":>14}')
for (pol, mac), s in sorted(by_arm.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
    rate = s["complete"] / s["n"] if s["n"] else 0.0
    med = statistics.median(s["makespan"]) if s["makespan"] else float("nan")
    print(f"{str(pol):<11}{str(mac):<15}{s['n']:>5}{rate:>8.1%}{med:>14.1f}")

sw = by_arm.get(("surrogate", "SwapBattery"), {"n": 0})
rp = by_arm.get(("surrogate", "Replace"), {"n": 0})
print()
print(f"surrogate 배터리 결정: SwapBattery {sw['n']} · Replace {rp['n']}")
if sw["n"] == 0:
    print("→ surrogate 가 SwapBattery 를 한 번도 안 골랐다. 라벨 stale 문제가 아니라 "
          "지원집합/게이트 문제일 수 있다 — test_surrogate_support.py 를 볼 것.")
