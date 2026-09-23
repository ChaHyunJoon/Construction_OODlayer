# 존 복구 base ablation — 설계 (2026-09-23)

## 0. 목적

> 사람이 작성한 **존 복구 전용 함수와 해법 정보**를 제공하지 않고, 동일한 물리 관측 및 기본 상태
> 조작 API 만 제공했을 때, LLM 이 복구 절차를 직접 생성하여 건설을 완주할 수 있는지 검증한다.

**범위 밖(모든 팔에서 오늘과 같이 켜 둔다):** 일반 교착 해소(`CARRIER_RESCUE=1`, 스냅·reform 사다리),
MILP 재풀이, 캐시 재개, 주행 3층 정책. 따라서 A2 가 성공해도 결론은 "**존 복구** base 없이 완주" 이지
"사람이 만든 복구 로직 전부 없이 완주" 가 아니다.

## 1. 배경 — 오늘 결과가 무엇에 기대고 있는가

`results/2026-09-23-router-sol/README.md`: sol 세 agent, 120판 중 117 완주. 원장 decide 120행 중
110행이 사람이 쓴 `translate_whole_build!`(`src/respec/restage_zone.jl`, 최초 `aafd7655` 2026-07-30)를
부르고, 68행은 수동 ForbidZone 매크로(`replan.jl` `_enact_one!`)와 같은 `restage_all_blocked!` →
`translate_whole_build!` 사슬이다. 광고 문구가 그 사슬을 직접 알려준다(`restage_all_blocked!` 의
`:residual_blocked` 설명). ⟹ 현재 결과로는 "좋은 함수를 골랐다" 와 "복구를 구현했다" 를 구분할 수 없다.

## 2. 팔

| 팔 | 역할 | 제거 대상 |
|---|---|---|
| `none` | **동일 버전 대조군**(오늘 117판을 재사용하지 않는다, §7) | 없음 |
| `A1 translate` | 원인 분석: 국소 restage 해법이 남을 때 전체 이동을 스스로 만드는가 | 평행이동 해법·실행부 |
| `A2 all` | **주 실험** | 존 복구 해법·실행부 전부 |

setter 로 모델이 직접 평행이동·재적치를 구현하는 것은 **허용**한다 — 그것이 재려는 능력이다.

## 3. 함수 분류 (관측과 해법을 분리한다)

함수는 네 부류로 나눈다. **센서는 어느 팔에서도 지우지 않는다.** 그래야 "해법 제거" 와 "정보 제거" 가
섞이지 않는다.

| 부류 | 함수 | none | A1 | A2 |
|---|---|---|---|---|
| 센서 | `zone_blockage`(막힘·목표별 상세), `active_restriction_zones`, `zone_blocked_assemblies`, `root_deposit_goals`, `root_goal_coverage`, `zone_clears_root_goals`, `zone_team_coverage`, **새 `zone_facts`**(§4), 좌표 접근자(`global_transform` 등) | ✔ | ✔ | ✔ |
| 기본 상태 조작 | `set_desired_global_transform!` 등 씬트리 setter, `reset_cache_resume!` | ✔ | ✔ | ✔ |
| 동기화 | `_resync_scene_drift!` | (미광고) | (미광고) | **결정 D1** |
| 해법(solver) | `find_clear_staging_center` | ✔ | ✔ | ✘ |
| 〃 | `_find_min_translation`, `_find_clear_translation`, `_minimum_clear_translation`, `zone_relocatable`, `core_zone_for_severity` | ✔ | ✘ | ✘ |
| 해법+센서 혼합 | `zone_diagnosis`, `zone_diagnoses` (`feasible`·`relocate_delta`·`verdict` 를 계산) | ✔ | ✘ | ✘ |
| 실행부(actuator) | `restage_assembly!`, `restage_all_blocked!` | ✔ | ✔ | ✘ |
| 〃 | `translate_whole_build!`, `_apply_uniform_translation!` | ✔ | ✘ | ✘ |

## 4. 새 센서 `zone_facts(env; zone)` — 모든 팔에 광고

`zone_diagnosis` 의 **관측 필드만** 담는다: `center`, `radius`, `blocked`(재적치 대상 후보가 아니라
"비-root·미시작·존과 겹침" 이라는 상태 사실), `root_covered/total/frac`, `n_work_overlap`, `teams`,
`n_teams_forming/covered`, 항법 막힘 필드 전부(`zone_blockage` 유래).
**빼는 것:** `feasible`, `n_restage_feasible`, `relocate_delta`, `relocate_norm`, `relocate_feasible`, `verdict`.
`zone_diagnosis` 를 안에서 부르지 않고 센서만으로 조립한다(해법기 호출 0 을 시험으로 고정).

## 5. 모든 팔에 공통으로 적용하는 프롬프트·관측 변경

팔 사이의 차이를 **함수 가용성 하나**로 만들기 위해, 아래 변경은 `none` 을 포함한 세 팔에 똑같이 적용한다.
(오늘 117판과 새 `none` 의 차이는 이 변경 + 코드 정리의 합산 효과이며, 부수 보고로만 쓴다.)

- `PHYSICAL_PRINCIPLES`(`synthesize.py` §2): "Moving staging areas or translating the whole build edits
  THIS tree" → "Geometric edits (staging poses, deposit goals, build placement) edit THIS tree".
- 관측 `_GEOM_COVERAGE`(`dspy_service.py`): 해법 산출인 `zone_restage_feasible`("of which movable") 행과
  "the root cannot be restaged" 문구를 뺀다. 센서 사실(root 목표가 존 안에 몇 개인가)은 남긴다.
- 원장·스트림에 `repair_ablation` 을 기록한다.

광고 문구 중 **팔 고유**인 것: 차단된 이름을 언급하는 광고 문장은 전부(상태 설명 — 예: `restage_all_blocked!`
의 `:residual_blocked` — 과 센서 설명 — 예: `zone_blocked_assemblies` 의 "the set a single `restage_assembly!`
misses") 그 이름이 차단된 팔의 산출물에서만 지운다. 없는 함수를 가리키는 문장이기 때문이다. 산출물 전체에
차단된 이름이 0 회임을 시험으로 고정한다.

## 6. 차단 — 네 층

광고에서만 빼면 새기 때문에 네 층 모두 둔다. 조사 근거: D15 게이트는 `isdefined` 만 보므로 미광고
내부 함수도 부를 수 있고(`minted_registration.jl:289`), unwedge 사다리가 LLM 없이
`restage_all_blocked!` → `translate_whole_build!` 를 부른다(`replace_robot.jl:616-624`).

1. **광고**: `gen_world_interface.jl` 이 팔별 산출물을 낸다(`world_interface.json` /
   `.ablate_translate.json` / `.ablate_all.json`). 기본 산출물은 바이트 동일로 유지한다.
2. **등록 게이트**: body AST 에 차단된 심볼이 나오면 `reject:ablated_primitive:<name>` 로 거절한다.
   `CB.x`, `getfield(_, :x)`, `QuoteNode` 형태를 포함한다. `/rewrite` 로 가는 사유는 대안을 적지 않고,
   "가까운 이름" 제안에서 차단된 이름을 뺀다.
3. **실행 가드(전역)**: 존 주입이 **끝난 뒤** 켠다(주입은 `zone_relocatable` 로 존을 고르므로 가드 밖이어야
   세 팔의 존이 같다). 켜진 뒤 차단된 함수가 불리면 `AblatedPrimitiveError` 를 던지고 호출자별로 센다.
   명시적 면제는 둘뿐이다: 모니터 기록용 사후 `zone_diagnosis`(`policy.jl:2414`, LLM 에 안 간다), 채점.
   면제된 호출도 센다. 판 끝에 `[ablation] level=… denied=… exempt=… ladder_zone_skipped=…` 한 줄을
   **항상** 찍는다(0 이어도 찍는다 — 조용한 0 방지).
4. **자동 복구 경로**: `recover_stalled_teams!` 의 존 분기(restage→translate)는 ablation 팔에서 건너뛰고
   센다. `none` 에서는 오늘처럼 동작하되 **발동 횟수를 센다** — 오늘은 이 경로의 기여를 잴 수단이 없었다.
   `enact_reform!` ZONE_RESCUE 등 현재 도달 불가인 경로는 층 3 이 잡는다.

**핸드셰이크**: Julia 가 `/decide` 요청에 자기 `REPAIR_ABLATION` 을 싣고, 서비스 값과 다르면 서비스가
크게 실패한다. campaign 지문의 cell 축에 `REPAIR_ABLATION` 을 넣는다.

## 7. 동일 버전 대조와 동등성

세 팔은 **같은 코드 버전, 같은 서비스 설정**으로 같은 날 돈다. 오늘 117판(실패 3판 포함 120판)은 비교
대상이 아니라 참고값이다. 판마다 아래가 세 팔에서 같아야 하며, 다르면 그 쌍을 버리지 않고 보고한다.

- 시드(`DEMO_SEED`·`DEMO_ZONE_SEED`), 존 배치(`zone_place` 문자열), 존 주입 시점(sim step), 초기 상태 지문
- 모델·전송(`gpt-5.6-sol`, responses, temperature none, max_tokens 16000), 캐시 off, `/rewrite` 재시도 예산, W

격자: tractor·X-wing × zone·all3 × 30시드 × 3팔 = **360판**.

## 8. 실현 가능성 오라클 (무료, 유료 런보다 먼저)

A2 어휘(§3 의 A2 ✔ 만)로 사람이 쓴 body `OracleZoneClearNoBase!` 를 픽스처로 만들어
`DEMO_SYNTH_FIXTURE` 로 **120 시드 전부**에 태운다(서비스 안 탐, 유료 0원).

**해석 규칙:**
- 오라클이 시드 s 를 완주 → "그 조건에서 A2 어휘로 풀 수 있다" 의 증거. A2 LLM 실패는 모델 능력으로 해석 가능.
- 오라클이 시드 s 를 미완주 → **실현 가능성 확인 실패. 그 시드의 LLM 실패 원인 해석을 보류한다.**
  (불가능의 증명이 아니다 — 오라클 구현 오류·동기화 누락·예산 부족일 수 있다.)
- A1 어휘는 A2 의 상위집합이므로 A2 오라클 완주는 A1 에도 성립한다.

**격리**: 오라클 body 는 `tools/fixtures/` 에만 두고 어떤 프롬프트·예시·광고에도 넣지 않는다. 유료 런에서
`DEMO_SYNTH_FIXTURE` 가 비어 있음을 campaign 지문으로 확인하고, 오라클의 함수명이 원장·렌더된 프롬프트에
0 회임을 검사한다.

**음성 대조**: 기존 `oracle_zone_clear.json`(translate 호출)을 A1·A2 에서 태우면 등록 게이트에서 거절돼야
한다. 거절이 아니면 차단이 안 된 것이므로 멈춘다.

## 9. 측정과 판정

판별 기록: 완주, 존 해소(`n_blocked=0` 이 된 시점), `project_blocked`, 정지 서명(stall·world_deadlock),
body 첫 시도·재시도·throw·거절 사유, `[ablation]` 줄, body 기전 분류(setter 로 직접 평행이동 / 직접
재적치 / 그래프 수술 / 기타), 단계별 비용.

주 비교: 같은 시드 짝으로 `none` vs `A2` 완주율(McNemar), 오라클 완주 시드로 한정한 `A2` 완주율.
보조: `none` vs `A1`, A1 에서 전체 이동을 스스로 쓴 body 비율.

허용되는 주장:

| 결과 | 주장 |
|---|---|
| A2 ≈ none, `denied=0`, 사다리 skip 이 완주에 관여 안 함 | 존 복구 base 없이도 LLM 이 복구 절차를 만든다(§0 범위 안에서) |
| A2 ≪ none, 오라클은 완주 | base 가 성과의 원천이다; LLM 은 base 를 고르는 데 강하다 |
| A2 ≪ none, 오라클도 미완주 | 판단 보류 — 어휘·오라클부터 조사 |
| A1 ≈ none, A2 ≪ none | 전체 이동은 만들 수 있으나 국소 재적치 해법에 기대고 있다 |

## 10. 순서와 게이트

- **G0** 다른 세션의 레포 정리(`wm4spacecraft_manufacturing/` → `src/decision/`)가 커밋될 때까지 코드 수정 금지.
- **G1** 구현 + 시험(분류표를 그대로 고정하는 시험, 기본 산출물 바이트 동일, `zone_facts` 해법기 호출 0,
  AST 우회 형태 거절, 가드의 주입 후 무장·면제·카운터 줄).
- **G2** 음성 대조(§8) — 두 ablation 팔에서 거절.
- **G3** 오라클 120 시드(무료). D1 을 여기서 정한다.
- **G4** 팔마다 파일럿 tractor zone s1–4. `[ablation]` 줄·핸드셰이크·존 배치 동일을 확인.
- **G5** 360판. cost watchdog 상한 $150.

비용 추정: 오늘 판당 $0.16 → 360판 $60 안팎, A2 는 재시도가 늘 수 있어 상한을 넉넉히 둔다.

## 11. 미결 결정

- **D1** `_resync_scene_drift!` 를 기본 상태 API 로 볼 것인가. 오라클(G3)이 setter 만으로 완주하면
  노출하지 않는다. 동기화 없이는 씬 본체가 표류해 완주 못 하면, 공개 래퍼(`resync_scene_to_schedule!`)로
  **세 팔 모두에** 광고한다(팔 간 상수라 단일 요인 설계가 유지된다).
- **D2** A1 에서 `zone_diagnosis` 를 막으면 restage 가능 여부(`feasible`) 정보도 사라진다. 이 설계는
  그것을 해법 정보로 보고 A1 에서도 뺀다(`find_clear_staging_center` 자체는 A1 에 남는다).

## 12. 위험

- 존 선택 편향: 주입이 translate 해법기로 풀리는 존만 받는다(`render_demo.jl:453`). 세 팔 공통이라
  비교는 유효하지만, "임의의 존" 으로 일반화하지 않는다.
- 전역 가드가 오늘 보이지 않던 호출자를 드러내면(면제 밖 `denied>0`) 그 판의 결과를 섞지 말고 호출자부터
  분류한다.
- 세대 게이트: `llm_service/` 를 건드리는 동안 모든 유료 런이 막힌다. 구현 커밋 → 서비스 재기동 → 세대 확인 후 런.
