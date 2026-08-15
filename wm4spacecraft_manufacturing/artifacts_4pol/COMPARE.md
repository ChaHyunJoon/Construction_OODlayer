# 네 가지 제어기, 일곱 가지 실패 case

각 칸 — 위: 30 시드 중 완주한 판 수 · 아래: 완주판 평균 build time(sim 초) · 에너지(J/closed)

| FAILURE CASE | **DP**<br><sub>offline value-table lookup · NOT a ceiling (§8.7)</sub> | **CANONICAL**<br><sub>hand-written rule</sub> | **SURROGATE**<br><sub>random forest</sub> | **LLM**<br><sub>DSPy</sub> |
|---|---|---|---|---|
| Battery depletion | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **30/30**<br><sub>21.8 s · 311 J</sub> | **30/30**<br><sub>22.8 s · 338 J</sub> |
| Robot breakdown | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **28/30**<br><sub>26.1 s · 490 J</sub> |
| Keep-out zone | **30/30**<br><sub>56.4 s · 492 J</sub> | **30/30**<br><sub>56.4 s · 492 J</sub> | **30/30**<br><sub>39.0 s · 456 J</sub> | **30/30**<br><sub>30.9 s · 362 J</sub> |
| Breakdown + battery | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>23.3 s · 402 J</sub> | **28/30**<br><sub>24.5 s · 447 J</sub> |
| Breakdown + zone | **30/30**<br><sub>59.8 s · 656 J</sub> | **30/30**<br><sub>59.8 s · 656 J</sub> | **26/30**<br><sub>31.3 s · 624 J</sub> | **29/30**<br><sub>45.6 s · 577 J</sub> |
| Battery + zone | **30/30**<br><sub>59.8 s · 656 J</sub> | **30/30**<br><sub>59.8 s · 656 J</sub> | **28/30**<br><sub>35.1 s · 494 J</sub> | **30/30**<br><sub>36.8 s · 440 J</sub> |
| All three at once | **30/30**<br><sub>62.7 s · 733 J</sub> | **30/30**<br><sub>62.7 s · 733 J</sub> | **26/30**<br><sub>32.3 s · 595 J</sub> | **28/30**<br><sub>37.1 s · 537 J</sub> |

| 합계 (7 case) | 207/210 | 207/210 | 198/210 | 203/210 |
|---|---|---|---|---|

> **읽는 법.** `dp` 는 네 번째 주자가 아니라 **천장 후보**다 — 실행 가능한 온라인 정책이 아니다. 이 표의 DP 는 측정된 φ̃ 격자 위의 **진짜 Bellman backward induction** 이다(`V(goal)=0`, `Q(s,a)=mean[c + V(s')]`). 구간 비용 `c` 는 J 의 완주 분기 형태로 고정되고 두 분기의 차액은 종단에서 정산되며, 그 분해는 판마다 `Σc + terminal == J` 로 기계 검사된다. 자세한 정의와 한계는 `dp_oracle/dp_solve.py` 머리말과 `dp_oracle/value.json` 의 `known_limits`.

> build time 은 **완주한 판만** 평균한다(생존자 편향). 그래서 완주 0/30 인 칸은 `—` 다. J/closed 는 미완주 판에서도 정의되므로 그 칸에서도 남는다.

> **DP 격자 커버리지** 66 / 65 관측 칸 = 101.5% · a\* 미확정(동점) 24칸 · 전부 채점불가 0칸 · 단일팔 23칸.

> **원 설계 §8.7 gap (평균 대 평균, n≥3 인 (칸,정책) 쌍 121개; 비교 단위 = 그 칸부터의 **실현 cost-to-go**).** 실행 정책이 DP 의 V 보다 **좋은** 쌍 101개 = **83.5%**. 0 이 아니므로 이 표에서 **DP 열을 '천장' 이라 부르지 않는다.** 원인은 상수-팔이 아니다(V 는 진짜 backward induction 이다). 2026-08-15 실측에서 셋으로 갈렸다 — ① 표집 팔 메뉴에 실행 레인이 쓰는 매크로가 없는 축(ReformTeam) · ② φ̃ 추상화 손실 · ③ 전이 표본이 여전히 상수-팔 rollout 에서만 나온다는 구조적 한계. 쪼갠 수치는 `dp_oracle/gap_breakdown.py`, 해석은 `md/RESULTS_DP_BACKWARD_2026-08-15.md` §4-D. 다만 dp **레인**은 칸마다 a* 를 갈아 쓰므로 이 열의 실현 결과 자체는 유효한 실행 결과다.

> 목적함수 세대: `2026-08-13-global-kappa-precedence`. 지표는 `llm_ood_eval.py report` 가 계산한 값을 그대로 읽는다(이 스크립트는 배치만 한다).
