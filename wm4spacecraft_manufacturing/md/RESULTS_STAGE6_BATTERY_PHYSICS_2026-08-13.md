# 단계 6 (2차) — 배터리 물리 복구 + 전역 κ 우선순위 후 630판 재실행

> ## 🟢 현행 세대
>
> | | |
> |---|---|
> | `objective_hash` | **`19819377a7f8ebb2`** (630/630 행) |
> | `generation` | `2026-08-13-global-kappa-precedence` |
> | `energy_objective` | `1` (630/630) |
> | `battery_physics` | `stall=true@0.15 · derate=true@0.5 · capacity=8.28e6 J` (630/630, 단일) |
>
> 이 문서가 **현행 측정치**다. 같은 날 19:33 에 끝난 1차 스윕
> (`RESULTS_STAGE6_ENERGY_2026-08-13.md`, `generation=2026-08-13-energy-activation`)은
> 구세대다 — 다만 그 문서의 §5.1 이 **이 재실행의 동기**이므로 남겨 둔다.

## 1. 왜 다시 돌렸나

1차 스윕에서 드러난 것: **`run_demo.jl` 에서 배터리가 방전돼도 로봇이 멈추지 않았다.**
`enable_battery!` 만 부르고 `set_battery_stall!`/`set_battery_derate!` 를 부르지 않았는데 둘 다
기본값이 `enabled=false` 였다. 그래서 배터리 OOD 는 "로봇이 그 자리에 멈췄다"는 자연어를
생성하면서 **물리적 효과가 0** 이었고, `noop` 이 battery case 를 30/30 완주했다.

추가로 용량이 `demo_battery_params(shrink = 25.0)` 로 25배 축소돼 있었다. 그건 짧은 데모에서
방전을 눈에 보이게 하려는 **시각화용 해킹**이지 물리가 아니다(battery.jl:85-91).

## 2. 무엇을 고쳤나

### 2.1 용량 — 축소를 없앴다 (`shrink=25` → 없음)

스펙 기본값 2.3 kWh(8.28e6 J)와 스펙 전력값으로 계산한 지속 가동시간:

| 부하 | 전력 | shrink=25 (옛) | **축소 없음 (현행)** |
|---|---|---|---|
| 조작(manipulate, 최대) | 1000 W | 5.5 분 | **2.30 시간** |
| 운반(carry, 짐 100 kg) | ~833 W | 6.6 분 | 2.76 시간 |
| 보행(무부하) | 500 W | 11 분 | 4.60 시간 |
| 실측 함대평균 | 394 W | 14 분 | 5.8 시간 |

실제 작업로봇이 충전 없이 두어 시간 일하는 것과 맞다. 30~40초 빌드에서 배터리가 눈에 띄게
닳는 것은 물리적으로 성립하지 않는다.

**측정된 귀결:** 자연 방전은 무시할 수준이다 — 스모크에서 `mean_soc = 0.944`, 즉
**SoC 를 떨어뜨리는 것은 주입된 OOD 뿐**이다. 부수적으로 `battery_edge_multiplier` 도
(`soc ≥ soc_target=0.5` 이므로) 정확히 1.0 이라 평상시 목적식을 건드리지 않는다.

### 2.2 방전 → 정지 / 감속을 켰다

```julia
CB.set_battery_stall!(enabled = true, threshold = 0.15, clear = true, obstacle = false)
CB.set_battery_derate!(enabled = true, hi = 0.5, min_factor = 0.35)
```

**라벨러 레인(`gen_oracle_dataset.jl:_arm_battery!`)과 같은 값**이다. 두 레인이 다른 물리를
쓰면 오라클 라벨과 4pol 평가를 같은 축에 못 올린다.

`soc_speed_factor` 의 `BATTERY_STALL[].enabled || return 1.0` 은 **지우지 않았다** — 그건
버그가 아니라 이 기능의 on/off 스위치 자체이고, 지우면 옵트인한 적 없는 모든 레인에서
모션 게이트가 켜지며 `tools/checks.jl:159-183` 이 깨진다. 팀 최저 SoC 로 속도를 맞추는 로직은
이미 `soc_speed_factor` 안에 구현돼 있다(`f = min(f, ...)`).

⚠️ 알려진 결합: `soc_speed_factor` 가 stall 여부로 조기반환하므로 **derate 는 stall 이 켜져
있을 때만 동작한다.** derate 만 켜는 조합은 조용히 무동작이다.

### 2.3 `render_demo.jl` 에도 같은 물리를 넣었다

대시보드 렌더 엔진이 같은 결함을 갖고 있었다(`:763`). 두 엔진의 물리가 다르면 화면에 보이는
판과 표의 근거가 다른 세계가 된다.

### 2.4 전역 κ 가 레인별 `ENERGY_W` 를 이긴다

`get_objective_expr` 의 auto 경로 조건에서 `w_eff == 0.0 &&` 를 제거했다. 예전에는 명시적으로
설정된 `efficiency` 가 전역 κ 를 조용히 눌러서, spec §4 의 "κ 하나를 돌리면 세 자리가 같이
움직인다"가 `ENERGY_W` 를 쓰는 5개 레인(`tools/e2e.jl:685`, `tools/demos.jl:1123·1288·1586·2759`)
에서 거짓이었다.

**정직한 범위:** 그 5개 레인은 `init_objective_weights!` 를 부르지 않아 κ 가 `nothing` 이므로
**당장 그 레인들의 숫자는 안 바뀐다.** 실효는 (a) 앞으로 둘 다 하는 레인에서 κ 가 단일 계수로
작동하고, (b) `demos.jl:1420·1748` 의 의도적 `efficiency = 0.0` OFF 스위치가 κ 설정 시 덮인다는 점.

### 2.5 세대 축을 하나 더 박았다

동역학이 바뀌었지만 `objective.json` 의 스칼라는 하나도 안 바뀌므로 **해시로는 구분되지
않는다.** 그래서 레코드에 `battery_physics{stall, stall_soc, derate, derate_hi, capacity_J,
n_stalled}` 를 추가하고 `generation` 을 올렸다.

**`n_stalled` 가 특히 중요하다.** 이 레인은 `run_demo.jl:472` 에서 `global_logger` 를
`Logging.Warn` 으로 심는데 `battery.jl:297` 의 `[STALL] ...` 는 `@info` 라 통째로 버려진다.
즉 **"로그에 STALL 이 없다"가 "정지가 없었다"의 증거가 되지 못한다** — CLAUDE.md 가 실제
오판 전력이 있다고 경고한 함정이다. 이 필드가 유일한 기계적 증거다.

## 3. 스윕 결과

| | |
|---|---|
| 격자 | 7 case × 30 seed × 3 policy = **630판** (210 샤드) |
| 벽시계 | **62분** (21:41:18 → 22:43:02), `--jobs 40` |
| 결과 | **ok 210 / fail 0 / deadline 0** |

독립 검증(상태파일이 아니라 행 내용으로):

| 검사 | 결과 |
|---|---|
| 총 행 / 고유 `(case,seed,policy)` | **630 / 630** |
| `objective_hash` | `19819377a7f8ebb2` × 630 (단일) |
| `battery_physics` 설정 | 630행 **전부 동일** |
| **정지가 일어난 행 / 총 정지 수** | **105행 / 126회** |
| 완주 388행 중 `energy_J > 0` | **388 / 388** |
| 이상행 | **0** |

## 4. 배터리 case 가 드디어 정책을 가른다

| case=battery | 구세대(무해) | **현행(물리 복구)** |
|---|---|---|
| `noop` | 30/30 완주, J **18.79** | **0/30 완주**, 정지 43회, J **26200** |
| `surrogate` | 25/30, J 22.68 | 29/30, J 23.26 |
| `dspy` | 30/30, J 18.79 (**noop 과 바이트 동일**) | **30/30, J 19.79** |

예전에는 **"아무것도 안 하는 것"이 공동 1위**였다. 이제는 완전히 실패한다.

**정지는 배터리가 낀 case 에서만, 그리고 `noop` 에서만 일어난다:**
battery 43 · all 21 · fault_battery 25 · battery_zone 37 / fault·fault_zone·zone 은 0.
`surrogate`·`dspy` 는 **모든 case 에서 정지 0회** — 로봇이 방전되기 **전에** 개입해
(SwapBattery/Replace) 정지를 예방한다는 뜻이다. 인과사슬이 끝까지 작동한다는 강한 증거다.

### 전체 표

| case | policy | 완주 | 고유 makespan | 정지 | 중앙 J |
|---|---|---|---|---|---|
| battery | noop / surrogate / dspy | 0/30 · 29/30 · 30/30 | 0 · 23 · 1 | 43 · 0 · 0 | 26200 · 23.26 · **19.79** |
| fault | | 0/30 · 29/30 · 26/30 | 0 · 23 · 22 | 0 · 0 · 0 | 26200 · **23.26** · 30.12 |
| all | | 0/30 · 21/30 · 28/30 | 0 · 21 · 25 | 21 · 0 · 0 | 26200 · 27.46 · **24.21** |
| fault_battery | | 0/30 · 29/30 · 28/30 | 0 · 23 · 11 | 25 · 0 · 0 | 26200 · 23.26 · **20.06** |
| fault_zone | | 0/30 · 26/30 · 26/30 | 0 · 24 · 25 | 0 · 0 · 0 | 22950 · **26.80** · 31.77 |
| battery_zone | | 0/30 · 26/30 · 30/30 | 0 · 24 · 28 | 37 · 0 · 0 | 22950 · 26.80 · **23.04** |
| zone | | 0/30 · 30/30 · 30/30 | 0 · 29 · 29 | 0 · 0 · 0 | 14700 · 27.63 · **26.57** |

전체 pooled (각 n=210): `noop` 중앙 J **26200.12** · `surrogate` **26.69** · `dspy` **23.63**
(평균은 각각 23318.69 · 2217.69 · 1077.89).

## 5. 에너지 결정력

| | 1차(구세대) | **현행** |
|---|---|---|
| 에너지가 a\* 를 바꾼 instance | 15/204 (7.35%) | **12/204 (5.88%)** |
| 오류 / 에너지 결측 | 0 / 0 | **0 / 0** |

κ=0.01 에서 에너지 항은 여전히 무력하지 않다.

## 6. 남아 있는 한계

1. **surrogate 는 여전히 battery/fault/fault_battery 를 구분하지 못한다** — 세 case 에서
   완주 29/30, 고유 makespan 23, 중앙 J 23.26 이 **완전히 같다**(fault_zone·battery_zone 도
   서로 같다). 물리를 고친 뒤에도 남았으므로 **배터리 결함의 부산물이 아니라 surrogate 자체의
   결함**이다. spec §8 단계 7(재라벨·재학습)이 겨냥할 지점.
2. **`dspy`/battery 의 고유 makespan 이 1** — 30/30 완주하되 결과가 한 점이다. 구세대의
   "아무 일도 없어서 같음"과는 다르다(그때는 noop 과 바이트 동일했고 지금은 noop 이 0/30 이다).
   SwapBattery 가 명목 운전을 완전히 복원한다는 해석이 자연스럽지만 **확인되지 않았다.**
3. **라벨러 레인의 용량은 아직 `DS_SHRINK=200`** (= 41,400 J, 최대부하 41초). 같은 물리
   논증이 그대로 적용되지만, 고치면 `n44_plus78` 라벨셋이 무효가 되므로 **단계 7 의 첫 항목**이다.
4. `build_final_table.py` 는 여전히 exit 1 — 오라클 ceiling 이 단계 7 에 게이트돼 있다.

## 7. 계약 재확인

`Pkg.test()` **11 pass / 1 error**(문서화된 baseline) · `test_objective.py` · `audit_objective.py`
**9/9** · `audit_action_vocab.py` · `test_surrogate_support.py` 전부 exit 0 ·
`test/objective_hooks_smoke.jl` 1/1 · `test/greedy_cost_dispatch_equivalence.jl` 전 testset 통과.

## 8. 재현

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
mv _night/status_shards.jsonl _night/status_shards_prev.jsonl   # ★ 누적 파일이라 반드시 회전
bash run_4pol_parallel.sh --jobs 40
.venv/bin/python merge_shards.py --shards-dir results_4pol/shards --out-dir results_4pol \
  --cases battery,fault,all,fault_battery,fault_zone,battery_zone,zone --seeds $(seq -s, 1 30)
```

구세대 보존: `results_4pol_gen_energyactivation/`(1차) · `results_4pol_oldgen_2026-08-13/`(그 이전).
