# 결과 — 세 제어기가 일곱 가지 실패 case 에 어떻게 대응하는가

> **이 문서가 현행 결과의 단일 진입점이다.** 7 case × 30 seed = 210판 × 3 레인.
> 원자료 `results_4pol/*.jsonl`, 생성 표 `artifacts_4pol/COMPARE.md`.
> 목적함수 세대 `2026-08-13-global-kappa-precedence`. 코드 세대 `3e492c21`.
>
> **baseline 은 `canonical` 이다. 검증된 천장(ceiling)은 현재 없다** — 아래 §4 참조.
> 이 문서 이전 판(E1–E4, 매크로 7·8 이전)은 git 이력에 있다.

---

## 1. 요약표

각 칸 — **완주 / 30** · 완주판 평균 build time(sim 초) · 에너지(J/closed)

| # | FAILURE CASE | **CANONICAL**<br><sub>손으로 쓴 규칙</sub> | **SURROGATE**<br><sub>random forest</sub> | **LLM**<br><sub>DSPy · gpt-4o</sub> |
|---|---|---|---|---|
| 1 | Battery depletion | 29/30 · 26.0 s · 451 J | **30/30 · 21.8 s · 311 J** | 30/30 · 22.8 s · 338 J |
| 2 | Robot breakdown | **29/30 · 26.0 s · 451 J** | **29/30 · 26.0 s · 451 J** | 28/30 · 26.1 s · 490 J |
| 3 | Keep-out zone | 30/30 · 56.4 s · 492 J | 30/30 · 39.0 s · 456 J | **30/30 · 30.9 s · 362 J** |
| 4 | Breakdown + battery | 29/30 · 26.0 s · 451 J | **29/30 · 23.3 s · 402 J** | 28/30 · 24.5 s · 447 J |
| 5 | Breakdown + zone | **30/30** · 59.8 s · 656 J | 26/30 · 31.3 s · 624 J | 29/30 · 45.6 s · 577 J |
| 6 | Battery + zone | **30/30** · 59.8 s · 656 J | 28/30 · 35.1 s · 494 J | **30/30 · 36.8 s · 440 J** |
| 7 | All three at once | **30/30** · 62.7 s · 733 J | 26/30 · 32.3 s · 595 J | 28/30 · 37.1 s · 537 J |
| | **합계** | **207/210** | 198/210 | 203/210 |

**정지(`n_stalled`)는 세 레인 · 전 case 에서 0회다.**

---

## 2. 무엇을 집행했나 — 같은 case 에서 세 레인이 다른 행동을 한다

완주율만 보면 안 되는 이유가 여기 있다. 아래는 case 별로 각 레인이 실제로 집행한 매크로
(상위 3개, 210판 합산). 출처는 `results_4pol/*.jsonl` 의 결정 행 `macro` 필드다.

| # | CASE | CANONICAL | SURROGATE | LLM |
|---|---|---|---|---|
| 1 | Battery depletion | Replace×120 · ReformTeam×17 | **SwapBattery×72** · Replace×48 | Replace×75 · **SwapBattery×45** |
| 2 | Robot breakdown | Replace×120 · ReformTeam×17 | Replace×120 · ReformTeam×17 | Replace×119 · ReformTeam×29 |
| 3 | Keep-out zone | ReformTeam×150 · NOOP×120 | **RelocateBuild×104** · ReformTeam×50 | NOOP×70 · **RelocateBuild×50** |
| 4 | Breakdown + battery | Replace×120 · ReformTeam×17 | Replace×89 · **SwapBattery×31** | Replace×95 · ReformTeam×28 |
| 5 | Breakdown + zone | ReformTeam×153 · Replace×60 · NOOP×60 | ReformTeam×61 · Replace×58 · **RelocateBuild×55** | ReformTeam×99 · Replace×59 · NOOP×39 |
| 6 | Battery + zone | ReformTeam×153 · Replace×60 · NOOP×60 | ReformTeam×58 · **RelocateBuild×54** · SwapBattery×34 | ReformTeam×64 · NOOP×40 · Replace×37 |
| 7 | All three at once | ReformTeam×164 · Replace×81 · NOOP×39 | ReformTeam×75 · Replace×52 · **RelocateBuild×33** | ReformTeam×76 · Replace×68 · RelocateBuild×21 |

**읽는 법 세 가지:**

1. **case 3(zone) 이 세 레인을 가장 크게 가른다.** canonical 은 `NOOP` 을 120회 집행하고
   그 대가로 `ReformTeam` 을 150회 불러 **56.4초**가 든다. surrogate·LLM 은 `RelocateBuild`
   를 써서 각각 39.0초 · **30.9초** 로 끝낸다 — canonical 대비 **55%** 다.
   완주율은 셋 다 30/30 이라 **완주율만 보면 이 대비가 통째로 안 보인다.**
2. **case 2(fault) 에서 surrogate 는 canonical 과 바이트 수준으로 같다** (Replace×120 ·
   ReformTeam×17 · 26.0 s · 451 J). 그 사건에서는 학습된 정책이 손으로 쓴 규칙을 재현할 뿐
   더 내지 못한다. LLM 은 `ReformTeam` 을 29회로 더 부르고 그만큼 느리고(26.1 s) 비싸다(490 J).
3. **case 1(battery) 에서 `SwapBattery` 를 아는 레인만 이긴다.** surrogate 가 72회로 가장 많이
   쓰고 유일하게 30/30 · 21.8 s · **311 J**(canonical 대비 −31%) 를 낸다. canonical 은 그 팔을
   한 번도 안 쓴다.

---

## 3. 조합 case 에서 갈리는 지점 — 완주 대 비용의 맞교환

사건이 둘 이상인 네 case(#4·#5·#6·#7, 판 120개)만 따로 집계하면:

| 기준 (조합 4 case · 판 120개) | CANONICAL | SURROGATE | LLM |
|---|---|---|---|
| 완주 | **119/120** | 109/120 | 115/120 |
| build time (판 가중 평균, 완주판) | 52.3 s | **30.4 s** | 36.1 s |
| J/closed (판 가중 평균) | 624 J | 529 J | **500 J** |

**세 레인의 순위가 지표마다 뒤집힌다** — canonical 이 완주에서 1위, surrogate 가 시간에서
1위, LLM 이 에너지에서 1위다. canonical 은 30/30 을 지키는 대신 **surrogate 보다 72% 오래
걸리고 18% 많은 에너지를 쓴다.** surrogate 는 절반 시간에 끝내지만 **완주를 10판 잃는다.**

**단일 지표로 "누가 이겼다" 를 말할 수 없다는 것이 이 표의 결론이다.**
어느 것을 고를지는 미완주 1판의 비용이 build time 22초보다 큰가에 달려 있고, 그것은
목적함수가 정한다 — `objective.json` 의 `C_fail`(10000) 이 그 답을 이미 갖고 있다.

---

## 4. baseline 과 ceiling — 지금 무엇을 기준으로 삼을 수 있나

**baseline = `canonical`.** 7 case 전부에서 돌고 207/210 완주하며, 다른 두 레인이 그것에
대해 상대적으로 측정된다.

**검증된 ceiling 은 현재 없다.** 두 후보가 다 못 쓴다:

- **DP 값표**(`dp_oracle/value.json`) — 천장이 아니다. 실행 정책의 실현 cost-to-go 가 DP 의
  `V` 보다 **좋은** (칸,정책) 쌍이 **101/121 = 83.5%** 다. 게다가 표가 확정한 19칸이 **전부
  `Replace` 하나**로 붕괴했고(구세대는 17칸이 세 매크로에 걸쳐 있었다), 그 결과 dp 레인 210판이
  canonical 과 완전히 동일하다. 경위와 남은 원인은
  **`md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md`**.
- **Oracle 라벨 격자** — 조합 case 를 다루지 못한다. 격자의 kind 는
  `fault 405 · battery 240 · zoneblk 160 · reform 67` 로 **전부 단일 사건**이고,
  `results_matrix.py:44` 의 `ORACLE_KIND` 에 조합 키가 없다(사건이 섞이면 단일-종류 격자가
  성립하지 않는다). 따라서 **7 case 중 4개(#4·#5·#6·#7)에 oracle 칸이 아예 없다.**
  남은 3개도 지금은 못 쓴다 — 천장 행이 전부 **미측정**이다(`energy_J` 없어 J 채점 불가:
  battery 18 · fault 22 · zone 2 instance). fault 격자는 instance 1개인데 두 팔 다 미완주이고,
  zone 격자는 NOOP 과 RelocateBuild 가 정확히 동점이다(n=2).

**그러므로 이 표는 "천장 대비 몇 %" 가 아니라 "canonical 대비 어떻게 다른가" 로 읽어야 한다.**

---

## 5. 재현

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
export DSPY_URL=http://127.0.0.1:8090      # :8090 이 떠 있어야 한다
nohup bash run_4pol_parallel.sh --jobs 50 > /tmp/sweep.log 2>&1 &
bash finish_tables.sh                       # -> artifacts_4pol/COMPARE.md
```

§1·§2 의 수치는 `results_4pol/*.jsonl` 에서 직접 재집계해 검증했다 — 28칸 + 4합계 일치.

---

## 6. 더 읽을 것

| 무엇을 알고 싶은가 | 어디를 볼 것인가 |
|---|---|
| 함정 · 용어 · 철회된 결론 | `md/README.md` §1 · §6 · §7 · §8 |
| DP 가 왜 천장이 아닌가 | `md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md` |
| 행동 어휘가 어떻게 닫혔나 | `md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md` |
| 현재 상태 · 재개 지점 | `md/STATUS.md` |
| 세대 판정 계약 | `.claude/CLAUDE.md` §★ 결과 세대 |
