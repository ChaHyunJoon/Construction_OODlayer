# 평가 보강 계획 — baseline 사다리 · case별 비교 (2026-08-09 추가)

> **이 절은 2026-08-09 늦게 덧붙였다.** 아래 §II(원 문서, "오라클 라벨 재빌드 계획")는 독립 작업이
> 아니라 **이 계획의 STEP D** 다. 두 문서를 한 파일에 둔 이유는 STEP D 가 나머지 STEP 과 **CPU 를
> 다투기 때문**이다 — 순서를 모르면 둘 다 무효가 된다(함정 30).
>
> **신뢰 등급.** §0~§2 의 "현재" 열은 2026-08-09 에 아티팩트·소스를 **읽어서 확인한 사실**이다.
> §5 의 소요시간은 `artifacts_llm7h/final.json` 의 `wall_seconds` **실측**에서 곱한 것이지만,
> case별 런의 판당 시간이 `all` 과 같다는 보장은 없으므로 **추정**이다. §3 의 명령은 기존 드라이버의
> 인자를 조합한 것이고 **끝까지 돌려본 적은 없다.**

---

## 0. 왜 쓰는가 — 덱(2026-08-17)의 evaluation 이 방어되지 않는다

발표덱 `SISL_labmeeting_260817` 의 평가 슬라이드는 metric 4개(완주율·옳은 결정·빌드 시간·에너지)와
baseline 3개(`Oracle` / `Only LLM` / `Only surrogate`)를 적었다. 저장소의 실제 상태와 대조한 결과
**세 가지가 어긋난다.**

| # | 어긋남 | 근거 (2026-08-09 실측) |
|---|---|---|
| **1** | **제안한 2층 시스템이 결과표에 한 줄도 없다** | 20판 전부 `DEMO_ROUTER=0`(`llm_ood_eval.py:73`). 두 층을 **따로** 쟀고, 라우터가 붙은 판은 측정된 적이 없다. 덱 슬라이드 8 의 아키텍처가 곧 미측정 대상이다 |
| **2** | baseline 이 "가장 싼 반증"을 담고 있지 않다 | 덱의 3개는 전부 **강한** 대조군이다. 정작 주장을 죽일 수 있는 싼 설명(kind 룩업표·random-over-valid·편집 없는 MILP 전면 재해)이 없다. `always_per_kind`/`random` 은 오프라인 격자용(`e1_analyze.py:336`)으로만 존재하고 **스트림 평가에는 배선되지 않았다** |
| **3** | case별 비교가 4축 중 **1축**만 가능하다 | 한 판에 4사건이 **섞여** 터지므로 완주·시간·에너지를 case 에 귀속할 수 없다. 종류별로 나오는 것은 "옳은 결정" 하나뿐이다(`final.json::per_kind`) |

**#2 가 가장 위험하다.** 이 저장소가 이미 측정해 둔 `H(best|kind) = 0.00 bits`(fault, README §3)는
*fault 축은 종류 이름만으로 정답이 결정된다*는 뜻이다. 3행짜리 룩업표가 fault 6/6 을 그냥 맞힌다.
지금 표의 `dspy` 18/20 중 6개는 룩업표도 맞히는 것이므로, **B1 을 표에 올리기 전까지 남는 마진이
얼마인지 아무도 모른다.**

## 1. 현재 채워져 있는 셀 (재측정 불필요 — `artifacts_llm7h/final.json`)

| policy | Battery | Fault | Zone | 합계 | 완주 | sim s | J/closed |
|---|---|---|---|---|---|---|---|
| `noop` | 0/6 | 0/**5** | 0/6 | 0/17 | 0/5 | — | 856 |
| `canonical` | 0/6 | 6/6 | 0/7 | 6/19 | 4/5 | 66.3 | 971 |
| `surrogate` | 0/6 | 6/6 | **7/7** | 13/19 | 4/5 | 35.5 | 739 |
| `dspy` | **6/6** | 6/6 | 6/8 | 18/20 | 5/5 | 41.0 | 538 |

이 표를 인용할 때 **반드시 함께 적을 것**:

- `noop` 의 fault 분모만 **5** 다(나머지 6). 총 결정 수도 47/49/29/30 으로 제각각 — **정책 간 동일
  분모가 아니다.** STEP A 가 이것을 고친다.
- `surrogate` 행만 2026-08-07 재적합 세대, 나머지 3행은 08-06 재사용.
- zone 열은 정답률이 아니라 **n=2 격자에서 유도한 규칙과의 일치율**이다(§5-g).
- 축 이름 "옳은 결정(correct decision)"은 오라클로 오독된다. 덱에는
  **"기준 정책 일치율 (agreement with measured reference policy)"** 로 적고 축별 근거 n
  (battery 18 / fault 42 / **zone 2**)을 병기한다.

## 2. Baseline 사다리 — 무엇을 반증하는가로 정의한다

graph 를 **수리**하는 선행연구가 없다는 것은 LLM 문헌만 봤을 때 참이다. 비교 대상은
**predictive-reactive scheduling / plan repair** 문헌이고, 그 baseline 들이 이 저장소의 행동공간에
그대로 대응된다. 아래 표의 굵은 항목이 **지금 없는 것**이다.

| # | 팔 | 문헌 대응 | 무엇을 반증하는가 | 현재 |
|---|---|---|---|---|
| B0 | `noop` | right-shift rescheduling | 적응이 필요하긴 한가 | ✅ 0/5 완주 |
| **B1** | **kind→macro 룩업표** | — | **"상태를 읽는다"는 주장 전체** | ❌ 오프라인에만 |
| **B2** | **random-over-valid** | — | 메뉴가 좁아서 맞은 것 아닌가 | ❌ |
| B3 | `canonical` | dispatching rule | 학습이 필요한가 | ✅ |
| B4 | `surrogate` | — | LLM 이 필요한가 | ✅ |
| B5 | `dspy` | — | surrogate 가 필요한가 | ✅ |
| **B6** | **라우터 ON = 제안 시스템** | multi-rate routing (DEXTER-LLM) | **논문의 주장 그 자체** | ❌ 미측정 |
| **B7** | **편집 없는 MILP 전면 재해** | complete regeneration | **graph edit 이 필요한가** | ❌ |
| **B8** | 반사실 오라클(전 팔 교차) | — | 상한선 | ⚠️ 3축 중 **2축 삭제됨** → STEP D |
| **B9** | **LLM text-only**(kind 이름만) | — | LLM 이 상태를 읽는가, 이름만 보는가 | ❌ |

**B7 이 왜 필요한가.** 발표장의 첫 질문은 *"그냥 MILP 를 다시 풀면 되지 않나"* 다. 덱 슬라이드 8 의
`MILP re-solve` 박스는 **그래프 편집을 고른 뒤** 도는 것이라 편집 자체의 필요성을 증명하지 못한다.
`RelocateBuild`·`SwapBattery` 처럼 재배정으로는 도달 불가능한 편집이 있다는 것이 논지의 핵심인데,
그걸 보여주는 팔이 표에 없다.

**B9 가 왜 필요한가.** `RESULTS_LLM7H §5-e` 는 LLM 이 `work frozen = 32` 가 프롬프트에 들어 있는데도
두 번 `NOOP` 을 골랐다고 기록한다. 상태를 안 읽을 가능성이 실측으로 열려 있으므로, text-only
ablation 없이 "LLM reasoning" 이라 부를 근거가 없다.

### 추가할 metric 3개

현재 4축은 방향은 맞지만 **아키텍처가 주장하는 것을 재는 축**이 빠져 있다.

| 축 | 왜 | 재는 법 | 선행조건 |
|---|---|---|---|
| **결정 지연 / 플래너 호출 수** | fast/slow path 가 논지인데 **시간 축이 metric 목록에 없다**. surrogate 0.11 ms vs LLM 수 초 vs MILP 81 s | `cost_eval.py` 실측 재사용 | 없음 (즉시) |
| **catastrophic-choice rate** | 평균만 보면 "완주를 놓친 선택"이 숨는다. 실측: `always-NOOP` 과 `always-Replace` 의 subopt 가 0.490 vs 0.500 으로 구별 불가인데 실패 방식은 완전히 다르다(`EVALUATION.md:36`) | 완주 가능한 팔이 있었는데 안 고른 비율 | **STEP D** (오라클) |
| **plan stability** (Fox et al. 2006) | 개입의 **파괴력**. `RelocateBuild` 가 때때로 손해인 이유를 설명하는 유일한 축(실측: cov 가족 232 → 197 = **−35**) | 원 스케줄 대비 바뀐 배정/노드 수 | 신규 계산 |

---

## 3. STEP A — 시뮬 0회로 회수한다 (**가장 먼저**)

**발견**: 모든 결정 레코드가 세 producer 가 각각 무엇을 골랐을지를 **이미 다 기록하고 있다**
(shadow mode). 2026-08-09 확인 — `results/llm_ood_eval.jsonl` 의 **155개 결정 전부**에서
`rule` / `surrogate` / `llm` 세 필드가 채워져 있다:

```json
{"truth":"BatteryTruth", "valid":["NOOP","Replace","Deprioritize","SwapBattery"],
 "rule":"Replace", "surrogate":"Replace", "llm":"SwapBattery", "macro":"SwapBattery",
 "soc":0.0, "agent_pending":4, "router_p":0.693, "router_novel":false, "escalated":false}
```

따라서 **새 시뮬 없이** 다음이 나온다:

1. **동일 사건·동일 분모** 위의 4 producer 채점 → §1 의 분모 불일치(47/49/29/30) 해소
2. **B1**(kind 룩업표)·**B2**(random-over-valid) 추가 — `truth` 와 `valid` 만 있으면 계산된다.
   zone 의 `valid` 는 `[NOOP, RelocateBuild]` 이므로 B2 의 기댓값은 **50%** 다. `surrogate` 의 zone
   7/7 이 이 바닥선 위로 얼마나 올라가는지가 그 셀의 진짜 값이다
3. `router_p` / `router_novel` 이 라우터가 꺼진 판에서도 기록되므로 **novelty 게이트의 사후 재생**

**할 일**: `wm4spacecraft_manufacturing/shadow_score.py` 신규(~40줄). 입력
`results/llm_ood_eval.jsonl`, 채점기는 `reference_policy.score` 재사용, 출력은
`llm_ood_eval.py report --md` 와 같은 형식의 markdown 조각.

**반드시 함께 적을 해석 한계**: 실행된 정책이 이후 세계를 갈라놓으므로 shadow 채점은
**"이 상태에서 정책 X 는 a\* 를 골랐겠는가"**(상태 조건부 결정 충실도)이지 **결과 비교가 아니다.**
완주·시간·에너지를 shadow 로 말하면 안 된다. 다만 덱의 "Rate of correct decision making" 축은
정확히 이것을 뜻하므로 그 슬라이드에는 그대로 쓸 수 있다.

**이미 나온 부수적 실측 하나** (STEP E 의 근거): `dspy` lane 30개 결정에서
`router_novel` 이 **30/30 전부 `false`**, `escalated` 는 **전 lane 0** 이다. 즉 측정된 스트림에서
**novelty 게이트는 한 번도 발화하지 않는다.** 라우터가 켜졌다면 novelty 만으로는 아무 사건도 LLM 으로
올라가지 않았을 것이다. 표현력(expressiveness) 게이트가 대신 발화했을지는 이 판들에서 **꺼져 있었으므로
기록이 없다**(§1-a) — 그래서 STEP E 가 필요하다.

## 4. STEP B~F — 실행 순서와 명령

모든 명령은 `wm4spacecraft_manufacturing/` 에서(Julia 런은 드라이버가 repo 루트로 `cd` 한다).
**★ 전 구간 순차 실행.** 병렬이면 HiGHS 가 다른 스케줄을 내 정책 비교 자체가 무효다(함정 30).

### STEP B — 검정력: 시드 5 → 10

지금 5시드에서 짝지은 부호검정의 **최소 p 는 0.062** 다. 5-0 완승이어도 p<0.05 가 **원리적으로
불가능**하다. 양측 부호검정에서 `2·(1/2)^n < 0.05` 를 만족하는 최소값은 **n=6**(p=0.031)이고,
n=10 이면 0.002 다. **6 이 최소선, 10 이 목표.**

```bash
python llm_ood_eval.py run --seeds 6,7,8,9,10 --policies noop,canonical,surrogate,dspy
python llm_ood_eval.py report --json artifacts_llm7h/final.json --md artifacts_llm7h/results_table.md
```

> 시드는 `DEMO_OOD_SEED`(= 언제 어떤 고장이 나는가)이지 `DS_SEEDS`(= 다른 공장)가 아니다.
> world 는 계속 seed 1 고정이다(§5 함정 ⑥ 과 같은 축 분리).

### STEP C — case별 격자 (덱의 새 슬라이드 본체)

단일 kind 스트림은 드라이버가 이미 지원한다 — `case_kinds()` 가
`battery` / `fault` / `zone` 을 각각 단일 원소로 돌려주고(`run_demo.jl:87-101`),
`DEMO_OOD_STREAM3=1` 이면 그 종류만 4번 추첨된다.

```bash
for c in battery fault zone; do
  python llm_ood_eval.py run --case $c --seeds 1,2,3,4,5,6,7,8,9,10 \
    --policies noop,canonical,surrogate,dspy \
    --out results/llm_ood_eval_$c.jsonl                    # ★ --out 분리 필수, 아래 함정 ①
  python llm_ood_eval.py report --out results/llm_ood_eval_$c.jsonl \
    --md artifacts_llm7h/table_$c.md
done
```

이것이 나와야 **완주율·빌드 시간·에너지를 case 에 귀속**할 수 있다. 지금은 "battery 사건에서 LLM 이
완주시켰다"를 말할 근거가 없다 — 한 판에 세 종류가 섞여 있기 때문이다.

### STEP D — 오라클 복구 (= 아래 §II 원 문서 전체)

`a*` 의 근거 파일 2/3 이 삭제돼 있다. 위 §1 표의 fault·zone 열은 **지금 재검증이 불가능**하고,
게이트 `test_llm7h.py` 는 fault 축에서 하드 크래시, zone 축은 **조용히 n=0 으로 통과**한다.
절차는 아래 §II 를 그대로 따른다. **catastrophic-choice rate 의 선행조건**이기도 하다.

### STEP E — 라우터 ON: 제안 시스템을 표에 올린다 (B6)

```bash
DEMO_ROUTER=auto NOVELTY_CALIB=<repo>/novelty_calibration_no_zoneblk.json \
  python llm_ood_eval.py run --seeds 1,...,10 --policies router --out results/llm_ood_eval_router.jsonl
```

- `llm_ood_eval.run_one` 이 `DEMO_ROUTER="0"` 을 **하드코딩**하고 있다(`llm_ood_eval.py:73`) —
  이 STEP 은 그 줄에 옵트인 인자(`--router`)를 다는 **코드 수정을 먼저 요구한다.**
- `policy.jl` 은 `POLICY=="noop"` 이면 라우팅을 끄므로(§1-a) router lane 의 정책 이름은 noop 이면 안 된다.
- 리포트에 **escalation rate**(LLM 으로 올린 비율)와 **risk–coverage** 를 추가한다. 2층 구조를 평가하는
  유일한 metric 이고, STEP A 의 실측(novelty 30/30 false)이 이미 이 축의 첫 데이터점을 준다.

### STEP F — B7 / B9 (구현 필요)

- **B7 편집 없는 MILP 전면 재해**: `RESPEC_PRODUCER` 봉합선(`src/respec/replan.jl:91`)에 빈 제약집합을
  돌려주되 재해를 강제하는 producer 를 꽂는다. 나머지 팔과 **같은 하니스**로 돌아야 비교가 성립한다.
- **B9 LLM text-only**: `LLM_NL_MODE` 에 상태 숫자를 제거한 모드를 추가하고 같은 시드로 재측정.
  `dspy` 와의 차이가 "LLM 이 상태를 읽어서 번 것"의 유일한 추정치다.

## 5. 비용과 순서

판당 wall-clock **실측**(`final.json`): `noop` 137 s · `canonical` 110 s · `surrogate` 96 s ·
`dspy` 91 s → 평균 ~110 s.

| 순서 | STEP | 판 수 | 시간 | 막히면 |
|---|---|---|---|---|
| 1 | **A** shadow 재채점 (B1·B2·동일분모) | 0 | **분 단위** | 없음 — 지금 당장 가능 |
| 2 | **B** 시드 5→10 | 20 | ~40 분 (추정) | — |
| 3 | **C** case별 3×4×10 | 120 | **~3.7 h** (추정) | 함정 ①② |
| 4 | **E** 라우터 ON | 10 | ~20 분 | `--router` 인자 구현 선행 |
| 5 | **D** 오라클 복구 (§II) | 88 + 4 | ~3 h (§4 추정) | §II §5 함정 6개 |
| 6 | **F** B7 · B9 | — | 구현 시간 지배 | — |

**A → B → C 까지만 해도 덱의 evaluation 은 방어된다.** D 는 "그 a\* 를 어떻게 아느냐"는 질문에
답하기 위한 것이고, E 는 "제안 시스템의 숫자"를 위한 것이다. 발표까지 남은 일수가 짧으면
**A · C · E** 를 먼저 하고 D 를 뒤로 미룬다 — 단, 그 경우 §1 의 인용 각주(zone n=2, 근거 파일 부재)를
슬라이드에 **반드시** 남긴다.

## 6. 함정 (2026-08-09 확인)

① **`--out` 을 분리하지 않으면 데이터가 조용히 덮어써진다.** `load_rows` 의 dedup 키가
   `(ood_seed, policy)` 로 **`case` 가 빠져 있다**(`llm_ood_eval.py:130`). 기본 `--out` 으로 case별
   스위프를 돌리면 battery 판이 fault 판을, 나아가 기존 `all` 20판까지 **에러 없이** 덮어쓴다.
   근본 수정은 한 줄이고 하위호환된다(기존 행에 `case` 열이 이미 있다 — 전부 `"all"`):

   ```python
   dedup[(r.get("case"), r.get("ood_seed"), r.get("policy"))] = r
   ```

   같은 이유로 `summarize`/`paired` 도 case 를 섞어 집계하지 않는지 함께 볼 것.

② **zone 단일 kind 스트림은 4연속 주입이 보장되지 않는다.** `inject_blocking_zone!` 은 후보가 실패하면
   무해 가족으로 폴백한다(`RESULTS_LLM7H §2`). `--case zone` 은 한 판에서 4번을 요구하므로 뒤쪽
   사건이 무해로 떨어져 **채점 분모가 판마다 달라질 수 있다.** STEP C 는 zone lane 부터 **1판 스모크**로
   `n_decisions` 와 `truth` 분포를 눈으로 보고 시작할 것.

③ **순차 실행.** 함정 30. STEP B~E 를 겹쳐 돌리면 정책 비교가 무효가 되고, 판당 ~2.5 GB 라 OOM 도 난다.
   STEP D(§II)와 다른 STEP 을 **동시에 돌리지 말 것** — 이 두 문서를 한 파일에 둔 이유다.

④ **shadow 채점을 결과 비교로 쓰지 말 것.** §3 의 한계 문단을 리포트에 그대로 복사한다.

⑤ **`dspy` lane 은 seed 프로그램으로만 돌린다.** 컴파일된 `dspy_real_program_gpt4o.json` 은 배터리
   전용이라 zone·`RelocateBuild` 어휘가 통째로 없다(`DSPY_PROGRAM=__seed_only__`).

⑥ **덱 슬라이드 8 의 `NO · UNSEEN` 가지는 지금 평가할 사건이 없다.** battery/fault/zone 은 전부
   surrogate 훈련셋에 있으므로 정의상 **in-distribution** 이다(README §1: 알려진 고장모드 F ≠ OOD N).
   이 계획의 어떤 STEP 도 그 가지를 측정하지 않는다. 덱에서는 축 이름을
   **"held-out kind (LOKO) = OOD proxy"** 로 바꿔 달거나, 그 가지를 미측정으로 명시할 것.

## 7. 이 계획이 하지 않는 것

- **새 사건 클래스(능력상실 등) 신설** — 진짜 OOD 실험의 선행조건이지만(STATUS §9-5) 엔진에 개념이
  없다. 덱 마감 안에 들어갈 작업이 아니다.
- **`verify.py` 의 `S1 KeyError: 7` 수정** — 아래 §II §6 과 같은 이유로 범위 밖.
- **`openworld_merged.jsonl` 재생성** — novelty 교정 입력으로만 남긴 구세대 라벨이다. 건드리지 않는다.
- **plan stability 의 배선** — §2 에 축으로 적었으나 계산 위치(스케줄 diff)를 아직 특정하지 않았다.
  STEP F 이후로 미룬다.

---
---

# §II. 오라클 라벨 재빌드 계획 — `test_llm7h.py` 게이트 복구 (2026-08-09)

2026-08-09 세대 정리(커밋 `c91b2a5`)에서 매크로 7·8 이전 산출물을 지우면서, `RESULTS_LLM7H.md §4`
가 결과표 재측정 **전에 통과시키라고 지정한 게이트** `test_llm7h.py` 의 입력 두 개가 함께 사라졌다.
이 문서는 그 둘을 다시 만드는 절차다.

> **이 문서의 신뢰 등급.** 아래 §1·§2·§5 는 2026-08-09 에 **실행해서 확인한 사실**이다.
> §3 의 명령은 `LABELING_MANUAL.md` 와 드라이버 스크립트에서 **그대로 옮긴 것**이고, 노브가
> 실재하는지는 확인했지만 **끝까지 돌려본 적은 없다**. §4 의 소요시간은 문서상 수치에서 나온
> **추정**이며 실측이 아니다. STEP 0 스모크를 먼저 통과시킬 것.

---

## 1. 무엇이 깨졌나 (실측)

`python test_llm7h.py` 는 지금 **line 116 에서 죽는다**:

```
FileNotFoundError: .../wm4spacecraft_manufacturing/oracle/out/firegrid_merged.jsonl
```

이 게이트는 세 종류 사건에서 **기준 정책(`reference_policy.py`) vs 오라클 실측 최선**을 대조한다.
축별 현황:

| 축 | 필요한 입력 | 상태 | 실패 방식 |
|---|---|---|---|
| battery | `oracle/out/battgrid_0805_s1.jsonl` | ✅ 살아 있음 | — |
| **fault** | `oracle/out/firegrid_merged.jsonl` | ❌ 삭제됨 | **하드 크래시**(line 116) |
| **zone** | `oracle/out/zcausal_reform/{blk,cov}_{noop,reloc}.json` | ❌ 삭제됨 | **조용히 n=0**(line 140 `except OSError: continue`) |

**zone 축이 더 위험하다.** 파일이 없어도 예외를 삼키고 표본 0으로 "통과"하므로, 고치지 않으면
게이트를 돌려서 초록을 봐도 그것은 **battery 한 축만 검사한 결과**다.

## 2. 왜 두 개나 만들어야 하나 (실측)

`CANONICAL`(`openworld_merged.jsonl`, 300행/60 instance)은 살아 있고 fault instance 를 **18개**
갖고 있다. 그런데 그 18개는 `closed_at_fire` 가 `{50, 58}` **두 값뿐**이다(실측). `RESULTS_LLM7H.md`
가 인용한 fault 축은 **42 instance** 이므로, 나머지 24개가 발화 시점을 흩뿌린 `firegrid` 행이다.

즉 CANONICAL 만으로 `firegrid_merged.jsonl` 을 만들면 게이트는 **돌긴 하지만** 진행도 축이
점 두 개로 되돌아간다 — `LABELING_MANUAL §6` 이 지적한 바로 그 문제(progress sd 0.005)를 다시
불러들인다. 그래서 fault/faultidle lane 을 다시 돌린다.

## 3. 절차

모든 명령은 **`ConstructionBots.jl` 저장소 루트**에서 실행한다.

### STEP 0 — 스모크 (필수, 아직 미검증)

라벨러가 이 트리에서 도는지부터 확인한다. 2026-08-09 에 이 스모크를 띄웠으나 **사용자 요청으로
중단**했으므로, 완주 기록이 없다.

```bash
DS_SMOKE=1 DS_KINDS=battery DS_SPARES=3 DS_HOTSWAP=1 DS_VALID_ONLY=1 \
DS_OUT="$PWD/wm4spacecraft_manufacturing/oracle/out/_smoke.jsonl" \
  julia +lts --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

기대: `_smoke.jsonl` 에 행이 생긴다. 확인 후 그 파일은 지운다.
`gen_oracle_dataset.jl` 은 삭제된 `venv/decpomdp/examples/` 를 include 하던 것을
`oracle/ood_mdp_shim.jl` 로 대체한 상태다(`LABELING_MANUAL §패치`) — 스모크가 그 배선을 함께 검사한다.

### STEP 1 — fault 계열 firegrid lane

드라이버가 남아 있다. **이걸 쓰는 것이 손으로 env 를 나열하는 것보다 안전하다** — 발화점 격자와
`DS_*` 조합이 스크립트 안에 이유와 함께 박혀 있다.

```powershell
pwsh -File wm4spacecraft_manufacturing/oracle/run_firegrid_fault.ps1
```

이 드라이버가 도는 lane 3개와 그 의미:

| lane | `DS_KINDS` | 발화점 격자 | 왜 |
|---|---|---|---|
| `fault` | `fault` | `58,80,…,260` (11점) | 희생자가 남은 운반 일을 가짐 → **Replace 가 정답** |
| `faultidle` | `faultidle` | 같은 격자 | 같은 `kind="fault"` 라벨인데 희생자가 일이 없음 → **NOOP 이 정답** |
| `battB` | `battery` | `58,100,140,…260` | battery 축(게이트의 fault 축에는 불필요) |

- `faultidle` 은 `gen_oracle_dataset.jl:188 row_kind()` 가 `"fault"` 로 뭉친다(확인). 두 lane 을
  **둘 다** 돌려야 늦은 진행도의 fault 정답이 전부 Replace 로 쏠리지 않는다.
- **fault 축만 급하면** `battB` lane 은 건너뛰어도 게이트는 복구된다. 다만 `battgrid_0805_s1.jsonl`
  이 이미 battery 축을 덮고 있으므로 중복이기도 하다.
- 드라이버는 `DS_RESUME=1` 이라 **중단해도 이어서 돈다**. 죽으면 그냥 다시 실행할 것.
- 산출물 이름은 반드시 `oracle/out/firegrid_s<lane>.jsonl` 이어야 한다 — `merge_firegrid.py` 의
  기본 glob 이 `firegrid_s*.jsonl` 이라 규칙을 벗어나면 **에러 없이 병합에서 빠진다**.

### STEP 2 — 병합

```bash
cd wm4spacecraft_manufacturing
python merge_firegrid.py           # firegrid_merged.jsonl <- CANONICAL + firegrid_s*.jsonl
```

중복 제거 키는 `(instance, macro, rollout)` 이고 **나중 파일이 이긴다**(재실행 = 수정).
CANONICAL 은 덮어쓰지 않는다.

### STEP 3 — zone 축 (`zcausal_reform`) 4팔

게이트가 읽는 것은 **`blk_noop`, `blk_reloc`, `cov_noop`, `cov_reloc`** 넷뿐이다
(`control`·`harmless_*` 는 안 읽는다).

`run_zcausal_all.sh` 가 있지만 **그대로 쓰지 말 것** — 34행이 팔을 2개씩 **병렬**로 띄운다.
아래 §5 의 함정 ①②에 정면으로 걸린다. 순차로 돌린다:

```bash
OUT=wm4spacecraft_manufacturing/oracle/out/zcausal_reform
mkdir -p "$OUT"
for arm in blk_noop blk_reloc cov_noop cov_reloc; do
  [ -s "$OUT/$arm.json" ] && { echo "[skip] $arm"; continue; }
  ZC_ARM="$arm" ZC_OUT="$OUT/$arm.json" ZC_REFORM=400 ZC_REFORM_MAX=3 \
    julia +lts --project=. tools/restage.jl causal > "$OUT/$arm.log" 2>&1
  echo "[done] $arm -> $(grep -h '^RESULT' "$OUT/$arm.log" | tail -1)"
done
```

`ZC_REFORM=400 ZC_REFORM_MAX=3` 은 원 드라이버와 같은 값이다. **모든 팔에 같은 사다리를 걸어야**
한다 — 복구가 없으면 네 팔이 전부 루트 엔드게임 교착에 갇혀 구역의 효과가 가려진다(원 스크립트 주석).

### STEP 4 — 게이트 검증

```bash
cd wm4spacecraft_manufacturing
python test_llm7h.py            # 목표: 16/16 passed, exit 0
```

**반드시 n 을 눈으로 볼 것.** 통과/실패만 보면 zone 축이 n=0 으로 조용히 통과한 것을 못 잡는다.
기대치(`RESULTS_LLM7H.md §5` 기준):

| 검사 | 기대 |
|---|---|
| battery 규칙 == 오라클 최선 (battgrid) | n=18 |
| fault 규칙 == 오라클 최선 (firegrid) | **n=42** (CANONICAL 18 + firegrid 24) |
| zone 규칙 == 오라클 최선 (zcausal) | **n=2** (`blk`, `cov`) — 가장 약한 축 |

`n=0` 이거나 fault 가 18 에 그치면 STEP 1~3 중 무언가가 조용히 빠진 것이다.

그 다음에야 결과표 재측정으로 넘어간다:

```bash
python llm_ood_eval.py run --seeds 1,2,3,4,5 --policies noop,canonical,surrogate,dspy
python llm_ood_eval.py report --json artifacts_llm7h/final.json
```

## 4. 비용 (추정 — 실측 아님)

- fault + faultidle = 11 발화점 × 2 lane × (3팔 + control 1) ≈ **88 판**.
  `cost_eval` 이 기록한 판당 `label_seconds` 는 **81초**였다 → 약 **2시간**. 이 값은 다른 설정에서
  나온 것이므로 그대로 믿지 말 것.
- zcausal 4팔 = 각 팔이 전체 빌드 1회 → **수십 분** 규모.
- 둘 다 `DS_RESUME` / `[ -s ...]` 로 재개 안전하므로 나눠서 돌려도 된다.

## 5. 함정 (2026-08-09 확인)

① **순차로 돌릴 것.** 병렬이면 HiGHS 가 런마다 다른 스케줄을 내서 **팔 사이 비교 자체가 무효**가
   된다(`CLAUDE.md` 함정 30). zcausal 은 팔끼리 반사실 비교를 하는 실험이라 특히 치명적이다.

② **메모리.** 판 하나가 `DS_STACK`(기본 2GB) 스택을 통째로 잡는다. `run_firegrid_fault.ps1` 주석에
   따르면 lane 2개 병렬로 16GB 머신에서 `OutOfMemoryError` 가 났다. 2026-08-09 측정 시점의 여유는
   **2.0 GB / 15.7 GB** 였다 — 편집기·브라우저·PowerPoint 가 쥐고 있었다. 돌리기 전에 정리할 것.

③ **`ZC_OUT` 은 append 모드다**(`tools/restage.jl:1091` `open(OUT, "a")`). 같은 파일에 두 번 쓰면
   JSON 객체가 두 개 이어붙어 `json.load()` 가 깨진다. 위 루프의 `[ -s ... ]` 가드를 빼지 말 것.
   이미 깨졌다면 그 `.json` 을 지우고 그 팔만 다시 돌린다.

④ **`restage.jl causal` 의 출력 키는 게이트와 일치한다**(확인): `status`, `closed`, `root_covered`,
   `nav_blocked`. 스키마 때문에 다시 돌릴 일은 없다.

⑤ **`firegrid_s*.jsonl` 이름 규칙**(§STEP 1) — 벗어나면 병합에서 조용히 빠진다.

⑥ **`DS_SEEDS` 를 늘리지 말 것.** 그건 "다른 공장"(로봇 초기 배치)이지 확률성이 아니다. 배포
   world 는 항상 seed 1 이다. 예산은 전부 발화 시점(`DS_FIRE_GRID`)에 쓴다 — `run_firegrid_fault.ps1`
   의 "축 결정" 주석이 이 판단의 근거이고, "seed 를 30 까지"라는 옛 계획은 철회됐다.

## 6. 재빌드하지 않기로 한 것

`verify.py` 는 `graded_hs_n44.jsonl`(5매크로)에서 **8/8 PASS** 로 재현되지만,
현행 학습셋 `n44_plus78.jsonl`(7매크로)에서는 `S1 KeyError: 7` 로 죽는다(2026-08-09 실측).
이건 라벨이 없어서가 아니라 **harness 가 7·8 을 아직 못 다루기 때문**이므로, 데이터 재생성이
아니라 `verify.py::norm_regret` 수정으로 풀어야 한다. 이 문서의 범위 밖.
