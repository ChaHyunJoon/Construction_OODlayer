# 오라클 라벨 재빌드 계획 — `test_llm7h.py` 게이트 복구 (2026-08-09)

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
