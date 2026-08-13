# 실패 케이스 x 컨트롤러 결과 행렬

각 칸: 완주 k/n · 결정 적중률 · 빌드 시간(완주 판 평균) · 닫힌 노드당 에너지 · 평균 최소 SoC

기하 세대: `{"depot_distance": 20.0, "depot_mode": "fixed", "station_keeping": true}`

| FAILURE CASE | ORACLE | CANONICAL | SURROGATE | LLM |
|---|---|---|---|---|
| Battery depletion | 3/3 · acc — · 22.4s · 280 J/cl · SoC 0.75 | 2/2 · acc 0% · 30.0s · 447 J/cl · SoC 0.96 | 2/2 · acc 0% · 30.0s · 447 J/cl · SoC 0.96 | 2/2 · acc 100% · 22.4s · 280 J/cl · SoC 0.97 |
| Robot breakdown | 0/1 · acc — · — · — · — | 2/2 · acc 100% · 30.0s · 447 J/cl · SoC 0.96 | 2/2 · acc 100% · 30.0s · 447 J/cl · SoC 0.96 | 2/2 · acc 100% · 30.0s · 447 J/cl · SoC 0.96 |
| Keep-out zone | 1/1 · acc — · 22.4s · — · — | 2/2 · acc 0% · 58.6s · 510 J/cl · SoC 0.94 | 2/2 · acc 100% · 30.6s · 419 J/cl · SoC 0.96 | 2/2 · acc 88% · 29.8s · 398 J/cl · SoC 0.96 |
| Breakdown + battery | — | 2/2 · acc 50% · 30.0s · 447 J/cl · SoC 0.96 | 2/2 · acc 50% · 30.0s · 447 J/cl · SoC 0.96 | 2/2 · acc 100% · 26.5s · 350 J/cl · SoC 0.97 |
| Breakdown + zone | — | 0/2 · acc 50% · — · — · — | 1/2 · acc 100% · 38.0s · 456 J/cl · SoC 0.96 | 1/2 · acc 86% · 27.7s · 359 J/cl · SoC 0.96 |
| Battery + zone | — | 0/2 · acc 0% · — · — · — | 1/2 · acc 57% · 38.0s · 456 J/cl · SoC 0.96 | 2/2 · acc 75% · 43.0s · 424 J/cl · SoC 0.95 |
| All three at once | — | 1/2 · acc 25% · 66.9s · 809 J/cl · SoC 0.92 | 2/2 · acc 62% · 29.8s · 433 J/cl · SoC 0.96 | 2/2 · acc 100% · 23.0s · 340 J/cl · SoC 0.97 |

- ORACLE 은 단축 라벨 격자에서 유도한 상한이며 온라인 정책이 아니다. 조합 케이스는 격자가 없어 `—`.
- 빌드 시간은 완주한 판만 평균한다. 완주율이 낮은 칸의 시간은 그만큼 낙관적이다 — k/n 을 같이 볼 것.
- 에너지 주지표는 닫힌 노드당(J/cl)이다. 총 에너지는 일을 덜 한 미완주에 유리해 쓰지 않는다.
- ORACLE 열은 라벨 격자의 **심각도별 인스턴스**를 모아 평균한 값(battery 는 severity 0.02/0.30/0.50)이고, 같은 행의 CANONICAL/SURROGATE/LLM 열은 **한 심각도**에서 돌린 평가 런이다. 각 칸의 k/n 이 그 모집단 크기다 — 모집단이 서로 달라 행을 가로질러 짝지어 비교할 수 없다. 열 안에서만(같은 컨트롤러끼리) 비교할 것.
