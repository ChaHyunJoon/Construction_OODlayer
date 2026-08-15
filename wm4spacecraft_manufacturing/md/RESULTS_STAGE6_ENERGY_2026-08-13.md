# 단계 6 — 630판 스윕 재실행 (신세대) 결과

> ## 🟢 신세대 (2026-08-13 목적함수 통일 **이후**)
>
> 이 문서는 **에너지가 목적함수 J 에 들어간 뒤** 처음 만들어진 630판이다.
> 판정 계약: 산출물의 `objective_hash` == 현재 `objective.json` 의 해시 **그리고**
> `energy_objective` == 1. 이 스윕의 630행 **전부**가 그 쌍을 만족한다.
>
> | | |
> |---|---|
> | `objective_hash` | `59b1174118b874ed` (630/630 행) |
> | `energy_objective` | `1` (630/630 행) |
> | `generation` | `2026-08-13-energy-activation` |
> | 코드 세대 (provenance) | git `5d35bcf` (210/210 샤드) |

## 1. 무엇을 돌렸나

| | |
|---|---|
| 격자 | 7 case × 30 seed × 3 policy = **630 판** (210 샤드) |
| 드라이버 | `run_4pol_parallel.sh --jobs 40` |
| 벽시계 | **60 분** (18:33:26 → 19:33:39). 계획 부록 A 추정은 3~8시간(병렬) |
| 결과 | **ok 210 / fail 0 / deadline 0** |
| 구세대 보존 | 이전 샤드 트리는 `results_4pol_oldgen_2026-08-13/` 로 옮겨 보존 |

`--jobs 40` 은 CLAUDE.md 의 "프로세스당 ~2.5GB" 가정이 아니라 **실측**으로 정했다:
`VmHWM` 피크가 **1.46 GB** 였고, DSPy 서비스가 동시 40 요청을 1.1s 에 처리하는 것을 먼저 확인했다.
스윕 중 **관측된**(연속 측정이 아니라 T+5분·T+15분 표본) 사용량은 38 GB / 가용 117 GB —
진짜 최대값은 재지 않았으므로 "최대 38 GB" 라고 읽지 말 것.

## 2. 완전성 검증 — 상태파일이 아니라 provenance 로

`run_4pol_parallel.sh` 의 요약은 `_night/status_shards.jsonl` 을 읽는데, 그 파일은 **런 사이에
누적된다.** 이번에 실제로 그 함정을 밟을 뻔했다: 스윕 시작 시점에 그 파일에는 **02:23 런의
210개 `ok` 항목**이 이미 들어 있었고, 요약 파서는 `(case,seed)` 당 "마지막이 이긴다"로 접는다.
이번 스윕이 어떤 샤드를 **아예 못 돌렸다면 옛 `ok` 가 살아남아 "210개 전부 ok" 라는 거짓 합격**이
나왔을 것이다. 첫 샤드가 완료되기 전에 그 파일을 `status_shards_oldgen_0223.jsonl` 로 회전시켰다.

그와 별개로 **독립 검증**을 돌렸다(상태파일을 전혀 안 봄):

| 검사 | 결과 |
|---|---|
| `.shard_meta` provenance 도장이 HEAD(`5d35bcf`)와 일치 | **210 / 210** |
| 총 행 수 | **630** |
| 고유 `(case, ood_seed, policy)` | **630** (중복 0, 자리 잘못 잡은 샤드 0) |
| `objective_hash` 분포 | `59b1174118b874ed` × 630 (단일) |
| `energy_objective` 분포 | `1` × 630 (단일) |
| 완주 런 중 `energy_J > 0` | **420 / 420** |
| 이상행(makespan 없음 / 완주인데 에너지 없음) | **0** |

마지막 두 줄이 이 스윕의 존재 이유다. 이 저장소의 **모든** 기존 덤프는 완주 런에 `energy_J` 가
없어 `verify.py` 가 하드 스톱했다. 이 세대는 420 완주 런 전부가 J 계산 가능하다.

## 3. 에너지 결정력 (spec §9 무력 검사) — **처음으로 측정됨**

CLAUDE.md 는 이 값이 "**아직 측정 안 됐다**"고 적고 있었다(기존 덤프는 전부 미완주만 있거나
`energy_J` 자체가 없었다). 이 세대에서 처음 잰다:

| | |
|---|---|
| 평가된 instance | 210 (에너지가 실제로 관여한 그룹 204) |
| **에너지가 a\* 를 바꾼 instance** | **15 / 204 = 7.35 %** |
| 오류 / 에너지 결측 / 스키마 드리프트 | **0 / 0 / 0** |
| 덤프 세대 == 현재 세대 | **True** |

**결론: κ = 0.01 에서 에너지 항은 무력하지 않다.** 15건 전부 선택을 `surrogate` → `dspy` 로 옮겼다.
(도구: `report_energy_decisiveness.py`. 이 스윕은 instance×macro 격자가 아니라 case×seed×policy
격자이므로 `instance = <case>_s<seed>`, `arm = policy` 로 사상해 쟀다 — 오라클 라벨 격자에서의
결정력과 **같은 수치가 아니다**.)

## 4. 정책 비교 — 신세대 J 기준

`J = complete ? makespan + w_E·energy_J : C_fail + C_unclosed·(total−closed) + tie_eps·makespan`

| case | policy | 완주 | 중앙 makespan | 중앙 energy[J] | **중앙 J** |
|---|---|---|---|---|---|
| battery | noop | 30/30 | 18.60 | 73320 | **18.79** |
| battery | surrogate | 25/30 | 22.25 | 107684 | 22.68 |
| battery | dspy | 30/30 | 18.60 | 73320 | **18.79** |
| fault | noop | **0/30** | — | — | 25900.12 |
| fault | surrogate | 25/30 | 22.25 | 107684 | **22.68** |
| fault | dspy | 25/30 | 22.40 | 107806 | 22.96 |
| all | noop | **0/30** | — | — | 22650.12 |
| all | surrogate | 23/30 | 31.70 | 133001 | **33.64** |
| all | dspy | 29/30 | 33.68 | 137876 | 39.39 |
| fault_battery | noop | 2/30 | 18.60 | 73320 | 25600.12 |
| fault_battery | surrogate | 25/30 | 22.25 | 107684 | 22.68 |
| fault_battery | dspy | 29/30 | 21.62 | 91372 | **22.00** |
| fault_zone | noop | **0/30** | — | — | 24750.12 |
| fault_zone | surrogate | 28/30 | 34.06 | 138429 | 34.79 |
| fault_zone | dspy | 29/30 | 33.15 | 135565 | **33.55** |
| battery_zone | noop | 2/30 | 18.60 | 73320 | 14700.13 |
| battery_zone | surrogate | 28/30 | 34.06 | 138429 | 34.79 |
| battery_zone | dspy | 30/30 | 30.18 | 107497 | **30.46** |
| zone | noop | **0/30** | — | — | 14700.13 |
| zone | surrogate | 30/30 | 37.30 | 138175 | 37.66 |
| zone | dspy | 30/30 | 32.59 | 119255 | **32.88** |

전체 pooled (각 n=210): `noop` 중앙 J **19000.12** · `surrogate` **33.24** · `dspy` **29.57**.

## 5. ⚠ 해석의 한계 — 반드시 같이 읽을 것

### 5.1 battery case 는 이 레인에서 **물리적으로 무해하다**

`tools/monitor/run_demo.jl:482` 는 `CB.enable_battery!` **만** 부른다. `set_battery_stall!` 도
`set_battery_derate!` 도 부르지 않고, 둘 다 기본값이 `enabled = false` 이며
(`src/navigator/battery.jl:489`, `:539`) stall 이 꺼져 있으면 속도계수는 언제나 1.0 이다(`:576`).

**즉 이 스윕에서 배터리가 방전돼도 로봇은 멈추지도 느려지지도 않는다.** 사건은 발화하고 NL 은
"it has stopped where it stands and cannot drive or carry" 라고 말하지만 **물리적 효과가 0** 이다.
데이터가 그것을 그대로 보여준다:

- `battery` / `noop` 은 30/30 완주하고 **고유 makespan 이 1개뿐**이다(30 시드가 전부 동일 결과).
- `battery` / `dspy` 는 `SwapBattery` 를 120회 **유효하게 선택·적용**했는데도 결과가
  `noop` 의 `NOOP` 과 **시드별로 바이트 동일**하다 — 고칠 것이 없기 때문이다.
- `battery` / `surrogate` 는 `Replace`/`ReformTeam` 을 걸어 **오히려 나빠진다**(25/30, J 22.68).

저장소 자신의 주석이 이것을 독립적으로 확인해 준다 — `gen_oracle_dataset.jl:1174` 는 derate 가
없으면 "0.3 과 0.5 가 둘 다 속도배율 1.0 이라 다시 **한 점으로 겹친다**" 고 적고 있다.
관측된 "고유 makespan 1개" 가 정확히 그 겹침이다.

**정밀하게 말하면:** `enable_battery!` 는 `install_battery_objective_hook!()`(SoC 편향 목적식)도
설치하므로 SoC 가 원리적으로 완전히 무시되는 것은 아니다. 다만 CLAUDE.md 가 적어 둔 대로 그
경로는 이 레인에서 발화하지 않는다(greedy 는 t=0 에만 돌고 그때 `EDGE_COST_MULTIPLIER[]` 가
`nothing`, `rebalance_for_battery!` 는 빌드 중간에 후보 간선이 0개). 어느 쪽이든 **결정적 증거는
메커니즘이 아니라 관측**이다: 30 시드 · 고유 makespan 1개 · `SwapBattery` 와 `NOOP` 이 바이트 동일.

**그러므로 이 표의 battery 열로 "정책이 배터리 고장을 얼마나 잘 다루는가"를 읽으면 안 된다.**
읽을 수 있는 것은 "존재하지 않는 문제에 개입하면 손해"라는 것뿐이다.
(`gen_oracle_dataset.jl` 의 라벨러 레인은 `_arm_battery!` 로 stall/derate 를 켜므로 **다른 물리**다.
두 레인의 battery 결과를 같은 축에 올리지 말 것.)

### 5.2 surrogate 는 battery / fault / fault_battery 를 **구분하지 못한다**

세 case 에서 surrogate 의 매크로 분포가 **완전히 같다**: `Replace`×120, `ReformTeam`×49.
결과도 시드별로 바이트 동일하다. `fault_zone` 과 `battery_zone` 도 서로 동일하다
(zone 유무만 구분한다). 반면 `dspy` 는 case 별로 다른 매크로를 낸다
(battery→`SwapBattery`, fault→`Replace`/`Deprioritize`/`ReformTeam`).

이는 "surrogate 가 상태를 읽는다"는 전제에 대한 직접적인 반례다. spec §8 단계 7(재라벨·재학습)이
겨냥하는 문제와 같은 뿌리일 가능성이 높지만, **이 스윕은 그 인과를 증명하지 않는다.**

### 5.3 스케일 재교정은 **측정만 하고 적용하지 않았다**

| 스케일 | 구세대 | **신세대(이 스윕)** | 변화 |
|---|---|---|---|
| `M_ref` | 31.225 | **25.8625** | −17.2 % |
| `E_ref` | 121818.2 | **111127.7** | −8.8 % |
| `Eg_scale` | 418.62 | **381.88** | −8.8 % |
| `w_E = κ·M_ref/E_ref` | 2.563e−6 | **2.327e−6** | −9.2 % |

(n=420 완주 런, `--generation current` 로 세대 단일성 확인)

**적용하지 않은 이유 — 순환이다.** `M_ref`/`E_ref` 는 `objective_hash` 의 입력이다. 이 값을 쓰면
해시가 바뀌고, 그 순간 **방금 만든 630행이 전부 "구세대"로 재분류되어** `verify.py` 가 하드
스톱한다. 즉 재교정은 자기가 나온 스윕에 적용할 수 없다 — 적용하려면 **재교정 + 재스윕**을
한 묶음으로 결정해야 한다. 여기서는 숫자만 남긴다.

### 5.4 `build_final_table.py` 는 아직 못 돈다 (단계 7 게이트)

`REAL_RC=1`. 실패 지점은 이 스윕이 아니라 **오라클 덤프**다:
`compute_ceilings(oracle_dir)` → `instance='fault_s1_sev1.0_sp3_f58' ... energy_J=None`.
`kind=fault` 라벨 행에 에너지가 없어서다 — spec §8 **단계 7** 이 닫을 문제이며
`md/STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md` 에 조사 결과를 적어 뒀다(요약: 이 저장소에는
동역학을 바꾸지 않는 **energy-only** 모드가 이미 있고, `run_demo.jl` 이 바로 그 모드로 돌고 있다.
그래서 라벨러에도 같은 방식을 쓰면 fault/zoneblk 도 동역학 변경 없이 J 채점이 가능해진다).

## 6. UI 발행

- `publish_streams.sh --clean` → 21 스트림 발행, **깨진 심링크 0**.
  (주: 구세대 보존을 위해 샤드 트리를 옮기면서 기존 21개 심링크가 끊겼었다. 이 발행이 그것을
  신세대 대상으로 복구한 것이다.)
- `regen_router_cases.sh` (`DEMO_ROUTER=auto`, `DEMO_POLICY=router`) → battery/fault/zone 3판을
  **auto-routing** 산출물로 렌더(3/3 ok, 전부 `PROJECT COMPLETE`). 대시보드의 `ENACTED POLICY`
  기본값 `auto (legacy / router run)` 이 접미사 없는 이름을 읽으므로 `tractor__<case>.*` 와
  `tractor__<case>__router.*` **양쪽 이름으로** 낸다. 라우터는 두 갈래를 모두 보여 준다:
  battery(p=0.107)·fault(p=0.301) 은 *familiar → surrogate*, zone(p=0.005) 은
  *NEVER SEEN → ask the LLM → dspy*.
- 살아 있는 서버로 종단 확인(`POST /artifact`): 6개 조합 전부
  `stream_exists=true, anim_exists=true, anim_stale=false`.

### 6.1 🔧 `render_demo.jl` 에 목적함수 배선이 **아예 없었다** (이 작업에서 고침)

첫 렌더 3판은 `STATUS render ok cases=3/3` 로 통과했지만 **구세대 동역학으로 만들어진 것이었다.**
자기검토에서 발견한 사실:

- `run_demo.jl:433` 에는 `ENERGY_ON → CB.init_objective_weights!()` 블록이 있는데
  **`render_demo.jl` 에는 그 블록이 없었다**(`run_header.jl`·`policy.jl` 에도 없음).
  `ENERGY_OBJECTIVE=1` 을 줘도 **그냥 무시됐다.**
- `AUTO_EFFICIENCY_KAPPA` 의 기본값은 `nothing` 이고(`essential_tg_coponents.jl:1319`),
  `get_objective_expr` 의 auto 경로는 `AUTO_EFFICIENCY_KAPPA[] !== nothing` 일 때만 발화한다
  (`:1439`). 따라서 이 레인의 **모든 MILP 재풀이에 에너지 항이 실리지 않았다.**
- 그리고 이 레인은 `run_demo.jl` 과 달리 **중립이 아니다**: `render_demo.jl:731` 이
  `RESPEC_ENABLED[] = true` 로 두고 respec 재풀이를 실제로 돌린다(run_demo.jl:484 는 `false`).
  초기 배정은 `assignment_mode=:greedy` 라 양쪽 다 안 바뀌지만, **OOD 이후의 재계획이 달라진다.**

고친 방법: `run_demo.jl` 의 블록을 그대로 옮겨 심고(같은 `ENERGY_OBJECTIVE` 스위치, 같은 로깅)
세대 딱지도 로그에 남겼다. 산출물이 스트림/애니 뿐이라 행에 박을 자리가 없어 **로그가 유일한
provenance** 다. 고친 뒤 3판을 **다시 렌더**했고, 세 로그 전부 이렇게 찍힌다:

```
>>> objective weights: κ=0.01 w_g=0.000745904473072587
>>> objective_hash: 59b1174118b874ed  energy_objective=1
```

**교훈:** 산출물 존재·라우터 발화·신선도 검사는 전부 통과하는데도 판은 구세대일 수 있었다.
이 레인은 세대 딱지를 산출물에 못 박으므로, 로그의 저 두 줄이 없으면 **세대를 사후 판정할
수단이 없다** — 앞으로 UI 판을 인용할 때 저 두 줄을 먼저 확인할 것.

## 7. 재현

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
bash run_4pol_parallel.sh --jobs 40                      # 210 샤드 (신세대)
.venv/bin/python merge_shards.py --shards-dir results_4pol/shards --out-dir results_4pol \
  --cases battery,fault,all,fault_battery,fault_zone,battery_zone,zone --seeds $(seq -s, 1 30)
.venv/bin/python measure_objective_scales.py --generation current \
  --glob 'results_4pol/shards/*/s*/rows.jsonl'
```

**주의:** 재실행 전에 `_night/status_shards.jsonl` 을 회전시킬 것(§2 참조).
