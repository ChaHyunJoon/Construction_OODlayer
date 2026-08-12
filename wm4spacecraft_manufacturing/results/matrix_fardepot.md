# 실패 케이스 x 컨트롤러 결과 행렬

각 칸: 완주 k/n · 결정 적중률 · 빌드 시간(완주 판 평균) · 닫힌 노드당 에너지 · 평균 최소 SoC

기하 세대: `{"depot_distance": 40.0, "depot_mode": "fixed", "station_keeping": true}`

| FAILURE CASE | ORACLE | CANONICAL | SURROGATE | LLM |
|---|---|---|---|---|
| Battery depletion | 3/3 · acc 100% · 19.5s · 267 J/cl · SoC 0.63 | 1/1 · acc 0% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 0% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 100% · 20.1s · 274 J/cl · SoC 0.97 |
| Robot breakdown | 0/1 · acc 100% · — · — · — | 1/1 · acc 100% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 100% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 100% · 31.1s · 485 J/cl · SoC 0.96 |
| Keep-out zone | 1/1 · acc 100% · 20.1s · — · — | 1/1 · acc 0% · 58.0s · 500 J/cl · SoC 0.94 | 1/1 · acc 100% · 39.0s · 492 J/cl · SoC 0.95 | 1/1 · acc 100% · 39.0s · 492 J/cl · SoC 0.95 |
| Breakdown + battery | — | 1/1 · acc 25% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 25% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 100% · 26.1s · 343 J/cl · SoC 0.97 |
| Breakdown + zone | — | 1/1 · acc 75% · 79.9s · 927 J/cl · SoC 0.90 | 0/1 · acc 100% · — · — · — | 1/1 · acc 50% · 69.1s · 689 J/cl · SoC 0.92 |
| Battery + zone | — | 1/1 · acc 0% · 79.9s · 927 J/cl · SoC 0.90 | 0/1 · acc 33% · — · — · — | 1/1 · acc 75% · 58.0s · 500 J/cl · SoC 0.94 |
| All three at once | — | 1/1 · acc 25% · 74.8s · 790 J/cl · SoC 0.91 | 1/1 · acc 75% · 32.0s · 476 J/cl · SoC 0.96 | 1/1 · acc 100% · 40.8s · 480 J/cl · SoC 0.95 |

- ORACLE 은 단축 라벨 격자에서 유도한 상한이며 온라인 정책이 아니다. 조합 케이스는 격자가 없어 `—`.
- 빌드 시간은 완주한 판만 평균한다. 완주율이 낮은 칸의 시간은 그만큼 낙관적이다 — k/n 을 같이 볼 것.
- 에너지 주지표는 닫힌 노드당(J/cl)이다. 총 에너지는 일을 덜 한 미완주에 유리해 쓰지 않는다.
