# 네 가지 제어기, 일곱 가지 실패 case

각 칸 — 위: 30 시드 중 완주한 판 수 · 아래: 완주판 평균 build time(sim 초) · 에너지(J/closed)

| FAILURE CASE | **DP**<br><sub>offline value-table lookup · NOT a ceiling (§8.7)</sub> | **CANONICAL**<br><sub>hand-written rule</sub> | **SURROGATE**<br><sub>random forest</sub> | **LLM**<br><sub>DSPy</sub> |
|---|---|---|---|---|
| Battery depletion | **—**<br><sub>이 레인은 스윕에 없음</sub> | **30/30**<br><sub>25.0 s · 400 J</sub> | **26/30**<br><sub>30.4 s · 438 J</sub> | **28/30**<br><sub>27.8 s · 405 J</sub> |
| Robot breakdown | **—**<br><sub>이 레인은 스윕에 없음</sub> | **30/30**<br><sub>25.0 s · 400 J</sub> | **30/30**<br><sub>25.0 s · 400 J</sub> | **29/30**<br><sub>24.9 s · 438 J</sub> |
| Keep-out zone | **—**<br><sub>이 레인은 스윕에 없음</sub> | **30/30**<br><sub>64.5 s · 535 J</sub> | **30/30**<br><sub>50.7 s · 529 J</sub> | **30/30**<br><sub>34.9 s · 406 J</sub> |
| Breakdown + battery | **—**<br><sub>이 레인은 스윕에 없음</sub> | **30/30**<br><sub>25.0 s · 400 J</sub> | **28/30**<br><sub>28.3 s · 447 J</sub> | **30/30**<br><sub>27.4 s · 385 J</sub> |
| Breakdown + zone | **—**<br><sub>이 레인은 스윕에 없음</sub> | **30/30**<br><sub>62.4 s · 679 J</sub> | **25/30**<br><sub>40.1 s · 716 J</sub> | **29/30**<br><sub>46.1 s · 600 J</sub> |
| Battery + zone | **—**<br><sub>이 레인은 스윕에 없음</sub> | **30/30**<br><sub>62.4 s · 679 J</sub> | **25/30**<br><sub>45.0 s · 623 J</sub> | **29/30**<br><sub>47.3 s · 538 J</sub> |
| All three at once | **—**<br><sub>이 레인은 스윕에 없음</sub> | **30/30**<br><sub>63.3 s · 748 J</sub> | **25/30**<br><sub>45.0 s · 708 J</sub> | **30/30**<br><sub>43.4 s · 542 J</sub> |

| 합계 (7 case) | — | 210/210 | 189/210 | 205/210 |
|---|---|---|---|---|

> **읽는 법.** `dp` 는 네 번째 주자가 아니라 **천장 후보**다 — 실행 가능한 온라인 정책이 아니다. 이 표의 DP 는 측정된 φ̃ 격자 위의 **진짜 Bellman backward induction** 이다(`V(goal)=0`, `Q(s,a)=mean[c + V(s')]`). 구간 비용 `c` 는 J 의 완주 분기 형태로 고정되고 두 분기의 차액은 종단에서 정산되며, 그 분해는 판마다 `Σc + terminal == J` 로 기계 검사된다. 자세한 정의와 한계는 `dp_oracle/dp_solve.py` 머리말과 `dp_oracle/value.json` 의 `known_limits`.

> build time 은 **완주한 판만** 평균한다(생존자 편향). 그래서 완주 0/30 인 칸은 `—` 다. J/closed 는 미완주 판에서도 정의되므로 그 칸에서도 남는다.

> dp 레인은 이번 스윕에 없다(`results_4pol/shards_dp` 없음) — §8.7 gap 은 **측정하지 않았다.** 위 dp 열이 전 case 에서 `이 레인은 스윕에 없음` 인 것과 같은 이유다. 과거 스윕의 gap 수치를 이어 붙이지 않는 이유는, 그 값이 다른 코드 세대의 `results_4pol/*.jsonl` 로 잰 것이라 지금 세대와 대면시키면 두 세대가 섞인 숫자가 되기 때문이다 — 빈 열을 보고 '천장이 닫혔다' 나 'gap 이 줄었다' 로 읽지 말 것.

> 목적함수 세대: `2026-08-13-global-kappa-precedence`. 지표는 `llm_ood_eval.py report` 가 계산한 값을 그대로 읽는다(이 스크립트는 배치만 한다).
