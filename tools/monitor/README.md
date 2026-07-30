# AI&T Monitor — ConstructionBots 자율 multi-robot assembly 관제 대시보드

## Live control (v4)

Run the control dashboard on port 8080; MeshCat keeps its default live port 8700:

```powershell
julia +lts --project=. tools/monitor/server.jl
# open http://127.0.0.1:8080/
```

`Start live session` launches the selected assembly/OOD case even when a replay
already exists. While it is active, `Inject Forbid Zone` sends `(x, y, radius)`
to `POST /inject/zone`. The command is queued and consumed on the simulation
thread, then recorded as `ZoneTruth`, translated to `ForbidZone`, verified, and
restaged when it overlaps an assembly staging circle. `GET /status` reports the
active session. Deep battery-discharge frames tint the failed robot body red;
the dispatched replacement remains separately identified by its cyan ring.

Model settings now come from `get_project_params(filename)`, shared by both
`run_demo.jl` and `render_demo.jl`, so scale and robot count are not silently
reset to tractor defaults for Passenger Plane or other LDraw files.

Validated on 2026-07-22:

- Tractor live operator zone: `ForbidZone` admitted, assembly 8/8 complete.
- Tractor battery: `ReplaceAgent` admitted, red body tint animation generated,
  assembly 8/8 complete.
- TIE Fighter Mini nominal: assembly 4/4 complete at step 1516.
- Passenger Plane nominal: assembly 28/28 complete at step 9035.
- Passenger Plane zone: `ForbidZone AssemblyID(4)` admitted and restaged,
  assembly 28/28 complete at step 8858.

DEXTER-LLM식 관제 UI를 ConstructionBots(spacecraft AI&T)로 옮긴 것.
한 화면에서 **어떤 조립물(spacecraft)** 을 **어떤 OOD 상황**에서 조립·복구하는지 replay 로 확인한다.

## 실행 (권장: 컨트롤 서버)

```bash
# ConstructionBots.jl 폴더에서 (python http.server 는 끄고)
julia +lts --project=. tools/monitor/server.jl
#  → 브라우저: http://127.0.0.1:8080/
```

- **Assembly 드롭다운**: LDraw_files 의 모델 선택 (Tractor / Saturn V / X-wing / Shuttle / TIE / Star Destroyer / AT-AT …).
- **OOD 케이스 버튼 6종**:
  1. ① Battery — 로봇 배터리 방전
  2. ② Breakdown — 로봇 급작 고장
  3. ③ Forbid Zone — 통행/적치 금지구역 출현
  4. ④ Break+Battery
  5. ⑤ Break+Zone
  6. ⑥ Battery+Zone
  - (+ Nominal = OOD 없음)
- 버튼 클릭 → 해당 `streams/<model>__<case>.jsonl` 이 있으면 즉시 replay,
  없으면 서버가 `run_demo.jl` 서브프로세스로 **온디맨드 생성**(env 빌드+시뮬로 수 분) 후 자동 로드.

## 파이프라인

```
run_demo.jl (엔진)                     server.jl (컨트롤)          dashboard.html (UI)
────────────────────                   ──────────────────         ──────────────────
run_lego_demo(return_env_before_sim)   GET  /  , /streams/*       모델·OOD 선택
  → env                                GET  /models               → streams/<m>__<c>.jsonl 로드
수동 루프:                              POST /run {model,case}     replay 스크러버·자동재생
  ood_inject_step!  (OOD 발화)            → julia run_demo.jl       패널: Fleet(SoC)/Assembly tree/
  canonical_respec  (=분석, 캡처)                                    OOD feed/Re-spec/Gantt
  직접 복구:
    fault/battery(SoC≤0.2) → hot_swap_robot!  (정체성보존 교체, 완주 경로)
    battery(경미)          → rebalance_for_battery!
    zone                   → restage_assembly!
  monitor_emit! → JSONL 프레임
```

**검증(tractor)**: `fault` 케이스 = OOD @closed54 → canonical **ReplaceAgent** → hot-swap →
**PROJECT COMPLETE (8/8 assembly)**. 즉 OOD 주입 → 분석 → adaptive rescheduling → 자율 완성.

## 엔진 단독 실행 (서버 없이 스트림만 생성)

```bash
DEMO_MODEL=tractor.mpd DEMO_OOD=fault DEMO_N=3 julia +lts --project=. tools/monitor/run_demo.jl
#  → tools/monitor/streams/tractor__fault.jsonl
# DEMO_OOD: none|battery|fault|zone|fault_battery|fault_zone|battery_zone
# DEMO_ROBOTS: 로봇 수 (기본 10)
# DEMO_N: 주입할 OOD 이벤트 개수 (0=케이스 기본=종류당 1개). >0이면 fault/battery 이벤트를 N개로
#         순환 배치해 빌드 전반에 퍼뜨림(스트레스 테스트). zone은 transform-safe 때문에 항상 1회 초반 주입.
#         예) DEMO_OOD=fault DEMO_N=5 → 고장 5건 / DEMO_OOD=fault_battery DEMO_N=4 → fault,battery,fault,battery
```

**대시보드에서**: 케이스바의 **`OOD events`** 숫자 입력(0~20)에 값을 넣고 `Start live session` 을 누르면
그 개수만큼 OOD가 주입된다(0=케이스 기본). 서버가 `POST /run {..., n}` 으로 받아 `DEMO_N` 으로 넘긴다.
스트림/애니 파일명에 `_nN` 이 붙어 개수별로 따로 캐시되므로, 옛 replay가 새 카운트로 오인되지 않는다.
(카운터는 총합 = robot 이벤트 N + zone 1. 그래서 Battery+Zone 에 4 를 넣으면 카운터는 5.)

**restage 이동거리 튜닝**: no-go zone 발생 시 적치(staging) 재배치 이동거리는 **zone 크기에 비례**한다
(작은 zone→작은 이동). 노브:
- `RESTAGE_ZONE_MARGIN_FRAC` (기본 0.5) — zone 여유 = zone반지름×frac. 클수록 이동↑, 작을수록 타이트.
- `DEMO_ZONE_SCALE` (기본 0.20) — 주입되는 zone 자체 크기(적치반경 대비).

## 알려진 한계 / TODO
- **Factory View(MeshCat)** 는 현재 `visualization.html`(tractor 애니) 고정. 모델별 애니는 별도 생성 필요
  (fault/replace 는 scene-tree 수술이라 save_animation=true 시 애니 업데이터가 크래시 → OOD 런은 애니 off).
- **respec 분석 주체**는 지금 `canonical_respec`(baselines.jl B1 규칙맵) = heuristic "LLM". 실제 LLM 서비스
  (llm_bridge → Python /propose)로 교체 가능(인터페이스 동일).
- 큰 모델(Saturn V 1845 parts)은 env 빌드+시뮬이 오래 걸림 — 데모는 소형 모델(tractor/mini kits) 권장.
- 인간이 존을 **라이브** 주입하는 ⛔ 버튼은 `POST /inject/zone` 명령 큐와 시뮬레이션-thread control hook으로 구현됨.

---

## 라우터: "처음 보는 사건은 LLM, 익숙한 사건은 surrogate" (2026-07-28 추가)

여기까지의 데모는 실행 정책을 `DEMO_POLICY` 로 **런 전체에 고정**했다. 화면의 정책 버튼은 사람이
골라 보는 비교 도구였지 시스템의 결정이 아니었다. 이제 **사건마다 라우터가 스스로 고른다.**

```
낯섦도 p < eps  →  DSPy(LLM)   : 자연어 관찰을 읽고 대응        (처음 보는 사건)
낯섦도 p ≥ eps  →  surrogate   : 학습된 forest 가 0.11 ms 에 대응 (익숙한 사건)
```

판별기는 원래 `src/safety/novelty.jl` 에 다 있었는데 **아무도 호출하지 않았다**. `policy.jl` 의
`route()` 가 그 배선이다. 판정 근거(p, score, eps, 각 producer 가 본 입력)를 전부 monitor 레코드에
실어 보내므로, 대시보드 결정 패널 맨 위의 **ROUTER** 줄에서 "왜 그쪽으로 보냈는지"를 검증할 수 있다.

### 반드시 알아야 할 함정 — 기본 교정으로는 LLM 이 한 번도 안 불린다

`novelty_calibration.json` 은 **세 종류 전부**(battery/fault/zoneblk)로 맞춰져 있다. 그래서 데모의
어떤 사건도 낯설지 않고, 라우터는 항상 "익숙함 → surrogate" 만 낸다. 배선은 됐는데 화면에서는 아무
일도 안 일어난다(`tools/test_router.jl` 의 T7 이 이 상태를 잡아낸다).

라우팅을 보이려면 **교정이 그 종류를 몰라야 한다**:

```bash
cd ../wm4spacecraft_manufacturing
python export_novelty_calibration.py oracle/out/openworld_merged.jsonl \
       --exclude=zoneblk --out=novelty_calibration_no_zoneblk.json
```

그 다음 데모를 그 교정으로 띄운다:

```bash
cd ConstructionBots.jl
export NOVELTY_CALIB=../wm4spacecraft_manufacturing/novelty_calibration_no_zoneblk.json
julia +lts --project=. tools/test_router.jl        # 8/8, zone→dspy / battery,fault→surrogate 확인
julia +lts --project=. tools/monitor/run_demo.jl   # zone 사건에서만 [router] ... → dspy 가 찍힌다
```

### ENV

| 변수 | 기본 | 뜻 |
|---|---|---|
| `DEMO_ROUTER` | `auto` | `auto`=교정이 있으면 라우터 켬 / `1`=강제 / `0`=끔(예전처럼 `DEMO_POLICY` 고정) |
| `ROUTER_EPS` | 교정의 `alpha`(0.05) | 낯섦 p-value 임계. 키우면 더 많이 LLM 으로 간다 |
| `NOVELTY_CALIB` | `../wm4spacecraft_manufacturing/novelty_calibration.json` | 교정 파일 경로 |

**비파괴**: 교정 파일이 없거나 `DEMO_ROUTER=0` 이면 예전 동작 그대로(fail-open). 라우터 기록이 없는
옛 스트림도 대시보드가 그대로 연다("이 스트림에는 라우터 기록이 없습니다"로 표시).

## LLM 입력이 자연어 문장으로 바뀜 (2026-07-28)

이전에는 `ood_features` 가 만든 `kind=battery, soc=0.55, …` 를 LLM 에게 줬다. 이건 순환 논리다 —
그 필드가 존재한다는 것 자체가 "이미 아는 3종류 중 하나로 파싱됐다"는 뜻이고, 그게 검증하려는
능력이다. 진짜 새 사건에는 그 열들이 없다.

이제 `policy.jl` 이 주입 시점의 자연어 관찰(`nl`)과 종류-무관 물리 서술자 6개를 서비스로 보내고,
`dspy_service.py` 의 `_llm_input()` 이 LLM 에게 **문장**을 준다(`nl` 이 없으면 예전 렌더링으로 폴백).
대시보드 결정 패널은 두 입력을 나란히 보여준다:

```
LLM        자연어      OBSERVATION: Robot R7's battery is critically flat at about 12% …
                      MEASURED STATE: harm=0.88  work_at_risk=0.02  …
SURROGATE             OOD kind=battery, SoC=0.12, severity=0.12, spares_left=8, …
```

LLM 입력 배지가 `파싱된 필드`(주황)로 뜨면 그 사건은 문장을 못 받은 것 = 새 종류 주장에 쓸 수 없다.

---

## 케이스 × 실행정책 행렬 (24 녹화)

대시보드에는 두 개의 **직교하는** 정책 축이 있다. 헷갈리기 쉬우니 구분해서 적는다.

| 축 | 어디서 고르나 | 무슨 뜻인가 |
|---|---|---|
| **실행 정책** | 상단 케이스바의 `실행 정책` 드롭다운 | **어느 정책이 실제로 실행된 녹화**를 볼 것인가. 정책이 다르면 세계가 달라진다(완주 여부, makespan, 로봇 궤적) |
| **비교 정책** | 재명세 패널의 `DECISION POLICY` 버튼 | 그 사건에서 **세 정책이 각각 무엇을 골랐을지**. 한 녹화 안에 셋 다 기록돼 있다 |

두 번째 축은 한 번의 실행으로 공짜로 얻어진다(`policy.jl decide_all` 이 매 사건마다 셋 다 계산).
첫 번째 축은 정책마다 시뮬레이션을 따로 돌려야 하므로 **케이스 8 × 정책 3 = 24 런**이 필요하다.

```bash
# DSPy 서비스를 먼저 띄운다(주소는 DSPY_URL 로 넘긴다)
cd src/respec/llm_service && LLM_NL_MODE=raw python -m uvicorn dspy_service:app --port 8078 &

cd ConstructionBots.jl
DSPY_URL=http://127.0.0.1:8078 \
NOVELTY_CALIB=../wm4spacecraft_manufacturing/novelty_calibration_no_zoneblk.json \
bash tools/monitor/regen_case_policy_matrix.sh            # 24 런, 약 2~2.5시간

bash tools/monitor/regen_case_policy_matrix.sh fault zone  # 일부만 (× 3 정책)
DEMO_POLICIES="canonical dspy" bash tools/monitor/regen_case_policy_matrix.sh   # 정책 일부만
```

산출물: `streams/tractor__<case>__<policy>.jsonl` + `anim/tractor__<case>__<policy>.html`.
드롭다운에서 `auto` 를 고르면 기존 이름(`tractor__<case>.jsonl`)을 읽는다. 아직 안 돌린 조합은
자동으로 기존 파일로 폴백하고 `stream` 표시에 그 사실을 적는다 — 24 개를 다 돌리기 전에도 쓸 수 있다.

### 이 녹화들에서 라우터는 "참고용"이다

행렬 녹화는 `DEMO_ROUTER=0` 으로 돌아간다(정책을 고정해야 정책끼리 비교가 되므로). 그래도 라우터
**판정은 계속 기록**된다(`policy.jl route` 의 advisory 경로). 그래서 ROUTER 줄에 이렇게 뜬다:

```
ROUTER  [참고: 처음 보는 사건 → LLM 이었을 것]  낯섦도 p=0.012 · 이 녹화는 canonical 고정 실행
```

라우터가 실제로 실행을 정하는 녹화를 보려면 `DEMO_ROUTER` 를 건드리지 않고(기본 auto) 개별 케이스를
돌린 뒤 드롭다운에서 `auto` 를 고르면 된다.

### 산출물 점검 도구

```bash
python tools/monitor/verify_streams.py "tractor__*__*.jsonl"   # 무결성 검사
bash   tools/monitor/audit_matrix_artifacts.sh --fix            # 이 런이 안 만든 산출물 제거
bash   tools/monitor/restore_legacy_streams.sh                  # 기존 이름 복구 (드롭다운 `auto`)
python tools/monitor/anglicize_streams.py --write               # 녹화에 남은 한글 문구 -> 영어
```

`verify_streams.py` 가 잡는 것: **깨진 JSONL 줄**(대시보드가 조용히 건너뛰므로 프레임이 소리 없이
사라진다), 화면에 뜨는 잔여 한글, 프레임 0, 라우터 판정 누락.

**렌더가 도는 중에는 위 세 개(감사 제외)를 실행하지 말 것.** `render_demo.jl` 은 고정 이름
`streams/tractor__<case>.jsonl` 에 프레임을 이어붙이므로, 같은 순간에 그 파일을 덮어쓰면 두 프레임이
한 줄에 섞여 파일이 깨진다(실제로 `fault_zone__dspy` 를 그렇게 깨뜨려 재실행했다).
스크립트에 가드가 있고, **판정은 "파일이 실제로 자라는가"를 8초간 관찰**해서 한다:

| 시도한 판정 | 왜 틀렸나 |
|---|---|
| 파일 수정시각이 최근인가 | 렌더는 프레임을 수 초 간격으로 띄엄띄엄 쓴다 → 그 사이로 통과 |
| julia 프로세스가 있는가 | **대시보드 서버(server.jl)도 julia** → 서버가 떠 있으면 영원히 막힘 |
| **크기가 변하는가(8초 관찰)** | 채택 |
