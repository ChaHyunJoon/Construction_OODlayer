# 단계 7 준비 노트 — `energy_J = NaN` 은 막다른 길이 아니다 (2026-08-13)

**상태: 단계 7 은 보류됐다.** 이 문서는 그 단계를 재개할 사람이 읽을 조사 결과다. 아무 코드도
바꾸지 않았다.

## 무엇이 문제였나

spec §8 단계 7 은 surrogate 를 J 로 재라벨·재학습하라고 한다. 그런데 현행 배포 학습셋
`oracle/out/n44_plus78.jsonl` 의 라벨 격자는 이렇게 갈린다:

| kind | 라벨 행 수 | `energy_J` |
|---|---|---|
| `battery` | 179 | 유한 |
| `fault` | 75 | **NaN** |
| `zoneblk` | 32 | **NaN** |
| **합계** | **286** | **107행(37%)이 채점 불가** |

완주 분기의 J 는 `makespan + w_E·energy_J` 이므로, `energy_J` 가 NaN 인 행은 완주해도 J 가
정의되지 않는다(`Objective.J` 가 설계대로 던진다). 즉 라벨 격자의 37% 를 J 로 채점할 수 없다.

## CLAUDE.md 의 진술은 너무 거칠다

CLAUDE.md 의 "알려진 한계" 1번과 `gen_oracle_dataset.jl:1506-1510` 의 주석은 이렇게 적혀 있다:

> 그 kind 들에 배터리 레이어를 켜는 것은 **동작 변경**이라 이 계획의 범위 밖이다.

`_arm_battery!`(`gen_oracle_dataset.jl:1176`) **가 하는 일 전부**에 대해서는 맞는 말이다. 그 함수는
셋을 한꺼번에 켠다:

```julia
CB.enable_battery!(env; params = CB.demo_battery_params(shrink = 200.0))  # 용량 200× 축소
CB.set_battery_stall!(enabled = true, threshold = 0.15, ...)              # SoC<0.15 → 로봇 정지
CB.set_battery_derate!(enabled = true, hi = 0.5, min_factor = 0.35)       # SoC<0.5 → 감속
```

stall 과 derate 는 **명백한 동역학 변경**이다(로봇이 멈추고 느려진다).

**그러나 에너지 회계는 그 둘과 분리돼 있다.** `src/navigator/battery.jl` 의 실측:

- `:486` — 주석 그대로: **"Inert unless `set_battery_stall!(enabled=true)`; energy-only / nominal
  runs unaffected."**
- `:489` — `const BATTERY_STALL  = Ref((enabled = false, ...))` — **기본 꺼짐**
- `:539` — `const BATTERY_DERATE = Ref((enabled = false, ...))` — **기본 꺼짐**
- `:576` — `BATTERY_STALL[].enabled || return 1.0` — 꺼져 있으면 속도계수는 언제나 1.0(정상)
- `:689` — `install_soc_speed_hook!()` 은 "motion gate; **inert until** `set_battery_stall!(enabled=true)`"

즉 이 저장소는 **"energy-only" 모드를 이미 이름으로 가지고 있다**: `enable_battery!` 만 켜고
stall/derate 는 끈 상태. 그 모드에서 `battery_report(fl).total_energy_J` 는 나오고 동역학은
그대로다.

## 그래서 단계 7 의 선택지는 둘이 아니라 셋이다

| | J 로 채점 가능한 행 | fault/zoneblk 동역학 | 라벨 변화의 원인 |
|---|---|---|---|
| **A** — `_arm_battery!` 를 모든 kind 에 그대로 | 286/286 | **변함** (stall/derate) | 목적함수 **+** 동역학 (교락) |
| **B** — `battery` kind 만 재라벨 | 179/286 | 그대로 | 목적함수 |
| **C** — 비-battery kind 에 **energy-only** 계측만 | **286/286** | **그대로** | 목적함수 하나 |

**C 가 단계 7 을 교락 없이 성립시키는 유일한 선택지다.** A 는 라벨이 두 이유로 동시에 바뀌므로
"에너지를 목적함수에 넣으니 라벨이 이렇게 달라졌다"는 결론을 낼 수 없게 만든다. B 는 kind 마다
학습 타깃이 달라져 `audit_objective.py` 항목 8 의 유예를 닫지 못한다.

## C 를 실제로 켜기 전에 반드시 할 것

1. **동역학 불변을 실증한다 — 반드시 in-process A/B 로.**
   프로세스 간 골든 해시 비교는 이 저장소에서 **게이트가 될 수 없다**(CLAUDE.md Gotchas:
   바이트 동일한 소스도 재컴파일 후 다른 배정 지문을 냈다). 한 번 컴파일된 세션 **안에서는**
   결정적이므로, `test/greedy_cost_dispatch_equivalence.jl` 이 쓰는 것과 같은 패턴으로
   같은 instance 를 energy-only 켠 채 / 끈 채 연속 실행해 배정·tF 를 비교한다.
2. `shrink` 를 쓰지 않는다. `_arm_battery!` 의 `shrink=200.0` 은 용량을 줄여 소모를 눈에 보이게
   하려는 라벨러용 설정이다. stall/derate 가 꺼져 있으면 용량은 동역학을 게이팅하지 않지만,
   `total_energy_J` 는 한 일의 양이라 용량과 무관하므로 기본 파라미터로 켜는 것이 맞다.
3. 켜는 순간 **라벨 세대가 갈린다**. `objective_hash` 와 별개로 `gen_oracle_dataset.jl` 산출물에
   그 사실이 남아야 한다(에너지 계측 범위가 바뀐 것은 해시가 표현하지 못하는 축이다 —
   `energy_objective` 를 두 번째 축으로 둔 것과 같은 이유).

## 비용

부록 A 기준 12~20 시간. 재라벨 = 68 instance × 7 매크로 ≈ 476 full sim. 재학습 자체는 수 분.
게이트는 `test_surrogate_support.py` 재검증(7/7) + `audit_objective.py` 항목 8 의 유예 표식 해제.

## 확인 방법 (이 문서의 주장을 믿지 말고 다시 재라)

```bash
cd /home/chahj578/Construction_OODlayer
sed -n '479,500p;516,560p;570,580p' src/navigator/battery.jl     # stall/derate 기본값과 inert 주석
sed -n '1176,1190p' wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl   # _arm_battery! 가 켜는 셋
.venv/bin/python -c "
import json, collections
c = collections.Counter()
for line in open('wm4spacecraft_manufacturing/oracle/out/n44_plus78.jsonl'):
    line = line.strip()
    if line: c[json.loads(line).get('kind')] += 1
print(c)"                                                         # kind 별 라벨 행 수
```
