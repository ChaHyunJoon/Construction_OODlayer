# 발화 시점 재라벨링 — fault 를 여러 진행도에서 (2026-08-05)

**한 줄 요약.** 라우터가 데모의 battery 를 매번 "처음 보는 사건"으로 판정한 원인은 종류 판별이 아니라
**교정 데이터의 발화 시점이 점 하나**였던 것이고, fault 가 그 점을 벗어나지 못한 이유는 도메인이 아니라
**피커의 술어 하나**였다. 그 술어를 고치고 fault·faultidle 을 6 개 진행도(0.19~0.83)에서 다시
라벨링했다. 라우터 합격 판정 `battery must read FAMILIAR` = **PASS** (p 0.0116 → 0.345).

관련 문서: [`LABELING_MANUAL.md`](../LABELING_MANUAL.md) §6(진단)·§7(피커 수정과 재라벨링 절차).

---

## 1. 진단 — 왜 fault 만 초반에 갇혀 있었나

`pick_solo_fault_target` / `pick_solo_frontier_target` 은 둘 다 `_first_pending_assignment` 를 통과해야
한다. 그 함수는 "아직 안 닫힌 `RobotGo` 인데 선행자가 `RobotStart` 이거나 이미 closed" — 즉 **깨끗한
작업 경계**에 서 있는 로봇만 인정한다. 빌드가 굴러가면 로봇은 운반 사슬(`FormTransportUnit` →
`TransportUnitGo` → `DepositCargo`) 안에 있고 그 경계를 스쳐 지나갈 뿐이라, 중반 이후 스냅샷에서는
후보가 **0** 이 된다. 활성 로봇이 19~23 대인데도 그렇다.

그 술어가 지키려던 것은 **스케줄 재각인(re-stamp)** 경로의 어서션
(`@assert has_edge(scene_tree, agent, robot_id)`, route_planning.jl)이다. 정체성 보존 **hot-swap** 은
id 를 유지한 채 본체만 갈아끼우므로 넘길 엣지가 없고 운반 도중에도 안전하다 — 엔진은 이미 같은 예외를
두 곳(`mdp/hazard.jl:454 _hz_safe_target`, `navigator/battery.jl:505`)에서 쓰고 있었다. **라벨러만 그
예외를 못 받고 있었다.**

측정(`oracle/probe_fire_points.jl` → `oracle/out/fire_probe_hotswap.csv`), tractor·10 robots·spare 3:

| closed | 58 | 80 | 101 | 140 | 183 | 222 | 240 | 260 | 280 |
|---|---|---|---|---|---|---|---|---|---|
| 기존 피커 후보 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| **hot-swap 피커 후보** | 10 | 10 | 10 | 10 | 10 | 10 | 9 | 2 | 0 |

closed 280 의 0 은 술어가 아니라 사실이다(남은 운반 일이 없다). 그래서 그리드는 260 에서 끝냈다.

## 2. 고침

| 파일 | 무엇 |
|---|---|
| `src/respec/ood_injection.jl` | **신규** `pick_hotswap_fault_target(env)` — 예비가 아니고 **안 닫힌 운반팀의 멤버**인 로봇(= 남은 일이 있어 고장이 결과를 낳음). 기존 두 피커는 손대지 않음(기존 덤프 재현성). |
| 〃 | `fault_robot!(safe=true)` 의 **3단 사다리 마지막 칸**으로 연결. `hot_swap_enabled()` 일 때만. 앞 단이 성공하면 그대로 쓰므로 초반 발화는 **바이트 동일**, 예전에 `nothing` 이던 순간만 채운다. |
| `oracle/gen_oracle_dataset.jl` | `DS_FAULT_PICK="hotswap"` (이것만 사용) / `"auto"`(기본, 기존 3피커 실패 시 폴백, `DS_HOTSWAP=1` 조건). |
| `oracle/probe_fire_points.jl` | `n_hotswap`·`n_hotswap_inprog`·`hotswap_pick` 열 추가(위 표의 근거). |
| `oracle/run_firegrid_fault.ps1` | **신규** 재라벨링 엔트리포인트(순차 실행이 기본 — §5 참조). |
| `firegrid_report.py` | **신규** 커버리지 · 정답 다양성(raw/cost-aware) · admissibility 보고. |

## 3. 재라벨링 결과 (seed 1, 발화점 58/100/140/180/220/260)

`python firegrid_report.py` (데이터: `oracle/out/firegrid_merged.jsonl`)

| kind | closed | progress | n | admis | oracle-best (raw) | oracle-best (cost-aware λ=3) |
|---|---|---|---|---|---|---|
| fault | 50 | 0.168 | 6 | – | Replace×6 | Replace×6 |
| fault | 58 | 0.185 | 14 | 1/2 | Replace×9, NOOP×5 | Replace×7, NOOP×7 |
| fault | 100 | 0.319 | 2 | 1/2 | **Replace×1, NOOP×1** | Replace×1, NOOP×1 |
| fault | 140 | 0.447 | 2 | 1/2 | **Replace×1, NOOP×1** | Replace×1, NOOP×1 |
| fault | 181 | 0.578 | 2 | 1/2 | **Replace×1, NOOP×1** | Replace×1, NOOP×1 |
| fault | 222 | 0.709 | 2 | 1/2 | **Replace×1, NOOP×1** | Replace×1, NOOP×1 |
| fault | 260 | 0.831 | 2 | 1/2 | **Replace×1, NOOP×1** | Replace×1, NOOP×1 |

즉 새 발화점마다 **같은 kind 안에서 정답이 갈린다** — 갈라 놓는 것은 시점도 종류도 아니고 상태
(`agent_pending`)다. 이것이 이 데이터셋의 목적이다.

- `H(best|fault)` 0.852 → **0.940 bit** (cost-aware 0.985), n 18 → **42** (seed 1·2)
- fault progress 범위 0.168~0.185 → **0.168~0.831**
- 전체 교정 instance 의 `progress` sd **0.005 → 0.217**

**seed 2 로 재현됨.** 같은 그리드를 seed 2 로 한 번 더 돌렸다(발화점은 배치 경계 때문에 100↔101,
140↔141, 180↔181, 220↔222 로 한두 노드 어긋난다). fault 는 **모든 발화점에서 두 시드 모두**
`Replace(pending>0) / NOOP(pending=0)` 로 갈렸다 — 뒤집힘이 시드 우연이 아니다.

### 3-a. battery TIER B — 발화 시점이 **정답 자체를 뒤집는다** (이번 작업의 가장 큰 발견)

> ## ⚠️ 철회됨 (2026-08-05, 같은 날 저녁)
> **이 절의 결론은 틀렸다.** "후반(≥0.58)에는 깊은 방전도 함대가 흡수한다"가 아니라,
> `_pick_battery_target` 이 진행도 0.51 부터 **주차된 예비 로봇**을 표적으로 골라 사건이 무의미해진
> 것이었다(그래서 `agent_pending = 0` 이고 모든 팔이 동점이다). 피커를 고친 뒤 같은 발화점 그리드를
> 다시 라벨링하면 **NOOP 은 6개 발화점 전부에서 완주하지 못한다**(0.83 에서도).
> 근거와 재측정: **`BATTERY_FAULT_REDESIGN_2026-08-05.md` §1**.
> (같은 문서 §2 는 이 절이 쓴 심각도 사다리 0.05/0.35 자체도 재설계했다.)

fault 를 고친 김에 battery 도 같은 그리드에서 TIER B 로 돌렸다(deep soc=0.05 / mild soc=0.35).
그동안 battery 의 후반 행은 전부 TIER A(NOOP 한 팔)라 "정답"을 말할 수 없었는데, 이제 말할 수 있다:

| soc | 58 (0.19) | 100 (0.32) | 140 (0.45) | 181 (0.58) | 222 (0.71) | 260 (0.83) |
|---|---|---|---|---|---|---|
| **0.05 (deep)** | NOOP 미완주 176 → **Replace** | 미완주 184 → **Replace** | 미완주 211 → **Replace** | NOOP **완주** → **NOOP** | NOOP 완주 → **NOOP** | NOOP 완주 → **NOOP** |
| 0.35 (mild) | 동점 → NOOP | 동점 → NOOP | 동점 → NOOP | 동점 → NOOP | 동점 → NOOP | 동점 → NOOP |

**깊은 방전이라도 빌드 후반(≥0.58)에는 개입이 필요 없다** — 그 로봇에게 남은 일이 적어 함대가 흡수한다.
admissibility 도 그렇게 나온다(58~140 은 1/2, 181~260 은 **0/2** = NOOP 이 control 과 동등).

이건 단순한 커버리지 보강이 아니라 **모델이 배워야 할 새 구조**다. 종전 데이터는 전부 progress≈0.185
한 점이라 "deep battery → Replace"가 무조건 참인 것처럼 보였다. 실제로는 `soc` 만으로는 못 정하고
진행도(남은 일의 양)까지 읽어야 한다. `H(best|battery)` 0.811 → **0.999 bit**, n 24 → **48**(seed 1·2).

**경계는 시드마다 조금 움직인다(정직하게).** seed 1 은 progress 0.447 에서 아직 Replace 가 필요했고
(admissible 1/2), seed 2 는 0.450 에서 이미 흡수됐다(0/2). 즉 "≥0.58 이면 NOOP" 은 두 시드 모두에서
성립하지만, 뒤집히는 **정확한 지점은 0.45~0.58 구간 어딘가**이고 시드에 따라 다르다. 경계값을 상수로
박지 말 것 — 모델이 상태에서 읽어야 하는 것이 바로 이 부분이다.

원자료(한 건도 빠짐없이):

| instance | NOOP | Replace | 판정 |
|---|---|---|---|
| `fault_f58` (pending 3) | 미완주 176 | 완주 291 / mk 22.1 | Replace |
| `fault_f100` (pending 2) | 미완주 234 | 완주 291 / mk 24.4 | Replace |
| `fault_f140` (pending 2) | 미완주 236 | 완주 291 / mk 22.7 | Replace |
| `fault_f180` (pending 1) | 미완주 266 | 완주 291 / mk 26.1 | Replace |
| `fault_f220` (pending 1) | 미완주 266 | 완주 291 / mk 27.0 | Replace |
| `fault_f260` (pending 1) | 미완주 282 | 완주 291 / mk 23.2 | Replace |
| `faultidle_f58…f260` (pending 0) | **완주 291 / mk = control 과 동일** | 완주 291 | NOOP (cost-aware 엄격 우위) |

## 4. 덤으로 잡힌 두 번째 버그 — faultidle 이 중반부터 무해하지 않았다

`faultidle` 은 "같은 kind·같은 NL 인데 희생자가 일이 없어 NOOP 이 정답"인 쌍둥이여야 한다. 첫 실행
결과(`oracle/out/firegrid_v1broken_faultidle.jsonl`):

| 발화점 | 58 | 100 | 140 | 180 | 220 | 260 |
|---|---|---|---|---|---|---|
| 희생자 `agent_pending` | **0** | 4 | 2 | 2 | 2 | 1 |
| NOOP 완주 | **Y** | n | n | n | n | n |

원인은 §1 과 **같은 술어**였다 — `_pick_idle_victim` 이 "남은 일이 있는가"를
`_first_pending_assignment === nothing` 으로 물었고, 그건 중반 이후 거의 모두에게 참이라 **바쁜 로봇이
'일 없음'으로 오분류**됐다. 판정을 "안 닫힌 `FormTransportUnit` 팀의 멤버인가"로 바꾸자 6 개 발화점
**전부** `agent_pending=0` · NOOP 완주 · makespan 이 control 과 소수점까지 동일(= 완전 흡수)이 됐다.

> 이 술어를 "일감 유무"로 쓴 곳이 저장소에 최소 두 군데 있었고 둘 다 중반 이후 조용히 틀렸다.
> `_first_pending_assignment` 는 **인계 지점을 찾는 함수**지 "남은 일이 있는가"를 재는 함수가 아니다.

## 5. 운영상 함정 (다음 사람을 위해)

1. **lane 병렬 = OOM.** 판 하나마다 `DS_STACK`(2GB)을 통째로 예약하므로 2 프로세스면 4GB 이고,
   편집기·파이썬 서비스가 물고 있으면 16GB 머신에서도 죽는다. 이번에 두 번 겪었다
   (`OutOfMemoryError() @ run_with_stack`). `run_firegrid_fault.ps1` 은 **순차가 기본**이고
   `FG_PARALLEL=1` 로만 병렬이 된다.
2. **`DS_RESUME` 이 VALID_ONLY 에서 안 먹었다.** 기대 팔 수를 `length(MACROS)=5` 로 잡는데 VALID_ONLY 는
   instance 당 2~3 팔이라 어떤 instance 도 done 으로 안 잡혔다 → 이어받기가 끝난 것을 전부 재실행
   (실측 12 분 낭비). 각 행에 이미 적혀 있는 `arms_labeled` 를 기대치로 쓰도록 고쳤다.
3. **`export_novelty_calibration.py` 의 분별력 점검이 꺼져 있었다.** probe 슬라이스를 `len(X)//2` 로
   잘라, instance 가 probe 수보다 많으면(99 > 32) 뒤쪽이 비어 `mean = nan` 이 되고 경고가 조용히
   사라진다. 경계를 probe 구조(`n_cal_probes`)로 잡도록 고쳤다 — 지금은 in-dist p=0.587 vs
   shifted p=0.016 으로 정상 작동한다.

## 6. 합격 판정 — 라우터

`python verify_router_calibration.py novelty_calibration_no_zoneblk.json` (녹화 스트림 재판정, 시뮬 0 판)

| 사건 | progress | 녹화 당시 p | 새 교정 p | 판정 |
|---|---|---|---|---|
| **BATTERY R1** | 0.413 | 0.0116 → NOVEL | **0.321** | familiar → surrogate |
| FAULT R16 | 0.659 | 0.0116 → NOVEL | **0.311** | familiar → surrogate |
| FAULT R7 | 0.177 | 0.430 | 0.362 | familiar (변화 없음) |
| ZONE ×3 · 후반 OOD | 0.18~0.87 | novel | novel | → LLM (zoneblk 제외 교정이므로 **의도된 것**) |

`ACCEPTANCE (battery must read FAMILIAR): PASS` · 4/7 NOVEL(전부 zone 계열).
축 감사에서 DEGENERATE 축이 사라졌다: `progress` sd 0.00593 → **0.217**(전 종류, n=126) /
**0.232**(zone 제외, n=97). 분별력 점검도 정상: 교정점 p=0.67~0.69 vs 밀어낸 점 p=0.010.

**Julia 쪽 검증**: `julia +lts --project=. tools/test_novelty.jl wm4.../novelty_calibration.json`
→ **33 passed, 0 failed** (파이썬과 1e-9 이내 파리티 + 손상 파일 거부 F1~F7 전부 통과).

교체된 배포 파일: `novelty_calibration.json`(126 instance), `novelty_calibration_no_zoneblk.json`(97)
— 직전 버전은 `*.bak_2026-08-04` 로 보존. 병합 데이터셋은 `oracle/out/firegrid_merged.jsonl`(414행),
CANONICAL(`openworld_merged.jsonl`)은 **손대지 않았다**(발표된 regret/frontier 숫자의 근거이므로).

## 7. 남은 일 / 권고

- **소비 측 필터 버그를 고쳐야 새 라벨이 쓰인다 (2026-08-05 추가, 수정 완료).**
  `e1_analyze.py`(cost-aware)와 `dspy_service.py`(배포 적합)가 둘 다 `len(g) == 5` 로 instance 를
  걸렀다. `DS_VALID_ONLY` 라벨은 유효 팔이 2개뿐이라 5를 영영 못 채운다 → **새 66 instance 가 학습·
  평가에서 통째로 사라졌다**(실측: 126 중 60 통과, 그 60 은 전부 옛 덤프). 판정을
  `instance_arms_complete`(= 그 사건의 유효 행동집합을 다 라벨링했는가)로 바꿨다. 하위호환 확인:
  기존 배포 데이터셋 `graded_hs_n44` 는 44 → **44 로 동일**, 새 덤프는 60 → **108**.
- **surrogate 재학습**: 배포 서비스는 시작할 때 `SURRO_DATA` 에서 직접 적합하므로, 재학습 = 데이터셋을
  가리키고 재시작이다. 기본값은 벤치마크 일치를 위해 `HS_N44` 로 **핀 고정**되어 있어 건드리지 않았다:
  `EVAL_DATA=oracle/out/firegrid_merged.jsonl` 로 띄우면 108 instance 로 적합된다.
- **`_pick_battery_target` 도 같은 술어에 의존한다**(navigator/battery.jl:385-393). 1·2 순위가 모두
  `_first_pending_assignment` 라 중반 이후 둘 다 실패하고, 주석이 "항상 주차된 예비를 고른다"고 경고한
  레거시 폴백으로 떨어진다. 녹화된 데모에서는 실제로 작업 로봇(R1)이 맞았으므로 **관측된 피해는 없다.**
  구조적으로 취약하니 같은 방식(FTU 멤버십)으로 고치는 것을 권한다 — 배터리 라벨 전체에 영향이 가는
  변경이라 이번에는 손대지 않았다.
- **데모 창.** `render_demo.jl` 의 fault 창 `(2,20)` 은 hot-swap 이전 조건이다. 이제 후반 고장도
  안전하므로 `DEMO_FAULT_SAFE=1 DEMO_FAULT_STEPS=60,600` 으로 중·후반 고장 데모가 가능하다
  (기본값은 녹화 재현성을 위해 그대로 뒀다).
- **다음 작업: world 가 아니라 시점을 채운다 (2026-08-05 축 재정의).**

  > **이 문서의 이전 판에 있던 "seed 를 30 정도까지 채운다"는 계획은 철회한다.** 축을 잘못 잡았다.

  `DS_SEEDS` 는 **확률적 사건 축이 아니다.** 시뮬레이터가 `rng` 를 소비하는 곳은 딱 한 군데,
  `full_demo.jl:420` 의 `StatsBase.sample(rng, vtxs, num_robots)` = **로봇 10 대의 초기 배치**뿐이고
  그 뒤는 전부 결정론적이다(`gen_oracle_dataset.jl` DETERMINISM 주석: *(seed, policy) fixes the whole
  trajectory*). 게다가 fire-grid 는 `DS_MC_K=1` 이라 hazard 점과정이 꺼져 있고 발화 시점·종류·심각도는
  `DS_FIRE_GRID` 로 명시된다. 즉 **seed 를 바꿔도 교란 과정은 재추첨되지 않고 공장 도면만 바뀐다.**

  이 과제의 도메인은 같은 셀에서 같은 우주선을 반복 제조하는 것이고, 배포 world 는 항상 seed 1
  (`full_demo.jl` 의 기본 `MersenneTwister(1)` = 데모가 도는 그 world)이다. 판마다 도크 위치가
  달라지는 세계는 존재하지 않으므로, 거기에 51 시간(28 시드 × 110 분)을 쓰면 배포와 무관한 축을 채우게
  된다. **확률성은 "언제 어떤 고장이 나는가"에만 있다.** 그래서 축을 이렇게 분리한다:

  | 축 | 값 | 어디서 |
  |---|---|---|
  | world (공장) | **seed 1 고정** | `DS_SEEDS` / `DEMO_SEED` |
  | 확률성 (언제·무엇·얼마나) | 스위프 | 라벨=`DS_FIRE_GRID` 격자 / 평가=`DEMO_OOD_SEED` 무작위 |

  **라벨에서 시점이 격자인 것은 버그가 아니라 요구조건이다.** 라벨 한 줄은 반사실 비교(NOOP 미완주
  176 vs Replace 완주 291)이므로 두 팔에서 **같은 사건이 같은 시점에** 터져야 한다. 무작위로 뽑으면
  팔마다 다른 사건을 겪어 비교 자체가 성립하지 않는다. 확률적으로 뽑힌 시점에서의 성능은 라벨이 아니라
  **평가**에서 잰다(바로 아래 항목).

  그래서 `run_firegrid_fault.ps1` 을 이렇게 고쳤다(전 lane `DS_SEEDS=1`):

  | lane | 격자 | 새로 도는 발화점 |
  |---|---|---|
  | fault / faultidle | `58,80,100,120,140,160,180,200,220,240,260` (6→11 점) | 80·120·160·200·240 |
  | battery TIER B (soc 0.05/0.35) | `58,100,140,150,160,170,180,200,220,260` | 150·160·170·200 |

  battery 격자가 140~180 에 몰린 이유는 §3-a 다 — 정답이 뒤집히는 경계가 progress 0.45~0.58 사이
  어딘가인데 기존 6 점 격자에는 그 구간에 점이 **하나도** 없다. 새로 도는 instance 는 18 개(≈1.4 시간,
  순차). 기존 6 점은 `DS_RESUME=1` 이 그대로 건너뛴다(요청값 id 가 같도록 181/222 대신 180/220 사용).

- **새 실험: 무작위 OOD 스트림 스위프 (`tools/monitor/run_ood_sweep.ps1`).**
  "어느 시점에 어떤 사건이 나든 적응하는가"를 실제로 재는 것은 라벨이 아니라 이쪽이다. 지금까지
  저장소의 모든 평가는 사건 시점이 고정이었다 — 오라클은 격자, 데모는 슬롯 `[0.10, 0.32, 0.55]`.
  즉 "적응적"이라는 주장의 근거가 사실상 한두 개의 대본이었고, **무작위 스트림 위에서 정책을 비교한
  적은 한 번도 없다.**

  - `run_demo.jl` 에 `DEMO_OOD_SEED` 를 추가했다(>0 이면 `CB.schedule_random_ood!` 로 시점·종류·
    심각도를 그 시드로 추첨, 0=기본은 예전 고정 슬롯 그대로라 녹화 스트림 재현 불변).
    `DEMO_SEED`(world)와 **다른 손잡이**라는 점이 핵심이다.
  - `policy.jl` 에 `noop`(no-adapt 바닥선)을 1급 정책으로 추가했다. 이게 없으면 완주율 비교의 분모가
    없다. 정책 비교 시 라우터는 **끈다**(`DEMO_ROUTER=0`) — 켜두면 "surrogate 를 쟀다"는 판이 사실은
    LLM 판이 된다. 라우터 자체를 재려면 `SWEEP_POLICIES` 에 `router` 를 넣는다.
  - `run_demo.jl` 이 `DEMO_SUMMARY` 에 한 줄 JSONL(완주 여부·closed·사건별 결정·라우터 판정)을 남기고,
    `ood_sweep_report.py` 가 ① 정책별 완주율(Wilson CI) ② **같은 ood_seed 끼리 짝지은** 승패(부호검정)
    ③ 결정 분포·규칙 불일치율 ④ 발화 진행도 분포(히스토그램)를 낸다. 짝짓기가 필요한 이유는 판마다
    스트림 난이도가 다르기 때문이다(평균만 비교하면 그 차가 섞인다).

  ```
  $env:SWEEP_SEEDS="1,2,3,...,20"; $env:SWEEP_POLICIES="noop,canonical"
  pwsh -File tools/monitor/run_ood_sweep.ps1
  python wm4spacecraft_manufacturing/ood_sweep_report.py
  ```
  `surrogate`/`dspy`/`router` lane 은 파이썬 서비스(`dspy_service.py`, 포트 8077)가 떠 있어야 한다.

  > **스모크 1 판만 돌리고 중단(2026-08-05, repo 설계 변경 예정이라 보류).** 확인된 것과 남은
  > 버그는 아래.
  >
  > **작동 확인됨** — 무작위 스트림 배선. `DEMO_OOD_SEED=1` 이 fault/battery 3 건을 closed
  > 47/123/188 (progress **0.15 / 0.39 / 0.60**)에 뽑았다. 고정 슬롯(0.10/0.32/0.55)이 아니라
  > 시드에서 나온 값이고, 그 판은 완주했다(step 885, closed 291/313).
  >
  > **미해결 버그 — `DEMO_POLICY=noop` 이 안 먹는다.** noop lane 으로 돈 판이 사건 3 건 모두
  > `Replace` 를 실행했고(= canonical 동작), 요약 행의 `policy` 도 `canonical` 로 찍혔다(= julia
  > 안에서 `ENV["DEMO_POLICY"]` 가 기본값). 그 판은 exit code 1 로 끝났다.
  > **환경변수 전달은 범인이 아니다** — 같은 문자열을 재현해 자식 프로세스에서 확인했더니
  > `DEMO_POLICY=noop` 이 정상적으로 보였고, 같은 경로로 온 `DEMO_N=3`·`DEMO_OOD=fault_battery`·
  > `DEMO_OOD_SEED=1` 은 전부 반영됐다. 따라서 `policy.jl` 의 `noop` 분기(또는 그것을 읽기 전에
  > 죽는 무언가)를 봐야 한다. exit 1 의 원인도 같이 봐야 하는데 로그가 **UTF-16LE**(PS 5.1
  > `Tee-Object` 기본)이라 grep 이 안 걸린다 — 스위프 스크립트에서 인코딩을 UTF-8 로 고정할 것.
  >
  > 재개 시: 위 버그 먼저 고치고 → 4 판 스모크로 바닥선(noop)과 상한선(canonical)이 실제로
  > 갈리는지 확인 → 그 다음 20 시드. 참고로 canonical 은 이 스트림에서 완주했으므로, 바닥선이
  > 고쳐진 뒤에도 둘 다 완주하면 난이도(스페어 3 대 / `SWEEP_N` / `severe_frac`)를 올려야 측정이 된다.

  > 참고: 이전 판의 "seed 를 더 늘릴 필요 없다(LOSO 로 확인)"는 주장도 여전히 철회 상태다. 다만
  > 그 반대 결론(시드 확장)이 아니라 **축 자체가 다른 것**이 결론이다. `--group=seed` 옵션은 남겨
  > 두되, world 가 하나로 고정되면 그 그룹핑은 더 이상 할 일이 없다.

- **남은 오차 22/108 의 성질** (아래는 seed 1·2 위에서 잰 값이므로, 조밀해진 격자 라벨이 쌓이면 다시 잴 것) 오답의 **실제 손해가 전부 ≤ 3.0 노드**
  (중앙값 0.9)인데, 이는 개입비용 λ 한 단위이고 value 모델의 MAE(7 노드)보다 작다. 전체 108 중
  **61 개가 3 노드 이하 차이로 갈리는 near-tie** 다. 오답의 형태도 한 가지뿐이다 — **필요 없을 때
  개입**(mild battery: NOOP↔Deprioritize / 후반 deep battery: NOOP↔Replace). fault 는 41/42 정답이고
  **새 발화점 전부 정답**이다. 치명적 오선택은 0 건.
  → 유력한 가설은 **해상도 문제**(값 회귀의 잡음이 결정 마진보다 크다)이고, 그렇다면
  **decision-focused 목적함수**(값 회귀 대신 팔 사이 차이를 직접 랭킹/분류; SPO+ 계열)가 레버다.
  다만 이건 아직 **가설**이다 — 지금 데이터로는 "데이터를 더 뽑아도 안 줄어든다"를 확인할 수 없다.
  조밀해진 격자(fault 11 점 · battery 10 점)가 쌓인 뒤 같은 분해를 다시 돌려서 판단할 것. 특히
  오답이 몰려 있는 곳(후반 deep battery 의 NOOP↔Replace)이 바로 새 격자가 뚫는 150~180 구간이므로,
  "해상도 문제인가 데이터 공백이었나"가 그때 갈린다.
- **zoneblk 는 여전히 후반이 비어 있다**(0.185~0.585, 그나마 TIER A). 그리고 `H(best|zoneblk)=0` 이라
  현재도 trivial 하다 — 이건 이번 작업 범위 밖이고, LABELING_MANUAL §5 의 "zone 은 상류에서 막혀
  있다"가 그대로 유효하다.

---

## 8. 이번에 확인된 것 / 확인 못 한 것

**확인된 것**
- fault 가 초반에만 터진 것은 도메인이 아니라 술어였다(측정: 후보 0 → 10).
- 중반·후반 고장에서 Replace 는 실제로 완주를 사고, NOOP 은 팀을 영구 정지시킨다(6/6 발화점).
- 무해한 쌍둥이는 고치고 나면 전 구간에서 완전 흡수된다(makespan 이 control 과 동일).
- deep battery 의 정답이 진행도에 따라 뒤집힌다(≥0.58 에서 NOOP).
- 라우터가 데모 battery 를 familiar 로 판정한다(재현 가능한 합격 판정 + Julia 파리티 33/33).

- 두 시드에서 fault 의 뒤집힘이 **모든 발화점에서 재현**된다(seed 1·2 — world 2 개짜리 재현이다).
- 회귀 없음: `tools/tests.jl respec_reassign` 통과(t=0 재배정 · 중반 freeze-respecting 재배정 둘 다),
  `tools/test_novelty.jl` **33 passed / 0 failed**(새 교정으로 Julia↔Python 파리티 1e-9).

**확인 못 한 것(정직하게)**
- **무작위로 뽑힌 시점에서 정책이 실제로 적응하는지는 아직 모른다.** 지금까지의 모든 평가는 사건
  시점이 고정(격자 또는 슬롯)이었다. §7 의 `run_ood_sweep.ps1` 이 이걸 재려고 만든 것인데 **아직
  한 판도 안 돌렸다.** 그 전까지 "적응적"이라는 표현은 고정 대본 위의 결과로만 읽어야 한다.
- battery 의 뒤집히는 **정확한 지점**을 못 좁혔다(seed 1 은 progress 0.447 에서 아직 Replace 필요,
  seed 2 는 0.450 에서 이미 흡수). 다만 이건 world 를 늘려 풀 문제가 아니라 **그 구간에 발화점이
  없어서** 생긴 공백이다 — 새 battery 격자(150/160/170)가 이걸 겨냥한다.
- 아래 숫자들은 전부 world 2 개(seed 1·2) 위에서 잰 값이다. 앞으로의 라벨은 seed 1 한 세계로
  고정되므로, seed 2 행은 **기존 자산으로 남기되 새로 늘리지 않는다**(섞어 쓸 때 그 사실을 기억할 것).
- surrogate 재학습을 안 했으므로 "라우터가 surrogate 로 보낸 뒤 실제 결정이 좋아지는가"는 미측정.
- `_pick_battery_target` 의 같은 술어 의존은 **고치지 않았다**(§7). 관측된 피해는 없지만 잠재 위험.
- 전체 테스트 스위트를 다 돌리진 않았다(위 두 개만). 이번 변경은 기존 피커를 건드리지 않고 뒤에
  폴백만 붙였으므로 회귀 위험은 낮다고 판단했다.
