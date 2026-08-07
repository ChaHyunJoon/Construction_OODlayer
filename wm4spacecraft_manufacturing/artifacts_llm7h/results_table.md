| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/17) | — (완주 0) | 856 | 0.182 | 12.0 |
| `canonical` | 5 | 80% (4/5) [0.38, 0.96] | 32% (6/19) | 66.3 ± 1.3 | 971 | 0.907 | 9.6 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 68% (13/19) | 35.5 ± 4.3 | 739 | 0.937 | 9.6 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 90% (18/20) | 41.0 ± 13.9 | 538 | 0.952 | 10.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×47 | Battery 0/6, Fault 0/5, Zone 0/6 |
| `canonical` | ReformTeam×30, Replace×12, NOOP×7 | Battery 0/6, Fault 6/6, Zone 0/7 |
| `surrogate` | Replace×12, ReformTeam×10, RelocateBuild×7 | Battery 0/6, Fault 6/6, Zone 7/7 |
| `dspy` | ReformTeam×10, SwapBattery×6, Replace×6, RelocateBuild×6, NOOP×2 | Battery 6/6, Fault 6/6, Zone 6/8 |

- 짝지은 비교 `noop` vs `canonical` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `noop` vs `surrogate` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `canonical` vs `surrogate` — 0승 0패 5무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000
