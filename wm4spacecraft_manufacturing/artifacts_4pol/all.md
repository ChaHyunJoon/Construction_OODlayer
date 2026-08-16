| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 34% (41/120) | 63.3 ± 10.6 | 748 | 0.997 | 9.3 |
| `surrogate` | 30 | 83% (25/30) [0.66, 0.93] | 84% (98/116) | 45.0 ± 20.4 | 708 | 0.997 | 10.3 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 65% (78/120) | 43.4 ± 18.2 | 542 | 0.998 | 9.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×166, Replace×81, NOOP×39 | Battery 0/39, Fault 41/42, Zone 0/39 |
| `surrogate` | ReformTeam×114, Replace×52, RelocateBuild×31, SwapBattery×26, NOOP×7 | Battery 26/37, Fault 41/41, Zone 31/38 |
| `dspy` | ReformTeam×75, Replace×66, RelocateBuild×21, NOOP×18, SwapBattery×15 | Battery 15/39, Fault 42/42, Zone 21/39 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/286) | 34% (41/120) | 46% (41/90) | 48% (29/60) | 27% (8/30) |
| `surrogate` | 0% (0/116) | 0% (0/230) | 84% (98/116) | 87% (76/87) | 84% (49/58) | 86% (25/29) |
| `dspy` | 0% (0/120) | 0% (0/195) | 65% (78/120) | 67% (60/90) | 70% (42/60) | 63% (19/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 5승 0패 25무, 부호검정 p=0.062
- 짝지은 비교 `canonical` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 5패 25무, 부호검정 p=0.062
