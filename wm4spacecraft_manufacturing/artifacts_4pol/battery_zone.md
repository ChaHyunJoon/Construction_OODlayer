| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 0% (0/120) | 62.4 ± 9.7 | 679 | 0.997 | 10.0 |
| `surrogate` | 30 | 83% (25/30) [0.66, 0.93] | 76% (87/115) | 45.0 ± 18.9 | 623 | 0.967 | 11.2 |
| `dspy` | 30 | 97% (29/30) [0.83, 0.99] | 47% (56/119) | 47.3 ± 20.3 | 538 | 0.998 | 10.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×163, Replace×60, NOOP×60 | Battery 0/60, Zone 0/60 |
| `surrogate` | ReformTeam×96, RelocateBuild×55, SwapBattery×32, Replace×24, NOOP×4 | Battery 32/56, Zone 55/59 |
| `dspy` | ReformTeam×90, Replace×35, RelocateBuild×32, NOOP×28, SwapBattery×24 | Battery 24/59, Zone 32/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/283) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `surrogate` | 0% (0/115) | 0% (0/211) | 76% (87/115) | 72% (62/86) | 59% (34/58) | 66% (19/29) |
| `dspy` | 0% (0/119) | 0% (0/209) | 47% (56/119) | 40% (36/89) | 42% (25/60) | 43% (13/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 5승 0패 25무, 부호검정 p=0.062
- 짝지은 비교 `canonical` vs `dspy` — 1승 0패 29무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 4패 26무, 부호검정 p=0.125
