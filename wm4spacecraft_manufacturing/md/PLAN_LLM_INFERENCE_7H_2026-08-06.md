# 계획: LLM 의 OOD 대응 추론을 "완벽"하게 만들기 — 7시간 무인 파이프라인

작성 2026-08-06. 선행: `STATUS.md`(재개 지점) · `README.md` §1 용어/§8 함정 ·
`DESIGN_ASSIMILATION.md`(C1~C4) · `PLAN_ACTION_GROWTH.md`(행동공간 성장).

---

## 0. "완벽한 inference" 를 검증 가능한 문장으로

산문 그대로 두면 측정할 수 없다. 이 계획이 쓰는 정의:

> **커버한 구간에서 초과비용 = 0(= 최적행동 적중률 100%), 커버하지 않은 구간은 스스로 기권한다.**
> 헤드라인은 정확도 한 숫자가 아니라 **risk–coverage 곡선**이다
> — "coverage 60% 에서 초과비용 0노드 · 0초".

100% 커버리지에서 초과비용 0 을 주장하지 않는 이유: 현 데이터의 61/108 이 near-tie 이고, NL-only 상한이
**원리적 하한**으로 존재하기 때문이다(`DESIGN_ASSIMILATION` §3). 기권을 인정하지 않는 "완벽"은
정의상 도달 불가이고, 기권을 인정하면 도달 가능하며 라우터 설계와도 정확히 맞물린다.

### 0-a. 용어 교체 (2026-08-06 결정) — `regret` 을 헤드라인에서 내린다

이 문서와 앞으로 새로 쓰는 코드(`llm_eval.py`)는 아래 표의 **오른쪽 용어**만 쓴다.

| 옛 용어 | 새 용어 | 정의 | 단위 |
|---|---|---|---|
| `regret` (정규화) | **정규화 준최적성** `subopt_norm` | `(V* − V^π) / (V* − V_worst)` | 0~1, **진단용** |
| — | **초과비용** `excess_cost` | `V* − V^π` 를 **사전식 층별로** 분해 | 아래 3줄 |
| — | ┣ `d_feasibility` | 완주 가능한 팔이 있었는데 못 고른 사건 | 건 · % |
| — | ┣ `d_closed` | 완주끼리 비교 시 잃은 노드 | **노드** |
| — | ┗ `d_makespan` | 잃은 시간 | **초** |
| (없었음) | **최적행동 적중률** `optimal_action_rate` | `P(a = a*)`, 동점 제외 | % |
| catastrophic-choice | **치명적 선택률** `infeasible_pick_rate` | 완주 가능했는데 미완주 팔을 고름 | % |
| (없었음) | **선택적 위험** `selective_risk@coverage` · `AURC` | 기권 허용 시 커버 구간의 손실 | — |

**왜 바꾸는가** (세 가지 전부 실질적 결함이다):

1. **단위가 없다.** `regret 0.100` 은 노드도 초도 아니다. 분모 `span` 이 사건마다 다르므로
   같은 0.100 이 사건마다 다른 물리량을 뜻한다.
2. **λ 에 오염돼 있다.** 정규화 때문에 λ 가 크면 저절로 작아 보인다(README 함정 21 이 이미
   "λ 를 가로질러 비교하지 말 것" 이라고 적고 있다). **튜닝 파라미터에 의존하는 지표는 헤드라인이 될 수 없다.**
3. **용어가 부정확하다.** 논문에서 regret 은 보통 bandit/online learning 의 **누적 regret**
   (T 스텝 동안 최선 고정팔 대비 손해)이다. 여기서 재는 것은 1회 결정의 손해이므로 정확한 이름은
   **simple regret** 또는 **suboptimality gap** 이다.

**폐기가 아니라 강등이다.** `subopt_norm` 은 사건 간 집계·짝지은 검정에 여전히 필요하므로 남긴다.
다만 **발표·판정 문장에는 단위 있는 수치만 쓴다.**

**마이그레이션 규칙** (과거 아티팩트를 깨지 않기 위해):
`regret` 은 20개 py 파일·350여 곳·JSON 키에 박혀 있다. 따라서 **JSON 은 새 키를 추가하고
`regret` 키를 별칭으로 남긴다.** 기존 함수명(`verify.norm_regret`)은 그대로 두고 새 이름을
별칭으로 추가한다. 일괄 치환은 하지 않는다 — 발표 숫자의 근거인 옛 아티팩트를 읽는 스크립트가
조용히 깨진다.

### 0-b. 헤드라인 문장의 형태

판정은 항상 이 세 숫자로 적는다:

> "N개 사건에서 **최적행동 적중률 XX%**, 틀렸을 때 **평균 X.X 노드 손해**,
> **완주를 놓친 선택 X건(X.X%)**."

`subopt_norm 0.100` 보다 방어하기 쉽다 — 각 숫자가 시뮬레이터의 실제 양이고 λ·span 에 오염되지 않는다.

### 분해식 — 이번 7시간이 닫는 것

```
초과비용_LLM  =  천장_관측(Ch-B)  +  격차_어휘(Ch-A)  +  격차_서술자(Ch-C)
               +  격차_채점(Ch-D)  +  격차_절차(Ch-E)  +  기약 동점
```

각 항을 **따로 측정**하기 전에는 "LLM 이 추론을 못 한다"는 진단 자체가 성립하지 않는다.
지금까지의 모든 LLM 수치는 이 다섯이 뒤엉킨 합계다.

---

## 1. 왜 지금은 불가능한가 — 다섯 천장과 그 증거

| | 천장 | 코드 증거 | 결과 |
|---|---|---|---|
| **Ch-A** | **행동 어휘 불일치** | `llm_producer.py:82` `MACRO_NAME` 에 **8(SwapBattery) 없음** · `dspy_service.py:75` 6개 · `steering_signature.py:36` **5개**(7·8 둘 다 없음) · `e1_analyze.py:70` `[0,1,2,3,4,7,8]` · `gen_oracle_dataset.jl:76` `[0,1,2,3,4,8]`(**7 없음**) | README §4 가 battery 의 기본 정답이라 못박은 `SwapBattery` 를 **LLM 은 발화할 수 없고**, zone 의 정답 `RelocateBuild` 를 **오라클은 채점하지 않는다**. 정답이 어휘 밖이면 초과비용은 절대 0 이 안 된다 |
| **Ch-B** | **관측 채널 결손** | `firegrid_merged.jsonl`(414행, 108 instance) 키에 `nl`·`nl_source` **없음**; `zone_blocked`·`n_nav_blocked` 등 STEP 3 원시값도 **없음** | LLM 입력 문장이 `nl_events.py` **합성본**이다(`DESIGN_ASSIMILATION` §6-1 이 "헤드라인은 재생성 후에 인용" 이라 적어둔 그 상태 그대로). 그리고 "막혔다" 를 볼 열이 없다 — 라우터 에스컬레이션 조건 (d) 와 **같은 구멍** |
| **Ch-C** | **서술자에 개입 비용 축이 없다** | `features_agnostic.py` 서술자 6개 = `[harm, work_at_risk, resource_loss, recovery_capacity, progress, slack]` | zone 인과 규칙이 **1/2** 인 것과 동일 원인(`STATUS` §1). 수복의 **파괴력**(측정치: cov 가족 232→197 = −35)을 담는 축이 없어 LLM 이 zone 에서 과잉개입한다(적중률 0%, 서술자 수정 후에도 미해결) |
| **Ch-D** | **채점 기준의 공백** | `gen_oracle_dataset.jl:76` (7 팔 부재) + 동점 61/108 | "정답" 이 없는 사건에서 초과비용을 재고 있다. 완벽을 정의할 대상 자체가 결손 |
| **Ch-E** | **절차가 1-샘플 greedy** | `llm_producer.decide()` temperature=0, 단발, 기권 없음, 자기검증 없음 | 자기일관성·기권·검증 왕복이 전무. 위 넷을 다 고쳐도 남는 마지막 항 |

> 부수 사실: C1/C3/C4 **드라이버 3개가 삭제됐다**(`c1_novel_kind.py`·`assimilation_stream.py`·
> `test_assimilation.py`). 라이브러리(`llm_producer.py`·`nl_events.py`·`verify.py`·
> `openworld_experiments.py`)는 전부 살아 있으므로 **얇은 드라이버 하나로 재건**한다(P5).
> 옛 드라이버를 복원하지 않는 이유: 그것들은 삭제된 어휘·서술자 가정 위에 서 있다.

---

## 2. 운영 규칙 (어기면 결과가 조용히 틀린다)

1. **★ 전경에서 시간·완주 비교를 돌리지 않는다.** P1 의 라벨 잡이 7시간 내내 배경에서 도므로,
   같은 기간의 Julia 비교 실행은 HiGHS MILP CPU 경합으로 **다른 스케줄**을 낸다(함정 30).
   → 배경 라벨링 중의 전경 작업은 **파이썬 분석 + LLM 호출뿐**.
2. **병렬 2 상한** (프로세스당 ~2.5 GB, `DS_STACK=1000000000`) — 함정 31.
3. `set -e` 금지, 단계 실패해도 다음으로. 스크립트명 기반 프로세스 킬 금지(함정 32).
4. `PYTHONIOENCODING=utf-8`, 로그는 UTF-8 강제(함정 33·34).
5. 패치는 heredoc `assert` 말고 Edit 도구로(함정 35).
6. **CANONICAL 은 건드리지 않는다** — `openworld_merged.jsonl` 은 발표 숫자의 근거.
   새 산출물은 전부 `artifacts_llm7h/` 와 `oracle/out/llm7h_*` 아래로.
7. 모든 변경은 **opt-in 환경변수**. 기본 경로의 바이트 동일성을 P0 의 베이스라인으로 검증한다.
8. LLM 호출은 `llm_cache/` 에 남으므로 재실행은 무료. 키가 없으면 `LLM_MOCK=1` 로 배선까지만 가고
   품질 수치는 **미측정**으로 보고한다(추정치를 적지 않는다).

---

## 3. 타임라인

| 시각 | 페이즈 | 무엇 | 시뮬 | 성공 기준 |
|---|---|---|---|---|
| 0:00–0:20 | **P0** | 프리플라이트 · 베이스라인 동결 | 0 | 현재 수치 4개가 `baseline.json` 에 박힘 |
| 0:20–0:40 | **P1** | **장시간 라벨 잡 착수**(배경 ~5h) | ▲▲▲ | 스모크 1 instance 에서 새 열(`nl`,7팔)이 실제로 나옴 |
| 0:40–1:45 | **P2** | Ch-A: 행동 어휘 단일화 | 0 | `audit_action_vocab.py` 6/6 GREEN |
| 1:45–2:45 | **P3** | Ch-B: 관측 채널 (nl 캡처 + 막힘 원시값) | 0 | Julia↔Python 파리티 + 새 NL 상한 재계산 |
| 2:45–3:45 | **P4** | Ch-C: 7번째 서술자 `repair_disruption` | 0 | zone 2사건에서 정답이 갈림 |
| 3:45–4:45 | **P5** | Ch-E: `llm_eval.py` 재건 + 자기일관성 + 기권 | 0 | risk–coverage 곡선 산출 |
| 4:45–5:30 | **P6** | 안전필터 왕복 · 거부율 측정 | 0 | 거부율 + 폴백 로그 |
| 5:30–6:30 | **P7** | 라벨 수확 → 재채점 → G1/G2/G3 | 0 | 게이트 3개 판정 |
| 6:30–7:00 | **P8** | 리포트 · `STATUS.md` 갱신 · 커밋 | 0 | `md/RESULTS_LLM7H.md` |

**중단 지점**: P2~P6 는 서로 독립이므로 어느 하나가 실패해도 나머지를 계속한다.
P7 만 P1 에 의존하고, P1 이 죽으면 §7 의 폴백 데이터로 진행한다.

---

## 4. 페이즈 상세

### P0 (0:00–0:20) — 프리플라이트 & 베이스라인 동결

```bash
export PYTHONIOENCODING=utf-8
cd wm4spacecraft_manufacturing && mkdir -p artifacts_llm7h

# 1) env 이름을 추측하지 말고 실제 목록을 뽑는다 (CLAUDE.md 지침)
grep -rho 'get(ENV, *"[A-Z0-9_]*"' ../src ../tools oracle | sort -u > artifacts_llm7h/env_knobs.txt

# 2) 지금 수치를 동결 — 이후 모든 변경은 이것과의 차이로만 말한다
python e1_analyze.py --data oracle/out/firegrid_merged.jsonl --json artifacts_llm7h/baseline_firegrid.json
python openworld_experiments.py loko --json artifacts_llm7h/baseline_loko.json
python nl_events.py oracle/out/firegrid_merged.jsonl   > artifacts_llm7h/baseline_nlceiling.txt
python verify.py                                        > artifacts_llm7h/baseline_verify.txt
```

**동결할 4개 숫자**: (a) firegrid 108-instance 의 surrogate 적중률·초과비용, (b) LOKO 폴드별 초과비용,
(c) NL-only 상한, (d) `verify.py` 8/8. P8 에서 이 넷이 **나빠지지 않았는가**가 G1 이다.

> 인자 이름이 위와 다르면 `--help` 로 확인하고 **플랜이 아니라 명령을 고친다**. 스크립트를 바꾸지 않는다.

### P1 (0:20–0:40 착수, 배경 ~5h) — 라벨 잡

**이 7시간에서 유일하게 시뮬을 쓰는 작업이고, 늦게 시작하면 못 끝난다. 먼저 띄운다.**

목적 3가지를 한 번에 얻는다:
1. `nl`/`nl_source` **실제 캡처** (합성본 탈출 — `DESIGN_ASSIMILATION` §5 의 "4) 확정본" 단계)
2. **7(RelocateBuild) 팔 라벨** — Ch-D 를 닫는 유일한 방법
3. zone **원시값 열**(`zone_blocked` 등, opt-in)

```bash
cd wm4spacecraft_manufacturing/oracle
# 0) 스모크 1건 — 새 열이 실제로 나오는지 확인한 뒤에만 대량으로 넘어간다
DS_SMOKE=1 DS_SEEDS=1 DS_KINDS=zone \
DS_EP_MACROS="0,3,7" DS_ZONE_RAW=1 DS_LOG=info \
DS_STACK=1000000000 DS_OUT=out/llm7h_smoke.jsonl \
  julia +lts --project=.. gen_oracle_dataset.jl 2>&1 | tee ../artifacts_llm7h/p1_smoke.log

python - <<'PY'
import json
r=[json.loads(l) for l in open("out/llm7h_smoke.jsonl",encoding="utf-8")]
need={"nl","nl_source","zone_blocked"}
print("행수",len(r),"팔",sorted({x["macro"] for x in r}))
print("결손열",need-set(r[0]))
PY
```

**게이트**: 결손열이 비어 있고 팔에 7 이 있으면 대량 실행, 아니면 **P1 을 중단**하고 그 사실을 로그에
남긴 뒤 §7 폴백으로 간다(있지도 않은 열을 기다리며 5시간을 버리지 않는다).

대량(2병렬, lane 당 kind 분리 — 같은 lane 안은 순차):

```bash
# lane A : zone 발화점 격자 (7팔이 핵심)
DS_SEEDS=1 DS_KINDS=zone DS_EP_MACROS="0,3,7" DS_ZONE_RAW=1 \
DS_OUT=out/llm7h_zone.jsonl  DS_STACK=1000000000 julia +lts --project=.. gen_oracle_dataset.jl &
# lane B : battery/fault 조밀 격자 (SwapBattery 8 팔 포함, STATUS §2 "다음 1")
DS_SEEDS=1 DS_KINDS=battery,fault DS_EP_MACROS="0,1,2,8" DS_BSOC_MODE=abs \
DS_OUT=out/llm7h_batt.jsonl  DS_STACK=1000000000 julia +lts --project=.. gen_oracle_dataset.jl &
wait
```

**예산 감각**: 라벨 1개 ≈ 81 s(측정), instance 당 3~4 팔 → instance 당 4~6 분.
5시간 × 2 lane ≈ **80~110 instance**. 이게 P7 이 쓸 수 있는 전부다.
lane 별로 30분마다 행 수를 찍어 진척을 로그에 남긴다.

### P2 (0:40–1:45) — Ch-A: 행동 어휘 단일화

**단일 진실원 하나**를 만들고 5곳이 그걸 읽게 한다. 새 추상화가 아니라 **JSON 한 장**이다.

```
wm4spacecraft_manufacturing/action_registry.json
{ "7": {"name":"RelocateBuild","cost":1.5,"psi":[...],"doc":"shift the ENTIRE build ..."},
  "8": {"name":"SwapBattery",  "cost":0.2,"psi":[...],"doc":"swap only the battery in place ..."} , ... }
```

배선 대상 5곳(전부 **읽기만** 하도록 바꾼다, 값은 현행 유지):

| 파일 | 지금 | 조치 |
|---|---|---|
| `llm_producer.py:82` `MACRO_NAME` | 8 없음 | 레지스트리에서 로드 → **SwapBattery 발화 가능** |
| `src/respec/llm_service/dspy_service.py:75` | 6개 | 〃 |
| `src/respec/llm_service/steering_signature.py:36` | 5개 | 〃 |
| `features_agnostic.py:156,164,332` | 7·8 있음 | 값 일치 검사만 |
| `oracle/gen_oracle_dataset.jl:76` `MACROS` | 7 없음 | `DS_MACROS` 기본값을 레지스트리에서 읽음(**기본 동작 불변**: 7 은 zone kind 에서만 valid) |

검사기 신설 `audit_action_vocab.py` — 6개 소비처(위 5 + `e1_analyze.MACRO_COST`)의
**id↔이름↔비용**이 전부 같은지 assert. README §2 의 경고("세 곳을 같이 늘려야 한다")를
주석이 아니라 **테스트**로 만든다.

**수용 기준**
- `python audit_action_vocab.py` → `6/6 consistent`
- `LLM_MOCK=1 python llm_eval.py --smoke` 에서 battery 행에 대해 파서가 `SwapBattery` 를 **id 8 로** 되돌린다
- P0 베이스라인 4개 숫자가 **바이트 동일**(기본 경로 무변경 증명)

**롤백**: 레지스트리 로딩을 `try/except` 로 감싸 실패 시 옛 리터럴로 폴백 — 하지 않는다.
조용한 폴백은 함정 4 와 같은 종류의 사고를 만든다. 실패하면 **큰 소리로 죽인다**.

### P3 (1:45–2:45) — Ch-B: 관측 채널

1. **캡처율 표시 의무화**: 모든 LLM 리포트 첫 줄에 `nl_source` 의 captured/synthesized 비율.
   합성본으로 만든 수치는 파일명에 `_synth` 를 붙인다(발표 인용 사고 방지).
2. **막힘 원시값을 LLM 입력에 opt-in 으로 추가**: `zone_blocked`, `n_nav_blocked`,
   `downstream_frozen`(막힌 노드가 잠그는 하류 작업 수 — `STATUS` §1 "다음 1(a)").
   스위치 `LLM_OBS_BLOCKAGE=1`, 기본 OFF.
3. **파리티 검사**: `features_agnostic.py` ↔ `src/safety/novelty.jl` 두 쌍둥이가 같은 값을 내는지
   (기존 33/33 검사와 같은 방식). 이게 깨지면 Julia 라이브 데모와 파이썬 평가가 **다른 시스템**이 된다.
4. **NL 상한 재계산**: `nl_partition_ceiling()` 을 새 데이터에서. 상한이 안 내려가면 문장을
   아무리 잘 읽어도 소용없다는 뜻이므로 **P5 의 목표치를 상한으로 갈아끼운다**.

**수용 기준**: 파리티 GREEN + 새 상한 숫자 + `LLM_OBS_BLOCKAGE=0` 일 때 P0 수치 불변.

### P4 (2:45–3:45) — Ch-C: 서술자 7번째 축 `repair_disruption`

**"막힘 > 0 은 개입의 필요조건이지 충분조건이 아니다"**(`STATUS` §1) 를 서술자로 만든다.

```
repair_disruption = (수복이 흩뜨리는 진행 중 작업량) / (막힌 노드가 잠그는 하류 작업량)
                     ↑ RelocateBuild = 전역 강체이동 → 진행 중 팀 전부
```
값이 1 보다 크면 수복이 손해다. 실측 앵커가 이미 있다: cov 가족 232 → 197 = **−35**.

주의(반드시 지킬 것):
- **차원이 바뀌면 export 된 surrogate·novelty 교정과 호환되지 않는다**(README §5).
  → 새 교정 파일 `novelty_calibration_d7.json` 을 **따로** 만들고 기존 두 파일은 손대지 않는다.
- 옛 덤프에는 열이 없으므로 `-1`(=모름) 센티넬. **0.0 으로 채우지 말 것**(함정 12).
- 프롬프트에 규칙을 산문으로 넣지 않는다(README §4) — **숫자 한 축을 더 줄 뿐**이다.

**수용 기준**: zone 두 사건(blocking / core)에서 LLM 이 각각 `RelocateBuild` / `NOOP` 을 고른다.
이게 되면 zone 인과 규칙 1/2 문제가 **규칙표가 아니라 정책 쪽에서** 풀린 것이다.
안 되면 그 사실을 그대로 기록한다 — 서술자 하나로 안 되는 것도 결과다.

### P5 (3:45–4:45) — Ch-E: 드라이버 재건 + 자기일관성 + 기권

`llm_eval.py` 신설(삭제된 3개 드라이버의 얇은 대체, ~150줄 목표):

```
llm_eval.py --data <jsonl> --arm nl+state --k 5 --abstain-tau 0.6 --json out.json
  ├ 채점(§0-a 새 용어)       : verify.py · openworld_experiments.py 를 재사용하되 subopt_norm 은
  │                            진단으로만 두고 excess_cost 3층·적중률을 새로 계산
  ├ producer                 : llm_producer.decide()
  ├ 자기일관성 K=5           : temperature 0.7 × 5 표결, 표결 분산 = 신뢰도
  └ 기권                     : 신뢰도 < τ 면 escalate (= surrogate/oracle 로)
```

**함정 15 를 반드시 피한다**: `len(g)==5` 로 instance 를 거르면 새 라벨이 통째로 폐기된다.
`instance_arms_complete(g)` 를 쓴다. **함정 16**: 출처 폴더를 그룹 키에 포함(사다리 소멸 방지).
**함정 17**: 동점 제외 후 재계산(`reg_NOTIE`)을 같이 찍는다.

**산출**: risk–coverage 곡선 (x=coverage, y=`excess_cost`) + AURC — arm 4종 비교
`nl` / `nl+state` / `nl+state+blockage`(P3) / `+repair_disruption`(P4).

**헤드라인 판정**: 어떤 coverage 에서 **초과비용 0노드·0초(= 적중률 100%)** 에 도달하는가.
비용: 108 instance × 5 표결 × 4 arm ≈ 2160 호출, gpt-4o-mini 기준 수 달러 · 캐시로 재실행 무료.

### P6 (4:45–5:30) — 안전 필터 왕복

LLM 이 낸 제안을 `safety_filter.py` 3층(문법/의미/불변식) → `src/respec/verifier.jl` 로 통과시키고,
거부되면 canonical 폴백 + **거부 사유를 로그**(`PLAN_ACTION_GROWTH` §4-[4]).

- **거부율 자체가 측정값**이다(그 계획의 R4).
- `allow_mixed_kinds=False` 는 **유지**한다. A0 다중 spec 디스패처가 없는 한 혼합 조합은
  조용히 버려지므로(`PLAN_ACTION_GROWTH` §2 정정), 큰 소리로 거부하는 것이 옳다.

**수용 기준**: 거부율 표 + 거부 사유 히스토그램 + 폴백 후 초과비용이 무필터 대비 나빠지지 않음.

### P7 (5:30–6:30) — 라벨 수확 → 재채점 → 게이트

```bash
python merge_firegrid.py oracle/out/llm7h_zone.jsonl oracle/out/llm7h_batt.jsonl \
       --out oracle/out/llm7h_merged.jsonl
python llm_eval.py --data oracle/out/llm7h_merged.jsonl --k 5 --json artifacts_llm7h/final.json
```

- **G1**(회귀): P0 의 베이스라인 4개에서 유의하게 나빠지지 않았는가 — 짝지은 부트스트랩.
- **G2**(개선): 7 팔이 들어간 zone instance 에서 적중률·초과비용이 유의하게 좋아졌는가.
- **G3**(교정): novelty 호출률이 폭주하지 않는가(d7 교정 파일 기준).

하나라도 실패면 **그 변경만 롤백**하고 후보로 남긴다(삭제하지 않음).
표본이 작으면 **판정하지 않는다**(함정 18) — n 과 CI 를 같이 찍고 "미확립" 으로 적는다.

### P8 (6:30–7:00) — 리포트

`md/RESULTS_LLM7H.md` 신설 + `STATUS.md` §0 표 갱신. 리포트 필수 항목:

1. 다섯 채널별 **before/after 기여도** (분해식의 각 항)
2. risk–coverage 곡선 + AURC + "초과비용 0 을 달성한 coverage"
3. 캡처/합성 비율 · n · CI · 동점률
4. **하지 못한 것과 이유** (§6)

---

## 5. 산출물

```
wm4spacecraft_manufacturing/
  action_registry.json          # P2  단일 진실원
  audit_action_vocab.py         # P2  6곳 일치 검사
  llm_eval.py                   # P5  삭제된 c1/stream 드라이버의 대체
  novelty_calibration_d7.json   # P4  7서술자용 별도 교정(기존 파일 무변경)
  artifacts_llm7h/              # 전 페이즈 로그·json·곡선
  oracle/out/llm7h_{zone,batt,merged}.jsonl   # P1 라벨
  md/RESULTS_LLM7H.md           # P8
```

---

## 6. 이 7시간이 **하지 않는** 것 (그리고 왜)

| 안 하는 것 | 이유 |
|---|---|
| **B1 능력상실 = 진짜 OOD(N) 구현** | README §1 기준 battery/zoneblk/fault 는 **OOD 가 아니라 알려진 고장모드 F** 다. 진짜 OOD 실험은 엔진에 "특정 능력만 잃는다" 개념을 새로 넣어야 하고, 그것만으로 하루가 든다. **이 7시간은 그 무대를 만드는 준비**다 — P2 의 레지스트리가 있으면 새 행동 추가가 JSON 한 줄이 된다 |
| **A0 다중 spec 디스패처** | `maybe_respecify!` 의 첫-매치-승리 체인을 바꾸는 일 = 엔진 수술 + 전 회귀 재검. 7시간 안에 안전하게 못 넣는다. 그때까지 혼합 조합은 P6 에서 **큰 소리로 거부** |
| **makespan 예측 헤드 / μ-키 배포** | λ→μ 전환의 선행조건이지만 추론 품질과 직교(`STATUS` §3) |
| **`DEMO_POLICY=noop` 버그 · 무작위 스트림 스위프** | `STATUS` §5 의 최우선 과제지만 **Julia 전경 실행**이 필요하다 → 운영규칙 1(배경 라벨 잡과 CPU 경합)에 정면으로 걸린다. P1 이 끝난 **다음 세션의 첫 작업**으로 둔다 |
| **DSPy 컴파일 프로그램 재컴파일** | 현 `dspy_real_program_gpt4o.json` 은 배터리 전용이라 zone 어휘가 없다(`STATUS` §1 경고). 재컴파일은 P7 의 새 라벨이 쌓인 **뒤에** 해야 의미가 있다 |

---

## 7. 폴백 — P1 이 죽거나 느릴 때

| 상황 | 조치 |
|---|---|
| 스모크에서 `nl`/7팔 열이 안 나옴 | P1 **즉시 중단**. `firegrid_merged.jsonl`(108) + `lad_*`(32, 결정적) 로 P5~P7 진행. 7 팔 관련 결론은 **"미채점"** 으로 명시 |
| 5:00 까지 instance < 20 | 있는 만큼만 병합. n 과 CI 를 찍고 G2 는 **미확립** 처리(함정 18) |
| API 키 없음 | `LLM_MOCK=1` 로 배선까지만. P2·P3·P4·P6 은 전부 완주 가능(LLM 호출 불요), P5 품질 수치만 미측정 |
| 파리티 검사 실패(P3) | 그 변경 롤백 후 진행. Julia/Python 이 갈린 채로 만든 수치는 인용 불가 |

---

## 8. 이 계획이 성공했다면 P8 에 이렇게 적힌다

> "LLM 은 이제 `SwapBattery`·`RelocateBuild` 를 발화할 수 있고(Ch-A), 실제 관측 문장과 막힘 원시값을
> 읽으며(Ch-B), 수복의 파괴력을 하나의 축으로 본다(Ch-C). 오라클은 7 팔을 채점한다(Ch-D).
> K=5 표결 + 기권으로, **coverage X% 에서 최적행동 적중률 100% · 초과비용 0노드 0초** 다(Ch-E).
> 남은 오차는 전부 NL 상한과 동점 구간에 있다."

이 문장의 **X 를 채우는 것**이 7시간의 유일한 목표다.
