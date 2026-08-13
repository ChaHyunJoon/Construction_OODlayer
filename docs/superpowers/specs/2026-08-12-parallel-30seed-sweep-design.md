# 30시드 4정책 스윕의 병렬 실행 설계 (bethpage)

- 날짜: 2026-08-12
- 대상 저장소: `Construction_OODlayer`, 브랜치 `oracle-rebuild-night-2026-08-10`
- 실행 호스트: bethpage (56 core, 125 GB RAM, / 에 1.6 T 여유)

## 1. 목표

`run_4pol.sh` 스윕을 **7 case × 30 seed × 3 policy = 630 판**으로 확장하고, 하룻밤 안에
완주시킨다. 현재 순차 실행 기준 630판은 약 34 코어·시간이라 단일 프로세스로는 하루를 넘긴다.

성공 기준:

1. `results_4pol/<case>.jsonl` 7개 파일이 각각 90행(30 seed × 3 policy)을 갖는다.
2. 그 90행이 **모두 D=20 기하**로 생성됐다 — D=40 시절 행과 섞이지 않는다.
3. 병렬 실행이 결과 분포를 옮기지 않았다는 사전 증거가 남아 있다(§5 P7).
4. `build_final_table.py` / `build_md_report.py` 가 수정 없이 그대로 돈다.

비목표: 비결정성의 원인 규명(§9), `run_seed_sweep.sh` 병렬화.

## 2. 왜 병렬이 가능한가 — 금지 근거의 재검토

`llm_ood_eval.py` 머리말과 `run_seed_sweep.sh` 주석은 병렬을 금지하며 세 가지를 든다.
이 스윕이 타는 경로(`tools/monitor/run_demo.jl`)에서 셋 다 성립하지 않는다.

| 금지 근거 | 실태 | 근거 |
|---|---|---|
| HiGHS MILP 가 CPU 경합에 따라 다른 해를 낸다 | 이 경로는 `assignment_mode = :greedy`. MILP 를 아예 풀지 않는다 | `tools/monitor/run_demo.jl:387`, `src/full_demo.jl:251` (HiGHS 속성 블록은 `:milp` 계열에서만 실행) |
| 프로세스당 ~2.5 GB 라 OOM | 가용 121 GB. K=16 이면 ~40 GB | `free -g` 실측 |
| 렌더가 MeshCat 포트 8700 을 공유 | `run_demo.jl` 에 MeshCat 없음. 렌더 엔진은 `render_demo.jl` 로 분리돼 있고 이 스윕은 그걸 타지 않는다 | `run_demo.jl` grep |

**주의 — 이것은 "안전하다"의 증명이 아니다.** 위 셋이 무효라는 것과, 병렬이 결과를 바꾸지
않는다는 것은 다른 명제다. 실제로 이 저장소의 시뮬레이션은 **순차 실행에서도 재현되지
않는다**(동일 코드·동일 워크트리 재실행에서 monitor frames 214→204, n_closed 149→123,
2026-08-11 실측). 원인은 미상이며 RNG 도 스레딩도 아니다. 그래서 §5 의 게이트가 필요하다.

## 3. 샤딩

샤드 단위는 **(case, seed)** 다. 7 × 30 = 210 샤드, 샤드당 3 판(정책 3개).

```
.venv/bin/python llm_ood_eval.py run \
  --case "$CASE" --seeds "$SEED" \
  --policies noop,surrogate,dspy \
  --out "results_4pol/shards/$CASE/s$SEED/rows.jsonl" \
  --dspy-url http://127.0.0.1:8090 --router 0
```

### 3.1 이 단위를 고른 이유

**파일 충돌이 경로 지정만으로 사라진다.** `llm_ood_eval.py:173` 이
`log_dir = out_path.parent / "logs"` 로 로그 디렉토리를 잡고, `:113` 이 그 안에
`stream_s{seed}_{policy}.jsonl` 을 쓴다. 파일명에 case 가 없으므로 지금처럼 모든 case 가
`results_4pol/logs/` 를 공유하면 case 간에 같은 파일을 덮어쓴다 — 순차에서는 덮어쓰기로
끝나지만 병렬에서는 동시 write 다. `--out` 을 샤드마다 다른 디렉토리로 주면 `logs/` 도 따라
갈라진다. **파이썬 코드 변경이 필요 없다.**

**요약 append 도 같이 해결된다.** `DEMO_SUMMARY` 로 넘긴 파일에 julia 가 한 줄씩 붙이는데,
한 행이 약 4.9 KB 라 `PIPE_BUF`(4096 B)를 넘는다. 즉 `O_APPEND` 라도 동시 write 는 원자적이지
않아 줄이 섞일 수 있다. 샤드마다 `rows.jsonl` 이 따로면 한 파일에 쓰는 프로세스가 언제나 하나다.

**정책 비교가 부하 편향으로부터 보호된다.** 3정책은 샤드 **안에서** 순차로 돈다. 부하 조건은
샤드 사이에서만 달라지고 정책 사이에서는 같다. 부하가 결과를 흔들더라도 그것은 정책 대비에
실리는 계통 편향이 아니라 시드 간 노이즈로 들어간다. `llm_ood_eval.py:182` 가 의도한
"시드 바깥 / 정책 안쪽" 순서도 그대로 보존된다.

## 4. 실행 드라이버

신규 `wm4spacecraft_manufacturing/run_4pol_parallel.sh`. 기존 `run_4pol.sh` 는 **손대지 않는다**
— 순차 재현 경로를 남겨 둔다.

- 스케줄러: `xargs -P $K`. K 는 `--jobs` 인자, 기본 16.
- 모든 워커에 `JULIA_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1`, `OMP_NUM_THREADS=1` 을 강제한다.
  안 걸면 BLAS 가 프로세스마다 스레드를 띄워 K 배로 코어를 뺏는다.
- 데드라인(`--deadline-seconds`, 기본 28800 = 8 h)을 넘으면 **신규 샤드 투입만** 멈추고 진행 중인
  샤드는 완주시킨다.
- 작업 목록은 **seed 를 바깥, case 를 안쪽**으로 나열한다(`s1×7case, s2×7case, …`). 값싼 case 를
  앞세우는 비용 기반 재정렬은 하지 않는다 — case 별로 실행 시각이 뭉치면 case 가 부하 조건과
  교락된다. 이 순서면 어느 시각에도 여러 case 가 섞여 돈다.

## 5. 사전 조건 게이트

`run_4pol.sh` 의 P1~P6 을 계승하되 병렬 전제에 맞춰 고친다.

| 게이트 | 처리 |
|---|---|
| P1 살아있는 LLM 프로브 (`POST /macro`) | 유지, 스윕 시작 전 1회 |
| P2 health + program 신원 기록 | 유지 |
| P3 `audit_action_vocab.py` | 유지 |
| P4 `test_surrogate_support.py` | 유지 |
| P5 `pgrep -x -u $UID julia` 없어야 함 | **제거**. 병렬이 전제이므로 성립할 수 없다. 동시 실행 수는 스케줄러가 보장한다 |
| P6 결과 디렉토리 청결 | **샤드 단위로 재정의**: 샤드 `rows.jsonl` 이 3행이면 완료로 보고 건너뛴다(= 재개) |
| **P7 분포 게이트** | 신규, 아래 |
| **P8 LLM 동시성** | 신규, 아래 |

### 5.1 P7 — 분포 게이트

노트북에서 제안한 "단독 실행과 부하 하 실행의 요약 행이 **완전히 같아야 한다**" 는 판정은 쓸 수
없다. 순차 재실행끼리도 이미 같지 않기 때문이다(§2). 그 판정을 쓰면 병렬이 원인인지 원래
그런지 구분하지 못한 채 무조건 "불합격" 이 나온다.

대신 **분포**를 본다.

- 대상: `--case zone --seeds 1 --policies noop`.
  `noop` 을 쓰는 이유는 LLM 이 끼지 않아 부하 효과와 API 지연이 섞이지 않기 때문이다.
  (노트북 메모의 `canonical` 은 이 스윕의 정책 목록에 없다.)
- 표본: ① 단독 8회 ② 부하 하 8회. 부하는 **본 스윕과 같은 종류의 샤드** 15개를 동시에 돌려
  만든다(다른 case 의 실제 샤드를 쓴다 — 인공 부하 생성기는 CPU/메모리 프로필이 달라 대표성이
  없다). 그 15개의 산출물은 §7 의 재개 규칙에 따라 본 스윕에서 재사용된다.
- 지표: `complete`(이진), `sim_seconds`(연속), `n_closed`(연속).
- 판정: `sim_seconds` 와 `n_closed` 에 Mann-Whitney U 로 p > 0.05, `complete` 에 Fisher exact 로
  p > 0.05 이면 통과.
- 불합격 시: K=4 로 낮춰 재시험 → 그래도 불합격이면 K=1 순차로 후퇴하고 밤 스윕의 범위를
  줄인다.
- 비용: 약 40분.

표본 8+8 은 큰 효과만 잡는다. 이 게이트는 "부하가 결과를 뒤집지 않는다" 를 증명하지 않으며,
**뒤집는다는 뚜렷한 증거가 없음**을 확인하는 장치다. 스펙에 이 한계를 명시해 둔다.

### 5.2 P8 — LLM 동시성

dspy 레인은 210 판이고 판당 4~9 결정이라 약 840~1,890 회의 gpt-4o 호출이 발생한다. 샤드 안에서
정책이 순차이므로 동시 dspy 판은 최대 K=16 이다.

게이트: DSPy 서비스(`uvicorn dspy_service:app --port 8090`) 기동 후 `/macro` 에 동시 16 요청을
던져 전부 HTTP 200 이고 `policy` 가 `dspy` 로 시작하며 `error` 가 null 인지 확인한다. 하나라도
rate limit(429)이면 K 를 낮춘다.

## 6. 데이터 흐름과 병합

```
results_4pol/shards/<case>/s<seed>/rows.jsonl   (3행)
results_4pol/shards/<case>/s<seed>/logs/        (스트림·런 로그)
        │  merge
        ▼
results_4pol/<case>.jsonl                       (90행)
_night/status_4pol.jsonl                        (샤드별 status 기록)
        │
        ▼
build_final_table.py --results-dir results_4pol --out-dir artifacts_4pol
build_md_report.py   --results-dir results_4pol --out-dir artifacts_4pol --oracle-dir oracle/out
```

병합이 필요한 이유는 `build_final_table.py:301` 이 `results_dir / "<case>.jsonl"` 평면 구조를
기대하기 때문이다. 병합은 (seed, policy) 로 정렬해 결정적으로 만든다 — 완료 순서에 따라 행
순서가 달라지면 산출물이 실행마다 달라진다.

병합 스크립트는 행 수를 검사한다. 90행이 아니면 어느 (seed, policy) 가 비었는지 찍고 0이 아닌
코드로 끝낸다. 조용한 부분 병합은 없다.

`_night/status_4pol.jsonl` 은 기존 포맷(`case,status,rows,wall_seconds,seeds,policies,program`)을
유지한다 — `build_final_table.py:284` 가 읽는다.

## 7. 오류 처리와 재개

- 샤드 실패는 그 샤드만 재시도한다. 샤드 디렉토리를 지우고 다시 돌리면 되므로 idempotent 다.
- 재개(`--resume`)는 샤드 `rows.jsonl` 의 행 수가 3인 샤드를 건너뛴다.
- 미완주 판(`complete=no`)은 실패가 아니다 — 그 자체가 측정값이므로 재시도하지 않는다. 재시도
  대상은 julia 가 0이 아닌 코드로 죽었거나 행이 아예 안 쓰인 샤드다.

## 8. 기존 결과의 격리

`results_4pol/*.jsonl` 은 2026-08-10 에 **D=40 기하**로 만든 것이다. 원격에서 병합해 온
`chore(depot): 기본 창고 거리를 40 에서 20 으로 내린다` 이후 새로 도는 판은 D=20 이다.
`--resume` 으로 이어 붙이면 한 파일 안에 두 기하가 섞인다.

따라서 스윕 전에 `results_4pol/` 의 기존 `*.jsonl` 과 `logs/`, 그리고
`_night/status_4pol.jsonl` 을 `_quarantine_D40_2026-08-12/` 로 **이동**한다. 삭제하지 않는다.

## 9. 이번 범위 밖

- **비결정성 원인 규명.** 214→204 는 여전히 미해결이다. P7 의 단독 8회 반복이 그 조사의 첫
  체계적 표본이 되므로 원자료를 남긴다. 별도 세션에서 `systematic-debugging` 으로 다룬다.
- `run_seed_sweep.sh` 병렬화. 그쪽은 `render_demo.jl` 을 타서 MeshCat 포트 충돌이 실재한다.

## 10. 예상 소요 (K=16)

| 단계 | 소요 |
|---|---|
| git 병합 (완료: `3d112cb`) | 15분 |
| DSPy 서비스 기동 + P1~P4, P8 | 10분 |
| P7 분포 게이트 | 40분 |
| 본 스윕 630판 | 2.2 h |
| 병합 + 리포트 생성 | 15분 |
| **합계** | **약 3.5 h** |

case 별 단가(`run_4pol.sh` 의 실측 기반 `unit_price_for_case`, 143~212 s ×1.15)를 630판에 적용하면
약 34 코어·시간이고, K=16 에 서버/노트북 단일코어 성능비 f=1.0~1.4 를 곱하면 2.2~3.0 h 다.

56 코어라 K=24 까지 여유가 있으나(RAM 약 60 GB) 이번에는 K=16 으로 간다.
