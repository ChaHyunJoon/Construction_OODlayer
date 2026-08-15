| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 35% (42/120) | 62.7 ± 14.1 | 733 | 0.997 | 9.3 |
| `surrogate` | 30 | 70% (21/30) [0.52, 0.83] | 68% (75/111) | 25.5 ± 4.7 | 789 | 0.997 | 9.5 |
| `dspy` | 30 | 93% (28/30) [0.79, 0.98] | 89% (106/119) | 32.3 ± 16.6 | 468 | 0.998 | 10.7 |
| `dp` | 30 | 100% (30/30) [0.89, 1.00] | 38% (46/120) | 47.4 ± 19.1 | 503 | 0.998 | 10.9 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×164, Replace×81, NOOP×39 | Battery 0/39, Fault 42/42, Zone 0/39 |
| `surrogate` | ReformTeam×92, Replace×74, RelocateBuild×37 | Battery 0/35, Fault 38/39, Zone 37/37 |
| `dspy` | ReformTeam×58, SwapBattery×39, Replace×39, RelocateBuild×29, NOOP×10, Deprioritize×2 | Battery 39/39, Fault 38/41, Zone 29/39 |
| `dp` | ReformTeam×110, SwapBattery×49, NOOP×32, Replace×32, RelocateBuild×7 | Battery 23/39, Fault 16/42, Zone 7/39 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/284) | 35% (42/120) | 47% (42/90) | 50% (30/60) | 27% (8/30) |
| `surrogate` | 0% (0/111) | 0% (0/203) | 68% (75/111) | 57% (47/83) | 50% (28/56) | 21% (6/28) |
| `dspy` | 0% (0/119) | 0% (0/177) | 89% (106/119) | 94% (84/89) | 98% (59/60) | 100% (30/30) |
| `dp` | 0% (0/120) | 0% (0/230) | 38% (46/120) | 43% (39/90) | 42% (25/60) | 57% (17/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 9승 0패 21무, 부호검정 p=0.004
- 짝지은 비교 `canonical` vs `dspy` — 2승 0패 28무, 부호검정 p=0.500
- 짝지은 비교 `canonical` vs `dp` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 8패 22무, 부호검정 p=0.008
- 짝지은 비교 `surrogate` vs `dp` — 0승 9패 21무, 부호검정 p=0.004
- 짝지은 비교 `dspy` vs `dp` — 0승 2패 28무, 부호검정 p=0.500
