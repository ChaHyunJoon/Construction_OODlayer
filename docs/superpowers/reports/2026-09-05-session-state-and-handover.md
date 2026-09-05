# 세션 상태 인계 (2026-09-05) — zone 레인, 유료 런 13판

이 문서는 컨텍스트 압축 직전에 쓴 것이다. **다음 세션은 이것부터 읽는다.**
표기: `[측정]` = 실제로 잼 · `[미측정]` = 코드 읽기. 코드는 **함수·testset 이름**으로 가리킨다.

---

## 0. 지금 무엇을 하고 있었나 (한 문단)

zone OOD 사건에서 multi-agent LLM 이 새 Julia 도구를 합성해 **미완주 build 를 완주시키는** 데모를
만드는 중. 배관은 전부 라이브에서 작동함을 확인했고, **모델 출력이 진동해서** 안 되고 있다.
사용자 지시로 모델을 `gpt-4o` → **`gpt-5.6-sol`** 로 바꾸는 중이며, 두 판(런 12·13)이 **배선에서**
죽어 **아직 sol 의 능력을 한 번도 관측하지 못했다**.

🔵 **진행 중인 작업 하나**: 런 13 의 blank decision 원인 진단(서브에이전트). 아래 §6.

---

## 1. 🔴 합격 기준 (사용자 정의, 구속력 있음)

> "multi agent workflow 가 새로운 tool 을 만들 때 **아무런 에러 없이** 만들어야 하고,
>  그에 따라 **simulation demo 까지 정확히** 만들 수 있어야 한다"

| # | 기준 | 술어 | 현재 |
|---|---|---|---|
| A1 | multi-agent 가 만든다 | `ORACLE BYPASS` 배너 0건 · `expressible=False` | ✅ (런 6·8·10·11) |
| A2 | **에러 없다** | `registered=true` · `steps[1].status === :success` · `partial=false` | ✅ 런 6·8 |
| A3 | 도구가 일한다 | L3 `interface_calls ≠ []` · **L4 `world_delta_body` ≠ 0** | ❌ 전 판 0 |
| A4 | 데모가 정확히 나온다 | `PROJECT COMPLETE!` + `render_demo.jl` 이 **발행** | ❌ |
| A5 | 결과가 더 낫다 | 대조 INCOMPLETE(270/305) → 완주 | ❌ |

🔴 **A4 는 아직 한 번도 안 태웠다** — 전부 `DEMO_ANIM=0` 으로 돌렸다. 기본값은 `1` 이고,
미완주면 `error("refusing to publish incomplete animation …")` 로 발행을 거부한다.
**최종 판정 런은 `DEMO_ANIM=1` 로 한 번 돌려 발행까지 확인해야 한다.**

🔴 **오라클(`DEMO_SYNTH_FIXTURE`)은 A1 을 만족하지 않는다.** 수단이지 목표가 아니다.

---

## 2. 사건과 대조 — **zone 으로 확정**

```bash
DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 DEMO_CASE_TAG=zone_mild \
DEMO_POLICY=dspy DEMO_ANIM=0
```
🔴 **`DEMO_OOD=none` 이 필수** — `DEMO_OOD=zone*` 은 `case_kinds` 에서 **하드에러**다.
zone 은 직교 플래그 `DEMO_ZONE=1` 로 켠다. 사건은 **pre-sim** 에 주입되고 결정은 `closed=54` 에 난다.

| | 대조 (tool off) | 오라클 `OracleZoneClear!` |
|---|---|---|
| 완주 | **INCOMPLETE** | ✅ **COMPLETE** |
| `t` / `n_closed` | 5776 / 270 | 1022 / **287** |
| `total_energy_J` | 242615 | 90406 |

**목표 body (오라클이 증명)**: `active_restriction_zones` → `restage_all_blocked!` →
(거절 `:already_started`) → **`translate_whole_build!`**. **2단 확대가 필요하다.**
🔴 완주 판정은 `CB.project_complete` 이지 `n_closed == n_total` 이 **아니다**(완주해도 287/305).

**mild battery 는 폐기했다** — 오라클 3판으로 개선 불가 판정(N = −2.13 / 0.0 / −3.52).
근거 정본: `docs/superpowers/reports/2026-09-05-oracle-reassignment-refutes-the-premise.md`.

---

## 3. 지표 (mild 용으로 만들었으나 zone 에서도 유효)

- 잡음 바닥 = **정확히 0** [측정]: 같은 디렉토리 순차 실행. 처치·대조가 사건 **전** 프레임에서 바이트 동일.
- `min_soc` 은 `energy_J[대상]` 의 충실한 변환(1.208e-7 soc/J, 18구간).
- 척도 무관: `N = 1 − ΔE_처치/ΔE_대조`, 사건 프레임 **이후** 증분만.
- 🔴 **`_battery_load_features`(`tools/monitor/policy.jl`)가 payload 를 팀 크기로 안 나눠 프롬프트에
  넣는다 — 120쌍 중 9쌍(7.5%) 순위 역전.** 미수정. 옳은 것은 `cargo_burden_after`.

---

## 4. 오늘 착륙한 커밋 (전부 변이 증명 있음)

| 커밋 | 무엇 |
|---|---|
| `b3a62982` | `release_pending_assignments!` 광고. 🔴 `export` 만으론 무동작(`callable:false`) — `_CURATED_SEEDS` 필요 |
| `bca635f1` | `/rewrite` catch 가 첫 줄이 아니라 진짜 사유를 찍는다 |
| `c0cff8f3`+`b62133b4` | 프레임에 에너지 축(`total_energy_J`·`soc_spread`·로봇별 `energy_J`) |
| `09204a2c` | `ood_event_target()` — 사건 대상을 **id 객체**로 답한다 |
| `c444666d` | 모듈 비수식 짧은 agent 형식 수용 |
| `bc1e9d5b` | **S5** 인자 채널이 지어낸 로봇 정체를 못 나른다(`_is_generated` 게이트, 변이 5) |
| `b99c2ce3` | **오라클 우회** `DEMO_SYNTH_FIXTURE` — 시끄럽고, 폴백 없고, 게이트 안 낮춤 |
| `5a2ede9d` | `forbid_heavy_cargo!` 광고 (감춘 다섯 → 셋) |
| `7596d0b1` | **L4 여섯째 축** `n_staging_moved` — 기하 수리가 안 보였다 |
| `57a7d588` | zone **종단성**을 그래프 사실로 계산해 보고(비율이 아니라 술어) |
| `86b5be25` | **S6** 자리채움 토큰 차단(변이 7) |
| `ba11fa09` | **키워드인자 타입** 광고(37/44 메서드) |
| `2a18fe44` | **메서드 `returns`** 광고 (블록 33k→40k자) |
| `94bd8132` | **D17b** 되먹임을 집행 **예외**까지(변이 8). `allow_redefine` 필요 |
| `fbf6d17c` | **D17c** 되먹임을 **잰 무동작**까지(변이 10). 상한 1 을 런 전체에 강제 |
| `730951cd` | 🔴 **`/rewrite` 가 한 번도 성공 못 한 진짜 이유 = `retries = 0`**(죽은 keep-alive 소켓). `retry_non_idempotent=true` 가 하중을 진다 |
| `1f715885` | 되먹임 params 계승 — 우리 설치 코드가 **원본 스키마를 덮어쓰고 있었다** |
| `5dd9d7f4` | `DSPY_MODEL_TYPE` / `DSPY_TEMPERATURE` knob (responses 전송) |
| `24d910ea` | `DSPY_MAX_TOKENS` knob |

---

## 5. 유료 런 13판 — 실패가 매번 **키워드인자에서** 났다

| 런 | 모델 | L1 | L2b | L3 | L4 | 죽은 자리 |
|---|---|---|---|---|---|---|
| 1–5 | gpt-4o | | ❌ | | 0 | 필드명 → `"R1"` → kwarg 기본값 → `::Int64` → `["R2"]` |
| 6 | gpt-4o | ✅ | **✅ 최초** | ✅ | 0 | 좌표 튜플 · 거짓 `:success` |
| 7 | gpt-4o | ✅ | ❌ | — | 0 | `["goal1",…]` |
| 8 | gpt-4o | ✅ | — | ✅ | 0 | **조립된 Symbol · 무동작** (예측 적중) |
| 9 | gpt-4o | ✅ | — | — | 0 | 무동작 게이트 발화, `/rewrite` 왕복 실패 |
| 10 | gpt-4o | ✅ | — | — | 0 | 🔴 **`/rewrite` 사상 처음 서비스 도착** → 고친 body 가 `reject:param_type` |
| 11 | gpt-4o | ✅ | — | ❌ None | 0 | 되먹임 완주(`retried`) → 두 번째 body 가 **주석 스텁** |
| 12 | **sol** | — | — | — | — | 🔴 **전송 오류** — function tools + reasoning_effort 거부 |
| 13 | **sol** | — | — | — | — | 🔴 **blank decision** — 진단 중 |

🔴 **13판 다 "세계에게 묻지 않고 식별자를 지어냈다" 다.** 모양만 바뀌었다.
🔴 **런 12·13 은 배선에서 죽어 sol 능력을 관측하지 못했다.**

---

## 6. 🔵 진행 중 / 즉시 다음 수

1. **진행 중**: 런 13 blank decision 진단(서브에이전트 `task-sol-blank-report.md`).
   ⓑ `tool_lane_error`(빈/파싱 불가) 인지 ⓒ `tool_calls_n==0`(호출 없음) 인지 가른다.
   🔴 유력 가설: **responses 에서 출력 상한이 추론 토큰을 포함하고 절단이 조용하다**.
   대조 사실: 같은 모델·같은 전송·`tool_choice="required"` 의 **작은** 프로브(1296 토큰)는
   tool call 을 정상 반환했다 [측정]. 실제 프롬프트는 **40k자**다.
2. 그 뒤 서비스 재기동 → 런 14(sol) → **sol 의 첫 유효 관측**.
3. sol 이 통과하면 → `DEMO_ANIM=1` 로 최종 판정 런(A4).
4. sol 도 같은 자리에서 죽으면 → 남은 것은 설계 결함이고, `gpt-5.5-pro`($30/$180) 비교가 다음.

### 서비스 기동 (현행)
```bash
DSPY_MODEL=gpt-5.6-sol DSPY_MODEL_TYPE=responses DSPY_TEMPERATURE=none DSPY_MAX_TOKENS=16000 \
TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 DSPY_CACHE=0 \
.venv/bin/python -m uvicorn dspy_service:app --app-dir src/respec/llm_service \
  --host 127.0.0.1 --port 8077
```
🔴 `pkill -f "…port 8077"` **금지**(자기 셸을 죽인다). 포트별 PID 로 죽인다.
🔴 `/health` 200 은 세대 증거가 아니다 — `tools/require_current_service.sh` 로 판정.
✅ `_served_files` 가 `test_*.py` 를 **제외**하므로 pytest 만 고친 커밋은 재기동 불필요.

---

## 7. 🔴 이 세션이 되풀이해 밟은 것 — 다음 세션이 알아야 할 것

1. **"배선했다" ≠ "작동한다".** `/rewrite` 는 3커밋·25변이 증명·모든 시험 초록인 채로
   **라이브에서 단 한 번도 안 돌았다**. 원인은 `retries=0` 이었고, 모든 시험이 **스텁**을 상대로 돌았다.
   ⟹ **라이브 왕복을 요구하는 게이트 없이 채널을 완성했다고 하지 말 것.**
2. **프롬프트가 세계에 없는 결과를 주장했다** — 두 번. mild 는 "느리게 움직인다"(실측 계수 1.0),
   zone 은 심각도를 기하 겹침으로(실제 해악은 종단성). **모델을 탓하기 전에 서술이 참인지 재라.**
3. **규칙을 더하면 실패가 옮겨간다** — 5회 측정. 처방은 산문이 아니라 **기계 유도된 사실**
   (키워드 타입 · 반환 타입 · 종단성 술어)이어야 한다.
4. **자기신고를 판정에 쓰지 말 것.** `steps[1].status` 는 모델이 반환한 심볼이다.
   런 6 이 `:success` 를 냈는데 세계는 안 움직였다. 진실은 L4 다.
5. **n=1 로 판정하지 말 것.** 런 간 분산이 크다(런 6 최고 → 런 11 최악). 내가 이 실수를 했다.

---

## 8. 아직 안 닫힌 것

- `test/smdp_global_inventory.jl` **HEAD 에서 빨감**(선행 존재, 미분류 전역 20) — 이 레인 것 아님.
- `_battery_load_features` 의 7.5% 오류(§3).
- `translate_whole_build!` 의 반환이 `NamedTuple` 로만 광고돼 tier-2 상태 어휘가 안 보인다.
- `world_delta_body` 여섯 축은 배터리 스왑·`SPARE_POOLS`·fault 플래그·배송을 **안 본다**.
- 되먹임 두 번째 시도가 또 무동작이면 상한 1 이라 끝이다. 두 시도의 `impl_code` 동일 여부를 안 찍는다.
