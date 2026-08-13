> 🔴 **구세대 측정치(2026-08-06 세대, 옛 창고 기하).** 현재 성능은 `RESULTS_D20_2026-08-12.md`
> (D=20 근거리 창고) 를 볼 것. 중간 세대인 `RESULTS_FARDEPOT_2026-08-12.md`(D=40 원거리) 도
> 이미 대체됐다 — 그쪽을 거쳐 가지 말 것. 현재 기하도 "가까운 창고"(D=20)라서 이 문서를
> "가까운 창고 세대"라고 부르면 현재 세대와 구별이 안 된다: 이 문서는 **창고 거리를 명시적으로
> 스윕하기 이전**의 기하다.

# 확률적 OOD 스트림 위의 LLM 재명세 — 구현과 측정

작성 2026-08-06. 선행: `PLAN_LLM_INFERENCE_7H_2026-08-06.md`(계획) · `STATUS.md`(재개 지점) ·
`README.md` §1 용어 / §8 함정.

> **한 줄 요약.** fault / battery / no-go zone 이 **하나의 추첨**으로 시점·종류·심각도를 뽑아 오는
> 스트림을 만들고, 그 위에서 DSPy(gpt-4o) 가 사건마다 재명세를 결정해 씬트리를 고치도록 배선한 뒤,
> 네 축(완주율·옳은 결정 비율·빌드 시간·에너지)으로 5개 시드 × 4 정책 = 20판을 측정했다.
>
> **결과 (5 시드, §5).** 개입하지 않으면 **5판 전부 미완주**. 규칙과 배포 서로게이트는 4/5,
> **LLM 은 5/5 완주**하며 기준 행동 적중률 90%(18/20) · 완주판 시뮬 시간 41.0 s(규칙 66.3) ·
> 닫힌 노드당 에너지 538 J(규칙 971)를 냈다. 시드 5개로는 부호검정이 원리적으로 p<0.05 를
> 낼 수 없으므로(최소 0.062) **유의성은 주장하지 않는다.**

*(§1~§3 은 무엇을 왜 만들었는지, §4 는 재현 방법, §5 가 결과, §6 은 돌린 검사, §7 이 못 한 것.)*

---

## 1. 이 작업 전에 막혀 있던 것

계획서가 다섯 천장(Ch-A~Ch-E)으로 분해한 것 중 이번에 실제로 닫은 것과, 닫는 도중 드러난
**새 버그 두 개**를 함께 적는다. 후자가 사실 더 중요했다 — 계획서에 없던 것들이고, 둘 다
"측정을 조용히 무효로 만드는" 종류였기 때문이다.

| # | 무엇이 막혀 있었나 | 증거 | 조치 |
|---|---|---|---|
| **Ch-A** | 행동 어휘가 6곳에 따로 박혀 있었고 서로 달랐다. `llm_producer.MACRO_NAME` 과 `dspy_service.MACROS` 에 **`SwapBattery`(8) 가 없었다** | README §4 가 battery 의 기본 정답이라 못박은 팔을 **LLM 이 발화할 수 없었다** | `action_registry.json` 단일 진실원 + 6곳 배선 + `audit_action_vocab.py` |
| **버그 1** | `DEMO_POLICY=noop` 이 안 먹는다 (STATUS §5, 원인 미규명이던 것) | noop lane 이 3건 모두 `Replace` 를 실행 | 원인 = **라우터가 POLICY 를 덮어씀**. `route()` 에서 noop 은 라우팅 대상에서 제외 |
| **버그 2** | 빌드 중반 `RelocateBuild` 가 **시뮬을 죽인다** | `@assert has_edge(scene_tree, assembly, id)` (실측: closed=151, Δ=2.4 m) | 원인 = `RESPEC_ENABLED` 가 4가지를 한꺼번에 껐다. `RESPEC_DRIFT_REPAIR` 로 분리 |
| **없던 것** | zone 은 **언제나 sim 전에 1회 고정**으로 터졌다 | `run_demo.jl` 의 `:zone` 분기가 스텝 전에 주입 | `DEMO_OOD_STREAM3=1`: 세 종류를 한 추첨으로 |
| **없던 것** | 라이브 스트림의 결정을 "옳았나"로 채점할 기준이 없었다 | 요약 행에 완주 여부·closed 뿐 | `reference_policy.py` (격자 실측에서 유도, 62 instance 로 검증) |

### 1-a. 버그 1 — 바닥선이 바닥선이 아니었다

`decide_all` 의 실행 정책 선택은 이렇게 되어 있었다:

```julia
requested = get(rt, "enabled", false) ? String(rt["target"]) : POLICY
```

`DEMO_ROUTER` 의 기본값은 `auto` 이고 교정파일이 설치돼 있으면 라우터가 켜진다. 라우터의
`target` 은 `surrogate` 또는 `dspy` 뿐이므로, **`DEMO_POLICY=noop` 은 구조적으로 실행될 수
없었다.** STATUS §5 가 "환경변수 전달은 범인이 아니다"라고 적어둔 것이 맞았고, 범인은 그 다음 줄이었다.

no-adapt 바닥선은 "정책 후보"가 아니라 **통제 실험의 대조군**이다. 개입이 실제로 이득인지 재려면
아무도 이 lane 을 대신 판단해 주면 안 된다. 그래서 `POLICY == "noop"` 이면 라우팅을 끈다.

같은 이유로 **표현력 에스컬레이션 두 곳도 라우터가 켜졌을 때만** 발화하도록 게이트를 걸었다.
예전에는 라우터 설정과 무관하게 항상 돌아서, `DEMO_ROUTER=0` 으로 "정책을 고정했다"고 적은
비교 실행이 사건에 따라 조용히 dspy 로 넘어갔다 — "surrogate 를 쟀다"는 판이 사실은 LLM 판이 된다.

### 1-b. 버그 2 — 크래시 복구 코드가 게이트 하나 때문에 도달 불가였다

`close_node!(::CloseBuildStep)` 에는 이미 이 상황을 위한 완화 코드가 있다. 주석까지 정확하다:

> "A respec RECOVERY (e.g. a restage that translated this assembly AFTER this part was already
> delivered) can leave a delivered part desynced from its slot, so capture fails and the @assert
> below would CRASH the whole sim."

그런데 그 블록이 `RESPEC_ENABLED[]` 로 게이트돼 있었다. `run_demo.jl` 은 프레임워크 respec **큐**를
우회해 자기가 직접 복구를 집행하므로 `RESPEC_ENABLED[] = false` 로 둔다 — 그래서 정작 그 상황을
위해 쓰인 코드에 도달하지 못했다.

`RESPEC_ENABLED` 는 실제로 네 가지를 한꺼번에 켜고 끈다: ① respec 큐 처리 ② OOD 의 큐 적재
③ `_enforce_serial_frontiers!` ④ 포획 드리프트 완화. ④ 만 성질이 다르다("누가 복구를 모는가"가
아니라 "복구가 이미 일어난 뒤의 씬을 어떻게 다룰 것인가"). 그래서 `RESPEC_DRIFT_REPAIR` 로 분리하되
**기본값을 `nothing`(= `RESPEC_ENABLED` 를 따라감)** 으로 두어 기존 실행·덤프의 재현성은 그대로 뒀다.

---

## 2. 확률적 3종 스트림

`DEMO_OOD_STREAM3=1` + `DEMO_OOD_SEED=s` 이면 `[lo, hi]` 진척 구간에 균등 슬롯 ± 반슬롯 jitter 로
발화점을 뽑고, 각 점에서 **종류를 추첨**한다:

| 종류 | 주입 | 심각도 추첨 |
|---|---|---|
| `fault` | `fault_action(safe=true, obstacle=false)` — 단독 운반체만 | — |
| `battery` | `battery_action(soc_drop=…)` | 확률 `sev_frac` 로 깊은 방전(SoC→0), 아니면 완만한 열화 |
| `zone` | `inject_blocking_zone!` — **실제로 막는** 구역 | 후보 실패 시 무해 가족으로 폴백 |

zone 을 무작위 스트림에 넣을 수 있게 된 이유가 핵심이다. 예전에 zone 이 sim 전 1회로 고정됐던 것은
`ForbidZone`(재적치)이 **조립체가 pristine 할 때만** 변환 안전하기 때문이었다. `RelocateBuild`
(빌드 전체 평행이동)에는 그 전제가 없으므로 빌드 도중에도 성립한다 — 버그 2 를 고치고 나서야
그것이 실제로 참이 됐다.

`inject_blocking_zone!` 은 `render_demo.jl` 의 검증된 절차를 그대로 옮긴 것이다: 아직 활성이 아닌
항법 목표만 후보 → 결정적 정렬 → `zone_relocatable` 통과분만 → 심은 뒤 `n_blocked ≥ 1` 로 **실제로
막혔는지 확인**, 아니면 지우고 다음 후보. (두 파일에 같은 절차가 있다는 사실은 두 곳 주석에 적어 뒀다.
`render_demo.jl` 은 덱 영상 4편의 녹화 경로라 손대지 않았다.)

---

## 3. 평가지표 4종과 "옳은 결정"의 정의

### 3-a. 네 축

| 축 | 정의 | 함정 |
|---|---|---|
| ① 완주율 | `project_complete` 비율 + Wilson CI | 완주 ≠ `closed == total` (종단 노드가 남는다) |
| ② 옳은 결정 비율 | 기준 행동 `a*` 대비 적중률 | **반사실 오라클이 아니다** — 아래 3-b |
| ③ 빌드 시간 | `sim_seconds = dt × steps`, **완주한 판만** | 섞으면 "실패가 빠르다"로 뒤집혀 읽힌다(정지 판정 대기 2500 step 때문) |
| ④ 에너지 | **닫힌 노드당 에너지** `J/closed` + min SoC | 총 에너지만 보면 **미완주가 유리하다**(일을 덜 해서) |

### 3-b. 기준 행동 `a*` 는 어디서 오는가 (가장 중요한 단서)

계획서 §0-a 의 `optimal_action_rate = P(a = a*)` 는 `a*` 를 요구한다. 격자 오라클에서 `a*` 는
"같은 사건을 모든 팔로 각각 굴려 본 결과의 최선"이다. 그런데 **무작위 스트림에서는 그 정의를 그대로
쓸 수 없다**: 사건 i 의 반사실을 재려면 결정 i 이후의 세계가 갈라지므로 사건마다 트리가 지수로
늘어난다(사건 4개 × 팔 4개 = 256 런, 런당 수 분).

그래서 `reference_policy.py` 는 격자에서 **실측된 정답 구조**를 규칙으로 옮겨 적는다. 이것은
반사실 오라클이 **아니라 측정에서 유도한 기준 정책**이고, 이 문서의 모든 "적중률" 숫자는 그
기준에 대한 것이다.

규칙과 그 근거:

| 종류 | 규칙 | 근거 (실측) |
|---|---|---|
| battery | SoC ≤ 0.2 → **SwapBattery**(메뉴에 없으면 Replace) · SoC > 0.2 → **NOOP** | `battgrid_0805_s1.jsonl` 18 instance. SoC 0.02 에서 NOOP 미완주 / Replace·SwapBattery 둘 다 완주 closed 291 **동일** → 동점은 비용으로 갈린다(0.2 < 1.0). SoC 0.3·0.5 는 세 팔 전부 완주 → 가장 싼 NOOP |
| fault | `agent_pending > 0` → **Replace** · `= 0` → **NOOP** | `firegrid_merged.jsonl` fault 42 instance, seed 1~6. **완전 분리**(24/24, 18/18). "고장났으니 교체"가 아니라 **일을 지고 있었는가**가 가른다 |
| zone | `nav_blocked > 0` **그리고** `root_covered == 0` → **RelocateBuild** · 그 외 → **NOOP** | `zcausal_reform/` STEP 10, 팔 교차 2사건. blk(root 0, 막힘 3): NOOP 정지 254 / Reloc 완주 279. cov(root 8, 막힘 1): NOOP 정지 232 / Reloc 정지 197 |
| reform | — | 실측 격자 없음 → **채점하지 않는다**(unscored). 없는 정답을 지어내지 않는다 |

`root_covered == 0` 조건이 붙는 이유: 막힘만 보는 규칙은 위 2사건 중 **1개만** 맞는다
(STATUS §1 "인과 규칙이 1/2"). 개입의 파괴력이 함께 들어가야 2/2 가 된다.

### 3-c. 규칙을 주장이 아니라 검사로 만들었다

`test_llm7h.py` 는 오라클 덤프의 **모든 instance** 에 대해 (a) 팔을 전부 굴린 결과의 사전식 최선과
(b) 규칙의 답을 맞대어 본다.

```
3. ★ 기준 정책 vs 오라클 실측 라벨
  battery 규칙 == 오라클 최선 (battgrid, n=18)     PASS  18/18
  fault   규칙 == 오라클 최선 (firegrid, n=42)     PASS  42/42
  zone    규칙 == 오라클 최선 (zcausal,  n=2)      PASS  [blk→RelocateBuild, cov→NOOP]
16/16 passed
```

zone 축은 **n=2** 다. 가장 약한 근거이고, 그 사실을 여기 그대로 적는다.

---

## 4. 재현 방법

```bash
# 0) LLM producer 서비스 (hjcrl venv, OPENAI_API_KEY 필요)
#    ★ DSPY_PROGRAM 을 존재하지 않는 경로로 주어 **seed 프로그램**을 쓴다.
#      컴파일된 dspy_real_program_gpt4o.json 은 배터리 전용이라 zone·RelocateBuild 어휘가 통째로
#      없다(STATUS §1 경고). 그걸로 zone 을 재면 어휘 밖 사건을 재는 것이 된다.
cd src/respec/llm_service
DSPY_MODEL=gpt-4o DSPY_PROGRAM=__seed_only__ \
  <hjcrl>/python.exe -m uvicorn dspy_service:app --host 127.0.0.1 --port 8090

# 1) 배선 검사 (LLM 불필요, 수 초)
cd wm4spacecraft_manufacturing
python audit_action_vocab.py     # 6/6 consistent
python test_llm7h.py             # 16/16 passed  (기준 정책 vs 오라클 라벨 포함)
# 2026-08-06 이후: dspy_service.SURRO_DATA 기본값이 wm_datasets.N44_PLUS78 로 바뀌었다(§5-f-이후).
# 옛 모델(§5의 것)을 재현하려면 서비스에 EVAL_DATA=oracle/out/graded_hs_n44.jsonl 을 준다.
python test_surrogate_support.py # support=[0,1,2,3,4,7,8], n=68 이어야 한다

# 2) 스위프 (★ 순차 실행 강제 — 병렬로 돌리면 MILP 가 다른 스케줄을 내 비교가 무효)
python llm_ood_eval.py run --seeds 1,2,3,4,5 --policies noop,canonical,surrogate,dspy
python llm_ood_eval.py report --json artifacts_llm7h/final.json

# 한 판만 손으로 (LLM lane)
DEMO_OOD=all DEMO_OOD_STREAM3=1 DEMO_N=4 DEMO_OOD_SEED=1 \
DEMO_POLICY=dspy DEMO_ROUTER=0 DSPY_URL=http://127.0.0.1:8090 \
DEMO_SPARES=3 DEMO_REFORM=300 DEMO_REFORM_MAX=6 LLM_NL_MODE=observation \
  julia +lts --project=. tools/monitor/run_demo.jl
```

새로 만든 파일:

```
wm4spacecraft_manufacturing/
  action_registry.json      행동 어휘 단일 진실원 (id · 이름 · 비용 · 전제조건 kinds)
  action_registry.py        그 로더 (조용한 폴백 없음 — 깨지면 크게 죽는다)
  audit_action_vocab.py     6개 소비처 일치 검사
  reference_policy.py       기준 행동 a* (격자 실측에서 유도)
  llm_ood_eval.py           스위프 드라이버 + 4축 리포트
  test_llm7h.py             위 전부의 검사 (기준 정책 vs 오라클 라벨 대조 포함)
  md/RESULTS_LLM7H.md       이 문서
```

고친 파일: `src/respec/replan.jl`(`RESPEC_DRIFT_REPAIR` 신설) · `src/route_planning.jl`(그 게이트
적용) · `src/respec/llm_service/{dspy_service,steering_signature}.py`(레지스트리 배선) ·
`wm4spacecraft_manufacturing/llm_producer.py`(〃) · `tools/monitor/{policy,run_demo}.jl`.

---

## 5. 결과

설정: `tractor.mpd` · 로봇 10 · 스페어 3/pool · world_seed 1 고정 · ood_seed 1~5 ·
사건 4개/판 · `sev_frac=0.5` · `DEMO_ROUTER=0`(정책 고정) · `LLM_NL_MODE=observation` ·
producer = DSPy **seed 프로그램** + gpt-4o(temperature 0).

**20판 (5 시드 × 4 정책).** 표는 `llm_ood_eval.py report --md` 가 아티팩트에서 직접 생성한다
(`artifacts_llm7h/results_table.md`) — 손으로 옮겨 적지 않는다.

*(2026-08-07 갱신: `surrogate` 행만 재측정 — `n44_plus78.jsonl` 재적합 후. noop/canonical/dspy 는
Task 6 이 재사용한 옛 행이다 — §5-f-이후 참조. 아래는 `artifacts_llm7h/results_table.md` 를 그대로 옮긴 것이다.)*

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` (바닥선) | 5 | **0%** (0/5) [0.00, 0.43] | 0% (0/17) | — (완주 0) | 856 | 0.182 | 12.0 |
| `canonical` (규칙) | 5 | 80% (4/5) [0.38, 0.96] | 32% (6/19) | 66.3 ± 1.3 | 971 | 0.907 | 9.6 |
| `surrogate` (RF) | 5 | 80% (4/5) [0.38, 0.96] | **68% (13/19)** | **35.5 ± 4.3** | **739** | 0.937 | 9.6 |
| **`dspy` (LLM)** | 5 | **100%** (5/5) [0.57, 1.00] | **90%** (18/20) | **41.0 ± 13.9** | **538** | 0.952 | 10.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×47 | Battery 0/6, Fault 0/5, Zone 0/6 |
| `canonical` | ReformTeam×30, Replace×12, NOOP×7 | Battery 0/6, Fault 6/6, Zone 0/7 |
| `surrogate` | Replace×12, ReformTeam×10, RelocateBuild×7 | Battery 0/6, Fault 6/6, **Zone 7/7** |
| `dspy` | ReformTeam×10, SwapBattery×6, Replace×6, RelocateBuild×6, NOOP×2 | Battery 6/6, Fault 6/6, Zone 6/8 |

> **주의**: 이 매크로 개수는 정책마다 총 결정 수가 달라(`canonical` 49건, `surrogate` 29건 등) 정책 간
> 동일 분모가 아니다 — 값의 크고 작음을 행동 성향으로 읽지 말 것. 정책 간 비교가 성립하는 분모는
> 위 표의 채점된 19~20건뿐이다(§7-a).

- 짝지은 비교 `noop` vs `canonical` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `noop` vs `surrogate` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `canonical` vs `surrogate` — 0승 0패 **5무**, p=1.000 (완주·closed 기준 — §5-f-이후에서 이 통계가
  왜 여전히 5무인지, 그리고 왜 그것이 "변화 없음"을 뜻하지 않는지 설명한다)
- 짝지은 비교 `canonical` vs `dspy` — 0승 **1패** 4무, p=1.000 (그 1패가 시드 2)
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, p=1.000 (그 1패도 시드 2 — 배터리 축에서 둘 다 규칙과 같다)

전 판 상세:

| seed | 정책 | 결과 | closed | steps | J/closed | 매크로(reform 제외) |
|---|---|---|---|---|---|---|
| 1 | noop / canonical / **dspy** | stall / complete / **complete** | 202 / 291 / 291 | 4910 / 2734 / **1479** | 848 / 832 / **467** | `NOOP×4` / `Replace,Replace,NOOP,NOOP` / **`SwapBattery,Replace,NOOP,RelocateBuild`** |
| 2 | noop / canonical / **dspy** | stall / **stall** / **complete** | 174 / 208 / 291 | 4885 / 4875 / **1307** | 947 / 1524 / **460** | `NOOP×3` / `Replace,Replace,Replace` / **`Replace,SwapBattery,SwapBattery,RelocateBuild`** |
| 3 | noop / canonical / dspy | stall / complete / complete | 224 / 291 / 291 | 4883 / 2624 / 2624 | 780 / 881 / 797 | `NOOP×3` / `Replace,NOOP,Replace,Replace` / `SwapBattery,NOOP,Replace,Replace` |
| 4 | noop / canonical / **dspy** | stall / complete / complete | 266 / 291 / 291 | 4984 / 2633 / **1309** | 721 / 809 / **438** | `NOOP×4` / `Replace,Replace,NOOP,NOOP` / **`SwapBattery,SwapBattery,RelocateBuild,RelocateBuild`** |
| 5 | noop / canonical / **dspy** | stall / complete / complete | 173 / 291 / 291 | 4644 / 2623 / **1474** | 986 / 811 / **528** | `NOOP×3` / `NOOP,Replace,Replace,NOOP` / **`RelocateBuild,Replace,Replace,RelocateBuild`** |

*(위 표는 재적합 전(§5-f) 세계다. 재적합 후(2026-08-07, §5-f-이후) `surrogate` 는 더 이상 `canonical` 과
같지 않다 — closed 는 시드별로 완전히 같지만(291/208/291/291/291, `canonical` 과 동일) zone 사건마다
`RelocateBuild` 를 골라 steps 가 시드 1·3·4·5 에서 거의 절반으로 줄었다(2734→1638, 2624→1324, 2633→1250,
2623→1474). 시드 2(배터리 축이 미완주를 가르는 판)는 두 정책이 여전히 바이트 단위로 같다 —
`surrogate` 가 `SwapBattery` 를 여전히 고르지 않기 때문이다.)*

### 5-a. 완주율 — 적응이 실제로 이득인가

**이것이 이 저장소에서 처음 나온 직접 증거다.** STATUS §5 가 "'적응적'이라는 주장의 근거가
사실상 한두 개의 대본이고, 무작위 스트림 위에서 정책을 비교한 적은 한 번도 없다"고 적어둔 그 공백이다.

no-adapt 바닥선은 **5판 전부 미완주**(평균 진행도 0.66)다. 개입하지 않으면 트랙터는 완성되지 않는다.
바닥선이 실제로 바닥선처럼 동작하는 것을 확인한 것도 이번이 처음이다 — §1-a 의 버그 때문에 그동안
noop lane 은 사실 canonical 이었다.

> **주의(검정력).** 시드 5개에서 짝지은 부호검정의 **최소 p 는 0.062** 다(2/2⁵). 즉 5-0 완승이어도
> p<0.05 는 **원리적으로 불가능**하다. 유의성을 주장하지 않는다 — 방향과 효과 크기만 보고한다.
> 함정 18("표본이 작으면 판정하지 않는다")을 그대로 따른다.

### 5-b. 옳은 결정 — 어휘가 정답을 담자 규칙과 갈렸다

종류별로 보면 무엇이 갈렸는지가 분명하다.

| 종류 | canonical | dspy(LLM) | 무엇이 갈렸나 |
|---|---|---|---|
| fault | 6/6 | 6/6 | 규칙과 LLM 이 동일. 이 축은 애초에 규칙이 맞힌다 |
| battery | **0/6** | **6/6** | 규칙은 임계값만 보고 언제나 `Replace`(창고 본체 소모). LLM 은 `SwapBattery`(cost 0.2) |
| zone | 0/7 | 6/8 | 규칙은 언제나 `NOOP`(투영 후 도메인 없음). LLM 은 6번 `RelocateBuild` |

battery 축의 0/6 vs 6/6 은 **Ch-A 를 닫은 직접적 결과**다. 이 작업 전에는 `SwapBattery` 가
`llm_producer.MACRO_NAME` 에도 `dspy_service.MACROS` 에도 없었으므로 **LLM 이 6/6 을 맞히는 것이
원리적으로 불가능**했다. 어휘 한 줄이 적중률 0%p → 100%p 를 만든 셈이다.

가장 깨끗한 대조는 **시드 3** 이다. 두 정책이 첫 사건에서만 갈리고(`SwapBattery` vs `Replace`)
나머지 셋은 동일했는데, 결과는 **steps 2624 로 완전히 같고** 에너지만 797 vs 881 J/closed,
스페어는 하나 더 남았다. 격자(`battgrid`)가 예측한 그대로다 — 두 팔은 시간이 같고 **자원만 다르다**.

그 자원 차이가 값을 하는 곳이 **시드 2** 다. canonical 은 깊은 방전 2건에 창고 본체를 쓰고
(`Replace,Replace,Replace`) **closed 208 에서 정지**했다. LLM 은 `Replace,SwapBattery,SwapBattery,
RelocateBuild` 로 본체를 아껴 **1307 스텝에 완주**했다. 15판 중 두 정책의 완주 여부가 갈린 유일한 판이다.

### 5-c. 빌드 시간 — RelocateBuild 가 절반을 만든다

완주판의 시뮬 시간은 LLM 41.0 s vs 규칙 66.3 s 다. 기전은 판별 가능하다: 구역을 치운 판
(시드 1·2·4·5, `RelocateBuild` 포함)은 **1307~1479 스텝**, 구역에 `NOOP` 한 판(시드 3)은 **2624 스텝**
으로 규칙과 정확히 같다. 즉 시간 이득은 배터리 팔이 아니라 **공간 팔에서 나온다**.

### 5-d. 에너지 — 총량이 아니라 닫힌 노드당으로 읽어야 한다

`J/closed` 는 LLM 538 · 규칙 971 · 바닥선 856 이다. **바닥선의 총 에너지가 규칙보다 작다**는 점이
이 축의 함정을 그대로 보여준다 — 미완주 판은 일을 덜 해서 총량이 작다. 그래서 분모를 닫힌 노드로 둔다.

`min_soc` 는 바닥선 0.182 vs 개입 0.907~0.952 로 갈리지만, 이 값은 **개입에 오염돼 있다**:
`SwapBattery`·`Replace` 는 SoC 를 1.0 으로 되돌리므로 런 종료 시점의 SoC 는 "얼마나 아꼈나"가
아니라 "얼마나 자주 갈았나"를 함께 반영한다. 이 데모의 배터리 파라미터
(`demo_battery_params(shrink=25)`)는 자연 방전이 완만해서 개입 없는 축의 분산도 작다.
**에너지 축의 해석은 `J/closed` 로 하고 `min_soc` 는 보조 지표로 둔다.**

### 5-e. LLM 이 틀린 2건 — 무엇을 잘못 읽었나

zone 8건 중 2건(시드 1 @150, 시드 3 @133)에서 `NOOP` 을 골랐다. 두 사건 모두
`nav_blocked=3`, `root_covered=0`, **`work frozen by those = 32`** 로 기준 규칙상 개입이 답이다.
프롬프트에는 그 32 라는 숫자가 `work frozen by those` 로 **이미 들어가 있다**.

두 오답의 `nav_goals` 분모가 89·95 로 컸다는 공통점이 있어 "3/95 는 작다"는 비율 읽기가
의심되지만, 시드 5 @60 은 분모가 **133 인데도** `RelocateBuild` 를 골랐다. **n=8 로는 기전을
특정할 수 없다**. 확실한 것은 두 가지뿐이다: (a) 같은 판정이 필요한 사건에서 답이 갈렸다,
(b) temperature=0 이므로 표집 잡음이 아니라 **상태 숫자에 대한 진짜 민감도**다.
이것이 계획서 Ch-E(자기일관성 K=5 + 기권)가 겨냥한 바로 그 자리다.

### 5-f. 배포 서로게이트가 규칙과 **완전히 같은 판**을 냈다

가장 날카로운 결과는 이것이다. 배포 RandomForest lane 은 5판 전부에서 규칙과 **바이트 단위로 같은
결과**를 냈다 — 같은 완주 여부, 같은 closed, 같은 steps, 같은 에너지, 같은 매크로 분포.

폴백이 아니다. 49개 결정 전부 `enacted = "surrogate"` 로 기록됐고, 서로게이트가 **자기 점수로**
골랐는데 매번 규칙과 같은 팔이 나왔다. 기전은 어휘다:

| 사건 | 유효 팔 | 서로게이트가 점수 낼 수 있는 팔 | 결과 |
|---|---|---|---|
| battery | NOOP, Replace, Deprioritize, **SwapBattery** | NOOP, Replace, Deprioritize | `SwapBattery` 는 학습 근거 0 → 후보에서 탈락 → `Replace` |
| zone | NOOP, **RelocateBuild** | NOOP | 점수 낼 팔이 **하나뿐** → 언제나 `NOOP` |
| fault | NOOP, Replace, Deprioritize | 전부 | `Replace` (규칙과 일치) |

배포 서로게이트는 `graded_hs_n44` (매크로 지원 `[0,1,2,3,4]`)로 적합돼 7·8 행이 **한 줄도 없다**.
그래서 이 스트림에서 두 정책을 가르는 팔이 전부 그 지원 밖에 있고, 학습된 싼 정책은
**규칙보다 나을 여지 자체가 없다.** 이것이 `policy.jl` 이 "행동 표현력" 이라 부르며 라우터의
에스컬레이션 조건으로 넣어 둔 그 조건이고, 이번에 처음으로 **스트림 위에서 측정**됐다.

읽는 법에 주의: 이것은 "서로게이트가 나쁘다"가 아니라 **"이 스트림에서 서로게이트는 규칙과 구별
불가능하다"** 이다. 학습된 정책이 값을 하려면 (a) 7·8 팔이 들어간 라벨로 재적합하거나
(b) 라우터가 그 사건을 LLM 으로 올려야 한다. 후자는 이미 구현돼 있고(`DEMO_ROUTER=auto`),
이 실험은 정책 비교를 위해 일부러 껐다(§1-a).

### 5-f-이후. (a) 를 실제로 했다 — 재적합 후 재측정 (2026-08-07)

위 (a)를 했다. `n44_plus78.jsonl`(68 instance, 매크로 지원 `[0,1,2,3,4,7,8]` — Task 3 의
`battgrid_0805_s1.jsonl`(8=SwapBattery) 과 Task 5 의 `fzgrid_0806/merged.jsonl`(7=RelocateBuild) 을
`graded_hs_n44.jsonl` 에 합친 것)로 배포 서로게이트를 재적합하고, **같은 5시드·같은 스트림**에서
`surrogate` lane 만 다시 돌렸다(`noop`/`canonical`/`dspy` 는 재사용 — §4, 재사용 가능함을 먼저 확인했다).

결과: **더 이상 바이트 단위로 같지 않다.**

| 축 | 재적합 전 | 재적합 후 |
|---|---|---|
| 옳은 결정 | 32% (6/19) | **68% (13/19)** |
| zone 적중 | 0/7 | **7/7** |
| battery 적중 | 0/6 | 0/6 (불변) |
| 고른 매크로 | `canonical` 과 완전 동일 | `RelocateBuild×7` 이 `NOOP×7` 을 대체, `ReformTeam` 30→10 |
| 빌드 시간(완주판) | 66.3 s (`canonical` 과 동일) | **35.5 s** |
| J/closed | 971 (`canonical` 과 동일) | **739** |

> **주의**: `ReformTeam 30→10` 을 정책이 "reform 을 덜 하게 됐다"는 행동 변화로 읽지 말 것 — 재적합
> 후 세계는 zone 을 더 빨리 치워 완주가 더 빨라지므로 reform 경보 자체가 더 적게 뜬다(총 결정 수
> 49→29). 매크로 카운트는 정책 간 동일 분모가 아니다(§7-a).

기전은 서비스가 실제로 계산하는 것과 같은 코드 경로(`surrogate_rank`, `e1_analyze.featurize`)를
그대로 재생해 확인했다 — zone 사건(valid=`[NOOP, RelocateBuild]`)에서 두 팔 모두 점수가 나고
(`unsupported=[]`, `UNSUPPORTED` 아님), `RelocateBuild` 가 **매번 더 높은 점수**를 받아 선택된다
(예: 시드 1 @149, `RelocateBuild` 228.79 vs `NOOP` 176.65 — 점수는 학습 시와 동일한
`closed − λ·cost` 스케일). 즉 지원 집합에 넣는 것만으로 **모델이 스스로 참조 정책과 같은 결론에
도달했다** — zone 축에서는 "학습 근거 없음"이 진짜 원인이었다는 §5-f 의 진단이 맞았다.

이 결론이 기대는 학습 근거의 크기를 정확히 적어 둔다: `fzgrid_0806/merged.jsonl` 12행(6사건 × 2팔)은
**전부 `complete=False`** 다. `RelocateBuild` 는 6사건 중 5곳에서 `NOOP` 보다 closed **56~105** 만큼
더 벌었고(나머지 1곳은 동점, margin 0), **완주 여부를 뒤집은 사건은 0건**이다. 즉 이 라벨이 뒷받침하는
것은 **닫힌 노드 마진**이지 실현가능성(feasibility)의 개선이 아니다 — 위에서 서술한 행동 변화(모델이
`RelocateBuild` 를 실제로 채택했다는 것)는 그대로 사실이지만, 그 근거의 강도를 이 이상으로 읽으면 안 된다.

battery 축은 다르다. `SwapBattery`(8)도 이제 점수가 나지만(`unsupported=[]`), **매번 `Replace` 보다
낮게 랭크된다**(예: 시드 1 @58, `Replace` 248.15 vs `SwapBattery` 223.56) — battery 적중은 여전히
0/6, `canonical` 과 바이트 단위로 같다. 이건 어휘 문제가 아니라 **모델이 `SwapBattery` 를 진짜로
선호하지 않는 것**이다(§5-b 가 실측한 대로 두 팔은 closed 가 같고 cost 만 다른데, RF 가 그 불변성을
이 특징 영역에서 학습하지 못했다는 뜻이다).

**짝지은 비교(완주·closed 기준) `canonical` vs `surrogate` 는 재측정 후에도 0승 0패 5무다.** 이
통계는 `(완주, closed)` 튜플만 비교하고 steps/energy/매크로를 보지 않으며(`llm_ood_eval.py::paired`),
이 스트림의 zone 축은 애초에 완주를 가르지 않는다(§5-g: 시드 3 의 LLM 도 zone 에서 `NOOP` 을 골랐지만
완주했다). 그래서 **§5-f 의 문자 그대로의 주장("완주·closed·steps·에너지·매크로 분포가 전부 같다")은
반증됐지만**, 이 하니스가 리포트하는 헤드라인 부호검정은 이 스트림에서 그 반증을 승/패로 드러내지
못한다. 완주율/closed 만 보고 "재적합이 무의미했다"고 읽으면 이 문서 §5-b~§5-d 가 이미 경고한 것과
같은 함정(집계만 보고 사건별 결정을 안 읽음)에 빠진다.

이것은 계획서 Step 8 의 세 가지 가능한 결론 중 **(2)** 에 해당한다 — 지원 집합은 열렸고 두 팔 다
점수를 받지만(어느 쪽도 `UNSUPPORTED` 로 탈락하지 않는다), **축마다 모델의 선호가 갈린다**: zone 은
새 어휘를 실제로 채택했고, battery 는 점수는 내면서도 여전히 채택하지 않는다.

### 5-g. 기준 규칙 자체의 한계 — zone 축은 이 스트림에서 완전히 전이되지 않았다

정직하게 적어야 할 반증이 하나 있다. 시드 3 의 LLM 은 zone 에 `NOOP` 을 골라 기준 규칙을 어겼지만
**그 판은 완주했다**(2624 스텝). 기준 규칙의 zone 항은 `zcausal_reform` **2사건**에서 유도한 것이고,
그 격자에서는 NOOP 이 254 에서 정지했다. 이 스트림은 스페어 3 · 복구 사다리 ON 으로 설정이 달라
**같은 판정이 성립하지 않는다.**

따라서 **zone 축의 "옳은 결정"은 정답률이 아니라 격자 규칙과의 일치율로 읽어야 한다.**
battery(n=18)·fault(n=42) 축은 근거가 훨씬 두껍고, 실제로 그 두 축에서는 규칙 위반이
결과 악화와 함께 나타났다(시드 2).

---

## 6. 실제로 돌린 검사와 그 결과

주장이 아니라 **돌린 명령과 출력**만 적는다.

| 검사 | 명령 | 결과 |
|---|---|---|
| 행동 어휘 일치 | `python audit_action_vocab.py` | **6/6 consistent** (exit 0) |
| 기준 정책 · 레지스트리 | `python test_llm7h.py` | **16/16 passed** (exit 0) — 그중 3개가 오라클 라벨 62 instance 대조 |
| 배포 surrogate 지원 계약 | `python test_surrogate_support.py` | **PASS (7/7 checks)** — support=`[0,1,2,3,4,7,8]`, n=68 (2026-08-07 추가) |
| Julia 패키지 스위트 | `julia +lts --project=. -e 'using Pkg; Pkg.test()'` | **11 pass / 1 error** — 아래 |
| 스트림 e2e | `llm_ood_eval.py run` 20판 (+ 2026-08-07 surrogate 5판 재측정) | 20/20 + 5/5 프로세스 exit 0 |
| 회귀(파이썬 파이프라인) | `python verify.py oracle/out/graded_hs_n44.jsonl` | **8/8** — 아래 |
| 선언적 ForbidZone 주입기 (Task 4) | `julia +lts --project=. wm4spacecraft_manufacturing/oracle/test_forbidzone_injector.jl` | **9/9 PASS** (2026-08-07 재확인) — `zone_inject.jl::inject_declared_zone!` 단위검사, 시뮬 없음 |

**Julia 1 error 의 정체**: `test/test_demo.jl:61` 의 MILP 블록이
`Gurobi Error 10009: No Gurobi license found` 로 죽는다. 이 환경에 Gurobi 라이선스가 없다는 뜻이고
**이번 변경과 무관**하다. 같은 `Demo` testset 안에서 그 앞의 greedy 전체 데모(=이번에 고친
`close_node!`/`route_planning.jl` 경로를 실제로 지나가는 블록)는 정상 완주한 뒤 Gurobi 블록에서
멈췄다. 나머지 11개(IDs · Potential Fields 8 · Twist 3) 전부 통과.

**`verify.py` 8/8 의 정체(2026-08-06 Task 2 갱신, 이 문서는 2026-08-07 재확인)**: V0 은 원래
`0/44 instances have all **7** macro arms rolled out` 으로 실패했다 — 덤프는 5팔인데
`e1_analyze.MACROS` 는 7개(`[0,1,2,3,4,7,8]`)라 개수가 안 맞았고, 이것이 계획서가 **Ch-D**
("오라클이 7·8 팔을 채점하지 않는다")라고 부른 구멍이다. Task 2 가 V0 판정을 **팔 개수**가 아니라
`valid_mask` 기준(그 사건에서 실제로 유효한 팔을 다 굴렸는가)으로 고쳤고, 그 뒤로는 **8/8** 이
재현된다(Step 4·Step 11 에서 재확인). 이 문서의 옛 버전과 계획서 일부가 인용한 "7/8"은 **그 수정
이전 시점의 판정**이므로, 지금 값(8/8)과 함께 인용하지 말 것 — 둘은 서로 다른 검사 기준의 결과다.

**기본 경로 불변 증명**: `RESPEC_DRIFT_REPAIR[]` 기본값이 `nothing` 일 때
`respec_drift_repair() == RESPEC_ENABLED[]` 임을 직접 확인했다(false→false, true→true).
패키지 안에서 이 Ref 를 설정하는 곳은 없고, 오직 `tools/monitor/run_demo.jl` 만 `true` 로 켠다.

**Task 4 배선도 기본 경로를 안 건드린다는 증명**: `zone_inject.jl` include 와 `DEMO_ZONE_AT` 분기를
추가한 뒤, `DEMO_ZONE_AT` 을 **주지 않고** STREAM3 seed 1 을 `canonical` 로 다시 돌려
(`results/fam_nav_check.jsonl`) §5 표의 원래 canonical seed-1 행과 대조했다 — closed 291·steps
2734·결정 시퀀스(각 `at`)까지 바이트 단위로 같다(달라지는 건 wall-clock 뿐). `DEMO_ZONE_AT` 미설정 시
`declared_zone_spec()` 이 `nothing` 을 돌려주는 코드 경로(`zone_inject.jl:82-98`)가 실제로 아무것도
바꾸지 않음을 재확인한 것이다.

---

## 7. 하지 못한 것과 그 이유

| 안 한 것 | 이유 |
|---|---|
| **반사실 오라클 기반 `optimal_action_rate`** | 스트림에서는 결정 이후 세계가 갈라져 사건당 트리가 지수로 늘어난다(사건 4 × 팔 4 = 256 런/시드). §3-b 의 기준 정책으로 대체했고 그 사실을 표에 명시했다 |
| **Ch-E: 자기일관성 K=5 · 기권 · risk–coverage 곡선** | 계획서의 헤드라인이지만, 먼저 Ch-A 와 **계획에 없던 버그 2개**를 닫아야 스트림이 아예 돌았다. §5-e 가 이 작업이 왜 다음 순서인지에 대한 실측 근거다 |
| **Ch-B: `nl` 실제 캡처 · 캡처/합성 비율** | 이 스트림의 `nl` 은 **주입기가 만든 실제 관찰문**이라 합성본 문제는 없다. 다만 오프라인 격자 덤프의 `nl` 재생성(P1 라벨 잡)은 하지 않았다 |
| **Ch-C: 7번째 서술자 `repair_disruption`** | §5-e 가 보여주듯 필요한 정보(frozen 32)는 **이미 프롬프트에 있다**. 축을 더 넣기 전에 "있는 축을 왜 못 읽는가"를 먼저 봐야 한다 |
| ~~**`verify.py` 8/8**~~ **해결됨(Task 2, 2026-08-06)** | 이 표가 처음 쓰였을 때는 실측 **7/8**(canonical set)이었다 — V0 이 "0/44 instances have all **7** macro arms" 로 실패했다(덤프는 5팔인데 `e1_analyze.MACROS` 는 7개, 계획서의 **Ch-D**). Task 2 가 V0 판정을 팔 개수 대신 `valid_mask` 기준으로 고쳐 **8/8** 이 재현된다 — 지금 값은 §6 을 볼 것. 이 행은 "한때 여기 있었다"는 이력으로만 남긴다 |
| **P1 대량 라벨 잡(~5h)** | 운영규칙 1 과 정면으로 충돌한다 — 스위프의 Julia 실행과 CPU 를 다투면 HiGHS 가 **다른 스케줄**을 내 정책 비교가 무효가 된다(함정 30). 사용자가 요청한 산출물이 스트림 평가였으므로 그쪽에 CPU 를 전부 줬다 |
| **`ForbidZone` 팔의 실제 발화** | (2026-08-07 갱신) Task 4 의 단일 좌표 사전주입기(`DEMO_ZONE_AT`)로는 **처음으로 메뉴에 올랐고 `canonical` 이 실제로 선택했다** — 이 저장소 최초 기록. 그러나 **§5·본 태스크의 20판이 쓰는 STREAM3 무작위 주입기(`inject_blocking_zone!`)는 손대지 않았고**, 재측정(2026-08-07)에서도 그 사건들은 여전히 `n_restage_feasible=0` 이라 `valid=[NOOP, RelocateBuild]` — **스트림 안에서는 여전히 죽은 팔이다**. 서로게이트 재적합은 점수가 나는 팔을 넓혔을 뿐 기하학적 실현가능성을 바꾸지 않으므로, 이 결과는 예상된 것이다. **메뉴에 오른 것이 옳은 선택이었다는 뜻은 아니다** — 같은 사건에서 `ForbidZone` 은 closed **68** 에서 정지했고 `NOOP` 은 closed **205** 에서 정지했다(`results/fz_declared_s1.jsonl`), 둘 다 미완주(n=1). 이 항목의 성과는 팔이 **발화 가능해졌다**는 것이지, 그 팔이 `NOOP` 보다 나았다는 것이 아니다 |

### 7-a. 알려진 한계 (코드 수정 없음 — 기록만)

**train/serve 특징 불일치 — `zone_root_cover`.** `oracle/out/fzgrid_0806/merged.jsonl` 12행(macro-7
학습 근거) 전부가 `zone_root_cover` 열을 갖고 실측값(0.0 또는 1.0)을 담는 반면, 기존 zone 계열 20행
(`graded_hs_n44.jsonl`/`n44_plus8.jsonl` 의 `kind∈{zone,zoneblk,zonecore}`)은 **단 한 행도 이 열이
없다**. 그런데 배포 서비스 `src/respec/llm_service/dspy_service.py::surrogate_rank`(:296-306)가
채점용으로 만드는 요청 딕셔너리는 `zone_root_cover` 를 **한 번도 설정하지 않는다** — `e1_analyze.py:190`
가 없는 열을 `-1.0` 으로 채우므로, 실서비스가 보내는 모든 행은 이 특징에서 항상 `-1` 을 받는다.
즉 **학습 시엔 실측값(0.0/1.0), 서빙 시엔 언제나 센티넬(-1)** 이라는 분포 불일치가 있다.

이번 패스에서 재확인(probe, 코드 변경 없음): `n44_plus78.jsonl` 로 실제 배포와 동일하게 적합한
RandomForest 에, `fzgrid_0806/merged.jsonl` 의 실제 zoneblk 행 3개를 기반으로 `zone_root_cover`
를 `{-1(서빙 값), 0.0, 1.0}` 로 바꿔 가며 `RelocateBuild`(7) vs `NOOP`(0) 점수를 비교했다. 세 사건
전부, 세 값 전부에서 **`RelocateBuild` 가 이겼다**(margin 31.2~62.4, 방향 반전 없음) — §5-f-이후가
보고한 결론은 이 열의 값에 좌우되지 않는다. 다만 **이것을 지키는 코드나 검사는 없다** — 앞으로 두
분포(학습/서빙)를 섞어 다시 만들 덤프가 이 열을 "실제 기하 신호"가 아니라 우연히 "출처 태그"
(fzgrid 유래=값 있음/1.0 근처, 그 외=-1)로 학습해 버릴 위험은 그대로 남아 있다.

**매크로 개수는 정책 간 동일 분모가 아니다.** §5-f-이후 표의 "고른 매크로" 행(`ReformTeam` 30→10)을
정책의 행동 변화로 읽으면 안 된다 — `canonical` 은 49개 결정, 재적합된 `surrogate` 는 29개 결정을
내렸을 뿐이다(더 빠르게 완주하는 세계라 reform 경보 자체가 더 적게 뜬다). 정책 간 비교가 성립하는
유일한 분모는 §5 본문의 채점된 19~20건이다 — 매크로 카운트 표가 나올 때마다 이 사실을 함께 읽을 것.

### 다음 한 수

1. **Ch-E** — §5-e 의 2건이 표적이다. K=5 표결의 분산을 신뢰도로 쓰고 τ 아래면 기권 → 오라클/규칙으로.
2. **zone 기준의 표본 확대** — n=2 는 §5-f 의 반증을 감당하지 못한다. 지금 하니스로 zone 사건만
   팔 교차(`DEMO_FORCE_MACRO`)해 돌리면 스트림 설정 그대로의 라벨을 얻을 수 있다.
3. ~~**Ch-D** — 오라클 생성기의 `MACROS` 에 7 을 넣어 `verify.py` V0 을 되살린다.~~ **완료(다른 경로,
   Task 2, 2026-08-06)** — `MACROS` 에 7 을 넣는 방법은 쓰지 않았다(그러면 `expected_arms` 가 바뀌어
   기존 덤프의 완전성 판정이 소급으로 흔들린다 — 계획서 "이 계획이 하지 않는 것" 표). 대신 V0 판정
   자체를 `valid_mask` 기준으로 고쳐 8/8 을 되살렸다(§6).
