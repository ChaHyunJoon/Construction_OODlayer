# 네 가지 제어기, 일곱 가지 실패 case

각 칸 — 위: 30 시드 중 완주한 판 수 · 아래: 완주판 평균 build time(sim 초) · 에너지(J/closed)

| FAILURE CASE | **DP**<br><sub>offline value-table lookup · NOT a ceiling (§8.7)</sub> | **CANONICAL**<br><sub>hand-written rule</sub> | **SURROGATE**<br><sub>random forest</sub> | **LLM**<br><sub>DSPy</sub> |
|---|---|---|---|---|
| Battery depletion | **30/30**<br><sub>19.6 s · 265 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **30/30**<br><sub>19.6 s · 261 J</sub> |
| Robot breakdown | **30/30**<br><sub>19.6 s · 264 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **26/30**<br><sub>32.4 s · 599 J</sub> |
| Keep-out zone | **29/30**<br><sub>27.4 s · 426 J</sub> | **30/30**<br><sub>56.4 s · 492 J</sub> | **30/30**<br><sub>28.8 s · 418 J</sub> | **30/30**<br><sub>28.6 s · 390 J</sub> |
| Breakdown + battery | **30/30**<br><sub>19.6 s · 264 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **28/30**<br><sub>24.0 s · 394 J</sub> |
| Breakdown + zone | **29/30**<br><sub>22.9 s · 350 J</sub> | **30/30**<br><sub>59.8 s · 656 J</sub> | **26/30**<br><sub>26.9 s · 597 J</sub> | **26/30**<br><sub>37.9 s · 639 J</sub> |
| Battery + zone | **29/30**<br><sub>22.9 s · 352 J</sub> | **30/30**<br><sub>59.8 s · 656 J</sub> | **26/30**<br><sub>26.9 s · 597 J</sub> | **30/30**<br><sub>25.1 s · 334 J</sub> |
| All three at once | **29/30**<br><sub>21.4 s · 319 J</sub> | **30/30**<br><sub>62.7 s · 733 J</sub> | **21/30**<br><sub>25.5 s · 789 J</sub> | **28/30**<br><sub>32.3 s · 468 J</sub> |

| 합계 (7 case) | 206/210 | 207/210 | 190/210 | 198/210 |
|---|---|---|---|---|

> **읽는 법.** `dp` 는 네 번째 주자가 아니라 **천장**이다 — 실행 가능한 온라인 정책이 아니고, 이 표의 DP 는 상수-팔 반사실 표집의 최선이다(backward induction 이 아니다: 이 하니스는 J 를 판 단위로 낸다). 자세한 정의와 한계는 `dp_oracle/dp_solve.py` 머리말과 `dp_oracle/value.json` 의 `known_limits`.

> build time 은 **완주한 판만** 평균한다(생존자 편향). 그래서 완주 0/30 인 칸은 `—` 다. J/closed 는 미완주 판에서도 정의되므로 그 칸에서도 남는다.

> **DP 격자 커버리지** 64 / 65 관측 칸 = 98.5% · a\* 미확정(동점) 9칸 · 전부 채점불가 0칸 · 단일팔 16칸.

> **원 설계 §8.7 gap (평균 대 평균, n≥3 인 (칸,정책) 쌍 121개).** 실행 정책의 평균 J 가 DP 의 V 보다 **좋은** 쌍 108개 = **89.3%**. 0 이 아니므로 이 표에서 **DP 열을 '천장' 이라 부르지 않는다.** V 는 상수-팔 표집에서 나오는데 사건이 섞인 판을 한 팔로 처리할 수 없어 그 정책군이 실행 레인보다 약하기 때문이다. 다만 dp **레인**은 칸마다 a* 를 갈아 쓰므로 이 열의 실현 결과 자체는 유효한 실행 결과다.

> 목적함수 세대: `2026-08-13-global-kappa-precedence`. 지표는 `llm_ood_eval.py report` 가 계산한 값을 그대로 읽는다(이 스크립트는 배치만 한다).
